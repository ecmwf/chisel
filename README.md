# Numerical Code Port

Fidelity-preserving translation of numerical codebases from a SOURCE language to a
TARGET language (and, where applicable, onto a new execution model), executed with
agentic coding assistants (Claude Code and opencode) under human domain-expert
direction.

## What we are trying to achieve

Valuable numerical codebases outlive the languages and hardware they were written
for. Rewriting them is risky in a way ordinary software is not: the most dangerous
bugs are silent physics errors that compile cleanly, run plausibly, and only show up
deep into production-scale runs. This repo exists to make such a translation
**trustworthy**:

- **Preserve the science, provably.** The original code is treated as the
  specification; the port must reproduce its behavior, demonstrated by evidence at
  every stage rather than by inspection or trust.
- **Convert silent failures into loud, localized ones.** Differential tooling and a
  tiered validation ladder are built before any translation, so a mistake fails a
  cheap gate immediately instead of corrupting results months later.
- **Make a long, multi-session effort cumulative.** All project state, every lesson,
  and every accepted decision live in versioned files; any session, by any agent or
  human, can pick up the work without repeating a mistake already paid for.
- **Validate the workflow before betting on it.** A pilot port of a small program
  exercises every mechanism end to end; only then does a large port run in the same
  structure.

The methodology is language-agnostic. The languages, the program under port, and every
acceptance criterion of the **current instantiation** are defined in one place:
`port/plan/00-charter.md`.

## The doctrine

Translate literally in stages, validate each stage at the strictest criterion it can
physically meet, build the differential tooling before you need it, and persist every
lesson to disk so no session repeats a mistake another session already paid for.

## Start here

| You are | Read |
|---|---|
| An agent starting a session | `AGENTS.md`, then run `/session-start` |
| A human reviewing | `port/plan/00-charter.md` (the constitution), `docs/evidence/` |
| Anyone needing the methodology | `.claude/skills/code-port/SKILL.md` + its `references/` |

## Layout

- `source/` - SOURCE at pinned commit (read-only by convention)
- `target/` - the port; builds and runs at every commit
- `reference/` - canonical reference-run definitions and checksums
- `tools/` - differential tools, gate scripts, conformance checks, scoping tooling
- `port/` - durable project state: charter & plans, TRACE matrix, LESSONS,
  KNOWN-DIVERGENCES, handoffs, coordination, retrospectives
- `docs/evidence/` - gate evidence packs for sign-off
- `.claude/` - canonical skill + slash commands; `.opencode/` symlinks to the same

## Ground rules (full set in AGENTS.md)

The SOURCE is the specification. Literal translation only. Every claim about the
SOURCE cites file:line. The configuration is pinned. One change of dimension per
stage. Runnable at every commit; milestone = git tag. State lives in files, not in
conversation. No gate is self-certified.
