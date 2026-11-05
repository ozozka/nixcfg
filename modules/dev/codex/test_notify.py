import contextlib
import io
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import notify


class NotifyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    @patch("notify.subprocess.run")
    def test_notification_events(self, run):
        run.return_value.returncode = 0
        for event, message in [
            ({"hook_event_name": "Stop"}, "Done"),
            ({"hook_event_name": "PermissionRequest"}, "Permission required"),
            (
                {"hook_event_name": "PreToolUse", "tool_name": "request_user_input"},
                "Input required",
            ),
        ]:
            notify.notify(event, self.root, "/injected/busctl")
            args = run.call_args.args[0]
            self.assertEqual(args[0], "/injected/busctl")
            self.assertIn("Codex", args)
            self.assertIn(self.root.name, args)
            self.assertIn(message, args)
            self.assertEqual(args[-1], "-1")
            self.assertEqual(run.call_args.kwargs["timeout"], 5)

    @patch("notify.subprocess.run")
    def test_ignored_notifications(self, run):
        for event in [
            {"hook_event_name": "SubagentStop"},
            {"hook_event_name": "Interrupt"},
            {"hook_event_name": "PostToolUseFailure"},
            {"hook_event_name": "Stop", "agent_id": "child"},
        ]:
            notify.notify(event, self.root, "busctl")
        with patch.dict(os.environ, {"CI": "1"}):
            notify.notify({"hook_event_name": "Stop"}, self.root, "busctl")
        run.assert_not_called()

    @patch("notify.subprocess.run")
    def test_notification_failures_are_nonfatal(self, run):
        for failure in [FileNotFoundError(), subprocess.TimeoutExpired("busctl", 5)]:
            run.side_effect = failure
            with contextlib.redirect_stderr(io.StringIO()):
                notify.notify({"hook_event_name": "Stop"}, self.root, "busctl")

    @patch("notify.subprocess.run")
    def test_main_uses_busctl_argument_without_mode_and_returns_no_decision(self, run):
        run.return_value.returncode = 0
        event = {"hook_event_name": "PermissionRequest", "cwd": str(self.root)}
        output = io.StringIO()
        with (
            patch("sys.argv", ["notify.py", "/injected/busctl"]),
            patch("sys.stdin", io.StringIO(json.dumps(event))),
            contextlib.redirect_stdout(output),
        ):
            notify.main()
        self.assertEqual(run.call_args.args[0][0], "/injected/busctl")
        self.assertEqual(json.loads(output.getvalue()), {})

    def test_malformed_input_is_nonfatal(self):
        output = io.StringIO()
        with (
            patch("sys.stdin", io.StringIO("not json")),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            notify.main()
        self.assertEqual(json.loads(output.getvalue()), {})


if __name__ == "__main__":
    unittest.main()
