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
from functools import cache
from pathlib import Path

AGENT_DIR = Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent"))
# Image blocks carry base64 data; count each as a fixed size instead.
IMAGE_BYTES = 6000
CONTEXT_FILE = re.compile(
    r'<project_instructions path="([^"]+)">(.*?)</project_instructions>', re.DOTALL
)
# Context files Pi loads itself; the rest of project_context is added by docs.ts.
PI_CONTEXT_FILES = {"AGENTS.md", "CLAUDE.md"}
# How Pi lists each skill in the system prompt's skills section.
SKILL_TAG = "<skill>"
# How subagent.ts marks the parent's messages to a child, and the child's note tool.
PARENT_MESSAGE = "Message from the parent:"
NOTE_TOOL = "send_message"
# Run endings in subagent.ts, as labeled in the report.
OUTCOMES = {"idle": "Done", "budget": "Budget", "failed": "Failed", "aborted": "Stopped"}
TOP_PARTS = 15
TOP_RESULTS = 15
GROWTH_MIN_SESSIONS = 3
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


def merged(parts):
    # Context files from docs.ts as one part; Pi's own context files stay separate.
    result = defaultdict(float)
    for name, value in parts.items():
        group, _, item = name.partition(":")
        docs = group == "context" and Path(item).name not in PI_CONTEXT_FILES
        result["context:docs.ts" if docs else name] += value
    return result


def system_parts(state, cwd):
    parts = []
    for name, text in state["sections"].items():
        if name == "project_context":
            parts += context_parts(text, cwd)
        else:
            parts.append((f"system:{name}", size(text)))
    parts.extend((f"tool:{name}", length) for name, length in state["tools"].items())
    return parts


def calls_of(header, entries, agent):
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
        conversation = []
        for item in path:
            item_message = item.get("message") or {}
            if item_message.get("role") == "system":
                apply_system(state, item_message)
            elif item["id"] in edits:
                if edits[item["id"]] is not None:
                    conversation += message_parts(item, edits[item["id"]])
            else:
                if item["id"] not in measured:
                    measured[item["id"]] = message_parts(item)
                conversation += measured[item["id"]]
        if not state["sections"]:
            yield {"skipped": True}
            continue

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
        usage = compaction.get("usage") or {}
        consumed["conversation:compaction runs"] += sum(
            usage.get(key, 0) for key in ("input", "cacheRead", "cacheWrite", "output")
        )
    peak = max(calls, key=lambda c: c["prompt"])
    messages = [e.get("message") or {} for e in entries if e["type"] == "message"]
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


def collect(since, project):
    main_files = sorted(AGENT_DIR.glob("sessions/*/*.jsonl"))
    child_files = sorted(AGENT_DIR.glob("subagent-sessions/*.jsonl"))
    sessions = [(*read_session(path), False) for path in main_files]
    # Child session ID -> agent name and run endings, from the parents' subagent results and
    # messages. A run's end is delivered once, in a wait result or a message.
    agents, outcomes = {}, defaultdict(Counter)
    for _, entries, _ in sessions:
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
                    if ends and result.get("state") in OUTCOMES:
                        outcomes[result["sessionId"]][result["state"]] += 1
    sessions += [(*read_session(path), True) for path in child_files]

    found, results, skipped = [], [], 0
    for header, entries, child in sessions:
        if project and project not in header.get("cwd", ""):
            continue
        agent = agents.get(header.get("id"), "subagent") if child else "main"
        calls = []
        for call in calls_of(header, entries, agent):
            if call["skipped"]:
                skipped += 1
            else:
                calls.append(call)
        if not calls or (since and calls[0]["time"] < since):
            continue
        found.append(session_of(header, calls, agent, entries))
        found[-1]["outcomes"] = outcomes.get(header.get("id"), Counter())
        arguments = {
            block["id"]: block["arguments"]
            for e in entries
            for block in (e.get("message") or {}).get("content") or []
            if isinstance(block, dict) and block.get("type") == "toolCall"
        }
        for entry in entries:
            message = entry.get("message") or {}
            if message.get("role") != "toolResult":
                continue
            results.append(
                {
                    "agent": agent,
                    "tool": message["toolName"],
                    "bytes": text_size(message["content"]),
                    "error": bool(message.get("isError")),
                    "cwd": header.get("cwd", ""),
                    "time": entry["timestamp"],
                    "args": json.dumps(arguments.get(message.get("toolCallId"), {})),
                }
            )
    return found, results, skipped


# Rendering: an HTML page of tabs; charts are matplotlib SVG in the theme's colors.

TABS = {"overview": "Overview", "startup": "Startup", "session": "Session", "tools": "Tools"}
# Sessions offered after the averages in the Startup and Session selectors, newest first;
# averages use all of them.
SESSION_LIMIT = 30
# Parts listed per group in session tables, by consumption.
SESSION_PARTS = 8
# Chart groups and their theme colors, in stacking order; parts map to them by prefix.
CHART_GROUPS = {
    "tool results": "s",
    "tool calls": "p",
    "fixed": "m",
    "conversation": "f",
}
CHART_GROUP = {
    "system": "fixed",
    "context": "fixed",
    "tool": "fixed",
    "conversation": "conversation",
    "call": "tool calls",
    "result": "tool results",
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
const show = () => {
  const id = location.hash.slice(1) || document.querySelector("main > section").id;
  document.querySelectorAll("main > section").forEach(tab => { tab.hidden = tab.id !== id; });
  document.querySelectorAll("nav a").forEach(link => {
    link.toggleAttribute("aria-current", link.hash === "#" + id);
  });
};
addEventListener("hashchange", show);
show();
// Choosing an average or a session in one tab chooses it in the others too.
const choose = (select, value) => {
  select.value = value;
  select.parentElement.querySelectorAll(":scope > .panel").forEach(panel => {
    panel.hidden = panel.id !== value;
  });
};
const selects = document.querySelectorAll("select[data-panels]");
selects.forEach(select => {
  select.addEventListener("change", () => {
    const key = select.selectedOptions[0].dataset.key;
    selects.forEach(other => {
      const option = [...other.options].find(o => o.dataset.key === key);
      if (option) choose(other, option.value);
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


def kib(value):
    return f"{value / 1024:,.1f}"


def pct(value):
    return f"{100 * value:.1f}%"


def p90(values):
    return statistics.quantiles(values, n=10)[-1] if len(values) > 1 else values[0]


def group_of(part):
    return CHART_GROUP[part.split(":", 1)[0]]


def square(part, theme):
    return swatch(CHART_GROUPS[group_of(part)], theme)


def swatch(color_key, theme):
    return Markup(f'<span class="square" style="color:#{theme["colors"][color_key]}">■</span>')


def kpis(items):
    cells = "".join(f"<div><span>{esc(k)}</span><b>{esc(v)}</b></div>" for k, v in items)
    return f'<div class="kpis">{cells}</div>'


def table(headers, rows, cls=""):
    # rows: (cells, row class); cells are escaped unless wrapped in Markup.
    head = "".join(f"<th>{esc(h)}</th>" for h in headers)
    body = "".join(
        f'<tr class="{row_class}">{"".join(f"<td>{cell_html(c)}</td>" for c in cells)}</tr>'
        for cells, row_class in rows
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


def combo_chart(theme, labels, bars, lines, xlabel="", points=False, axis="own", marks=()):
    """Overlay-colored columns on the left axis and lines over them.

    bars: (label, values); lines: (label, values, color key, axis label or None).
    axis: "own" gives each line its own zero-based axis, the first labeled one on the right
    and the others hidden; "bars" draws the lines on the columns' axis, for the same unit;
    "lines" puts every line on one right axis, for lines sharing a unit apart from the bars.
    points draws unconnected markers instead, for categories rather than a sequence.
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
            line = {"linestyle": "none", "marker": "D"} if points else {}
            handles += axes.plot(
                range(len(values)), values, color=f"#{colors[color]}", label=label, **line
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


def overview_tab(sessions, calls, skipped, theme):
    prompt = sum(c["prompt"] for c in calls)
    main = [s for s in sessions if s["agent"] == "main"]
    ratio = statistics.median(c["bytes"] / c["prompt"] for c in calls)
    head = kpis(
        [
            ("sessions", len(main)),
            ("subagent runs", len(sessions) - len(main)),
            ("requests", len(calls)),
            ("input", num(prompt)),
            ("output", num(sum(c["output"] for c in calls))),
            ("cost", f"${sum(c['cost'] for c in calls):.2f}"),
            ("cache hit", f"{100 * sum(c['cache'] for c in calls) / prompt:.0f}%"),
            ("bytes/token", f"{ratio:.2f}"),
            ("skipped calls", skipped),
        ]
    )

    days = defaultdict(lambda: {"tokens": 0, "cost": 0, "sessions": set()})
    for call in calls:
        day = days[call["time"][:10]]
        day["tokens"] += call["prompt"] + call["output"]
        day["cost"] += call["cost"]
        day["sessions"].add(call["session"])
    labels = sorted(days)
    chart = combo_chart(
        theme,
        labels,
        ("Tokens", [days[d]["tokens"] for d in labels]),
        [
            ("Cost $", [days[d]["cost"] for d in labels], "s", "Cost $"),
            ("Sessions", [len(days[d]["sessions"]) for d in labels], "p", None),
        ],
        "Day",
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


def tools_tab(sessions, calls, results, theme):
    ratio = statistics.median(c["bytes"] / c["prompt"] for c in calls)
    main_calls = [c for c in calls if c["agent"] == "main"]
    by_tool = defaultdict(list)
    for result in results:
        by_tool[result["tool"]].append(result)
    declared = set().union(*(c["tools"] for c in main_calls)) if main_calls else set()
    order = sorted(
        set(by_tool) | declared, key=lambda t: -sum(r["bytes"] for r in by_tool.get(t, []))
    )
    rows, totals, counts = [], [], []
    for tool in order:
        items = by_tool.get(tool, [])
        sizes = [r["bytes"] / ratio for r in items] or [0]
        totals.append(sum(sizes))
        counts.append(len(items))
        rows.append(
            (
                [
                    tool,
                    len(items),
                    sum(r["error"] for r in items),
                    num(statistics.mean(sizes)),
                    num(p90(sizes)),
                    num(max(sizes)),
                    num(sum(sizes)),
                    kib(sum(r["bytes"] for r in items)),
                ],
                "" if items else "flag",
            )
        )
    tools = table(["Tool", "Calls", "Errors", "Avg", "P90", "Max", "Total", "KiB"], rows)
    chart = combo_chart(
        theme,
        order,
        ("Result tokens", totals),
        [("Calls", counts, "p", "Calls")],
        "Tool",
        points=True,
    )

    children = [s for s in sessions if s["agent"] != "main"]
    agents = ""
    if children:
        runs = defaultdict(list)
        for session in children:
            runs[session["agent"]].append(session)
        rows = []
        for agent, items in sorted(runs.items()):
            flat = [c for s in items for c in s["calls"]]
            ends = sum((s["outcomes"] for s in items), Counter())
            total = sum(ends.values())
            rows.append(
                (
                    [
                        agent,
                        len(items),
                        f"{len(flat) / len(items):.1f}",
                        num(statistics.mean(s["calls"][0]["prompt"] for s in items)),
                        num(sum(c["prompt"] for c in flat)),
                        num(sum(c["output"] for c in flat)),
                        f"${sum(s['cost'] for s in items):.2f}",
                        sum(s["notes"] for s in items),
                        sum(s["parent_messages"] for s in items),
                        *(ends[state] for state in OUTCOMES),
                        pct(ends["budget"] / total) if total else "",
                    ],
                    "",
                )
            )
        headers = [
            "Agent",
            "Sessions",
            "Requests/session",
            "Startup",
            "Input",
            "Output",
            "Cost",
            "Notes",
            "Parent messages",
            *OUTCOMES.values(),
            "Budget stops",
        ]
        agents = "<h2>Subagents</h2>" + table(headers, rows)

    rows = [
        (
            [
                r["tool"],
                num(r["bytes"] / ratio),
                kib(r["bytes"]),
                r["agent"],
                Path(r["cwd"]).name,
                r["time"][:16].replace("T", " "),
                r["args"][:PREVIEW],
            ],
            "",
        )
        for r in sorted(results, key=lambda r: -r["bytes"])[:TOP_RESULTS]
    ]
    largest = table(
        ["Tool", "Tokens", "KiB", "Agent", "Project", "Time", "Arguments"], rows, "text"
    )
    return tools + chart + agents + "<h2>Largest tool results</h2>" + largest


def startup_of(session):
    # The first call's parts before any conversation in tokens and bytes, and the counts of
    # its tools, context files (each file, before docs.ts files are merged), and skills.
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


def startup_kpis(tokens, sizes, counts):
    # Totals of a startup, or averages over several; counts averaged keep one decimal.
    return kpis(
        [
            ("startup tokens", num(sum(tokens.values()))),
            ("startup KiB", kib(sum(sizes.values()))),
            *[(name, f"{round(value, 1):g}") for name, value in counts.items()],
        ]
    )


def startup_table(theme, values, sizes, extra=None, limit=TOP_PARTS):
    # values: part -> tokens; sizes: part -> bytes;
    # extra: part -> one more cell (sessions seen), when given;
    # limit: parts listed per group before the rest folds into one row, None for all.
    total = sum(values.values()) or 1
    rows = []
    for key, (label, color) in STARTUP_GROUPS.items():
        items = sorted(
            ((name, tokens) for name, tokens in values.items() if name.split(":")[0] == key),
            key=lambda item: -item[1],
        )
        if not items:
            continue
        subtotal = sum(tokens for _, tokens in items)
        cells = [
            Markup(swatch(color, theme) + esc(label)),
            num(subtotal),
            pct(subtotal / total),
            kib(sum(sizes.get(name, 0) for name, _ in items)),
        ]
        rows.append(([*cells, ""] if extra else cells, "group"))
        shown, rest = (items[:limit], items[limit:]) if limit else (items, [])
        for name, tokens in shown:
            cells = [
                name.split(":", 1)[1],
                num(tokens),
                pct(tokens / total),
                kib(sizes.get(name, 0)),
            ]
            rows.append(([*cells, extra[name]] if extra else cells, "part"))
        if rest:
            tokens = sum(t for _, t in rest)
            cells = [
                f"other ({len(rest)})",
                num(tokens),
                pct(tokens / total),
                kib(sum(sizes.get(name, 0) for name, _ in rest)),
            ]
            rows.append(([*cells, ""] if extra else cells, "part"))
    headers = ["Part", "Tokens", "Share", "KiB"] + (["Sessions"] if extra else [])
    return table(headers, rows)


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


def startup_average(items, theme):
    # Every session start of one agent, averaged; a part missing from a start counts as 0.
    starts = list(map(startup_of, items))
    totals, seen, size_totals = defaultdict(float), defaultdict(int), defaultdict(float)
    for fixed, sizes, _ in starts:
        for name, tokens in fixed.items():
            totals[name] += tokens / len(starts)
            size_totals[name] += sizes.get(name, 0) / len(starts)
            seen[name] += 1
    counts = {name: statistics.mean(c[name] for _, _, c in starts) for name in starts[0][2]}
    # Stacked from the bottom in prompt order, labeled with the group names.
    history = stacked_chart(
        theme,
        [s["time"][:10] for s in items],
        [
            {
                label: sum(t for n, t in fixed.items() if n.split(":")[0] == key)
                for key, (label, _) in STARTUP_GROUPS.items()
            }
            for fixed, _, _ in starts
        ],
        "Startup tokens",
        "Session",
        groups=dict(STARTUP_GROUPS.values()),
    )
    return (
        startup_kpis(totals, size_totals, counts)
        + history
        + startup_table(theme, totals, size_totals, seen)
    )


def startup_single(session, theme):
    fixed, sizes, counts = startup_of(session)
    return (
        startup_kpis(fixed, sizes, counts)
        + startup_bar(theme, fixed)
        + startup_table(theme, fixed, sizes, limit=None)
    )


def startup_tab(sessions, theme):
    return panels_tab(sessions, "startup", startup_average, startup_single, theme)


def shares(parts):
    total = sum(parts.values()) or 1
    return {name: tokens / total for name, tokens in parts.items()}


def mean_shares(calls):
    # Each call's context shares, averaged with equal weight per call.
    totals = defaultdict(float)
    for call in calls:
        for name, share in shares(merged(call["parts"])).items():
            totals[name] += share / len(calls)
    return totals


def mean_sizes(calls):
    # Each part's bytes, averaged over the calls.
    totals = defaultdict(float)
    for call in calls:
        for name, value in merged(call["sizes"]).items():
            totals[name] += value / len(calls)
    return totals


def ratio(consumption, context):
    return f"{consumption / context:.1f}x" if context else "-"


def session_table(theme, context, consumption, sizes, context_label):
    # Parts grouped by GROUPS: context share, consumption share, their ratio, and size.
    rows = []
    for key, label in GROUPS.items():
        names = sorted(
            {n for n in (*context, *consumption) if n.split(":")[0] == key},
            key=lambda n: -consumption.get(n, 0),
        )
        if not names:
            continue
        ctx = sum(context.get(n, 0) for n in names)
        cons = sum(consumption.get(n, 0) for n in names)
        name = Markup(square(f"{key}:", theme) + esc(label))
        group_size = kib(sum(sizes.get(n, 0) for n in names))
        rows.append(([name, pct(ctx), pct(cons), ratio(cons, ctx), group_size], "group"))
        for n in names[:SESSION_PARTS]:
            ctx, cons = context.get(n, 0), consumption.get(n, 0)
            cells = [n.split(":", 1)[1], pct(ctx), pct(cons), ratio(cons, ctx)]
            rows.append(([*cells, kib(sizes.get(n, 0))], "part"))
        rest = names[SESSION_PARTS:]
        if rest:
            ctx = sum(context.get(n, 0) for n in rest)
            cons = sum(consumption.get(n, 0) for n in rest)
            cells = [f"other ({len(rest)})", pct(ctx), pct(cons), ratio(cons, ctx)]
            rows.append(([*cells, kib(sum(sizes.get(n, 0) for n in rest))], "part"))
    return table(["Part", context_label, "Consumption", "Ratio", "KiB"], rows)


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
        + session_table(
            theme, mean_shares(calls), shares(merged(consumed)), mean_sizes(calls), "Context"
        )
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
        + session_table(
            theme,
            shares(merged(peak["parts"])),
            shares(merged(session["consumed"])),
            merged(peak["sizes"]),
            "Peak context",
        )
    )


def session_tab(sessions, theme):
    return panels_tab(sessions, "session", session_average, session_single, theme)


def panels_tab(sessions, prefix, average, single, theme):
    # One selector: an average per agent, then the newest sessions. Panel IDs carry the tab
    # prefix; option keys do not, so choosing a session selects it in every tab.
    by_agent = defaultdict(list)
    for session in sorted(sessions, key=lambda s: s["time"]):
        by_agent[session["agent"]].append(session)
    averages = [
        (f"avg-{agent}", f"{agent} · {len(items)} sessions", average(items, theme))
        for agent, items in sorted(by_agent.items(), key=lambda kv: (kv[0] != "main", kv[0]))
    ]
    newest = sorted(sessions, key=lambda s: s["time"], reverse=True)[:SESSION_LIMIT]
    singles = [(f"s-{s['id']}", session_label(s), single(s, theme)) for s in newest]
    return selector(prefix, [("Averages", averages), ("Sessions", singles)])


def session_label(session):
    return (
        f"{session['time'][:16].replace('T', ' ')} · {Path(session['cwd']).name}"
        f" · {session['agent']} · {len(session['calls'])} requests"
        f" · peak {num(session['peak'])}"
    )


def selector(prefix, groups):
    # A select over grouped panels (key, label, content); the first panel is shown.
    panels = [panel for _, items in groups for panel in items]
    options = "".join(
        f'<optgroup label="{esc(group)}">'
        + "".join(
            f'<option value="{esc(prefix)}-{esc(key)}" data-key="{esc(key)}">{esc(label)}</option>'
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


def report(sessions, results, skipped, theme, title):
    calls = [call for session in sessions for call in session["calls"]]
    tabs = {
        "overview": overview_tab(sessions, calls, skipped, theme),
        "startup": startup_tab(sessions, theme),
        "session": session_tab(sessions, theme),
        "tools": tools_tab(sessions, calls, results, theme),
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
    sessions, results, skipped = collect(args.since, args.project)
    if not sessions:
        raise SystemExit("No sessions found.")
    filters = " ".join(f for f in [args.project, args.since and f"since {args.since}"] if f)
    title = f"Pi stats {filters}".strip()
    args.out.write_text(report(sessions, results, skipped, theme, title))
    print(args.out)


if __name__ == "__main__":
    main()
