import contextlib
import io
import json
import re
import subprocess
import unittest
from unittest.mock import patch

import statusline

NOW = 1_800_000_000


def plain(text):
    # Strip ANSI color codes so assertions read like the rendered line.
    return re.sub(r"\033\[[0-9;]*m", "", text)


class StatuslineTest(unittest.TestCase):
    def test_directory_abbreviates_home(self):
        self.assertEqual(statusline.directory("/home/ouz", "/home/ouz"), "~")
        self.assertEqual(statusline.directory("/home/ouz/a/b", "/home/ouz"), "~/a/b")
        self.assertEqual(statusline.directory("/home/ouzz", "/home/ouz"), "/home/ouzz")
        self.assertEqual(statusline.directory("/ozozka/ol", "/home/ouz"), "/ozozka/ol")

    def test_duration_matches_pi_format(self):
        self.assertEqual(statusline.duration(30), "<1m")
        self.assertEqual(statusline.duration(59 * 60), "59m")
        self.assertEqual(statusline.duration(2 * 3600 + 53 * 60 + 10), "2h53m")
        self.assertEqual(statusline.duration(3 * 86400 + 4 * 3600), "3d4h")

    def test_limit_shows_remaining_and_countdown(self):
        window = {"used_percentage": 18, "resets_at": NOW + 2 * 3600 + 53 * 60}
        self.assertEqual(plain(statusline.limit("5h", window, NOW)), "5h 82% 2h53m")

    def test_limit_colors_low_remaining(self):
        yellow = statusline.limit("5h", {"used_percentage": 75, "resets_at": NOW + 600}, NOW)
        red = statusline.limit("5h", {"used_percentage": 95, "resets_at": NOW + 600}, NOW)
        self.assertIn("\033[33m", yellow)
        self.assertIn("\033[31m", red)

    def test_limit_passed_reset_is_unknown(self):
        window = {"used_percentage": 50, "resets_at": NOW - 1}
        self.assertEqual(plain(statusline.limit("w", window, NOW)), "w ? due")

    def test_limit_ignores_invalid_values(self):
        for window in [
            None,
            {},
            {"used_percentage": "x"},
            {"used_percentage": True},
            {"used_percentage": 120},
            {"used_percentage": float("nan")},
        ]:
            self.assertIsNone(statusline.limit("5h", window, NOW))

    def test_limit_without_reset(self):
        self.assertEqual(plain(statusline.limit("5h", {"used_percentage": 10}, NOW)), "5h 90%")

    def test_context_thresholds(self):
        self.assertEqual(statusline.context({"used_percentage": 42.4}), "ctx 42%")
        self.assertIn("\033[33m", statusline.context({"used_percentage": 70}))
        self.assertIn("\033[31m", statusline.context({"used_percentage": 90}))
        self.assertIsNone(statusline.context(None))

    @patch("statusline.subprocess.run")
    def test_branch(self, run):
        run.return_value.returncode = 0
        run.return_value.stdout = "# branch.oid abcdef123456\n# branch.head main\n"
        self.assertEqual(statusline.branch("/repo", "/nix/git"), "main")
        self.assertEqual(run.call_args.args[0][0], "/nix/git")
        self.assertIn("--no-optional-locks", run.call_args.args[0])
        run.return_value.stdout += "1 .M N... 100644 100644 100644 a b file\n"
        self.assertEqual(statusline.branch("/repo", "/nix/git"), "main*")
        run.return_value.stdout = "# branch.oid abcdef123456\n# branch.head (detached)\n"
        self.assertIsNone(statusline.branch("/repo", "/nix/git"))

    @patch("statusline.subprocess.run")
    def test_branch_failures_are_silent(self, run):
        run.return_value.returncode = 128
        self.assertIsNone(statusline.branch("/tmp", "/nix/git"))
        run.side_effect = subprocess.TimeoutExpired("git", 1)
        self.assertIsNone(statusline.branch("/repo", "/nix/git"))
        run.side_effect = OSError("missing")
        self.assertIsNone(statusline.branch("/repo", "/nix/git"))

    @patch("statusline.branch", return_value="main*")
    def test_full_line(self, _):
        event = {
            "workspace": {"current_dir": "/home/ouz/ozozka/ol"},
            "model": {"display_name": "Opus 5.5"},
            "context_window": {"used_percentage": 42},
            "rate_limits": {
                "five_hour": {"used_percentage": 18, "resets_at": NOW + 2 * 3600 + 53 * 60},
                "seven_day": {"used_percentage": 35, "resets_at": NOW + 3 * 86400 + 4 * 3600},
            },
        }
        self.assertEqual(
            plain(statusline.status(event, "/nix/git", "/home/ouz", NOW)),
            "~/ozozka/ol  main*  Opus 5.5  ctx 42%  5h 82% 2h53m  w 65% 3d4h",
        )

    @patch("statusline.branch", return_value=None)
    def test_minimal_line(self, _):
        # API-key sessions have null rate_limits; missing fields are simply left out.
        event = {"cwd": "/ozozka/ol", "rate_limits": None, "context_window": None}
        self.assertEqual(
            plain(statusline.status(event, "/nix/git", "/home/ouz", NOW)), "/ozozka/ol"
        )

    def test_main_reports_bad_input(self):
        output = io.StringIO()
        with (
            patch("sys.stdin", io.StringIO("not json")),
            patch("sys.argv", ["statusline.py", "/nix/git"]),
            contextlib.redirect_stdout(output),
        ):
            statusline.main()
        self.assertTrue(output.getvalue().startswith("status line:"))

    @patch("statusline.branch", return_value=None)
    def test_main_prints_line(self, _):
        output = io.StringIO()
        with (
            patch("sys.stdin", io.StringIO(json.dumps({"cwd": "/ozozka/ol"}))),
            patch("sys.argv", ["statusline.py", "/nix/git"]),
            contextlib.redirect_stdout(output),
        ):
            statusline.main()
        self.assertEqual(plain(output.getvalue()), "/ozozka/ol\n")


if __name__ == "__main__":
    unittest.main()
