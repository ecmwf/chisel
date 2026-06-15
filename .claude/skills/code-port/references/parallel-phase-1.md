# Parallel Phase 1 (building the tooling with many explorations)

Phase 1 builds the comparison infrastructure - the differential harness, the gates, the
conformance checks, the dependency-map extractor, the six diff-tool classes - before any
translation. At scale that build itself parallelizes, on the WS-E0 coordination
substrate (`references/team-coordination.md`). The difference from parallel Phase 2: the
unit is a **tooling component**, not a translated module; acceptance is **broader than a
single seeded proof**, because every later wave *trusts* this tooling; and the work lands
in the **workbench**, not the product (tools live in the workbench).

Read with `references/differential-tooling.md` (the six tool classes + design rules),
`references/validation-ladder.md` (tiers), and `references/team-coordination.md` (the
claims/fragments/integrator substrate this reuses).

## F0. Prerequisite: a signed Phase 0

Do not fan out until Phase 0 is human-signed: the SOURCE is imported at a pinned commit,
the configuration is pinned, the live-subset method is fixed, and the canonical reference
run is defined and archived (`reference/runs.md`). The dependency-map extractor (F2/F4)
depends on that live-subset and configuration evidence; a fan-out over an unsigned Phase
0 builds tooling against a moving target.

## F1. Layer 0 (near-serial): the differential harness first

Everything else compares *through* the differential harness against the reference run,
so it comes first and nearly serial - one small, owned surface. Until Layer 0 is gated,
the Layer-1 fan-out has nothing to validate against. Gate Layer 0 before opening the pool.

## F2. Layer 1 (fan out in parallel)

Once Layer 0 is gated, the rest is largely independent and fans out: the ladder gates,
the conformance checks, the dependency-map extractor, and the six diff-tool classes. This
reuses the WS-E0 substrate unchanged - atomic claims, ephemeral `.worktrees/`,
per-component PRs, independent review, the integrator queue - with one placement
difference: **the integrator merges tooling into the workbench** (the product is not
involved in Phase 1). Tooling components are themselves owned surfaces or leaves: a
shared harness API is owned (versioned contract); an independent conformance check is a
leaf.

## F3. Acceptance per component is broader than a seed

A seeded red->green proof is necessary but **not sufficient** for tooling, because later
waves rely on it. Each Layer-1 component is accepted only with ALL of:

1. a **seeded red->green** record (`tools/conformance/seeded-bugs/`) - the detector fires;
2. a **source-side demonstration run** - it behaves correctly on the real SOURCE, not
   only on a fixture;
3. **inertness / non-vacuity** evidence where applicable - a diff/probe tool is byte-inert
   when off (the results-inertness guarantee in `differential-tooling.md`), and a check is
   non-vacuous (it actually exercises its target, not a trivially-empty scan);
4. an **independent review of the tool itself** (separate session/person from its author);
5. its **`tools/README.md` enforcement-table row** updated to ENFORCED in the same change.

Until a component meets all five, downstream waves must not depend on it.

## F4. Parallel read-only exploration feeds the map

Use read-only `explore`-style agents in parallel for the analysis-heavy parts -
live-subset determination and call-graph / coupling analysis - that do not mutate state
and so need no claim. Their output is the **confidence-labeled dependency map** (edges
proven / suspected / unknown; unknown stays guarded, out of the leaf pool) and the
**parallelizability + owned-surface assessment** that parallel Phase 2 consumes
(`references/team-coordination.md`: the topology is a hypothesis to test, not assume).

## Done-when

Layer 0 is gated; each Layer-1 component meets the F3 acceptance and is merged into the
workbench in parallel; and the confidence-labeled dependency map and the
parallelizability assessment exist and are human-reviewed - ready for Phase 2.

> Execution note: this is a protocol for a live, multi-contributor Phase 1; it runs on a
> real signed Phase 0 with the WS-E0 operational machinery (generator, dashboard,
> integrator) in place. The methodology (this protocol + the substrate + the per-tool
> acceptance ladder) lands on the branch; the run itself is per-project.
