---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

name: code-port
description: >
  Plan and execute the full translation of a numerical/scientific codebase from one
  programming language to another (e.g. legacy Fortran/C to modern C/C++/Rust, or onto a
  performance-portability layer for GPUs) while provably preserving its numerics. Use this
  skill whenever the task involves porting, translating, transpiling, modernizing, or
  rewriting a simulation code, numerical model, solver, or HPC application across languages
  or execution models - even for a single module, a feasibility assessment, or a migration
  plan. Also use it when resuming a port in progress: it defines the phases, the validation
  ladder, the review layer and the persistent state files (charter, plan, LESSONS, TRACE,
  handoffs) that carry the project between sprints and between parallel workers.
---

# Code Port - fidelity-preserving translation of numerical codebases

A method for porting fidelity-critical code between languages and execution models without
degrading the science, carried out by AI coding agents under the direction of a human domain expert.
It applies to any fidelity-critical numerical code - geophysical models, CFD, structural mechanics,
plasma, molecular dynamics, astrophysics, signal processing - and to any language pair.

Vocabulary: **SOURCE** (the verified original), **TARGET** (the destination), optionally
**INTERMEDIATE** (a stepping-stone language), and the **EXECUTION MODEL** (the parallel or
accelerator framework, if any). AGENTS.md is the contract every agent follows; this skill says what
is translated and how it is validated. The target-conventions skill says how it is rendered.

## The doctrine

**Translate literally in stages, validate each stage at the strictest criterion it can physically
meet, build the differential tooling before you need it, and persist every lesson to disk so no
sprint repeats a mistake another sprint already paid for.**

## Why the prime directives hold

The prime directives are in AGENTS.md and are restated at every sprint start. What each one guards
against:

1. **The SOURCE is the specification** - even where it looks wrong, slow or ugly. Debating whether
   the science "should" behave differently turns a port bug into an opinion.
2. **Literal translation.** Each "improvement" produces plausible output and an unbounded debugging
   search (B1). The only permitted changes are the charter's mechanical ones (index base, storage
   order through fixed index helpers, global state to explicit arguments). A mechanical change is one
   a script could make; if it cannot be scripted it is not mechanical, and large ones are made by a
   committed script. Interim placeholders follow the registry in `references/bring-up-strategy.md`.
3. **Cite file:line.** Comments lie: trusting one once hid a full-scale instability for several
   sprints (B2). If you have not read the line this sprint, read it now.
4. **Pin the configuration first.** Mature codes are configurable supersets; you are prone to
   following a plausible but inactive branch, or a default the run's parameter file overrides (B3,
   N6). The pinned configuration, with the provenance of every effective value, is the charter's
   contract for the whole port.
5. **One change of dimension per stage.** A language change and an execution-model change (serial to
   parallel, CPU to GPU, memory model) are independent error sources; mixed, they cannot be told
   apart.
6. **Runnable and verifiable at every commit.** Port kernel by kernel so the build always runs and
   can always be compared with its reference.
7. **Focused sprints, durable files.** A bloated context is slower and less reliable; the state lives
   in `port/`, never only in a conversation.
8. **Never self-certify.** The human decides acceptance, per unit or once, up front, in the charter.
9. **Parallelize every ready-set wider than one** (`references/parallel-phase-2.md`).

## Phase plan

Adapt the phases to the project, but keep their boundaries and sign-off checks. The instantiated plan
lives in `port/plan/`, starting with the charter, `port/plan/00-charter.md`; get the human's sign-off
before Phase 2 begins.

### Phase 0 - Scoping and feasibility

- **Languages and scope are the human's decisions** (AGENTS.md). Observe the SOURCE language and
  standard from the tree (cite file:line); recommend the TARGET language and standard, its compilers
  and flags, the execution model, and the scope (pinned configuration and live subset), each with its
  rationale; ask once, and record the answers in charter sections 1 and 3.
- Inventory the SOURCE: files, lines, build system, external dependencies, I/O formats,
  parallelization constructs, code generation and preprocessing.
- **Import the SOURCE with `tools/import-source.sh`, never by hand.** Clone the upstream at the
  chosen commit under `source/<name>` and run it: it refuses a dirty clone or one with submodules,
  saves the upstream URL, commit and tracked-file count to `port/provenance/<name>.yaml`, strips the
  nested `.git`, and warns when the SOURCE's own `.gitignore` would drop upstream-tracked files (stage
  those with `git add -f`). `check-source-import.sh` and `check-live-tracked.sh` re-check completeness
  on every conformance run (B17). Record the upstream commit in charter section 2 and TRACE
  `upstream_commit`, and the local commit that adds `source/` as TRACE `source_commit`: the anchor
  verifier reads the SOURCE from that one, since the upstream commit is not in this repository.
  `source/` is read-only from then on.
- **Identify the live subset** with tooling (build logs, coverage, link maps), not memory. Coverage
  is not liveness (B6): a declarations-only unit shows no coverage yet is live when live code
  references it. Exclude a unit only with proof of deadness, and record the excluded remainder in
  TRACE. In mature configurable codes the live subset is often a small fraction of the whole, so
  scoping is one of the biggest levers on effort.
- **Build the dependency map** with `tools/coordination/extract_dependencies.py`: it gives the
  planner its order and the completeness check its SOURCE inventory. The shipped extractor reads a
  Fortran SOURCE with preprocessor guards; a SOURCE in another language needs an extractor that
  writes the same map schema (`references/team-coordination.md`). Record every preprocessor macro
  that guards a dependency edge in `tools/scoping/macro-state.yaml`, in the shape of
  `assets/macro-state.template.yaml` (each macro's value and the file that fixes it); a guarded edge
  whose macro is not recorded makes the extraction UNRELIABLE (B24). Then make the map exact with
  the compiler: build the SOURCE once, recording its compile commands (`bear -- <build command>`, or
  CMake's `CMAKE_EXPORT_COMPILE_COMMANDS=ON`), run `tools/coordination/compiler_graph.py
  --compile-commands <its compile_commands.json>`, commit `tools/scoping/compiler-graph.yaml`, and
  extract again. The map then also holds the calls, uses and data reads only the compiler resolves;
  rerun both whenever the SOURCE changes, since the map check refuses a stale graph.
- Choose the staging and the acceptance criterion for each stage. Consider an INTERMEDIATE stage
  when the SOURCE is a low-resource language for LLMs, or the final TARGET bundles a new execution
  model.
- Establish the **canonical reference run** - exact SOURCE commit, build flags, inputs, duration,
  outputs - archived immutably and recorded in `reference/runs.md`. Immutable freezes each defined
  run, not the size of the set: when a coverage gap appears later (adjoint or tangent-linear
  operators, error handlers), add new runs that reach it, using purpose-built drivers if needed; never
  edit or remove an existing run. Pair with self-consistency checks where they exist (such as the
  adjoint identity `<L x, y> == <x, L* y>`), which validate a routine without reference output.
- Deliverables: the charter with the pinned configuration, the stages and their acceptance bars, the
  risks, the named exceptions, and a populated TRACE. Phase 0 is one scoping arc with no TARGET code:
  drive it through to `/port-digest` without stalling - commit routine work yourself, lead with
  recommendations rather than blocking questions - and end at the human's sign-off (`SIGNOFF.md`,
  then the `phase0-signed` tag).

### Phase 1 - Reference instrumentation and differential tooling

- **Ratify the review threat model with the human before the first review** (charter section 6a,
  including the review round cap; B20). Phase 1 reviews audit detectors, and a detector review
  without a threat model does not converge.
- **Settle the intrinsic traps before any translation** with one probe comparing each SOURCE
  intrinsic with its candidate TARGET rendering on raw bit patterns, under the pinned flags, in every
  supported precision, including signed zeros, NaN, infinities and subnormals. Record the verdict
  table and the toolchain it is bound to. The pair reference (target-conventions,
  `references/pairs/`) says which intrinsics to suspect; the probe turns that into evidence, once,
  instead of per routine.
- Build the comparison infrastructure **before translating any code**, instrumenting the SOURCE too:
  the tool classes and design rules are in `references/differential-tooling.md` (check first whether
  the SOURCE already has a tool natively). Design the validation ladder
  (`references/validation-ladder.md`) and set up the fast rig and synthetic inputs
  (`references/bring-up-strategy.md`).
- Instantiate `port/conventions/<source>-to-<target>.md` with the human from the target-conventions
  skill (naming map, comment policy, types, formatter, the pair's trap table), with its enforcement
  scripts.
- Write what is already true in the product README (`references/product-readme.md`): what the code
  does and where it comes from, for a consumer, with nothing about the porting.
- Exit check: the tooling demonstrated on the SOURCE alone (dump and restore round-trip, probes silent
  on the reference run); every proof and probe seen to fire on a seeded bug; the conventions signed
  off with their enforcement scripts landed. With several contributors, Phase 1 runs in parallel
  (`references/parallel-phase-1.md`).

### Phase 2 - Language translation (SOURCE to INTERMEDIATE or TARGET-serial)

- Translate module by module in dependency order (utilities and data structures, then operators,
  then drivers), literally, following the bring-up order in `references/bring-up-strategy.md` and
  rendering per `port/conventions/<source>-to-<target>.md`, with the trap table open while
  translating, not consulted after the bug.
- Verify per procedure (`references/validation-ladder.md`): unit tests for pure routines,
  capture-replay against reference dumps for wide-footprint ones, the ladder for seams. Before any
  differential exists, early modules are accepted by intrinsic checks (R0), which never prove; a piece
  is proven from the Phase-2 R1 proof up. The tests are product-owned (`tests/unit/`,
  `tests/fixtures/`), so a clone of the product tests itself. Bind every assertion that claims to
  discriminate a rendering choice to production, with a fixture that can observe the choice (B23).
- Track **performance parity** from the first milestone (`references/performance-campaign.md`): a
  literal port is roughly performance-neutral, so a deviation outside the charter's performance band
  is a finding (build flags, debug artifacts, rendering bugs), never a license to optimize. Run the
  fair-field check on both sides before recording any comparison.
- **Acceptance** follows the bit-identity rule (`references/validation-ladder.md`): a cross-language
  stage is never assumed bit-identical. It is held to the SOURCE's own validation criterion, or to the
  statistical test design agreed with the human in charter section 7, at the **full-scale, real-use
  configuration** - the real inputs, sizes and duration, never a smoke test, which misses latent bugs
  (N1).
- The bulk runs as parallel waves of Kha-Workers (`references/parallel-phase-2.md`).

### Phase 3 - Execution-model translation (serial reference to parallel or accelerated TARGET)

- Keep the serial reference from Phase 2 alive inside the TARGET tree, built with the same compiler.
  Where the INTERMEDIATE is a near-subset of the TARGET language, show the plain recompile is
  bit-identical before any parallel work.
- Port kernel by kernel; each keeps its serial twin with a runtime verify mode that must show exactly
  zero difference on a deterministic backend (R1).
- Instantiate R2-R5 from `references/validation-ladder.md` in the charter. Bit-identity usually holds
  only at a fixed process count; record it.

### Phase 4 - Performance campaign (only after correctness)

Read `references/performance-campaign.md` first. Optimize only under the ladder; profile before every
change; run the fair-field check on both sides before any SOURCE-against-TARGET comparison; expect the
first accelerator run to be slower than the CPU baseline; delete optimizations that do not measure as
wins and record them as negative results.

### Phase 5 - Portability and handover

- **Pin the portability targets by interview,** as Phase 0 pins the configuration: which
  architectures, operating systems, compilers, accelerator vendors and named machines, and how to
  build and run on each (access, module environment, scheduler, toolchain). Record the matrix in the
  charter. Bring the port up on the real targets, never a stand-in: platform-conditional code is
  exactly what sits silently inert elsewhere (N7).
- **Classify each target's bar by the bit-identity rule** (`references/validation-ladder.md`): a
  target that preserves arithmetic is held to bit-identity against the canonical reference (R2); one
  that changes it is held to statistical parity (R5) with per-field bounds the human confirms, and its
  floating-point floor recorded.
- **Bring up early, then consolidate.** Cross-platform bring-up starts as soon as Phase 3 yields a
  portable build; a cheap smoke test on a different platform flushes out N7 guards early. Phase 5 then
  completes each target's ladder and consolidates the per-platform evidence in `docs/evidence/`, the
  final LESSONS distillation, and a retrospective written as context for the next port.

## Sprints and state

The project state lives in ordinary files under `port/` (AGENTS.md, repository map): the charter and
plans, TRACE, LESSONS with its standing rules, KNOWN-DIVERGENCES, the handoffs. Probable bugs in the
SOURCE itself go to `port/SOURCE-FINDINGS.md`, to report upstream: record them, never fix them. The
sprint rules are in AGENTS.md and the procedures in `/port-sprint-start` and `/port-sprint-end`.

## The self-improvement loop

How the port gets easier as it goes instead of repeating its failures:

1. **Capture.** When a bug is found, a proof fails, an assumption breaks or an approach is abandoned,
   record it at once with `/port-lesson`: symptom, root cause, fix, and above all the rule or detector
   that would have prevented it. Tag it with its failure-class and trap IDs (N2, B1, T6, ...): the
   ledger is searched, never read linearly.
2. **Promote.** A lesson that is general or recurs becomes a candidate for STANDING RULES, short
   imperatives every sprint restates; you propose, the human decides. Keep the block under about
   twenty rules, merging or retiring stale ones at retrospectives.
3. **Mechanize.** The strongest promotion is from rule to tool: an always-on probe, a proof, a
   conformance script, a CI check. A rule depends on being remembered; a check does not, and at scale
   it is the primary defense. Record any enforceable invariant a sprint creates or reveals as a
   MECHANIZATION CANDIDATE in LESSONS, and build candidates only after triage at the phase
   retrospective, never as you go: check sprawl is its own failure. A candidate is accepted only if
   it cites the failure class, trap or charter rule it guards, is cheap to run, has near-zero false
   positives, and will pass a seeded-bug demonstration. A check that raises false alarms or guards a
   retired invariant is deleted and recorded under NEGATIVE RESULTS; silence alone is never grounds
   for deletion, since a detector that never fires may be deterring.
4. **Retrospect at phase boundaries.** Re-read LESSONS, fold what matters into the next phase's plan,
   and write a short retrospective in `port/retrospectives/`. A class that recurs despite a standing
   rule means: mechanize it or amend the plan. Triage the candidates (build, reject with a reason, or
   defer to a named point). Then archive closed entries to `port/lessons-archive/phase-<n>.md`; lesson
   numbers are permanent, so references survive. No state file ever needs reading end to end:
   handoffs are rewritten, standing rules capped, plans split, TRACE queried, the ledger searched and
   archived.
5. **Feed forward across ports.** Every port runs in its own clone of the base repository, and the
   methodology layer is shared. Keep methodology improvements in their own commits and run
   `/port-contribute-to-base` at retrospectives and at the end: distill what generalizes, strip every
   project specific, and propose it. The human approves what flows up.

## The review layer (independence insurance)

Proofs detect divergence when they run; they cannot review themselves, cannot see a wrongly pinned
reference, and catch literalness violations only if a run happens to exercise them. The review layer
covers exactly those blind spots; anything scriptable belongs in `tools/`, not in review.

1. **Independent fidelity review.** Before a piece is `proven`, a session that did not produce it
   walks the TARGET against the SOURCE with the charter and trap table open (`/port-review`). B1-B3
   are failures of the translating agent, and the session that rationalized a deviation will approve
   it again. The reviewer always runs in a separate session, with a `reviewer_session` outside
   `author_sessions`, and should run on a different model. The review unit is the coherent
   deliverable (a module and its tightly coupled helpers, in one report), not a file. Review a piece
   before anything consumes it, since a violation in a producer corrupts every consumer. Pending
   reviews run as a batch: one port-review subagent per piece, in parallel, each writing only its own
   report; the session that ran `/port-review` then records the results and commits the reports, and
   the human answers one consolidated question, not one per piece. A review walks a fixed checklist,
   and every finding cites SOURCE and TARGET file:line pairs.
2. **Tooling trust.** A proof or probe is trusted only after it has been seen to fail on a seeded bug
   (`references/validation-ladder.md`, `/port-seed`).
3. **Evidence pre-digest.** At phase boundaries `/port-digest` compiles and cross-checks the
   evidence pack (proof runs against the charter, TRACE against tags, placeholders closed, the comment
   audit done), so the human's attention goes to judgment, not collation.

`proven` is a technical status, defined in AGENTS.md: an R1+ proof and a clean independent review,
with evidence recorded. `/port-review` records it, applying the human's choice or the charter's
auto-prove policy; `/port-land`, run by Ptah-Orchestrator, then integrates the piece. Milestone
acceptance is separate and higher: it is sealed only by `finalize.sh` (AGENTS.md; for autodrive,
`references/auto-mode.md`). Review is not for anything a conformance script or proof already
covers, nor style (the formatter owns it), nor re-running validations (CI does). A review without a
checklist and a citation duty is theater.

## Working at scale

A small port runs as one stream: one handoff, one piece at a time. As soon as more than one piece is
ready, the work fans out: Ptah-Orchestrator provisions one isolated worktree per piece and dispatches
a Kha-Worker to each, port-review subagents review the results, and Seshat-Integrator lands proven
pieces one at a time through the guarded scripts. The substrate is in
`references/team-coordination.md` and the wave loop in `references/parallel-phase-2.md`; autodrive
drives the same loop from a planner (`references/auto-mode.md`).

- **TRACE (`port/TRACE.yaml`).** Every live SOURCE file appears exactly once: its TARGET files,
  status (`unmapped`, `in-progress`, `proven`, `excluded`), proof and review evidence. With several
  writers each piece writes its own status fragment and TRACE is generated from them, never edited by
  hand; `check-completeness.sh` ensures no SOURCE file is silently dropped.
- **Producer before consumer.** A piece is ready only when the pieces it depends on are integrated,
  and a consumer of another piece's field or routine waits for that producer (N3).
- **Shared knowledge stays global.** LESSONS, the charter and KNOWN-DIVERGENCES are global: lessons
  are the shared immune system, and a divergence accepted for one piece is never re-investigated for
  another. Several humans may split the port into workstreams, each with its own handoff and plan
  card; the pieces, claims and checks stay the same.

## Division of labour

You (the agent) own reading, literal translation, harness construction, debugging, profiling,
documentation and the state files. The human domain expert owns strategy, plan and diff review,
exceptions to literalness, the TARGET and scope, the tolerance bands, judging statistical acceptance
(whether a residual difference is physically meaningful), and sign-off. Never self-certify: present
the evidence in `docs/evidence/`, recommend a verdict with reasoning, and give the human a
verification runbook (exact steps and the good-against-bad signature) for anything that needs their
judgment. Never block them either: ask for each of their decisions once, up front where possible,
and keep working on everything that does not depend on the answer.

## Reference files (read when entering the relevant phase)

- `references/validation-ladder.md` - the bit-identity rule, the tiers R0-R5 (including the Phase-2
  R1 proof), the per-procedure verification policy. Read at Phases 1 and 3.
- `references/differential-tooling.md` - the six tool classes, their design rules, the poison
  discriminator and the workflow when a proof fails. Read at Phase 1 and whenever debugging.
- `references/bring-up-strategy.md` - the fast rig, synthetic inputs, intrinsic acceptance (R0), the
  bring-up harness sprint, the order of work, the placeholder registry. Read at Phases 1 and 2.
- `references/failure-modes.md` - the failure classes (B, N) with cause, symptom and defense; the
  defenses are the requirements for Phase 1 tooling. Read at Phase 1 and whenever debugging.
- `references/performance-campaign.md` - parity tracking, the fair-field check, measure-first
  optimization under the ladder. Read at Phase 2 (parity) and Phase 4.
- `references/product-readme.md` - writing the product README for a consumer. Read when first
  writing it and when finalizing it.
- `references/two-repo-architecture.md` - the workbench and the product: linkage, provenance anchors,
  landing only the reviewed commit, the bring-up preview, assemblies, the two-root proof contract,
  chisel-invisibility. Read before the first land and whenever touching linkage or proofs.
- `references/team-coordination.md` - claims, status fragments and generated TRACE, isolated
  worktrees, owned surfaces and the leaf pool, interface contracts, the land funnel. Read before
  running any phase with more than one worker.
- `references/parallel-phase-1.md` - building the tooling in parallel: Layer 0 first, the Layer-1
  fan-out, per-tool acceptance. Read when fanning out Phase 1.
- `references/parallel-phase-2.md` - the bulk translation: the four roles, the wave loop, the staged
  build order and entry check, parallel by default. Read before fanning out Phase 2.
- `references/auto-mode.md` - autodrive: the levels, the loop, the stop conditions, what stays the
  human's. Read before enabling it.

Templates: `assets/README.md` lists each one, the file it becomes, and what writes and reads it.
The sibling skill **target-conventions** holds the deterministic rendering rules (naming,
comments, types, formatter, the trap table of each language pair); it is instantiated into
`port/conventions/<source>-to-<target>.md` at Phase 1 and read by every sprint that writes TARGET code.
