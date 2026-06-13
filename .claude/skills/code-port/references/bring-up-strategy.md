# Bring-Up Strategy

How to grow the port from nothing to the full, real configuration while staying
runnable, verifiable, and fast to iterate at every commit. Read at Phase 1 (to set up
the rigs) and throughout Phase 2–3.

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
