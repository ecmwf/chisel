# SEEDED-BUG DEMONSTRATION - conformance/check-index-helpers

- Date: 2026-06-20 (re-seeded after the comparison-logic change: balanced-bracket extraction,
  `idx4` whitelisted, and the allow rule scoped to the multi-dimensional FLATTEN per the
  convention - single linear 1-D accesses no longer flagged).
- Detector: tools/conformance/check-index-helpers.sh
- Failure class targeted: ad-hoc index arithmetic. An open-coded MULTI-DIMENSIONAL flatten -
  `a[i + j*nx]` - that does NOT go through a central index helper (CONVENTIONS section 6 /
  the charter index-base + storage-order transforms). A hand-written stride multiply silently
  reintroduces the storage-order/index-base assumptions the helpers exist to localize.
- Exit-code contract: 0 GREEN (no open-coded flatten), 1 RED (an ad-hoc stride flatten),
  2 UNRELIABLE (could not run).

The detector scans the shipped TRANSLATED TARGET `*.c`/`*.h` (a product `tests/` subtree is pruned -
test scaffolding like a fixture buffer SIZE `buf[N*M]` is a declaration, not a ported-array subscript;
a `tests`-NAMED file under `src/` is still scanned), extracts every `[...]` subscript with a BALANCED-bracket
walk (so a helper call carrying a nested subscript, `a[idx2(n, arr[jm], jn)]`, reads as one
unit, not a malformed fragment), and flags a subscript only when it is an open-coded flatten:
a binary `*` stride OUTSIDE a helper call. Allowed without a helper: numeric literals,
whitelisted helper calls (`idx0`, `idx1`, `idx2`, `idx3`, `idx4`, `idx1_stride`, `idxlb` - with
arbitrary nested `()`/`[]` in their arguments), and single linear 1-D accesses (a bare index,
or an index +/- a literal). Base-shift correctness of a bare 1-D access is the fidelity
reviewer's call (and, for proven code, already proven bit-identical by the proof); the mechanical
net catches the stride-multiply flatten. With no product wired (no TARGET C) the check skips
(exit 0); the demonstration runs against fixtures.

## Seeded defect (representative of the class)

A TARGET line whose subscript open-codes a 2-D flatten, `z[i + j * nx]` (stands in for any
hand-rolled stride multiply outside a helper).

## Red proof

- Fixture `red.c` with nine subscripts on separate lines: `a[idx0(i)]`,
  `b[idxlb(i, lb)]`, `c[idx3(i,j,k)]`, `d[idx4(n1,n2,n3,i,j,k,l)]`,
  `e[pp[idx2(n, arr[jm], jn)]]`, `g[jm]`, `h[i - 1]`, `m[NSMAX0 + 1]`, `z[i + j * nx]`.
- NEW detector: RED, exit 1 - exactly one violation,
  `[FAIL] red.c:10: ad-hoc subscript '[i + j * nx]'`. The helper calls (including `idx4` and
  the nested-bracket `idx2`), the bare index `[jm]`, the base-shift `[i - 1]`, and the
  literal-offset `[NSMAX0 + 1]` are all accepted. `9 subscript(s) checked ... 1 violation(s).`
  The detector still fires on the open-coded flatten - the rule was scoped to the flatten, not
  disabled.

## Causal proof (the change is what tightens the scope to the flatten)

- Same fixture run against the PRE-change detector (`git show HEAD:...check-index-helpers.sh`):
  RED, exit 1 with SIX violations - `[idx4(...)]` (defined but then-unwhitelisted), the
  nested-bracket `idx2` (extracted as the malformed `[pp[idx2(n, arr[jm]`), `[jm]`, `[i - 1]`,
  `[NSMAX0 + 1]` AND the flatten `[i + j * nx]`. So the five false-positives/benign forms were
  flagged before this change and are accepted after it, while the genuine flatten stays RED;
  the diff is causal.

## Green proof (defect removed)

- Fixture `green.c` = `red.c` minus the flatten line (and minus the two then-only-illustrative
  whitelist forms `idxlb`/`idx3`, keeping `idx0`, `idx4`, the nested `idx2`, `[jm]`, `[i - 1]`,
  `[NSMAX0 + 1]`): GREEN, exit 0 - `6 subscript(s) checked ... 0 violation(s). RESULT: GREEN`.

## Scope / non-defect signals confirmed

- `idx0`..`idx4`, `idx1_stride`, `idxlb` calls (incl. nested `()`/`[]` arguments), bare numeric
  literals, bare single indices, and index +/- literal all pass.
- A binary `*` stride OUTSIDE a helper (`i + j*nx`, `(s-1)*C + (i-1)`) is flagged.
- Helper definition files (`*/idx.h`, `*/idx.c`) are excluded by design.
- No TARGET `*.c`/`*.h` under the scan root skips with exit 0 (vacuous-clean, not "could
  not run").

## Waiver layer (per-site convention-exceptions)

The checker honors a project waiver list (tools/conformance/project/index-helper-waivers.txt,
or $INDEX_HELPER_WAIVERS): `<path-substring><TAB><exact subscript content>`. A flagged flatten
matching an entry is reported `[WAIVE]` and does not fail. A waiver is TARGETED, not a bypass:

- Fixture `m.c` with two flattens, `z[i + j * nx]` and `w[a + b * ny]`. With NO waiver file:
  RED, exit 1, `2 violation(s); 0 waived`. With a waiver file containing only the single line
  `m.c<TAB>i + j * nx`: the first is `[WAIVE]`, the second is still `[FAIL]` -
  `1 violation(s); 1 waived`, exit 1. The other flatten is unaffected; the detector still fires.
- Real use: an open-coded flatten in already-attested code, proven bit-identical by its proof and recorded
  as a KNOWN-DIVERGENCE that policy declines to churn, is waived; the product check reports it as
  `waived`, not a violation.

## Comparison-logic version (re-seeded 2026-06-20)

A subscript (content of a balanced `[...]`) is ALLOWED iff, trimmed, it is: a numeric literal
(`^[0-9]+$`); OR a whole whitelisted helper call (`^idx(0|1|2|3|4|1_stride|lb)\s*\(` whose first
`(` balances at the final non-space char); OR carries no binary stride multiply (no
`[A-Za-z0-9_)]\s*\*`). Re-run this demonstration after any change to that allow rule or the
extraction logic (standing seeded-bug rule): tightening or widening it must keep the RED on the
open-coded flatten, and any form whose disposition changes must be shown moving across the
PRE/POST boundary on the fixture.

## Fail-closed on a multi-line subscript (hardened 2026-06-21)

The per-line extractor cannot read a subscript split across physical lines. It now FAILS CLOSED on
an unbalanced `[` instead of silently skipping the line - a multi-line flatten could otherwise hide:

- Fixture `ml.c` with the flatten split over two lines:
  `z[i +` / `    j * nx] = 0.0;`. Detector: RED, exit 1 -
  `[FAIL] ml.c:2: ad-hoc subscript '[multi-line subscript - put it on one line to verify: [i +]'`.
  PRE-hardening (and the pre-`#137` extractor): GREEN, `0 subscript(s) checked` - the subscript was
  silently skipped, so a multi-line flatten passed. The fix closes that fail-open; put the subscript
  on one physical line and the normal helper/literal/waiver logic applies.

## Declaration recognition by whole type tokens (re-seeded 2026-10-25)

- Detector change: `is_declaration` requires a token boundary `([^A-Za-z0-9_]|$)` after every type
  or storage-class keyword, and also recognizes a declaration that starts with a `_t` typedef name
  (a project precision type such as `scalar_t`) followed by the declared name
  (`<name>_t[[:space:]]+[*[:space:]]*<identifier>`).
- Why both: a declaration's array SIZE is not an access, so a declaration line's subscripts before
  its initializer are skipped. Without the boundary, a statement whose first identifier merely
  BEGINS with a keyword (`integral[...]`, `doublet[...]`) was read as a declaration and its flatten
  skipped - the check silently disabled itself for that line. Without the typedef form, a faithful
  declaration such as `scalar_t ar1[n * m];` was flagged as an ad-hoc flatten, which pressures a
  port to reshape faithful code (a VLA into a heap allocation) to satisfy the checker. A `_t` name
  followed directly by `[`, `=` or an operator is a variable, not a type, and stays checked.
- Failure class unchanged: an open-coded `*` stride outside a helper.

### Red proof (negative controls)

- `prefix_int.c`: `integral[i + j * nx] = 0.0;` - RED, exit 1,
  `[FAIL] prefix_int.c:3: ad-hoc subscript '[i + j * nx]'`. The same holds for `doublet[...]`, for a
  call `scalar_transform(a[i + j * n], ...)`, and for `_t`-named variables
  (`rate_t[i + j * nx] = 0.0;`, `count_t = rate_t[i + j * nx];`).

### Green proof (faithful declarations accepted)

- `decl_ok.c` with `double vv[n * m];`, `static int w[2 * n];`, `scalar_t ar1[n * m];` and
  `const scalar_t *row[n * m];`: GREEN, exit 0 - `0 subscript(s) checked ... 0 violation(s)`.

### Causal proof

- The same fixtures against the PRE-change detector: `decl_ok.c` RED,
  `[FAIL] decl_ok.c:5: ad-hoc subscript '[n * m]'` (the `scalar_t` declaration), and
  `prefix_int.c` GREEN, `0 subscript(s) checked` (the flatten skipped as a "declaration"). The
  change moves each across the boundary in the intended direction.
- Executable form: `tools/tests/test-index-helpers.sh` (run by `tools/tests/run.sh`).
