# SEEDED-BUG DEMONSTRATION - conformance/check-completeness

- Date: 2026-06-18 (new detector: TRACE completeness vs the SOURCE inventory)
- Detector: tools/conformance/check-completeness.sh (wraps tools/coordination/check_completeness.py)
- Failure class targeted: the drift check (check-trace-drift.sh) proves the canonical TRACE matches
  the fragments that EXIST - but it is blind to a fragment that is MISSING. Because TRACE is
  GENERATED from whatever fragments are present, a SOURCE unit with no fragment is simply absent
  from TRACE, and every other check stays green: a whole module can drop out of the trust
  accounting unnoticed. The dependency map (tools/scoping/dependency-map.yaml, itself drift-checked
  by check-depmap) is the canonical SOURCE inventory - one node per unit; this check requires every
  map node to have a TRACE row and every TRACE row to be a real map node.
- Exit-code contract: 0 GREEN (every unit has a row and every row is a real unit OR a valid declared
  assembly, or nothing wired yet), 1 RED (a unit missing from TRACE, or a row with no unit / no valid
  declared assembly), 2 UNRELIABLE (no PyYAML, malformed map/TRACE/assemblies registry).

The map is the inventory; TRACE is generated from fragments. Committing the map is the signal the
inventory is known (Phase-0/1 scoping done); from then on TRACE must account for ALL of it. An
unstarted unit is `unmapped` (a row), never absent. Both the map and the generated TRACE must
exist to compare; before that there is nothing to check, so it skips.

## Seeded defects and red proofs (against the end-to-end scenario, restored after each)

The scenario is a complete inventory: 6 SOURCE units (grid_mod, io_mod, bc, solver, util, main),
6 TRACE rows (grid_mod proven, io_mod proven+integrated, util/bc/solver/main unmapped). So the proof
is GREEN on it.

- **A unit missing from TRACE (the silent drop):** delete `port/status/solver.yaml` and regenerate
  TRACE -> RED, exit 1: `[FAIL] SOURCE unit 'solver' (solver.f90) has no TRACE row - it is silently
  outside the trust accounting (give it a fragment, even status: unmapped)`. The drift check stays
  GREEN on the same state (TRACE still matches the remaining fragments) - only this check catches it.
- **A TRACE row with no SOURCE unit (a phantom or stale map):** a fragment `id: ghost` for a source
  the map does not contain -> RED: `[FAIL] TRACE row 'ghost' has no SOURCE unit in the dependency
  map (a fragment for a unit the SOURCE does not have, or a stale map)`.

## Assembly-proven rows (the narrow reverse-direction exemption)

An ASSEMBLY-PROVEN deliverable is a proven TRACE row with NO single SOURCE unit (it composes already-proven
member units, validated by one assembly-level differential). So the reverse direction ("every TRACE row is
a SOURCE node") would reject it and `integrate_assembly.sh` would fail-close - no assembly could ever land.
A declared assembly in `tools/scoping/assemblies.yaml` (project layer, like the dependency map) is exempted
from the reverse direction ONLY when every declared member is a real map node. The forward direction
("every SOURCE unit has a row") is untouched, so nothing weakens. Verified against a 2-unit map
(alpha, beta) whose TRACE adds a `bundle` row:

- **Valid assembly is GREEN:** `assemblies.yaml` declares `bundle` with members `[alpha, beta]` ->
  GREEN, exit 0: `2 SOURCE unit(s), 3 TRACE row(s); 1 declared assembly row(s) accepted; 0 gap(s)`.
- **Fake-member assembly is RED:** members `[alpha, ghost]` (ghost not a map node) -> RED, exit 1:
  `[FAIL] TRACE row 'bundle' is a declared assembly, but member(s) 'ghost' are not SOURCE units ... -
  assembly exemption refused`. A non-node row cannot smuggle a phantom unit via fake membership.
- **Empty-member assembly is RED:** members `[]` -> RED, exit 1: `... declared as an assembly but has an
  empty members list ... a real assembly must compose real SOURCE units`.
- **Phantom row with NO registry is RED (unchanged):** `bundle` in TRACE, no `assemblies.yaml` -> RED,
  exit 1 (the original phantom-row defect): a non-node row is only ever accepted when DECLARED.
- **A dropped real unit stays RED even WITH a valid assembly (forward direction preserved):** TRACE
  missing `beta` while `bundle` is a valid declared assembly -> RED, exit 1 - the assembly exemption
  never masks a vanished SOURCE unit.
- **A malformed registry is UNRELIABLE (exit 2), not a false pass:** `assemblies: not-a-list` (or a
  non-mapping entry, duplicate id, non-string/empty member) -> exit 2. A truly ABSENT registry means "no
  assemblies declared" (behaviour unchanged) and skips that exemption.

## Green proof (defect removed)

- The complete scenario inventory: GREEN, exit 0 - `6 SOURCE unit(s), 6 TRACE row(s); 0 declared
  assembly row(s) accepted; 0 gap(s)`. Restoring the dropped fragment (and regenerating TRACE) returns
  the proof to GREEN.
- The base repo with no committed dependency map: GREEN, exit 0 - `no dependency map yet (the
  SOURCE inventory is not committed) ... skipping`. The skip is ONLY for an absent map.
- **The half-wired state is RED, not a skip:** the dependency map exists (the inventory is known) but
  the generated TRACE is absent -> RED, exit 1: `the dependency map exists ... but the generated
  TRACE '...' is absent - every SOURCE unit is outside the trust accounting`. Skipping here would
  have let a known inventory go entirely unaccounted; only a truly-absent map (no inventory yet) skips.
- An `excluded` unit is NOT a gap: it still has a TRACE row (status: excluded), so it is counted
  as accounted-for; completeness is about a row EXISTING, not about the unit being ported.

## Scope / non-defect signals confirmed

- This check composes with check-trace-drift, not duplicates it: drift proves TRACE == the fragments
  that exist; completeness proves the fragments cover the SOURCE inventory. Together they pin TRACE
  to both the fragments AND the SOURCE tree, so neither a hand-edit nor an omission slips through.
- Fail-closed UNRELIABLE (exit 2) distinct from RED: PyYAML absent, the map or TRACE not a mapping,
  or a malformed `nodes`/`files` shape. A truly-absent map or TRACE skips (exit 0), not a false pass.

## Comparison-logic version

The logic is: strict-load the dependency map, the generated TRACE, and the optional assemblies registry;
collect node ids (the SOURCE inventory) and TRACE row ids; RED for every map id with no TRACE row (a
silently-dropped unit) and every TRACE id with no map node UNLESS it is a declared assembly all of whose
members are real map nodes (the narrow exemption); GREEN when every map id has a row and every extra row
is a valid declared assembly; skip when the map or TRACE is absent or the map has no nodes (an absent
assemblies registry just means none declared); UNRELIABLE on a malformed artifact. Re-run this
demonstration after any change to that join (standing seeded-bug rule): the missing-unit, phantom-row,
fake-member-assembly, and empty-member-assembly defects must go RED and the complete scenario (and a
valid declared assembly) stay GREEN.
