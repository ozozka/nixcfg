# Agents

Assets shared by the coding agents, and tools over their sessions. `default.nix` declares the
shared instructions, workflow, prompts, and skills that [Pi](pi/README.md) and
[Claude Code](claude/default.nix) link into their own locations, and installs `agent-stats`.

## agent-stats

`agent-stats` rebuilds every model request from the session files of Pi (`~/.pi/agent`) and
Claude Code (`~/.claude/projects`), then serves a NiceGUI app on `127.0.0.1` and opens it in
Zen; Ctrl+C stops it. It is styled with the system theme, and the reload button reads the
session files again. A tree on the left opens each page, with its own URL:

- The overview: totals of your usage, tokens per calendar day with moving averages (weight 1/12)
  of tokens, active hours, and your wait per turn, then totals per agent and per model.
- An average per agent type of each agent (`Pi · main`, `Claude Code · web-fetch`), then each
  agent's sessions ordered by their latest user prompt, newest first, with the subagent runs
  they started nested in start-time order (oldest first), then subagent runs whose parent is
  missing. A parent's position uses only its own prompts.

The average page's session chart uses latest-prompt order, oldest first. Sessions without user
prompts fall back to their first counted model request. Displayed dates and daily accounting
keep using the first counted model request, independently of ordering; assistant responses, tool
results, and metadata do not move a session.

Each session page shows figures (including the startup's tokens, KiB, tools, context files, and
skills), the context per request stacked by section, the startup's parts as one bar, and a parts
table nested by section (startup, conversation, tool calls, tool results, other) that opens on
click, with context and consumed tokens, their shares and ratio, KiB, how many times each part
occurred, and, for averages, how many sessions it appeared in. Then where time goes, and
compaction summaries. A parent shows its subagent runs (cost, report, compression, kept out,
parent re-send, ending, parallelism), a run shows its delegation, and an agent's average shows
its efficiency (median compression, startup overhead, budget stops).

Figures an agent does not record show `-`. Claude Code's figures are approximate where its
transcripts lack detail:

- The context is the transcript path plus the recorded system prompt and tools; the server's
  context edits are not recorded.
- Thinking text is not kept; its context size is estimated from its tokens.
- Cost is the API-equivalent price: each request's tokens at per-model rates derived from the
  session cost totals Claude Code records.
- Compaction runs' tokens, subagent notes and corrections, and permission prompt waits are not
  recorded; the latter count as tool time.
- `claude -p` (SDK) runs are left out.
