# Agents

Assets shared by the coding agents, and tools over their sessions. `default.nix` declares the
shared instructions, workflow, prompts, and skills that [Pi](pi/README.md) and
[Claude Code](claude/default.nix) link into their own locations, and installs `agent-stats`.

## agent-stats

`agent-stats` rebuilds every model request from the session files of Pi (`~/.pi/agent`) and
Claude Code (`~/.claude/projects`), then serves a NiceGUI app on `127.0.0.1` and opens it in
Zen; Ctrl+C stops it. It is styled with the system theme, and the reload button reads the
session files again. A tree on the left opens each page, with its own URL:

- The overview: totals of your usage, size per calendar day with moving averages (weight 1/12)
  of size, active hours, and your wait per turn, then totals per agent and per model. Below
  them, the average over the sessions you started, of both agents, with subagent runs counted
  within their parents, and an agent types table of each subagent type's efficiency (median
  compression, startup overhead, kept out, budget stops).
- Every session, of both agents, directly below the overview, captioned with its agent, size,
  and cost, ordered by latest user prompt, newest first, with the subagent runs it started
  nested in start-time order (oldest first), then a group of subagent runs whose parent is
  missing. A parent's position uses only its own prompts.

The average's session chart uses latest-prompt order, oldest first. Sessions without user
prompts fall back to their first counted model request. Displayed dates keep using the first
counted model request, independently of ordering; assistant responses, tool results, and
metadata do not move a session. Daily size counts each request's share on its own day, and
active time on the session's first day.

A session's size is the tokens that entered it, each counted once: its first prompt, each later
prompt's growth beyond the previous prompt and output, and all output, from the recorded token
counts. Cache misses and compactions do not change it, and a subagent run's size is its own;
compaction runs count in cost, where recorded, but not in size. Input and output are what
providers bill, for comparison with their dashboards: every request's prompt tokens, cached or
not, with the share read from cache, and its output tokens; compaction runs are not included.
Peak context and requests are details of a session page.

Each session page shows figures (size, size with subagents, cost, and the startup's tokens, KiB,
tools, context files, and skills), the context per request stacked by section, the startup's
parts as one bar, and a parts table nested by section (startup, conversation, tool calls, tool
results, other) that opens on click, with context and size tokens, their shares, KiB, how many
times each part occurred, and, for averages, how many sessions it appeared in. Then where time
goes, and compaction summaries. A parent shows its subagent runs (size, report, compression,
kept out, parent re-send, ending, parallelism), and a run shows its delegation.

Figures an agent does not record show `-`. Claude Code's figures are approximate where its
transcripts lack detail:

- The context is the transcript path plus the recorded system prompt and tools; the server's
  context edits are not recorded.
- Thinking text is not kept; its context size is estimated from its tokens. Sizes are exact;
  their split into parts uses these measured bytes.
- Cost is the API-equivalent price: each request's tokens at per-model rates derived from the
  session cost totals Claude Code records.
- Compaction requests (their tokens and cost), subagent notes and corrections, and permission
  prompt waits are not recorded; the latter count as tool time.
- `claude -p` (SDK) runs are left out.
- Claude Code deletes transcripts after `cleanupPeriodDays`;
  [claude/default.nix](claude/default.nix) keeps them for two years.
