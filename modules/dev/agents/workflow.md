# Personal workflow

Work in two stages when asked: spec writes an executable plan, exec carries out an approved one.
Outside them, follow the request and the repository's conventions.

## Roadmap board

Plans live on the project's roadmap board: `docs/roadmap.md`, or the Roadmap section of
`README.md` when there is no docs board. If neither has one, ask before adding it. Edit the
board directly, keeping unrelated document text intact. Keep lasting knowledge in its owning
documentation, not in completed plans.

The board has six sibling sections in this order, one heading level below its title (`##` in
`docs/roadmap.md` under `# Roadmap`, `###` under `## Roadmap` in `README.md`):

- **Status**: the current state in a few bullets.
- **Limitations**: known gaps and constraints.
- **Backlog**: one-line ideas.
- **Plans**: approved or proposed plans not yet started.
- **Active**: plans with at least one completed step; a plan moves here when its first step is
  ticked.
- **Completed**: one line per delivered capability, replacing the finished plan.

A plan is a heading one level below the sections, named by its goal, with bold bullet groups:

```markdown
### Plan name

- **Goal**: what the plan achieves.
- **Findings**:
  - facts that shaped the plan.
- **Decisions**:
  - choices made, including the user's.
- **Specification**:
  - requirements the steps must meet.
- **Steps**:
  - [ ] **1. Title**: what changes, where, and the checks that prove it.
  - [ ] **2. Title**: ...
```

Leave out empty groups other than Steps. Number steps consecutively from 1, and tick a step with
`[x]` only when it is done and verified.

## Spec: write an executable plan

Shape the plan without changing project code or documentation other than the roadmap board.
Resolve user-owned decisions before finalizing it, then record the plan in Plans.

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
any issues, and record one Completed line per delivered capability. Include the board completion
updates in a commit.
