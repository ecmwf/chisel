# SEEDED-BUG DEMONSTRATION - conformance/check-depmap

- Date: 2026-06-16 (new detector, WS-J: the dependency map + confidence model; hardened to be
  conservative and schema-strict)
- Detector: tools/conformance/check-depmap.sh (wraps tools/coordination/extract_dependencies.py --check)
- Failure class targeted: the ready-set and the owned/leaf partition of a parallel port are
  computed from the SOURCE dependency map. Two distinct failures must be caught: (1) a committed
  map that DRIFTS from (or misrepresents) the SOURCE, and (2) the extractor itself silently
  calling a truly-coupled unit a clean leaf, which would dispatch it into parallel work and
  corrupt the shared line. The map is GENERATED from SOURCE; the extractor is CONSERVATIVE
  (anything it cannot fully analyze is marked `coverage: partial` and kept out of the self-serve
  pool); and the drift check regenerates from SOURCE and fails on any disagreement.
- Exit-code contract: 0 GREEN (committed map matches SOURCE, or there is none yet), 1 RED (drift
  or a malformed committed map), 2 UNRELIABLE (no python3 / PyYAML / git, a missing source root,
  or a structural SOURCE problem like a duplicate file stem).

The extractor is a line-based REFERENCE extractor for the Fortran->C pair. Every edge carries a
CONFIDENCE: proven (use/call/include resolved in-tree), suspected (an unresolved reference
`unresolved:NAME`, or a structural coupling `common:/blk/` / `include:NAME`); `unknown` is
reserved for a future human/charter overlay and is never auto-emitted. Each node carries
`self_serve_eligible` (true only when unowned, `coverage: full`, and free of suspected/unknown
coupling) with `guarded_reasons`. Shipped GOOD fixture: `tools/coordination/fixtures/depmap/`.

## What the extractor produces (the GOOD fixture)

Six nodes: `grid_mod` is `role: owned` (a module used by four other files) so not self-serve;
`bc` and `solver` are `unowned` but NOT self-serve (`guarded_reasons` include `suspected-coupling`
and `shared-surface:common:/state/`); `io_mod`, `main`, `util` are `self_serve_eligible: true`.
Two owned surfaces (`module:grid_mod` owner `grid_mod`; `common:/state/` owner `null`). Twelve
edges (use/call PROVEN; the `/state/` couplings and the unresolved `call ext_unknown` SUSPECTED).
`--owned-surfaces` prints `grid_mod.f90` plus the `/state/` participants `bc.f90`, `solver.f90`.

## Seeded defects and red proofs

### CONSERVATISM - the extractor must not invent a clean leaf

- **An unparsed construct -> guarded, not a clean leaf:** a file with `equivalence (a, b)` ->
  the node is emitted `coverage: partial`, `self_serve_eligible: false`,
  `guarded_reasons: [coverage-gap:equivalence]`. The same holds for `interface`, `external`,
  `procedure`/`=>`, `entry`, `&` continuation, a preprocessor `#` line, `;` multi-statement, and
  `include`. A coupled unit is therefore never silently waved into the self-serve pool.
- **Intrinsics are not false dependencies:** a file whose only calls are `call cpu_time(t)` and
  `call random_number(t)` produces NO edges and stays `self_serve_eligible: true` - the intrinsic
  allowlist keeps `cpu_time`/`random_number`/... from looking like external couplings.

### DRIFT - the committed map must equal the SOURCE projection

Mutating a scratch copy of the committed map, re-checked against the unchanged SOURCE -> RED, exit 1:
- drop the `solver -> bc` call edge -> `committed map DRIFTS from what SOURCE generates.`
- (a forged edge, a dropped/added node, or a changed role/eligibility/coverage are reported the
  same way, naming the offending node or edge.)

### SCHEMA - a malformed committed map is RED before drift is even compared

- an unknown top-level key (`manual_edges:`) -> `[FAIL] unknown top-level key 'manual_edges'`
- a missing required top-level key (`schema_version`, `source_root`, `nodes`, or `edges`
  absent or null) -> `[FAIL] missing required top-level key '<key>'` (a truncated or
  partially-written map is RED, not silently treated as an empty projection)
- an invalid `role` (`role: core`) -> `[FAIL] node 'bc' has invalid role 'core'`
- a dangling edge target -> `[FAIL] edge target 'ghost' is neither a node nor a typed surface`
- a duplicate node id -> `[FAIL] duplicate node id 'bc'`
- a committed map that is not a mapping, or that has a duplicate YAML key (strict loader) -> RED.

### WRONG TREE / STRUCTURE

- **source_root mismatch:** a committed map whose `source_root` is not the checked tree ->
  `committed source_root '...' does not match the checked tree '...'` -> RED. The wrapper pins
  `--source-root "$ROOT/source"`, so a map generated against another tree cannot pass GREEN.
- **duplicate file stem:** two SOURCE files with the same stem (`a/init.f90`, `b/init.f90`) ->
  exit 2, `duplicate file stem 'init' ... node ids must be unique` (fail closed, never a silently
  collapsed node).

## Green proof (defect removed)

- The shipped good fixture: GREEN, exit 0 - `committed map matches SOURCE (6 node(s), 12 edge(s))`,
  directly and through `check-depmap.sh` (whose pinned `--source-root` the fixture's trailing
  `--source-root` overrides).
- The base repo with no `tools/scoping/dependency-map.yaml`: GREEN, exit 0 -
  `no committed map ... nothing to check (skipping)`.

## Causal proof (the check is what catches it)

The committed map passes only when it is the data-normalized projection the extractor computes
from the current SOURCE - same nodes (id, source, role, self_serve_eligible, guarded_reasons,
coverage, provides), owned surfaces, and edges with the same confidence. Independently, a file
the extractor cannot fully parse is emitted guarded, so a unit is excluded from the leaf pool by
the extractor, not by a reviewer's memory. "The map is correct and the partition is safe"
therefore means "it equals the conservative extraction of SOURCE," never "someone drew it once."

## Scope / non-defect signals confirmed

- Conservatism is the safe direction: a parse the extractor cannot do yields a GUARDED node (a
  human looks), never a clean leaf. The reference extractor's documented blind spots (generics,
  fixed-form, function-reference calls, recursive include decks) therefore cannot produce a
  silent self-serve unit - at worst they over-guard.
- Determinism: nodes sorted by id, surfaces by name, edges by (from, to, kind, confidence); the
  comparison normalizes ordering and ignores `source_root` spelling, so reformatting the committed
  file does not flap and the same SOURCE always yields the same verdict.
- `unknown` confidence is reserved (never auto-emitted), so the exact drift comparison is correct
  for a purely-generated map; a future reviewed-overlay of human/charter `unknown` couplings is a
  separate layer, not a hand-edit of this generated file.
- Fail-closed UNRELIABLE (exit 2), distinct from RED: PyYAML absent, not a git repo, an explicit
  `--map` that is not a file, a `source_root` that is missing / not a directory, or a duplicate
  SOURCE file stem.

## Comparison-logic version

The logic is: `extract(source_root)` walks the Fortran tree, marks each file's coverage, builds
nodes (role owned iff a provided module has >= 2 external dependents; self_serve_eligible iff
unowned + full coverage + no suspected/unknown out-edge + no shared-surface), owned surfaces, and
edges (use/call/include resolved -> proven; unresolved/common/include -> suspected; intrinsics ->
no edge); `--check` strict-loads and schema-validates the committed map (required top-level keys
`schema_version`/`source_root`/`nodes`/`edges` present, no unknown keys, well-typed lists),
rejects a mismatched source_root, then compares a data-normalized view against the freshly
extracted one. Equal ->
GREEN, malformed/unequal -> RED, bad environment/structure -> UNRELIABLE. Re-run this
demonstration after any change to the extraction regexes, the coverage-gap set, the confidence
assignment, the owned-surface or self-serve derivation, the schema validation, or the comparison
(standing seeded-bug rule): every listed defect must go RED/exit 2 and the good fixture stay GREEN.
