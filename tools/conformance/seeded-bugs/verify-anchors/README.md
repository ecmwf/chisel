# Anchor-verifier test cases

A corpus of SOURCE/TARGET fixture pairs for an anchor verifier that compares VALUES: for every
provenance-anchored constant in TARGET C code, it compiles the cited SOURCE Fortran constant with
gfortran and the TARGET constant with clang and compares the two bit for bit. Each case is one
SOURCE constant, its TARGET rendering, and the verdict such a verifier must give. The corpus holds
no verifier code; a verifier is ready when it gives every case its expected verdict in every
regime the case lists.

The cases come from situations a textual anchor verifier had to special-case one by one: kind
suffixes, integer and real operands, dual-precision builds, powers, computed and conditional
constants, intrinsics, names, run-time values, malformed anchors. Several verdicts differ from
what a textual reading suggests, because the verdict is the bits: a hard-coded value with the
bits of an intrinsic is a pass, and the pair-table product tree for a constant power can be a
mismatch, since the SOURCE compiler folds a constant power correctly rounded.

## Layout

One case per directory, `<category>/<NN>-<short-slug>/`, holding exactly three files:

| File | Content |
|---|---|
| `source.F90` | A minimal free-form Fortran module declaring the SOURCE constant(s), preprocessed (`gfortran -cpp`). Generic names only. |
| `target.c` (or `target.h` for a header-only rendering) | The self-contained C rendering, carrying the anchor grammar below. |
| `case.yaml` | What is compared and the expected verdict. |

`case.yaml`:

```yaml
description: <one line: the situation>
source: {file: source.F90, line: <int>, name: <SOURCE name or component path>}
target: {file: target.c, line: <int>, name: <C name or member path>}
regimes: [dp]            # precision builds the verdict holds in: [dp], [sp] or [dp, sp]
expect: pass             # pass | mismatch | not-comparable | invalid-anchor
mismatch: value          # ONLY when expect: mismatch -> value | kind | type | shape
at: <optional element/field path of the first difference>
why: <one or two lines: what a verifier must get right, and the wrong verdict a naive one gives>
```

- `source` names the SOURCE constant the TARGET renders and the line that declares (or assigns)
  it; `target` names the TARGET entity and its line. A name may be a path (`T%A`, `TAB(2)`,
  `ctx.a`, `ctx->a`, `tab[1]`); the cited line must contain one of its identifiers (SOURCE: any
  case; TARGET: exact case).
- For an `invalid-anchor` case, `source` and `target` still name the true pair; the anchor on
  the TARGET line is what is wrong.
- `at` is for aggregates: the element or field of the first difference.

## Anchor grammar

A constant anchor is `/* src: source.F90:<line> = <literal-as-read> */`, on one physical line,
where `<literal-as-read>` is the right-hand side exactly as written on the cited SOURCE line. It
binds to the declaration on its own line, or to the declaration on the line below it. Every case
except an `invalid-anchor` case carries, on the TARGET line or the line above it, the anchor
citing `source.line`.

## Regimes

| Regime | SOURCE | TARGET |
|---|---|---|
| `dp` | `gfortran -cpp -DFIXTURE_DP` | `clang -std=c17 -DFIXTURE_DP` |
| `sp` | `gfortran -cpp` | `clang -std=c17` |

A working-precision case declares, in `source.F90`:

```fortran
#ifdef FIXTURE_DP
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(13, 300)
#else
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(6, 37)
#endif
```

and in the TARGET, the dual-precision wrapper:

```c
#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif
```

A fixed-kind case (`DP`, `REAL(8)`, integers, logicals) usually lists `[dp]` only. A verdict
that holds in one build only lists that build: a float literal for a working-precision constant
is a `mismatch` in `[dp]` and correct in `sp`.

## Verdicts

| Verdict | Meaning |
|---|---|
| `pass` | Bit-identical value and the same type and kind, in every listed regime. |
| `mismatch` / `value` | Same type and kind, different bits. Signed zeros differ; numeric equality is not enough. |
| `mismatch` / `kind` | Same type class, different precision: a different kind or width (a float for a double, a 4-byte integer for an 8-byte one), or the same declared kind holding a value rounded through another precision (a single-precision literal or product in a double constant, a missing or broken dual-precision wrapper). |
| `mismatch` / `type` | Different type class: integer, real, logical, complex. |
| `mismatch` / `shape` | Element or field count differs; a missing, extra or duplicated element or designator; a wrong designator. |
| `not-comparable` | The SOURCE value is not a compile-time constant (assigned at run time, allocated). The verifier must report the anchor as unverified, never as a pass, even when the code looks right. |
| `invalid-anchor` | The anchor itself is wrong or cannot be bound: it cites a line not holding the constant or a file that does not exist, is duplicated, is bound to the wrong declaration, or breaks the grammar. The value comparison is never reached, whatever the values are. |

When several differences coexist, the verdict names the first of shape, type, kind, value. A
LOGICAL renders as `bool` throughout; trap T14 also permits `int`, which a verifier supporting it
takes as configuration.

The value compared is the one each compiler gives the constant: a PARAMETER or initializer
folded by gfortran; an object, enumerator or object-like macro evaluated by the compiled C
program. A TARGET entity may be a file-scope object, an enumerator, an object-like macro
(including one that calls a math function), a struct member reached through its path, or a
block-scope constant whose initializer is a constant expression. A mutable variable with an
initializer is compared through its initial value.

## How the expected verdicts were established

Every `pass` and `mismatch` verdict was measured, not assumed. A scratch harness, kept outside
the repository, compiled each case in each listed regime and ran a small program on each side
that prints the named constant's type, kind and bit pattern: on the SOURCE side the constant is
passed to a `CLASS(*)` dummy, classified with `SELECT TYPE` and printed with `TRANSFER` to an
integer in hexadecimal; on the TARGET side it is classified with `_Generic` and printed through
`memcpy` to `uint32_t` or `uint64_t`. Flags: `gfortran -cpp -O0 -ffp-contract=off`,
`clang -std=c17 -O0 -ffp-contract=off -lm`. The verdict follows from the two printouts; a
same-kind real difference is `kind` only when it disappears once the TARGET's literal precision
alone is moved (every `f` suffix dropped, or every unsuffixed literal given one), else `value`.
A block-scope constant was reached through the function that returns it, and a pointer through
its association status.

The measurements were taken on x86-64 with GNU Fortran 16.2.1, clang 23.1.3 and GNU libc 2.44.
Cases whose TARGET calls a math function (`log`, `exp`, `cos`, `tanh`, `atan2`, `pow`) rely on
the math library returning the correctly rounded result for the argument used, as gfortran's
folding does; re-measure them on another platform. `sqrt`, `fabs`, the integer and rounding
functions are exact everywhere.

`not-comparable` and `invalid-anchor` verdicts follow from their definitions; each case's `why`
gives the reason. For most `invalid-anchor` cases the values agree, so only the anchor is wrong.

## Validation

`tools/tests/test-verify-anchors-cases.sh` (run by `tools/tests/run.sh` and CI) validates every
case: `case.yaml` parses and uses only the keys and values above, `mismatch` is present exactly
when `expect` is `mismatch`, the three files exist, the cited lines exist and name the symbol,
every case but an `invalid-anchor` one carries its anchor, the TARGET passes
`clang -std=c17 -fsyntax-only` and the SOURCE `gfortran -cpp -fsyntax-only` in each listed regime,
and every category holds at least one `pass` case and at least one other. A missing compiler
fails the test. The test also runs the validator on seeded malformed cases and requires each to
be rejected for its own reason.

The validator does not measure verdicts: a new `pass` or `mismatch` case needs its verdict
measured as described above before it is added.

## Adding a case

1. Pick the category, or create one (lowercase, hyphenated) with at least one `pass` case and
   one other. Number the case after the last one in its category.
2. Write `source.F90` (module `MOD_A`, generic names: `A`, `B`, `X1`, `NPTS`, `WP`) and the
   TARGET with its anchor; keep both minimal and free of comments other than anchors.
3. Write `case.yaml`; say in `why` what a verifier must get right and which wrong verdict a
   naive one gives.
4. Measure the verdict in every listed regime (pass and mismatch cases), then run
   `bash tools/tests/test-verify-anchors-cases.sh`.
5. Every situation has a `pass` case and a case for its plausible wrong rendering.

## Categories

One row per category; add one when adding a category.

| Category | Situations |
|---|---|
| `literals-kinds/` | Kind suffixes (trailing point, exponent after the point, numeric kinds), D and E exponents, f-suffixed literals for double constants, integer and logical kinds, an integer rendered as a logical, digit strings, anchor text against code. |
