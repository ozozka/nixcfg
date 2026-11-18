"""Agent context statistics: what each model request of Pi and Claude Code contained, rebuilt
from their session files and shown as a local NiceGUI app.

Usage: stats.py THEME BROWSER

Parts are measured in UTF-8 bytes; their tokens are the part's share of the request's real
prompt tokens (input + cache read + cache write) from the response usage. Output tokens are
split over the response's own text, thinking, and tool calls the same way; reported reasoning
tokens go to thinking. A session's size is the tokens that entered it, each counted once,
from the recorded prompt and output tokens (size_parts); caching and compactions do not
change it.

Pi: each assistant message is one model request. Its context is the path from the session root
to that message: system messages patch the prompt sections and tool declarations, the latest
compaction replaces older entries with its summary and prompt checkpoint, and context edits
replace or drop entries.

Claude Code: each response, written as one entry per content block, is one model request. Its
context is the system prompt and tools of its recorded request shape, and the transcript path
to it, which a compaction boundary starts; attachments carry the instructions, skills, and
reminders sent. The server's context edits are not recorded, so the context is approximate.

Pi subagent sessions live in subagent-sessions/; the parent's subagent results and messages
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

PI_DIR = Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent"))
# The coding agents whose sessions are read, by harness, in display order.
HARNESSES = {"pi": "Pi", "claude": "Claude Code"}
# Each agent's theme color in the usage table and donut.
HARNESS_COLORS = {"pi": "p", "claude": "s"}
CLAUDE_DIR = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude"))
# Claude Code request sources counted: the main thread and subagents; print mode (sdk) runs
# are left out.
CLAUDE_SOURCES = ("repl_main_thread", "agent:")
# Claude's token prices relative to an input token, to split recorded costs over requests.
CLAUDE_WEIGHTS = {"input": 1, "cache5m": 1.25, "cache1h": 2, "read": 0.1, "output": 5}
# Attachments Claude Code sends as context at startup, counted as system prompt parts; the
# instructions, hook context, skills, and deferred tools have parts of their own, and other
# attachments are reminders in the conversation.
CLAUDE_SYSTEM_ATTACHMENTS = {
    "environment",
    "model",
    "date",
    "session_context",
    "mcp_instructions_delta",
    "agent_listing_delta",
    "auto_mode",
    "sandbox_instructions",
}
# How Claude Code marks instruction files and the docs hook's files, and lists each skill.
CLAUDE_INSTRUCTIONS = r"^Contents of (\S+) \(.*\):$"
CLAUDE_HOOK_SOURCE = r"^# Source: (\S+)$"
CLAUDE_SKILL_LINE = "\n- "
# Bytes per token assumed for thinking, whose text Claude Code does not keep: about Pi's
# median over its sessions.
CLAUDE_THINKING_BYTES = 4
# Claude Code's tools that ask you a question and that start a subagent.
CLAUDE_QUESTION_TOOL = "AskUserQuestion"
CLAUDE_AGENT_TOOL = "Agent"
# Claude Code's subagent run states, as the run endings of OUTCOMES; others are unknown.
CLAUDE_STATES = {"completed": "idle"}
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
# Context parts that never enter a session between requests: the previous response's own
# parts (with every call: part), and summaries that restate counted content.
NOT_INCOMING = {
    "conversation:thinking",
    "conversation:assistant",
    "conversation:compaction summary",
}
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


# Data


def size(text):
    # Sizes are UTF-8 bytes.
    return len(text.encode())


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


def split_output(parts, output, reasoning):
    # A response's output tokens split over its own (part, bytes); reasoning tokens go to
    # thinking.
    reasoning = min(reasoning or 0, output)
    totals = defaultdict(int)
    for name, length in parts:
        totals[name] += length
    length = sum(totals.values())
    if not length:
        return {"conversation:thinking": output} if output else {}
    shares = {name: (output - reasoning) * value / length for name, value in totals.items()}
    if reasoning:
        shares["conversation:thinking"] = shares.get("conversation:thinking", 0) + reasoning
    return shares


def size_parts(requests):
    """The session's size by part: the tokens that entered it, each counted once.

    The size is the first request's prompt, then each later request's incoming tokens, its
    prompt's growth beyond the previous prompt and output (none after a compaction shrinks
    it), then every response's output parts. Incoming tokens are split over the parts that
    grew, by their bytes, leaving out output parts and compaction summaries, which restate
    what was counted; tokens without grown parts are unmeasured. Each request's share is set
    as its added tokens. Compaction runs are not part of the size.
    """
    size = defaultdict(float)
    previous = None
    for request in requests:
        if previous is None:
            incoming = dict(request.parts)
        else:
            tokens = max(0, request.prompt - previous.prompt - previous.output)
            grown = {
                name: length - previous.sizes.get(name, 0)
                for name, length in request.sizes.items()
                if length > previous.sizes.get(name, 0)
                and name not in NOT_INCOMING
                and not name.startswith("call:")
            }
            length = sum(grown.values())
            incoming = (
                {name: tokens * value / length for name, value in grown.items()}
                if length
                else {"conversation:unmeasured": tokens}
            )
        for parts in (incoming, request.out):
            for name, tokens in parts.items():
                size[name] += tokens
        request.added = sum(incoming.values()) + sum(request.out.values())
        previous = request
    return dict(size)


def occurrences(entry_parts, size, compactions, bytes_per_token):
    """How many times each part occurred, and its tokens with each occurrence counted once.

    entry_parts holds each entry's (part, bytes): every message block, custom message, and
    summary counts once however often later requests resend it; each compaction run counts
    once; startup parts count 1. Tokens are bytes at the session's own bytes per token.
    """
    counts, once = Counter(), defaultdict(float)
    for parts in entry_parts:
        for name, length in parts:
            counts[name] += 1
            once[name] += length / bytes_per_token
    counts["conversation:compaction runs"] = compactions
    for name in size:
        if section_of(name)[0] == "startup":
            counts[name] = 1
    return +counts, once


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
    # The agent's time for the whole response, from sending the request; None when unknown.
    duration: float | None
    # Skills listed in the system prompt.
    skills: int
    # Context bytes in all and per part; context tokens per part; output tokens per part.
    bytes: int
    sizes: dict[str, int]
    parts: dict[str, float]
    out: dict[str, float]
    # The request's share of its session's size, set by size_parts.
    added: float = 0.0


@dataclass
class Compaction:
    """One compaction: the context before it (the agent's count), the context of the first
    request after it and the summary's tokens in that request (None when none followed), the
    tokens of its own run (None when not recorded), its time (None when unknown), and its
    run's cost (0 when not recorded).
    """

    before: int
    after: int | None
    summary: float | None
    run: int | None
    time: float | None
    cost: float = 0.0


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
    def size(self):
        return self.session.total_size if self.session else None

    @property
    def active(self):
        return self.session.active if self.session else None

    @property
    def overhead(self):
        # The fixed price of an agent: its startup's share of its size.
        if not (self.session and self.size):
            return None
        return sum(self.session.startup.values()) / self.size

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
    # The coding agent that wrote the session: pi or claude.
    harness: str
    # The agent type: main for a session you started, or the subagent's type.
    agent: str
    cwd: str
    child: bool
    requests: list[Request]
    # Navigation and average-chart ordering only; time remains the first request.
    last_prompt_time: str
    # Part -> tokens that entered the session, each counted once (size_parts).
    size: dict[str, float]
    compactions: list[Compaction]
    # The index of the first request after each compaction.
    marks: list[int]
    # Milliseconds per TIME_PARTS category, and each counted wait as (prompt time, wait).
    spent: dict[str, float]
    waits: list[tuple[float, float]]
    # Wall-clock span, for the parallelism of a parent's subagent runs.
    start: float
    end: float
    # None when the agent does not record them.
    notes: int | None
    parent_messages: int | None
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
        return sum(r.cost for r in self.requests) + sum(c.cost for c in self.compactions)

    @property
    def input(self):
        # Every request's prompt tokens, cached or not: what a provider bills as input.
        return sum(r.prompt for r in self.requests)

    @property
    def total_size(self):
        return sum(self.size.values())

    @property
    def family_size(self):
        # The session's size with its subagent runs' sizes.
        return self.total_size + sum(d.size or 0 for d in self.delegations)

    @property
    def active(self):
        return sum(self.spent.values())

    @property
    def startup(self):
        # The first request's parts before any conversation, in tokens.
        parts = self.requests[0].parts
        return {n: v for n, v in parts.items() if n.split(":")[0] in STARTUP_GROUPS}


def session_order(session):
    # Compare instants, with stable tie-breakers independent of file discovery order.
    return (
        milliseconds(session.last_prompt_time),
        milliseconds(session.time),
        session.id,
    )


# Pi sessions


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
    usage = message["usage"]
    return split_output(
        message_parts({"type": "message", "message": message}),
        usage.get("output", 0),
        usage.get("reasoning", 0),
    )


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
    # Its time runs from the entry before it, unknown above COMPACTION_MAX_MS.
    after = next((r for r in requests if r.time > entry["timestamp"]), None)
    gap = milliseconds(entry["timestamp"]) - milliseconds(previous["timestamp"])
    return Compaction(
        before=entry.get("tokensBefore", 0),
        after=after.prompt if after else None,
        summary=after.parts.get("conversation:compaction summary") if after else None,
        run=run_tokens(entry),
        time=gap if gap <= COMPACTION_MAX_MS else None,
        cost=((entry.get("usage") or {}).get("cost") or {}).get("total", 0),
    )


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
    agents, parents, tasks, outcomes = links
    session_id = header.get("id")
    size = size_parts(requests)
    compactions = [e for e in entries if e["type"] == "compaction"]
    bytes_per_token = statistics.median(r.bytes / r.prompt for r in requests)
    counts, once = occurrences(
        map(message_parts, entries), size, len(compactions), bytes_per_token
    )
    messages = [e.get("message") or {} for e in entries if e["type"] == "message"]
    spent, waits = timing(entries)
    return Session(
        id=session_id,
        harness="pi",
        agent=agents.get(session_id, "subagent") if child else "main",
        cwd=header.get("cwd", ""),
        child=child,
        requests=requests,
        last_prompt_time=max(
            (
                e["timestamp"]
                for e in entries
                if e["type"] == "message" and e["message"].get("role") == "user"
            ),
            key=milliseconds,
            default=requests[0].time,
        ),
        size=size,
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


def pi_sessions():
    """Every Pi session with requests."""
    main_files = sorted(PI_DIR.glob("sessions/*/*.jsonl"))
    child_files = sorted(PI_DIR.glob("subagent-sessions/*.jsonl"))
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
    return sessions


# Claude Code sessions


def read_claude(path):
    entries = []
    for line in path.read_text().splitlines():
        # A line cut off by an interrupted write is skipped.
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return entries


def claude_weight(tokens):
    # Price-weighted tokens of one model's usage, in units of an input token.
    return sum(tokens.get(key, 0) * weight for key, weight in CLAUDE_WEIGHTS.items())


def claude_rates(files):
    """Dollars per price-weighted token for each model, from every session's latest cost
    totals: Claude Code records cost per session and model, not per request.
    """
    cost, weight = defaultdict(float), defaultdict(float)
    for entries in files:
        state = next((e for e in reversed(entries) if e.get("type") == "cost-state"), None)
        for model, usage in ((state or {}).get("modelUsage") or {}).items():
            cost[model] += usage.get("costUSD", 0)
            weight[model] += claude_weight(
                {
                    "input": usage.get("inputTokens", 0),
                    "cache5m": usage.get("cacheCreationEphemeral5mInputTokens", 0),
                    "cache1h": usage.get("cacheCreationEphemeral1hInputTokens", 0),
                    "read": usage.get("cacheReadInputTokens", 0),
                    "output": usage.get("outputTokens", 0),
                }
            )
    return {model: cost[model] / weight[model] for model in cost if weight[model]}


def claude_request_cost(usage, rate):
    creation = usage.get("cache_creation") or {}
    return rate * claude_weight(
        {
            "input": usage.get("input_tokens", 0),
            # Older usage has no split; its cache writes count at the 5 minute price.
            "cache5m": creation.get(
                "ephemeral_5m_input_tokens", usage.get("cache_creation_input_tokens", 0)
            ),
            "cache1h": creation.get("ephemeral_1h_input_tokens", 0),
            "read": usage.get("cache_read_input_tokens", 0),
            "output": usage.get("output_tokens", 0),
        }
    )


def split_files(text, pattern, wrapper, cwd):
    # Context files marked by pattern's path group, each up to the next mark, as context
    # parts; the text around them is the wrapper part.
    marks = list(re.finditer(pattern, text, re.MULTILINE))
    parts = []
    for mark, following in pairwise([*marks, None]):
        body = text[mark.end() : following.start() if following else len(text)]
        parts.append((f"context:{context_file_name(mark[1], cwd)}", size(body)))
    return [*parts, (wrapper, size(text) - sum(length for _, length in parts))]


@cache
def claude_attachment_parts(kind, text, cwd):
    # (part, bytes) of an attachment Claude Code sent as context.
    if kind == "instructions":
        return split_files(text, CLAUDE_INSTRUCTIONS, "system:instructions", cwd)
    if kind == "hook_additional_context":
        return split_files(text, CLAUDE_HOOK_SOURCE, "system:hook context", cwd)
    if kind == "skill_listing":
        return [("system:skills", size(text))]
    if kind == "deferred_tools_delta":
        return [("tool:deferred tools", size(text))]
    if kind in CLAUDE_SYSTEM_ATTACHMENTS:
        return [(f"system:{kind.replace('_', ' ')}", size(text))]
    return [(f"conversation:reminder {kind.replace('_', ' ')}", size(text))]


def claude_rendered(entry):
    # The text an attachment sent to the model; empty when it sent none.
    return "".join(
        text_of(item.get("content"))
        for key in ("rendered", "renderedInHumanTurn")
        if isinstance(entry.get(key), list)
        for item in entry[key]
    )


def claude_parts(entry, lookups):
    # (part, bytes) for one transcript entry, with the lookups of claude_lookups.
    tools, thinking = lookups
    kind = entry.get("type")
    if kind == "attachment":
        text = claude_rendered(entry)
        if not text:
            return []
        kind = entry["attachment"].get("type")
        return list(claude_attachment_parts(kind, text, entry.get("cwd")))
    if kind not in ("user", "assistant"):
        return []
    content = entry["message"].get("content")
    if kind == "user" and entry.get("isCompactSummary"):
        return [("conversation:compaction summary", text_size(content))]
    if isinstance(content, str):
        return [(f"conversation:{kind}", size(content))]
    parts = []
    for block in content or []:
        block_type = block.get("type")
        if block_type == "text":
            parts.append((f"conversation:{kind}", size(block["text"])))
        elif block_type == "image":
            parts.append(("conversation:user", IMAGE_BYTES))
        elif block_type == "thinking":
            length = size(block.get("thinking", ""))
            parts.append(
                ("conversation:thinking", length or thinking.get(entry.get("uuid"), 0))
            )
        elif block_type == "tool_use":
            parts.append((f"call:{block['name']}", size(json.dumps(block.get("input")))))
        elif block_type == "tool_result":
            name = tools.get(block.get("tool_use_id"), "unknown")
            parts.append((f"result:{name}", text_size(block.get("content") or "")))
    return parts


@cache
def claude_shape_parts(shape_json):
    """The system prompt split into its top-level sections, and each tool definition.

    Text before a block's first heading belongs to the prompt part.
    """
    shape = json.loads(shape_json)
    parts = defaultdict(int)
    for block in shape.get("system") or []:
        text = block.get("text", "")
        sections = re.split(r"^# (.+)$", text, flags=re.MULTILINE)
        parts["system:prompt"] += size(sections[0])
        for heading, body in zip(sections[1::2], sections[2::2], strict=True):
            parts[f"system:{heading.strip()}"] += size(f"# {heading}{body}")
    for tool in shape.get("tools") or []:
        parts[f"tool:{tool.get('name', '?')}"] += size(json.dumps(tool))
    return list(parts.items())


def claude_lookups(entries):
    """Tool use ID -> tool name, for naming tool results, and entry UUID -> the estimated
    bytes of its thinking block.

    Claude Code keeps only the signature of thinking, which stays in the context; its size is
    the response's thinking tokens at CLAUDE_THINKING_BYTES, split over its thinking blocks.
    """
    tools, blocks = {}, defaultdict(list)
    for entry in entries:
        if entry.get("type") != "assistant":
            continue
        for block in entry["message"].get("content") or []:
            if block.get("type") == "tool_use":
                tools[block["id"]] = block["name"]
            elif block.get("type") == "thinking":
                blocks[entry["message"]["id"]].append(entry)
    thinking = {}
    for response in blocks.values():
        details = response[-1]["message"].get("usage", {}).get("output_tokens_details") or {}
        share = (details.get("thinking_tokens") or 0) * CLAUDE_THINKING_BYTES / len(response)
        for entry in response:
            thinking[entry["uuid"]] = share
    return tools, thinking


def claude_requests(entries, rates, uses):
    """The session's model requests, each a response deduplicated by its message ID; uses
    counts for each entry UUID the requests whose context included it.

    A request's context is the transcript path from the entry before its response to the
    root, which a compaction boundary ends, plus the system prompt and tool definitions of
    its recorded request shape, or of the latest shape before it when it has none.
    """
    by_uuid = {e["uuid"]: e for e in entries if "uuid" in e}
    lookups = claude_lookups(entries)
    sent = {e["id"]: e for e in entries if e.get("type") == "api-request"}
    shapes = {
        e["shapeHash"]: json.dumps(e["shape"])
        for e in entries
        if e.get("type") == "api-request-shape"
    }
    # Each response's block entries, in the order the responses began.
    responses = defaultdict(list)
    for entry in entries:
        if entry.get("type") == "assistant":
            responses[entry["message"]["id"]].append(entry)
    measured = {}
    shape = None
    index = count()
    for blocks in responses.values():
        first, last = blocks[0], blocks[-1]
        message = last["message"]
        usage = message.get("usage") or {}
        prompt = (
            usage.get("input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0)
            + usage.get("cache_creation_input_tokens", 0)
        )
        request = sent.get(first.get("requestRef"))
        if request:
            if not request.get("querySource", "").startswith(CLAUDE_SOURCES):
                continue
            shape = shapes.get(request.get("shapeHash"), shape)
        if not prompt:
            continue
        path = []
        parent = by_uuid.get(first.get("parentUuid"))
        while parent:
            path.append(parent)
            parent = by_uuid.get(parent.get("parentUuid"))
        path.reverse()
        uses.update(item["uuid"] for item in path)
        conversation = []
        for item in path:
            if item["uuid"] not in measured:
                measured[item["uuid"]] = claude_parts(item, lookups)
            conversation += measured[item["uuid"]]
        parts = defaultdict(int)
        for name, length in (claude_shape_parts(shape) if shape else []) + conversation:
            parts[name] += length
        skills = sum(
            text_of(item.get("content")).count(CLAUDE_SKILL_LINE)
            for e in path
            if e.get("type") == "attachment" and e["attachment"].get("type") == "skill_listing"
            for item in e.get("rendered") or []
        )
        # Thinking's output is its reported tokens; the rest is split over the other blocks.
        response = [
            part
            for e in blocks
            for part in claude_parts(e, lookups)
            if part[0] != "conversation:thinking"
        ]
        total = sum(parts.values()) or 1
        yield Request(
            index=next(index),
            time=last["timestamp"],
            model=message.get("model"),
            prompt=prompt,
            output=usage.get("output_tokens", 0),
            cache=usage.get("cache_read_input_tokens", 0),
            cost=claude_request_cost(usage, rates.get(message.get("model"), 0)),
            duration=(
                milliseconds(last["timestamp"]) - milliseconds(request["timestamp"])
                if request
                else None
            ),
            skills=skills,
            bytes=total,
            sizes=dict(parts),
            parts={name: value / total * prompt for name, value in parts.items()},
            out=split_output(
                response,
                usage.get("output_tokens", 0),
                (usage.get("output_tokens_details") or {}).get("thinking_tokens", 0),
            ),
        )


def claude_prompt(entry):
    # A prompt you sent, rather than a tool result, reminder, or system message.
    return entry.get("type") == "user" and (entry.get("origin") or {}).get("kind") == "human"


def claude_timing(entries, requests):
    """Milliseconds per TIME_PARTS category, and each counted wait as (prompt time, wait).

    Model time is each request's duration. A response's tool time is its longest tool call,
    from the call to its result, since the calls of one response run in parallel; it counts as
    subagent waits when one of them starts a subagent, and the question tool's time is yours.
    Permission prompts are not recorded, so their time counts as tool time. Compaction time is
    recorded with each compaction. Your time is the wait from the end of a finished run to your
    next prompt; gaps longer than BREAK_MS are breaks.
    """
    spent, waits = defaultdict(float), []
    spent["model"] = sum(r.duration or 0 for r in requests)
    # Tool use ID -> (tool name, call time, response ID); response ID -> its longest call,
    # and whether it waited for a subagent.
    calls, turns = {}, defaultdict(lambda: [0.0, False])
    ended = None
    for entry in entries:
        kind = entry.get("type")
        if kind == "system" and entry.get("subtype") == "compact_boundary":
            spent["compaction"] += (entry.get("compactMetadata") or {}).get("durationMs") or 0
        if kind not in ("user", "assistant"):
            continue
        stamp = milliseconds(entry["timestamp"])
        message = entry["message"]
        if kind == "assistant":
            for block in message.get("content") or []:
                if block.get("type") == "tool_use":
                    calls[block["id"]] = (block["name"], stamp, message["id"])
            reason = message.get("stop_reason")
            if reason:
                ended = stamp if reason != "tool_use" else None
            continue
        if claude_prompt(entry):
            if ended is not None and stamp - ended <= BREAK_MS:
                spent["you"] += stamp - ended
                waits.append((stamp, stamp - ended))
            ended = None
        content = message.get("content")
        for block in content if isinstance(content, list) else []:
            call = (
                calls.get(block.get("tool_use_id"))
                if block.get("type") == "tool_result"
                else None
            )
            if not call:
                continue
            name, start, response = call
            if name == CLAUDE_QUESTION_TOOL:
                spent["you"] += stamp - start
            else:
                turn = turns[response]
                turn[0] = max(turn[0], stamp - start)
                turn[1] |= name == CLAUDE_AGENT_TOOL
    for longest, waited in turns.values():
        spent["subagent waits" if waited else "tools"] += longest
    return dict(spent), waits


def claude_reports(entries, runs, bytes_per_token, uses, lookups):
    """The reports subagents returned to this parent: one per Agent call.

    runs: (child session ID, agent ID, meta) for each subagent the session started. A report
    is the call's tool result and the messages that deliver the agent's hand-back or its task
    notification (attachments, or user messages for background runs); its tokens are their
    bytes at the parent's bytes per token, and its re-sent tokens count every later request
    that carried them.
    """
    reports = []
    for child, agent_id, meta in runs:
        tokens, resent, state = 0.0, 0.0, None
        marks = (f'<agent-message from="{agent_id}"', f"<task-id>{agent_id}</task-id>")
        for entry in entries:
            kind = entry.get("type")
            content = (entry.get("message") or {}).get("content")
            result = kind == "user" and any(
                block.get("tool_use_id") == meta.get("toolUseId")
                for block in (content if isinstance(content, list) else [])
            )
            if result:
                state = CLAUDE_STATES.get((entry.get("toolUseResult") or {}).get("status"))
            text = claude_rendered(entry) if kind == "attachment" else ""
            if kind == "user" and not result:
                text = text_of(content)
            if result or any(mark in text for mark in marks):
                length = sum(
                    n
                    for name, n in claude_parts(entry, lookups)
                    if not result or name.startswith("result:")
                )
                tokens += length / bytes_per_token
                resent += length / bytes_per_token * uses[entry["uuid"]]
        if state is None and meta.get("finished"):
            state = "idle"
        reports.append(
            RunReport(
                child=child,
                agent=meta.get("agentType", "subagent"),
                task=meta.get("description", ""),
                state=state,
                tokens=tokens,
                resent=resent,
            )
        )
    return reports


def claude_session(path, entries, requests, uses, run, runs):
    """A session; run, for a subagent, is its (parent session ID, meta), and runs are the
    subagents the session started, for claude_reports.
    """
    size = size_parts(requests)
    boundaries = [
        e
        for e in entries
        if e.get("type") == "system" and e.get("subtype") == "compact_boundary"
    ]
    compactions = []
    for boundary in boundaries:
        meta = boundary.get("compactMetadata") or {}
        after = next((r for r in requests if r.time > boundary["timestamp"]), None)
        compactions.append(
            Compaction(
                before=meta.get("preTokens", 0),
                after=after.prompt if after else None,
                summary=after.parts.get("conversation:compaction summary") if after else None,
                run=None,
                time=meta.get("durationMs"),
            )
        )
    bytes_per_token = statistics.median(r.bytes / r.prompt for r in requests)
    lookups = claude_lookups(entries)
    counts, once = occurrences(
        (claude_parts(e, lookups) for e in entries), size, 0, bytes_per_token
    )
    parent, meta = run or (None, {})
    stamps = [milliseconds(e["timestamp"]) for e in entries if "timestamp" in e]
    # A name you gave wins over Claude Code's generated title.
    given = [e["agentName"] for e in entries if e.get("type") == "agent-name"]
    titles = [e["aiTitle"] for e in entries if e.get("type") == "ai-title"]
    spent, waits = claude_timing(entries, requests)
    return Session(
        id=path.stem,
        harness="claude",
        agent=meta.get("agentType", "subagent") if run else "main",
        cwd=next((e["cwd"] for e in entries if e.get("cwd")), ""),
        child=run is not None,
        requests=requests,
        last_prompt_time=max(
            (e["timestamp"] for e in entries if claude_prompt(e)),
            key=milliseconds,
            default=requests[0].time,
        ),
        size=size,
        compactions=compactions,
        marks=[
            next((r.index for r in requests if r.time > b["timestamp"]), len(requests) - 1)
            for b in boundaries
        ],
        spent=spent,
        waits=waits,
        start=min(stamps),
        end=max(stamps),
        # Claude Code's subagents have no notes, and messages to them are not marked.
        notes=None,
        parent_messages=None,
        counts=counts,
        material=sum(t for n, t in once.items() if n.startswith("result:")),
        bytes_per_token=bytes_per_token,
        reports=claude_reports(entries, runs, bytes_per_token, uses, lookups),
        parent=parent,
        task=meta.get("description", ""),
        outcomes=Counter(),
        name=(given or titles or [None])[-1],
    )


def claude_sessions():
    """Every Claude Code session with requests.

    A subagent's transcript is <session>/subagents/agent-<ID>.jsonl beside its meta file, whose
    toolUseId is the Agent call that started it, in the main transcript or another subagent's.
    """
    paths = sorted(CLAUDE_DIR.glob("projects/*/*.jsonl"))
    paths += sorted(CLAUDE_DIR.glob("projects/*/*/subagents/agent-*.jsonl"))
    files = [read_claude(path) for path in paths]
    rates = claude_rates(files)
    # Agent call ID -> the session that made it.
    callers = {
        tool_id: path.stem
        for path, entries in zip(paths, files, strict=True)
        for tool_id, name in claude_lookups(entries)[0].items()
        if name == CLAUDE_AGENT_TOOL
    }
    # Child session ID -> (parent session ID, meta); parent session ID -> its runs.
    links, runs = {}, defaultdict(list)
    for path in paths:
        meta_path = path.with_suffix(".meta.json")
        if path.parent.name != "subagents" or not meta_path.exists():
            continue
        meta = json.loads(meta_path.read_text())
        parent = callers.get(meta.get("toolUseId"))
        links[path.stem] = (parent, meta)
        if parent:
            runs[parent].append((path.stem, path.stem.removeprefix("agent-"), meta))
    sessions = []
    for path, entries in zip(paths, files, strict=True):
        uses = Counter()
        requests = list(claude_requests(entries, rates, uses))
        if requests:
            child = path.parent.name == "subagents"
            run = links.get(path.stem, (None, {})) if child else None
            sessions.append(claude_session(path, entries, requests, uses, run, runs[path.stem]))
    # How each run ended, as its parent recorded it.
    by_id = {s.id: s for s in sessions}
    for session in sessions:
        for report in session.reports:
            if report.child in by_id and report.state in OUTCOMES:
                by_id[report.child].outcomes[report.state] += 1
    return sessions


# Sessions


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
    """Every session of every agent, children linked to their parents."""
    sessions = pi_sessions() + claude_sessions()
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


def agent_key(session):
    # An agent type of one harness, such as pi:main, for labels and the agent types table.
    return f"{session.harness}:{session.agent}"


def agent_label(key):
    harness, agent = key.split(":", 1)
    return f"{HARNESSES[harness]} · {agent}"


def session_label(session):
    return (
        f"{session.time[:16].replace('T', ' ')} · {Path(session.cwd).name}"
        f" · {agent_label(agent_key(session))} · {num(session.total_size)}"
        f" · {money(session.cost)}"
    )


def wait_per_turn(items):
    # Your average wait over every counted turn of the sessions.
    waits = [w for s in items for _, w in s.waits]
    return duration(statistics.mean(waits)) if waits else "-"


def overview_figures(sessions):
    # Your usage of the agents over every session: volume, cost, time, and rhythm.
    requests = [r for s in sessions for r in s.requests]
    return [
        ("sessions", numstr(sum(1 for s in sessions if s.agent == "main"))),
        ("size", num(sum(s.total_size for s in sessions))),
        ("input", num(sum(s.input for s in sessions))),
        ("cache hit", cache_hit(sessions)),
        ("output", num(sum(r.output for r in requests))),
        ("cost", money(sum(s.cost for s in sessions))),
        ("active time", duration(sum(s.active for s in sessions))),
        ("wait/turn", wait_per_turn(sessions)),
    ]


def speed(requests):
    # Output tokens over response time, for the responses with a duration; it includes the
    # time before the first token, so it compares models rather than measuring raw
    # generation speed.
    timed = [r for r in requests if r.duration]
    seconds = sum(r.duration for r in timed) / 1000
    return numstr(sum(r.output for r in timed) / seconds, 1) if seconds else "-"


def usage_rows(sessions):
    """Usage per agent, in HARNESSES order, each opening to its models (most requests
    first) and, when the agent records them, its compaction runs' cost, so an agent's
    children add up to it.

    A model's sessions are the sessions you started that used it, directly or through their
    subagent runs. Rows are colored as in the donut. Returns the headers and the rows of
    nested_table.
    """
    ids = count()
    rows = []
    size_total = sum(s.total_size for s in sessions) or 1
    colors = model_colors(usage_sizes(sessions))

    def add(parent, depth, branch, key, cells):
        node = next(ids)
        rows.append(
            {"id": node, "parent": parent, "depth": depth, "branch": branch, "color": key}
            | {"cells": cells}
        )
        return node

    for harness, label in HARNESSES.items():
        items = [s for s in sessions if s.harness == harness]
        if not items:
            continue
        requests = [r for s in items for r in s.requests]
        agent = add(
            None,
            0,
            True,
            HARNESS_COLORS[harness],
            [
                label,
                numstr(sum(1 for s in items if not s.child)),
                numstr(len(requests)),
                num(sum(s.total_size for s in items)),
                pct(sum(s.total_size for s in items) / size_total),
                num(sum(s.input for s in items)),
                cache_hit(items),
                num(sum(r.output for r in requests)),
                money(sum(s.cost for s in items)),
                speed(requests),
            ],
        )
        models, used = defaultdict(list), defaultdict(set)
        for session in items:
            owner = session.parent if session.child and session.parent else session.id
            for request in session.requests:
                models[request.model].append(request)
                used[request.model].add(owner)
        for model, group in sorted(models.items(), key=lambda m: -len(m[1])):
            add(
                agent,
                1,
                False,
                colors[harness, model or "unknown"],
                [
                    model or "unknown",
                    numstr(len(used[model])),
                    numstr(len(group)),
                    num(sum(r.added for r in group)),
                    pct(sum(r.added for r in group) / size_total),
                    num(sum(r.prompt for r in group)),
                    cache_share(group),
                    num(sum(r.output for r in group)),
                    money(sum(r.cost for r in group)),
                    speed(group),
                ],
            )
        if compacted := sum(c.cost for s in items for c in s.compactions):
            cells = ["compaction runs", *["-"] * 7, money(compacted), "-"]
            add(agent, 1, False, None, cells)
    headers = ["Agent", "Sessions", "Requests", "Size", "Size %", "Input", "Cache", "Output"]
    headers += ["Cost", "Tok/s"]
    return headers, rows


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
    """Calendar days with size per day and moving averages of size, active hours, and your
    wait per turn in minutes.

    Each request's share of its session's size counts on its day. Days without sessions count
    as zero tokens and hours; waits carry over them. A session's active time counts on the
    day it started; a wait on the day of its prompt.
    """
    tokens, active, waits = defaultdict(float), defaultdict(float), defaultdict(list)
    for session in sessions:
        for request in session.requests:
            tokens[request.time[:10]] += request.added
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


def cache_share(requests):
    # The share of the requests' input read from the provider's cache.
    prompt = sum(r.prompt for r in requests)
    return pct(sum(r.cache for r in requests) / prompt) if prompt else "-"


def cache_hit(items):
    # The share of the sessions' input read from the provider's cache, over all requests.
    return cache_share([r for s in items for r in s.requests])


def subagent_share(items):
    # The subagent runs' share of the size of the sessions and their runs together.
    children = sum(d.size or 0 for s in items for d in s.delegations)
    own = sum(s.total_size for s in items)
    return pct(children / (own + children)) if children else "-"


def session_figures(items, average):
    # The same figures for one session or, with average, the means over several.
    def mean(values):
        return statistics.mean(values) if average else values[0]

    return [
        ("size", num(mean([s.total_size for s in items]))),
        ("with subagents", num(mean([s.family_size for s in items]))),
        ("input", num(mean([s.input for s in items]))),
        ("cache hit", cache_hit(items)),
        ("output", num(mean([sum(r.output for r in s.requests) for s in items]))),
        ("cost", money(mean([s.cost for s in items]))),
        ("active time", duration(mean([s.active for s in items]))),
        ("wait/turn", wait_per_turn(items)),
        ("peak context", num(mean([s.peak.prompt for s in items]))),
        ("requests", numstr(mean([len(s.requests) for s in items]), 0)),
        *startup_figures(items),
        ("subagents", trimmed(mean([len(s.delegations) for s in items]))),
        ("subagent share", subagent_share(items)),
    ]


def context_columns(session):
    # The context of each request stacked by chart group, with the compactions.
    labels = [numstr(r.index + 1) for r in session.requests]
    return labels, [grouped(r.parts) for r in session.requests], session.marks


def history_columns(items):
    # Columns follow the supplied session order; day labels remain the stable start day.
    return [s.time[:10] for s in items], [grouped(s.size) for s in items]


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


def parts_rows(context, size, sizes, counts, sessions=None, context_shares=None):
    """Every part, nested in SECTIONS (startup in STARTUP_SECTIONS), as table rows.

    context: part -> tokens in the context; size: part -> tokens in the session's size;
    sizes: part -> bytes in the context; counts: part -> how many times it occurred (per session in
    averages); sessions, for averages: each session's set of parts, counted for every row;
    context_shares, for averages: part -> its context share averaged over the requests, so
    each request weighs the same, instead of its share of the mean tokens.

    Returns the headers, and rows of id, parent, depth, branch (it opens to rows below it),
    the color of a section, and the cells.
    """
    ctx_total = sum(context.values()) or 1
    if context_shares is None:
        context_shares = {name: tokens / ctx_total for name, tokens in context.items()}
    size_total = sum(size.values()) or 1
    ids = count()

    def cells(label, members):
        ctx = sum(context.get(n, 0) for n in members)
        share = sum(context_shares.get(n, 0) for n in members)
        tokens = sum(size.get(n, 0) for n in members)
        row = [
            label,
            num(ctx),
            pct(share),
            num(tokens),
            pct(tokens / size_total),
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
            else sorted(members, key=lambda n: -size.get(n, 0))
        )
        for name in names:
            add(node, depth + 1, False, None, cells(name.split(":", 1)[1], [name]))

    by_section = defaultdict(list)
    for name in set(context) | set(size):
        by_section[section_of(name)].append(name)
    for section in SECTIONS:
        if section == "startup":
            children = [(sub, by_section[("startup", sub)]) for sub in STARTUP_SECTIONS]
            members = [n for _, part_names in children for n in part_names]
            nest(section, members, None, 0, children=children)
        else:
            fixed = CONVERSATION_PARTS if section == "conversation" else None
            nest(section, by_section[(section, None)], None, 0, fixed)
    headers = ["Part", "Context", "Context %", "Size", "Size %", "KiB"]
    headers.append("Count/session" if sessions is not None else "Count")
    if sessions is not None:
        headers.append(f"Sessions/{numstr(len(sessions))}")
    return headers, rows


def session_parts(session):
    # The parts at the session's peak context, with its size and counts.
    peak = session.peak
    return parts_rows(peak.parts, session.size, peak.sizes, session.counts)


def average_parts(items):
    # Each part's mean context, bytes, size, and count over the sessions.
    requests = [r for s in items for r in s.requests]
    return parts_rows(
        mean_dict([r.parts for r in requests]),
        mean_dict([s.size for s in items]),
        mean_dict([r.sizes for r in requests]),
        {n: c / len(items) for n, c in sum((s.counts for s in items), Counter()).items()},
        [set(s.size) for s in items],
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
        (
            "run tokens",
            num(statistics.mean(runs))
            if (runs := [c.run for c in every if c.run is not None])
            else "-",
        ),
        ("compaction time", mean_duration([c.time for c in every])),
    ]


def compression(row):
    # Tokens of the child's size per token of report, when both are known.
    if not (row.size and row.tokens):
        return "-"
    return f"{numstr(row.size / row.tokens, 0)}x"


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
    # One row per subagent run of a parent, largest first.
    headers = ["Agent", "Task", "Runs", "Requests", "Size", "Active", "Overhead"]
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
            maybe(row.size, num),
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
        for row in sorted(session.delegations, key=lambda r: -(r.size or 0))
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


def per_run(values, runs):
    # The recorded values summed per run, "-" when the agent records none.
    known = [v for v in values if v is not None]
    return numstr(sum(known) / runs, 1) if known else "-"


def efficiency_figures(items):
    # An agent type's runs: how much each returned token stands for, and how runs went.
    rows = [s.delegation for s in items if s.delegation]
    if not rows:
        return None
    ratios = [r.size / r.tokens for r in rows if r.size and r.tokens]
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
        ("corrections/run", per_run([r.corrections for r in rows], runs)),
        ("notes/run", per_run([r.notes for r in rows], runs)),
    ]


def agent_type_rows(sessions):
    # One row of efficiency figures per subagent type with linked runs, agents in HARNESSES
    # order.
    types = defaultdict(list)
    for session in sessions:
        if session.child:
            types[agent_key(session)].append(session)
    headers, rows = ["Agent"], []
    for key in sorted(types, key=lambda k: (list(HARNESSES).index(k.split(":")[0]), k)):
        if figures := efficiency_figures(types[key]):
            headers = ["Agent", *(label.capitalize() for label, _ in figures)]
            rows.append([agent_label(key), *(value for _, value in figures)])
    return headers, rows


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
    # The sessions you started, of every agent, oldest last prompt first; the overview's
    # average is over them, with subagent runs counted within their parents.
    main: list[Session] = field(default_factory=list)

    def load(self, sessions):
        self.sessions = sessions
        self.by_id = {s.id: s for s in sessions}
        self.main = [s for s in sorted(sessions, key=session_order) if not s.child]


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
# The usage donut's width and height, in pixels.
DONUT = 300
# Theme colors of an agent's models in order, as the context chart stacks its groups from the
# top; overlay is left out, as it is nearly the background.
MODEL_COLORS = ["f", "s", "p", "m"]
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
    # Size per day as columns with its average on the same axis, and the averages of
    # active hours and your wait per turn on their own axes, the wait's hidden.
    return column_options(
        series["days"],
        "Day",
        [value_axis("Size tokens"), value_axis("Hours", tokens=False), value_axis(show=False)],
        [
            {"type": "bar", "name": "Size", "data": series["tokens"], "color": color("o")},
            line("Size EMA", series["tokens_ema"], "m", 0),
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


def usage_sizes(sessions):
    # Agent -> model -> size, models by most requests; the models of an agent add up to it.
    sizes = {}
    for harness in HARNESSES:
        models, counts = defaultdict(float), Counter()
        for session in (s for s in sessions if s.harness == harness):
            for request in session.requests:
                models[request.model or "unknown"] += request.added
                counts[request.model or "unknown"] += 1
        if counts:
            sizes[harness] = {m: models[m] for m, _ in counts.most_common()}
    return sizes


def model_colors(sizes):
    # (agent, model) -> theme color: each agent's models take MODEL_COLORS in order, most
    # requests first, cycling after the last.
    return {
        (harness, model): MODEL_COLORS[i % len(MODEL_COLORS)]
        for harness, models in sizes.items()
        for i, model in enumerate(models)
    }


def donut_options(sessions):
    """Size as two rings: agents inside, their models outside in model_colors, separated by
    thin lines in the background color.
    """
    sizes = usage_sizes(sessions)
    colors = model_colors(sizes)
    edge = {"borderColor": color("b"), "borderWidth": 1}
    inner = [
        {"name": HARNESSES[h], "value": sum(m.values())}
        | {"itemStyle": {"color": color(HARNESS_COLORS[h])} | edge}
        for h, m in sizes.items()
    ]
    outer = [
        {"name": f"{HARNESSES[h]} · {model}", "value": size}
        | {"itemStyle": {"color": color(colors[h, model])} | edge}
        for h, models in sizes.items()
        for model, size in models.items()
    ]
    ring = {"type": "pie", "label": {"show": False}, "startAngle": 90}
    return {
        "tooltip": {
            "trigger": "item",
            ":formatter": f"""p => p.name + ': ' + ({NUMSTR})(p.value, 0)
              + ' · %' + ({NUMSTR})(p.percent, 1)""",
        },
        "series": [
            ring | {"name": "Agents", "radius": ["28%", "52%"], "data": inner},
            ring | {"name": "Models", "radius": ["56%", "80%"], "data": outer},
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


# A row of a nested table: an arrow on the rows that open, the top row's color, and the
# part name indented by depth; the rows that open emit toggle with their ID.
NESTED_ROW = """
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


def nested_table(headers, rows, opened=False):
    """A table of nested rows (as parts_rows returns them), collapsed to its top rows or,
    when opened, fully open; a row opens its direct children and closes all its descendants.
    """
    opened = {row["id"] for row in rows if row["branch"]} if opened else set()
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
    grid.add_slot("body", NESTED_ROW.replace("INDENT", str(store.theme["dim"]["m"])))
    grid.on("toggle", toggle)


def overview_page():
    sessions = store.sessions
    with ui.column().classes("page"):
        kpis(overview_figures(sessions))
        chart(daily_options(daily_series(sessions)), 420)
        # The usage table beside its cost donut.
        with ui.row().classes("w-full no-wrap items-start"):
            with ui.element("div").classes("col small"):
                nested_table(*usage_rows(sessions), opened=True)
            element = ui.echart(donut_options(sessions), theme=chart_theme())
            element.style(f"width:{DONUT}px; height:{DONUT}px")
        if store.main:
            average_section(store.main)
        headers, rows = agent_type_rows(sessions)
        if rows:
            section("Agent types")
            table(headers, rows)


def average_section(items):
    # The averages over your sessions; each session's column is labeled with its day, shows
    # its title, and opens its page.
    section(f"Average of {numstr(len(items))} sessions")
    kpis(session_figures(items, True))
    days, columns = history_columns(items)
    titles = [session_title(s) for s in items]
    chart(
        stacked_options(titles, columns, "Size tokens", "Session", ticks=days),
        420,
        on_click=lambda e: ui.navigate.to(f"/session/{items[e.data_index].id}"),
    )
    chart(bar_options(startup_segments(items), "Tokens"), 96)
    nested_table(*average_parts(items))
    time_section(items)
    compactions_section(items)
    running, average = growth_series(items)
    if running:
        chart(growth_options(running, average), 420)


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
        nested_table(*session_parts(session))
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
    """The drawer's tree: overview, every agent's sessions by newest prompt, then the group
    of unlinked children.

    Nested subagent runs retain their start-time order, oldest first.

    Node IDs are the pages' paths; group nodes cannot be selected.
    """
    newest = sorted(store.sessions, key=session_order, reverse=True)
    children = defaultdict(list)
    for session in sorted(store.sessions, key=lambda s: s.time):
        if session.parent in store.by_id:
            children[session.parent].append(session)

    def node(session):
        figures = f"{num(session.total_size)} · {money(session.cost)}"
        who = session.agent if session.child else HARNESSES[session.harness]
        caption = f"{who} · {figures}"
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

    unlinked = [s for s in newest if s.child and s.parent not in store.by_id]
    return [
        {"id": "/", "label": "Overview"},
        *(node(s) for s in newest if not s.child),
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
        tree.expand(["unlinked"])
    ui.sub_pages(
        {
            "/": overview_page,
            "/session/{session_id}": session_page,
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
.small .q-table, .small .q-table th {{ font-size:{px(size["m"])}px; }}
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
        title="Agent stats",
        dark=store.theme["dark"],
        show=False,
        reload=False,
    )


if __name__ == "__main__":
    main()
