"""Pi context statistics: what each model request contained, rebuilt from Pi's session files
and shown as a local NiceGUI app.

Usage: stats.py THEME BROWSER

Each assistant message is one model request. Its context is the path from the session root to
that message: system messages patch the prompt sections and tool declarations, the latest
compaction replaces older entries with its summary and prompt checkpoint, and context edits
replace or drop entries. Parts are measured in UTF-8 bytes; their tokens are the part's share
of the request's real prompt tokens (input + cache read + cache write) from the response usage.

Output tokens are split over the response's own text, thinking, and tool calls the same way;
reported reasoning tokens go to thinking. A session's consumption is the sum of its requests'
prompt and output parts, so a part sent with every request weighs more than its context share.

Subagent sessions live in subagent-sessions/; the parent's subagent results and messages
record their session IDs, and how each run of a child ended. A child's notes are its
send_message calls; parent messages (steers and continuations) are its prompts that start
with PARENT_MESSAGE.

THEME is a JSON file of colors, fonts, and sizes, and BROWSER the browser that opens the app;
both are supplied by Nix. The sessions are read once at start and again on reload.
"""

import json
import math
import os
import re
import socket
import statistics
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from functools import cache
from itertools import count, pairwise
from pathlib import Path

from nicegui import app, run, ui

AGENT_DIR = Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent"))
# Image blocks carry base64 data; count each as a fixed size instead.
IMAGE_BYTES = 6000
CONTEXT_FILE = re.compile(
    r'<project_instructions path="([^"]+)">(.*?)</project_instructions>', re.DOTALL
)
# How Pi lists each skill in the system prompt's skills section.
SKILL_TAG = "<skill>"
# How subagent.ts marks the parent's messages to a child, and the child's note tool.
PARENT_MESSAGE = "Message from the parent:"
NOTE_TOOL = "send_message"
# Run endings in subagent.ts, as labeled in the app.
OUTCOMES = {"idle": "Done", "budget": "Budget", "failed": "Failed", "aborted": "Stopped"}
GROWTH_MIN_SESSIONS = 3
# Gaps before a prompt longer than this are breaks, not time spent on the session.
BREAK_MS = 60 * 60 * 1000
# A compaction's time is the gap from the entry before it. After a run ends that gap can
# include your idle time; real compactions take a few minutes, so longer gaps are not counted.
COMPACTION_MAX_MS = 5 * 60 * 1000
# Weight of each new day in the overview's moving averages: about a twelve-day memory.
EMA_ALPHA = 1 / 12
# Where a session's time goes, and the theme colors of the time bar.
TIME_PARTS = {
    "model": "p",
    "tools": "s",
    "subagent waits": "f",
    "compaction": "m",
    "you": "o",
}
PREVIEW = 80
# Part groups in display order, by the prefix of their part names.
GROUPS = {
    "system": "system prompt",
    "context": "context files",
    "tool": "tool definitions",
    "conversation": "conversation",
    "call": "tool calls",
    "result": "tool results",
}
# Sections of the parts table, top to bottom, with the subsections of startup; the chart
# stacks them the other way round, so the system prompt is at the bottom of both.
SECTIONS = ["other", "tool results", "tool calls", "conversation", "startup"]
STARTUP_SECTIONS = ["tool definitions", "context files", "system prompt"]
# The conversation's own parts, in table order; its other parts are listed under other.
CONVERSATION_PARTS = ["conversation:thinking", "conversation:assistant", "conversation:user"]
# The parts table SECTIONS as the chart stacks them, bottom to top, with their theme colors.
CHART_GROUPS = {
    "startup": "o",
    "conversation": "m",
    "tool calls": "p",
    "tool results": "s",
    "other": "f",
}
# Startup groups: the parts of a request before any conversation, and their theme colors, in
# the order the prompt is put together.
STARTUP_GROUPS = {
    "system": ("system prompt", "m"),
    "tool": ("tool definitions", "p"),
    "context": ("context files", "s"),
}


# Session files


def read_session(path):
    entries = []
    for line in path.read_text().splitlines():
        # A line cut off by an interrupted write is skipped.
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    header = next((e for e in entries if e["type"] == "session"), {})
    return header, [e for e in entries if "id" in e]


def size(text):
    # Sizes are UTF-8 bytes.
    return len(text.encode())


def text_size(content):
    if isinstance(content, str):
        return size(content)
    return sum(
        IMAGE_BYTES if block.get("type") == "image" else size(block.get("text", ""))
        for block in content
    )


def text_of(content):
    if isinstance(content, str):
        return content
    return "".join(block.get("text", "") for block in content or [])


def milliseconds(stamp):
    return datetime.fromisoformat(stamp).timestamp() * 1000


def section_of(part):
    # The parts table section and, for startup, the subsection of a part.
    group = part.split(":", 1)[0]
    if group in ("system", "context", "tool"):
        return "startup", GROUPS[group]
    if group in ("call", "result"):
        return GROUPS[group], None
    return ("conversation" if part in CONVERSATION_PARTS else "other"), None


def message_parts(entry, content=None):
    # (part, bytes) for one context entry; content overrides it after a context edit.
    if entry["type"] == "compaction":
        return [("conversation:compaction summary", size(entry["summary"]))]
    if entry["type"] == "branch_summary":
        return [("conversation:branch summary", size(entry.get("summary", "")))]
    if entry["type"] == "custom_message":
        return [(f"conversation:custom {entry['customType']}", text_size(entry["content"]))]
    if entry["type"] != "message":
        return []
    message = entry["message"]
    content = message.get("content") if content is None else content
    role = message["role"]
    if role == "user":
        return [("conversation:user", text_size(content))]
    if role == "toolResult":
        return [(f"result:{message['toolName']}", text_size(content))]
    if role != "assistant":
        return []
    if isinstance(content, str):
        return [("conversation:assistant", size(content))]
    parts = []
    for block in content:
        kind = block.get("type")
        if kind == "text":
            parts.append(("conversation:assistant", size(block["text"])))
        elif kind == "thinking":
            parts.append(("conversation:thinking", size(block.get("thinking", ""))))
        elif kind == "toolCall":
            parts.append((f"call:{block['name']}", size(json.dumps(block["arguments"]))))
    return parts


def output_parts(message):
    # The response's output tokens split over its own blocks; reasoning tokens go to thinking.
    usage = message["usage"]
    output = usage.get("output", 0)
    reasoning = min(usage.get("reasoning", 0) or 0, output)
    parts = defaultdict(int)
    for name, length in message_parts({"type": "message", "message": message}):
        parts[name] += length
    length = sum(parts.values())
    if not length:
        return {"conversation:thinking": output} if output else {}
    shares = {name: (output - reasoning) * value / length for name, value in parts.items()}
    if reasoning:
        shares["conversation:thinking"] = shares.get("conversation:thinking", 0) + reasoning
    return shares


def apply_system(state, message):
    for name, value in (message.get("sections") or {}).items():
        if value is None:
            state["sections"].pop(name, None)
        else:
            state["sections"][name] = value
    for tool in message.get("toolsAdded") or []:
        state["tools"][tool["name"]] = size(json.dumps(tool))
    for tool in message.get("toolsRemoved") or []:
        state["tools"].pop(tool["name"], None)


def context_file_name(path, cwd):
    if cwd and path.startswith(cwd.rstrip("/") + "/"):
        return path[len(cwd.rstrip("/")) + 1 :]
    return path.replace(str(Path.home()), "~")


@cache
def context_parts(text, cwd):
    # The project_context section split into its files and the wrapper text around them.
    files = CONTEXT_FILE.findall(text)
    parts = [(f"context:{context_file_name(path, cwd)}", size(body)) for path, body in files]
    wrapper = size(text) - sum(size(body) for _, body in files)
    return [*parts, ("system:project_context", wrapper)]


def system_parts(state, cwd):
    parts = []
    for name, text in state["sections"].items():
        if name == "project_context":
            parts += context_parts(text, cwd)
        else:
            parts.append((f"system:{name}", size(text)))
    parts.extend((f"tool:{name}", length) for name, length in state["tools"].items())
    return parts


def subagent_records(entries):
    # The subagent tool's results and messages in a session, as (entry, details, content).
    for entry in entries:
        message = entry.get("message") or {}
        if message.get("toolName") == "subagent":
            yield entry, message.get("details") or {}, message.get("content")
        elif entry.get("customType") == "subagent":
            yield entry, entry.get("details") or {}, entry.get("content")


# Data


@dataclass
class Request:
    """One model request: an assistant message with real usage and a system prompt."""

    index: int
    time: str
    model: str | None
    # Prompt tokens: input + cache read + cache write.
    prompt: int
    output: int
    cache: int
    cost: float
    # Pi's time for the whole response, from sending the request; None before Pi recorded it.
    duration: float | None
    # Skills listed in the system prompt.
    skills: int
    # Context bytes in all and per part; context tokens per part; output tokens per part.
    bytes: int
    sizes: dict[str, int]
    parts: dict[str, float]
    out: dict[str, float]


@dataclass
class Compaction:
    """One compaction: the context before it (Pi's count), the context of the first request
    after it and the summary's tokens in that request (None when none followed), the tokens
    of its own run, and its time from the entry before it (None above COMPACTION_MAX_MS).
    """

    before: int
    after: int | None
    summary: float | None
    run: int
    time: float | None


@dataclass
class RunReport:
    """A report a subagent returned to its parent: one per ended child run."""

    child: str
    agent: str
    task: str
    state: str | None
    tokens: float
    resent: float


@dataclass
class Delegation:
    """A child session's runs as its parent saw them, with the child's own totals."""

    child: str
    agent: str
    task: str
    state: str | None
    parent: Session
    session: Session | None
    runs: int = 0
    tokens: float = 0.0
    resent: float = 0.0

    @property
    def requests(self):
        return len(self.session.requests) if self.session else None

    @property
    def consumed(self):
        return self.session.total if self.session else None

    @property
    def active(self):
        return self.session.active if self.session else None

    @property
    def overhead(self):
        # The fixed price of an agent: its startup tokens, sent with every request.
        if not (self.session and self.consumed):
            return None
        return sum(self.session.startup.values()) * len(self.session.requests) / self.consumed

    @property
    def kept(self):
        # What the parent never had to hold: the child's tool results, less the report.
        return max(0, self.session.material - self.tokens) if self.session else None

    @property
    def corrections(self):
        return self.session.parent_messages if self.session else None

    @property
    def notes(self):
        return self.session.notes if self.session else None


@dataclass
class Session:
    id: str
    agent: str
    cwd: str
    child: bool
    requests: list[Request]
    # Part -> tokens over the session, prompt and output parts of every request.
    consumed: dict[str, float]
    compactions: list[Compaction]
    # The index of the first request after each compaction.
    marks: list[int]
    # Milliseconds per TIME_PARTS category, and each counted wait as (prompt time, wait).
    spent: dict[str, float]
    waits: list[tuple[float, float]]
    # Wall-clock span, for the parallelism of a parent's subagent runs.
    start: float
    end: float
    notes: int
    parent_messages: int
    # Part -> how many times it occurred.
    counts: Counter
    # The tool results the session read, each counted once, for delegation's kept out.
    material: float
    bytes_per_token: float
    reports: list[RunReport]
    parent: str | None
    task: str
    # How its runs ended, as its parent recorded them.
    outcomes: Counter
    # The name given in Pi, the latest when renamed.
    name: str | None
    delegations: list[Delegation] = field(default_factory=list)
    # Set for a child whose parent's reports include it.
    delegation: Delegation | None = None

    @property
    def time(self):
        return self.requests[0].time

    @property
    def peak(self):
        return max(self.requests, key=lambda r: r.prompt)

    @property
    def cost(self):
        return sum(r.cost for r in self.requests)

    @property
    def total(self):
        return sum(self.consumed.values())

    @property
    def active(self):
        return sum(self.spent.values())

    @property
    def startup(self):
        # The first request's parts before any conversation, in tokens.
        parts = self.requests[0].parts
        return {n: v for n, v in parts.items() if n.split(":")[0] in STARTUP_GROUPS}


def requests_of(header, entries, uses):
    # The session's requests; uses counts for each entry ID the requests whose context
    # included it.
    by_id = {e["id"]: e for e in entries}
    # Each entry is measured once; later requests share it.
    measured = {}
    index = count()
    for entry in entries:
        message = entry.get("message") or {}
        usage = message.get("usage") or {}
        if message.get("role") != "assistant":
            continue
        prompt = usage.get("input", 0) + usage.get("cacheRead", 0) + usage.get("cacheWrite", 0)
        if not prompt:
            continue
        path = []
        parent = by_id.get(entry.get("parentId"))
        while parent:
            path.append(parent)
            parent = by_id.get(parent.get("parentId"))
        path.reverse()

        edits = {e["targetId"]: e["replacement"] for e in path if e["type"] == "context_edit"}
        state = {"sections": {}, "tools": {}}
        compactions = [i for i, e in enumerate(path) if e["type"] == "compaction"]
        if compactions:
            at = compactions[-1]
            compaction = path[at]
            apply_system(state, compaction.get("systemMessage") or {})
            kept = next(
                (i for i, e in enumerate(path) if e["id"] == compaction["firstKeptEntryId"]),
                at,
            )
            # Kept entries before the compaction, without their system messages, then the rest.
            path = (
                [compaction]
                + [e for e in path[kept:at] if (e.get("message") or {}).get("role") != "system"]
                + path[at + 1 :]
            )
        conversation, included = [], []
        for item in path:
            item_message = item.get("message") or {}
            if item_message.get("role") == "system":
                apply_system(state, item_message)
            elif item["id"] in edits:
                if edits[item["id"]] is not None:
                    conversation += message_parts(item, edits[item["id"]])
                    included.append(item["id"])
            else:
                if item["id"] not in measured:
                    measured[item["id"]] = message_parts(item)
                conversation += measured[item["id"]]
                included.append(item["id"])
        if not state["sections"]:
            continue
        uses.update(included)

        parts = defaultdict(int)
        for name, length in system_parts(state, header.get("cwd")) + conversation:
            parts[name] += length
        total = sum(parts.values()) or 1
        yield Request(
            index=next(index),
            time=entry["timestamp"],
            model=message.get("model"),
            prompt=prompt,
            output=usage.get("output", 0),
            cache=usage.get("cacheRead", 0),
            cost=(usage.get("cost") or {}).get("total", 0),
            duration=message.get("durationMs"),
            skills=state["sections"].get("skills", "").count(SKILL_TAG),
            bytes=total,
            sizes=dict(parts),
            parts={name: value / total * prompt for name, value in parts.items()},
            out=output_parts(message),
        )


def timing(entries):
    """Milliseconds per TIME_PARTS category.

    Model time is each response's durationMs; a turn's tool time is its longest tool result,
    since tools of one turn run in parallel, and counts as subagent waits when it includes a
    subagent wait. Compaction runs from the entry before it, up to COMPACTION_MAX_MS. Your
    time is the wait from the end of a finished run to your next prompt (prompts sent while a
    run continues, such as steering, are not waits; gaps longer than BREAK_MS are breaks),
    plus the time you take to answer the question tool. The session files do not record
    closing Pi or /resume, so a shorter gap across them counts as a wait too.

    Returns the milliseconds per category and each counted wait as (prompt time, wait).
    """
    spent, calls, waits = defaultdict(float), {}, []
    # ended: when the last run finished, None while one runs; entries after it (a mode switch,
    # a changed system prompt) do not shorten the wait.
    previous, turn, waited, ended = None, 0.0, False, None
    for entry in entries:
        stamp = milliseconds(entry["timestamp"])
        message = entry.get("message") or {}
        role = message.get("role")
        if role in ("user", "assistant"):
            spent["subagent waits" if waited else "tools"] += turn
            turn, waited = 0.0, False
        if entry["type"] == "compaction" and previous is not None:
            if stamp - previous <= COMPACTION_MAX_MS:
                spent["compaction"] += stamp - previous
        elif role == "user":
            if ended is not None and stamp - ended <= BREAK_MS:
                spent["you"] += stamp - ended
                waits.append((stamp, stamp - ended))
            ended = None
        elif role == "assistant":
            spent["model"] += message.get("durationMs") or 0
            # A response without tool calls ends the run; one with tool calls continues it.
            ended = stamp if message.get("stopReason") != "toolUse" else None
            for block in message.get("content") or []:
                if block.get("type") == "toolCall":
                    calls[block["id"]] = (block["name"], block.get("arguments") or {})
        elif role == "toolResult":
            duration = message.get("durationMs") or 0
            name, args = calls.get(message.get("toolCallId"), (message.get("toolName"), {}))
            if name == "subagent" and args.get("action"):
                name = f"subagent {args['action']}"
            if name == "question":
                spent["you"] += duration
            else:
                turn = max(turn, duration)
                waited |= name == "subagent wait"
        previous = stamp
    spent["subagent waits" if waited else "tools"] += turn
    return dict(spent), waits


def run_tokens(compaction):
    # Tokens of the compaction's own model request.
    usage = compaction.get("usage") or {}
    return sum(usage.get(key, 0) for key in ("input", "cacheRead", "cacheWrite", "output"))


def compaction_of(entry, requests, previous):
    after = next((r for r in requests if r.time > entry["timestamp"]), None)
    gap = milliseconds(entry["timestamp"]) - milliseconds(previous["timestamp"])
    return Compaction(
        before=entry.get("tokensBefore", 0),
        after=after.prompt if after else None,
        summary=after.parts.get("conversation:compaction summary") if after else None,
        run=run_tokens(entry),
        time=gap if gap <= COMPACTION_MAX_MS else None,
    )


def occurrences(entries, consumed, compactions, bytes_per_token):
    """How many times each part occurred, and its tokens with each occurrence counted once.

    Every message block, custom message, and summary counts once however often later requests
    resend it; each compaction run counts once; startup parts count 1. Tokens are bytes at the
    session's own bytes per token.
    """
    counts, once = Counter(), defaultdict(float)
    for entry in entries:
        for name, length in message_parts(entry):
            counts[name] += 1
            once[name] += length / bytes_per_token
    counts["conversation:compaction runs"] = compactions
    for name in consumed:
        if section_of(name)[0] == "startup":
            counts[name] = 1
    return +counts, once


def reports_of(entries, bytes_per_token, uses):
    """The reports subagents returned to this parent: one per ended child run.

    A report is a subagent wait result or message; its tokens are its bytes at the parent's
    bytes per token, split evenly when one wait returned several runs, and its re-sent
    tokens count every later request that carried it.
    """
    reports = []
    for entry, details, content in subagent_records(entries):
        # Older results have no action; notes are not reports.
        if details.get("action") not in (None, "wait", "event") or details.get("note"):
            continue
        ended = [
            r
            for r in details.get("results", [])
            if r.get("sessionId") and r.get("state") not in ("queued", "running")
        ]
        for result in ended:
            tokens = text_size(content or []) / bytes_per_token / len(ended)
            reports.append(
                RunReport(
                    child=result["sessionId"],
                    agent=result["agent"],
                    task=result.get("task", ""),
                    state=result.get("state"),
                    tokens=tokens,
                    resent=tokens * uses[entry["id"]],
                )
            )
    return reports


def session_of(header, entries, requests, uses, links, child):
    # Session totals; consumption sums every request's prompt parts and output parts.
    agents, parents, tasks, outcomes = links
    session_id = header.get("id")
    consumed = defaultdict(float)
    for request in requests:
        for parts in (request.parts, request.out):
            for name, tokens in parts.items():
                consumed[name] += tokens
    compactions = [e for e in entries if e["type"] == "compaction"]
    for compaction in compactions:
        consumed["conversation:compaction runs"] += run_tokens(compaction)
    consumed = dict(consumed)
    bytes_per_token = statistics.median(r.bytes / r.prompt for r in requests)
    counts, once = occurrences(entries, consumed, len(compactions), bytes_per_token)
    messages = [e.get("message") or {} for e in entries if e["type"] == "message"]
    spent, waits = timing(entries)
    return Session(
        id=session_id,
        agent=agents.get(session_id, "subagent") if child else "main",
        cwd=header.get("cwd", ""),
        child=child,
        requests=requests,
        consumed=consumed,
        compactions=[
            compaction_of(e, requests, previous)
            for previous, e in pairwise(entries)
            if e["type"] == "compaction"
        ],
        marks=[
            next((r.index for r in requests if r.time > e["timestamp"]), len(requests) - 1)
            for e in compactions
        ],
        spent=spent,
        waits=waits,
        start=milliseconds(entries[0]["timestamp"]),
        end=milliseconds(entries[-1]["timestamp"]),
        notes=sum(
            1
            for m in messages
            if m.get("role") == "assistant"
            for block in m.get("content") or []
            if block.get("type") == "toolCall" and block.get("name") == NOTE_TOOL
        ),
        parent_messages=sum(
            1
            for m in messages
            if m.get("role") == "user" and text_of(m.get("content")).startswith(PARENT_MESSAGE)
        ),
        counts=counts,
        material=sum(t for n, t in once.items() if n.startswith("result:")),
        bytes_per_token=bytes_per_token,
        reports=[] if child else reports_of(entries, bytes_per_token, uses),
        parent=parents.get(session_id) if child else None,
        task=tasks.get(session_id, "") if child else "",
        outcomes=outcomes.get(session_id, Counter()),
        name=next(
            (e.get("name") for e in reversed(entries) if e["type"] == "session_info"), None
        ),
    )


def delegations_of(session, children):
    # One delegation per child session: its runs' reports summed, with the child's totals.
    rows = {}
    for report in session.reports:
        row = rows.setdefault(
            report.child,
            Delegation(
                child=report.child,
                agent=report.agent,
                task=report.task,
                state=report.state,
                parent=session,
                session=children.get(report.child),
            ),
        )
        row.runs += 1
        row.tokens += report.tokens
        row.resent += report.resent
        row.state = report.state
    return list(rows.values())


def collect():
    """Every session with requests, children linked to their parents."""
    main_files = sorted(AGENT_DIR.glob("sessions/*/*.jsonl"))
    child_files = sorted(AGENT_DIR.glob("subagent-sessions/*.jsonl"))
    files = [(*read_session(path), False) for path in main_files]
    # Child session ID -> agent name, parent session ID, task, and run endings, from the
    # parents' subagent results and messages. A run's end is delivered once, in a wait result
    # or a message.
    agents, parents, tasks, outcomes = {}, {}, {}, defaultdict(Counter)
    for header, entries, _ in files:
        for _, details, _ in subagent_records(entries):
            ends = details.get("action") in ("wait", "event") and details.get("note") is None
            for result in details.get("results", []):
                if result.get("sessionId"):
                    agents[result["sessionId"]] = result["agent"]
                    parents[result["sessionId"]] = header.get("id")
                    tasks.setdefault(result["sessionId"], result.get("task", ""))
                    if ends and result.get("state") in OUTCOMES:
                        outcomes[result["sessionId"]][result["state"]] += 1
    files += [(*read_session(path), True) for path in child_files]

    sessions = []
    links = (agents, parents, tasks, outcomes)
    for header, entries, child in files:
        uses = Counter()
        requests = list(requests_of(header, entries, uses))
        if requests:
            sessions.append(session_of(header, entries, requests, uses, links, child))
    # Each parent's subagent runs, with the child sessions' own totals; each child keeps its
    # delegation, which knows its parent.
    children = {s.id: s for s in sessions if s.child}
    for session in sessions:
        session.delegations = delegations_of(session, children)
        for row in session.delegations:
            if row.session:
                row.session.delegation = row
    return sessions


# Figures: what the pages show, as text and series.


def numstr(number: float, decimals: int = 2) -> str:
    # Turkish number format: dots between thousands, a comma before decimals.
    if isinstance(number, int):
        return f"{number:,}".replace(",", ".")
    if not math.isfinite(number):
        return "unavailable"
    if round(number, decimals) == 0:
        number = 0.0
    formatted = f"{number:,.{decimals}f}"
    return formatted.replace(",", "_").replace(".", ",").replace("_", ".")


def num(value):
    # Token counts, in thousands, millions, or billions from 10,000.
    if value >= 1e9:
        return f"{numstr(value / 1e9, 1)}B"
    if value >= 1e6:
        return f"{numstr(value / 1e6, 1)}M"
    if value >= 1e4:
        return f"{numstr(value / 1e3, 0)}k"
    return numstr(value, 0)


def trimmed(value):
    # One decimal, left out for whole numbers.
    value = round(value, 1)
    return numstr(int(value)) if value.is_integer() else numstr(value, 1)


def money(value):
    return f"${numstr(float(value), 2)}"


def duration(ms):
    seconds = ms / 1000
    if seconds >= 3600:
        return f"{seconds // 3600:.0f}h{seconds % 3600 // 60:02.0f}m"
    if seconds >= 60:
        return f"{seconds // 60:.0f}m{seconds % 60:02.0f}s"
    return f"{numstr(seconds, 1)}s"


def kib(value):
    return numstr(value / 1024, 1)


def pct(value):
    # A share of exactly 0 is an int, which numstr writes without decimals.
    return f"%{numstr(float(100 * value), 1)}"


def ratio(consumption, context):
    return f"{numstr(consumption / context, 1)}x" if context else "-"


def maybe(value, show):
    return show(value) if value is not None else "-"


def preview(task):
    # A task's first line, cut to PREVIEW.
    line = task.strip().split("\n")[0]
    return line[:PREVIEW] + ("…" if len(line) > PREVIEW else "")


def session_title(session):
    # Its name in Pi; otherwise a run's agent and task, or a session's start and project.
    if session.name:
        return session.name
    if session.child:
        return f"{session.agent} · {preview(session.task)}"
    return f"{session.time[:16].replace('T', ' ')} · {Path(session.cwd).name}"


def session_label(session):
    return (
        f"{session.time[:16].replace('T', ' ')} · {Path(session.cwd).name}"
        f" · {session.agent} · {numstr(len(session.requests))} requests"
        f" · peak {num(session.peak.prompt)}"
    )


def wait_per_turn(items):
    # Your average wait over every counted turn of the sessions.
    waits = [w for s in items for _, w in s.waits]
    return duration(statistics.mean(waits)) if waits else "-"


def overview_figures(sessions):
    # Your usage of Pi over every session: volume, cost, time, and rhythm.
    requests = [r for s in sessions for r in s.requests]
    return [
        ("sessions", numstr(sum(1 for s in sessions if s.agent == "main"))),
        ("input", num(sum(r.prompt for r in requests))),
        ("output", num(sum(r.output for r in requests))),
        ("cost", money(sum(r.cost for r in requests))),
        ("active time", duration(sum(s.active for s in sessions))),
        ("wait/turn", wait_per_turn(sessions)),
    ]


def model_rows(sessions):
    # One row per model, most requests first.
    models = defaultdict(list)
    for session in sessions:
        for request in session.requests:
            models[request.model].append(request)
    rows = []
    for model, items in sorted(models.items(), key=lambda m: -len(m[1])):
        tokens = sum(r.prompt for r in items)
        # Output tokens over response time, for the responses with a duration; it includes
        # the time before the first token, so it compares models rather than measuring raw
        # generation speed.
        timed = [r for r in items if r.duration]
        seconds = sum(r.duration for r in timed) / 1000
        rows.append(
            [
                model,
                numstr(len(items)),
                num(tokens),
                num(sum(r.output for r in items)),
                money(sum(r.cost for r in items)),
                f"%{numstr(100 * sum(r.cache for r in items) / tokens, 0)}",
                numstr(sum(r.output for r in timed) / seconds, 1) if seconds else "-",
            ]
        )
    return ["Model", "Requests", "Input", "Output", "Cost", "Cache", "Tok/s"], rows


def ema(values):
    """The exponential moving average with EMA_ALPHA.

    None (a day without a value) keeps the previous average; days before the first value
    are None.
    """
    averages, current = [], None
    for value in values:
        if value is not None:
            current = (
                value if current is None else EMA_ALPHA * value + (1 - EMA_ALPHA) * current
            )
        averages.append(current)
    return averages


def daily_series(sessions):
    """Calendar days with tokens per day and moving averages of tokens, active hours, and
    your wait per turn in minutes.

    Days without sessions count as zero tokens and hours; waits carry over them. A session's
    active time counts on the day it started; a wait on the day of its prompt.
    """
    tokens, active, waits = defaultdict(int), defaultdict(float), defaultdict(list)
    for session in sessions:
        for request in session.requests:
            tokens[request.time[:10]] += request.prompt + request.output
        active[session.time[:10]] += session.active / 3_600_000
        for stamp, wait in session.waits:
            day = datetime.fromtimestamp(stamp / 1000).date().isoformat()
            waits[day].append(wait / 60_000)
    first, last = date.fromisoformat(min(tokens)), date.fromisoformat(max(tokens))
    days = [(first + timedelta(n)).isoformat() for n in range((last - first).days + 1)]
    daily = [tokens[d] for d in days]
    return {
        "days": days,
        "tokens": daily,
        "tokens_ema": ema(daily),
        "hours_ema": ema([active[d] for d in days]),
        "wait_ema": ema([statistics.mean(waits[d]) if waits[d] else None for d in days]),
    }


def grouped(parts):
    # Part tokens summed per chart group.
    totals = defaultdict(float)
    for name, tokens in parts.items():
        totals[section_of(name)[0]] += tokens
    return totals


def mean_dict(dicts):
    # Each key's value averaged over the dicts (0 where it is missing).
    totals = defaultdict(float)
    for values in dicts:
        for name, value in values.items():
            totals[name] += value / len(dicts)
    return totals


def mean_shares(requests):
    # Each request's context shares, averaged with equal weight per request.
    totals = defaultdict(float)
    for request in requests:
        total = sum(request.parts.values()) or 1
        for name, tokens in request.parts.items():
            totals[name] += tokens / total / len(requests)
    return totals


def startup_figures(items):
    # The startup's tokens and skills, or their means over several sessions; its other
    # sizes and counts are in the parts table's startup rows.
    skills = statistics.mean(s.requests[0].skills for s in items)
    return [
        ("startup tokens", num(statistics.mean(sum(s.startup.values()) for s in items))),
        ("skills", trimmed(skills)),
    ]


def cache_hit(items):
    # The share of the sessions' input read from the provider's cache, over all requests.
    requests = [r for s in items for r in s.requests]
    prompt = sum(r.prompt for r in requests)
    return pct(sum(r.cache for r in requests) / prompt) if prompt else "-"


def subagent_share(items):
    # The subagent runs' share of the tokens of the sessions and their runs together.
    children = sum(d.consumed or 0 for s in items for d in s.delegations)
    own = sum(s.total for s in items)
    return pct(children / (own + children)) if children else "-"


def session_figures(items, average):
    # The same figures for one session or, with average, the means over several.
    def mean(values):
        return statistics.mean(values) if average else values[0]

    return [
        ("requests", numstr(mean([len(s.requests) for s in items]), 0)),
        ("peak context", num(mean([s.peak.prompt for s in items]))),
        ("consumed", num(mean([s.total for s in items]))),
        ("cache hit", cache_hit(items)),
        ("output", num(mean([sum(r.output for r in s.requests) for s in items]))),
        ("cost", money(mean([s.cost for s in items]))),
        ("active time", duration(mean([s.active for s in items]))),
        ("wait/turn", wait_per_turn(items)),
        *startup_figures(items),
        ("subagents", trimmed(mean([len(s.delegations) for s in items]))),
        ("subagent share", subagent_share(items)),
    ]


def context_columns(session):
    # The context of each request stacked by chart group, with the compactions.
    labels = [numstr(r.index + 1) for r in session.requests]
    return labels, [grouped(r.parts) for r in session.requests], session.marks


def history_columns(items):
    # Each session's consumption stacked by chart group, by start day.
    return [s.time[:10] for s in items], [grouped(s.consumed) for s in items]


def startup_segments(items):
    # The startup's parts, averaged part by part over the sessions, as (tokens, color, part)
    # by group in prompt order, largest first per group.
    tokens = mean_dict([s.startup for s in items])
    return [
        (value, color, name.split(":", 1)[1])
        for key, (_, color) in STARTUP_GROUPS.items()
        for name, value in sorted(
            ((n, t) for n, t in tokens.items() if n.split(":")[0] == key),
            key=lambda item: -item[1],
        )
    ]


def parts_rows(context, consumed, sizes, counts, sessions=None, context_shares=None):
    """Every part, nested in SECTIONS (startup in STARTUP_SECTIONS), as table rows.

    context: part -> tokens in the context; consumed: part -> tokens over the session;
    sizes: part -> bytes; counts: part -> how many times it occurred (per session in
    averages); sessions, for averages: each session's set of parts, counted for every row;
    context_shares, for averages: part -> its context share averaged over the requests, so
    each request weighs the same, instead of its share of the mean tokens.

    Returns the headers, and rows of id, parent, depth, branch (it opens to rows below it),
    the color of a section, and the cells.
    """
    ctx_total = sum(context.values()) or 1
    if context_shares is None:
        context_shares = {name: tokens / ctx_total for name, tokens in context.items()}
    cons_total = sum(consumed.values()) or 1
    ids = count()

    def cells(label, members):
        ctx = sum(context.get(n, 0) for n in members)
        share = sum(context_shares.get(n, 0) for n in members)
        cons = sum(consumed.get(n, 0) for n in members)
        row = [
            label,
            num(ctx),
            pct(share),
            num(cons),
            pct(cons / cons_total),
            ratio(cons / cons_total, share),
            kib(sum(sizes.get(n, 0) for n in members)),
            numstr(
                float(sum(counts.get(n, 0) for n in members)), 1 if sessions is not None else 0
            ),
        ]
        if sessions is not None:
            row.append(
                numstr(sum(1 for present in sessions if any(n in present for n in members)))
            )
        return row

    rows = []

    def add(parent, depth, branch, color, cells):
        node = next(ids)
        rows.append(
            {"id": node, "parent": parent, "depth": depth, "branch": branch, "color": color}
            | {"cells": cells}
        )
        return node

    def nest(label, members, parent, depth, fixed=None, children=None):
        # A row that opens to its parts, or to child rows given as (label, members).
        if not members:
            return
        color = CHART_GROUPS[label] if depth == 0 else None
        node = add(parent, depth, True, color, cells(label, members))
        if children:
            for child_label, child_members in children:
                nest(child_label, child_members, node, depth + 1)
            return
        names = (
            [n for n in fixed if n in members]
            if fixed
            else sorted(members, key=lambda n: -consumed.get(n, 0))
        )
        for name in names:
            add(node, depth + 1, False, None, cells(name.split(":", 1)[1], [name]))

    by_section = defaultdict(list)
    for name in set(context) | set(consumed):
        by_section[section_of(name)].append(name)
    for section in SECTIONS:
        if section == "startup":
            children = [(sub, by_section[("startup", sub)]) for sub in STARTUP_SECTIONS]
            members = [n for _, part_names in children for n in part_names]
            nest(section, members, None, 0, children=children)
        else:
            fixed = CONVERSATION_PARTS if section == "conversation" else None
            nest(section, by_section[(section, None)], None, 0, fixed)
    headers = ["Part", "Context", "Context %", "Consumed", "Consumed %", "Ratio", "KiB"]
    headers.append("Count/session" if sessions is not None else "Count")
    if sessions is not None:
        headers.append(f"Sessions/{numstr(len(sessions))}")
    return headers, rows


def session_parts(session):
    # The parts at the session's peak context, with its consumption and counts.
    peak = session.peak
    return parts_rows(peak.parts, session.consumed, peak.sizes, session.counts)


def average_parts(items):
    # Each part's mean context, size, consumption, and count over the sessions.
    requests = [r for s in items for r in s.requests]
    consumed = defaultdict(float)
    for session in items:
        for name, tokens in session.consumed.items():
            consumed[name] += tokens
    return parts_rows(
        mean_dict([r.parts for r in requests]),
        {name: tokens / len(items) for name, tokens in consumed.items()},
        mean_dict([r.sizes for r in requests]),
        {n: c / len(items) for n, c in sum((s.counts for s in items), Counter()).items()},
        [set(s.consumed) for s in items],
        mean_shares(requests),
    )


def time_spent(items):
    # Milliseconds per TIME_PARTS category, as means per session over several.
    return {part: sum(s.spent.get(part, 0) for s in items) / len(items) for part in TIME_PARTS}


def mean_duration(values):
    # The mean of the known durations, "-" without any.
    known = [v for v in values if v is not None]
    return duration(statistics.mean(known)) if known else "-"


def compaction_figures(items):
    # The compactions per session, then means over every compaction; None without any.
    every = [c for s in items for c in s.compactions]
    if not every:
        return None
    done = [c for c in every if c.after and c.before]
    return [
        ("compactions", trimmed(len(every) / len(items))),
        ("context before", num(statistics.mean(c.before for c in every))),
        ("context after", num(statistics.mean(c.after for c in done)) if done else "-"),
        ("summary", num(statistics.mean(c.summary for c in done)) if done else "-"),
        ("run tokens", num(statistics.mean(c.run for c in every))),
        ("compaction time", mean_duration([c.time for c in every])),
    ]


def compression(row):
    # Tokens of the child's work per token of report, when both are known.
    if not (row.consumed and row.tokens):
        return "-"
    return f"{numstr(row.consumed / row.tokens, 0)}x"


def parallelism(rows):
    # The children's summed active time over the wall-clock span they covered.
    sessions = [r.session for r in rows if r.session]
    span = max((s.end for s in sessions), default=0) - min(
        (s.start for s in sessions), default=0
    )
    active = sum(s.active for s in sessions)
    return f"{numstr(active / span, 1)}x" if span > 0 else "-"


def delegations_figures(session):
    # A parent's subagent runs together; their number and share are among its figures.
    rows = session.delegations
    return [
        ("kept out", num(sum(r.kept or 0 for r in rows))),
        ("parent re-send", num(sum(r.resent for r in rows))),
        ("parallelism", parallelism(rows)),
    ]


def delegation_rows(session):
    # One row per subagent run of a parent, most tokens first.
    headers = ["Agent", "Task", "Runs", "Requests", "Consumed", "Active", "Overhead"]
    headers += [
        "Report",
        "Compression",
        "Kept out",
        "Re-send",
        "Corrections",
        "Notes",
        "Ending",
    ]
    rows = [
        [
            row.agent,
            preview(row.task),
            numstr(row.runs),
            maybe(row.requests, numstr),
            maybe(row.consumed, num),
            maybe(row.active, duration),
            maybe(row.overhead, pct),
            num(row.tokens),
            compression(row),
            maybe(row.kept, num),
            num(row.resent),
            maybe(row.corrections, numstr),
            maybe(row.notes, numstr),
            OUTCOMES.get(row.state, "-"),
        ]
        for row in sorted(session.delegations, key=lambda r: -(r.consumed or 0))
    ]
    return headers, rows


def delegation_figures(row):
    # A child's run as its parent saw it: what it returned and how it ended.
    return [
        ("runs", numstr(row.runs)),
        ("report", num(row.tokens)),
        ("compression", compression(row)),
        ("kept out", maybe(row.kept, num)),
        ("parent re-send", num(row.resent)),
        ("overhead", maybe(row.overhead, pct)),
        ("corrections", maybe(row.corrections, numstr)),
        ("notes", maybe(row.notes, numstr)),
        ("ending", OUTCOMES.get(row.state, "-")),
    ]


def efficiency_figures(items):
    # An agent type's runs: how much each returned token stands for, and how runs went.
    rows = [s.delegation for s in items if s.delegation]
    if not rows:
        return None
    ratios = [r.consumed / r.tokens for r in rows if r.consumed and r.tokens]
    overheads = [r.overhead for r in rows if r.overhead is not None]
    kept = [r.kept for r in rows if r.kept is not None]
    ends = sum((s.outcomes for s in items), Counter())
    runs = sum(r.runs for r in rows)
    return [
        ("linked runs", numstr(runs)),
        ("compression", f"{numstr(statistics.median(ratios), 0)}x" if ratios else "-"),
        ("overhead", pct(statistics.mean(overheads)) if overheads else "-"),
        ("kept out/run", num(sum(kept) / runs) if kept else "-"),
        ("budget stops", pct(ends["budget"] / sum(ends.values())) if ends else "-"),
        ("corrections/run", numstr(sum(r.corrections or 0 for r in rows) / runs, 1)),
        ("notes/run", numstr(sum(r.notes or 0 for r in rows) / runs, 1)),
    ]


def growth_series(items):
    # The average context at each request number over the sessions that reached it, while
    # at least GROWTH_MIN_SESSIONS did, with their number.
    average, running = [], []
    for i in range(max(len(s.requests) for s in items)):
        at = [s.requests[i].prompt for s in items if len(s.requests) > i]
        if len(at) < GROWTH_MIN_SESSIONS:
            break
        running.append(len(at))
        average.append(statistics.mean(at))
    return running, average


# App state: the theme, and the sessions read at start and on reload.


@dataclass
class Store:
    theme: dict = field(default_factory=dict)
    sessions: list[Session] = field(default_factory=list)
    by_id: dict[str, Session] = field(default_factory=dict)
    # Agent -> its sessions, oldest first.
    by_agent: dict[str, list[Session]] = field(default_factory=dict)

    def load(self, sessions):
        self.sessions = sessions
        self.by_id = {s.id: s for s in sessions}
        self.by_agent = defaultdict(list)
        for session in sorted(sessions, key=lambda s: s.time):
            self.by_agent[session.agent].append(session)


store = Store()


def color(key):
    return f"#{store.theme['colors'][key]}"


def px(points):
    return points * 96 / 72


# Charts: ECharts options in the theme's colors.

# numstr() in JavaScript; axis labels in the short form of num(), and tooltips with exact
# values.
NUMSTR = """(x, d) => x.toLocaleString('tr-TR',
  {minimumFractionDigits: d, maximumFractionDigits: d, useGrouping: 'always'})"""
SHORT_NUMBER = f"""v => {{ const f = {NUMSTR};
  return v >= 1e9 ? f(v / 1e9, 1) + 'B' : v >= 1e6 ? f(v / 1e6, 1) + 'M'
    : v >= 1e4 ? f(v / 1e3, 0) + 'k' : f(v, 0); }}"""
EXACT_NUMBER = f"v => v == null ? '-' : ({NUMSTR})(v, 0)"
DECIMAL = f"v => v == null ? '-' : ({NUMSTR})(v, 1)"
# Axis ticks that are not token counts, with as many decimals as the tick has.
PLAIN_NUMBER = (
    "v => v.toLocaleString('tr-TR', {useGrouping: 'always', maximumFractionDigits: 3})"
)
DENSE_COLUMNS = 60
BAR_GAP = "28%"


def chart_theme():
    # Fonts and axes in the page's colors, without grid lines.
    pointer = {"lineStyle": {"color": color("o")}, "shadowStyle": {"color": color("o")}}
    axis = {
        "axisLine": {"lineStyle": {"color": color("o")}},
        "axisTick": {"lineStyle": {"color": color("o")}},
        "axisLabel": {"color": color("m")},
        "nameTextStyle": {"color": color("m")},
        "splitLine": {"show": False},
    }
    return {
        "backgroundColor": "transparent",
        "textStyle": {
            "fontFamily": store.theme["fonts"]["mono"],
            "fontSize": px(store.theme["fontSize"]["s"]),
            "color": color("f"),
        },
        "categoryAxis": axis,
        "valueAxis": axis,
        "legend": {"textStyle": {"color": color("f")}},
        # Hovers in overlay: the tooltip, and the line or band that marks the hovered column.
        "axisPointer": pointer,
        "tooltip": {
            "backgroundColor": color("o"),
            "borderWidth": 0,
            "axisPointer": pointer,
            "textStyle": {"color": color("f")},
        },
    }


def value_axis(name=None, show=True, tokens=True):
    # A zero-based axis; token axes label in the short form, others in full.
    return {
        "type": "value",
        "min": 0,
        "show": show,
        "name": name,
        "nameLocation": "middle",
        "nameGap": 56,
        "axisLabel": {":formatter": SHORT_NUMBER if tokens else PLAIN_NUMBER},
    }


def column_options(labels, xlabel, yaxes, series, legend=None, ticks=None):
    # Columns and lines over category labels, with the legend in the top left, in the
    # series' order or legend's; ticks, when given, label the axis in place of the labels,
    # which the tooltip still shows.
    tick_labels = {"axisLabel": {":formatter": f"(_, i) => {json.dumps(ticks)}[i]"}}
    return {
        "grid": {"left": 72, "right": 72, "top": 40, "bottom": 48},
        "tooltip": {"trigger": "axis", ":valueFormatter": EXACT_NUMBER},
        "legend": {"left": 0, "top": 0} | ({"data": legend} if legend else {}),
        "xAxis": {
            "type": "category",
            "data": labels,
            "name": xlabel,
            "nameLocation": "middle",
            "nameGap": 32,
        }
        | (tick_labels if ticks else {}),
        "yAxis": yaxes,
        "series": series,
    }


def line(name, values, key, axis, formatter=None):
    return {
        "type": "line",
        "name": name,
        "data": values,
        "yAxisIndex": axis,
        "showSymbol": False,
        "color": color(key),
    } | ({"tooltip": {":valueFormatter": formatter}} if formatter else {})


def daily_options(series):
    # Tokens per day as columns with their average on the same axis, and the averages of
    # active hours and your wait per turn on their own axes, the wait's hidden.
    return column_options(
        series["days"],
        "Day",
        [value_axis("Tokens"), value_axis("Hours", tokens=False), value_axis(show=False)],
        [
            {"type": "bar", "name": "Tokens", "data": series["tokens"], "color": color("o")},
            line("Tokens EMA", series["tokens_ema"], "m", 0),
            line("Active hours EMA", series["hours_ema"], "p", 1, DECIMAL),
            line("Wait/turn minutes EMA", series["wait_ema"], "s", 2, DECIMAL),
        ],
    )


def stacked_options(labels, columns, ylabel, xlabel, marks=(), ticks=None):
    """Columns stacked by CHART_GROUPS, in their order from the bottom: each column's height
    is its total, each color a group's tokens, and a group's colored area over all columns
    its sum.

    columns: group name -> tokens, one per label; marks: positions of dashed vertical rules.
    """
    # Above DENSE_COLUMNS, columns touch, so dense sessions read as a stepped area; a
    # hairline edge in each column's color closes the seams between them.
    dense = len(columns) > DENSE_COLUMNS
    series = [
        {
            "type": "bar",
            "stack": "total",
            "name": group,
            "data": [column.get(group, 0) for column in columns],
            "color": color(key),
            "barCategoryGap": "0%" if dense else BAR_GAP,
        }
        | ({"itemStyle": {"borderColor": color(key), "borderWidth": 0.5}} if dense else {})
        for group, key in CHART_GROUPS.items()
    ]
    if marks:
        series[0]["markLine"] = {
            "symbol": "none",
            "silent": True,
            "label": {"show": False},
            "lineStyle": {"color": color("f"), "type": "dashed", "width": 1},
            "data": [{"xAxis": mark} for mark in marks],
        }
    return column_options(
        labels, xlabel, [value_axis(ylabel)], series, list(CHART_GROUPS)[::-1], ticks
    )


def bar_options(segments, xlabel, tokens=True, legend=False):
    """One horizontal bar of segments (value, theme color key, name) from the left.

    With a legend, the segments are named below the bar and touch; without one, thin lines
    in the background color separate them.
    """
    edge = {} if legend else {"itemStyle": {"borderColor": color("b"), "borderWidth": 1}}
    # The bar ends at its total, which is not a round number to label.
    axis = value_axis(xlabel, tokens=tokens)
    axis |= {"max": sum(v for v, _, _ in segments) or 1, "nameGap": 24}
    axis["axisLabel"]["showMaxLabel"] = False
    return {
        "grid": {"left": 0, "right": 0, "top": 0, "bottom": 64 if legend else 40},
        "tooltip": {
            "trigger": "item",
            ":valueFormatter": EXACT_NUMBER if tokens else DECIMAL,
        },
        "legend": {"show": legend, "bottom": 0},
        "xAxis": axis,
        "yAxis": {"type": "category", "data": [""], "show": False},
        "series": [
            {
                "type": "bar",
                "stack": "all",
                "name": name,
                "data": [value],
                "color": color(key),
                "barWidth": "100%",
            }
            | edge
            for value, key, name in segments
        ],
    }


def growth_options(running, average):
    # The sessions that reached each request number as columns, and their average context.
    return column_options(
        [numstr(i + 1) for i in range(len(running))],
        "Request",
        [value_axis("Sessions", tokens=False), value_axis("Context tokens")],
        [
            {"type": "bar", "name": "Sessions", "data": running, "color": color("o")},
            line("Average context", average, "p", 1),
        ],
    )


# Pages


def chart(options, height, on_click=None):
    element = ui.echart(options, on_point_click=on_click, theme=chart_theme())
    element.classes("w-full").style(f"height:{height}px")


def kpis(items):
    with ui.element("div").classes("kpis"):
        for label, value in items:
            with ui.element("div"):
                ui.label(label).classes("kpi-label")
                ui.label(value).classes("kpi-value")


def table(headers, rows, wrap=None):
    # A plain table; the first column and the wrap column hold left-aligned text.
    columns = [
        {
            "name": f"c{i}",
            "label": header,
            "field": f"c{i}",
            "align": "left" if i in (0, wrap) else "right",
        }
        | ({"classes": "wrap"} if i == wrap else {})
        for i, header in enumerate(headers)
    ]
    data = [
        {"id": n} | {f"c{i}": cell for i, cell in enumerate(row)} for n, row in enumerate(rows)
    ]
    ui.table(columns=columns, rows=data).props("flat dense square").classes("w-full")


# A row of the parts table: an arrow on the rows that open, the section's color, and the
# part name indented by depth; the rows that open emit toggle with their ID.
PARTS_ROW = """
<q-tr :props="props" :class="props.row.branch ? 'branch' : ''"
      @click="() => props.row.branch && $parent.$emit('toggle', props.row.id)">
  <q-td v-for="col in props.cols" :key="col.name" :props="props">
    <span v-if="col.name === 'c0'" :style="{paddingLeft: props.row.depth * INDENT + 'px'}">
      <span v-if="props.row.branch" class="marker">{{ props.row.open ? '▾ ' : '▸ ' }}</span>
      <span v-if="props.row.color" class="square" :style="{color: props.row.color}">■</span>
      <b v-if="props.row.branch">{{ col.value }}</b>
      <template v-else>{{ col.value }}</template>
    </span>
    <template v-else>{{ col.value }}</template>
  </q-td>
</q-tr>
"""


def parts_table(headers, rows):
    """The parts table, collapsed to its sections; a section row opens its direct children
    and closes all its descendants.
    """
    opened = set()
    children = defaultdict(list)
    for row in rows:
        children[row["parent"]].append(row["id"])

    def close(node):
        opened.discard(node)
        for child in children[node]:
            close(child)

    def shown():
        visible = {None}
        data = []
        for row in rows:
            if row["parent"] in visible and (row["parent"] is None or row["parent"] in opened):
                visible.add(row["id"])
                data.append(
                    {
                        "id": row["id"],
                        "depth": row["depth"],
                        "branch": row["branch"],
                        "open": row["id"] in opened,
                        "color": row["color"] and color(row["color"]),
                    }
                    | {f"c{i}": cell for i, cell in enumerate(row["cells"])}
                )
        return data

    def toggle(event):
        node = event.args
        if node in opened:
            close(node)
        else:
            opened.add(node)
        grid.update_rows(shown())

    columns = [
        {"name": f"c{i}", "label": h, "field": f"c{i}", "align": "left" if i == 0 else "right"}
        for i, h in enumerate(headers)
    ]
    grid = ui.table(columns=columns, rows=shown()).props("flat dense square").classes("w-full")
    grid.add_slot("body", PARTS_ROW.replace("INDENT", str(store.theme["dim"]["m"])))
    grid.on("toggle", toggle)


def overview_page():
    sessions = store.sessions
    with ui.column().classes("page"):
        kpis(overview_figures(sessions))
        chart(daily_options(daily_series(sessions)), 420)
        table(*model_rows(sessions))


def session_page(session_id: str):
    session = store.by_id.get(session_id)
    with ui.column().classes("page"):
        if session is None:
            ui.label("No such session.")
            return
        ui.label(session_label(session)).classes("title")
        kpis(session_figures([session], False))
        labels, columns, marks = context_columns(session)
        chart(stacked_options(labels, columns, "Context tokens", "Request", marks), 420)
        chart(bar_options(startup_segments([session]), "Tokens"), 96)
        parts_table(*session_parts(session))
        time_section([session])
        compactions_section([session])
        if session.delegations:
            section("Subagents")
            kpis(delegations_figures(session))
            table(*delegation_rows(session), wrap=1)
        if row := session.delegation:
            section("Delegation")
            ui.link(session_label(row.parent), f"/session/{row.parent.id}").classes("title")
            ui.label(row.task.strip().split("\n")[0])
            kpis(delegation_figures(row))


def average_page(agent: str):
    items = store.by_agent.get(agent)
    with ui.column().classes("page"):
        if not items:
            ui.label("No such agent.")
            return
        ui.label(f"{agent} · {numstr(len(items))} sessions").classes("title")
        kpis(session_figures(items, True))
        # Each session's column is labeled with its day, shows its title, and opens its page.
        days, columns = history_columns(items)
        titles = [session_title(s) for s in items]
        chart(
            stacked_options(titles, columns, "Consumed tokens", "Session", ticks=days),
            420,
            on_click=lambda e: ui.navigate.to(f"/session/{items[e.data_index].id}"),
        )
        chart(bar_options(startup_segments(items), "Tokens"), 96)
        parts_table(*average_parts(items))
        time_section(items)
        compactions_section(items)
        if figures := efficiency_figures(items):
            section("Efficiency")
            kpis(figures)
        running, average = growth_series(items)
        if running:
            chart(growth_options(running, average), 420)


def section(title):
    ui.label(title).classes("section")


def time_section(items):
    # Time per category as a bar; averages show means per session.
    spent = time_spent(items)
    if any(spent.values()):
        section("Time")
        segments = [(spent[part] / 60000, key, part) for part, key in TIME_PARTS.items()]
        chart(bar_options(segments, "Minutes", tokens=False, legend=True), 120)


def compactions_section(items):
    if figures := compaction_figures(items):
        section("Compactions")
        kpis(figures)


def navigation():
    """The drawer's tree: the overview, an average per agent, every session newest first
    with the subagent runs it started, then subagent runs whose parent is not in the app.

    Node IDs are the pages' paths; group nodes cannot be selected.
    """
    newest = sorted(store.sessions, key=lambda s: s.time, reverse=True)
    children = defaultdict(list)
    for session in newest[::-1]:
        if session.parent in store.by_id:
            children[session.parent].append(session)

    def node(session):
        size = f"{numstr(len(session.requests))} requests · peak {num(session.peak.prompt)}"
        caption = size if session.child else f"{session.agent} · {size}"
        runs = [node(child) for child in children[session.id]]
        return (
            {"id": f"/session/{session.id}", "label": session_title(session)}
            | {"caption": caption}
            | ({"children": runs} if runs else {})
        )

    def group(key, label, nodes):
        return (
            [{"id": key, "label": label, "selectable": False, "children": nodes}]
            if nodes
            else []
        )

    agents = sorted(store.by_agent.items(), key=lambda kv: (kv[0] != "main", kv[0]))
    averages = [
        {"id": f"/average/{agent}", "label": agent, "caption": f"{numstr(len(items))} sessions"}
        for agent, items in agents
    ]
    unlinked = [s for s in newest if s.child and s.parent not in store.by_id]
    return [
        {"id": "/", "label": "Overview"},
        *group("averages", "Averages", averages),
        *group("sessions", "Sessions", [node(s) for s in newest if not s.child]),
        *group("unlinked", "Unlinked subagents", [node(s) for s in unlinked]),
    ]


def root():
    # The drawer with reload and the tree, and the page of the current path beside it.
    async def reload():
        button.props("loading")
        store.load(await run.io_bound(collect))
        ui.navigate.reload()

    with ui.left_drawer(value=True, fixed=True).props("width=320 bordered"):
        button = ui.button("Reload", icon="refresh", on_click=reload).props("flat dense")
        tree = ui.tree(navigation(), on_select=lambda e: e.value and ui.navigate.to(e.value))
        tree.add_slot(
            "default-header",
            """<div class="column no-wrap">
              <span>{{ props.node.label }}</span>
              <span v-if="props.node.caption" class="caption">{{ props.node.caption }}</span>
            </div>""",
        )
        tree.expand(["averages", "sessions", "unlinked"])
    ui.sub_pages(
        {
            "/": overview_page,
            "/session/{session_id}": session_page,
            "/average/{agent}": average_page,
        }
    )

    # The tree follows the shown page, also one opened from a link, and opens the parent of
    # a subagent run.
    def follow(path):
        tree.select(path)
        session = store.by_id.get(path.removeprefix("/session/"))
        if session and session.parent in store.by_id:
            tree.expand([f"/session/{session.parent}"])

    router = ui.context.client.sub_pages_router
    follow(router.current_path)
    router.on_path_changed(follow)


def style():
    # The page in the theme's colors, fonts, and sizes: 12 px between blocks, 24 px before
    # a section.
    theme = store.theme
    c, size, dim, fonts = theme["colors"], theme["fontSize"], theme["dim"], theme["fonts"]
    return f"""
:root {{ --p:#{c["p"]}; --s:#{c["s"]}; --f:#{c["f"]}; --m:#{c["m"]}; --o:#{c["o"]};
  --b:#{c["b"]}; }}
body, body.body--dark {{ background:var(--b); color:var(--f);
  font:{px(size["m"])}px "{fonts["sans"]}"; }}
.nicegui-content {{ padding:0; }}
.nicegui-sub-pages {{ width:100%; }}
.page {{ width:100%; gap:{dim["s"]}px; padding:{dim["m"]}px; }}
.title {{ color:var(--m); }}
a.title {{ text-decoration:none; }}
.section {{ width:100%; font-size:{px(size["s"])}px; color:var(--m); text-transform:uppercase;
  border-bottom:1px solid var(--o); margin-top:{dim["s"]}px; }}
.kpis {{ width:100%; display:grid; grid-template-columns:repeat(6, minmax(0, 1fr));
  row-gap:{dim["s"]}px; text-align:center; }}
.kpi-label {{ color:var(--m); font-size:{px(size["s"])}px; }}
.kpi-value {{ font:{px(size["h"])}px "{fonts["mono"]}"; }}
.q-table__card, .q-table {{ background:transparent; color:var(--f); box-shadow:none; }}
.q-table {{ font:{px(size["l"])}px "{fonts["mono"]}"; }}
.q-table th {{ font:{px(size["l"])}px "{fonts["sans"]}"; color:var(--m); }}
.q-table th, .q-table td {{ padding:{dim["t"]}px {dim["s"]}px; height:auto;
  font-size:inherit; white-space:nowrap; border-color:var(--o); }}
.q-table td.wrap {{ white-space:normal; color:var(--m); font:{px(size["m"])}px "{fonts["sans"]}"; }}
.q-table tbody tr.branch {{ cursor:pointer; }}
.q-table tbody td {{ border-bottom-width:0; }}
.square {{ margin-right:{dim["t"] * 2}px; }}
.marker {{ color:var(--m); }}
.q-drawer {{ background:var(--b); }}
.q-drawer--bordered {{ border-color:var(--o) !important; }}
.q-drawer .q-tree {{ color:var(--f); padding:{dim["s"]}px; }}
/* Hovers and the selected page in overlay, in place of Quasar's translucent layers, which
   sit above the text. */
.q-drawer .q-focus-helper, .q-table tbody td::before {{ display:none; }}
.q-tree__node-header:hover, .q-drawer .q-btn:hover, .q-tree__node--selected,
  .q-table tbody tr:hover > td {{ background:var(--o); }}
.q-tree__node--selected .q-tree__node-header-content {{ color:var(--f); }}
.q-tree__node::after, .q-tree__node-header::before, .q-tree__node-body::after {{
  color:var(--o); }}
.caption {{ color:var(--m); font-size:{px(size["s"])}px; }}
"""


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def main():
    theme, browser = Path(sys.argv[1]), sys.argv[2]
    store.theme = json.loads(theme.read_text())
    store.load(collect())
    if not store.sessions:
        raise SystemExit("No sessions found.")
    port = free_port()
    url = f"http://127.0.0.1:{port}/"
    # The browser runs in its own session, so Ctrl+C stops only the app.
    app.on_startup(
        lambda: subprocess.Popen(
            [browser, url],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    )
    c = store.theme["colors"]
    app.colors(primary=f"#{c['p']}", secondary=f"#{c['s']}", dark=f"#{c['b']}")
    ui.add_css(style(), shared=True)
    ui.run(
        root,
        host="127.0.0.1",
        port=port,
        title="Pi stats",
        dark=store.theme["dark"],
        show=False,
        reload=False,
    )


if __name__ == "__main__":
    main()
