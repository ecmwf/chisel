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
  plan. Also use it when resuming a port in progress: it defines the sprint protocol and
  the persistent state files (charter, plan, LESSONS, TRACE, handoffs) that carry the
  project between sprints and between parallel workstreams.
---

# Code Port - fidelity-preserving translation of numerical codebases

Methodology for porting fidelity-critical code between languages and execution models
without degrading the science. It encodes practices proven on full-scale ports of
complete numerical models carried out by agentic LLM assistants under expert direction,
extended here for large repositories and parallel workstreams. It applies to any
fidelity-critical numerical code: geophysical models, CFD, structural mechanics, plasma,
molecular dynamics, astrophysics, signal processing, and similar.

Vocabulary used throughout: **SOURCE** (the verified original), **TARGET** (the
destination), optionally **INTERMEDIATE** (a stepping-stone language), and the
**EXECUTION MODEL** (parallel/accelerator framework, if any).

## The one-sentence doctrine

**Translate literally in stages, validate each stage at the strictest criterion it can
physically meet, build the differential tooling before you need it, and persist every
lesson to disk so no sprint repeats a mistake another sprint already paid for.**

## Prime directives (never violate; restate at the start of every sprint)

1. **The SOURCE is the specification.** It is verified, stable, and right - even where
   it looks wrong, inefficient, or ugly. Any divergence of the port from SOURCE behavior
   is a port bug *by definition*. Never debate whether the science "should" behave
   differently.

2. **Literal translation. Never improve, simplify, approximate, or modernize.** The only
   permitted changes are *mechanical* ones listed in the charter (e.g., index-base
   conversion, storage-order conversion via fixed index helpers, global-state-to-explicit-
   argument conversion). A mechanical change is one you could perform with a script -
   if it cannot be scripted, it is not mechanical, and large mechanical changes SHOULD
   be performed by script rather than by hand. Anything else is forbidden, because each
   "improvement" produces *plausible* output and an unbounded debugging search.
   Deliberate departures (e.g., redesigning I/O) require human authorization and a named
   exception in the charter. Interim placeholders are allowed only under the registry
   discipline of `references/bring-up-strategy.md`.

3. **Cite file:line for every claim about the SOURCE.** Any statement about what the
   SOURCE does - especially the value of any constant - must quote the exact file, line
   number, and the literal text read there. Never a value recalled from memory, rounded,
   or copied from a *comment* - comments lie: trusting one has hidden a
   full-scale instability for multiple working sprints. If you have not read the
   line this sprint, read it now.

4. **Pin the configuration first.** Mature codes are configurable supersets: compile-time
   switches, runtime parameter files, and in-source defaults select which fraction of the
   code is live. Before translating anything, record the *single* configuration being
   ported - every active switch, every effective parameter value, and its provenance
   (parameter file beats source default). You are especially prone to following a
   plausible-but-inactive branch or adopting a default that the run's parameter file
   overrides. The pinned configuration lives in the charter and is the contract for the
   whole port.

5. **One change of dimension per stage.** Never change the language and the execution
   model (serial→parallel, CPU→GPU, memory model) in the same stage. They are
   independent error sources; mixed together they are indistinguishable.

6. **Keep the port runnable and verifiable at every commit.** Port kernel by kernel /
   module by module so the build always runs and can always be compared to its
   reference. Tag every passed milestone in version control.

7. **Focused sprints, durable files.** A bloated context is slower and less reliable,
   so a sprint covers one coherent unit of work (a module and its checks, not a
   single function) and ends when the unit is done or the context grows heavy.
   Right-size it: neither fragment into micro-sprints nor sprawl across unrelated
   modules. Each sprint starts by reading the state files and ends by writing
   them (see Sprint protocol).

## Phase plan

Adapt the phases to the project, but keep their boundaries and sign-off checks. Write the
instantiated plan to `port/plan/` (charter template in `assets/CHARTER.template.md`)
and get human sign-off before Phase 2 begins.

### Phase 0 - Scoping and feasibility
- **Languages are CHOSEN with the human, not silently inferred.** Observe the SOURCE
  language/standard from the tree (cite file:line); the TARGET language/standard, compilers + flags,
  and execution model are the human's call - recommend a choice with its rationale, then ask and wait
  for the answer (`/port-sprint-start`, step 0), never SILENTLY inferred from the
  repo/instance/product name or the tree. Record them in charter section 1.
- Inventory the SOURCE: files, lines, build system, external dependencies, I/O formats,
  parallelization constructs, code generation or preprocessing.
- **Import the SOURCE with provenance.** From a fresh clone of the upstream at the
  chosen commit, verified byte-identical against the tree being committed (any delta
  is shown to the human and either re-imported away or recorded as a pinned local
  change). Strip nested VCS metadata before committing - a committed clone becomes a
  broken link entry, not files - and confirm the tree is self-sufficient (no LFS
  pointers, no submodules). A completeness trap: the SOURCE's own ignore rules (its
  `.gitignore`, now a plain imported file) can match paths the upstream force-tracked, so
  a naive `git add` silently drops them - confirm the host would stage exactly the
  upstream tracked-file count and force-add any shadowed remainder. Do the import by
  running `tools/import-source.sh` (not by hand): it performs the strip, this
  completeness check, and the byte verification, and refuses rather than corrupt the
  provenance. Record the
  upstream URL + commit in the charter and the
  verification statement in the import commit message. Two commit identities matter and
  differ once the nested metadata is stripped: the UPSTREAM provenance commit (in the
  charter, for traceability) and the LOCAL import commit that introduced the bytes here -
  the latter is what the anchor verifier reads the SOURCE from, since the upstream commit is
  not in this repo's object store. Record both; the consistency check verifies the
  imported bytes correspond to the upstream commit, not that the two hashes are equal. The
  imported tree is read-only from that commit on.
- **Identify the live subset** with tooling (build-log analysis, coverage
   instrumentation, link-map inspection), not memory. **Coverage is not liveness:** a
   declarations-only unit (constants, type aliases, shared data; no executable statements)
   emits zero coverage at any run length yet is live when referenced by live code.
   Classify each non-executing unit - declarations-only and referenced = live; otherwise
   REVIEW (human decides) - and exclude a unit only with proof of deadness, never on
   coverage absence (failure mode B6). Port only the live subset; record the excluded
   remainder explicitly in `port/TRACE.yaml`. In mature configurable codes the live
   subset is routinely a small fraction of the full distribution - scoping is one of the
   biggest levers on total effort.
- **Build the dependency map with `tools/coordination/extract_dependencies.py`.** The map is the planner's ordering and the completeness check's SOURCE inventory. Any preprocessor macro that guards a `USE`/`CALL`/`#include` edge must be recorded in `tools/scoping/macro-state.yaml`, in the shape of `.opencode/skills/code-port/assets/macro-state.template.yaml` (a top-level `macro_state:` mapping each macro to its value and the file that fixes it). An absent, unreadable, or malformed table, or an unrecorded macro on a guarded edge, makes the extraction `UNRELIABLE` (exit 2) by design — record the macro before the map can be trusted.
- Choose the staging strategy and the acceptance criterion for each stage. Consider an
  INTERMEDIATE stage when (a) SOURCE is a low-resource language for LLMs, or (b) the
  final TARGET bundles a new execution model.
- Establish the **canonical reference run**: exact SOURCE commit, build flags, inputs,
  duration, outputs - archived immutably, recorded in `reference/runs.md`. *Immutable*
  freezes each DEFINED run, not the dataset's size: when a coverage gap surfaces later
  (code paths no run exercises - e.g. adjoint/tangent-linear operators, error handlers),
  AUGMENT the dataset with NEW runs that reach them (purpose-built drivers/executables are
  acceptable to exercise otherwise-unreachable code). Augmentation is additive - it never
  edits or removes an existing run, so immutability holds. Pair with self-consistent checks
  where they exist (e.g. the adjoint-dot-product identity `<L x, y> == <x, L* y>`), which
  validate a routine without external reference output.
- Deliverables: charter with pinned configuration, stage list with acceptance bars,
  risk list, named exceptions, populated TRACE. Phase 0 is one coherent scoping arc (no TARGET
  code yet): drive it through to `/port-digest` in the sprint WITHOUT stalling - commit routine work
  yourself and lead with recommendations, not blocking questions - ending at the human sign-off checkpoint
  (SIGNOFF.md -> the `phase0-signed` tag).

### Phase 1 - Reference instrumentation and differential tooling
**Before dispatching the first review, RATIFY the review threat model with the human**
(charter section 6a, `assets/CHARTER.template.md`; rationale in `references/failure-modes.md`,
B20) - including the per-unit review round cap. Phase 1 reviews audit DETECTORS, and a
detector review without a ratified threat model does not converge: an adversary who already
has write access admits no fixed point. Ratifying it costs one exchange; skipping it costs
review rounds on every unit.

**Settle the intrinsic traps mechanically in this phase, before any translation** - one
probe comparing each SOURCE intrinsic against its candidate TARGET rendering on raw bit
patterns, under the pinned flags, in every supported precision, with the awkward operands
(signed zeros, NaN, infinities, subnormals) included. Record the verdict table and what
toolchain it is bound to. The language-pair reference for your pair
(`target-conventions`, `references/pairs/`) says which intrinsics to suspect; the probe is
what turns that into evidence. Resolving these one at a time during translation is the
expensive order - the question resurfaces per routine and a wrong call resurfaces later as a
divergence hunt where the intrinsic is the last thing suspected.

Build the comparison infrastructure **before translating any code**, instrumenting the
SOURCE side as well. Before building a tool class, check whether the SOURCE already
implements it (a native sanity/range guard, a conservation monitor): recognize and
reproduce it rather than building a duplicate (the design rules in
`references/differential-tooling.md`). Read `references/differential-tooling.md` for the six tool classes
and the design rules (each tool behind an environment switch, compiled out when off,
byte-neutral when disabled). Design the validation ladder now - read
`references/validation-ladder.md`. Also set up the **fast rig** and synthetic inputs -
read `references/bring-up-strategy.md`. Instantiate `port/conventions/<source>-to-<target>.md` now, with
the human, from the **target-conventions** skill (naming map, comment policy, types,
formatter, and the semantic trap table for the language pair). Fill in the
**product README** in the product repo (seeded by `tools/new-product.sh` at init): it
describes the ported codebase to a consumer - what it does, a link to the original
project, how to build and run it - and says nothing about the porting process. It is a
real DELIVERABLE, not a one-time stub: at init you write what you can (what it does, the
origin link), and you FINALIZE it - exact build + run commands, usage, status - as the
product becomes buildable/usable, owned and reviewed like product docs (the integrator
never hand-authors it - the build/README are reviewed deliverables). Keep
porting-process content (charter, TRACE, reference runs, proofs, anchors, sprints) out
of it; `tools/conformance/check-product-readme.sh` guards against the known
methodology-vocabulary leaks, and its `--require-filled` mode (run by `/port-digest` at
the product-milestone / handover sign-off) fails if the README is still an unwritten
placeholder - so a milestone never seals with a README a consumer cannot use. How to write
it well - audience and voice, the leak-vs-provenance line, and translating KNOWN-DIVERGENCES
into an honest supported-subset - is in `references/product-readme.md`. The TARGET code (in the product repo)
builds and runs at every commit (Directive 6), differs structurally from the
SOURCE only by the charter §5 mechanical transformations (everything else is literal),
pins compiler and deterministic flags per the charter, and mirrors per-file status in
`port/TRACE.yaml`. Exit check: tooling
demonstrated on the SOURCE alone (dump/restore round-trips, probes silent on the
reference run), AND every proof/probe demonstrated to fire on a seeded bug before
first real use (the seeded-bug rule - see The review layer); conventions signed off
with their enforcement scripts landed.

### Phase 2 - Language translation (SOURCE → INTERMEDIATE or TARGET-serial)
- Translate module by module in dependency order (utilities and data structures first,
  then operators, then drivers), literally, under Directives 1-4, following the
  bring-up order in `references/bring-up-strategy.md`. Render per
  `port/conventions/<source>-to-<target>.md`, with the semantic trap table open during translation, not
  consulted after the bug.
- Verify per procedure under the per-procedure verification policy
  (`references/validation-ladder.md`): classic unit tests for pure/narrow-footprint
  routines, capture-replay against reference dumps for wide-footprint routines, the
  ladder for seams. Early modules, before differential comparison exists, are accepted
  by *intrinsic* checks (tier R0). These tests are **product-owned**: drivers live in the
  product's `tests/unit/` and the vectors they replay in `tests/fixtures/`, built by the
  product's own build so a clone is self-testing - the fixture generator that instruments
  `source/` stays in the workbench (`conformance/check-product-tests.sh` keeps tests from
  being orphaned there). Bind every assertion that claims to discriminate a rendering choice
  to a PRODUCTION entity - the function's output, its signature, a production-declared
  field - never a test-local stand-in, and pick a fixture that can observe the choice; document
  a site that is non-discriminable by construction with its measured delta, never fake it
  (`references/failure-modes.md`, B23 and its refinements).
- Track **performance parity** from the first milestone (see
  `references/performance-campaign.md`): a literal port is roughly
  performance-neutral, so a deviation outside the charter's parity band is a
  finding to investigate (build flags, debug artifacts, rendering bugs), never a
  license to optimize during translation. Run that file's **fair-field check** (effective
  compile lines and artifact freshness, on BOTH sides) before recording any comparison.
- **Acceptance** follows the bit-identity rule (`references/validation-ladder.md`): a
  cross-language stage is never assumed bit-identical. It is held to the SOURCE's own
  validation criterion, or to the statistical test design agreed with the human and
  recorded in charter section 7. Validate at the **full-scale, real-use configuration** - the real inputs, sizes,
  and duration the code is genuinely run at (for a simulation, e.g., the full
  timestep, resolution, and workload), never a quick smoke test. Short smoke tests at
  forgiving settings systematically miss latent bugs (`references/failure-modes.md`,
  class N1).

### Phase 3 - Execution-model translation (serial reference → parallel/accelerated TARGET)
- Keep the serial reference from Phase 2 alive *inside* the TARGET tree, compiled with
  the same compiler. Where the INTERMEDIATE is a (near-)subset of the TARGET language,
  verify the pure re-compilation step is bit-identical before any parallel work.
- Port kernel by kernel; each ported kernel keeps its serial "twin" with a runtime
  verify mode whose acceptance on a deterministic backend is **exactly zero** difference.
- Instantiate the full ladder (R1-R5) from `references/validation-ladder.md` in the
  charter. Bit-identity typically holds only at a fixed process count; record it.

### Phase 4 - Performance campaign (only after correctness)
Read `references/performance-campaign.md` before any tuning. Core rules: optimize only
under the bit-identity (or ladder) constraint; profile before every change; run the
**fair-field check** on both sides before any SOURCE-vs-TARGET comparison; expect the
first accelerator run to be *slower* than the CPU baseline; delete optimizations that
don't measure as wins and record them as negative results.

### Phase 5 - Portability and handover

**Pin the portability targets first, by interview - as Phase 0 pins the
configuration.** Do not assume the platform set; elicit it from the human: which CPU
architectures, OSes, compilers, accelerator vendors, and named machines (e.g. a
specific HPC system) the port must run on, and crucially HOW to build and run on each
(login/SSH access, module environment, scheduler, toolchain). Record it as the
portability-target matrix in the charter. The agent brings the port up on the REAL
target the human gives access to, never a stand-in: a port validated only on the
development machine is unproven elsewhere, and that is exactly where platform-
conditional code sits silently inert (failure mode N7).

**Classify each target's acceptance bar by the bit-identity rule**
(`references/validation-ladder.md`): a target that preserves arithmetic is held to
bit-identity against the canonical reference (R2); one that changes it is held to
statistical parity (R5) with per-field bounds the human confirms, and its floating-point
floor recorded. Chaining carries the home validation onto each.

**Bring up early, then consolidate.** Cross-platform bring-up *begins* as soon as Phase
3 yields a portable build - a cheap smoke test on a materially different platform
flushes out N7 guards before they cost anything. Phase 5 then runs each target's
classified ladder to completion and consolidates: the per-platform evidence pack (ladder
results plus recorded floors) in `docs/evidence/`, the final LESSONS distillation, and a
retrospective written explicitly as *context for the next port*.

## Sprint protocol (every sprint, no exceptions)

The project state lives in ordinary files under `port/`, not in conversational memory:

- `port/plan/00-charter.md` - pinned configuration, acceptance criteria, named
  exceptions, mechanical-transformation list, canonical reference run. The constitution.
- `port/plan/` phase files and `port/plan/modules/` cards - milestones, git-tagged.
- `port/TRACE.yaml` - source→target traceability matrix (see Working at scale).
- `port/LESSONS.md` - append-only ledger; STANDING RULES block at top.
- `port/KNOWN-DIVERGENCES.md` - accepted differences; do not chase these.
- `port/SOURCE-FINDINGS.md` - probable bugs in the SOURCE itself, to report upstream; RECORD, never fix.
- `port/handoffs/<workstream>.md` - rewritten at the END of every sprint.

**On sprint start** (`/port-sprint-start`): read your workstream's handoff, then the
STANDING RULES in LESSONS.md, then the relevant plan section, then KNOWN-DIVERGENCES.md.
Restate the prime directives plus the standing rules. Do not begin work before this.

**During the sprint:** work the coherent unit named in the handoff (it may span
several related steps). If it turns out larger than one sprint can hold reliably,
split it: update the plan, write the handoff, recommend a fresh sprint.
Record a genuine lesson the moment it happens - auto-run the capture-only `/port-lesson`
procedure yourself, then report what you wrote - never deferring it to sprint end.

**On sprint end** (`/port-sprint-end`): update plan checkboxes and TRACE statuses, append
to LESSONS.md, rewrite the handoff. Commit the state files with the code. A milestone
passed = a git tag.

## The self-improvement loop

How the port gets *easier* as it proceeds instead of repeating its failures:

1. **Capture.** Whenever a bug is found, a proof fails, a wrong assumption is exposed, or
   an approach is abandoned, append a LESSONS.md entry *in the same sprint*: date/phase,
   symptom, root cause, fix, and - most important - the **rule or detector that would
   have prevented it**. Tag every entry with its failure-class and trap IDs (N2, B1,
   T6, ...): the ledger is consulted by search, never by linear reading.
2. **Promote.** A lesson that is general or recurs gets promoted into STANDING RULES -
   short imperative rules every future sprint restates. Keep the block under ~20 rules;
   merge or retire stale ones at retrospectives.
3. **Mechanize.** The strongest promotion is from rule to *tool*: an always-on probe, a
   proof, a conformance script in `tools/`, a CI check. A rule depends on being remembered; a check does not. At scale, mechanization is the primary defense, not the
   backstop - a human cannot diff-review everything.
   Mechanization is also **proactive**, not only bug-triggered: when a sprint
   creates or reveals an enforceable invariant (a new idiom all call sites must
   follow, a contract a phase introduced, a property the charter implies), record it
   as a MECHANIZATION CANDIDATE in LESSONS.md. Candidates are recorded continuously
   (cheap) but BUILT only after triage at the phase retrospective - never
   build-as-you-go, because check sprawl is its own failure mode. A candidate is
   accepted only if it meets ALL of: (a) it cites the named failure class, trap, or
   charter rule it guards - no citation, no check; (b) it is cheap to run (CI or
   env-switched probe); (c) near-zero expected false positives - a check that cries
   wolf erodes trust in every other check; (d) it will pass a seeded-bug
   demonstration. Deletion path: a check producing false positives or guarding a
   retired invariant is deleted and recorded under NEGATIVE RESULTS; silence alone
   is never grounds for deletion (a detector that never fires may be deterring).
4. **Retrospect at phase boundaries.** Re-read LESSONS.md, fold what's relevant into the
   next phase's plan, write a short retrospective into `port/retrospectives/`. A lesson
   class recurring despite a standing rule means: mechanize it or amend the plan.
   Triage the MECHANIZATION CANDIDATES block: build (criteria met), reject (record
   why, so it is not re-proposed), or defer with a named revisit point.
   Then **archive**: move closed entries (mechanized, or specific to finished modules)
   to `port/lessons-archive/phase-<n>.md`. L-numbers are permanent and never reused,
   so references survive archival; the active ledger stays lean. This is the size
   discipline for the whole state layer - no state file is ever required linear
   reading (handoffs are rewritten, standing rules are capped, plans are split per
   phase/module, TRACE is queried, the ledger is searched and archived).
5. **Feed forward across projects.** Every port runs in its own clone/fork of the
   base repo; the methodology layer (skills, commands, templates, generic tools) is
   shared property. Keep methodology improvements in their own commits (never mixed
   with project-layer changes) so they cherry-pick cleanly, and run `/port-contribute-to-base` at
   phase retrospectives and at project end: distill what generalizes from LESSONS,
   mechanizations, and trap-table additions, strip every project specific, and
   propose it to the base repo. The human approves what flows up. The skill is
   versioned knowledge; it should grow.

## The review layer (independence insurance)

Proofs detect divergence when executed; they cannot review themselves, cannot see that
the reference is wrongly pinned, and catch literalness violations only when (and if) a
run exercises them - late and expensively. The review layer covers exactly those
structural blind spots and nothing else; anything scriptable belongs in `tools/`, not
in review:

1. **Independent fidelity review.** Before any TRACE entry moves to `proven`, a session
   that did NOT produce the translation walks TARGET against SOURCE with the charter
   and trap table open (`/port-review`). Rationale: B1/B2/B3 are failure modes of
   the translating agent, and the session that rationalized a deviation will approve
   it again - independence is the control group. **The review unit is the sprint's
   coherent deliverable** (a module and its tightly-coupled helpers reviewed together as
   one report, which each covered module's TRACE `review` field points at), not a single
   file. **Timing is producer-before-consumer:** review a unit before anything consumes
   it, never deferred to a milestone, because a violation in a producer corrupts every
   consumer built on it. Keep this cheap by running the review as a **background
   sub-agent task by default** rather than a manual fresh session: low friction is what
   lets per-unit review stay timely. When several units are pending, `/port-review` detects
   the whole review queue itself (grouping tightly-coupled entries into one unit) and reviews
   them as a batch - one independent sub-agent per unit IN PARALLEL, each writing only its own
   report; the orchestrating session then applies the TRACE and handoff writes serially (one
   writer per worktree), commits the review evidence in one project-layer commit (an
   independent review session has no porting sprint-end to ride on, so review commits its own
   evidence), and presents a single consolidated verdict round: N independent reviews, one
   human decision, never N rounds. A milestone tag is then just a forcing
   function - it
   requires that every module it covers is already reviewed and proven. Whichever way it
   runs, the reviewer needs a clean context (no author rationalizations) and a recorded
   `reviewer_session` disjoint from `author_sessions`. It self-orients from the handoff's
   awaiting-review pointer and the TRACE review queue (proof set and not proven - review null, or set to a violations verdict),
   never from conversation. Review is read-only, walks a fixed checklist, and every
   finding cites SOURCE and TARGET file:line pairs.
2. **Tooling trust (seeded-bug rule).** A proof or probe is trusted only after it has
   been seen to fail: before first real use it must demonstrate firing on a seeded
   bug representative of its target failure class, recorded per
   `assets/SEEDED-BUG.template.md` (red proof, removal, green proof, logic version)
   and renewed after any change to comparison logic. A proof that has never failed is
   unproven, and a buggy always-pass proof is worse than none.
3. **Evidence pre-digest.** At phase boundaries, an agent compiles and cross-checks
   the evidence pack (proof runs vs charter criteria, TRACE vs tags, placeholders
   closed, comment audit done; the /port-digest command) so the human's
   bandwidth goes to judgment, not collation. Acceptance is sealed by `finalize.sh`:
   hand-driven, a human accept-`SIGNOFF.md` (`assets/SIGNOFF.template.md` filled into the
   evidence pack); in L2/L3 auto-mode, `finalize.sh --auto` after full conformance green at HEAD,
   with each piece's independent review and the §7 standard set once in the charter as the
   acceptance. A milestone tag is created only through that check.

`proven` in TRACE is therefore a TECHNICAL status: acceptance proof passed (tier R1
or higher, never R0) AND independent fidelity review clean, both with evidence
recorded, author and reviewer sessions disjoint. Phase/milestone ACCEPTANCE is the
sealed sign-off above, a separate and superior thing. What review is NOT for:
anything a conformance script or proof already covers, style (the formatter owns
it), or re-running validations (CI owns it). A review without a checklist and
citation duty is theater.

## Working at scale (multi-workstream ports)

A small port runs as one stream: one handoff, serialized sprints. A large port (a big
codebase, multiple humans/agents) adds a coordination layer - activate it when more than
one workstream exists; until then the files simply stay short:

- **TRACE (`port/TRACE.yaml`).** Every live SOURCE file appears exactly once: its TARGET
  file(s), status (`unmapped | in-progress | proven | excluded`), workstream, proof
  evidence, review evidence, tag. `proven` requires both the acceptance proof and the
  independent fidelity review (see The review layer). CI checks completeness - no
  source file silently dropped. This is the scale replacement for "the map in one
  person's head."
- **Workstreams.** Partition the module dependency graph into streams that can proceed
  in parallel (per subsystem, dependency-ordered inside each). At scale the graph is
  extracted by tooling (`tools/scoping/`), not assembled from memory, and TRACE is
  generated by script from the SOURCE tree plus the live-subset result, never
  hand-written. Each stream gets its own
  handoff in `port/handoffs/` and plan card in `port/plan/modules/`. LESSONS.md, the
  charter, and KNOWN-DIVERGENCES.md remain **global** - lessons are the shared immune
  system, and a divergence accepted in one stream must not be re-investigated in another.
- **Coordination (`port/COORDINATION.md`).** Interface contracts between streams,
  do-not-touch locks, merge order. A stream may only depend on another stream's output
  once it is `proven` in TRACE.
- **Producer-before-consumer across streams.** When a stream introduces a reader of a
  field or routine owned by another stream, verify the producer is ported and proven
  first (failure mode N3 generalizes across streams).

## Division of labour

You (the agent) own: reading, literal translation, harness construction, debugging,
profiling, documentation, and the state files. The human domain expert owns: strategy,
plan and diff review, authorizing exceptions to literalness, judging statistical
acceptance (whether a residual difference is physically meaningful), and the final word on every acceptance decision. **Never self-certify a stage acceptance:** present the evidence (in
`docs/evidence/`), recommend a verdict with reasoning, hand the human a concrete
verification runbook (exact steps and the good-vs-bad signature) for anything that
needs their judgment, and let them decide. You recommend; the human signs.

## Reference files (read when entering the relevant phase)

- `references/validation-ladder.md` - acceptance criteria and proofs; the two regimes;
  tiers R0-R5; the per-procedure verification policy; what can and cannot be
  bit-for-bit. Read at Phase 1 and 3.
- `references/differential-tooling.md` - the six tool classes, design rules, the
  proof-failure workflow, and the poison-don't-perturb discriminator. Read at Phase 1
  and whenever debugging.
- `references/bring-up-strategy.md` - the fast rig, synthetic inputs, intrinsic
  acceptance, order of work, interim-placeholder registry. Read at Phase 1-2.
- `references/failure-modes.md` - taxonomy of porting failure classes with symptom →
  detector pairs. Its detector column is the requirements list for Phase 1 tooling.
  Read at Phase 1 and whenever debugging.
- `references/performance-campaign.md` - measure-first optimization under a correctness
  constraint; scale proxies; typical bottleneck sequence. Read at Phase 4.
- `references/two-repo-architecture.md` - the workbench/product split: linkage, kept
  provenance anchors, the land/seal review-to-tree binding, the two-root proof contract, the
  cross-repo trust boundary, chisel-invisibility, and migration. Read before separating the
  product repo (and whenever touching linkage or proof invocation).
- `references/team-coordination.md` - the coordination substrate for parallel work:
  shard-and-generate status fragments, atomic claims, owned surfaces vs the leaf pool,
  the dependency map, interface contracts, the integrator/merge-queue, and the
  `integrated` state. Read before running Phase 1 or Phase 2 with more than one
  contributor.
- `references/parallel-phase-1.md` - building the tooling in parallel on the substrate:
  Layer-0 harness first, Layer-1 fan-out, the broader per-tool acceptance ladder (a seed
  is necessary but not sufficient), and parallel read-only exploration feeding the
  dependency map. Read when fanning out Phase 1.
- `references/parallel-phase-2.md` - running the bulk translation with many workers: the
  four roles, the wave loop, the staged build order + the hard fan-out entry check,
  parallel-by-default (fan out the whole safe ready-set every wave; no earned-width ramp),
  the two-repo wiring (worker PRs to the product, evidence to the workbench), and
  the multi-person mapping. Read before fanning out Phase 2.

Templates in `assets/`: charter, handoff, lessons, trace, known-divergences,
product-README, the calibration brief (`CALIBRATION.template.md`, the guided
evidence-backed tolerance-setting surface - `/port-calibrate`), plus the two-repo
linkage (`product.yaml.template`) and the per-work-item status fragment
(`status-fragment.template.yaml`).

Sibling skill: **target-conventions** - deterministic rendering rules for the TARGET
language (naming, comments, types, formatter, semantic trap tables per language
pair). Instantiated into `port/conventions/<source>-to-<target>.md` at Phase 1; read by every sprint
that writes TARGET code.
