# AGENTS.md - normative instructions for all agents and humans

This repository hosts the **port of a numerical codebase from a SOURCE language to a
TARGET language**, executed with agentic coding assistants under human domain-expert
direction. The current instantiation (languages, program, acceptance criteria) is
defined in `port/plan/00-charter.md`. A pilot port of a small program runs first to
validate the full workflow; the large port follows in the same structure.

The complete methodology lives in two skills: **code-port** (what is translated and
how it is validated) and **target-conventions** (how the translation is rendered:
naming, comments, types, semantic trap tables), both under `.claude/skills/`. This
file is the entry point and the contract; when in doubt, the skills and the charter
govern.

## Prime directives (non-negotiable; restate at every session start)

1. **The SOURCE is the specification.** Any divergence of the port from SOURCE
   behavior is a port bug by definition. Never debate the science.
2. **Literal translation.** Never improve, simplify, approximate, or modernize. Only
   the mechanical transformations listed in the charter are permitted; deliberate
   departures require human authorization as named exceptions.
3. **Cite file:line for every claim about the SOURCE** - especially constants. Quote
   the literal text read this session. Never trust comments or memory.
4. **Pin the configuration first.** Only the charter's pinned configuration is being
   ported; record provenance for every effective value.
5. **One change of dimension per stage.** Language and execution model never change
   together.
6. **Runnable and verifiable at every commit.** Milestone passed = git tag.
7. **Short sessions, durable files.** State lives in `port/`, not in conversation.
8. **Never self-certify a gate.** Present evidence (`docs/evidence/`) and ask the
   human.

## Session protocol (mandatory)

- **Start:** run `/session-start` (or follow `.claude/commands/session-start.md`
  manually): handoff → standing rules → plan section → known divergences → restate
  directives → confirm scope.
- **During:** stay within the single task in the handoff. Capture lessons the moment
  they happen (`/lesson`). Run gates via `/gate`.
- **End:** run `/session-end`: update plan + TRACE, append lessons, rewrite handoff,
  commit state with code.

## Repository map

| Path | What it is |
|---|---|
| `source/` | SOURCE code at the pinned commit. **Read-only by convention** - never edit; instrumentation goes through the charter. |
| `target/` | The port. Must build and run at every commit. |
| `target/CONVENTIONS.md` | Frozen rendering conventions (naming, comments, types, trap table). Read before writing any TARGET code; instantiated at Phase 1 from the target-conventions skill. |
| `reference/` | Canonical reference run definitions + checksums (`runs.md`). Artifacts live outside git; this dir holds the immutable descriptions. |
| `tools/diff/` | Differential tools (six classes - see skill references). |
| `tools/gates/` | Validation-ladder gate scripts (R0–R5), CI-callable. |
| `tools/conformance/` | Purity/convention checks (index helpers only, sizing rules, …). |
| `tools/scoping/` | Live-subset determination tooling. |
| `port/plan/00-charter.md` | **The constitution**: pinned config, acceptance criteria, named exceptions, mechanical transforms, placeholders. |
| `port/plan/` | Phase plans and `modules/` cards; milestones mirrored as git tags. |
| `port/TRACE.yaml` | Source→target traceability matrix; CI completeness check is a Phase 1 deliverable. Enforcement status table: `tools/README.md`. |
| `port/LESSONS.md` | Global append-only lessons ledger + STANDING RULES. Searched by Class tags, never read linearly. |
| `port/lessons-archive/` | Closed ledger entries, moved here at phase retrospectives. L-numbers permanent. |
| `port/KNOWN-DIVERGENCES.md` | Accepted differences - consult FIRST when debugging; do not chase. |
| `port/handoffs/` | One handoff per workstream (single stream: `main.md`). |
| `port/COORDINATION.md` | Workstream locks, interface contracts, merge order. |
| `port/retrospectives/` | Phase-boundary retrospectives. |
| `docs/evidence/` | Gate evidence packs for human sign-off. |

## Tooling note (Claude Code + opencode)

This repo is used by both Claude Code and opencode agents simultaneously.
- `CLAUDE.md` is a symlink to this file. opencode reads `AGENTS.md` natively and
  prefers it over CLAUDE.md.
- The skills and slash commands are canonical under `.claude/` and symlinked into
  `.opencode/` (`skill/`, `command/`). Edit the canonical copies only.
  Verified against opencode's implementation: its discovery follows symlinks; it
  also reads `.claude/skills/` natively (so the skill symlink is redundancy against
  that compat being disabled), but it does NOT read `.claude/commands/` - the
  command symlink is load-bearing. Command files need a `description` frontmatter
  key and a non-empty body (the body is the template; $ARGUMENTS is supported).
- Commands: `/session-start`, `/session-end`, `/lesson`, `/gate`, `/review-module`,
  `/seeded-bug`, `/evidence-digest`, `/upstream`.

## The two layers (reuse model)

This repo is a reusable workbench: every port starts from a fresh clone/fork of the
base repo, fills the project layer, and feeds improvements back to the base.

- **Methodology layer** (project-agnostic, upstreamable): `.claude/` skills and
  commands, `AGENTS.md`, `README.md`, generic scripts in `tools/`, the templates,
  `.github/`. Improvements here belong to every future port.
- **Project layer** (this port only, never upstreamed): `source/`, `target/`,
  `port/`, `reference/`, `docs/evidence/`.

**Commit discipline: never mix the two layers in one commit.** A methodology
improvement made mid-port must be its own commit so it can be cherry-picked to the
base repo cleanly. At phase retrospectives and at project end, run `/upstream` to
distill and propose what generalizes (human approves what flows up).

## Hard rules for this repo

- Never modify `source/` content or the canonical reference run definition.
- Never weaken a gate, tolerance, or floor without human sign-off recorded in the
  charter; never delete or rewrite LESSONS ledger entries (append-only).
- No TRACE entry reaches `gated` without an independent fidelity review
  (`/review-module`) by a session not listed in the entry's `author_sessions`, with
  the report recorded in `docs/evidence/`. The gate field cites tier R1 or higher,
  never R0.
- No gate or probe is used for real until it has a current red-then-green
  seeded-bug record (`/seeded-bug`, template in the code-port skill assets).
- `gated` is a technical status. Phase/milestone acceptance is the human's
  SIGNOFF.md in the evidence pack; a milestone tag is created only after it exists.
- The methodology stays self-contained: do not cite external papers, authors, or
  other projects' numbers as provenance for rules or values. Provenance is always
  this repo's SOURCE, charter, or LESSONS.
- Question instructions, including the human's: if a request would weaken a gate,
  add unenforced complexity, or conflict with the charter, say so with reasons and
  propose the alternative before complying. The human still has the final word;
  silent compliance is not loyalty.
- Every file status change lands in `port/TRACE.yaml` in the same session.
- Mechanical mass-edits are performed by scripts committed to `tools/`, not by hand.
- All state files are committed together with the code they describe.
- **No em-dashes anywhere** in this repository: not in code, comments, docs, plans,
  state files, or commit messages. Use a plain hyphen, a colon, or restructure the
  sentence. (Enforced: files via `tools/conformance/no-emdash.sh`, latest commit
  message via CI.)
