# SEEDED-BUG DEMONSTRATION - conformance/check-depmap

- Date: 2026-06-16 (new detector, WS-J: the dependency map + drift check); revised when the
  extractor was slimmed to the ROBUST core (inventory + proven edges + structural surfaces; no
  suspected/coverage-gap guessing and no overlay).
- Detector: tools/conformance/check-depmap.sh (wraps tools/coordination/extract_dependencies.py --check)
- Failure class targeted: the ready-set, the owned/leaf partition, and check-completeness's SOURCE
  inventory are all read from the committed dependency map (tools/scoping/dependency-map.yaml), so a
  committed map that has DRIFTED from SOURCE (a stale node/edge/surface, or a hand-edit) would route
  work against a wrong graph. The map is GENERATED from SOURCE; this check regenerates and fails on any
  disagreement, the same generate-and-drift-check guard the canonical TRACE uses.
- Exit-code contract: 0 GREEN (the committed map matches SOURCE, or there is none yet), 1 RED (drift
  or a malformed committed map), 2 UNRELIABLE (no python3/PyYAML/git, or the source root is missing).

The extractor emits ONLY what a line scan resolves unambiguously: the file INVENTORY (one node per
SOURCE unit, id = file stem), the PROVEN in-tree use/call edges, and the STRUCTURAL owned/shared
surfaces (a module USEd by >= 2 units -> `role: owned`, `owned-foundation`; a common block shared by
>= 2 -> a `common:/blk/` owned surface with owner null and a `shared-surface:` guard on each
participant). A reference it cannot resolve in-tree draws NO edge and NO guard - it never invents a
"suspected" coupling, so there is nothing fragile to clear and no overlay. `coverage` is always
`full`. `self_serve_eligible` is true iff a node is unowned and free of a shared-surface guard.

## Shipped GOOD fixture

`tools/coordination/fixtures/depmap/` - 6 SOURCE units (grid_mod, io_mod, bc, solver, util, main).
`grid_mod` is USEd by >= 2 units (`role: owned`, `owned-foundation`); `bc` and `solver` share the
`common:/state/` block (`shared-surface:common:/state/`, `self_serve_eligible: false`); io_mod, util,
main are clean leaves. GREEN: `committed map matches SOURCE (6 node(s), 9 edge(s)). RESULT: GREEN`.

## Seeded defects and red proofs (against the GOOD fixture, restored after each)

- **Edge drift (a stale committed map):** remove one proven edge from the committed map -> RED, exit 1:
  `committed map DRIFTS from what SOURCE generates. edge ('bc', 'grid_mod', 'use', 'proven') is in
  SOURCE but not the committed map.` The reverse (an edge in the committed map not in SOURCE) is caught
  the same way.
- **Node drift:** a committed map missing a SOURCE node (or carrying one the SOURCE does not have) ->
  RED (`node '<id>' is in SOURCE but not the committed map`, or a dangling edge target if a referenced
  node was removed).
- **Malformed committed map:** an invalid `role` (not owned/unowned), an invalid edge `confidence`, a
  missing required top-level key, or a duplicate node id -> RED, exit 1, e.g.
  `[FAIL] node 'util' has invalid role 'bogus'`.
- **source_root mismatch:** a committed map whose `source_root` is not the checked tree -> RED
  (`committed source_root '...' does not match the checked tree '...'`). The wrapper pins
  `--source-root "$ROOT/source"`, so a map generated against another tree cannot pass GREEN.

## Green / skip proofs

- The GOOD fixture: GREEN, exit 0 - `6 node(s), 9 edge(s)`.
- The base repo with no `tools/scoping/dependency-map.yaml`: GREEN, exit 0 - `no committed map ...
  nothing to check (skipping)`. The skip is ONLY for an absent map (single-operator pilot / pre-scoping).
- A duplicate file STEM among the live SOURCE files fails the extractor (exit 2, fail-closed): node ids
  must be unique; sibling build variants are excluded coarsely in `tools/scoping/source-exclude.yaml`.

## Scope / non-defect signals confirmed

- The comparison normalizes ordering and ignores `source_root` spelling, so reformatting or reordering
  the committed map is NOT drift; only a real node/edge/surface change is.
- The extractor never emits `suspected`/`unknown` edges or `coverage-gap`/`suspected-coupling` guards:
  a reference it cannot resolve in-tree is simply absent from the map. The conservatism that guessing
  used to provide now comes from the real net - a unit wrongly worked in isolation fails its R1
  DIFFERENTIAL gate or the INDEPENDENT review. Re-run this demonstration after any change to the
  extraction regexes or the map shape (standing seeded-bug rule).
