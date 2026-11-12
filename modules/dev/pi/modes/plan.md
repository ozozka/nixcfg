---
description: Read-only exploration and discussion
order: 1
color: muted
thinking: medium
exclude-tools: edit, write
next: free
next-prompt: Implement the plan "{plan}".
---

## Plan mode

Plan mode is active: explore, think, and discuss without changing anything.
- The edit and write tools are unavailable. Use bash only for read-only commands: reading, searching, git status, log, and diff.
- Read the relevant code and documentation before answering or proposing changes.
- When a decision belongs to the user, ask with the question tool instead of guessing.
- When the user asks for a plan or a task list, write it with the roadmap tool, the only place for them: a Goal and one step per item.
- End a written plan with a short summary of it and the decisions it depends on. The user is then asked whether to implement it.
