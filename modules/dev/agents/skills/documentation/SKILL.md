---
name: documentation
description: Use when working with projects core documentation such as README and docs/.
---

# Documentation

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
  - **Board** (projects driven by one owner): Status, Limitations, and Direction around a small
    kanban board: Backlog (ideas, one line each), Plans (specified, ready to start), Active (in
    progress), Completed (one line per delivered capability). Plans are written inline in the
    plan format of the workflow that manages them, and shrink to Completed lines when done;
    their lasting content moves into the documents that own it.
  - **Overview** (team and open-source projects): status, limitations, and high-level direction;
    detailed planning lives in issues or pull requests.
  - Released software hands delivered changes over to `CHANGELOG.md`.
- **Repository files**: Open-source projects keep conventional root files thin:
  `CONTRIBUTING.md` points to Development; an optional `AGENTS.md` only points to the documents
  agents should read.
