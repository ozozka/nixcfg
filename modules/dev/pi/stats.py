"""Pi context statistics: what each model call contained, rebuilt from Pi's session files.

Usage: stats.py THEME PI [--since YYYY-MM-DD] [--project TEXT] [--out FILE]

Each assistant message is one model call. Its context is the path from the session root to
that message: system messages patch the prompt sections and tool declarations, the latest
compaction replaces older entries with its summary and prompt checkpoint, and context edits
replace or drop entries. Parts are measured in characters; their tokens are the part's share
of the call's real prompt tokens (input + cache read + cache write) from the response usage.

Output tokens are split over the response's own text, thinking, and tool calls the same way;
reported reasoning tokens go to thinking. A session's consumption is the sum of its calls'
prompt and output parts, so a part sent with every call weighs more than its context share.

Subagent sessions live in subagent-sessions/; parent tool results record their session IDs.
THEME is a JSON file of colors, fonts, and sizes supplied by Nix; PI is the Pi executable,
used to read model context windows.
"""

import argparse
import html
import io
import json
import os
import re
import statistics
import subprocess
from collections import defaultdict
from functools import cache
from pathlib import Path

AGENT_DIR = Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".pi/agent"))
# Image blocks carry base64 data; count each as a fixed size instead.
IMAGE_CHARS = 6000
CONTEXT_FILE = re.compile(
    r'<project_instructions path="([^"]+)">(.*?)</project_instructions>', re.DOTALL
)
# Context files Pi loads itself; the rest of project_context is added by docs.ts.
PI_CONTEXT_FILES = {"AGENTS.md", "CLAUDE.md"}
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


def text_chars(content):
    if isinstance(content, str):
        return len(content)
    return sum(
        IMAGE_CHARS if block.get("type") == "image" else len(block.get("text", ""))
        for block in content
    )


def message_parts(entry, content=None):
    # (part, chars) for one context entry; content overrides it after a context edit.
    if entry["type"] == "compaction":
        return [("conversation:compaction summary", len(entry["summary"]))]
    if entry["type"] == "branch_summary":
        return [("conversation:branch summary", len(entry.get("summary", "")))]
    if entry["type"] == "custom_message":
        return [(f"conversation:custom {entry['customType']}", text_chars(entry["content"]))]
    if entry["type"] != "message":
        return []
    message = entry["message"]
    content = message.get("content") if content is None else content
    role = message["role"]
    if role == "user":
        return [("conversation:user", text_chars(content))]
    if role == "toolResult":
        return [(f"result:{message['toolName']}", text_chars(content))]
    if role != "assistant":
        return []
    if isinstance(content, str):
        return [("conversation:assistant", len(content))]
    parts = []
    for block in content:
        kind = block.get("type")
        if kind == "text":
            parts.append(("conversation:assistant", len(block["text"])))
        elif kind == "thinking":
            parts.append(("conversation:thinking", len(block.get("thinking", ""))))
        elif kind == "toolCall":
            parts.append((f"call:{block['name']}", len(json.dumps(block["arguments"]))))
    return parts


def output_parts(message):
    # The response's output tokens split over its own blocks; reasoning tokens go to thinking.
    usage = message["usage"]
    output = usage.get("output", 0)
    reasoning = min(usage.get("reasoning", 0) or 0, output)
    parts = defaultdict(int)
    for name, chars in message_parts({"type": "message", "message": message}):
        parts[name] += chars
    chars = sum(parts.values())
    if not chars:
        return {"conversation:thinking": output} if output else {}
    shares = {name: (output - reasoning) * value / chars for name, value in parts.items()}
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
        state["tools"][tool["name"]] = len(json.dumps(tool))
    for tool in message.get("toolsRemoved") or []:
        state["tools"].pop(tool["name"], None)


def context_file_name(path, cwd):
    if cwd and path.startswith(cwd.rstrip("/") + "/"):
        return path[len(cwd.rstrip("/")) + 1 :]
    return path.replace(str(Path.home()), "~")


@cache
def context_parts(text, cwd):
    # The project_context section split into its files and the wrapper text around them.
    # Pi's own context files stay separate; everything else comes from docs.ts, as one part.
    files = CONTEXT_FILE.findall(text)
    parts = [
        (
            f"context:{context_file_name(path, cwd)}"
            if Path(path).name in PI_CONTEXT_FILES
            else "context:docs.ts",
            len(body),
        )
        for path, body in files
    ]
    wrapper = len(text) - sum(len(body) for _, body in files)
    return [*parts, ("system:project_context", wrapper)]


def system_parts(state, cwd):
    parts = []
    for name, text in state["sections"].items():
        if name == "project_context":
            parts += context_parts(text, cwd)
        else:
            parts.append((f"system:{name}", len(text)))
    parts.extend((f"tool:{name}", chars) for name, chars in state["tools"].items())
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
        for name, chars in system_parts(state, header.get("cwd")) + conversation:
            parts[name] += chars
        chars = sum(parts.values()) or 1
        yield {
            "skipped": False,
            "session": header.get("id"),
            "agent": agent,
            "cwd": header.get("cwd", ""),
            "time": entry["timestamp"],
            "model": message.get("model"),
            "mode": mode or "free",
            "prompt": prompt,
            "chars": chars,
            "output": usage.get("output", 0),
            "cache": usage.get("cacheRead", 0),
            "cost": (usage.get("cost") or {}).get("total", 0),
            "tools": set(state["tools"]),
            "parts": {name: value / chars * prompt for name, value in parts.items()},
            "out": output_parts(message),
        }


def model_windows(pi):
    # Context window by model ID, from the table `pi --list-models` prints.
    windows = {}
    units = {"K": 1e3, "M": 1e6}
    output = subprocess.run([pi, "--list-models"], capture_output=True, text=True, check=False)
    for line in output.stdout.splitlines()[1:]:
        fields = line.split()
        if len(fields) >= 3 and fields[2][-1] in units:
            windows[fields[1]] = round(float(fields[2][:-1]) * units[fields[2][-1]])
    return windows


def session_of(header, calls, agent, entries, windows):
    # Session totals; consumption sums every call's prompt parts and output parts.
    consumed = defaultdict(float)
    for index, call in enumerate(calls):
        call["index"] = index
        call["window"] = windows.get(call["model"])
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
    return {
        "id": header.get("id"),
        "agent": agent,
        "cwd": header.get("cwd", ""),
        "time": calls[0]["time"],
        "model": peak["model"],
        "calls": calls,
        "peak": peak["prompt"],
        "fill": peak["prompt"] / peak["window"] if peak["window"] else None,
        "consumed": dict(consumed),
        "compactions": len(compactions),
        # The first call after each compaction.
        "marks": [
            next((c["index"] for c in calls if c["time"] > e["timestamp"]), len(calls) - 1)
            for e in compactions
        ],
        "cost": sum(c["cost"] for c in calls),
    }


def collect(since, project, windows):
    main_files = sorted(AGENT_DIR.glob("sessions/*/*.jsonl"))
    child_files = sorted(AGENT_DIR.glob("subagent-sessions/*.jsonl"))
    sessions = [(*read_session(path), False) for path in main_files]
    # Child session ID -> agent name, from the parents' subagent results.
    agents = {}
    for _, entries, _ in sessions:
        for entry in entries:
            message = entry.get("message") or {}
            if message.get("toolName") == "subagent":
                for result in (message.get("details") or {}).get("results", []):
                    if result.get("sessionId"):
                        agents[result["sessionId"]] = result["agent"]
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
        found.append(session_of(header, calls, agent, entries, windows))
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
                    "chars": text_chars(message["content"]),
                    "error": bool(message.get("isError")),
                    "cwd": header.get("cwd", ""),
                    "time": entry["timestamp"],
                    "args": json.dumps(arguments.get(message.get("toolCallId"), {})),
                }
            )
    return found, results, skipped


# Rendering: an HTML page of tabs; charts are matplotlib SVG in the theme's colors.

TABS = {"overview": "Overview", "startup": "Startup", "session": "Session", "tools": "Tools"}
# Sessions offered in the Session tab's selector, newest first; averages use all of them.
SESSION_LIMIT = 30
# Parts listed per group in session tables, by consumption.
SESSION_PARTS = 8
# Parts compared in the context vs consumption chart, by consumption.
TOP_PAIRS = 15
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
# Startup groups: the parts of a call before any conversation, and their theme colors.
STARTUP_GROUPS = {
    "context": ("context files", "s"),
    "tool": ("tool definitions", "p"),
    "system": ("system prompt", "m"),
}
BAR_WIDTH = 0.72
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
.split {{ display:grid; grid-template-columns:minmax(0, 1fr) minmax(0, 1fr);
  gap:{dim["m"]}px; align-items:start; }}
@media (max-width:{dim["h"] * 3}px) {{ .split {{ grid-template-columns:1fr; }} }}
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


def composition_chart(theme, columns, groups=CHART_GROUPS):
    # 100% stacked areas of the groups per column, without axes; tables carry the legend.
    # groups: group name -> theme color key, in stacking order.
    colors = theme["colors"]

    def draw(figure):
        axes = figure.subplots()
        totals = [sum(column.values()) or 1 for column in columns]
        axes.stackplot(
            range(len(columns)),
            *[
                [
                    100 * column.get(group, 0) / total
                    for column, total in zip(columns, totals, strict=True)
                ]
                for group in groups
            ],
            colors=[f"#{colors[key]}" for key in groups.values()],
            step="mid",
        )
        axes.set_ylim(0, 100)
        axes.set_xlim(-0.5, len(columns) - 0.5)
        axes.set_axis_off()

    return render(theme, draw, size=(8, 4))


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
    ratio = statistics.median(c["chars"] / c["prompt"] for c in calls)
    head = kpis(
        [
            ("sessions", len(main)),
            ("subagent runs", len(sessions) - len(main)),
            ("calls", len(calls)),
            ("prompt", num(prompt)),
            ("output", num(sum(c["output"] for c in calls))),
            ("cost", f"${sum(c['cost'] for c in calls):.2f}"),
            ("cache hit", f"{100 * sum(c['cache'] for c in calls) / prompt:.0f}%"),
            ("chars/token", f"{ratio:.2f}"),
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
    models_table = table(["Model", "Calls", "Prompt", "Output", "Cost", "Cache"], rows)
    return head + chart + models_table


def tools_tab(sessions, calls, results, theme):
    ratio = statistics.median(c["chars"] / c["prompt"] for c in calls)
    main_calls = [c for c in calls if c["agent"] == "main"]
    by_tool = defaultdict(list)
    for result in results:
        by_tool[result["tool"]].append(result)
    declared = set().union(*(c["tools"] for c in main_calls)) if main_calls else set()
    order = sorted(
        set(by_tool) | declared, key=lambda t: -sum(r["chars"] for r in by_tool.get(t, []))
    )
    rows, totals, counts = [], [], []
    for tool in order:
        items = by_tool.get(tool, [])
        sizes = [r["chars"] / ratio for r in items] or [0]
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
                ],
                "" if items else "flag",
            )
        )
    tools = table(["Tool", "Calls", "Errors", "Avg", "P90", "Max", "Total"], rows)
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
                    ],
                    "",
                )
            )
        headers = ["Agent", "Runs", "Calls/run", "Startup", "Prompt", "Output", "Cost"]
        agents = "<h2>Subagents</h2>" + table(headers, rows)

    rows = [
        (
            [
                r["tool"],
                num(r["chars"] / ratio),
                r["agent"],
                Path(r["cwd"]).name,
                r["time"][:16].replace("T", " "),
                r["args"][:PREVIEW],
            ],
            "",
        )
        for r in sorted(results, key=lambda r: -r["chars"])[:TOP_RESULTS]
    ]
    largest = table(["Tool", "Tokens", "Agent", "Project", "Time", "Arguments"], rows, "text")
    return tools + chart + agents + "<h2>Largest tool results</h2>" + largest


def startup_of(session):
    # The first call's parts before any conversation, and the user's first message.
    parts = session["calls"][0]["parts"]
    fixed = {
        name: tokens for name, tokens in parts.items() if name.split(":")[0] in STARTUP_GROUPS
    }
    return fixed, parts.get("conversation:user", 0)


def startup_kpis(totals, user, window):
    by_group = defaultdict(float)
    for name, tokens in totals.items():
        by_group[name.split(":")[0]] += tokens
    total = sum(totals.values())
    return kpis(
        [
            ("startup", num(total)),
            *[(label, num(by_group[key])) for key, (label, _) in STARTUP_GROUPS.items()],
            ("first message", num(user)),
            ("of window", pct(total / window) if window else "-"),
        ]
    )


def startup_table(theme, values, extra=None):
    # values: part -> tokens; extra: part -> one more cell (sessions seen), when given.
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
        ]
        rows.append(([*cells, ""] if extra else cells, "group"))
        shown, rest = items[:TOP_PARTS], items[TOP_PARTS:]
        for name, tokens in shown:
            cells = [name.split(":", 1)[1], num(tokens), pct(tokens / total)]
            rows.append(([*cells, extra[name]] if extra else cells, "part"))
        if rest:
            tokens = sum(t for _, t in rest)
            cells = [f"other ({len(rest)})", num(tokens), pct(tokens / total)]
            rows.append(([*cells, ""] if extra else cells, "part"))
    headers = ["Part", "Tokens", "Share"] + (["Sessions"] if extra else [])
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


def startup_tab(sessions, theme):
    by_agent = defaultdict(list)
    for session in sorted(sessions, key=lambda s: s["time"]):
        by_agent[session["agent"]].append(session)
    agents = sorted(by_agent, key=lambda a: (a != "main", a))

    # Average: every session start of each agent.
    panels = []
    for agent in agents:
        items = by_agent[agent]
        starts = [startup_of(s) for s in items]
        totals, seen = defaultdict(float), defaultdict(int)
        for fixed, _ in starts:
            for name, tokens in fixed.items():
                totals[name] += tokens / len(starts)
                seen[name] += 1
        user = statistics.mean(u for _, u in starts)
        windows = [s["calls"][0]["window"] for s in items if s["calls"][0]["window"]]
        columns = [
            {
                key: sum(t for n, t in fixed.items() if n.split(":")[0] == key)
                for key in STARTUP_GROUPS
            }
            for fixed, _ in starts
        ]
        groups = {key: color for key, (_, color) in STARTUP_GROUPS.items()}
        labels = [s["time"][:10] for s in items]
        history = combo_chart(
            theme,
            labels,
            ("Startup tokens", [sum(f.values()) for f, _ in starts]),
            [
                (label, [c[key] for c in columns], color, None)
                for key, (label, color) in STARTUP_GROUPS.items()
            ],
            "Session",
            axis="bars",
        )
        panels.append(
            (
                f"average-{agent}",
                f"{agent} · {len(items)} sessions",
                startup_kpis(totals, user, statistics.mean(windows) if windows else None)
                + '<div class="split">'
                + startup_table(theme, totals, seen)
                + composition_chart(theme, columns, groups)
                + "</div>"
                + history,
            )
        )
    average = selector(panels)

    # Selected: the latest session start of each project and agent.
    latest = {}
    for session in sorted(sessions, key=lambda s: s["time"]):
        latest[(Path(session["cwd"]).name, session["agent"])] = session
    panels = []
    for (project, agent), session in sorted(
        latest.items(), key=lambda kv: kv[1]["time"], reverse=True
    ):
        fixed, user = startup_of(session)
        panels.append(
            (
                f"start-{session['id']}",
                f"{project} · {agent} · {session['time'][:10]}",
                startup_kpis(fixed, user, session["calls"][0]["window"])
                + startup_bar(theme, fixed)
                + startup_table(theme, fixed),
            )
        )
    return "<h2>Average</h2>" + average + "<h2>Selected</h2>" + selector(panels)


def shares(parts):
    total = sum(parts.values()) or 1
    return {name: tokens / total for name, tokens in parts.items()}


def mean_shares(calls):
    # Each call's context shares, averaged with equal weight per call.
    totals = defaultdict(float)
    for call in calls:
        for name, share in shares(call["parts"]).items():
            totals[name] += share / len(calls)
    return totals


def ratio(consumption, context):
    return f"{consumption / context:.1f}x" if context else "-"


def session_table(theme, context, consumption, context_label):
    # Parts grouped by GROUPS: context share, consumption share, and their ratio.
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
        rows.append(([name, pct(ctx), pct(cons), ratio(cons, ctx)], "group"))
        for n in names[:SESSION_PARTS]:
            ctx, cons = context.get(n, 0), consumption.get(n, 0)
            rows.append(([n.split(":", 1)[1], pct(ctx), pct(cons), ratio(cons, ctx)], "part"))
        rest = names[SESSION_PARTS:]
        if rest:
            ctx = sum(context.get(n, 0) for n in rest)
            cons = sum(consumption.get(n, 0) for n in rest)
            rows.append(
                ([f"other ({len(rest)})", pct(ctx), pct(cons), ratio(cons, ctx)], "part")
            )
    return table(["Part", context_label, "Consumption", "Ratio"], rows)


def pairs_chart(theme, context, consumption):
    # Context share against consumption share for the most consumed parts.
    colors = theme["colors"]
    names = sorted(consumption, key=lambda n: -consumption[n])[:TOP_PAIRS][::-1]

    def draw(figure):
        axes = figure.subplots()
        rows = range(len(names))
        height = BAR_WIDTH / 2
        axes.barh(
            [r + height / 2 for r in rows],
            [100 * context.get(n, 0) for n in names],
            height=height,
            color=f"#{colors['m']}",
            label="Context %",
        )
        axes.barh(
            [r - height / 2 for r in rows],
            [100 * consumption[n] for n in names],
            height=height,
            color=f"#{colors['p']}",
            label="Consumption %",
        )
        axes.set_yticks(list(rows), [n.replace(":", " ") for n in names])
        axes.set_xlabel("Share %")
        axes.legend(loc="lower right", framealpha=1)

    return render(theme, draw, size=(16, 0.4 * len(names) + 1))


def session_tab(sessions, theme):
    ordered = sorted(sessions, key=lambda s: s["time"])
    by_agent = defaultdict(list)
    for session in ordered:
        by_agent[session["agent"]].append(session)

    # Average: all sessions of each agent.
    panels = []
    for agent in sorted(by_agent, key=lambda a: (a != "main", a)):
        items = by_agent[agent]
        calls = [c for s in items for c in s["calls"]]
        consumed = defaultdict(float)
        for session in items:
            for name, tokens in session["consumed"].items():
                consumed[name] += tokens
        fills = [s["fill"] for s in items if s["fill"]]
        head = kpis(
            [
                ("sessions", len(items)),
                ("avg calls", f"{len(calls) / len(items):.0f}"),
                ("avg peak", num(statistics.mean(s["peak"] for s in items))),
                ("avg peak fill", pct(statistics.mean(fills)) if fills else "-"),
                ("avg consumed", num(sum(consumed.values()) / len(items))),
                ("avg cost", f"${statistics.mean(s['cost'] for s in items):.2f}"),
            ]
        )
        columns = [grouped(s["consumed"]) for s in items]
        labels = [s["time"][:10] for s in items]
        history = combo_chart(
            theme,
            labels,
            ("Consumed tokens", [sum(s["consumed"].values()) for s in items]),
            [
                (
                    "Peak context %",
                    [100 * (s["fill"] or 0) for s in items],
                    "s",
                    "Peak context %",
                ),
                ("Calls", [len(s["calls"]) for s in items], "p", None),
            ],
            "Session",
        )
        median, high, running = [], [], []
        for i in range(max(len(s["calls"]) for s in items)):
            at = [s["calls"][i]["prompt"] for s in items if len(s["calls"]) > i]
            if len(at) < GROWTH_MIN_SESSIONS:
                break
            running.append(len(at))
            median.append(statistics.median(at))
            high.append(p90(at))
        growth = (
            combo_chart(
                theme,
                [str(i + 1) for i in range(len(running))],
                ("Sessions", running),
                [
                    ("Median prompt", median, "p", "Prompt tokens"),
                    ("P90 prompt", high, "s", None),
                ],
                "Call",
                axis="lines",
            )
            if running
            else ""
        )
        panels.append(
            (
                f"sessions-{agent}",
                f"{agent} · {len(items)} sessions",
                head
                + '<div class="split">'
                + session_table(theme, mean_shares(calls), shares(consumed), "Context")
                + composition_chart(theme, columns)
                + "</div>"
                + history
                + growth,
            )
        )
    average = selector(panels)

    # Selected: the newest sessions, one at a time.
    panels = []
    for session in ordered[::-1][:SESSION_LIMIT]:
        calls = session["calls"]
        peak = max(calls, key=lambda c: c["prompt"])
        consumption = shares(session["consumed"])
        context = shares(peak["parts"])
        head = kpis(
            [
                ("calls", len(calls)),
                ("peak context", num(session["peak"])),
                ("peak fill", pct(session["fill"]) if session["fill"] else "-"),
                ("consumed", num(sum(session["consumed"].values()))),
                ("output", num(sum(c["output"] for c in calls))),
                ("cost", f"${session['cost']:.2f}"),
                ("compactions", session["compactions"]),
            ]
        )
        per_call = [grouped(c["parts"]) for c in calls]
        tokens = combo_chart(
            theme,
            [str(c["index"] + 1) for c in calls],
            ("Prompt tokens", [c["prompt"] for c in calls]),
            [
                (group, [column.get(group, 0) for column in per_call], color, None)
                for group, color in CHART_GROUPS.items()
            ],
            "Call",
            axis="bars",
            marks=session["marks"],
        )
        label = (
            f"{session['time'][:16].replace('T', ' ')} · {Path(session['cwd']).name}"
            f" · {session['agent']} · {len(calls)} calls"
            + (f" · peak {pct(session['fill'])}" if session["fill"] else "")
        )
        panels.append(
            (
                f"session-{session['id']}",
                label,
                head
                + '<div class="split">'
                + session_table(theme, context, consumption, "Peak context")
                + composition_chart(theme, per_call)
                + "</div>"
                + tokens
                + pairs_chart(theme, context, consumption),
            )
        )
    return "<h2>Average</h2>" + average + "<h2>Selected</h2>" + selector(panels)


def selector(panels):
    # A select over panels (id, label, content); the first is shown.
    options = "".join(
        f'<option value="{esc(i)}">{esc(label)}</option>' for i, label, _ in panels
    )
    shown = "".join(
        f'<div class="panel" id="{esc(i)}"{" hidden" if n else ""}>{content}</div>'
        for n, (i, _, content) in enumerate(panels)
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
    parser.add_argument("pi", help="Pi executable, for model context windows")
    parser.add_argument("--since", help="only sessions started from this date (YYYY-MM-DD)")
    parser.add_argument("--project", help="only sessions whose directory contains this text")
    parser.add_argument("--out", type=Path, default=Path("/tmp/pi-stats.html"))
    args = parser.parse_args()

    theme = json.loads(args.theme.read_text())
    sessions, results, skipped = collect(args.since, args.project, model_windows(args.pi))
    if not sessions:
        raise SystemExit("No sessions found.")
    filters = " ".join(f for f in [args.project, args.since and f"since {args.since}"] if f)
    title = f"Pi stats {filters}".strip()
    args.out.write_text(report(sessions, results, skipped, theme, title))
    print(args.out)


if __name__ == "__main__":
    main()
