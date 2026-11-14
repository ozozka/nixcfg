# Pi

The Pi coding agent with a few extensions, configured through Nix. `default.nix` installs the
commands below and links the files under `~/.pi/agent` through the `pi` home profile.

## Commands

| Command                             | What it runs                                                             |
| ----------------------------------- | ------------------------------------------------------------------------ |
| `pi`                                | Pi with the extensions below, without the workflow, docs, or subagents   |
| `wpi`                               | Pi with the personal workflow appended to the system prompt and `--docs` |
| `wpi --subagents`, `pi --subagents` | Either of the above with subagents enabled                               |
| `pi-stats`                          | An HTML report of what Pi's model requests contained (`stats.py`)        |

Flags enable whole features (`--docs`, `--subagents`); a single tool is turned on through the
tool selection (`--tools +name`). `wpi` stays the only wrapper.

## Extensions

Every extension loads in every Pi process, including subagents; flags decide what is active.

| File            | Loaded             | Behavior                                                                                                |
| --------------- | ------------------ | ------------------------------------------------------------------------------------------------------- |
| `status.ts`     | Always             | Status line on the editor's borders: mode, work clock, Codex quota, context use, model, folder, branch  |
| `mode.ts`       | Always             | Modes from `modes/` (currently `plan`); see below                                                       |
| `question.ts`   | Always, TUI only   | `question` tool: the model asks one or more questions with options                                      |
| `notify.ts`     | Always, TUI only   | Desktop notifications: "Done" or "Failed" when a run settles, "Input required" for dialogs during a run |
| `docs.ts`       | With `--docs`      | Adds the project's `README.md` and `docs/**/*.md` to the context of every run                           |
| `subagent.ts`   | With `--subagents` | `subagent` tool, widget, and `/subagents`; see below                                                    |
| `lib/shared.ts` | Imported           | Shared helpers; Pi skips `lib/` as an extension                                                         |

`question` and `subagent` are model-only: `codemode` scripts cannot call them.

## Modes

A mode is a Markdown file in `modes/`: its frontmatter excludes tools and sets the thinking
level, and its body joins the system prompt. Switch with `/mode [name]`, `/mode free`, or
Shift+Tab (thinking levels cycle with Ctrl+T). The mode is recorded in the session, so resuming
restores it, and leaving a mode restores the earlier tools and thinking level.

- `free`: the normal settings.
- `plan`: explore and discuss; no `edit` or `write`.

## Subagents

Agents are Markdown files in `agents/`: frontmatter for the model, thinking level, and tools,
and a body appended to the child's system prompt.

- `reader`: read-only research and review.
- `worker`: full tools for delegated changes.

Each child is a separate `pi` process in RPC mode with its own context, which sees only its
task. Children get `--docs` when the parent has it, never `--subagents` (delegation stays one
level deep) or `question`, and keep their sessions in `~/.pi/agent/subagent-sessions/`.

The parent's `subagent` tool:

| Action                  | Behavior                                                                                     |
| ----------------------- | -------------------------------------------------------------------------------------------- |
| `start { agent, task }` | Starts a child in the background and returns its ID at once                                  |
| `send { to, text }`     | Steers a running child, or continues one that ended its turn in the same session             |
| `wait { ids?, until? }` | Waits for children (default: all running), until `any` or `all` ended; a note always ends it |
| `stop { ids? }`         | Aborts children; each returns its last text                                                  |

A child reports by ending its turn, asks a question the same way, and can send a note while it
keeps working with `send_message`, a tool only children get. Each report or note reaches the
parent once: in a `wait` result, otherwise as a message that starts a turn when the parent is
idle. In print mode (`pi -p`) the parent waits for its children before it exits.

Limits:

- At most 6 children run at once, the rest wait in a queue; the guidelines advise 2-3.
- At 72 turns or 30 minutes a child is told to stop and report; it is aborted 24 turns or 5
  minutes later. Either way its last text comes back as a partial report.
- Quitting, `/new`, `/resume`, and `/reload` abort running children.

User-facing parts: a widget below the editor shows one line per child (state, task, turns, time,
tokens and cost, current tool call) until the next prompt after it ends, and
`/subagents stop [id ...]` stops children directly, since Escape stops only the parent's turn.

## Other commands and keys

| Command or key             | Effect                                                             |
| -------------------------- | ------------------------------------------------------------------ |
| `/docs`                    | Lists the context files of the current run and whether docs are on |
| `/mode`, Shift+Tab         | Switch modes                                                       |
| `/subagents stop [id ...]` | Stop subagents (with `--subagents`)                                |
| Ctrl+T                     | Cycle thinking levels                                              |
| Ctrl+R                     | Resume a session                                                   |

## pi-stats

`pi-stats [--since YYYY-MM-DD] [--project TEXT] [--out FILE]` rebuilds every model request from
the session files and writes `/tmp/pi-stats.html`, styled with the system theme, as one page:

- The overview: totals, the subagent share of all tokens, and tokens per day.
- The sessions: one dropdown with an average per agent, then every session newest first, with
  the subagent runs it started nested under it, then subagent runs whose parent is missing.

Each session panel shows figures (including the startup's tokens, KiB, tools, context files, and
skills), the context per request stacked by section, the startup's parts as one bar, and a parts
table nested by section (startup, conversation, tool calls, tool results, other) that opens on
click, with context and consumed tokens, their shares and ratio, KiB, and, for averages, how
many sessions each part appeared in. Then tools (calls, errors, result tokens, run time), where
time goes, and compaction summaries. A parent shows its subagent runs (cost, report,
compression, kept out, parent re-send, ending, parallelism), a run shows its delegation, and an
agent's average shows its efficiency (median compression, startup overhead, budget stops).
