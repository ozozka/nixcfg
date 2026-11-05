"""Claude Code status line. The git path is supplied by Nix."""

import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

CYAN = "36"
DIM = "2"
YELLOW = "33"
RED = "31"


def color(code, text):
    return f"\033[{code}m{text}\033[0m"


def number(value):
    # bool is an int subclass; never treat it as a percentage.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return value if math.isfinite(value) else None


def record(value):
    return value if isinstance(value, dict) else {}


def directory(path, home):
    # Same shape as the shell prompt's \w: home becomes ~.
    if home and (path == home or path.startswith(home.rstrip("/") + "/")):
        return "~" + path[len(home.rstrip("/")) :]
    return path


def branch(path, git):
    # Status lines refresh often: never take git's optional index lock, and give up fast.
    try:
        result = subprocess.run(
            [git, "-C", path, "--no-optional-locks", "status", "--porcelain=v2", "--branch"],
            capture_output=True,
            text=True,
            timeout=1,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if result.returncode:
        return None
    name = None
    dirty = False
    for line in result.stdout.splitlines():
        if line.startswith("# branch.head "):
            name = line.removeprefix("# branch.head ")
        elif line.startswith("# branch.oid ") and name is None:
            name = line.removeprefix("# branch.oid ")[:7]
        elif not line.startswith("#"):
            dirty = True
    if name == "(detached)":
        name = None
    return f"{name}{'*' if dirty else ''}" if name else None


def duration(seconds):
    # Same countdown format as the Pi status extension.
    if seconds < 60:
        return "<1m"
    minutes = int(seconds // 60)
    if seconds >= 86400:
        return f"{minutes // 1440}d{minutes // 60 % 24}h"
    if seconds >= 3600:
        return f"{minutes // 60}h{minutes % 60}m"
    return f"{minutes}m"


def limit(label, window, now):
    # Remaining quota and time until reset, e.g. "5h 82% 2h53m".
    window = record(window)
    used = number(window.get("used_percentage"))
    if used is None or not 0 <= used <= 100:
        return None
    reset = number(window.get("resets_at"))
    left = None if reset is None else reset - now
    if left is not None and left <= 0:
        # A passed reset is not evidence of a fresh quota allocation.
        return color(DIM, f"{label} ? due")
    remaining = round(100 - used)
    text = f"{label} {remaining}%" + ("" if left is None else f" {duration(left)}")
    if remaining <= 10:
        return color(RED, text)
    if remaining <= 30:
        return color(YELLOW, text)
    return text


def context(window):
    used = number(record(window).get("used_percentage"))
    if used is None:
        return None
    text = f"ctx {round(used)}%"
    if used >= 90:
        return color(RED, text)
    if used >= 70:
        return color(YELLOW, text)
    return text


def status(event, git, home, now):
    workspace = record(event.get("workspace"))
    path = workspace.get("current_dir") or event.get("cwd") or os.getcwd()
    limits = record(event.get("rate_limits"))
    parts = [
        color(CYAN, directory(path, home)),
        branch(path, git),
        record(event.get("model")).get("display_name"),
        context(event.get("context_window")),
        limit("5h", limits.get("five_hour"), now),
        limit("w", limits.get("seven_day"), now),
    ]
    return "  ".join(part for part in parts if isinstance(part, str) and part)


def main():
    try:
        event = json.load(sys.stdin)
        if not isinstance(event, dict):
            raise TypeError("status line input is not an object")
        print(status(event, sys.argv[1], str(Path.home()), time.time()))
    except (OSError, ValueError, TypeError, IndexError) as error:
        # Keep a status line visible; a traceback would replace it.
        print(f"status line: {error}")


if __name__ == "__main__":
    main()
