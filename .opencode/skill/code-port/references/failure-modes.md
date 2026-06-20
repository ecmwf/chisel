# Failure Modes in LLM-Assisted Numerical Porting

A taxonomy of recurring failure classes, each paired with its characteristic symptom and
the detector that catches it cheaply. Derived from full-scale porting experience
and intended to grow: when a project ends, fold its distilled LESSONS.md back into this
file (with the human's approval).

Read this file at Phase 1 - its detector column is the requirements list for your
differential tooling - and again whenever debugging.

## Agent-behavioral failure modes (about *you*)

**B1 - The urge to improve.** A standing tendency to simplify, modernize, or
"clean up" during translation. Each improvement produces *plausible* output and an
unbounded debugging search; whole port attempts have failed through accumulated
improvements alone (a linearized coefficient, a lookup table replaced by a closed form,
a volume ratio swapped for an area ratio, a history length mismatched to a scheme's
order - each individually defensible, each wrong). *Detector:* the
literal-translation rule itself, plus human diff review. If you notice yourself
rationalizing a deviation as harmless, stop and record it as a proposed exception in the
charter instead.

**B2 - Plausible paraphrase instead of the actual line.** Stating what the SOURCE does
from memory, from pattern-completion, or from a code comment rather than from the line
itself. Comments can be confidently wrong; a wrong comment about a constant has hidden
an instability for several working sprints. *Detector:* the file:line citation rule -
every claim about SOURCE behavior quotes path, line number,
and literal text read this sprint. *Mechanization:* machine-checked provenance
anchors - constant anchors embed the literal as read, and a conformance script
verifies the anchor against the pinned SOURCE line and the TARGET rendering, both
directions, in CI (see the target-conventions skill). Inherited comments are marked
untrusted; one found contradicting its code is upgraded to a contradiction marker and
logged, so a lying comment is defused once instead of re-trusted by every later
sprint.

**B3 - Following the inactive branch.** Porting a plausible code path that the pinned
configuration never executes, or adopting an in-source default that the run's parameter
file overrides. (Typical instance: a scheme existing in two implementations selected by
one parameter, where the obvious one is the wrong one.) *Detector:* the
pinned-configuration contract in the charter; provenance recorded for every effective
parameter value (parameter file > source default); the multi-run statistical comparison
catches survivors as systematic regional bias.

**B4 - Chasing an accepted divergence.** Spending sprints investigating a difference
that is correct SOURCE behavior (partition-dependent reductions, documented
nondeterminism, the recorded accelerator floor). *Detector:* the accepted-divergence
registry (`port/KNOWN-DIVERGENCES.md`) - consulted first in every debugging workflow,
appended only with human sign-off.

**B5 - Stale sprint state over a moving repo.** A sprint persists state -
whole-file rewrites of handoffs or plans, commits - based on what it read at sprint
start, while the repo moved underneath: a concurrent edit is silently overwritten by
a stale write, or a plain commit silently concludes an in-progress merge and sweeps
foreign staged content in under the sprint's commit; no conflict fires in either
case. *Detectors:* re-read or blob-compare every state file immediately before
rewriting it; before any commit, verify no merge is pending and the staged set
contains exactly the announced paths; after any commit, verify the parent hash
equals the HEAD reconciled against. *Prevention:* one writer per worktree - human
git operations happen between sprints, never during one; an agent finding the
worktree unexpectedly changed stops and reports rather than absorbing or reverting.

**B6 - Coverage read as liveness.** Excluding a compilation unit from the port because
coverage shows it never executed - but a declarations-only unit (constants, type
aliases, shared data; no executable statements) emits zero coverage at any run length
while being essential, referenced by live code. Dropping it removes constants or types
the port needs, forcing a build failure or, worse, a hand-re-derivation (a
literal-translation violation, B1). *Detector:* determine the live subset from THREE
signals, not coverage alone - executed = live; not-executed AND declarations-only AND
referenced by live code = live; not-executed AND (contains procedures OR unreferenced)
= REVIEW (human decides, never auto-exclude). *Prevention:* exclude a unit only with
proof of deadness (not compiled, or code-read unreachability), never on coverage
absence. Corollary: once every non-executing unit is shown declarations-only, the
executed set is provably complete, so a short coverage run suffices - no long run is
needed to "be sure". *Corollary (build-graph liveness):* the link-map / build graph is
the authoritative inclusion signal but is necessary-not-sufficient when the build
GENERATES sources - generated-source templates (configure-time inputs) and headers are
not link inputs. A template is live iff its generated output feeds a live unit; a header's
liveness comes from the COMPILER DEPFILES (the real post-preprocessor include graph),
never text-grep (which false-positives on disabled `#ifdef` blocks and misses
include-path variants). A live-tree header included by no live unit is REVIEW, never an
auto-exclude.

**B7 - Assembly-gated deliverable landed per-id.** Landing a multi-module deliverable one member at a
time when its GATE is assembly-level - one differential links several modules, so no single member passes
the gate in isolation - and its parallel-port work branches are independent full-closure trees (each
carries its whole dependency closure and defines the same build target). The first member's land moves the
product mainline and STALES every sibling branch; the members' build files collide on landing; and an
intermediate mainline holding only some members cannot pass the assembly-level gate, so the two-root
merge-result check goes red on each step. *Detector:* before landing, ask whether the gate differential
links more than one module, OR whether the work branches each carry the full closure / share a build target
- either means the deliverable is assembly-gated, not a set of independent pieces. *Prevention:* land the
whole member group as ONE reviewed **assembly piece** - an assembled `work/<assembly-id>` branch (the gated
members + their build glue) with one INTEGRATION-LEVEL review of the assembled commit (bound by
check-trace-evidence, no manifest) - via `tools/coordination/integrate_assembly.sh <assembly-id> --members
"<id> ..."`; never land a member of an assembly-gated deliverable alone. (See references/two-repo-architecture.md.)

**B8 - Unratified seam departure.** A rendering choice that departs from literal
translation to handle a SOURCE-language construct with no direct TARGET analog (a
foreign-library bridge that vanishes at the language boundary, a generic interface
that does not collapse to a single dispatch, an execution-model branch deferred to a
later phase, a FIAT-external symbol rendered as a no-op seam) - each individually
defensible, each a judgment call the author must NOT make unilaterally. *Symptom:*
the code is numerically clean (the twin is bit-identical) but the independent review
flags it as a governance finding because the departure was neither authorized by the
human nor recorded in the divergence registry. *Detector:* the independent review
assesses each seam rendering against the charter's mechanical-transform list; any
departure not on the list is a finding until the human ratifies it in
`port/KNOWN-DIVERGENCES.md` and a separate clean re-review confirms. *Prevention:*
surface every seam rendering for the human BEFORE gating; register it in the
divergence registry as review-pending; the fix is a registry row + a re-review in a
separate session, not a code edit. When ratification is the ONLY remediation (no
code change), the gate evidence is not stale, so the re-review reuses the same twin.

**B9 - Editing a gated file without re-gating.** Modifying a file whose TRACE status
is `gated` (the independent review passed, the gate is green) and presenting it as
still gated. The prior review covered the OLD code; the edit invalidates it.
*Symptom:* a small cosmetic or consolidation edit (moving a static helper to a shared
module, stripping a comment) lands on a gated file; the gate re-runs green, but the
independent review has not seen the new code. *Detector:* the TRACE status field -
editing a gated file reverts it to `in-progress` and OWES a fresh independent
re-review in a separate session. The old review pointer is kept but noted as
pre-edit; the editing session is appended to `author_sessions`. Re-run the module's
numerical twin to show the change is behavior-neutral before claiming it.
*Prevention:* the gate is a property of (code, review, evidence) triple; any leg
changed invalidates the triple. A cosmetic edit is not a reason to skip re-review -
it is a reason to do one quickly.

**B10 - Behaviour-neutral departure presented as done.** A rendering choice that is
faithful and numerically neutral but departs from the charter's mechanical-transform
list, presented as complete without being recorded in the divergence registry.
*Symptom:* the independent review returns VIOLATIONS on code whose twin is
bit-identical, purely because a rendering departure (e.g., dividing a live range
differently, clamping a subtraction-derived allocation to non-negative) was not in
the registry. The author believed "faithful + neutral = done"; the reviewer requires
"ratified + re-reviewed = gated." *Detector:* the divergence registry - every
behaviour-neutral departure from the mechanical-transform list is a governance
finding until it carries a registry row marked delegate-ratified / human-authorized
AND a re-review in a SEPARATE session passes. *Prevention:* register the departure
BEFORE presenting for review, not after. The fix is a registry row + re-review, not
a code edit (when the code is already correct).

**B11 - Pre-writing the review disposition.** Authoring the evidence README with the
review outcome ("Independent review (clean first-pass) -> GATED") BEFORE the
independent review runs. *Symptom:* the evidence pack asserts an outcome that has
not happened; the independent reviewer flags it as a governance violation (the
evidence is claiming authority it does not have), and the code may be fully clean
but still draws a FINDINGS verdict purely on the premature-disposition issue,
costing a fix + a separate clean re-review. *Detector:* the evidence README's review
section - if it states a verdict before the reviewer session exists, it is
premature. *Prevention:* author the evidence with the review section as PENDING (or
stating only the facts that exist - the gate result, the seeded-bug, the bring-ups);
fill in the review outcome + the GATED disposition ONLY after the verdict returns.
The code can be fully clean and still draw a findings verdict on this governance
issue alone.

## Numerical failure modes (about the *code*)

**L1 - The latent bug (most expensive class).** A genuinely-used term or constant,
mis-ported such that its effect is negligible at smoke-test settings but significant at
full-scale settings. Canonical instance: a stabilization constant mis-ported many orders
of magnitude too small - the resulting marginally-unstable scheme blows up only deep
into a full-length run, and only at the full timestep. *Detectors:* validate
at the full-scale configuration over a full-length run (not just smoke
tests); the file:line constant rule; per-kernel twin checks (the twin keeps its own copy
of every coefficient, so a mistyped constant fails the gate immediately).

**L2 - Stale exchange region (distributed-memory specialist).** A write loop ported
over owned points only where the SOURCE wrote owned-plus-halo. Diverges *silently*, and
only at some process counts; the damage can be indirect (a stale coefficient at the halo
breaking a cancellation several subsystems downstream) and can scale with the timestep,
so it passes at a short step and kills the full timestep. *Detectors:* the boundary
probe (copy, exchange, compare) run over all candidate fields at once; byte-identity
across rank counts where achievable. *Prevention:* size every field any downstream
routine might read at the exchange region at owned-plus-halo - the memory cost is
trivial and the failure severe.

**L3 - Allocated but never computed.** A field allocated and exchanged but never
assigned; it sits at zero and passes differential comparison (the reference is also
untouched at that phase), failing only when a later phase consumes it. *Detector:*
always-on physical-range probes. *Prevention (planning rule):* producer before
consumer - when a phase or workstream introduces a *reader* of a field, first verify
the *writer* is ported and gated; if none exists, port the producer first.

**L4 - Wrong stride / wrong extent.** Indexing with a loop bound where the allocated
extent belongs (or vice versa), classically when converting array storage order or
index base. Effect is typically violent (gradients inflated by orders of magnitude,
solver failure within steps). *Detector:* per-kernel twin check, which saturates far above the noise
floor at the first invocation. *Prevention:* take the stride from the allocation shape,
never from the iteration range; fixed, centrally-defined index helpers (macros, inline
functions, or accessor methods) - never ad-hoc index arithmetic at call sites; enforce
with a conformance script in `tools/conformance/`.

**L5 - Staggering / centering / location-class confusion.** In any code with
discretized fields on a grid or mesh: data stored at one location class
(vertices/cells/edges/faces, or staggered grid positions) used as if at another,
corrupting geometry-derived quantities. Especially likely on unstructured or staggered
discretizations, which are under-represented in training data relative to regular
grids. *Detector:* staged reference dump localizes the substep; identical-input diff
confirms the operator.

**L6 - Configuration drift.** A parameter whose effective value comes from the run's
parameter file, ported from the source-code default instead. Produces a *correct-looking*
model with a systematic bias. *Detectors:* pinned configuration with provenance (B3);
long-run statistical comparison.

**L7 - Vendor/platform-conditional code silently skipped.** A feature guarded by a
platform-specific compile flag is silently inert on a new platform - correct but slow,
or subtly different. (Typical instance: a device-residency layer behind a
vendor-specific guard, silently falling back to host staging on the other vendor.)
*Detector:* bring-up on a second, materially different platform early (a Phase-5 smoke
test can run as soon as Phase 3 yields a portable build); audit all conditional guards
to use neutral *capability* flags rather than vendor-specific ones.

**L8 - Stale authoritative copy (multi-memory-space specialist).** Two copies of a
field exist (host/device, cache/store, primary/mirror); one is updated, the other is
read. Invisible on the fast rig for many commits; surfaces only in configurations where
the stale reader is actually exercised, and grows orders of magnitude above the
floating-point floor. Naive debugging (toggling synchronizations) is confounded on
chaotic systems because it also changes execution order. *Detectors:* the executable
memory-authority contract (tool class 6) - a build that aborts when the non-authoritative
copy is read; the poison discriminator for localization; the mandatory short
all-subsystems-active gate (R4) before any commit touching data movement.

**L9 - Storage-order transform broken by buffer reinterpretation.** When the port
converts array storage order (the classic column-major to row-major), the per-array index
transform is sound only while each array owns its bytes. It becomes UNSOUND when one
buffer is reinterpreted under multiple shapes - aliased as several differently-shaped
arrays within a routine (EQUIVALENCE/overlay style), or reused and RESHAPED between
routines by a driver (one pass's output becomes the next pass's differently-shaped input
through the same scratch buffer). Transforming each view independently leaves every view
internally consistent, but the views disagree on byte layout: elements that coincide in
the SOURCE storage order no longer coincide. Because each routine is locally correct it
PASSES ITS OWN isolated gate, and the corruption surfaces only once the routines are
composed through the shared buffer - a suite of green per-unit gates sitting over a broken
composition. *Detector:* an end-to-end gate over the composed pipeline, with inputs sized
to FORCE multi-unit composition (not the single-unit paths that dodge the seam); a green
per-unit gate is necessary but NOT sufficient here (see `validation-ladder.md`, rules of
thumb). *Prevention:* storage order is a WHOLE-SUBSYSTEM property, not a per-array one - if
any buffer is reinterpreted across views or routines, every routine touching it must share
ONE storage order: either preserve the SOURCE storage order for those buffers (a
charter-listed carve-out in the central index helpers) or route all views through a single
shared flat-index scheme. Decide it before porting the first aliased routine.

**L10 - Validating a stochastic code by comparing full runs (a cross-language false gate).**
An RNG-driven code (optimizer, Monte-Carlo, sampler) cannot be validated by running SOURCE and
TARGET to completion and comparing the outputs. Two independent reasons: (1) the languages' PRNGs
are different algorithms (the compiler intrinsic vs the TARGET library generator), so identical
seeds produce different random streams from the first draw - the trajectories diverge by
construction (see the language-pair trap table); (2) even with an identical stream, finite-precision
FP chaos amplifies tiny rounding differences over a long iterative trajectory. A whole-run
comparison therefore conflates "is the port faithful" with "the dice landed differently," and over
few samples it has almost no statistical power. A sibling pitfall: calibrating the whole-program
(trajectory or distribution) tolerance from the per-KERNEL precision floor - a dimensional
mismatch, because the trajectory / seed-to-seed variance dominates the kernel floor by orders of
magnitude, so a floor-derived bound is unachievable even by a perfect port. *Detector:* DETERMINISTIC
fixed-input differentials - feed fixed inputs, and substitute a FIXED value where the source draws
randomness, to the kernels AND to each update step of the stochastic logic, comparing against
SOURCE-computed references at the per-kernel tolerance; this isolates the arithmetic from both RNG
divergence and long-run chaos. *Prevention:* make the deterministic fixed-input differential the
acceptance gate for stochastic units; keep the full stochastic run only as a COARSE plausibility
check (sane output range, completes), never a numeric bar; and calibrate any whole-program tolerance
from the MEASURED distribution spread, not the kernel floor (the calibration brief, `/port-calibrate`).

## The meta-lesson

Every class above breaks an unguarded port and is caught *cheaply* by one specific
guard. None is reliably caught by manual inspection. Therefore: build the guard set
before the port (Phase 1), and when a new failure class appears, mechanize its detector
and add it here.
