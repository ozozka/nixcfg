"""Claude Code documentation context hook. Configuration is supplied by Nix."""

import json
import stat
import sys
from pathlib import Path

# Claude spills hook strings above 10,000 characters, with no configurable override.
# Leave room for framing; larger sets get a warning and explicit full-file reading
# instructions. Full loading then depends on Claude following those instructions.
MAX_CONTEXT = 9_000


def documentation(cwd):
    # Load cwd/README.md and recursive cwd/docs/**/*.md in sorted traversal order.
    # Skip symlinks and docs entries starting with _ (including whole subtrees).
    # Never search parents. Missing files are optional; other read failures warn.
    # Claude gates settings-file hooks on workspace trust. In -p/SDK mode,
    # Claude considers the workspace trusted: only run those modes in vetted repos.
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
        # Explicit read instructions instead of Claude's truncated spill preview.
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
        result["systemMessage"] = "\n".join(warnings)[:MAX_CONTEXT]
    return result


def main():
    try:
        event = json.load(sys.stdin)
        cwd = Path(event["cwd"]).resolve()
        print(json.dumps(documentation(cwd)))
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Claude Code hook: {error}", file=sys.stderr)
        print("{}")


if __name__ == "__main__":
    main()
