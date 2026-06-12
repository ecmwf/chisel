<p align="center">
  <img src="logo.png" alt="Project logo" width="320">
</p>

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

## How to work with this repo

1. **Bring the SOURCE.** The program being ported goes into `source/` at a pinned
   commit (read-only from then on). Together with the human, pin the configuration
   and define the canonical reference run in `port/plan/00-charter.md` (Phase 0).
2. **The port grows in `target/`.** It must build and run at every commit;
   rendering rules live in `target/CONVENTIONS.md` once instantiated at Phase 1.
3. **Work in short sessions.** `/session-start` loads the state files and the one
   task for this session; do that task; `/session-end` persists everything for the
   next session. Capture lessons the moment they happen with `/lesson`.
4. **Validate, never trust.** Run gates with `/gate`, prove new detectors with
   `/seeded-bug`, get ported modules independently reviewed with `/review-module`.
   All evidence lands in `docs/evidence/`.
5. **Milestones need the human.** A phase or milestone is accepted only by the
   domain expert's recorded sign-off (prepared with `/evidence-digest`), then
   git-tagged.

The binding rules live in `AGENTS.md`; the full methodology in the two skills under
`.claude/skills/`.
