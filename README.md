<p align="center">
  <img src="logo.png" alt="Project logo" width="320">
</p>

# Numerical Code Port

Fidelity-preserving translation of numerical codebases from a SOURCE language to a TARGET language
(and, where needed, onto a new execution model), run with agentic coding assistants (opencode) under
human domain-expert direction.

Rewriting numerical code is uniquely dangerous: the worst bugs are silent physics errors that compile
cleanly, run plausibly, and only surface deep into a full-scale run. This methodology makes such a
translation **trustworthy**:

- **Preserve the science, provably** - the original is the specification; the port reproduces its
  behavior by evidence at every stage, never by inspection.
- **Turn silent failures into loud, localized ones** - the differential tooling and the tiered
  validation ladder are built *before* any translation, so a mistake fails a cheap gate at once.
- **Make a long effort cumulative** - all state, lessons, and decisions live in versioned files; any
  sprint, by any agent or human, picks up without repeating a paid-for mistake.

> **Doctrine:** translate literally in stages, validate each stage at the strictest criterion it can
> physically meet, build the differential tooling before you need it, and persist every lesson so no
> sprint repeats a mistake another already paid for.

The methodology is language-agnostic; the languages, the program, and every acceptance criterion of a
given port live in one file, `port/plan/00-charter.md`. The shipped tooling baseline is tuned for a
**C target (Fortran → C)**; a different TARGET extends it at Phase 1. The methodology's own release
version is whatever `VERSION` says (semantic versioning).

## Quick start

```bash
# interactive; add --dry-run to preview (changes nothing)
git clone <base-repo-url> port-foo && cd port-foo
python3 tools/chisel-init.py
```

`chisel-init` is the guided front door. It checks your tooling, asks whether you are **starting** a
new port or **contributing** to one, then does the cloning/wiring and picks each agent's model -
asking before anything that writes, clones, or pushes:

- **New port** flips this clone into your own **instance** (the *workbench*, where all state lives),
  creates the separate clean **product repo** for the ported code, and can import the SOURCE at a
  pinned commit.
- **Contribute** clones an existing instance and wires it to pull base improvements while you work.

Then open the agent and run **`/port-sprint-start`** - it loads the handoff and names your one task.

## How a port flows

```mermaid
flowchart TD
  A([chisel-init]) --> B[Phase 0 - Scoping<br/>pin SOURCE, charter, reference run]
  B --> C[Phase 1 - Tooling<br/>build the gates and diff tools first]
  C --> D[Phase 2 - Translation<br/>focused sprints, one module each, in parallel]
  D --> E{R1+ gate passed and<br/>independent review clean?}
  E -- no --> D
  E -- yes --> F[Integrate into the product repo<br/>+ audit manifest]
  F --> G([Human sign-off, then git tag])
```

Work happens in **sprints** (one bounded chunk - a module and its checks - in one session), grouped
into **phases** (0 scoping, 1 tooling, 2 translation, ...). The human signs off at phase and milestone
boundaries, not after every sprint. Each sprint runs in a fresh conversation; the handoff carries the
baton, so no context is hand-copied between them.

## The agents

Four roles with deliberately-separated powers - the one who carves is not the one who reviews, and the
one who schedules is not the one who records or merges, so no single agent can both do work and bless it:

- **Ptah-Orchestrator** - the scheduler and your front door: **this is the agent you talk to.**
  Derives the ready-set, dispatches work to the workers, reports human-readable status, and (opt-in)
  drives auto-mode; never reviews, merges, or self-certifies.
- **Kha-Worker** - the worker. Carves one claimed piece into the TARGET on its own branch/worktree;
  authors and gates it and requests review, but never reviews, merges, or pushes. Many run in parallel.
- **Seshat-Integrator** - the single integration funnel. Orders, preflights, attests, and records the
  audit manifest and canonical TRACE; the merge keystroke stays human-/charter-gated.
- **port-review** - the independent fidelity reviewer, in its own clean, separate session (ideally a
  different model than the author).

`chisel-init` sets each agent's model and reasoning effort in an instance-owned `opencode.json`. Defaults:

- **Ptah-Orchestrator** and **Seshat-Integrator** → a stronger model
- **Kha-Worker** → a capable, lower-cost model (there are many parallel workers)
- **port-review** → a distinct reviewer model (a stronger independence control than a different session alone)
- **effort** → `high` for every role (written as opencode's provider-agnostic `variant`, validated against the chosen model's provider); raise the reviewer to `xhigh` or the Anthropic agents to `max` for maximum scrutiny

## The commands

You only ever need **`/port-sprint-start`** and **`/port-sprint-end`** - the agent proposes the rest at
the right moment (anything that produces evidence, or that you might forget, has a command):

| Command | When |
|---|---|
| `/port-sprint-start` | First thing in every new conversation - loads the handoff, names the one task |
| `/port-sprint-end` | Task done, or ballooned, or you are stepping away - saves state, writes the next task |
| `/port-lesson` | The moment something surprising happens (a bug, a failed gate, a broken assumption) |
| `/port-gate` | A deliverable is done and its criterion is a script - run the tier, record the evidence |
| `/port-seed` | A new or changed gate/detector - prove it goes red then green before its result is trusted |
| `/port-review` | A module passed its gate - independent walk in a FRESH session; a clean verdict unlocks `gated` |
| `/port-digest` | A phase/milestone is complete - compile the evidence pack + a prefilled `SIGNOFF.md` |
| `/port-sync-with-base` | Pull base methodology improvements into this instance |
| `/port-contribute-to-base` | Send a generalized lesson back to the base (human-approved) |

Running a command is yours by default; the governance/independence/git ones (`/port-review`, milestone
tags, sign-off, sync/contribute) are never self-driven - each exists to keep a human or a separate
session in the loop. The binding rules live in `AGENTS.md`; the full methodology in `.opencode/skill/`.

## Auto-mode (optional, opt-in)

For a parallel port, **Ptah-Orchestrator** can drive the whole wave loop - claim, dispatch, review,
gate, integrate - with no human keystroke. It removes the human *pause*, never a gate: the reviewer is
still a separate agent, the checks still fail closed (any red halts the run), guarded units are never
auto-claimed, and every decision is logged to an audit ledger and re-checked by
`check-autodrive-integrity`. Configure it in `port/autodrive.yaml`:

| Level | Behavior |
|---|---|
| **L0** | off - the orchestrator only suggests; you run each action (default) |
| **L1** | plan-and-stop: prints the plan, executes nothing (a dry run - start here) |
| **L2** | auto within a phase, stops at every phase boundary for sign-off |
| **L3** | full auto across phases; a bot records a `BOT_ATTESTATION.md`, but the milestone tag still needs your one-line countersign (a bot never writes `SIGNOFF.md`) |

Run `/port-autodrive` (or `/port-autodrive status` to just see the plan); a completed run gets the same
independent eyes a hand-driven one does via `/port-review-autorun`. Full design:
`.opencode/skill/code-port/references/auto-mode.md`.

## Layout

- `source/` - SOURCE at a pinned commit (read-only by convention)
- the ported code lives in its own clean **product repo** (not here), linked via `port/product.yaml`
- `reference/` - reference-run definitions and checksums
- `tools/` - differential tools, gate scripts, conformance checks, coordination/scoping tooling
- `port/` - durable state: charter, TRACE matrix, LESSONS, KNOWN-DIVERGENCES, handoffs, coordination
- `docs/evidence/` - gate evidence packs for sign-off
- `.opencode/` - canonical `skill/`, `command/`, `agents/`
- `VERSION` - the methodology release version (semantic versioning)

## Reuse: one repo per port

This repo is the **base** (the methodology). Each port is its own **instance** repo that fills the
project layer (`source/`, `port/`, `reference/`, `docs/evidence/`, the project tool subdirs) and shares
the methodology layer (`.opencode/`, `AGENTS.md`, generic `tools/`). We clone to a fresh repo rather
than fork (forks don't scale past one per account). The split is enforced by `.gitattributes` merge
drivers, so `/port-sync-with-base` pulls every base improvement in - methodology files take the base's
side, your project files keep yours - without touching your work, and `/port-contribute-to-base` sends a
generalized lesson back so each new port starts smarter than the last. The instance records its base in
`tools/base-repo.txt`. (Avoid GitHub "template repo" generation - it breaks the cherry-pick lineage
sync/contribute rely on.)

## Where to read more

| You are | Read |
|---|---|
| An agent starting a sprint | `AGENTS.md`, then `/port-sprint-start` |
| A human reviewing | `port/plan/00-charter.md` (the constitution), `docs/evidence/` |
| Anyone needing the methodology | `.opencode/skill/`: `code-port` (what is translated + how it is validated) and `target-conventions` (how it is rendered: naming, comments, trap tables) |
</content>
