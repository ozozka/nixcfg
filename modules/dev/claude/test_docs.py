import contextlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import docs


class DocsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()

    def context(self, cwd=None):
        return docs.documentation(cwd or self.root)["hookSpecificOutput"]["additionalContext"]

    def test_selection_and_order_in_cwd(self):
        (self.root / "README.md").write_text("README marker")
        (self.root / "readme.md").write_text("excluded lowercase")
        (self.root / "justfile").write_text("excluded justfile")
        directory = self.root / "docs"
        directory.mkdir()
        (directory / "z.md").write_text("last marker")
        (directory / "a space.md").write_text("first marker")
        (directory / "nested").mkdir()
        (directory / "nested" / "hidden.md").write_text("excluded nested")
        (directory / "link.md").symlink_to(self.root / "README.md")
        (directory / "dir.md").mkdir()
        result = self.context()
        self.assertLess(result.index("README marker"), result.index("first marker"))
        self.assertLess(result.index("first marker"), result.index("last marker"))
        self.assertNotIn("excluded", result)
        self.assertNotIn("link.md", result)
        self.assertNotIn("dir.md", result)

    def test_only_cwd_documentation_is_loaded(self):
        (self.root / "README.md").write_text("excluded parent README")
        (self.root / "docs").mkdir()
        (self.root / "docs" / "parent.md").write_text("excluded parent docs")
        sub = self.root / "src"
        sub.mkdir()
        marker = self.root / ".git"
        for kind in ("none", "repository", "worktree"):
            with self.subTest(kind=kind):
                if kind == "repository":
                    marker.mkdir()
                elif kind == "worktree":
                    marker.rmdir()
                    marker.write_text("gitdir: /not/executed")
                self.assertEqual(self.context(sub), "")
                (sub / "README.md").write_text("cwd README marker")
                (sub / "docs").mkdir()
                (sub / "docs" / "local.md").write_text("cwd docs marker")
                result = self.context(sub)
                self.assertIn("cwd README marker", result)
                self.assertIn("cwd docs marker", result)
                self.assertNotIn("excluded parent", result)
                (sub / "README.md").unlink()
                (sub / "docs" / "local.md").unlink()
                (sub / "docs").rmdir()

    def test_missing_and_symlinked_docs(self):
        self.assertEqual(self.context(), "")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "secret.md").write_text("excluded")
        (self.root / "README.md").symlink_to(outside / "secret.md")
        (self.root / "docs").symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.context(), "")

    def test_oversized_context_is_explicit(self):
        (self.root / "README.md").write_text("x" * (docs.MAX_CONTEXT + 1))
        result = docs.documentation(self.root)
        context = result["hookSpecificOutput"]["additionalContext"]
        self.assertIn("read ALL", context)
        self.assertIn(str(self.root / "README.md"), context)
        self.assertLessEqual(len(context), docs.MAX_CONTEXT)
        self.assertIn("Large documentation", result["systemMessage"])

    def test_read_error_is_nonfatal(self):
        (self.root / "README.md").write_bytes(b"\xff")
        result = docs.documentation(self.root)
        self.assertIn("Could not read", result["systemMessage"])

    def test_main_loads_context_without_mode_argument(self):
        (self.root / "README.md").write_text("entry point marker")
        output = io.StringIO()
        with (
            patch("sys.argv", ["docs.py"]),
            patch("sys.stdin", io.StringIO(json.dumps({"cwd": str(self.root)}))),
            contextlib.redirect_stdout(output),
        ):
            docs.main()
        self.assertIn(
            "entry point marker",
            json.loads(output.getvalue())["hookSpecificOutput"]["additionalContext"],
        )

    def test_malformed_input_is_nonfatal(self):
        output = io.StringIO()
        with (
            patch("sys.stdin", io.StringIO("not json")),
            contextlib.redirect_stdout(output),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            docs.main()
        self.assertEqual(json.loads(output.getvalue()), {})


if __name__ == "__main__":
    unittest.main()
