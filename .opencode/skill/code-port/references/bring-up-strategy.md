# Bring-Up Strategy

How to grow the port from nothing to the full, real configuration while staying
runnable, verifiable, and fast to iterate at every commit. Read at Phase 1 (to set up
the rigs) and throughout Phase 2-3.

## The fast rig

Every port needs a configuration that exercises the dynamical core end-to-end in
**seconds to a minute** - a tiny idealized problem that runs hundreds to thousands of
steps in well under a minute on one or two cores. This rig is the workhorse: the core is
rebuilt one kernel at a time and must be re-exercised many times a day, and no
full-scale configuration permits that cadence.

Rules:
- Set the fast rig up in Phase 1, on the SOURCE side first, so reference dumps for it
  exist before translation starts.
- The fast rig is for *iteration*, never for *acceptance*: latent bugs (failure class
  L1) and data-movement bugs (L8) are invisible on it by construction. Acceptance runs
  use the realistic configuration at full-scale settings; the mandatory short
  all-subsystems-active gate (R4) exists precisely because the fast rig cannot catch
  what it cannot exercise.
- Keep a ladder of rigs if useful (tiny → intermediate → full-scale), and know which
  property each rig does and does not preserve (see scale proxies in
  `performance-campaign.md`).

## Synthetic inputs: decouple numerics from I/O

The real code drives its physics from external inputs through an I/O subsystem
that may not exist yet in the port. Do not let numerics bring-up wait on I/O: have the
port *synthesize* its driving inputs in code - analytic forcing fields, prescribed
boundary conditions, constant initial states - designed to excite exactly the behavior
the current phase must validate (e.g., an analytic forcing profile shaped to drive a
known, testable circulation; mind coordinate frames and grid rotations when
synthesizing, or the pattern will not land where the physics expects it). Retire the synthetic driver once the real
reader exists; its purpose is to separate validation of the numerics from validation of
the input system during the period when both are being built.

## Intrinsic acceptance (ladder tier R0)

Early modules exist before any differential comparison is possible. Accept them by
*intrinsic* physical checks, agreed with the human per phase:
- an equilibrium/rest state stays at equilibrium;
- a small disturbance propagates at its known analytic speed;
- N steps (hundreds to thousands) run without instability;
- conserved quantities are conserved to the expected degree.
R0 is scaffolding, not proof: every R0-accepted module must eventually sit under the
differential tiers (R2/R5) at full-scale settings.

**The bring-up gate sprint (the R0 -> R1 hand-off).** R0 can never GATE a unit (validation-ladder.md):
gating needs R1 - a real differential against the SOURCE - and the cross-language capture-replay
harness that produces R1 is co-developed WITH the first TARGET code, so the first module reaches
R0-clean + independently-reviewed before that harness exists. That moment is a named, one-time
**bring-up gate sprint**, not a wall: stand up the R1 capture-replay harness (fixture generator +
replay + differential comparator, see validation-ladder.md's cross-language twin), wire the
naming-map check and the anchor verifier onto the TARGET tree, and pin the tooling baseline - each
seeded-bug-demoed and independently reviewed. Template: `assets/BRING-UP-GATE.template.md`
(instantiated to `port/bring-up-gate.md`, named for the first module). Build it once; afterwards every
module gates against it. Under `/port-autodrive` this stop is SCAFFOLDED (the plan is written and the
sprint set up), never auto-built - the harness is creative, fidelity-critical tooling with its own
review lifecycle.

## Order of work (instantiate per project)

The following order has proven itself on full-scale ports; instantiate it in the
phase plan:

1. **Serial baseline** - data structures mirroring the SOURCE's modules, geometry/setup,
   the minimal dynamical core, simplest variants of selectable schemes. R0 acceptance.
2. **Idealized completion** - the remaining core operators on the fast rig with
   synthetic inputs. R0 acceptance (long stable runs).
3. **Realistic serial** - real input data, real configuration, the full-scale problem
   on one process. First differential comparisons against SOURCE dumps.
4. **Distributed memory** - partition input, exchange layer with a self-test, every
   array sized owned-plus-exchange-region, an audit of every loop bound against the
   SOURCE, exchange after every kernel whose output another rank reads. This is where
   the hardest bugs live (L2); build the boundary probe before this phase, not during.
5. **Remaining subsystems**, one at a time, each behind a disable-switch whose OFF
   state byte-matches the previous tagged commit (inertness check).
6. **Full-scale settings** - raise timestep/resolution/duration to full-scale values as
   an explicit, separate milestone. Expect this step to *expose* latent bugs (L1, L2)
   rather than to be a formality; budget debugging time for it.
7. **Close residual biases** - chase remaining statistical differences to their causes
   with the differential tools; restore any interim placeholders (below) as faithful
   ports.
8. **Multi-year / full-length validation** - the R5 evidence pack.

## Interim placeholders (the registry discipline)

Strict literalness has one pragmatic relaxation during bring-up: a complex scheme may be
temporarily stood in for by a simpler one (e.g., a lower-order scheme standing in for a
high-order one until the surrounding machinery exists) **only under all of these
conditions**:

1. the placeholder is registered in the charter's placeholder table (what, where, why,
   the faithful target) the moment it is introduced;
2. it has a named closure milestone - a phase cannot reach R5 sign-off with open
   placeholders affecting its physics;
3. when closed, the faithful port replaces it under the normal literalness rules, and
   the residual bias the placeholder caused is shown to disappear in the differential
   comparison (this is positive evidence the tooling works).

An unregistered simplification is failure mode B1, full stop. The registry is what
separates scaffolding from improvement-creep. The same discipline covers deferral
markers: a TODO/FIXME/HACK comment in TARGET code is an unregistered placeholder
unless it carries a registry ID and closure milestone - register it or do the work
now.

## Producer before consumer

When a phase or workstream introduces a *reader* of a field or routine, search the port
for its *writer* first. If the producer is not yet ported (or not yet gated, in
multi-workstream settings), port the producer first. An allocated-but-never-written
field passes every differential comparison until a later phase consumes it (failure
class L3) - this planning rule prevents the class instead of detecting it.

## Mechanical transforms are scripts

Any transformation described as "mechanical" in the charter (index-base flips,
storage-order conversion, cast insertion, global-to-argument threading) should be
performed by a script committed to `tools/`, not by hand-editing: a mass edit touching
hundreds of sites should be one reviewed script, not hundreds of hand edits. If you cannot script it, question
whether it is really mechanical - it may be a named exception in disguise. Conformance
rules (index helpers only, no raw vendor API in portable code, exchange-region sizing)
likewise become scripts in `tools/conformance/`, run in CI.

## Generate the TARGET build from the dependency graph, not the SOURCE build file

When you generate the TARGET build system, derive each unit's dependencies from the
SOURCE itself (Fortran `use` statements; C `#include`s / compiler-emitted depfiles), not
from the SOURCE's hand-maintained build file. A hand-maintained dependency list is often
INCOMPLETE: a missing edge is masked by the order files happen to be listed, so the SOURCE
build "works" only because serial compilation stumbles into a workable order. Reuse that
list verbatim and the TARGET build breaks the moment anything reorders it - extract the
real graph from the `use`/`include` edges instead (a committed script in `tools/scoping/`).

The generated TARGET build is itself a **reviewed deliverable** - it ships in the product and is
gated/reviewed like any piece. It is NOT something the integrator hand-writes while assembling a
multi-module deliverable: hand-authored "deliverable build glue" at land is the unreviewed-author
trap (seshat-integrator.md). Land each reviewed piece in dependency order and let the product build
up from reviewed bytes only.

## Faithful rendering of SOURCE quirks (do not normalize)

The SOURCE is the specification. Several classes of SOURCE construct look like
"obvious improvements" to normalize away but must be preserved verbatim - each is
failure mode B1 (the urge to improve) in a specific guise.

- **Vestigial IF with identical active branches.** An `IF` whose THEN and ELSE bodies
  have become identical (e.g., one branch's distinctive code was commented out in
  SOURCE, leaving both branches computing the same thing) is PRESERVED, not
  collapsed to a single path. Collapsing removes the branch and makes any
  condition-dependent variable unused - a "harmless improvement" that is a fidelity
  departure. Suppress any linter warning about clone branches at that one site with
  a tooling directive (not a prose comment); register the rendering in the
  divergence registry.
- **SOURCE-DEAD code guarded by a compile-time constant false.** A block the SOURCE
  never executes in any configuration (guarded by a `PARAMETER` whose value is
  `.FALSE.`, or a condition that is statically false) is rendered FAITHFULLY, not
  dropped. Dropping it is B1 (the SOURCE declared it; the port does not second-guess
  which configurations exist). It is NOT a gate-vacuity gap - the SOURCE never
  executes it either. The reviewer accepts it as faithful dead rendering.
- **Dead stores: SOURCE pre-initializes a local then unconditionally overwrites it.**
  A local assigned a value the SOURCE then immediately overwrites on every path
  (e.g., `real :: x = 0.0` followed by `x = computed_value()` on every branch) is
  PRESERVED with the literal init. Static analyzers flag it as a dead store; the
  faithful port keeps it and disables the analyzer sub-check as a documented
  carve-out at the project level (not a per-site suppression). The R1 bit-pattern
  twin is the real defense against a wrongly-dead store (it changes outputs, fails
  the twin); the analyzer warning is noise for this class.

## Gate non-vacuity for routing

A gate that ROUTES values (forwarding arguments, slicing arrays, transposing
buffers) must use INJECTIVE inputs or it is vacuous for the routing. Two equal-valued
forwarded args swapped produce no diff; two args with distinct weights but equal
values still miss a swap. Make every forwarded scalar pairwise DISTINCT in the
config AND fold each with a distinct weight, then the gate detects any swap or
omission. A gate that passes on uniform inputs but would fail on injective inputs
has not proven the routing.
