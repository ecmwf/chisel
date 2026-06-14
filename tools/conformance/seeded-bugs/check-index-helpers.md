# SEEDED-BUG DEMONSTRATION - conformance/check-index-helpers

- Date: 2026-06-14 (re-seeded after the `idx3` whitelist-expansion comparison-logic change)
- Detector: tools/conformance/check-index-helpers.sh
- Failure class targeted: ad-hoc index arithmetic. A multi-dimensional or base-shifted
  TARGET array access that does NOT go through a central index helper (CONVENTIONS section 6
  / the charter index-base + storage-order transforms). A hand-written `a[i*nx + j]` silently
  reintroduces the storage-order/index-base assumptions the helpers exist to localize.
- Exit-code contract: 0 GREEN (all subscripts use the idiom), 1 RED (an ad-hoc subscript),
  2 UNRELIABLE (could not run).

The detector scans TARGET `*.c`/`*.h`, extracts every `[...]` subscript, and flags any that
is neither a numeric literal nor a whitelisted helper call. The whitelist is the comparison
logic; this change adds `idx3(...)` (the 3-D index helper) alongside `idx1`, `idx2`,
`idx1_stride`. The in-repo `target/` has no TARGET C yet, so the check skips there (exit 0);
the demonstration runs against fixtures.

## Seeded defect (representative of the class)

A TARGET line whose subscript is an unrecognized helper / hand-rolled expression, e.g.
`a[idx9(i)]` (stands in for any non-whitelisted subscript such as `a[i*nx + j]`).

## Red proof

- Fixture with three subscripts on separate lines: `a[idx3(i,j,k)]`, `b[idx2(i,j)]`,
  `a[idx9(i)]`.
- NEW detector: RED, exit 1 - `[FAIL] .../m.c:4: ad-hoc subscript '[idx9(i)]'`; the
  `idx3(...)` and `idx2(...)` subscripts are accepted. `3 subscript(s) checked ... 1
  violation(s).` The detector still fires on ad-hoc indexing - the whitelist was widened,
  not disabled.

## Causal proof (the change is what enables idx3)

- Same fixture run against the PRE-change detector (`git show main:...check-index-helpers.sh`):
  RED, exit 1 with TWO violations - BOTH `[idx3(i,j,k)]` AND `[idx9(i)]` are flagged. So
  `idx3` was rejected before this change and is accepted after it; the diff is causal.

## Green proof (defect removed)

- Fixture containing only a whitelisted subscript (`a[idx3(i,j,k)]`): GREEN, exit 0 -
  `1 subscript(s) checked ... 0 violation(s). RESULT: GREEN`.

## Scope / non-defect signals confirmed

- `idx1`, `idx2`, `idx1_stride`, `idx3` calls and bare numeric-literal subscripts pass.
- Helper definition files (`*/idx.h`, `*/idx.c`) are excluded by design.
- No TARGET `*.c`/`*.h` under the scan root skips with exit 0 (vacuous-clean, not "could
  not run").

## Comparison-logic version (re-seeded 2026-06-14)

Subscript content must match
`^[[:space:]]*([0-9]+|idx1\(...\)|idx2\(...\)|idx3\(...\)|idx1_stride\(...\))[[:space:]]*$`
(the `ALLOWED_RE` allowlist). Re-run this demonstration after any change to that
allowlist / extraction logic (standing seeded-bug rule): widening it must keep the RED on a
non-whitelisted subscript, and the newly added form must move from RED (before) to GREEN
(after).
