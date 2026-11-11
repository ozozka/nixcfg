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
