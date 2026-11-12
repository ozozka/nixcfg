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

Manage plans on the project's roadmap board: docs/roadmap.md or README.md's Roadmap section when they have one, otherwise a root roadmap.md (created on the first change). The board has six sections: Status and Limitations (free text, edited like other documentation), Backlog, Plans, Active, and Completed.
Each result identifies the board path and whether it is commit-eligible or local-only. The global instructions define which roadmap files may be committed.
Actions:
- show: the board's plans and the focused plan's text.
- backlog: add an idea to Backlog as one line.
- write: add a plan to Plans, or replace an existing plan's body where it is; focuses it.
- focus: make a plan the one this session works on.
- tick: mark a step done; the plan moves from Plans to Active on its first tick.
- complete: when all steps are ticked, replace the plan with Completed lines.
Plan format (the body, without the heading): bullets only; bold groups `- **Goal**:`, `- **Findings**:`, `- **Decisions**:`, `- **Specification**:`, and `- **Steps**:`, leaving out empty ones; each step under Steps is `  - [ ] **1. Title**: details`, numbered from 1, one commit each.
