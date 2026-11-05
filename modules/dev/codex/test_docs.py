import contextlib
import io
import json
import os
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
        self.home = self.root / "codex-home"
        self.home.mkdir()
        self.environment = patch.dict(os.environ, {"CODEX_HOME": str(self.home)}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.trust(self.root)

    def trust(self, directory, level="trusted"):
        (self.home / "config.toml").write_text(
            f"[projects.{json.dumps(str(directory))}]\ntrust_level = {json.dumps(level)}\n"
        )

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
        (directory / "nested" / "guide.md").write_text("nested marker")
        (directory / "link.md").symlink_to(self.root / "README.md")
        (directory / "dir.md").mkdir()
        result = self.context()
        self.assertLess(result.index("README marker"), result.index("first marker"))
        self.assertLess(result.index("first marker"), result.index("nested marker"))
        self.assertLess(result.index("nested marker"), result.index("last marker"))
        self.assertNotIn("excluded", result)
        self.assertNotIn("link.md", result)
        self.assertNotIn("dir.md", result)

    def test_recursive_exclusions_and_symlinks(self):
        directory = self.root / "docs"
        for name in ("_private", "_archive.md", "public/deep", "public/_drafts"):
            (directory / name).mkdir(parents=True, exist_ok=True)
        for name in (
            "_private/visible.md",
            "_archive.md/visible.md",
            "_hidden.md",
            "public/_hidden.md",
            "public/_drafts/visible.md",
            "public/deep/ignored.txt",
        ):
            (directory / name).write_text("excluded marker")
        (directory / "public" / "deep" / "guide.md").write_text("deep marker")
        (directory / "public" / "deep" / "_cycle").symlink_to(directory)
        (directory / "public" / "cycle").symlink_to(directory, target_is_directory=True)
        (directory / "public" / "linked.md").symlink_to(directory / "_hidden.md")
        (directory / "linked-dir").symlink_to(directory / "_private", target_is_directory=True)
        result = self.context()
        self.assertIn("deep marker", result)
        self.assertNotIn("excluded marker", result)
        self.assertNotIn("linked", result)

    def test_discovery_error_preserves_other_docs(self):
        directory = self.root / "docs"
        (directory / "broken").mkdir(parents=True)
        (directory / "guide.md").write_text("readable marker")
        original = Path.iterdir

        def iterdir(path):
            if path == directory / "broken":
                raise PermissionError("unreadable directory")
            return original(path)

        with patch.object(Path, "iterdir", iterdir):
            result = docs.documentation(self.root)
        self.assertIn("readable marker", result["hookSpecificOutput"]["additionalContext"])
        self.assertIn("unreadable directory", result["systemMessage"])

    def test_only_cwd_documentation_is_loaded(self):
        (self.root / "README.md").write_text("excluded parent README")
        (self.root / "docs").mkdir()
        (self.root / "docs" / "parent.md").write_text("excluded parent docs")
        sub = self.root / "src"
        sub.mkdir()
        self.trust(sub)
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
        (self.root / "README.md").symlink_to(self.home / "config.toml")
        (self.root / "docs").symlink_to(self.home, target_is_directory=True)
        self.assertEqual(self.context(), "")

    def test_trust_fails_closed(self):
        self.trust(self.root, "untrusted")
        self.assertNotIn("hookSpecificOutput", docs.documentation(self.root))
        (self.home / "config.toml").write_text("not valid TOML")
        self.assertNotIn("hookSpecificOutput", docs.documentation(self.root))

    def test_parent_trust_does_not_enable_cwd_documentation(self):
        (self.root / ".git").mkdir()
        sub = self.root / "src"
        sub.mkdir()
        (sub / "README.md").write_text("cwd README marker")
        self.assertNotIn("hookSpecificOutput", docs.documentation(sub))
        with (self.home / "config.toml").open("a") as source:
            source.write(f'[projects.{json.dumps(str(sub))}]\ntrust_level = "untrusted"\n')
        self.assertNotIn("hookSpecificOutput", docs.documentation(sub))
        self.trust(sub)
        self.assertIn("cwd README marker", self.context(sub))

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
