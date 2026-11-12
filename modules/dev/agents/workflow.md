# Personal workflow

Work in two stages when asked: spec writes an executable plan, exec carries out an approved one.
Outside them, follow the request and the repository's conventions.

## Plan storage

Plans live on a roadmap board. Use the roadmap tool when it is available; otherwise edit the
board directly. The project's board is `docs/roadmap.md` or the Roadmap section of `README.md`
when it already has these six sibling sections in order: Status, Limitations, Backlog, Plans,
Active, Completed. Prefer the docs file when both qualify.

Otherwise use the private board `.roadmap/roadmap.md` at the repository root. When it is
missing, create it with a `# Roadmap` heading and the six `##` sections, plus
`.roadmap/.gitignore` containing `*` so git ignores the folder. Never create or restructure
project documents for a board. A plan is a `###` heading in Plans, moving to Active when its
first step is ticked; a completed plan is replaced by one line per delivered capability in
Completed. Keep lasting knowledge in its owning documentation, not in completed plans.

## Spec: write an executable plan

Shape the plan without changing project code or documentation. Resolve user-owned decisions
before finalizing it.

Record the plan with the available planning tools. Use nested bullets under Goal, then Findings,
Decisions, and Specification where useful, followed by Steps. Number checkbox steps from 1, for
example `- [ ] **1. Title**: details`.

Each step is ordered, independently verifiable, and sized for one focused commit. Name the files
or functions it changes, the checks that prove it, and any necessary documentation updates. Make
decisions explicit so execution can identify contradictions.

End with a short summary and ask whether to execute. Do not start execution automatically.

## Exec: carry out the approved plan

Carry out the selected approved plan. If it is missing or ambiguous, ask which plan to use. Work
through unticked steps in order without asking for approval between them:

1. Implement the step and update the documentation that owns any changed behavior.
2. Run the relevant project checks. Never mark a failing step complete.
3. Mark the step complete, then make one focused commit containing its changes and any project
   board updates, following repository conventions.

Stop and explain the blocker if checks keep failing, a decision is missing, or a finding
contradicts the plan.

After all steps, review the changes against the plan and documentation ownership, fix and verify
any issues, and record one Completed line per delivered capability. Include project board
completion updates in a commit; the private board is never committed.
