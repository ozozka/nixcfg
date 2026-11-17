"""Claude Code notification hook: an OSC 777 sequence to the terminal Claude runs in.

The terminal decides what a notification is: Emacs sends a desktop card that shows the terminal
on click; terminals without support ignore it. Hook output goes to Claude and hooks have no
controlling terminal, so the sequence is written to the terminal of Claude itself.
"""

import json
import os
import re
import sys
from pathlib import Path

# Longest summary shown after "Done: " or "Failed: ", as in Pi's notify.ts.
SUMMARY_LENGTH = 80


def first_line(text):
    """Return the first non-empty line of a text, shortened to fit a notification."""
    line = next((line.strip() for line in str(text or "").splitlines() if line.strip()), "")
    return line if len(line) <= SUMMARY_LENGTH else line[: SUMMARY_LENGTH - 1] + "…"


def summarized(label, text):
    """Return the label, followed by the text's first line when there is one."""
    summary = first_line(text)
    return f"{label}: {summary}" if summary else label


def clean(text):
    """Replace control characters, which would end the sequence."""
    return re.sub(r"[\x00-\x1f\x7f-\x9f]", " ", text)


def terminal():
    """Return the terminal of the nearest ancestor that writes to one: hooks run without a controlling terminal."""
    pid = os.getppid()
    while pid > 1:
        target = Path(f"/proc/{pid}/fd/1").readlink()
        if target.is_relative_to("/dev/pts"):
            return target
        pid = int(Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[1])
    raise OSError("no terminal")


def notify(event, cwd):
    # Match Pi's presentation: agent and project as the title, a short body.
    # Exclude subagents, CI, and remote web sessions; a missing terminal must never
    # interrupt the agent.
    if event.get("agent_id") or os.environ.get("CI") or os.environ.get("CLAUDE_CODE_REMOTE"):
        return
    name = event.get("hook_event_name")
    if name == "Stop":
        message = summarized("Done", event.get("last_assistant_message"))
    elif name == "StopFailure":
        message = summarized("Failed", event.get("error_details") or event.get("error"))
    elif name == "Notification":
        kind = event.get("notification_type")
        if kind == "permission_prompt":
            message = "Permission required"
        elif kind in {"elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"}:
            message = "Input required"
        else:
            return
    else:
        return
    title = clean(f"Claude · {cwd.name or cwd}").replace(";", ",")
    try:
        with terminal().open("w", encoding="utf-8") as tty:
            tty.write(f"\x1b]777;notify;{title};{clean(message)}\x07")
    except OSError:
        pass


def main():
    try:
        event = json.load(sys.stdin)
        cwd = Path(event["cwd"]).resolve()
        notify(event, cwd)
        # Never approve, deny, or continue a turn from a notification hook.
        print("{}")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Claude Code hook: {error}", file=sys.stderr)
        print("{}")


if __name__ == "__main__":
    main()
