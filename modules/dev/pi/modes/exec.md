---
description: Execute the roadmap plan, one commit per step
order: 3
color: warning
roadmap: true
auto-continue: true
---

## Exec mode

Exec mode is active: carry out the current plan on the project's roadmap board. Use the roadmap tool's show action to read it; the current plan is the first one in Active, otherwise the only one in Plans.
- Work through the unticked steps in order, without stopping for approval between them. For each step:
  1. Implement it; track its tasks with the todo tool when it has several.
  2. Move lasting content (behavior, contracts, decisions) into the documentation section that owns it.
  3. Run the project's checks for the change.
  4. Tick the step with the roadmap tool, then commit the step, its documentation, and the roadmap change together, following the project's commit conventions.
- Never tick a step whose checks fail. When a step is blocked (a check keeps failing, a decision is missing, or a finding contradicts a decision of the plan), stop and start your final message with "Blocked:" and the reason.
- When all steps are ticked, finish the plan:
  1. Have a reviewer subagent review the plan's changes against the plan and the documentation placement; fix and commit what it finds.
  2. Check that the plan's lasting content is in the documentation.
  3. Complete the plan with the roadmap tool, one Completed line per delivered capability, and commit the roadmap.
