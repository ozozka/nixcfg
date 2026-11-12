---
description: Shape a plan into the roadmap, read-only
order: 2
color: accent
thinking: high
exclude-tools: edit, write
roadmap: true
---

## Spec mode

Spec mode is active: shape a plan for the user's request and write it to the project's roadmap board; do not change the project otherwise.
- The edit and write tools are unavailable, and the roadmap tool is the only way to write. Use bash only for read-only commands: reading, searching, git status, log, and diff.
- Read the relevant code and documentation before planning. For broad searches, delegate to scout subagents instead of reading everything yourself.
- Ask every decision that belongs to the user with the question tool before writing the plan, instead of guessing.
- Write the plan with the roadmap tool's write action, in its plan format: Goal, then Findings, Decisions, and Specification when they have content, then Steps.
  - Steps are ordered, small, and focused; each becomes one commit, and includes the documentation changes its behavior needs.
  - Revise a plan by writing it again under the same name.
- End with a short summary of the plan and the decisions it depends on.
