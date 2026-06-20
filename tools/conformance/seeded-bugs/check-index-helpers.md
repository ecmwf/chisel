# SEEDED-BUG DEMONSTRATION - conformance/check-index-helpers

- Date: 2026-06-19 (re-seeded after the `idx0`/`idxlb` whitelist-expansion comparison-logic change)
- Detector: tools/conformance/check-index-helpers.sh
- Failure class targeted: ad-hoc index arithmetic. A multi-dimensional or base-shifted
  TARGET array access that does NOT go through a central index helper (CONVENTIONS section 6
  / the charter index-base + storage-order transforms). A hand-written `a[i*nx + j]` silently
  reintroduces the storage-order/index-base assumptions the helpers exist to localize.
- Exit-code contract: 0 GREEN (all subscripts use the idiom), 1 RED (an ad-hoc subscript),
  2 UNRELIABLE (could not run).

The detector scans TARGET `*.c`/`*.h`, extracts every `[...]` subscript, and flags any that
is neither a numeric literal nor a whitelisted helper call. The whitelist is the comparison
logic; this change adds `idx0(...)` and `idxlb(...)` (the lower-bound-0 / explicit-lower-bound
helpers, see trap T30 in fortran-to-c.md) alongside `idx1`, `idx2`, `idx3`, `idx1_stride`.
With no product wired yet (no TARGET C), the check skips (exit 0); the demonstration runs
against fixtures.

## Seeded defect (representative of the class)

A TARGET line whose subscript is an unrecognized helper / hand-rolled expression, e.g.
`a[idx9(i)]` (stands in for any non-whitelisted subscript such as `a[i*nx + j]`).

## Red proof

- Fixture with four subscripts on separate lines: `a[idx0(i)]`, `b[idxlb(i, lb)]`,
  `a[idx3(i,j,k)]`, `a[idx9(i)]`.
- NEW detector: RED, exit 1 - `[FAIL] .../m.c:5: ad-hoc subscript '[idx9(i)]'`; the
  `idx0(...)`, `idxlb(...)` and `idx3(...)` subscripts are accepted. `4 subscript(s) checked
  ... 1 violation(s).` The detector still fires on ad-hoc indexing - the whitelist was widened,
  not disabled.

## Causal proof (the change is what enables idx0/idxlb)

- Same fixture run against the PRE-change detector (`git show main:...check-index-helpers.sh`):
  RED, exit 1 with THREE violations - `[idx0(i)]`, `[idxlb(i, lb)]` AND `[idx9(i)]` are all
  flagged. So `idx0` and `idxlb` were rejected before this change and are accepted after it;
  the diff is causal.

## Green proof (defect removed)

- Fixture containing only the newly whitelisted subscripts (`a[idx0(i)]`, `b[idxlb(i, lb)]`):
  GREEN, exit 0 - `2 subscript(s) checked ... 0 violation(s). RESULT: GREEN`.

## Scope / non-defect signals confirmed

- `idx0`, `idx1`, `idx2`, `idx3`, `idx1_stride`, `idxlb` calls and bare numeric-literal
  subscripts pass.
- Helper definition files (`*/idx.h`, `*/idx.c`) are excluded by design.
- No TARGET `*.c`/`*.h` under the scan root skips with exit 0 (vacuous-clean, not "could
  not run").

## Comparison-logic version (re-seeded 2026-06-19)

Subscript content must match
`^[[:space:]]*([0-9]+|idx0\(...\)|idx1\(...\)|idx2\(...\)|idx3\(...\)|idx1_stride\(...\)|idxlb\(...\))[[:space:]]*$`
(the `ALLOWED_RE` allowlist). Re-run this demonstration after any change to that
allowlist / extraction logic (standing seeded-bug rule): widening it must keep the RED on a
non-whitelisted subscript, and the newly added form must move from RED (before) to GREEN
(after).
