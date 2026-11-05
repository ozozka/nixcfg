"""Codex documentation context hook. Configuration is supplied by Nix."""

import json
import os
import stat
import sys
import tomllib
from pathlib import Path

# Bound resource use even though additionalContextLimit disables Codex spilling.
# Above this character budget, warn and request full-file reads instead of truncation.
MAX_CONTEXT = 200_000


def trusted(cwd):
    # User hooks also run in untrusted projects. Fail closed; never change trust.
    # Require a local trust record for this exact working directory, not a parent.
    # Cloud-only or command-line trust overrides are not inferred.
    # Keep config.toml writable so Codex can record its own trust decisions.
    home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
    try:
        with (home / "config.toml").open("rb") as source:
            projects = tomllib.load(source).get("projects", {})
        return projects.get(str(cwd), {}).get("trust_level") == "trusted"
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return False


def documentation(cwd):
    # Load cwd/README.md and recursive cwd/docs/**/*.md in sorted traversal order.
    # Skip symlinks and docs entries starting with _ (including whole subtrees).
    # Never search parents. Missing files are optional; other read failures warn.
    if not trusted(cwd):
        return {
            "systemMessage": "Documentation not loaded: no local Codex project trust record."
        }
    paths = [cwd / "README.md"]
    warnings = []

    def visit(path):
        try:
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                for child in sorted(path.iterdir()):
                    if not child.name.startswith("_"):
                        visit(child)
            elif stat.S_ISREG(mode) and path.suffix == ".md":
                paths.append(path)
        except FileNotFoundError:
            pass
        except OSError as error:
            warnings.append(f"Could not discover documentation {path}: {error}")

    visit(cwd / "docs")

    files = []
    parts = []
    size = 0
    oversized = False
    for path in paths:
        try:
            # lstat skips symlinks, directories, devices, and named pipes.
            if not stat.S_ISREG(path.lstat().st_mode):
                continue
            files.append(str(path))
            with path.open(encoding="utf-8") as source:
                content = source.read(MAX_CONTEXT + 1)
            part = f"\n# Source: {path}\n\n{content}\n"
            size += len(part)
            if size <= MAX_CONTEXT:
                parts.append(part)
            else:
                oversized = True
        except FileNotFoundError:
            pass
        except (OSError, UnicodeError) as error:
            warnings.append(f"Could not read {path}: {error}")

    if oversized:
        # Explicit read instructions instead of a silently truncated preview.
        context = (
            "Project documentation exceeds the automatic context budget. Before working on the "
            "request, read ALL of these files in full using file tools (in chunks if necessary):\n"
            + "\n".join(json.dumps(path) for path in files)
        )
        warnings.append(
            "Large documentation: supplied explicit full-file reading instructions."
        )
        if len(context) > MAX_CONTEXT:
            context = (
                f"Read {cwd / 'README.md'} and recursive {cwd / 'docs'}/**/*.md in full, "
                "excluding symlinks and files or directories whose names start with _."
            )
    else:
        context = "".join(parts)
    result = {
        "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}
    }
    if warnings:
        result["systemMessage"] = "\n".join(warnings)
    return result


def main():
    try:
        event = json.load(sys.stdin)
        cwd = Path(event["cwd"]).resolve()
        print(json.dumps(documentation(cwd)))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Codex hook: {error}", file=sys.stderr)
        print("{}")


if __name__ == "__main__":
    main()
