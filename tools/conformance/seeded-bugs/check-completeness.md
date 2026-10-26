# SEEDED-BUG DEMONSTRATION - conformance/check-completeness

- Date: 2026-06-18 (new detector: TRACE completeness vs the SOURCE inventory); revised 2026-10-26:
  duplicates are RED, each row is bound to its unit's map `source`, and a row without an `id` (the
  hand-written TRACE template's shape) is identified by its `source`
- Detector: tools/conformance/check-completeness.sh (wraps tools/coordination/check_completeness.py)
- Failure class targeted: the drift check (check-trace-drift.sh) proves the canonical TRACE matches
  the fragments that EXIST - but it is blind to a fragment that is MISSING. Because TRACE is
  GENERATED from whatever fragments are present, a SOURCE unit with no fragment is simply absent
  from TRACE, and every other check stays green: a whole module can drop out of the trust
  accounting unnoticed. The dependency map (tools/scoping/dependency-map.yaml, itself drift-checked
  by check-depmap) is the canonical SOURCE inventory - one node per unit; this check requires every
  map node to have a TRACE row and every TRACE row to be a real map node.
- Exit-code contract: 0 GREEN (every unit has exactly one row, bound to its map node's source, and
  every row is a real unit OR a valid declared assembly, or nothing wired yet), 1 RED (a unit missing
  from TRACE, a row with no unit / no valid declared assembly - including a row without an `id`
  whose `source` names no map node, or with neither, a unit claimed by two TRACE rows or an id
  carried by two map nodes, two map nodes naming one source or a map node with none, or a row whose
  `id` is a unit but whose `source` differs from that unit's map node), 2 UNRELIABLE (no PyYAML, malformed map/TRACE/assemblies registry).

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

## Duplicate ids (replayed by tools/tests/test-check-completeness.sh)

The join is one row per unit, but it used to compare SETS of ids, so a duplicate was collapsed
silently. A bad merge or a hand edit that duplicates a TRACE row leaves two rows that can disagree
(one `proven`, one `in-progress`) while the census stays green. The drift check sees a duplicated
row only when fragments exist (it compares the committed rows to the generated ones); a
hand-maintained TRACE has no fragments, so nothing else caught it. Verified against a 2-unit map
(alpha, beta):

- **A duplicated TRACE id is RED:** TRACE rows `alpha, alpha, beta` -> RED, exit 1: `[FAIL] TRACE
  has 2 rows for unit 'alpha' - one unit has exactly one entry; ...`. Before the fix: GREEN, exit 0
  (`2 SOURCE unit(s), 2 TRACE row(s); ... 0 gap(s)`).
- **A duplicated map id is RED:** map nodes `alpha, beta, beta` -> RED, exit 1: `[FAIL] dependency
  map has 2 nodes with id 'beta' ...`. Before the fix: GREEN, exit 0. (The extractor refuses a
  duplicate stem, so this is a hand-edited map; check-depmap also flags the edit as drift.)
- **Unaffected:** the complete 2-unit TRACE and a valid declared assembly row stay GREEN.

## Rows bound to their unit's file (replayed by tools/tests/test-check-completeness.sh)

The join used to compare ids only. The id is the file stem, so a row that keeps one unit's id while
its `source` names another file - a relabelled or copy-pasted row - counted the unit as accounted for
while no row described its file. A unit's row must now name exactly the path its map node names (the
map's sources are canonical relative paths; check-live-tracked rejects any other spelling). Verified against the map `alpha -> alpha.f90`, `beta -> sub/beta.f90`:

- **A row relabelled onto another unit's file is RED:** row `alpha` with `source: sub/beta.f90` ->
  RED, exit 1: `[FAIL] TRACE row 'alpha' source 'sub/beta.f90' does not match the canonical map
  source 'alpha.f90' - ...`. Before the fix: GREEN, exit 0.
- **A row naming a file that is no unit's is RED:** row `alpha` with `source: alpha_old.f90` -> RED,
  exit 1. Before the fix: GREEN, exit 0.
- **A unit's row with no `source` is RED:** row `alpha` with no `source` key -> RED, exit 1. Before
  the fix: GREEN, exit 0.
- **Another spelling of the right file is RED:** row `alpha` with `source: ./alpha.f90` -> RED.
- **The map itself is one file per unit:** two nodes naming `alpha.f90`, or a node with no `source`
  -> RED, exit 1.
- **Unaffected:** a declared assembly row is not a map node and is not bound, so it stays GREEN
  whatever `source` it names.

## Rows without an `id` (replayed by tools/tests/test-check-completeness.sh)

Generated rows carry an `id`; the hand-written TRACE template's rows do not - they are keyed by
`source`. The check used to collect identity from `id` only, so a complete TRACE in the template's
shape counted 0 rows and reported every unit missing (a false RED), and an id-less row could neither
be duplicated nor bound. A row without an `id` is now the unit whose map node names its `source`;
one whose `source` names no map node, or that has neither an `id` nor a `source`, is a row with no
SOURCE unit. The test instantiates the template file itself (its two placeholder sources replaced,
nothing else changed) against the same map:

- **A complete template-shaped TRACE is GREEN:** rows `alpha.f90`, `sub/beta.f90` -> GREEN, exit 0.
  Before the fix: RED, exit 1 (`0 TRACE row(s)`, both units missing). The same holds with a declared
  assembly row (which has an `id`) added beside the id-less rows.
- **Two rows for one unit are RED:** rows `alpha.f90`, `alpha.f90` -> RED, exit 1: `[FAIL] TRACE has
  2 rows for unit 'alpha' ...`. Likewise an id-less `alpha.f90` row plus a row `id: alpha`. Before the
  fix: RED only because every unit looked missing - the duplicate itself was not reported.
- **A row naming no unit's file is RED:** rows `alpha.f90`, `gone.f90` -> RED, exit 1: `[FAIL] TRACE
  row #2 has no id and its source 'gone.f90' is no SOURCE unit in the dependency map ...`.
- **A row with neither an `id` nor a `source` is RED:** beside two complete rows -> RED, exit 1:
  `[FAIL] TRACE row #3 has neither an id nor a source ...`. Before the fix: GREEN, exit 0 (the row
  was skipped).

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

The logic is: strict-load the dependency map, the generated TRACE, and the optional assemblies
registry; collect node ids (the SOURCE inventory); identify each TRACE row by its `id`, or, for a row
without one, by the map node whose `source` equals the row's; RED for a row without an `id`
that matches no map node or has no `source`; RED for every row whose `id` is a map id but whose
`source` differs from that node's; RED for every unit claimed by more than one row, every id carried by
more than one map node, every source named by more than one map node, and every map node with no
`source`; RED for every map id with no TRACE row (a silently-dropped unit)
and every TRACE id with no map node UNLESS it is a declared assembly all of whose members are real map
nodes (the narrow exemption); GREEN when every map id has exactly one row and every extra row is a
valid declared assembly; skip when the map or TRACE is absent or the map has no nodes (an absent
assemblies registry just means none declared); UNRELIABLE on a malformed artifact. Re-run this
demonstration after any change to that join (standing seeded-bug rule): the missing-unit, phantom-row,
id-less-phantom-row, duplicate-row, relabelled-row, fake-member-assembly, and empty-member-assembly
defects must go RED and the complete scenario (generated and template-shaped, and a valid declared
assembly) stay GREEN.
