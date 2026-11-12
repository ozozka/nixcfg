---
description: Workflow - spec a plan into the roadmap, or exec a plan from it
argument-hint: "spec <idea> | exec [instructions]"
---

# Workflow

Run the stage named by the first word of the arguments (`spec` or `exec`); the rest of the
arguments are its input. Arguments: $ARGUMENTS

The roadmap holds the plan, git holds the work, and the project's documentation holds the
lasting knowledge, so any session can continue from them.

## Roadmap board

- The roadmap is the only place for plans and task lists.
- The board is `docs/roadmap.md` or the `## Roadmap` section of `README.md` when it already has
  `Plans`, `Active`, and `Completed` sections; otherwise a root `roadmap.md`, created with
  `# Roadmap` and the sections below. Never add a board to a roadmap that is only an overview.
- Six sections, headings one level below the roadmap's own heading, in this order; add missing
  ones in place:
  - **Status**: the general overview, free text.
  - **Limitations**: limitations worth noting, free text.
  - **Backlog**: ideas not specified yet, one line each.
  - **Plans**: specified plans ready to start.
  - **Active**: plans in progress; their step checkboxes show what is done.
  - **Completed**: one line per delivered capability.
- Work moves Backlog → Plans → Active → Completed. Other text stays as it is.

## Plan format

- A plan is a heading one level below its section, naming it; everything else is nested
  bullets.
- Bold top-level bullets group the plan: `**Goal**`, `**Findings**`, `**Decisions**`,
  `**Specification**`, and `**Steps**`; leave out groups with nothing to say.
- Each step is a bullet under `**Steps**`: `[ ]`, or `[x]` once done, then its bold number and
  title, such as `- [ ] **3. Acquisition thread**: details`, with sub-bullets when needed.
- A step is an ordered, atomic unit of work and becomes one commit. A plan large enough to need
  phases becomes several plans.

Example (in a roadmap whose sections are `##` headings):

```markdown
## Plans

### Offline mode

- **Goal**: The app works without a connection and syncs when it returns.
- **Decisions**:
  - Local SQLite cache; the server stays authoritative.
- **Steps**:
  - [ ] **1. Cache layer**: read-through cache for documents.
  - [ ] **2. Sync queue**: queued writes replayed on reconnect.
```

## spec

Shape a plan for the idea in the input, without changing the project.

- Stay read-only apart from the roadmap: no edits to code or documentation.
- Read the relevant code and documentation first; use subagents for broad searches.
- Ask the user every decision that belongs to them, with structured questions, instead of
  guessing.
- Write the plan into the board's Plans section in the plan format; replace an existing plan
  with the same name instead of adding a second one.
- Write it for exec, which works through the steps without stopping and stops when a finding
  contradicts a decision:
  - Each step is ordered, self-contained, verifiable on its own, and small enough for one
    commit; it names the files or functions it changes and the checks that prove it.
  - Each step includes the documentation changes its behavior needs.
  - Decisions are explicit, since exec checks its findings against them.
- End with a short summary of the plan and its decisions, then ask whether to start executing.
  On yes, continue with exec.

## exec

Carry out a plan; the input can name the plan or add instructions.

- Pick the plan: the one named in the input or just written in spec, otherwise the only one in
  Active. Ask if it is ambiguous. Move a plan from Plans to Active when its first step starts.
- Work through the unticked steps in order, without stopping for approval between them:
  1. Implement the step.
  2. Move lasting content (behavior, contracts, decisions) into the documentation section that
     owns it.
  3. Run the project's checks for the change.
  4. Tick the step in the roadmap, then make one focused commit with exactly the step's changes,
     its documentation, and the tick, and nothing else.
- Stop and report when a step is blocked, a check keeps failing, or a finding contradicts a
  decision of the plan; never tick a step whose checks fail.
- When all steps are ticked, finish:
  1. Have a subagent review the plan's changes against the plan and the documentation
     placement; fix and commit what it finds.
  2. Check that the plan's lasting content is in the documentation.
  3. Replace the plan with one line per delivered capability in Completed, and commit.
