# Workflow

Work in two stages when asked: plan writes an executable spec, free carries out an approved one.
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
- **Findings**: facts that shaped the plan.
- **Decisions**: choices made, including the user's.
- **Specification**: requirements the steps must meet.
- **Steps**:
  1. [ ] **Title**: what changes, where, and the checks that prove it.
  2. [ ] **Title**: ...
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

- Before writing documentation, find the section that already owns the subject: edit it there,
  link to it elsewhere, and replace outdated text instead of appending. Implementation details
  belong in source comments next to the code.
- Commit only when asked or when the active workflow says so, in focused, atomic commits.

- Read the relevant code and documentation before changing them; extend existing owners instead
  of adding parallel implementations.

## Documentation

Use when working with projects core documentation such as README and docs/.

Scope of this skill is projects core documentation, a separate documentation such as web pages,
presentations, reports are out of the scope if they not contain files and parts explained below.

- **Philosophy**: Documentation follows Lean and Agile principles: pragmatic and maintainable.
- **Goal**: A cohesive, complete, accurate, and non-redundant body of essential knowledge.
- **Purpose**: Preservation of knowledge that code and tests cannot adequately communicate.
  - **Intent and rationale**: Decisions, constraints, and trade-offs.
  - **Knowledge preservation**: Architecture, concepts, and requirements.
  - **Practical guidance**: Information needed to use, develop, and maintain the software.
- **Principles**:
  - **Simplicity**: Documentation remains concise, relevant, and proportional to its value.
  - **Consistency**: Changes preserve the existing organization, conventions, and terminology.
  - **Change scope**: Changes remain focused, atomic, and limited to the relevant scope.
  - **Single source of truth**: Each concern has one authoritative source; others reference it.
  - **Code as documentation**: Code is the most detailed specification of its implementation.
  - **Locality**: Information resides close to its subject.
    - Documentation provides context, broader concepts and guidance.
    - Source comments explain internals and implementation details close to the relevant source.
  - **Separation of concerns: High cohesion, low coupling**:
    - Each document and section has a distinct, cohesive responsibility.
    - Clear boundaries and minimal coupling form a unified, non-overlapping documentation.
  - **Current-state accuracy**:
    - Documentation reflects the present system rather than its evolution.
    - Outdated descriptions are replaced, not accumulated as comparisons or change logs.
    - Historical context remains only when relevant to current decisions.
- **Patterns**:
  - **Language**: Documentation uses a descriptive, precise, concise, factual, and neutral tone.
  - Bullets take precedence over tables when they communicate information clearly.
  - Mermaid diagrams use a horizontal layout where practical.
- **Structure**: Documents are split by audience; each has one responsibility and states what it
  does not hold. A project uses only the documents it needs.
  - **About** (everyone, why): overview, background, scope, audience, goals, concepts, FAQ; team
    and communication for team projects. Not how-to steps or exact contracts.
  - **Manual** (users, how to): getting started, installation, usage, guides, examples. Shows
    how; links to Reference instead of listing every option.
  - **Reference** (users and integrators, exactly what): interfaces, inputs and outputs, file
    formats, configuration keys, environment variables, glossary; the design system for UI
    projects. Authoritative for exact behavior; no rationale or tutorials.
  - **Architecture** (contributors, how it is built and why): principles, code map (where things
    are), components, data, current decisions with their rationale. Not change procedures or
    code-level detail.
  - **Development** (contributors, how to change it): setup, workflow, standards, quality gates,
    delivery. Repository layout belongs to the code map; tool internals belong beside the tool.
  - **Roadmap** (everyone, where it stands): status, limitations, direction, and the planning
    shape the project uses.
  - Non-software projects map Manual to methodology and Reference to sources, data dictionary,
    and glossary; Architecture describes the analysis pipeline or is omitted.
- **Placement**: Each new fact gets exactly one home.
  1. Readable from code, tests, or command help: write nothing, or a source comment when not
     obvious.
  2. Internals of one module: a source comment at that module.
  3. Future or planned work: Roadmap.
  4. For users: why → About, how → Manual, exact facts → Reference.
  5. For contributors: how it is built → Architecture, how to change it → Development.
  6. Find the section that already owns the subject first: edit it there, link to it elsewhere,
     and replace outdated text instead of appending.
- **Levels**: Documentation grows in three levels, moving to the next when a document gets hard
  to scan or mixes topics.
  1. Sections of `README.md`.
  2. One file per document, such as `docs/development.md`; `README.md` keeps the overview and an
     index of the documents and their responsibilities.
  3. Topic files under a document: `docs/development/testing.md`; topic names are free, the
     parent document keeps its overview and links.
- **Roadmap shapes**:
  - **Board** (projects driven by one owner): use the project's chosen planning structure. Keep
    actionable plans distinct from lasting documentation and summarize completed work rather
    than accumulating obsolete plans.
  - **Overview** (team and open-source projects): status, limitations, and high-level direction;
    detailed planning lives in issues or pull requests.
  - Released software hands delivered changes over to `CHANGELOG.md`.
- **Repository files**: Open-source projects keep conventional root files thin:
  `CONTRIBUTING.md` points to Development; an optional `AGENTS.md` only points to the documents
  agents should read.
