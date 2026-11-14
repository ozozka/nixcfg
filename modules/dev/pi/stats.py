"""Pi context statistics: what each model call contained, rebuilt from Pi's session files.

Usage: stats.py THEME [--since YYYY-MM-DD] [--project TEXT] [--out FILE]

Each assistant message is one model call. Its context is the path from the session root to
that message: system messages patch the prompt sections and tool declarations, the latest
compaction replaces older entries with its summary and prompt checkpoint, and context edits
replace or drop entries. Parts are measured in UTF-8 bytes; their tokens are the part's share
of the call's real prompt tokens (input + cache read + cache write) from the response usage.

Output tokens are split over the response's own text, thinking, and tool calls the same way;
reported reasoning tokens go to thinking. A session's consumption is the sum of its calls'
prompt and output parts, so a part sent with every call weighs more than its context share.

Subagent sessions live in subagent-sessions/; the parent's subagent results and messages
record their session IDs, and how each run of a child ended. A child's notes are its
send_message calls; parent messages (steers and continuations) are its prompts that start
with PARENT_MESSAGE.
THEME is a JSON file of colors, fonts, and sizes supplied by Nix.
"""

import argparse
import html
import io
import json
import os
import re
import statistics
from collections import Counter, defaultdict
from datetime import datetime
from functools import cache
from pathlib import Path

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
# Run endings in subagent.ts, as labeled in the report.
OUTCOMES = {"idle": "Done", "budget": "Budget", "failed": "Failed", "aborted": "Stopped"}
GROWTH_MIN_SESSIONS = 3
# Gaps before a prompt longer than this are breaks, not time spent on the session.
BREAK_MS = 30 * 60 * 1000
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


def section_of(part):
    # The parts table section and, for startup, the subsection of a part.
    group = part.split(":", 1)[0]
    if group in ("system", "context", "tool"):
        return "startup", GROUPS[group]
    if group in ("call", "result"):
        return GROUPS[group], None
    return ("conversation" if part in CONVERSATION_PARTS else "other"), None


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


def calls_of(header, entries, agent, uses=None):
    # uses, when given, counts for each entry ID the requests whose context included it.
    # One record per assistant message with real usage.
    by_id = {e["id"]: e for e in entries}
    # Each entry is measured once; later calls share it.
    measured = {}
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
        modes = [e.get("data") or {} for e in path if e.get("customType") == "mode"]
        mode = modes[-1].get("name") if modes else None
        compactions = [i for i, e in enumerate(path) if e["type"] == "compaction"]
        if compactions:
            index = compactions[-1]
            compaction = path[index]
            apply_system(state, compaction.get("systemMessage") or {})
            kept = next(
                (i for i, e in enumerate(path) if e["id"] == compaction["firstKeptEntryId"]),
                index,
            )
            # Kept entries before the compaction, without their system messages, then the rest.
            path = (
                [compaction]
                + [
                    e
                    for e in path[kept:index]
                    if (e.get("message") or {}).get("role") != "system"
                ]
                + path[index + 1 :]
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
            yield {"skipped": True}
            continue
        if uses is not None:
            uses.update(included)

        parts = defaultdict(int)
        for name, length in system_parts(state, header.get("cwd")) + conversation:
            parts[name] += length
        total = sum(parts.values()) or 1
        yield {
            "skipped": False,
            "session": header.get("id"),
            "agent": agent,
            "cwd": header.get("cwd", ""),
            "time": entry["timestamp"],
            "model": message.get("model"),
            "mode": mode or "free",
            "prompt": prompt,
            "bytes": total,
            "sizes": dict(parts),
            "output": usage.get("output", 0),
            "cache": usage.get("cacheRead", 0),
            "cost": (usage.get("cost") or {}).get("total", 0),
            "tools": set(state["tools"]),
            # Skills listed in the system prompt.
            "skills": state["sections"].get("skills", "").count(SKILL_TAG),
            "parts": {name: value / total * prompt for name, value in parts.items()},
            "out": output_parts(message),
        }


def session_of(header, calls, agent, entries):
    # Session totals; consumption sums every call's prompt parts and output parts.
    consumed = defaultdict(float)
    for index, call in enumerate(calls):
        call["index"] = index
        for parts in (call["parts"], call["out"]):
            for name, tokens in parts.items():
                consumed[name] += tokens
    compactions = [e for e in entries if e["type"] == "compaction"]
    for compaction in compactions:
        consumed["conversation:compaction runs"] += run_tokens(compaction)
    peak = max(calls, key=lambda c: c["prompt"])
    messages = [e.get("message") or {} for e in entries if e["type"] == "message"]
    spent = timing(entries)
    return {
        "id": header.get("id"),
        "agent": agent,
        "cwd": header.get("cwd", ""),
        "time": calls[0]["time"],
        "model": peak["model"],
        "calls": calls,
        "peak": peak["prompt"],
        "consumed": dict(consumed),
        "compactions": len(compactions),
        # The first call after each compaction.
        "marks": [
            next((c["index"] for c in calls if c["time"] > e["timestamp"]), len(calls) - 1)
            for e in compactions
        ],
        "cost": sum(c["cost"] for c in calls),
        "compaction_list": [compaction_of(e, calls) for e in compactions],
        "spent": spent,
        # Wall-clock span, for the parallelism of a parent's subagent runs.
        "start": milliseconds(entries[0]["timestamp"]),
        "end": milliseconds(entries[-1]["timestamp"]),
        "notes": sum(
            1
            for m in messages
            if m.get("role") == "assistant"
            for block in m.get("content") or []
            if block.get("type") == "toolCall" and block.get("name") == NOTE_TOOL
        ),
        "parent_messages": sum(
            1
            for m in messages
            if m.get("role") == "user" and text_of(m.get("content")).startswith(PARENT_MESSAGE)
        ),
        # Filled in by collect from the parent's records.
        "outcomes": Counter(),
    }


def milliseconds(stamp):
    return datetime.fromisoformat(stamp).timestamp() * 1000


def timing(entries):
    """Milliseconds per TIME_PARTS category.

    Model time is each response's durationMs; a turn's tool time is its longest tool result,
    since tools of one turn run in parallel, and counts as subagent waits when it includes a
    subagent wait. Compaction runs from the entry before it; your time runs from the end of
    the previous run to the next prompt, without gaps longer than BREAK_MS, plus the time
    you take to answer the question tool.
    """
    spent, calls = defaultdict(float), {}
    previous, turn, waited = None, 0.0, False
    for entry in entries:
        stamp = milliseconds(entry["timestamp"])
        message = entry.get("message") or {}
        role = message.get("role")
        if role in ("user", "assistant"):
            spent["subagent waits" if waited else "tools"] += turn
            turn, waited = 0.0, False
        if entry["type"] == "compaction" and previous is not None:
            spent["compaction"] += stamp - previous
        elif role == "user" and previous is not None and stamp - previous <= BREAK_MS:
            spent["you"] += stamp - previous
        elif role == "assistant":
            spent["model"] += message.get("durationMs") or 0
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
    return dict(spent)


def run_tokens(compaction):
    # Tokens of the compaction's own model request.
    usage = compaction.get("usage") or {}
    return sum(usage.get(key, 0) for key in ("input", "cacheRead", "cacheWrite", "output"))


def compaction_of(entry, calls):
    # One compaction: the context before it (Pi's count), the context of the first request
    # after it (None when none followed), and the tokens of its own run.
    after = next((c for c in calls if c["time"] > entry["timestamp"]), None)
    return {
        "before": entry.get("tokensBefore", 0),
        "after": after["prompt"] if after else None,
        "run": run_tokens(entry),
    }


def collect(since, project):
    main_files = sorted(AGENT_DIR.glob("sessions/*/*.jsonl"))
    child_files = sorted(AGENT_DIR.glob("subagent-sessions/*.jsonl"))
    sessions = [(*read_session(path), False) for path in main_files]
    # Child session ID -> agent name, parent session ID, task, and run endings, from the
    # parents' subagent results and messages. A run's end is delivered once, in a wait result
    # or a message.
    agents, parents, tasks, outcomes = {}, {}, {}, defaultdict(Counter)
    for header, entries, _ in sessions:
        for entry in entries:
            message = entry.get("message") or {}
            if message.get("toolName") == "subagent":
                details = message.get("details") or {}
            elif entry.get("customType") == "subagent":
                details = entry.get("details") or {}
            else:
                continue
            ends = details.get("action") in ("wait", "event") and details.get("note") is None
            for result in details.get("results", []):
                if result.get("sessionId"):
                    agents[result["sessionId"]] = result["agent"]
                    parents[result["sessionId"]] = header.get("id")
                    tasks.setdefault(result["sessionId"], result.get("task", ""))
                    if ends and result.get("state") in OUTCOMES:
                        outcomes[result["sessionId"]][result["state"]] += 1
    sessions += [(*read_session(path), True) for path in child_files]

    found, skipped = [], 0
    for header, entries, child in sessions:
        if project and project not in header.get("cwd", ""):
            continue
        agent = agents.get(header.get("id"), "subagent") if child else "main"
        calls, uses = [], Counter()
        for call in calls_of(header, entries, agent, uses):
            if call["skipped"]:
                skipped += 1
            else:
                calls.append(call)
        if not calls or (since and calls[0]["time"] < since):
            continue
        found.append(session_of(header, calls, agent, entries))
        found[-1]["outcomes"] = outcomes.get(header.get("id"), Counter())
        found[-1]["child"] = child
        found[-1]["parent"] = parents.get(header.get("id")) if child else None
        found[-1]["task"] = tasks.get(header.get("id"), "") if child else ""
        # Set below for a child whose parent's reports include it.
        found[-1]["delegation"] = None
        found[-1]["reports"] = [] if child else reports_of(entries, calls, uses)
        # Tool results, sized at the session's own bytes per token.
        ratio = statistics.median(c["bytes"] / c["prompt"] for c in calls)
        found[-1]["results"] = [
            {
                "tool": message["toolName"],
                "tokens": text_size(message["content"]) / ratio,
                "error": bool(message.get("isError")),
                "duration": message.get("durationMs"),
            }
            for message in (e.get("message") or {} for e in entries)
            if message.get("role") == "toolResult"
        ]
    # Each parent's subagent runs, with the child sessions' own totals; each child keeps its
    # row and parent.
    children = {s["id"]: s for s in found if s["child"]}
    for session in found:
        session["delegations"] = delegations_of(session["reports"], children)
        for row in session["delegations"]:
            if row["child"] in children:
                children[row["child"]]["delegation"] = {**row, "parent": session}
    return found, skipped


def reports_of(entries, calls, uses):
    """The reports subagents returned to this parent: one record per ended child run.

    A report is a subagent wait result or message; its tokens are its bytes at the parent's
    bytes per token, split evenly when one wait returned several runs, and its re-sent
    tokens count every later request that carried it.
    """
    ratio = statistics.median(c["bytes"] / c["prompt"] for c in calls)
    reports = []
    for entry in entries:
        message = entry.get("message") or {}
        if message.get("toolName") == "subagent":
            details, content = message.get("details") or {}, message.get("content")
        elif entry.get("customType") == "subagent":
            details, content = entry.get("details") or {}, entry.get("content")
        else:
            continue
        # Older results have no action; notes are not reports.
        if details.get("action") not in (None, "wait", "event") or details.get("note"):
            continue
        ended = [
            r
            for r in details.get("results", [])
            if r.get("sessionId") and r.get("state") not in ("queued", "running")
        ]
        for result in ended:
            tokens = text_size(content or []) / ratio / len(ended)
            reports.append(
                {
                    "child": result["sessionId"],
                    "agent": result["agent"],
                    "task": result.get("task", ""),
                    "state": result.get("state"),
                    "tokens": tokens,
                    "resent": tokens * uses[entry["id"]],
                }
            )
    return reports


def delegations_of(reports, children):
    # One row per child session: its runs' reports summed, with the child's own totals.
    rows = {}
    for report in reports:
        row = rows.setdefault(
            report["child"],
            {**report, "runs": 0, "tokens": 0.0, "resent": 0.0},
        )
        row["runs"] += 1
        row["tokens"] += report["tokens"]
        row["resent"] += report["resent"]
        row["state"] = report["state"]
    for row in rows.values():
        child = children.get(row["child"])
        row["session"] = child
        row["requests"] = len(child["calls"]) if child else None
        row["consumed"] = sum(child["consumed"].values()) if child else None
        row["active"] = sum(child["spent"].values()) if child else None
        # The fixed price of an agent: its startup tokens, sent with every request.
        startup = sum(startup_of(child)[0].values()) if child else 0
        row["overhead"] = (
            startup * len(child["calls"]) / row["consumed"]
            if child and row["consumed"]
            else None
        )
        # What the parent never had to hold: the child's tool results, less the report.
        material = sum(r["tokens"] for r in child["results"]) if child else None
        row["kept"] = max(0, material - row["tokens"]) if material is not None else None
        row["corrections"] = child["parent_messages"] if child else None
        row["notes"] = child["notes"] if child else None
    return list(rows.values())


# Rendering: an HTML page of tabs; charts are matplotlib SVG in the theme's colors.

TABS = {"overview": "Overview", "session": "Session"}
# Chart groups and their theme colors, in stacking order; parts map to them by prefix.
# The parts table SECTIONS as the chart stacks them, bottom to top, with their theme colors.
CHART_GROUPS = {
    "startup": "o",
    "conversation": "m",
    "tool calls": "p",
    "tool results": "s",
    "other": "f",
}
# Startup groups: the parts of a call before any conversation, and their theme colors, in
# the order the prompt is put together.
STARTUP_GROUPS = {
    "system": ("system prompt", "m"),
    "tool": ("tool definitions", "p"),
    "context": ("context files", "s"),
}
BAR_WIDTH = 0.72
# Above this many columns, stacked bars touch, so dense sessions read as a stepped area.
DENSE_COLUMNS = 60
TICK_COUNT = 8

# Tabs follow the URL hash; a select shows the panel named by its value.
SCRIPT = """
// Nested table rows: a row with data-id opens its direct children and closes all its
// descendants.
const toggle = row => {
  const open = !row.classList.contains("open");
  row.classList.toggle("open", open);
  const close = id => row.parentElement.querySelectorAll(`tr[data-parent="${id}"]`).forEach(child => {
    child.hidden = true;
    child.classList.remove("open");
    if (child.dataset.id) close(child.dataset.id);
  });
  if (open) {
    row.parentElement.querySelectorAll(`tr[data-parent="${row.dataset.id}"]`).forEach(child => {
      child.hidden = false;
    });
  } else close(row.dataset.id);
};
document.querySelectorAll("table.nested tr[data-id]").forEach(row => {
  row.addEventListener("click", () => toggle(row));
});
const show = () => {
  const id = location.hash.slice(1) || document.querySelector("main > section").id;
  document.querySelectorAll("main > section").forEach(tab => { tab.hidden = tab.id !== id; });
  document.querySelectorAll("nav a").forEach(link => {
    link.toggleAttribute("aria-current", link.hash === "#" + id);
  });
};
addEventListener("hashchange", show);
show();
// A select shows the panel named by its value.
document.querySelectorAll("select[data-panels]").forEach(select => {
  select.addEventListener("change", () => {
    select.parentElement.querySelectorAll(":scope > .panel").forEach(panel => {
      panel.hidden = panel.id !== select.value;
    });
  });
});
"""


def esc(value):
    return html.escape(str(value))


def num(value):
    if value >= 1e6:
        return f"{value / 1e6:.1f}M"
    if value >= 1e4:
        return f"{value / 1e3:.0f}k"
    return f"{value:,.0f}"


def duration(ms):
    seconds = ms / 1000
    if seconds >= 3600:
        return f"{seconds // 3600:.0f}h{seconds % 3600 // 60:02.0f}m"
    if seconds >= 60:
        return f"{seconds // 60:.0f}m{seconds % 60:02.0f}s"
    return f"{seconds:.1f}s"


def kib(value):
    return f"{value / 1024:,.1f}"


def pct(value):
    return f"{100 * value:.1f}%"


def group_of(part):
    return section_of(part)[0]


def swatch(color_key, theme):
    return Markup(f'<span class="square" style="color:#{theme["colors"][color_key]}">■</span>')


def kpis(items):
    cells = "".join(f"<div><span>{esc(k)}</span><b>{esc(v)}</b></div>" for k, v in items)
    return f'<div class="kpis">{cells}</div>'


def table(headers, rows, cls=""):
    # rows: (cells, row class) or (cells, row class, row attributes); cells are escaped
    # unless wrapped in Markup.
    head = "".join(f"<th>{esc(h)}</th>" for h in headers)
    body = "".join(
        f'<tr class="{row[1]}"{row[2] if len(row) > 2 else ""}>'
        + "".join(f"<td>{cell_html(c)}</td>" for c in row[0])
        + "</tr>"
        for row in rows
    )
    return f'<table class="{cls}"><tr>{head}</tr>{body}</table>'


class Markup(str):
    pass


def cell_html(value):
    return value if isinstance(value, Markup) else esc(value)


def px(points):
    return points * 96 / 72


def style(theme):
    c, size, dim, fonts = theme["colors"], theme["fontSize"], theme["dim"], theme["fonts"]
    return f"""
:root {{ --p:#{c["p"]}; --s:#{c["s"]}; --f:#{c["f"]}; --m:#{c["m"]}; --o:#{c["o"]};
  --b:#{c["b"]}; }}
body {{ background:var(--b); color:var(--f); font:{px(size["m"])}px "{fonts["sans"]}";
  margin:0; }}
nav {{ display:flex; align-items:center; gap:{dim["s"]}px; padding:0 {dim["m"]}px; }}
nav b {{ font-size:{px(size["x"])}px; margin-right:{dim["m"]}px; }}
nav a {{ color:var(--f); text-decoration:none; padding:{dim["s"]}px; }}
nav a[aria-current] {{ background:var(--o); }}
main {{ padding:{dim["m"]}px; }}
h2 {{ font-size:{px(size["s"])}px; color:var(--m); text-transform:uppercase;
  border-bottom:1px solid var(--o); margin:{dim["m"]}px 0 {dim["s"]}px; }}
.kpis {{ display:grid; grid-template-columns:repeat(auto-fit, minmax({dim["x"]}px, 1fr));
  text-align:center; margin-bottom:{dim["s"]}px; }}
.kpis span {{ display:block; color:var(--m); font-size:{px(size["s"])}px; }}
.kpis b {{ font:{px(size["h"])}px "{fonts["mono"]}"; }}
table {{ border-collapse:collapse; width:100%; font:{px(size["l"])}px "{fonts["mono"]}";
  margin-bottom:{dim["s"]}px; }}
th {{ font-family:"{fonts["sans"]}"; color:var(--m); text-align:right; }}
th, td {{ padding:{dim["t"]}px {dim["s"]}px; white-space:nowrap; text-align:right;
  border-bottom:1px solid var(--o); }}
th:first-child, td:first-child, table.text :is(td, th):last-child {{ text-align:left; }}
table.text td:last-child {{ white-space:normal; color:var(--m);
  font-size:{px(size["m"])}px; }}
tr.group td {{ color:var(--m); }}
table.nested tr[data-id] {{ cursor:pointer; }}
table.nested tr[data-id] td:first-child::before {{ content:"▸ "; color:var(--m); }}
table.nested tr.open td:first-child::before {{ content:"▾ "; }}
table.nested tr.level-1 td:first-child, table.nested tr.part-1 td:first-child {{
  padding-left:{dim["m"]}px; }}
table.nested tr.part-2 td:first-child {{ padding-left:{dim["m"] * 2}px; }}
tr.part td:first-child {{ padding-left:{dim["m"]}px; }}
tr.flag td {{ color:var(--s); }}
.square {{ margin-right:{dim["t"] * 2}px; }}
.chart svg {{ width:100%; height:auto; display:block; margin-bottom:{dim["s"]}px; }}
select {{ background:var(--o); color:var(--f); border:0; padding:{dim["t"] * 2}px;
  font:{px(size["l"])}px "{fonts["mono"]}"; margin-bottom:{dim["s"]}px; }}
"""


# Charts


def chart_style(theme):
    from matplotlib import cycler

    c = {key: f"#{value}" for key, value in theme["colors"].items()}
    small = theme["fontSize"]["s"]
    return {
        "figure.figsize": (16, 6),
        "svg.fonttype": "none",
        "svg.hashsalt": "pi-stats",
        "font.family": theme["fonts"]["mono"],
        "font.size": small,
        "legend.fontsize": small,
        "figure.facecolor": c["b"],
        "axes.facecolor": c["b"],
        "text.color": c["f"],
        "axes.labelcolor": c["m"],
        "axes.edgecolor": c["o"],
        "axes.grid": False,
        "axes.xmargin": 0,
        "xtick.color": c["o"],
        "ytick.color": c["o"],
        "xtick.labelcolor": c["m"],
        "ytick.labelcolor": c["m"],
        "legend.facecolor": c["b"],
        "legend.edgecolor": c["o"],
        "axes.prop_cycle": cycler(color=[c["p"], c["f"], c["m"]]),
    }


def render(theme, draw, size=None):
    # Runs draw(figure) under the theme style and returns the SVG markup.
    from matplotlib import rc_context
    from matplotlib.figure import Figure

    with rc_context(chart_style(theme)):
        figure = Figure(layout="constrained", figsize=size)
        draw(figure)
        buffer = io.StringIO()
        figure.savefig(buffer, format="svg", metadata={"Date": None})
    svg = buffer.getvalue()
    return Markup(f'<div class="chart">{svg[svg.index("<svg") :]}</div>')


def compact_ticks(axes):
    from matplotlib.ticker import FuncFormatter

    axes.yaxis.set_major_formatter(FuncFormatter(lambda value, _: num(value)))


def x_labels(axes, labels):
    step = max(1, len(labels) // TICK_COUNT)
    # Evenly spaced ticks plus the last label, skipping one that would crowd it.
    last = len(labels) - 1
    positions = sorted({0, last, *(i for i in range(0, last, step) if last - i > step / 2)})
    axes.set_xticks(positions, [labels[i] for i in positions], rotation=30, ha="right")
    axes.set_xlim(-BAR_WIDTH / 2, len(labels) - 1 + BAR_WIDTH / 2)


def combo_chart(theme, labels, bars, lines, xlabel="", axis="own", marks=()):
    """Overlay-colored columns on the left axis and lines over them.

    bars: (label, values); lines: (label, values, color key, axis label or None).
    axis: "own" gives each line its own zero-based axis, the first labeled one on the right
    and the others hidden; "bars" draws the lines on the columns' axis, for the same unit;
    "lines" puts every line on one right axis, for lines sharing a unit apart from the bars.
    marks: x positions drawn as dashed vertical rules.
    """
    colors = theme["colors"]

    def draw(figure):
        base = figure.subplots()
        handles = [
            base.bar(
                range(len(labels)),
                bars[1],
                width=BAR_WIDTH,
                color=f"#{colors['o']}",
                label=bars[0],
            )
        ]
        base.set_ylim(bottom=0)
        base.set_ylabel(bars[0])
        compact_ticks(base)
        for mark in marks:
            base.axvline(mark, color=f"#{colors['m']}", linestyle="--", linewidth=1)
        common = base if axis == "bars" else base.twinx() if axis == "lines" else None
        shown = False
        for label, values, color, axis_label in lines:
            axes = common or base.twinx()
            handles += axes.plot(
                range(len(values)), values, color=f"#{colors[color]}", label=label
            )
            if common is None:
                axes.set_ylim(0, (max(values, default=0) or 1) * 1.05)
            if axis_label and not shown:
                shown = True
                axes.set_ylabel(axis_label)
                compact_ticks(axes)
            elif common is None:
                axes.set_axis_off()
        if axis == "lines":
            common.set_ylim(bottom=0)
        x_labels(base, labels)
        base.set_xlabel(xlabel)
        legend = figure.legend(
            handles=handles,
            loc="upper left",
            bbox_to_anchor=(0, 1),
            bbox_transform=base.transAxes,
            framealpha=1,
        )
        legend.set_in_layout(False)

    return render(theme, draw)


def stacked_chart(theme, labels, columns, ylabel, xlabel, marks=(), groups=CHART_GROUPS):
    """Columns stacked by group, in group order from the bottom: each column's height is its
    total, each color a group's tokens, and a group's colored area over all columns its sum.

    columns: group name -> tokens, one per label; groups: group name -> theme color key.
    marks: x positions drawn as dashed vertical rules.
    """
    colors = theme["colors"]

    def draw(figure):
        axes = figure.subplots()
        positions = range(len(columns))
        dense = len(columns) > DENSE_COLUMNS
        width = 1 if dense else BAR_WIDTH
        bottom = [0.0] * len(columns)
        handles = []
        for group, key in groups.items():
            values = [column.get(group, 0) for column in columns]
            handles.append(
                axes.bar(
                    positions,
                    values,
                    width=width,
                    bottom=bottom,
                    color=f"#{colors[key]}",
                    # A hairline edge in the bar's color closes the seams between dense bars.
                    edgecolor=f"#{colors[key]}" if dense else "none",
                    linewidth=0.5 if dense else 0,
                    label=group,
                )
            )
            bottom = [low + value for low, value in zip(bottom, values, strict=True)]
        axes.set_ylim(bottom=0)
        axes.set_ylabel(ylabel)
        compact_ticks(axes)
        for mark in marks:
            axes.axvline(mark, color=f"#{colors['f']}", linestyle="--", linewidth=1)
        x_labels(axes, labels)
        axes.set_xlabel(xlabel)
        legend = figure.legend(
            handles=handles[::-1],
            loc="upper left",
            bbox_to_anchor=(0, 1),
            bbox_transform=axes.transAxes,
            framealpha=1,
        )
        legend.set_in_layout(False)

    return render(theme, draw)


def grouped(parts):
    # Part tokens summed per chart group.
    totals = defaultdict(float)
    for name, tokens in parts.items():
        totals[group_of(name)] += tokens
    return totals


# Tabs


def subagent_share(sessions):
    # Child sessions' share of all consumed tokens.
    total = sum(sum(s["consumed"].values()) for s in sessions)
    children = sum(sum(s["consumed"].values()) for s in sessions if s["child"])
    return pct(children / total) if total else "-"


def overview_tab(sessions, calls, skipped, theme):
    prompt = sum(c["prompt"] for c in calls)
    main = [s for s in sessions if s["agent"] == "main"]
    ratio = statistics.median(c["bytes"] / c["prompt"] for c in calls)
    head = kpis(
        [
            ("sessions", len(main)),
            ("subagent runs", len(sessions) - len(main)),
            ("subagent share", subagent_share(sessions)),
            ("requests", len(calls)),
            ("input", num(prompt)),
            ("output", num(sum(c["output"] for c in calls))),
            ("cost", f"${sum(c['cost'] for c in calls):.2f}"),
            ("cache hit", f"{100 * sum(c['cache'] for c in calls) / prompt:.0f}%"),
            ("bytes/token", f"{ratio:.2f}"),
            ("compactions", sum(len(s["compaction_list"]) for s in sessions)),
            (
                "compaction tokens",
                num(sum(c["run"] for s in sessions for c in s["compaction_list"])),
            ),
            ("skipped calls", skipped),
        ]
    )

    # Tokens per day: input and output of every request.
    days = defaultdict(int)
    for call in calls:
        days[call["time"][:10]] += call["prompt"] + call["output"]
    labels = sorted(days)
    chart = stacked_chart(
        theme,
        labels,
        [{"tokens": days[d]} for d in labels],
        "Tokens",
        "Day",
        groups={"tokens": "o"},
    )

    models = defaultdict(list)
    for call in calls:
        models[call["model"]].append(call)
    rows = []
    for model, items in sorted(models.items(), key=lambda m: -len(m[1])):
        tokens = sum(c["prompt"] for c in items)
        rows.append(
            (
                [
                    model,
                    len(items),
                    num(tokens),
                    num(sum(c["output"] for c in items)),
                    f"${sum(c['cost'] for c in items):.2f}",
                    f"{100 * sum(c['cache'] for c in items) / tokens:.0f}%",
                ],
                "",
            )
        )
    models_table = table(["Model", "Requests", "Input", "Output", "Cost", "Cache"], rows)
    return head + chart + models_table


def startup_of(session):
    # The first call's parts before any conversation in tokens and bytes, and the counts of
    # its tools, context files, and skills.
    call = session["calls"][0]

    def fixed(parts):
        return {n: v for n, v in parts.items() if n.split(":")[0] in STARTUP_GROUPS}

    groups = [name.split(":")[0] for name in fixed(call["parts"])]
    counts = {
        "tools": groups.count("tool"),
        "context files": groups.count("context"),
        "skills": call["skills"],
    }
    return fixed(call["parts"]), fixed(call["sizes"]), counts


def startup_bar(theme, values):
    # One horizontal bar split into every part, colored by group.
    colors = theme["colors"]

    def draw(figure):
        axes = figure.subplots()
        left = 0
        for key, (_, color) in STARTUP_GROUPS.items():
            items = sorted(
                (t for n, t in values.items() if n.split(":")[0] == key), reverse=True
            )
            for tokens in items:
                axes.barh(
                    0,
                    tokens,
                    left=left,
                    color=f"#{colors[color]}",
                    edgecolor=f"#{colors['b']}",
                    linewidth=1,
                )
                left += tokens
        axes.set_xlim(0, left or 1)
        axes.set_yticks([])
        compact_ticks(axes)
        axes.xaxis.set_major_formatter(axes.yaxis.get_major_formatter())
        axes.set_xlabel("Tokens")

    return render(theme, draw, size=(16, 1.6))


def mean_shares(calls):
    # Each call's context shares, averaged with equal weight per call.
    totals = defaultdict(float)
    for call in calls:
        total = sum(call["parts"].values()) or 1
        for name, tokens in call["parts"].items():
            totals[name] += tokens / total / len(calls)
    return totals


def mean_parts(calls, key):
    # Each part's value in calls[key], averaged over the calls (0 where it is missing).
    totals = defaultdict(float)
    for call in calls:
        for name, value in call[key].items():
            totals[name] += value / len(calls)
    return totals


def ratio(consumption, context):
    return f"{consumption / context:.1f}x" if context else "-"


TABLE_IDS = iter(range(1, 1_000_000))


def session_table(theme, context, consumed, sizes, sessions=None, context_shares=None):
    """Every part, nested in SECTIONS (startup in STARTUP_SECTIONS), collapsed to the
    section rows until opened.

    context: part -> tokens in the context; consumed: part -> tokens over the session;
    sizes: part -> bytes; sessions, for averages: each session's set of parts, counted for
    every row; context_shares, for averages: part -> its context share averaged over the
    requests, so each request weighs the same, instead of its share of the mean tokens.
    """
    ctx_total = sum(context.values()) or 1
    if context_shares is None:
        context_shares = {name: tokens / ctx_total for name, tokens in context.items()}
    cons_total = sum(consumed.values()) or 1
    names = set(context) | set(consumed)

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
        ]
        if sessions is not None:
            row.append(sum(1 for present in sessions if any(n in present for n in members)))
        return row

    def order(members, fixed=None):
        if fixed:
            return [n for n in fixed if n in members]
        return sorted(members, key=lambda n: -consumed.get(n, 0))

    rows = []

    def nest(label, members, parent, depth, fixed=None, children=None):
        # A row that opens to its parts, or to child rows given as (label, members, fixed).
        if not members:
            return
        node = f"p{next(TABLE_IDS)}"
        attrs = f' data-id="{node}"' + (f' data-parent="{parent}" hidden' if parent else "")
        mark = swatch(CHART_GROUPS[label], theme) if depth == 0 else ""
        title = Markup(f"{mark}<b>{esc(label)}</b>")
        rows.append((cells(title, members), f"level-{depth}", attrs))
        if children:
            for child_label, child_members, child_fixed in children:
                nest(child_label, child_members, node, depth + 1, child_fixed)
            return
        for name in order(members, fixed):
            part = f' data-parent="{node}" hidden'
            rows.append((cells(name.split(":", 1)[1], [name]), f"part-{depth + 1}", part))

    by_section = defaultdict(list)
    for name in names:
        by_section[section_of(name)].append(name)
    for section in SECTIONS:
        if section == "startup":
            children = [(sub, by_section[("startup", sub)], None) for sub in STARTUP_SECTIONS]
            members = [n for sub in STARTUP_SECTIONS for n in by_section[("startup", sub)]]
            nest(section, members, None, 0, children=children)
        else:
            fixed = CONVERSATION_PARTS if section == "conversation" else None
            nest(section, by_section[(section, None)], None, 0, fixed)
    headers = ["Part", "Context", "Context %", "Consumed", "Consumed %", "Ratio", "KiB"]
    if sessions is not None:
        headers.append(f"Sessions/{len(sessions)}")
    return table(headers, rows, "nested")


def session_kpis(items, average):
    # The same figures for one session or, with average, the means over several.
    def mean(values):
        return statistics.mean(values) if average else values[0]

    head = [("sessions", len(items))] if average else []
    return kpis(
        [
            *head,
            ("requests", f"{mean([len(s['calls']) for s in items]):.0f}"),
            ("peak context", num(mean([s["peak"] for s in items]))),
            ("consumed", num(mean([sum(s["consumed"].values()) for s in items]))),
            ("output", num(mean([sum(c["output"] for c in s["calls"]) for s in items]))),
            ("cost", f"${mean([s['cost'] for s in items]):.2f}"),
            ("compactions", f"{round(mean([s['compactions'] for s in items]), 1):g}"),
            ("active time", duration(mean([sum(s["spent"].values()) for s in items]))),
            *startup_figures(items),
        ]
    )


def startup_figures(items):
    # The startup's tokens, KiB, and counts, or their means over several sessions.
    starts = [startup_of(s) for s in items]
    figures = [
        ("startup tokens", num(statistics.mean(sum(t.values()) for t, _, _ in starts))),
        ("startup KiB", kib(statistics.mean(sum(b.values()) for _, b, _ in starts))),
    ]
    for name in starts[0][2]:
        value = statistics.mean(c[name] for _, _, c in starts)
        figures.append((name, f"{round(value, 1):g}"))
    return figures


def startup_line(theme, items):
    # The startup's parts as one bar; averaged part by part over several sessions.
    tokens = defaultdict(float)
    for session in items:
        for name, value in startup_of(session)[0].items():
            tokens[name] += value / len(items)
    return startup_bar(theme, tokens)


def compactions_summary(items):
    # Means over every compaction of the sessions; the count is among the session figures.
    every = [c for s in items for c in s["compaction_list"]]
    if not every:
        return ""
    done = [c for c in every if c["after"] and c["before"]]
    return "<h2>Compactions</h2>" + kpis(
        [
            ("context before", num(statistics.mean(c["before"] for c in every))),
            ("context after", num(statistics.mean(c["after"] for c in done)) if done else "-"),
            (
                "reduction",
                pct(statistics.mean(1 - c["after"] / c["before"] for c in done))
                if done
                else "-",
            ),
            ("run tokens", num(statistics.mean(c["run"] for c in every))),
        ]
    )


def time_bar(theme, spent):
    # One horizontal bar of the TIME_PARTS categories, in milliseconds, with a legend.
    colors = theme["colors"]

    def draw(figure):
        axes = figure.subplots()
        left, handles = 0, []
        for part, key in TIME_PARTS.items():
            value = spent.get(part, 0) / 60000
            handles.append(
                axes.barh(
                    0,
                    value,
                    left=left,
                    color=f"#{colors[key]}",
                    edgecolor=f"#{colors['m']}",
                    linewidth=1,
                    label=part,
                )
            )
            left += value
        axes.set_xlim(0, left or 1)
        axes.set_yticks([])
        axes.set_xlabel("Minutes")
        figure.legend(handles=handles, loc="outside lower center", ncols=len(handles))

    return render(theme, draw, size=(16, 2))


def time_section(theme, items):
    # Time per category as a bar; averages show means per session.
    spent = {
        part: sum(s["spent"].get(part, 0) for s in items) / len(items) for part in TIME_PARTS
    }
    if not any(spent.values()):
        return ""
    return "<h2>Time</h2>" + time_bar(theme, spent)


def tools_table(items, average):
    """One row per tool the sessions called: calls, errors, result tokens, and run time.

    Averages show calls, totals, and errors per session; Avg and Max are per call. The
    subagent tool is left out: its runs have their own section.
    """
    results = defaultdict(list)
    for session in items:
        for result in session["results"]:
            if result["tool"] != "subagent":
                results[result["tool"]].append(result)
    per = len(items) if average else 1
    # Sessions that called each tool.
    sessions = Counter(t for s in items for t in {r["tool"] for r in s["results"]})
    rows = []
    for tool, calls in sorted(results.items(), key=lambda kv: -sum(r["tokens"] for r in kv[1])):
        tokens = [r["tokens"] for r in calls]
        times = [r["duration"] for r in calls if r["duration"] is not None]
        rows.append(
            (
                [
                    tool,
                    f"{len(calls) / per:.1f}" if average else len(calls),
                    f"{sum(r['error'] for r in calls) / per:.1f}"
                    if average
                    else sum(r["error"] for r in calls),
                    num(sum(tokens) / per),
                    num(statistics.mean(tokens)),
                    num(max(tokens)),
                    duration(sum(times) / per) if times else "-",
                    duration(statistics.mean(times)) if times else "-",
                    duration(max(times)) if times else "-",
                    *([sessions[tool]] if average else []),
                ],
                "",
            )
        )
    if not rows:
        return ""
    each = "/session" if average else ""
    headers = ["Tool", f"Calls{each}", f"Errors{each}", f"Tokens{each}", "Avg tokens"]
    headers += ["Max tokens", f"Time{each}", "Avg time", "Max time"]
    if average:
        headers.append(f"Sessions/{len(items)}")
    return "<h2>Tools</h2>" + table(headers, rows)


def compression(row):
    # Tokens of the child's work per token of report, when both are known.
    if not (row["consumed"] and row["tokens"]):
        return "-"
    return f"{row['consumed'] / row['tokens']:.0f}x"


def maybe(value, show):
    return show(value) if value is not None else "-"


def parallelism(rows):
    # The children's summed active time over the wall-clock span they covered.
    sessions = [r["session"] for r in rows if r["session"]]
    span = max((s["end"] for s in sessions), default=0) - min(
        (s["start"] for s in sessions), default=0
    )
    active = sum(sum(s["spent"].values()) for s in sessions)
    return f"{active / span:.1f}x" if span > 0 else "-"


def delegations_section(session):
    # A parent's subagent runs: figures for all of them, then one row per run.
    rows = session["delegations"]
    if not rows:
        return ""
    consumed = sum(r["consumed"] or 0 for r in rows)
    own = sum(session["consumed"].values())
    head = kpis(
        [
            ("subagents", len(rows)),
            ("subagent share", pct(consumed / (own + consumed)) if consumed else "-"),
            ("kept out", num(sum(r["kept"] or 0 for r in rows))),
            ("parent re-send", num(sum(r["resent"] for r in rows))),
            ("parallelism", parallelism(rows)),
        ]
    )
    lines = []
    for row in sorted(rows, key=lambda r: -(r["consumed"] or 0)):
        task = row["task"].strip().split("\n")[0]
        lines.append(
            (
                [
                    row["agent"],
                    task[:PREVIEW] + ("…" if len(task) > PREVIEW else ""),
                    row["runs"],
                    maybe(row["requests"], str),
                    maybe(row["consumed"], num),
                    maybe(row["active"], duration),
                    maybe(row["overhead"], pct),
                    num(row["tokens"]),
                    compression(row),
                    maybe(row["kept"], num),
                    num(row["resent"]),
                    maybe(row["corrections"], str),
                    maybe(row["notes"], str),
                    OUTCOMES.get(row["state"], "-"),
                ],
                "",
            )
        )
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
    return "<h2>Subagents</h2>" + head + table(headers, lines)


def delegation_section(session):
    # A child's run as its parent saw it: who started it, what it returned, how it ended.
    row = session["delegation"]
    if not row:
        return ""
    parent = row["parent"]
    task = row["task"].strip().split("\n")[0]
    return (
        "<h2>Delegation</h2>"
        + f"<p>{esc(session_label(parent))}<br>{esc(task)}</p>"
        + kpis(
            [
                ("runs", row["runs"]),
                ("report", num(row["tokens"])),
                ("compression", compression(row)),
                ("kept out", maybe(row["kept"], num)),
                ("parent re-send", num(row["resent"])),
                ("overhead", maybe(row["overhead"], pct)),
                ("corrections", maybe(row["corrections"], str)),
                ("notes", maybe(row["notes"], str)),
                ("ending", OUTCOMES.get(row["state"], "-")),
            ]
        )
    )


def efficiency_section(items):
    # An agent type's runs: how much each returned token stands for, and how runs went.
    rows = [s["delegation"] for s in items if s["delegation"]]
    if not rows:
        return ""
    ratios = [r["consumed"] / r["tokens"] for r in rows if r["consumed"] and r["tokens"]]
    overheads = [r["overhead"] for r in rows if r["overhead"] is not None]
    kept = [r["kept"] for r in rows if r["kept"] is not None]
    ends = sum((s["outcomes"] for s in items), Counter())
    runs = sum(r["runs"] for r in rows)
    return "<h2>Efficiency</h2>" + kpis(
        [
            ("linked runs", runs),
            ("compression", f"{statistics.median(ratios):.0f}x" if ratios else "-"),
            ("overhead", pct(statistics.mean(overheads)) if overheads else "-"),
            ("kept out/run", num(sum(kept) / runs) if kept else "-"),
            ("budget stops", pct(ends["budget"] / sum(ends.values())) if ends else "-"),
            ("corrections/run", f"{sum(r['corrections'] or 0 for r in rows) / runs:.1f}"),
            ("notes/run", f"{sum(r['notes'] or 0 for r in rows) / runs:.1f}"),
        ]
    )


def session_average(items, theme):
    calls = [c for s in items for c in s["calls"]]
    consumed = defaultdict(float)
    for session in items:
        for name, tokens in session["consumed"].items():
            consumed[name] += tokens
    history = stacked_chart(
        theme,
        [s["time"][:10] for s in items],
        [grouped(s["consumed"]) for s in items],
        "Consumed tokens",
        "Session",
    )
    # Context size at each call number, averaged over the sessions that reached it.
    average, running = [], []
    for i in range(max(len(s["calls"]) for s in items)):
        at = [s["calls"][i]["prompt"] for s in items if len(s["calls"]) > i]
        if len(at) < GROWTH_MIN_SESSIONS:
            break
        running.append(len(at))
        average.append(statistics.mean(at))
    growth = (
        combo_chart(
            theme,
            [str(i + 1) for i in range(len(running))],
            ("Sessions", running),
            [("Average context", average, "p", "Context tokens")],
            "Request",
            axis="lines",
        )
        if running
        else ""
    )
    return (
        session_kpis(items, average=True)
        + history
        + startup_line(theme, items)
        + session_table(
            theme,
            mean_parts(calls, "parts"),
            {name: tokens / len(items) for name, tokens in consumed.items()},
            mean_parts(calls, "sizes"),
            [set(s["consumed"]) for s in items],
            mean_shares(calls),
        )
        + tools_table(items, average=True)
        + time_section(theme, items)
        + compactions_summary(items)
        + efficiency_section(items)
        + growth
    )


def session_single(session, theme):
    calls = session["calls"]
    peak = max(calls, key=lambda c: c["prompt"])
    tokens = stacked_chart(
        theme,
        [str(c["index"] + 1) for c in calls],
        [grouped(c["parts"]) for c in calls],
        "Context tokens",
        "Request",
        marks=session["marks"],
    )
    return (
        session_kpis([session], average=False)
        + tokens
        + startup_line(theme, [session])
        + session_table(theme, peak["parts"], session["consumed"], peak["sizes"])
        + tools_table([session], average=False)
        + time_section(theme, [session])
        + compactions_summary([session])
        + delegations_section(session)
        + delegation_section(session)
    )


def session_tab(sessions, theme):
    return panels_tab(sessions, "session", session_average, session_single, theme)


def panels_tab(sessions, prefix, average, single, theme):
    """One selector: an average per agent, then every session newest first, each followed by
    the subagent runs it started, then subagent runs whose parent is not in the report.
    """
    by_agent = defaultdict(list)
    for session in sorted(sessions, key=lambda s: s["time"]):
        by_agent[session["agent"]].append(session)
    averages = [
        (f"avg-{agent}", f"{agent} · {len(items)} sessions", average(items, theme))
        for agent, items in sorted(by_agent.items(), key=lambda kv: (kv[0] != "main", kv[0]))
    ]
    newest = sorted(sessions, key=lambda s: s["time"], reverse=True)
    ids = {s["id"] for s in sessions}
    children = defaultdict(list)
    for session in newest[::-1]:
        if session["parent"] in ids:
            children[session["parent"]].append(session)
    entries = []
    for session in newest:
        if session["child"]:
            continue
        entries.append((f"s-{session['id']}", session_label(session, children), session))
        entries += [
            (f"s-{child['id']}", child_label(child), child) for child in children[session["id"]]
        ]
    unlinked = [s for s in newest if s["child"] and s["parent"] not in ids]
    return selector(
        prefix,
        [
            ("Averages", averages),
            ("Sessions", [(key, label, single(s, theme)) for key, label, s in entries]),
            (
                "Unlinked subagents",
                [(f"s-{s['id']}", session_label(s), single(s, theme)) for s in unlinked],
            ),
        ],
    )


def session_label(session, children=None):
    count = len((children or {}).get(session["id"], []))
    runs = f" · {count} subagent{'s' if count > 1 else ''}" if count else ""
    return (
        f"{session['time'][:16].replace('T', ' ')} · {Path(session['cwd']).name}"
        f" · {session['agent']} · {len(session['calls'])} requests"
        f" · peak {num(session['peak'])}{runs}"
    )


def child_label(session):
    # Indented under its parent; option text keeps non-breaking spaces only.
    task = session["task"].strip().split("\n")[0]
    task = task[:PREVIEW] + ("…" if len(task) > PREVIEW else "")
    return f"\u00a0\u00a0\u00a0└ {session['agent']} · {task} · {len(session['calls'])} requests"


def selector(prefix, groups):
    # A select over grouped panels (key, label, content); the first panel is shown.
    panels = [panel for _, items in groups for panel in items]
    options = "".join(
        f'<optgroup label="{esc(group)}">'
        + "".join(
            f'<option value="{esc(prefix)}-{esc(key)}">{esc(label)}</option>'
            for key, label, _ in items
        )
        + "</optgroup>"
        for group, items in groups
        if items
    )
    shown = "".join(
        f'<div class="panel" id="{esc(prefix)}-{esc(key)}"{" hidden" if n else ""}>{content}</div>'
        for n, (key, _, content) in enumerate(panels)
    )
    return f"<div><select data-panels>{options}</select>{shown}</div>"


def report(sessions, skipped, theme, title):
    calls = [call for session in sessions for call in session["calls"]]
    tabs = {
        "overview": overview_tab(sessions, calls, skipped, theme),
        "session": session_tab(sessions, theme),
    }
    links = "".join(f'<a href="#{key}">{esc(TABS[key])}</a>' for key in tabs)
    body = "".join(f'<section id="{key}">{content}</section>' for key, content in tabs.items())
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>{esc(title)}</title>
<style>{style(theme)}</style></head><body><nav><b>{esc(title)}</b>{links}</nav>
<main>{body}</main><script>{SCRIPT}</script></body></html>"""


def main():
    parser = argparse.ArgumentParser(description="Pi context statistics as an HTML report.")
    parser.add_argument("theme", type=Path, help="theme JSON supplied by Nix")
    parser.add_argument("--since", help="only sessions started from this date (YYYY-MM-DD)")
    parser.add_argument("--project", help="only sessions whose directory contains this text")
    parser.add_argument("--out", type=Path, default=Path("/tmp/pi-stats.html"))
    args = parser.parse_args()

    theme = json.loads(args.theme.read_text())
    sessions, skipped = collect(args.since, args.project)
    if not sessions:
        raise SystemExit("No sessions found.")
    filters = " ".join(f for f in [args.project, args.since and f"since {args.since}"] if f)
    title = f"Pi stats {filters}".strip()
    args.out.write_text(report(sessions, skipped, theme, title))
    print(args.out)


if __name__ == "__main__":
    main()
