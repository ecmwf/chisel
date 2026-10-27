<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Bring-Up Strategy

How to grow the port from nothing to the full, real configuration while staying runnable,
verifiable and fast to iterate at every commit. Read at Phase 1 (to set up the rigs) and throughout
Phases 2 and 3.

## The fast rig

Every port needs a configuration that exercises the core solver path end to end in **seconds to a
minute**: a tiny idealized problem that runs hundreds to thousands of steps on one or two cores. It
is the workhorse: the core is rebuilt one kernel at a time and re-exercised many times a day, which no
full-scale configuration allows.

- Set it up in Phase 1, on the SOURCE side first, so its reference dumps exist before translation.
- It is for *iteration*, never *acceptance*: latent bugs (N1) and data-movement bugs (N8) are
  invisible on it by construction. Acceptance runs use the realistic configuration at full-scale
  settings; the short all-subsystems-active proof (R4) exists because the fast rig cannot catch what
  it does not exercise.
- Keep a ladder of rigs if useful (tiny, intermediate, full-scale), and know which property each
  preserves and which it does not (scale proxies, `performance-campaign.md`).

## Synthetic inputs: decouple numerics from I/O

The real code drives its physics from external inputs through an I/O subsystem the port may not have
yet. Do not let numerics bring-up wait for it: have the port *synthesize* its driving inputs in code -
analytic forcing fields, prescribed boundary conditions, constant initial states - designed to excite
exactly the behavior the current phase must validate (mind coordinate frames and grid rotations, or
the pattern will not land where the physics expects it). Retire the synthetic driver once the real
reader exists; it only separates validating the numerics from validating the input system while both
are being built.

## Intrinsic acceptance (ladder tier R0)

Early modules exist before any differential comparison is possible. Accept them by intrinsic
physical checks agreed with the human per phase:
- an equilibrium or rest state stays at equilibrium;
- a small disturbance propagates at its known analytic speed;
- hundreds to thousands of steps run without instability;
- conserved quantities are conserved to the expected degree.

R0 is scaffolding, never proof: an R0-accepted module is not `proven`, and it must later sit under the
differential tiers (R2, R5) at full-scale settings.

**The bring-up harness sprint (from R0 to R1).** Proving needs R1, a real differential against the
SOURCE, and the Phase-2 R1 harness (the cross-language twin, `validation-ladder.md`) is built with
the first TARGET code, so the first module is R0-clean and reviewed before the harness exists. That
moment is a named, one-time sprint, not a wall: build the capture-replay harness (fixture generator,
replay driver, comparator), wire the naming-map check and the anchor verifier onto the TARGET tree,
and pin the tooling baseline, each with a seeded-bug record and an independent review. Template:
`assets/BRING-UP-HARNESS.template.md`, instantiated to `port/bring-up-harness.md`. Build it once;
every later module is proven against it. The R1 proof and its harness are Phase-1 tooling units, so
at L2 and L3 `phase1_drive.py` builds them through the normal tooling loop and the Phase-2 planner then
resumes; at L1 they are recommended instead. Built automatically, never trusted automatically: each
carries its seeded-bug record and review before it proves anything.

## Order of work (instantiate per project)

This order has held on full-scale ports; instantiate it in the phase plan:

1. **Serial baseline** - data structures mirroring the SOURCE's modules, geometry and setup, the
   minimal core solver, the simplest variants of selectable schemes. R0 acceptance.
2. **Idealized completion** - the remaining core operators on the fast rig with synthetic inputs. R0
   acceptance (long stable runs).
3. **Realistic serial** - real inputs, the real configuration, the full-scale problem on one process.
   First differential comparisons against SOURCE dumps.
4. **Distributed memory** - partitioned input, an exchange layer with a self-test, every array sized
   owned-plus-exchange-region, every loop bound audited against the SOURCE, an exchange after every
   kernel whose output another rank reads. The hardest bugs live here (N2); build the boundary probe
   before this step, not during it.
5. **Remaining subsystems**, one at a time, each behind a disable-switch whose off state reproduces
   the previous tagged commit's outputs byte for byte (the inertness check).
6. **Full-scale settings** - raise step size, resolution and duration to full-scale values as an
   explicit milestone. Expect it to *expose* latent bugs (N1, N2), and budget debugging time for it.
7. **Close residual biases** - chase the remaining statistical differences to their causes with the
   differential tools, and replace any interim placeholders (below) with faithful ports.
8. **Full-length validation** - the R5 evidence pack.

## Interim placeholders (the registry discipline)

Strict literalness has one pragmatic relaxation during bring-up: a complex scheme may be stood in for
by a simpler one (a lower-order scheme for a high-order one, until the surrounding machinery exists)
**only under all of these conditions**:

1. the placeholder is registered in the charter's placeholder table (what, where, why, the faithful
   target) the moment it is introduced;
2. it has a named closure milestone, and a phase cannot reach R5 sign-off with open placeholders
   affecting its physics;
3. when closed, the faithful port replaces it under the normal literalness rules, and the residual
   bias the placeholder caused is shown to disappear in the differential comparison (positive
   evidence that the tooling works).

An unregistered simplification is failure mode B1. The same discipline covers deferral markers: a
TODO, FIXME or HACK comment in TARGET code is an unregistered placeholder unless it carries a registry
ID and a closure milestone - register it or do the work now.

## Producer before consumer

When a phase or piece introduces a *reader* of a field or routine, find its *writer* in the port
first. If the producer is not ported (or, with several workers, not yet integrated), port the producer
first. An allocated-but-never-written field passes every differential comparison until a later phase
reads it (N3); this planning rule prevents the class instead of detecting it.

## Mechanical transforms are scripts

Any transformation the charter calls mechanical (index-base flips, storage-order conversion, cast
insertion, global-to-argument threading) is done by a reviewed script committed to `tools/`, not by
hundreds of hand edits. If you cannot script it, question whether it is mechanical; it may be a named
exception in disguise. Conformance rules (index helpers only, no raw vendor API in portable code,
exchange-region sizing) likewise become scripts in `tools/conformance/`, run in CI.

## Generate the TARGET build from the dependency graph, not the SOURCE build file

Derive each unit's dependencies from the SOURCE itself - its import and include statements, or the
compiler's dependency files - not from the SOURCE's hand-maintained build file. Such lists are often
incomplete: a missing edge is masked by the order files happen to be listed in, and the SOURCE builds
only because serial compilation stumbles on a workable order. Reuse the list and the TARGET build
breaks the moment anything reorders it; extract the real graph with a committed script in
`tools/scoping/` instead.

The generated TARGET build is itself a **reviewed deliverable**: it ships in the product and is proven
and reviewed like any piece. Seshat-Integrator never hand-writes build glue while landing a
multi-module deliverable (an unreviewed author); each reviewed piece lands in dependency order and the
product builds up from reviewed bytes only.

## Faithful rendering of SOURCE quirks (do not normalize)

The SOURCE is the specification. Some constructs look like obvious improvements to normalize away
but are preserved as written; dropping them is B1 in disguise.

- **A vestigial conditional whose branches have become identical** (one branch's distinctive code was
  commented out in the SOURCE) is preserved, not collapsed: collapsing removes the branch and can
  leave a condition-dependent variable unused. Silence a linter's identical-branches warning at that
  one site only, with a comment saying why the branches stay, as a charter named exception registered
  in `port/conventions/allowed-suppressions.yaml` (the silenced-detector check refuses it otherwise),
  and register the rendering in the divergence registry.
- **Code the SOURCE never executes in any configuration**, guarded by a compile-time constant that is
  false or a statically false condition, is rendered faithfully, not dropped: the port does not
  second-guess which configurations exist. It is not a proof-vacuity gap, since the SOURCE never runs
  it either; the reviewer accepts it as faithful dead code.
- **A dead store** - a local initialized and then overwritten on every path - keeps its literal
  initialization. Static analyzers flag it; turn off that analyzer sub-check project-wide as a charter
  named exception rather than per site. The R1 proof is the real defense against a store that is
  wrongly dead (it changes outputs and fails the proof).
