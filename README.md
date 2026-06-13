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
| An agent starting a session | `AGENTS.md`, then run `/port-start` |
| A human reviewing | `port/plan/00-charter.md` (the constitution), `docs/evidence/` |
| Anyone needing the methodology | `.claude/skills/`: `code-port` (what is translated, how it is validated) and `target-conventions` (how it is rendered: naming, comments, trap tables) |

## Layout

- `source/` - SOURCE at pinned commit (read-only by convention)
- `target/` - the port; builds and runs at every commit
- `reference/` - canonical reference-run definitions and checksums
- `tools/` - differential tools, gate scripts, conformance checks, scoping tooling
- `port/` - durable project state: charter & plans, TRACE matrix, LESSONS,
  KNOWN-DIVERGENCES, handoffs, coordination, retrospectives
- `docs/evidence/` - gate evidence packs for sign-off
- `.claude/` - canonical skills + slash commands; `.opencode/` symlinks to the same

## How to work with this repo

1. **Bring the SOURCE.** The program being ported goes into `source/` at a pinned
   commit (read-only from then on). Together with the human, pin the configuration
   and define the canonical reference run in `port/plan/00-charter.md` (Phase 0).
2. **The port grows in `target/`.** It must build and run at every commit;
   rendering rules live in `target/CONVENTIONS.md` once instantiated at Phase 1.
3. **Work in short sessions.** `/port-start` loads the state files and the one
   task for this session; do that task; `/port-end` persists everything for the
   next session.    Then open a FRESH conversation and run `/port-start` again -
   the handoff carries the baton, so no context is ever hand-copied between
   sessions. Capture lessons the moment they happen with `/port-lesson`. One writer
   per worktree: do your own git operations (pulls, merges) BETWEEN sessions,
   never while a session is working.
4. **Validate, never trust.** Run gates with `/port-gate`, prove new detectors with
   `/port-seed`, get ported modules independently reviewed with `/port-review`.
   All evidence lands in `docs/evidence/`.
5. **Milestones need the human.** A phase or milestone is accepted only by the
   domain expert's recorded sign-off (prepared with `/port-digest`), then
   git-tagged.

The binding rules live in `AGENTS.md`; the full methodology in the two skills under
`.claude/skills/`.

## The commands: when to use which

If you remember nothing else: **you only ever need `/port-start` and
`/port-end`** - the agent proposes the others at the right moments. But here
is the full map, with the trigger for each:

| Command | When | Example |
|---|---|---|
| `/port-start` | First thing in EVERY new conversation, before any work | You open the agent in the morning: `/port-start` - it loads the handoff and tells you the one task |
| `/port-end` | Task done; OR task ballooned; OR conversation grown long; OR you are stepping away. When in doubt: end | You finished pinning the configuration: `/port-end` - it saves everything and writes the next task into the handoff |
| `/port-lesson` | THE MOMENT something surprising happens: a bug found, a gate failed, an assumption broke, an approach abandoned. Never deferred to session end | The agent discovers a parameter file overrides an in-source default it had trusted: `/port-lesson` records symptom, cause, and the rule that would have caught it |
| `/port-gate` | A deliverable claims to be done and its acceptance criterion is a script: run the tier and record evidence | A module's translation is complete: `/port-gate R1 <module>` - runs the check, evidence lands in `docs/evidence/` |
| `/port-seed` | A NEW gate, probe, or conformance script was just built, or its comparison logic changed - before its result is trusted | You built the anchor verifier: `/port-seed anchor-verifier` - injects a wrong constant, proves the verifier goes red, then green |
| `/port-review` | A module passed its gate and wants the `gated` status - run in a FRESH conversation that did not write the translation | New conversation: `/port-review <module>` - independent line-by-line walk against the SOURCE; clean verdict unlocks `gated` |
| `/port-digest` | A phase or milestone is complete and needs the human's sign-off - run BEFORE asking | Phase 1 tooling all green: `/port-digest phase-1` - compiles the evidence pack and a prefilled SIGNOFF.md for the human's verdict |
| `/port-upstream` | At phase retrospectives and at project end, in a port instance: send what generalizes back to the base repo | Phase 2 retrospective done: `/port-upstream phase-2` - distills lessons into genericized base-repo proposals |

Where they fall in the lifecycle:

```text
new conversation ──> /port-start
                       ... work on the one task ...
                       surprise?            ──> /port-lesson  (same moment)
                       built a detector?    ──> /port-seed  (before trusting it)
                       deliverable done?    ──> /port-gate  (evidence recorded)
                     /port-end ──> close conversation

fresh conversation ─> /port-review  (independent eyes; never the author session)

phase boundary ─────> /port-digest ──> human writes SIGNOFF.md ──> git tag
                      /port-upstream  (instance only: learnings flow to base)
```

Two rules of thumb: anything that produces EVIDENCE has a command (so it lands in
`docs/evidence/` in a uniform shape), and anything you might FORGET has a command
(so the protocol remembers instead of you).

The agent watches for each command's trigger and SUGGESTS it the moment it sees
one - that part is automatic. Actually RUNNING a command is yours by default;
only capture-only `/port-lesson` may be set to autorun (it just records, then tells
you what it wrote). The governance, independence, and git commands
(`/port-review`, `/port-sync`, `/port-upstream`, milestone tags and sign-off) are never
self-driven, because each exists precisely to keep a human or a separate session
in the loop.

## Reuse: one repo per port, learnings flow both ways

This repo is the **base** (the methodology). Each actual port is its own
**instance** repo that fills the project layer (`source/`, `target/`, `port/`,
`reference/`, `docs/evidence/`) while sharing the methodology layer (`.claude/`,
`AGENTS.md`, `README.md`, generic `tools/`). We do NOT fork: GitHub allows only
one fork per account per repo, so forking cannot scale to many ports. A clone
pushed to a fresh repo has no such limit - run as many ports as you like, each
its own repo.

**Start a new port** (from a fresh clone of the base):

```bash
git clone <base-repo-url> port-foo && cd port-foo
tools/new-instance.sh me/port-foo        # gh name, or pass a git URL you made
```

That one script does the whole setup: points `upstream` at the base, makes the
new repo `origin`, turns on the layer merge driver, and pushes. The instance
records its base in `tools/base-repo.txt`, so from then on it **knows its own way
home** - nothing to remember.

**Pull base improvements down:** run `/port-sync` between sessions. It finds the base
from `tools/base-repo.txt` (repairing the `upstream` remote if needed), merges
(never rebases), auto-keeps the instance's side on any project-layer file via the
`merge=ours` driver, runs the conformance checks, scans for placeholder leakage,
and summarizes what arrived.

**Send lessons up:** run `/port-upstream` at retrospectives and project end. A
hard-won, generalized lesson is proposed back to the base (human-approved), then
flows out to every other port on its next `/port-sync`. Each new port starts smarter
than the last; a port that taught the methodology nothing was observed badly.

Avoid GitHub's "template repo" generation for instances: it disconnects history
and breaks the cherry-pick lineage that `/port-upstream` and `/port-sync` rely on.
