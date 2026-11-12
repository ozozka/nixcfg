# Exec: carry out the approved plan

Carry out the selected approved plan. If it is missing or ambiguous, ask which plan to use. Work
through unticked steps in order without asking for approval between them:

1. Implement the step and update the documentation that owns any changed behavior.
2. Run the relevant project checks. Never mark a failing step complete.
3. Mark the step complete, then make one focused commit containing its changes and any
   project-backed plan updates, following repository conventions.

Stop and explain the blocker if checks keep failing, a decision is missing, or a finding
contradicts the plan.

After all steps, review the changes against the plan and documentation ownership, fix and verify
any issues, and record one Completed line per delivered capability. Include project-backed
completion updates in a commit; session-local progress requires no file or separate commit.
