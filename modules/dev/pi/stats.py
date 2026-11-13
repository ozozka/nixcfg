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
    files = CONTEXT_FILE.findall(text)
    parts = [(f"context:{context_file_name(path, cwd)}", len(body)) for path, body in files]
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


# Rendering


def esc(value):
    return html.escape(str(value))


def num(value, digits=0):
    if value >= 1e6:
        return f"{value / 1e6:.1f}M"
    if value >= 1e4:
        return f"{value / 1e3:.0f}k"
    return f"{value:,.{digits}f}"


def p90(values):
    return statistics.quantiles(values, n=10)[-1] if len(values) > 1 else values[0]


def table(headers, rows, bar=None, cls=""):
    # rows: lists of cells; bar: (column index, maximum) drawn behind that cell.
    head = "".join(f"<th>{esc(h)}</th>" for h in headers)
    body = []
    for row, row_class in rows:
        cells = []
        for i, cell in enumerate(row):
            style = ""
            if bar and i == bar[0] and bar[1]:
                width = 100 * float(str(cell).rstrip("%")) / bar[1]
                style = f' style="--w:{width:.1f}%" class="bar"'
            cells.append(f"<td{style}>{esc(cell)}</td>")
        body.append(f'<tr class="{row_class}">{"".join(cells)}</tr>')
    return f'<table class="{cls}"><tr>{head}</tr>{"".join(body)}</table>'


def line_chart(series):
    # series: (label, color, [values by call number]); a plain SVG polyline per series.
    width, height, pad = 640, 220, 36
    top = max((max(v) for _, _, v in series if v), default=1)
    count = max((len(v) for _, _, v in series), default=1)

    def x(i):
        return pad + i * (width - 2 * pad) / max(count - 1, 1)

    def y(v):
        return height - pad - v * (height - 2 * pad) / top

    lines = [
        f'<line x1="{pad}" y1="{height - pad}" x2="{width - pad}" y2="{height - pad}"/>',
        f'<text x="{pad}" y="{pad - 8}">{num(top)}</text>',
        f'<text x="{width - pad}" y="{height - 12}" text-anchor="end">{count}</text>',
    ]
    for i, (label, color, values) in enumerate(series):
        points = " ".join(f"{x(j):.1f},{y(v):.1f}" for j, v in enumerate(values))
        lines.append(f'<polyline points="{points}" fill="none" stroke="#{color}"/>')
        lines.append(
            f'<text x="{width - pad}" y="{pad + 16 * i}" text-anchor="end" fill="#{color}">{esc(label)}</text>'
        )
    return f'<svg viewBox="0 0 {width} {height}" class="chart">{"".join(lines)}</svg>'


def style(theme):
    c, size, dim = theme["colors"], theme["fontSize"], theme["dim"]
    return f"""
:root {{ --p:#{c["p"]}; --s:#{c["s"]}; --f:#{c["f"]}; --m:#{c["m"]}; --o:#{c["o"]}; --b:#{c["b"]}; }}
body {{ background:var(--b); color:var(--f); font:{size["m"]}px "{theme["fonts"]["sans"]}";
  margin:{dim["m"]}px; }}
h1 {{ font-size:{size["x"]}px; margin:0 0 {dim["s"]}px; }}
h2 {{ font-size:{size["l"]}px; color:var(--p); margin:{dim["m"]}px 0 {dim["s"]}px; }}
.kpis {{ display:flex; flex-wrap:wrap; gap:{dim["s"]}px; }}
.kpi {{ background:var(--o); padding:{dim["s"]}px; min-width:{dim["x"]}px; }}
.kpi b {{ display:block; font:{size["h"]}px "{theme["fonts"]["mono"]}"; color:var(--p); }}
.kpi span, th, .muted {{ color:var(--m); }}
table {{ border-collapse:collapse; font-family:"{theme["fonts"]["mono"]}"; }}
th, td {{ text-align:right; padding:{dim["t"]}px {dim["s"]}px; white-space:nowrap; }}
th:first-child, td:first-child {{ text-align:left; }}
tr {{ border-bottom:1px solid var(--o); }}
tr.group td {{ color:var(--p); font-weight:bold; }}
tr.part td:first-child {{ padding-left:{dim["m"]}px; }}
tr.flag td {{ color:var(--s); }}
table.text td:last-child {{ text-align:left; }}
td.bar {{ min-width:{dim["x"]}px; --c:color-mix(in srgb, var(--p) 35%, transparent);
  background:linear-gradient(90deg, var(--c) var(--w), transparent var(--w)); }}
td.wrap {{ white-space:normal; }}
.chart {{ width:{dim["h"] * 2}px; max-width:100%; font:{size["s"]}px "{theme["fonts"]["mono"]}"; }}
.chart line {{ stroke:var(--m); }} .chart text {{ fill:var(--m); }}
.chart polyline {{ stroke-width:2; }}
"""


def report(calls, results, skipped, theme, title):
    main = [c for c in calls if c["agent"] == "main"]
    children = [c for c in calls if c["agent"] != "main"]
    prompt = sum(c["prompt"] for c in calls)
    ratio = statistics.median(c["chars"] / c["prompt"] for c in calls)
    kpis = [
        ("sessions", len({c["session"] for c in main})),
        ("subagent runs", len({c["session"] for c in children})),
        ("calls", len(calls)),
        ("prompt tokens", num(prompt)),
        ("output tokens", num(sum(c["output"] for c in calls))),
        ("cost", f"${sum(c['cost'] for c in calls):.2f}"),
        ("cache hit", f"{100 * sum(c['cache'] for c in calls) / prompt:.0f}%"),
        ("avg prompt", num(prompt / len(calls))),
        ("chars/token", f"{ratio:.2f}"),
        ("skipped calls", skipped),
    ]
    html_kpis = "".join(
        f'<div class="kpi"><b>{esc(v)}</b><span>{esc(k)}</span></div>' for k, v in kpis
    )

    # Average main call, by part, grouped.
    sections = []
    if main:
        totals = defaultdict(float)
        for call in main:
            for name, tokens in call["parts"].items():
                totals[name] += tokens / len(main)
        average = sum(totals.values())
        groups = defaultdict(list)
        for name, tokens in totals.items():
            groups[name.split(":", 1)[0]].append((name.split(":", 1)[1], tokens))
        rows = []
        for group, label in GROUPS.items():
            items = sorted(groups.get(group, []), key=lambda item: -item[1])
            subtotal = sum(t for _, t in items)
            if not items:
                continue
            rows.append(([label, num(subtotal), f"{100 * subtotal / average:.1f}%"], "group"))
            shown = items[:TOP_PARTS]
            rows += [([n, num(t), f"{100 * t / average:.1f}%"], "part") for n, t in shown]
            rest = sum(t for _, t in items[TOP_PARTS:])
            if rest:
                rows.append(
                    (
                        [
                            f"other ({len(items) - TOP_PARTS})",
                            num(rest),
                            f"{100 * rest / average:.1f}%",
                        ],
                        "part",
                    )
                )
        top = max(float(r[0][2].rstrip("%")) for r in rows)
        sections.append(
            ("Average main call", table(["part", "tokens", "share"], rows, (2, top)))
        )

        # Prompt tokens by call number across main sessions.
        by_session = defaultdict(list)
        for call in sorted(main, key=lambda c: c["time"]):
            by_session[call["session"]].append(call)
        median, high, fixed = [], [], []
        for i in range(max(len(s) for s in by_session.values())):
            at = [s[i] for s in by_session.values() if len(s) > i]
            if len(at) < GROWTH_MIN_SESSIONS:
                break
            median.append(statistics.median(c["prompt"] for c in at))
            high.append(p90([c["prompt"] for c in at]))
            fixed.append(
                statistics.median(
                    sum(
                        t
                        for n, t in c["parts"].items()
                        if n.split(":")[0] in ("system", "context", "tool")
                    )
                    for c in at
                )
            )
        colors = theme["colors"]
        chart = line_chart(
            [
                ("p90", colors["s"], high),
                ("median", colors["p"], median),
                ("fixed", colors["m"], fixed),
            ]
        )
        sections.append(("Prompt tokens by call number", chart))

    # Tools: calls and result sizes, plus tools declared but never called.
    by_tool = defaultdict(list)
    for result in results:
        by_tool[result["tool"]].append(result)
    declared = set().union(*(c["tools"] for c in main)) if main else set()
    rows = []
    for tool in sorted(
        set(by_tool) | declared, key=lambda t: -sum(r["chars"] for r in by_tool.get(t, []))
    ):
        items = by_tool.get(tool, [])
        sizes = [r["chars"] / ratio for r in items] or [0]
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
    sections.append(
        ("Tools", table(["tool", "calls", "errors", "avg", "p90", "max", "total"], rows))
    )

    # Subagents by agent name.
    if children:
        runs = defaultdict(lambda: defaultdict(list))
        for call in children:
            runs[call["agent"]][call["session"]].append(call)
        rows = []
        for agent, sessions in sorted(runs.items()):
            flat = [c for s in sessions.values() for c in s]
            rows.append(
                (
                    [
                        agent,
                        len(sessions),
                        f"{len(flat) / len(sessions):.1f}",
                        num(statistics.mean(c["prompt"] for c in flat)),
                        num(sum(c["prompt"] for c in flat)),
                        num(sum(c["output"] for c in flat)),
                        f"${sum(c['cost'] for c in flat):.2f}",
                    ],
                    "",
                )
            )
        headers = ["agent", "runs", "calls/run", "avg prompt", "prompt", "output", "cost"]
        sections.append(("Subagents", table(headers, rows)))

    # Largest tool results.
    rows = [
        (
            [
                r["tool"],
                num(r["chars"] / ratio),
                r["agent"],
                Path(r["cwd"]).name,
                r["time"][:16],
                r["args"][:PREVIEW],
            ],
            "",
        )
        for r in sorted(results, key=lambda r: -r["chars"])[:TOP_RESULTS]
    ]
    sections.append(
        (
            "Largest tool results",
            table(
                ["tool", "tokens", "agent", "project", "time", "arguments"], rows, cls="text"
            ),
        )
    )

    body = "".join(f"<h2>{esc(name)}</h2>{content}" for name, content in sections)
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>{esc(title)}</title>
<style>{style(theme)}</style></head><body><h1>{esc(title)}</h1><div class="kpis">{html_kpis}</div>
{body}</body></html>"""


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
    calls = [call for session in sessions for call in session["calls"]]
    filters = " ".join(f for f in [args.project, args.since and f"since {args.since}"] if f)
    title = f"Pi stats {filters}".strip()
    args.out.write_text(report(calls, results, skipped, theme, title))
    print(args.out)


if __name__ == "__main__":
    main()
