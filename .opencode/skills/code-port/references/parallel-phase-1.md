<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Parallel Phase 1 (building the tooling in parallel)

Phase 1 builds the comparison infrastructure - the differential harness, the proofs, the
conformance checks, the dependency-map extractor, the six diff-tool classes - before any
translation. At scale that build parallelizes on the coordination substrate
(`references/team-coordination.md`). It differs from parallel Phase 2 in three ways: the unit is a
**tooling component**, not a translated module; acceptance is **broader than one seeded proof**,
because every later wave trusts this tooling; and the work lands in the **workbench**, where the
tools live, not in the product.

Read with `references/differential-tooling.md` (the tool classes and design rules) and
`references/validation-ladder.md` (the tiers).

**Auto-mode.** `tools/coordination/phase1_drive.py` is the read-only planner that turns rules F0-F3
below into a per-unit plan, reading `port/phase1-plan.yaml` (scaffold it with
`tools/coordination/scaffold_phase1_plan.py`; template `assets/phase1-plan.template.yaml`).
`/port-autodrive` runs it at the charter's autonomy level (`references/auto-mode.md`, "Phase 1: the
tool-build driver").

**Shard the plan when several people author it.** One `port/phase1-plan.yaml` is a central registry:
sibling branches that each mark a different unit proven edit abutting stanzas, and git's three-way
merge can corrupt it with no conflict. Apply the TRACE fix (`team-coordination.md`): each unit's
stanza lives in its own `port/phase1/units/<id>.yaml` (template
`assets/phase1-unit-fragment.template.yaml`), the plan-wide values and unit order in
`port/phase1/_meta.yaml` (template `assets/phase1-meta.template.yaml`), and
`tools/coordination/generate_phase1_plan.py` generates the canonical plan, which `phase1_drive.py`
reads unchanged. `check-phase1-plan.sh` fails if the committed plan disagrees with the fragments and
skips until `port/phase1/units/` exists, so a small or serial Phase 1 may keep the single plan.

## F0. Prerequisite: a signed Phase 0

Do not fan out until Phase 0 is signed: the SOURCE imported at a pinned commit, the configuration
pinned, the live-subset method fixed, and the canonical reference run defined and archived
(`reference/runs.md`). The dependency-map extractor depends on that evidence; tooling built over an
unsigned Phase 0 is built against a moving target.

## F1. Layer 0 (near-serial): the differential harness first

Everything else compares through the differential harness, so it comes first: one small, owned
surface. Until Layer 0 is proven, the Layer-1 fan-out has nothing to validate against.

Layer 0 cannot validate itself through the harness, so it is accepted on its own terms: the SOURCE
built with instrumentation off reproduces the canonical reference outputs byte for byte (the
inertness rule in `differential-tooling.md`); dump and restore (or parse and compare) fixtures
round-trip; two identical SOURCE dumps compare green; a seeded corruption of a value, tag, record
order or count goes red, then green; the harness's dump format and comparison contract get an
independent review; and its enforcement-table row and evidence are recorded. Only then is the
Layer-1 pool opened.

## F2. Layer 1 (fan out in parallel)

Once Layer 0 is proven, the rest - the ladder proofs, the conformance checks, the dependency-map
extractor, the diff-tool classes - fans out exactly like parallel Phase 2: Ptah-Orchestrator
launches every unit whose `depends_on` and Layer 0 are integrated as parallel Kha-Workers in one
message, then their independent reviews, and authors none of them itself
(`parallel-phase-2.md`, "Parallel by default"). The substrate is the same - claims, isolated
worktrees, independent review, one land funnel - with one difference: Seshat-Integrator lands
tooling on the workbench (`integrate_land.sh`), then releases the unit's claim
(`release_claim.sh`) so it cannot linger into Phase 2. Tooling components are owned surfaces or
leaves: a shared harness API is owned, with a versioned contract; an independent conformance check
is a leaf.

Tool contracts follow producer before consumer: a component declares the contracts it provides and
consumes; a consumer may develop against a draft producer contract, but is not accepted, nor usable
as evidence by any wave, until that producer contract is F3-accepted. A later change to the
producer's contract marks its consumers stale (rebase and re-accept).

## F3. Acceptance per component is broader than a seed

A seeded red-then-green proof is necessary but not sufficient for tooling, because later waves rely
on it. Each Layer-1 component is accepted only with all of:

1. a current **seeded red-then-green** record (`/port-seed`), linked from its enforcement row;
   base-shipped conformance checks also keep a compact record under `tools/conformance/seeded-bugs/`;
2. a **SOURCE-side demonstration run**: it behaves correctly on the real SOURCE, not only a fixture;
3. **inertness or non-vacuity** evidence: a diff or probe tool is inert on results when off
   (`differential-tooling.md`); a check exercises its enumerated target set (at least one in-scope
   file, routine, path or record where a hit is expected), fails closed on a missing scan root, and
   says "not applicable" explicitly rather than reporting green on an empty scan;
4. an **independent review of the tool itself**, in a session (or by a person) other than its author;
5. its **enforcement row** set to ENFORCED in the same change: in `tools/README.md` for a generic
   tool, or in the README of the port's own tool folder (`tools/proofs/README.md`, ...), which a
   sync keeps.

Until a component meets all five, no later wave depends on it.

## F4. Parallel read-only exploration feeds the map

Use read-only exploration agents in parallel for the analysis-heavy work - live-subset
determination, call-graph and coupling analysis - which changes no state and needs no claim. Their
output is the **dependency map** (the file inventory, the proven in-tree edges, the structural
surfaces that keep a unit out of the leaf pool) and the **parallelizability and owned-surface
assessment** that parallel Phase 2 consumes (`parallel-phase-2.md`).

## Done-when

Layer 0 is proven; each Layer-1 component meets F3 and has landed on the workbench; and the
dependency map and the parallelizability assessment exist and are reviewed by the human, ready for
Phase 2.
