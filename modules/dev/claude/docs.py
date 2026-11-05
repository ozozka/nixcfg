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
    # Only cwd/README.md and sorted direct cwd/docs/*.md children, without symlinks.
    # Never search parents. Missing files are optional; other read failures warn.
    # Claude gates settings-file hooks on workspace trust. In -p/SDK mode,
    # Claude considers the workspace trusted: only run those modes in vetted repos.
    paths = [cwd / "README.md"]
    warnings = []
    docs = cwd / "docs"
    try:
        if stat.S_ISDIR(docs.lstat().st_mode):
            paths.extend(sorted(path for path in docs.iterdir() if path.suffix == ".md"))
    except FileNotFoundError:
        pass
    except OSError as error:
        warnings.append(f"Could not list {docs}: {error}")

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
                f"Read {cwd / 'README.md'} and all direct {cwd / 'docs'}/*.md files in full."
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
