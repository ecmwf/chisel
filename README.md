<p align="center">
  <img src="logo.png" alt="Project logo" width="320">
</p>

# Numerical Code Port

Fidelity-preserving translation of numerical codebases from a SOURCE language to a
TARGET language (and, where applicable, onto a new execution model), executed with
agentic coding assistants (opencode) under human domain-expert
direction.

## What we are trying to achieve

Valuable numerical codebases outlive the languages and hardware they were written
for. Rewriting them is risky in a way ordinary software is not: the most dangerous
bugs are silent physics errors that compile cleanly, run plausibly, and only show up
deep into full-scale runs. This repo exists to make such a translation
**trustworthy**:

- **Preserve the science, provably.** The original code is treated as the
  specification; the port must reproduce its behavior, demonstrated by evidence at
  every stage rather than by inspection or trust.
- **Convert silent failures into loud, localized ones.** Differential tooling and a
  tiered validation ladder are built before any translation, so a mistake fails a
  cheap gate immediately instead of corrupting results months later.
- **Make a long, multi-sprint effort cumulative.** All project state, every lesson,
  and every accepted decision live in versioned files; any sprint, by any agent or
  human, can pick up the work without repeating a mistake already paid for.
- **Validate the workflow before betting on it.** A pilot port of a small program
  exercises every mechanism end to end; only then does a large port run in the same
  structure.

The methodology is language-agnostic. The languages, the program under port, and every
acceptance criterion of the **current instantiation** are defined in one place:
`port/plan/00-charter.md`. (The shipped conformance/anchor tooling baseline -
`verify-anchors.sh`, `check-index-helpers.sh`, and the rendering conventions - is currently
tuned for a **C target** (Fortran -> C); a different TARGET extends these at Phase 1.)

The current methodology release is recorded in `VERSION` (released: `0.1.0`; this
branch is the in-progress `0.2.0` development line).

## The doctrine

Translate literally in stages, validate each stage at the strictest criterion it can
physically meet, build the differential tooling before you need it, and persist every
lesson to disk so no sprint repeats a mistake another sprint already paid for.

## Start here

| You are | Read |
|---|---|
| An agent starting a sprint | `AGENTS.md`, then run `/port-sprint-start` |
| A human reviewing | `port/plan/00-charter.md` (the constitution), `docs/evidence/` |
| Anyone needing the methodology | `.opencode/skill/`: `code-port` (what is translated, how it is validated) and `target-conventions` (how it is rendered: naming, comments, trap tables) |

## Layout

- `source/` - SOURCE at pinned commit (read-only by convention)
- (the ported code is NOT here - it lives in its own **product** repo, a clean codebase whose
  `git log` and README carry no porting machinery; the workbench links to it via
  `port/product.yaml` and stays its attestation authority)
- `reference/` - canonical reference-run definitions and checksums
- `tools/` - differential tools, gate scripts, conformance checks, scoping tooling
- `port/` - durable project state: charter & plans, TRACE matrix, LESSONS,
  KNOWN-DIVERGENCES, handoffs, coordination, retrospectives
- `docs/evidence/` - gate evidence packs for sign-off
- `.opencode/` - canonical skills (`skill/`), slash commands (`command/`), and agents (`agents/`)
- `VERSION` - the methodology release version (semantic versioning)

The agents under `.opencode/agents/` carry deliberately-named roles for a parallel,
many-contributor port - a mnemonic for the separation of powers the trust model depends on:

- **Kha-Worker** - named for Kha, the ancient Egyptian master builder and overseer of works
  (the hands that raise what others design): the worker, the standard sprint agent that
  actually carves one claimed piece into the TARGET on its own branch and worktree. Many run
  in parallel; each authors and gates its own piece and requests review, but never reviews it,
  never merges, and never pushes - publishing is human-gated.
- **Ptah-Orchestrator** - named for Ptah, the Egyptian craftsman-god who *conceives and
  coordinates* the making without doing the making himself: the scheduler and the human's
  front door. It derives the ready-set, dispatches work, and reports human-readable status -
  but never reviews, merges, or self-certifies.
- **Seshat-Integrator** - named for Seshat, the goddess of *writing, records, and
  measurement* (she who scribes what is built): the single integration funnel. It orders,
  preflights, attests, and records the audit manifest and the canonical TRACE, while the
  merge keystroke itself stays human- or charter-bot-gated.
- **port-review** - the independent fidelity reviewer, in its own clean, separate session.

The one who carves is not the one who reviews, and the one who schedules is not the one who
records or merges - so no single agent can both do the work and bless it.

## How to work with this repo

1. **Bring the SOURCE.** The program being ported goes into `source/` at a pinned
   commit (read-only from then on). Together with the human, pin the configuration
   and define the canonical reference run in `port/plan/00-charter.md` (Phase 0).
2. **The port grows in the product repo.** The ported code builds and runs at every commit;
   `chisel-init` creates that separate clean repo and links it via `port/product.yaml`. Rendering
   rules live in `port/conventions/<source>-to-<target>.md` (the workbench) once instantiated at Phase 1.
3. **Work in focused sprints.** `/port-sprint-start` loads the state files and the
   one coherent chunk of work for this sprint (a module and its checks, not a
   single function); do that; `/port-sprint-end` persists everything for the next
   sprint. Then open a FRESH conversation and run `/port-sprint-start` again -
   the handoff carries the baton, so no context is ever hand-copied between
   sprints. Capture lessons the moment they happen with `/port-lesson`. One writer
   per worktree: a sprint assumes a quiet worktree, so branch- or ref-changing
   maintenance (sync, contribute, tag pushes) runs in its own ephemeral `.worktrees/`
   worktree and is torn down when done; only the final land onto the working branch
   needs a sprint boundary.
4. **Validate, never trust.** Run gates with `/port-gate`, prove new detectors with
   `/port-seed`, get ported modules independently reviewed with `/port-review`.
   All evidence lands in `docs/evidence/`.
5. **Milestones need the human.** A phase or milestone is accepted only by the
   domain expert's recorded sign-off (prepared with `/port-digest`), then
   git-tagged.

The binding rules live in `AGENTS.md`; the full methodology in the two skills under
`.opencode/skill/`.

## Sprints, phases, and sessions

Three words, three distinct things - kept separate on purpose:

- A **sprint** is one bounded, focused unit of porting work - typically a module
  and its checks, done in one sitting. `/port-sprint-start` opens it,
  `/port-sprint-end` closes it (saving all state to files). "Sprint" here means
  *focused and bounded*, not *fast*: the porting itself is deliberately careful.
- A **phase** is a group of sprints (Phase 0 scoping, Phase 1 tooling, Phase 2
  translation, and so on). Many sprints make up a phase.
- The **human signs off at phase and milestone boundaries** - not after every
  sprint. That sign-off is the gate that lets a milestone be tagged.
- A **session** is the AI conversation a sprint runs in. We start a fresh
  conversation per sprint, so in practice one sprint = one session; "session"
  shows up only where we mean the conversation itself (for example, an
  independent review must run in a *different* session than the one that wrote
  the code).

So: sprints are the unit of work, phases group them with a human sign-off at the
boundary, and a session is just the conversation a sprint happens in.

## The commands: when to use which

If you remember nothing else: **you only ever need `/port-sprint-start` and
`/port-sprint-end`** - the agent proposes the others at the right moments. But here
is the full map, with the trigger for each:

| Command | When | Example |
|---|---|---|
| `/port-sprint-start` | First thing in EVERY new conversation, before any work | You open the agent in the morning: `/port-sprint-start` - it loads the handoff and tells you the one task |
| `/port-sprint-end` | Task done; OR task ballooned; OR conversation grown long; OR you are stepping away. When in doubt: end | You finished pinning the configuration: `/port-sprint-end` - it saves everything and writes the next task into the handoff |
| `/port-lesson` | THE MOMENT something surprising happens: a bug found, a gate failed, an assumption broke, an approach abandoned. Never deferred to sprint end | The agent discovers a parameter file overrides an in-source default it had trusted: `/port-lesson` records symptom, cause, and the rule that would have caught it |
| `/port-gate` | A deliverable claims to be done and its acceptance criterion is a script: run the tier and record evidence | A module's translation is complete: `/port-gate R1 <module>` - runs the check, evidence lands in `docs/evidence/` |
| `/port-seed` | A NEW gate, probe, or conformance script was just built, or its comparison logic changed - before its result is trusted | You built the anchor verifier: `/port-seed anchor-verifier` - injects a wrong constant, proves the verifier goes red, then green |
| `/port-review` | A module passed its gate and wants the `gated` status - run in a FRESH conversation that did not write the translation | New conversation: `/port-review <module>` - independent line-by-line walk against the SOURCE; clean verdict unlocks `gated` |
| `/port-digest` | A phase or milestone is complete and needs the human's sign-off - run BEFORE asking | Phase 1 tooling all green: `/port-digest phase-1` - compiles the evidence pack and a prefilled SIGNOFF.md for the human's verdict |
| `/port-contribute-to-base` | At phase retrospectives and at project end, in a port instance: send what generalizes back to the base repo | Phase 2 retrospective done: `/port-contribute-to-base phase-2` - distills lessons into genericized base-repo proposals |
| `/port-sync-with-base` | Base methodology improvements are available, or a contribution of yours just merged: pull them into this instance | Between sprints: `/port-sync-with-base` - resolves in an ephemeral `.worktrees/` worktree, then fast-forward-lands onto the working branch at the boundary |

Where they fall in the lifecycle:

```text
new conversation ──> /port-sprint-start
                       ... work on the one task ...
                       surprise?            ──> /port-lesson  (same moment)
                       built a detector?    ──> /port-seed  (before trusting it)
                       deliverable done?    ──> /port-gate  (evidence recorded)
                     /port-sprint-end ──> close conversation

fresh conversation ─> /port-review  (independent eyes; never the author session)

phase boundary ─────> /port-digest ──> human writes SIGNOFF.md ──> git tag
                      /port-contribute-to-base  (instance only: learnings flow to base)
```

Two rules of thumb: anything that produces EVIDENCE has a command (so it lands in
`docs/evidence/` in a uniform shape), and anything you might FORGET has a command
(so the protocol remembers instead of you).

The agent watches for each command's trigger and SUGGESTS it the moment it sees
one - that part is automatic. Actually RUNNING a command is yours by default;
only capture-only `/port-lesson` may be set to autorun (it just records, then tells
you what it wrote). The governance, independence, and git commands
(`/port-review`, `/port-sync-with-base`, `/port-contribute-to-base`, milestone tags and sign-off) are never
self-driven, because each exists precisely to keep a human or a separate session
in the loop.

## Auto-mode: let the orchestrator drive

For a parallel port you can flip that default and let **Ptah-Orchestrator** drive the whole wave
loop - claim, dispatch a worker, request an independent review, gate, integrate, advance - with no
human keystroke. Auto-mode removes the human *pause*, never a gate: the reviewer is still a
**separate** agent (a distinct registered identity, ideally a different model), the conformance
checks still **fail closed** (any red HALTS the run), guarded/coupled units are never auto-claimed,
and every decision is appended to an audit **ledger** so the run is replayable and reversible. It
is opt-in per charter and bounded - it trades your outer pair of eyes for autonomy, and is for
trusted or supervised batches.

Turn it on in `port/plan/00-charter.md` §12 by setting `autodrive.level`:

| Level | Behavior |
|---|---|
| **L0** | off - the orchestrator only suggests; you run each action (default) |
| **L1** | plan-and-stop: prints the full next-action plan with rationale, executes nothing (a dry run - start here) |
| **L2** | auto within a phase, **stops at every phase boundary** for sign-off |
| **L3** | full auto across phases; a charter-bot records each phase/milestone sign-off in your place |

Then run `/port-autodrive` (or `/port-autodrive status` to just see the plan). Under the hood a
read-only, deterministic planner (`tools/coordination/autodrive.py`) computes the next actions from
the validated artifacts; the orchestrator executes them within the charter's scope and budgets and
records the ledger under `docs/evidence/autodrive/`. The full design - autonomy levels, the loop,
the stop conditions, and why the trust core is unchanged - is in the code-port skill's
`references/auto-mode.md`. Keep it at L0/L1 until the plans look right on your codebase.

## Reuse: one repo per port, learnings flow both ways

This repo is the **base** (the methodology). Each actual port is its own
**instance** repo that fills the project layer (`source/`, `port/`, `reference/`,
`docs/evidence/`, and the project-instantiated tool subdirs `tools/scoping/`,
`tools/gates/`, `tools/diff/`) while sharing the methodology layer
(`.opencode/`, `AGENTS.md`, `README.md`, the generic reusable scripts in `tools/`). We do
NOT fork: GitHub allows only
one fork per account per repo, so forking cannot scale to many ports. A clone
pushed to a fresh repo has no such limit - run as many ports as you like, each
its own repo.

**Set up a port with `chisel-init`** - the guided front door. From a fresh clone of the
base it checks your tooling, asks whether you are STARTING a new port or CONTRIBUTING to one
someone already began, does the cloning/wiring, and configures the agents' models - reporting
each step and asking before anything that writes, clones, or pushes (`--dry-run` shows it all
and changes nothing):

```bash
git clone <base-repo-url> port-foo && cd port-foo
python3 tools/chisel-init.py            # interactive; add --dry-run to preview
```

- **New port** flips this clone into your own instance (the *workbench*, where all state and
  lessons persist): the base becomes `upstream`, your new repo becomes `origin`, the layer
  merge drivers are set, and main is pushed. It can also clone the SOURCE program into
  `source/` at a pinned commit and import it, ready for the charter.
- **Contribute** clones the existing instance someone else started and wires `upstream` ->
  the base plus the merge drivers, so you can pull base improvements while you work.

Either way it parses `opencode models` and sets each agent's model, writing the choice to a
per-instance `opencode.json` - the authoritative, instance-owned source of per-agent models. The
agents carry no model in their (base-owned) frontmatter, so this config is never shadowed by them
and a sync never clobbers it. (It lives at the repo root, where opencode reads project config;
`.opencode/` holds only base-owned methodology resources - `agents/`, `command/`, `skill/` - so a
per-instance config placed there would both be overwritten on every sync and, as the later-loaded
source, override the very models you set.) Defaults, when available: **Kha-Worker**
-> `anthropic/claude-sonnet-4-6` (a capable, lower-cost model for the many parallel workers);
**Ptah-Orchestrator** and **Seshat-Integrator** -> `anthropic/claude-opus-4-8`; **port-review**
-> `openai/gpt-5.5` (a reviewer model distinct from the worker it reviews is a stronger
independence control than a different session alone). The instance records its base in
`tools/base-repo.txt`, so it always **knows its own way home**.

The lower-level one-shots are still there if you prefer them: `tools/new-instance.sh
me/port-foo` (a gh name or a git URL) does just the base->instance flip, and
`tools/import-source.sh source/<name>` does just the SOURCE import.

**Pull base improvements down:** run `/port-sync-with-base`. The merge resolution runs in an
ephemeral `.worktrees/` worktree so it never disturbs an active sprint; only the final
fast-forward land onto the working branch needs a sprint boundary. It finds the base
from `tools/base-repo.txt` (repairing the `upstream` remote if needed), merges
(never rebases), and resolves every conflict by itself with no hand-work, because
truth is split by layer: your **project** files (`port/`, `source/`, `reference/`,
`docs/evidence/`, and the project-instantiated tool subdirs
`tools/scoping/`, `tools/gates/`, `tools/diff/`) keep the instance's side, and the
**methodology** files (`.opencode/`, `AGENTS.md`, generic `tools/`, ...) take the base's
side. Two
`.gitattributes` merge drivers (`ours` and `theirs`) do this automatically.
Upstream is the truth for the methodology; your instance is the truth for its own
port - so a sync brings every base improvement in while never touching your work.
It then runs the conformance checks, scans for placeholder leakage, and
summarizes what arrived.

**Send lessons up:** run `/port-contribute-to-base` at retrospectives and project end. A
hard-won, generalized lesson is proposed back to the base (human-approved), then
flows out to every other port on its next `/port-sync-with-base`. Each new port starts smarter
than the last; a port that taught the methodology nothing was observed badly.

Avoid GitHub's "template repo" generation for instances: it disconnects history
and breaks the cherry-pick lineage that `/port-contribute-to-base` and `/port-sync-with-base` rely on.
