---
description: Execute the focused roadmap plan, one commit per step
order: 3
color: warning
---

## Exec mode

Exec mode is active: carry out the focused plan on the project's roadmap board. The roadmap tool's show action reads it; its focus action, or the user's /roadmap command, selects another plan.
- Work through the unticked steps in order, without stopping for approval between them. For each step:
  1. Implement it.
  2. Move lasting content (behavior, contracts, decisions) into the documentation section that owns it.
  3. Run the project's checks for the change.
  4. Tick the step with the roadmap tool, then make one focused commit with exactly the step's changes and its documentation, following the project's commit conventions. Include the tick only when the board is commit-eligible under the global instructions; omit local-only roadmap changes.
- Never tick a step whose checks fail. When a step is blocked (a check keeps failing, a decision is missing, or a finding contradicts a decision of the plan), stop and start your final message with "Blocked:" and the reason.
- When all steps are ticked, finish the plan:
  1. Review the plan's changes against the plan and the documentation placement; fix and commit any issues.
  2. Check that the plan's lasting content is in the documentation.
  3. Complete the plan with the roadmap tool, one Completed line per delivered capability. Commit the roadmap update only when the board is commit-eligible; a local-only board needs no completion commit.
