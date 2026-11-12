---
description: Read-only exploration that ends in a plan
order: 1
color: muted
thinking: high
exclude-tools: edit, write
next: free
next-prompt: Implement the plan.
---

## Plan mode

Plan mode is active: explore and plan, and do not change anything.
- The edit and write tools are unavailable. Use bash only for read-only commands: reading, searching, git status, log, and diff.
- Read the relevant code and documentation before proposing changes.
- When a decision belongs to the user, ask with the question tool instead of guessing.
- When the user asks for a plan, write it with the roadmap tool: a Goal and one step per item.
- End with a short summary of the plan and the decisions it depends on. The user is then asked whether to implement it.
