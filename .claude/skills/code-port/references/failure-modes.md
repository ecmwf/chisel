# Failure Modes in LLM-Assisted Numerical Porting

A taxonomy of recurring failure classes, each paired with its characteristic symptom and
the detector that catches it cheaply. Derived from production-scale porting experience
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

## Numerical failure modes (about the *code*)

**L1 - The latent bug (most expensive class).** A genuinely-used term or constant,
mis-ported such that its effect is negligible at smoke-test settings but significant at
production settings. Canonical instance: a stabilization constant mis-ported many orders
of magnitude too small - the resulting marginally-unstable scheme blows up only deep
into a production-length run, and only at the production timestep. *Detectors:* validate
at the production configuration over production-relevant duration (not just smoke
tests); the file:line constant rule; per-kernel twin checks (the twin keeps its own copy
of every coefficient, so a mistyped constant fails the gate immediately).

**L2 - Stale exchange region (distributed-memory specialist).** A write loop ported
over owned points only where the SOURCE wrote owned-plus-halo. Diverges *silently*, and
only at some process counts; the damage can be indirect (a stale coefficient at the halo
breaking a cancellation several subsystems downstream) and can scale with the timestep,
so it passes at a short step and kills the production step. *Detectors:* the boundary
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

## The meta-lesson

Every class above breaks an unguarded port and is caught *cheaply* by one specific
guard. None is reliably caught by manual inspection. Therefore: build the guard set
before the port (Phase 1), and when a new failure class appears, mechanize its detector
and add it here.
