# Numerical Code Port

Fidelity-preserving translation of numerical codebases from a SOURCE language to a
TARGET language (and, where applicable, onto a new execution model), executed with
agentic coding assistants (Claude Code and opencode) under human domain-expert
direction.

The methodology is language-agnostic. The languages, the program under port, and every
acceptance criterion of the **current instantiation** are defined in one place:
`port/plan/00-charter.md`. A **pilot** port of a small program validates the full
workflow before any large port runs in the same structure.

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
