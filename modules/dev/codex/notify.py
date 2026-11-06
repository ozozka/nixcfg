"""Codex desktop notification hook. The busctl path is supplied by Nix."""

import json
import os
import subprocess
import sys
from pathlib import Path


def notify(event, cwd, busctl):
    # Match Pi's desktop presentation: application name, project title, short body.
    # Payloads do not reliably identify headless sessions: local automation with
    # a desktop bus may also notify. Exclude CI and identifiable subagent events.
    # Missing D-Bus/services and timeouts must never interrupt the agent.
    name = event.get("hook_event_name")
    if event.get("agent_id") or os.environ.get("CI"):
        return
    if name == "Stop":
        message = "Done"
    elif name == "PermissionRequest":
        message = "Permission required"
    elif name == "PreToolUse" and event.get("tool_name") == "request_user_input":
        message = "Input required"
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
                "Codex",
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
            print("Codex: could not send desktop notification", file=sys.stderr)
    except OSError, subprocess.TimeoutExpired:
        print("Codex: could not send desktop notification", file=sys.stderr)


def main():
    try:
        event = json.load(sys.stdin)
        cwd = Path(event["cwd"]).resolve()
        notify(event, cwd, sys.argv[1])
        # No decisions: normal approvals and turn termination are unchanged.
        print("{}")
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Codex hook: {error}", file=sys.stderr)
        print("{}")


if __name__ == "__main__":
    main()
