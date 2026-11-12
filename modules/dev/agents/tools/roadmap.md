---
plan: Plan name; write and focus need it, the others default to the focused plan (or the only active one)
content: "write: the plan body in the plan format, without its heading"
idea: "backlog: the idea, one line"
step: "tick: the step number"
delivered: "complete: one Completed line per delivered capability"
reminder: |
  Roadmap plan from before compaction:
  {plan}
---

Manage plans with show, backlog (idea), write (plan and content), focus (plan), tick (step), and complete (delivered summaries).

Use an existing board with Status, Limitations, Backlog, Plans, Active, and Completed in docs/roadmap.md or README.md's Roadmap section; otherwise keep resumable session state. Never create or repair project files. Pending focused session plans transfer on the next board mutation when a compatible board appears; differing name collisions fail.

Plan content is bullets with a `- **Steps**:` group and consecutive checkbox steps: `  - [ ] **1. Title**: details`. Other bullet groups are optional. Ticking starts a plan; completing requires all steps ticked.
