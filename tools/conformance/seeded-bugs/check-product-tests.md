# SEEDED-BUG DEMONSTRATION - conformance/check-product-tests

- Date: 2026-06-16 (new detector: the port's tests are product-owned)
- Detector: tools/conformance/check-product-tests.sh
- Failure class targeted: tests that do not ship with the product. The v1 orphan pattern
  was test sources authored into the WORKBENCH (a top-level `tests/unit/`) with the
  product build reaching OUT to find them (`TESTDIR := ../tests/unit` in
  `target/Makefile`). That cross-boundary reference does not even resolve once the product
  is its own repo (references/two-repo-architecture.md), so the regression net never ships
  with the deliverable. Tests belong under `PRODUCT_ROOT/tests/` (drivers + fixtures),
  built by the product itself; the fixture GENERATOR (it instruments the SOURCE) stays in
  the workbench under `tools/diff/`.
- Exit-code contract: 0 GREEN (tests product-owned, no workbench orphans, every shipped test wired
  into the build), 1 RED (an escaping product build reference, a workbench `tests/` orphan, or a
  shipped-but-unwired test source), 2 UNRELIABLE (no tooling, or product wired but its checkout is missing).

The detector has three arms. Product tree = `PRODUCT_ROOT`, resolved via `lib/product-root.sh`
(the product checkout in `port/product.yaml`, else `target/`); `--product-root <dir>` scans
a given tree (used by the fixtures below). Each arm is demonstrated INDEPENDENTLY so a
fixture that goes red proves the arm under test, not the other.

- **Arm 1 - product build escapes the product for test sources.** Each product build file
  (`Makefile` / `GNUmakefile` / `*.mk` / `CMakeLists.txt` / `*.cmake`) is scanned for a
  `..`-escaping path token that names a test; the token is resolved (`realpath -m`) against
  the build file's directory and must stay under `PRODUCT_ROOT`. Runs only when a product
  tree is present.
- **Arm 2 - workbench holds an orphaned top-level `tests/`.** A `tests/` at the workbench
  root containing test sources is the v1 orphan location. Always runs (a workbench
  invariant, meaningful even before a product is wired).
- **Arm 3 - a shipped product test source is not wired into the build.** A `test*`-named
  source under `PRODUCT_ROOT/tests/` whose stem is referenced by NO product build file is a
  shipped-but-unbuilt test: a fresh clone's `ctest` never runs it. Runs only with a product
  present and a `tests/`; SKIPPED when any build file uses `GLOB`/`wildcard` (the glob
  enumerates tests at configure time, so a shipped test cannot be silently unregistered). It
  deliberately does NOT try to detect a test that was never composed at all - there is no
  mechanical source of truth for "which tests should exist"; that gap is owned by the
  assembly integration review and the DONE clone-build-run check (a clone must run a test
  per ported unit, not 1).

## Seeded defects and per-arm red proofs

Reproduce: `bash /tmp/opencode/check_product_tests_seed.sh` (the demonstration harness;
fixtures are built in throwaway git repos). Observed:

- **Arm 1 RED - escaping build reference:** a product subdir `prod/` whose `Makefile` has
  `TESTDIR := ../tests/unit` -> RED, exit 1, one FAIL:
  `prod/Makefile: build references test sources outside the product ('../tests/unit' -> .../tests/unit)`.
  The `..` resolves above the product root, so the test source is not part of the
  deliverable.
- **Arm 2 RED - workbench orphan:** a workbench with a top-level
  `tests/unit/foo_capture_replay_test.c` and a clean product -> RED, exit 1, one FAIL:
  `workbench has a top-level tests/ holding 1 product test source(s)` (the offending paths
  are listed). Arm 1 stays silent (the product build does not escape), proving arm
  isolation.
- **Arm 3 RED - shipped test not wired:** a product whose `tests/` holds `test_foo.c` AND
  `test_bar.c` but whose `CMakeLists.txt` only `add_executable(test_foo tests/test_foo.c)` ->
  RED, exit 1, one FAIL: `product test source 'tests/test_bar.c' is referenced by NO product
  build file - a shipped test that never builds/runs`. Wiring `test_bar` too returns it to GREEN.

## Green proof (defect removed)

- **Arm 1 GREEN:** the same product with `tests/unit/` INSIDE it and `TESTDIR := tests/unit`
  (no `..`) -> GREEN, exit 0.
- **Arm 2 GREEN:** no top-level `tests/` in the workbench; the product owns
  `target/tests/unit/` -> GREEN, exit 0.
- **Arm 3 GREEN:** every `test*` source under the product's `tests/` is referenced by a build
  file (or the build GLOBs the tests dir, which skips the arm) -> GREEN, exit 0.
- **Base/unwired GREEN:** run in the methodology base repo (no `port/product.yaml`, no
  `target/`, no top-level `tests/`): Arm 1 skips (no product wired), Arm 2 is clean, Arm 3 skips
  (no product/tests) -> GREEN, exit 0. This is the canonical clean baseline the full conformance suite runs.

## Fail-closed (UNRELIABLE) proof

- A workbench whose `port/product.yaml` wires a product whose checkout is ABSENT -> exit 2
  UNRELIABLE, not a skip-green: once a product is declared, a check that cannot reach it
  must not pass by default (same fail-closed rule as check-product-invisibility).

## Real-world replay (the actual v1 bug)

Pointed at the v1 warmup port (`project-chisel-warmup`), the detector flags BOTH the real
defects at once: `target/Makefile`'s `TESTDIR := ../tests/unit` escape AND the 32 orphaned
capture-replay tests under the workbench `tests/unit/`. RED, exit 1, 2 findings. This is the
exact situation the convention now prevents.

## Scope / non-defect signals confirmed

- A product build that references its OWN tests relatively (`tests/unit`, no `..`) is not
  flagged - product-owned tests are the goal, not a defect.
- Only `..` tokens that NAME a test are considered, so ordinary parent-relative build flags
  (e.g. `-I../include` for a sibling product dir) do not false-positive.
- Arm 2 looks at the workbench's top-level `tests/` only; the methodology's own tests live
  under `tools/conformance/` and are never flagged.
- A missing product tree (no product wired) skips Arm 1 with a note; Arm 2 still runs.

## Comparison-logic version

The comparison logic is: (Arm 1) `grep -oE '\.\./[^[:space:]:=)(]*'` over product build
files, filtered to tokens matching `test`, each resolved with `realpath -m` and required to
stay under `PRODUCT_ROOT`; (Arm 2) `find "$ROOT/tests"` for test-source files; (Arm 3) for each
`test*` source under `PRODUCT_ROOT/tests/`, require its stem to appear (fixed-string) in some
product build file, unless any build file uses `GLOB`/`wildcard`. Re-run this demonstration after
any change to the arms or the build-file/extension lists (standing seeded-bug rule): an escaping
`../tests` product build reference, a workbench top-level `tests/` of sources, and a shipped
product test source wired into NO build file must each go RED, and a product that owns AND builds
its `tests/` must stay GREEN.
