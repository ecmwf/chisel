# SEEDED-BUG DEMONSTRATION - conformance/check-completeness

- Date: 2026-06-18 (new detector: TRACE completeness vs the SOURCE inventory)
- Detector: tools/conformance/check-completeness.sh (wraps tools/coordination/check_completeness.py)
- Failure class targeted: the drift check (check-trace-drift.sh) proves the canonical TRACE matches
  the fragments that EXIST - but it is blind to a fragment that is MISSING. Because TRACE is
  GENERATED from whatever fragments are present, a SOURCE unit with no fragment is simply absent
  from TRACE, and every other check stays green: a whole module can drop out of the trust
  accounting unnoticed. The dependency map (tools/scoping/dependency-map.yaml, itself drift-checked
  by check-depmap) is the canonical SOURCE inventory - one node per unit; this gate requires every
  map node to have a TRACE row and every TRACE row to be a real map node.
- Exit-code contract: 0 GREEN (every unit has a row and every row is a real unit, or nothing wired
  yet), 1 RED (a unit missing from TRACE, or a row with no unit), 2 UNRELIABLE (no PyYAML, malformed).

The map is the inventory; TRACE is generated from fragments. Committing the map is the signal the
inventory is known (Phase-0/1 scoping done); from then on TRACE must account for ALL of it. An
unstarted unit is `unmapped` (a row), never absent. Both the map and the generated TRACE must
exist to compare; before that there is nothing to check, so it skips.

## Seeded defects and red proofs (against the end-to-end scenario, restored after each)

The scenario is a complete inventory: 6 SOURCE units (grid_mod, io_mod, bc, solver, util, main),
6 TRACE rows (grid_mod gated, io_mod gated+integrated, util/bc/solver/main unmapped). So the gate
is GREEN on it.

- **A unit missing from TRACE (the silent drop):** delete `port/status/solver.yaml` and regenerate
  TRACE -> RED, exit 1: `[FAIL] SOURCE unit 'solver' (solver.f90) has no TRACE row - it is silently
  outside the trust accounting (give it a fragment, even status: unmapped)`. The drift check stays
  GREEN on the same state (TRACE still matches the remaining fragments) - only this gate catches it.
- **A TRACE row with no SOURCE unit (a phantom or stale map):** a fragment `id: ghost` for a source
  the map does not contain -> RED: `[FAIL] TRACE row 'ghost' has no SOURCE unit in the dependency
  map (a fragment for a unit the SOURCE does not have, or a stale map)`.

## Green proof (defect removed)

- The complete scenario inventory: GREEN, exit 0 - `6 SOURCE unit(s), 6 TRACE row(s); 0 gap(s)`.
  Restoring the dropped fragment (and regenerating TRACE) returns the gate to GREEN.
- The base repo with no committed dependency map: GREEN, exit 0 - `no dependency map yet (the
  SOURCE inventory is not committed) ... skipping`. The skip is ONLY for an absent map.
- **The half-wired state is RED, not a skip:** the dependency map exists (the inventory is known) but
  the generated TRACE is absent -> RED, exit 1: `the dependency map exists ... but the generated
  TRACE '...' is absent - every SOURCE unit is outside the trust accounting`. Skipping here would
  have let a known inventory go entirely unaccounted; only a truly-absent map (no inventory yet) skips.
- An `excluded` unit is NOT a gap: it still has a TRACE row (status: excluded), so it is counted
  as accounted-for; completeness is about a row EXISTING, not about the unit being ported.

## Scope / non-defect signals confirmed

- This gate composes with check-trace-drift, not duplicates it: drift proves TRACE == the fragments
  that exist; completeness proves the fragments cover the SOURCE inventory. Together they pin TRACE
  to both the fragments AND the SOURCE tree, so neither a hand-edit nor an omission slips through.
- Fail-closed UNRELIABLE (exit 2) distinct from RED: PyYAML absent, the map or TRACE not a mapping,
  or a malformed `nodes`/`files` shape. A truly-absent map or TRACE skips (exit 0), not a false pass.

## Comparison-logic version

The logic is: strict-load the dependency map and the generated TRACE; collect node ids (the SOURCE
inventory) and TRACE row ids; RED for every map id with no TRACE row (a silently-dropped unit) and
every TRACE id with no map node (a phantom row); GREEN when the two id sets are equal; skip when
either artifact is absent or the map has no nodes; UNRELIABLE on a malformed artifact. Re-run this
demonstration after any change to that join (standing seeded-bug rule): the missing-unit and
phantom-row defects must go RED and the complete scenario stay GREEN.
