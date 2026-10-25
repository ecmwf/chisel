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

With no product wired yet (no TARGET C), the full check skips (exit 0). The anchor-COVERAGE arm
(check 4) scans the shipped TRANSLATED sources only: a product `tests/` subtree is pruned, since test
scaffolding (runtime const-locals, fixtures, path arrays) has no SOURCE `file:line` to anchor; a
`tests`-NAMED file under `src/` is still scanned. The
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

## Check 2 (module header) - case-insensitivity (added 2026-06-14)

- Failure class targeted: a module-header anchor `/* src: <path>:<line> (module <name>) */`
  whose cited SOURCE line is a module declaration in a CASE that differs from the matcher.
  Fortran is case-insensitive and many codebases write the keyword uppercase (`MODULE FOO`),
  so a case-SENSITIVE check for lowercase `module` silently FAILs every uppercase-MODULE
  source - a false RED that blocks a correct anchor.
- Comparison logic: check 2 now lowercases both sides:
  `[[ "${stext,,}" != *"module ${modname,,}"* ]]`.
- Demonstration (the exact shipped comparison, driven directly):
  - SOURCE `MODULE TPM_CONSTANTS`, anchor `(module TPM_CONSTANTS)` -> GREEN (was RED before
    the fix: `module` != `MODULE`).
  - SOURCE `module foo`, anchor `(module foo)` -> GREEN (unchanged; lowercase source still works).
  - SOURCE `MODULE TPM_CONSTANTS`, anchor `(module TPM_OTHER)` -> RED (a wrong module name still
    fails; the fix does not weaken the name check, only the keyword case).
- Re-run after any change to the check-2 comparison.

## Project kinds file (added 2026-06-14)

Project kind aliases (e.g. a Fortran codebase whose working precision is `JPRB`/`JPRD`/`JPRM`) can
be persisted in a sourced file `.verify-anchors-kinds` at repo root (overridable via
VERIFY_ANCHORS_KINDS_FILE), setting VERIFY_ANCHORS_DOUBLE_KINDS / VERIFY_ANCHORS_SINGLE_KINDS. This
lets the BASE CI invocation honor them without per-project env (the .github workflow is base-owned).
The rendering logic is unchanged; only the kind lists are configured. Red-then-green: a `2.0_jprd`
double literal rendered `2.0` is RED with no kinds configured (treated as default-single, wants
`2.0f`), GREEN once `.verify-anchors-kinds` registers `jprd` as a double kind.

## Check 3 (TARGET rendering) - the anchor comment must not mask the code (added 2026-06-18)

- Failure class targeted: a constant anchor embeds the literal AS READ in its comment
  (`/* src: <path>:<line>: <literal> */` - the anchor convention is that the comment carries the
  SOURCE value verbatim). check 3 searched the WHOLE target line for the correctly-rendered
  literal, so a WRONG code initializer was silently ACCEPTED whenever the correct literal appeared
  in the anchor comment - which, by the embed convention, is ALWAYS. The verifier passed exactly
  the rendering bug (trap T1) it exists to catch: a false-PASS, the worst failure for a gate
  (a gate that cannot fail is worse than none).
- Comparison logic: the single-pass extractor now emits a CODE-ONLY field as the anchor record's
  LAST field, in place of the full target line (which check 3 no longer needs) - the target line
  with the `/* src: ... */` anchor comment excised
  (`code = substr(line, 1, mstart-1) substr(line, mstart+mlen)`). check 3 (`check_rendering`)
  compares against the code-only field, so the anchor text can never satisfy the rendering
  assertion; only the actual initializer can. Making it the LAST tab-separated field keeps it robust
  to a literal tab inside the target line (the tab cannot shift the field across the `read` split).

### Seeded defect (representative of the class)
- D3: a kind-suffixed double `9.81_dp` whose TARGET line renders the WRONG value in code while the
  anchor comment carries the right one:
  `static const double g = 9.8;  /* src: phys.f90:42: 9.81_dp */`

### Red proof (with the fix)
- D3 -> RED, return 1: check 3 reads the code-only field `static const double g = 9.8;`, finds
  `9.8` != the required `9.81`, and FAILs (rendering violation).

### Green proof (defect removed)
- `static const double g = 9.81;  /* src: phys.f90:42: 9.81_dp */` -> GREEN (return 0): the
  code-only field carries the correct `9.81`.

### Causal proof (the fix is what makes it RED)
- With the PRE-FIX logic (search the FULL line), D3 PASSED (false-pass): the correct `9.81` in the
  anchor comment satisfied the search even though the code said `9.8`. Excising the comment is what
  turns the false-pass into a correct RED - the masking, not the rendering rule, was the defect.

### Scope proof (no regression)
- A correct rendering with an embedded-literal anchor is still GREEN (the code-only field holds the
  right value); a line with no anchor comment is unchanged (excision is a no-op). The kind-suffix /
  d-exponent / module-header rules (above) are untouched - check 3 is fed the code, not the comment;
  `check_rendering` itself is unchanged.
- A constant def with a literal TAB inside it (e.g. a column-aligned declaration) and a WRONG value
  still goes RED: the code-only field is the record's LAST tab-separated field, so the tab cannot
  shift it across the `read` split and re-admit the right value from the anchor comment.
- Re-run after any change to the anchor-extraction awk or `check_rendering` (standing seeded-bug rule).

## Check 3 calibration: precision regime, value-equivalence, line scope (added 2026-06-20)

Four comparison-logic changes, all proven to PRESERVE the genuine trap-T1 / wrong-constant
detection while removing context-blind false-PASS-of-RED (false REDs in already-gated code):

1. **Default-real precision regime** (`DEFAULT_REAL`, from `VERIFY_ANCHORS_DEFAULT_REAL`,
   default `single`). A project compiled under a promote-default-real regime renders a bare
   `2.`/`1.` (no kind suffix) as a plain double; demanding the `f` suffix is wrong there (and
   trips -Wdouble-promotion - a charter-ratifiable rendering policy). `double` makes a bare real
   behave like an explicitly double-kinded literal (accept plain, reject `f`); `single` keeps the
   T1 f-suffix requirement.
2. **Value-equivalence for exponents** (`value_present`): `1.0E+100` (Fortran) and `1.0e100`
   (C house style) are the same value; the presence test normalizes the exponent marker to
   lowercase `e` and drops the redundant `+`.
3. **Comment-only anchor lines**: a stand-alone `/* src: ... */` documentation anchor leaves an
   empty code part; there is no rendered code on that line to assert about (the value is rendered
   and gate-checked on the line it annotates). `check_rendering` returns OK on an empty code line.
4. **Line scope for "value not found"** (`is_def`): a missing literal is a defect only on a
   CONSTANT-DEFINITION line (the same `const|enum|static` / `#define` shape check 4 keys on),
   where the value MUST be present. On a general expression/statement/format line the literal can
   legitimately be ABSENT from that physical line - rendered on a sibling line of a multi-line
   statement, rewritten algebraically (`2.0*x*x` -> `x*x + x*x`), or a Fortran FORMAT repeat count
   (`8I8`, `20(1X,I4)`) that becomes a printf format - so its rendering is gate-governed, not
   line-token-checkable. A value that IS present is still T1-precision-checked everywhere.

### Demonstration (the shipped `check_rendering` driven directly)

PRESERVED genuine defects -> RED (return 1):
- a constant DEFINITION rendering the WRONG value, `9.81_dp` vs code `static const double g = 9.8;`
  ("kind-suffixed double literal '9.81' not found"); `8` vs `enum { nmax = 7 };` (integer not found);
- a present double rendered f-suffixed, `1.0_dp` vs `x = 1.0f * y;` (trap T1, must be no-f);
- single-default regime still demands f: bare `2.` vs `x = 2.0;` -> RED (must be `2.f`).

CLEARED false-positives -> GREEN (return 0):
- non-definition line with the integer absent (`2` vs `kfield;`); a FORMAT repeat-count
  (`20` vs `fprintf(f," %4d",...)`); an algebraic vanish (`2.0_dp` vs `p*p ... * p ...`);
- a comment-only anchor line (empty code); a double-default bare real (`2.` vs `... 2.0 ...`);
  the exponent equivalence (`1.0E+100_dp` vs `zscale = 1.0e100;`).

### Causal proof

With `DEFAULT_REAL=single` (the pre-change default) the bare `2.` case is RED; a project's
kinds file sets `VERIFY_ANCHORS_DEFAULT_REAL=double`, which is what turns it GREEN.
The wrong-constant and present-f-suffix REDs above show the not-found / T1 arms still fire on a
definition line - the scope change narrows WHERE "not found" is fatal, it does not disable it.

- Re-run after any change to `check_rendering`, `value_present`, the kind lists, `DEFAULT_REAL`,
  or the `is_def` line-shape pattern (standing seeded-bug rule).

## Value-presence token boundary (hardened 2026-06-21)

`value_present` matched the literal as a raw SUBSTRING, so a WRONG constant that merely CONTAINED the
right value passed (`9.81` inside `static const double g = 19.81;`). It now matches at a NUMERIC TOKEN
boundary (the boundary class excludes digit, dot, AND identifier chars), with a right tail that admits
ONLY value-preserving spellings: an exponent literal is strict (every exponent digit is significant), a
plain float allows trailing fraction zeros, an integer may render as `N.0`. Demonstrated (driving
`value_present`):

- WRONG values now ABSENT -> the definition arm goes RED: `9.81` vs `19.81` (left-adjacent digit);
  `8` vs `18` (left), `8` vs `80` (integer right), `8` vs `n8` (identifier), `8` vs `1e8` (exponent
  token); `1.5` vs `1.5e8`, `9.81` vs `9.812` / `9.81e2`, `1.0E+100` vs `1.0e1000` (right-extension).
- PRESERVED equivalences still PRESENT: `9.81` vs `9.81`; trailing zeros `2.` vs `2.0` and `9.81` vs
  `9.810`; integer-as-float `8` vs `8.0`; the exponent spelling `1.0E+100` vs `1.0e100`.
- PRE-hardening: `9.81` vs `19.81` returned PRESENT (substring) - a wrong constant passed on a
  definition line; the fix closes that fail-open. (The differential gate remains the deeper backstop.)

## Malformed / wrapped anchor (check 5) - dangling "/* src:" (added 2026-06-23)

- Failure class targeted: an anchor the single-line matcher (`/\/\* src:.*\*\//`) SILENTLY
  DROPS. A `/* src:` opening with no closing `*/` on the SAME physical line is neither
  recognized as an anchor (the `A` matcher needs the close on the line) nor flagged by the
  coverage guard (which skips any line containing `/* src:`) - so a broken or
  auto-formatter-WRAPPED anchor (a long literal + its anchor reflowed across two lines) was
  an INVISIBLE FALSE-PASS: GREEN with a missing provenance anchor, no coverage gap raised.
- Comparison logic: the AWK extractor now emits a `D` record when a line contains `/* src:`
  but the full single-line anchor regex did NOT match (an `else if` on the existing matcher,
  so a valid single-line anchor still emits `A`, never `D`). The driver counts a `D` as a
  violation -> exit 1 RED. (Exit-code contract note updated: RED now names "anchor, coverage,
  or malformed-anchor violation".)
- Demonstration (the shipped verifier driven over a one-line fixture; the `D` check fires
  during the TARGET line scan, before any SOURCE lookup, so the pin only needs to resolve -
  `SOURCE_PIN_REF=HEAD`):

  RED (dangling - the formatter moved the closing `*/` to its own line):
  ```
  static const double pi = 3.14159265358979323846; /* src: src/mod.F90:9 = pi
   */
  ```
  ->
  ```
  [FAIL] line 1: malformed/wrapped anchor - '/* src:' opens with no closing '*/' on the same line
         (auto-formatter wrap?); the single-line matcher drops it silently - keep the anchor on one physical line
  SUMMARY: 0 anchor(s) checked; 1 violation(s); ...
  RESULT: RED (exit 1)
  ```

  GREEN (no false positive - a line with no `/* src:` opening stays quiet):
  ```
  double rng_draw(void);
  ```
  -> `SUMMARY: 0 anchor(s); 0 violation(s)` / `RESULT: GREEN (exit 0)`.

- Causal + scope proof (no regression to existing rules):
  - Causal: the `D` record is emitted only by the NEW `else if` - the prior matcher is
    unchanged, so a line that closes `*/` on the same line still emits `A` (recognized as an
    anchor), never `D`. Verified: a valid single-line constant anchor
    `static const double x = 1.0; /* src: src/m.F90:1 = 1.0_dp */` scans as `1 anchor(s)`
    (an `A` record) with NO `D` finding (the only residual FAIL is check1 source-absent in
    this base-only fixture - unrelated to the dangling check).
  - Scope: a generic multi-line comment that does NOT start with `/* src:` (e.g. `/* a long`)
    does not trigger `D` - only the anchor-opening marker does, so ordinary wrapped comments
    are unaffected.
- Re-run after any change to the AWK anchor matcher (the `match(line, /\/\* src:.*\*\//)` arm
  or the `else if (line ~ /\/\* src:/)` arm) or the driver `D)` case (standing seeded-bug rule).

## Check 4 (coverage) - line-keyed state is emptied per file (added 2026-10-25)

- Failure class targeted: a false GREEN in a MULTI-file run, caused by one file's bookkeeping
  carrying over into a later file. The driver keys three maps by physical LINE NUMBER:
  `HELPER_SEEN_AT` (per-declaration runtime-helper exemptions), `DECL_ELEM_COUNT_AT` (aggregate
  element counts) and `ANCHOR_COUNT_AT` (constant anchors counted per line). `HELPER_SEEN_AT` was
  declared with `declare -A` inside the per-file loop. In bash, `declare -A` on an associative
  array that already exists does NOT clear it. The other two were declared once and never
  emptied. So an entry that file A made at line N decided file B's coverage at line N: a helper
  exemption or a completed anchor tally from A hid a genuine coverage gap in B, and the run
  reported GREEN. Running B on its own gave RED. The verdict therefore depended on which files ran
  together and in what order. A full-tree scan is exactly this kind of multi-file run.
- Comparison logic: all three maps are declared once at top level, with the other line-keyed
  maps, and emptied (`=()`) at the start of every file, the same way `DECL_KIND_AT` /
  `DECL_NAME_AT` / `SEEN_DECL_LINE` / `DECL_AMBIGUOUS_AT` already were. The rest of the loop was
  audited for the same defect. `RCONST_CONTRACT_OK` (keyed by file) and `SRC_TOTAL` / `SRC_SEEN`
  (keyed by SOURCE path) are intentional whole-run caches and are not keyed by line. The run
  counters (`fails`, `unreliable`, ...) are intentional whole-run sums. Every other per-file
  variable is assigned before it is used in each iteration. Nothing else changed: a single-file
  verdict is computed exactly as before.

### Seeded defects (synthetic fixtures in `tools/tests/test-verify-anchors.sh`)

In each case file A is checked first and both entries sit on line 1. A is `a_helper.h` (a
declared helper) or `c_unit.h`; B is `b_unit.h` or `d_unit.h` (stems TRACE declares translated).

- D1 (helper exemption): A `static const int a_helper_limit = 64; /* runtime-helper: T1 - ... */`;
  B `static const int b_unit_count = 7;` (no anchor).
- D2 (anchor tally): A `static const int c_unit_three = 3; /* src: src/ints.F90:3 = 3 */`;
  B `static const int d_unit_tab[2] = {1, 2}; /* src: src/ints.F90:1 = 1 */` (two elements,
  one anchor).
- D3 (both aggregate maps): A `static const int c_unit_tab[2] = {1, 2};` with an anchor for each
  element; B `static const int d_unit_count = 7;` (no anchor).
- D4 (element count; a correct file, guarding against a false RED): A is the D3 aggregate;
  B `static const int d_unit_five = 5; /* src: src/ints.F90:4 = 5 */`.

### Red proof, green proof

| Case | Run | Pre-fix | Fixed |
|---|---|---|---|
| D1 | A alone / B alone | GREEN / RED | GREEN / RED |
| D1 | A then B | **GREEN (false)** | RED: `check4 - constant definition ('b_unit_count', ...) lacks a provenance anchor` |
| D2 | A alone / B alone | GREEN / RED | GREEN / RED |
| D2 | A then B | **GREEN (false)** | RED: `aggregate definition ('d_unit_tab', 2 elements) has only 1 anchor(s)` |
| D3 | B alone | RED | RED |
| D3 | A then B | **GREEN (false)** | RED: `lacks a provenance anchor` |
| D4 | A alone / B alone | GREEN / GREEN | GREEN / GREEN |
| D4 | A then B | GREEN | GREEN |

The single-file controls are identical before and after the fix. Every changed verdict is
therefore caused by cross-file state. Before the fix, D1 B-then-A was RED while A-then-B was GREEN,
which is the same leak showing up as order dependence. D4 was GREEN before the fix only by
cancellation: both aggregate maps leaked, and the leaked anchor tally covered the leaked element
count.

### Causal proof (each reset is load-bearing)

Deleting one reset at a time from the fixed verifier fails exactly the cases that depend on it:

- without `HELPER_SEEN_AT=()`: D1 A-then-B becomes GREEN (1 assertion fails);
- without `ANCHOR_COUNT_AT=()`: D2 A-then-B becomes GREEN (1 assertion fails);
- without `DECL_ELEM_COUNT_AT=()`: D4 A-then-B becomes a false RED, and D3 stays RED but now for
  the wrong reason, an aggregate message instead of the scalar gap (2 assertions fail);
- without all three, which behaves like the pre-fix verifier: D1, D2 and D3 A-then-B become GREEN
  (3 assertions fail). Running the test against the parent commit's verifier gives the same result.

### Reproduce

The test copies the real verifier and `lib/` into a throwaway workbench (synthetic SOURCE, TRACE,
declared-helper list and trap table) and needs `python3` with `clang.cindex` and the native
libclang. Without them it stops with `not ok` rather than passing vacuously.

```
bash tools/tests/test-verify-anchors.sh     # fixed: every assertion ok, exit 0
sed -i -e '/^\tHELPER_SEEN_AT=()$/d' -e '/^\tANCHOR_COUNT_AT=()$/d' \
       -e '/^\tDECL_ELEM_COUNT_AT=()$/d' tools/conformance/verify-anchors.sh
bash tools/tests/test-verify-anchors.sh     # pre-fix behaviour: 3 assertions fail, exit 1
git checkout -- tools/conformance/verify-anchors.sh
```

- Re-run after any change to per-file state in the driver loop: a map added, removed, or reset
  differently (standing seeded-bug rule).
