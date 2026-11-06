"""Claude Code desktop notification hook. The busctl path is supplied by Nix."""

import json
import os
import subprocess
import sys
from pathlib import Path


def notify(event, cwd, busctl):
    # Match Pi's desktop presentation: application name, project title, short body.
    # Payloads do not reliably identify headless sessions: local automation with
    # a desktop bus may also notify. Exclude subagents, CI, and remote web sessions.
    # Missing D-Bus/services and timeouts must never interrupt the agent.
    if event.get("agent_id") or os.environ.get("CI") or os.environ.get("CLAUDE_CODE_REMOTE"):
        return
    name = event.get("hook_event_name")
    if name == "Stop":
        message = "Done"
    elif name == "StopFailure":
        message = "Failed"
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
    try:
        result = subprocess.run(
            [
                busctl,
                "--user",
                "--timeout=3",
                "--",
                "call",
                "org.freedesktop.Notifications",
                "/org/freedesktop/Notifications",
                "org.freedesktop.Notifications",
                "Notify",
                "susssasa{sv}i",
                "Claude",
                "0",
                "",
                cwd.name or str(cwd),
                message,
                "0",
                "0",
                "-1",
            ],
            capture_output=True,
            timeout=5,
            check=False,
        )
        if result.returncode:
            print("Claude Code: could not send desktop notification", file=sys.stderr)
    except OSError, subprocess.TimeoutExpired:
        print("Claude Code: could not send desktop notification", file=sys.stderr)


def main():
    try:
        event = json.load(sys.stdin)
        cwd = Path(event["cwd"]).resolve()
        notify(event, cwd, sys.argv[1])
        # Never approve, deny, or continue a turn from a notification hook.
        print("{}")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Claude Code hook: {error}", file=sys.stderr)
        print("{}")


if __name__ == "__main__":
    main()
