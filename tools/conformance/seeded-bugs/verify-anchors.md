# SEEDED-BUG DEMONSTRATION - conformance/verify-anchors

- Date: 2026-06-14 (re-seeded after adding kind-suffix-literal rendering to check 3)
- Detector: tools/conformance/verify-anchors.sh (check 3, `check_rendering`)
- Failure class targeted: trap T1 - a Fortran real literal rendered at the wrong precision in
  TARGET. A kind-suffixed DOUBLE literal (`1.0_dp`, `2.5_real64`, `3.0_8`) rendered with a
  `f` suffix silently rounds to float; a kind-suffixed SINGLE literal (`1.0_sp`, `_real32`,
  `_4`) rendered WITHOUT the `f` suffix silently widens. The explicit kind suffix overrides
  default typing, so it must drive the rendering assertion.
- Exit-code contract: 0 GREEN, 1 RED (rendering violation), 2 UNRELIABLE (untested literal
  form, e.g. a `d`-exponent).

The in-repo `target/` has no TARGET C yet, so the full check skips (exit 0). The
comparison logic that changed is the pure function `check_rendering(literal, target_line)`;
the demonstration drives it directly with a verbatim harness built from the script's own
lines (kind-array config + `extract_numerics` + `check_rendering`), so the proof exercises
the exact shipped logic.

## Seeded defects (representative of the class)

- D1: kind-suffixed double rendered f-suffixed - `1.0_dp` with TARGET `... = 1.0f;`.
- D2: kind-suffixed single rendered without f - `1.0_sp` with TARGET `... = 1.0;`.

## Red proof

- D1: RED, return 1 - "kind-suffixed double literal '1.0' must render as a double ('1.0',
  no f suffix); an f suffix rounds to float (trap T1)". Confirmed for `1.0_dp`,
  `2.5_real64`, `3.0_8`.
- D2: RED, return 1 - "kind-suffixed single literal '1.0' must render f-suffixed ('1.0f')
  in TARGET (trap T1)". Confirmed for `1.0_sp`.
- Project kind ALIAS: with `VERIFY_ANCHORS_DOUBLE_KINDS=p`, `1.0_p` rendered `1.0f` is
  RED (the env var registers `p` as a double-kind alias).

## Green proof (defects removed)

- `1.0_dp` with TARGET `... = 1.0;` -> GREEN (return 0).
- `1.0_sp` with TARGET `... = 1.0f;` -> GREEN (return 0).
- `1.0_p` (alias env set) with TARGET `... = 1.0;` -> GREEN (return 0).

## Causal + scope proof (no regression to existing rules)

- Causal: `1.0_p` WITHOUT the env var is NOT treated as a kind suffix; it falls through to
  the default-single rule (the `p` is unknown), so TARGET `1.0f` is GREEN. The alias
  recognition exists only because the env var registers it - the new branch is what fires.
- Default-single (no kind suffix) unchanged: `1.0` rendered `1.0` is RED (must be
  f-suffixed); rendered `1.0f` is GREEN.
- Integer literal unchanged: `5` present unsuffixed is GREEN.
- `d`-exponent literal unchanged: `1.0d0` returns 2 (UNRELIABLE) - its d->e rendering rule
  is still not seed-tested, so the verifier refuses to assert it (rule 7), exactly as
  before this change.

## Comparison-logic version (re-seeded 2026-06-14)

For each numeric token in the literal-as-read, an explicit kind suffix is detected by
matching `<num>_<kind>` (case-insensitive) against the kind lists
`DOUBLE_KINDS="dp real64 8 $VERIFY_ANCHORS_DOUBLE_KINDS"` and
`SINGLE_KINDS="sp real32 4 $VERIFY_ANCHORS_SINGLE_KINDS"`. A double kind FAILs on an
`<num>f` rendering and requires `<num>`; a single kind requires `<num>f`. Literals with no
recognized kind suffix fall through to the prior rules (d-exponent -> UNRELIABLE;
`.`/`e` real -> f-suffixed single; integer -> unsuffixed). Re-run this demonstration after
any change to `check_rendering`, the kind lists, or `extract_numerics` (standing seeded-bug
rule).
