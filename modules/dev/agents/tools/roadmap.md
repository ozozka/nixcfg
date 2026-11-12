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

Manage plans in a complete six-section board in docs/roadmap.md or README.md's Roadmap section; otherwise use resumable session state. Sections: Status, Limitations, Backlog, Plans, Active, Completed. Never create or repair a project board. Results identify project or session storage. Pending focused session plans transfer on the next board mutation when a compatible project board becomes available; conflicts are errors.
Actions:
- show: the board's plans and the focused plan's text.
- backlog: add an idea to Backlog as one line.
- write: add a plan to Plans, or replace an existing plan's body where it is; focuses it.
- focus: make a plan the one this session works on.
- tick: mark a step done; the plan moves from Plans to Active on its first tick.
- complete: when all steps are ticked, replace the plan with Completed lines.
Plan format (the body, without the heading): bullets only; bold groups `- **Goal**:`, `- **Findings**:`, `- **Decisions**:`, `- **Specification**:`, and `- **Steps**:`, leaving out empty ones; each step under Steps is `  - [ ] **1. Title**: details`, numbered from 1.
