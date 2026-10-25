# SEEDED-BUG DEMONSTRATION - conformance/check-depmap

- Date: 2026-06-16 (new detector: the dependency map + drift check); revised when the
 extractor was slimmed to the ROBUST core (inventory + proven edges + structural surfaces; no
 suspected/coverage-gap guessing and no overlay); revised again when INCLUDE and GENERATE edges
 were added (this record covers the underlying, project-agnostic mechanism only); revised again
 when a NONEMPTY-but-truncated tree - which the zero-file guard cannot see - gained its own
 independent guard (git-tracked cross-check); revised again when that guard's coverage was
 completed - it now checks the FULL discovered inventory (primary units AND include-discovered
 headers) against a REQUIRED nonempty git baseline, closing two remaining holes the round-1
 guard left open; revised again when the comparison became SET EQUALITY - the round-2 guard
 only checked `tracked - discovered` (git has a file the scan missed); the opposite direction,
 `discovered - tracked` (the scan found a file git does not track), was still open and is now
 its own distinct failure; revised again when the extractor gained macro-state awareness:
 a `USE`/`CALL`/`#include` textually present but inside a preprocessor conditional the pinned
 configuration compiles out no longer draws an edge - previously it did, unconditionally,
 which had left a number of live units permanently `blocked` on an `excluded` dependency
 (an excluded node never integrates). See the guarded-edges section below for the mechanism
 and the fail-closed contract for an undeterminable macro.
- Detector: tools/conformance/check-depmap.sh (wraps tools/coordination/extract_dependencies.py --check)
- Failure class targeted: the ready-set, the owned/leaf partition, and check-completeness's SOURCE
 inventory are all read from the committed dependency map (tools/scoping/dependency-map.yaml), so a
 committed map that has DRIFTED from SOURCE (a stale node/edge/surface, or a hand-edit) would route
 work against a wrong graph. The map is GENERATED from SOURCE; this check regenerates and fails on any
 disagreement, the same generate-and-drift-check guard the canonical TRACE uses.
- Exit-code contract: 0 GREEN (the committed map matches SOURCE, or there is none yet), 1 RED (drift,
 a malformed committed map, or a truncated/unverifiable source root - see below), 2 UNRELIABLE (no
 python3/PyYAML/git, or the source root is missing) - or, in PLAIN generation mode (no `--check`),
 the equivalent exit 2 for an empty/truncated/unverifiable root, since there is no committed map to
 produce a RED comparison against. Full detail: `the non-vacuity demonstration`.

The extractor emits ONLY what a line scan resolves unambiguously: the file INVENTORY (one node per
SOURCE unit, id = file stem; a `.fypp` code generator is walked the same as a `.F90` unit, and a
header is added when a `#include` from an already-known unit resolves to a real in-tree file), the
PROVEN in-tree use/call/include/generates edges, and the STRUCTURAL owned/shared surfaces (a module
OR a header USEd/#included by >= 2 units -> `role: owned`, `owned-foundation`; a common block shared
by >= 2 -> a `common:/blk/` owned surface with owner null and a `shared-surface:` guard on each
participant). A reference it cannot resolve in-tree draws NO edge and NO guard - it never invents a
"suspected" coupling, so there is nothing fragile to clear and no overlay. The ONE exception, by
design, is an explicit, project-committed `tools/scoping/generator-edges.yaml` entry (optional,
absent by default): a human-authored, cited assertion for the one coupling class a line scan
genuinely cannot resolve (a fypp-templated identifier) - a stale entry there fails the extractor
CLOSED rather than being silently dropped. `coverage` is always `full`.
`self_serve_eligible` is true iff a node is unowned and free of a shared-surface guard.

## Shipped GOOD fixture

`tools/coordination/fixtures/depmap/` - 7 SOURCE units (grid_mod, io_mod, bc, solver, util, main,
consts). `grid_mod` is USEd by >= 2 units (`role: owned`, `owned-foundation`); `bc` and `solver`
share the `common:/state/` block (`shared-surface:common:/state/`, `self_serve_eligible: false`);
`consts.h` is `#include`d by both `grid_mod.f90` and `util.f90` (`include:consts.h` owned surface,
same >= 2 threshold as a module - proves the INCLUDE edge class); io_mod, main are clean leaves.
GREEN:
```
python3 tools/coordination/extract_dependencies.py --check \
 --map tools/coordination/fixtures/depmap/dependency-map.yaml \
 --source-root tools/coordination/fixtures/depmap/source --generator-edges /dev/null
```
`committed map matches SOURCE (7 node(s), 12 edge(s)). RESULT: GREEN`. (`--generator-edges /dev/null`
is required only because, without an override, the extractor reads the project's own
`tools/scoping/generator-edges.yaml` when one exists, whose asserted nodes this small generic
fixture does not have, so it would fail closed exactly as designed. `--generator-edges` was added
alongside the pre-existing `--map`/`--source-root` overrides for exactly this reason: a fixture/test
tree unrelated to a real project's own generators must never be checked against that project's
assertions.)

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
- **A stale `generator-edges.yaml` entry** (naming a node the SOURCE inventory does not have): the
 extractor itself fails closed, exit 1 in `--check` mode / exit 2 in plain mode -
 `generator-edges entry '<a> -> <b>' names a node the SOURCE inventory does not have`. Full
 demonstration on the real project table: `the non-vacuity demonstration`.
- **A NONEMPTY but TRUNCATED source root** (direction A — `tracked - discovered`): a
 git-tracked SOURCE file removed from disk without `git rm` (still tracked, just missing from the
 working tree) -> the extractor itself fails closed, PLAIN generation included, no committed map
 required - `source root '...' is missing N git-tracked recognized source file(s) that this scan
 did not discover`. Holds for a missing PRIMARY unit (`.F90`/`.fypp`) AND a missing HEADER
 (`.h`/`.inc`) alike. A source root with no git
 history at all is refused outright - `source root '...' is not inside a git working tree` - and
 so is a source root inside git that tracks ZERO recognized files (an unverifiable, "could not
 determine" baseline, not proof of completeness) - `git tracks ZERO recognized source file(s)
 ... an empty baseline cannot distinguish a complete import from a truncated one`.
- **A DISCOVERED-but-UNTRACKED source root** (direction B — `discovered - tracked`): a real SOURCE file present on disk and walked/discovered by the
 extractor, but which git does NOT track -> fails closed with a DISTINCT message -
 `source root '...' has N recognized source file(s) this scan discovered that git does NOT track
 `. Reproduced against the actual historical file
 (`git rm --cached` leaving a tracked file untracked on disk): RED/exit-2/
 exit-1 across plain and `--check`, naming the untracked file exactly. This is what
 makes the comparison SET EQUALITY rather than one-way containment: `tracked - discovered` alone
 (round 2) could not have caught this, since the file is neither missing from git nor missing from disk — it is present on disk but absent from git, the opposite shape.
 Full demonstration, including the exact commands and restore steps for all five shapes:
 `the non-vacuity demonstration`.

## Green / skip proofs

- The GOOD fixture: GREEN, exit 0 - `7 node(s), 12 edge(s)`.
- The base repo with no `tools/scoping/dependency-map.yaml`: GREEN, exit 0 - `no committed map ...
 nothing to check (skipping)`. The skip is ONLY for an absent map (single-operator pilot / pre-scoping).
- A duplicate file STEM among the live SOURCE files fails the extractor (exit 2, fail-closed): node ids
 must be unique; sibling build variants are excluded coarsely in `tools/scoping/source-exclude.yaml`.
- An existing scan root that yields ZERO recognized source files (empty directory, or every file
 excluded) fails the extractor closed rather than emitting an empty-but-valid map - see
 `the non-vacuity demonstration`.
- A GOOD, complete tree (this fixture, or a real imported tree) is unaffected by the F-01
 bidirectional guard: `git ls-files` under it and the FULL discovered inventory (primary units
 plus headers) agree EXACTLY (both `tracked - discovered` and `discovered - tracked` are empty),
 so extraction proceeds normally - confirmed by the fixture's own GREEN above and by
 `check-depmap.sh` staying GREEN against a real imported tree
 throughout this revision (a fresh regeneration is byte-identical to the committed map). A
 freshly-imported, not-yet-`git add`-ed SOURCE is NO LONGER exempt as of the round-2 fix - `git
 add` is now a precondition for plain generation to succeed, matching the actual Phase-0 workflow.
- **Not duplicate of `check-live-tracked.sh`:** that check audits the already-COMMITTED map/TRACE
 against git POST-HOC (after the fact, only if run); this guard runs INSIDE `extract()` at
 GENERATION time, so a map built from a partially-untracked tree can never be written or committed
 in the first place - prevention at the source, not detection after. Both are kept: see
 `the non-vacuity demonstration`'s "Is this duplicate of check_live_tracked.py?"
 section for the full reasoning.

## Guarded-dead `USE`/`CALL`/`#include` edges (macro-state unit)

Summary (mechanism only; counts and per-project evidence omitted):

- **The defect:** the extractor read `USE`/`CALL`/`#include` textually with no knowledge of the
 preprocessor state the pinned configuration fixes, so a reference inside an `#ifdef` the pinned
 build compiles out still drew an edge. The guarded module is `status: excluded` in TRACE, so
 that edge kept its consumer permanently `blocked` (an excluded node never integrates). A number
 of live units carried at least one such edge before the fix.
- **The fix:** `extract_dependencies.py` now computes, per node, a tri-state (Kleene-logic)
 LIVENESS for every physical line from the pinned table (`tools/scoping/macro-state.yaml`,
 instantiated from `assets/macro-state.template.yaml`), using clang's raw lexer
 (`scan_guarded_macros.py`'s own `_parse_raw_tokens`/`_spans`/`_first_significant` -
 REUSED, not re-derived) to recognize directive structure, then folds nested `#if`/`#ifdef`/
 `#ifndef`/`#elif`/`#else`/`#endif` through it - an `#else` branch is correctly LIVE when its
 `#ifdef` is OFF (a representative guarded `CALL` pair with distinct branches for the
 feature-on/feature-off cases proved this needed real branch semantics, not merely "does the
 directive mention a pinned macro"). A macro not in the pinned table makes the line's
 liveness UNKNOWN, and the extractor refuses to emit (or drop) an edge whose line is
 UNKNOWN - fails closed, exit 2, naming the file/line/macro - never guessing either direction.
- **Result on the originating port's full tree:** node count unchanged, edge count reduced by a
 modest amount with no edges added, owned-surface count slightly reduced. All previously-blocked
 live units were confirmed to carry zero remaining edges into an `excluded` node. Exact counts
 are project-specific and omitted here; the mechanism is generic.
- **Adjacent, independently-justified fix found while building this:** a preprocessor directive
 line (`#define`, `#ifdef`, generator's `#:...`, ...) was never Fortran statement text, but the
 old scan applied `RE_CALL`/`RE_USE` to every raw line unconditionally - a header's `#define`
 whose replacement text contains `call ...` textually matched `RE_CALL`, asserting an edge from
 a macro DEFINITION's replacement text. Fixed by skipping every directive line from the
 USE/CALL/invoke scan (`#include` is unaffected - matched separately, by its own regex).
 Independent of guarding; both endpoints were already in the excluded set, so no scheduling
 effect, pure accuracy.
- **New CLI surface (test/fixture use only):** `--macro-state FILE` merges NAME -> `{value, reason}`
 entries on top of the pinned table (`tools/scoping/macro-state.yaml`), letting a fixture prove
 all three outcomes (OFF -> no edge, ON -> edge, undetermined -> UNRELIABLE) through the shipped
 CLI, not a bespoke test harness.

## Scope / non-defect signals confirmed

- The comparison normalizes ordering and ignores `source_root` spelling, so reformatting or reordering
 the committed map is NOT drift; only a real node/edge/surface change is.
- The extractor never emits `suspected`/`unknown` edges or `coverage-gap`/`suspected-coupling` guards:
 a reference it cannot resolve in-tree is simply absent from the map. The conservatism that guessing
 used to provide now comes from the real net - a unit wrongly worked in isolation fails its R1
 DIFFERENTIAL proof or the INDEPENDENT review. Re-run this demonstration after any change to the
 extraction regexes or the map shape (standing seeded-bug rule).
- **Independent finding, fixed while re-verifying this record (unrelated to the include-edge work):**
 the fixture's committed map was already missing a `call` edge for a bare FUNCTION invocation before any change in this sprint — reproduced against the unmodified extractor, same RED. A fixture with no automated replay can drift silently; re-demonstration is required on any change to the comparison logic, not a one-time proof.
