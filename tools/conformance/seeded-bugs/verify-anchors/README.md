# Anchor-verifier test cases

A corpus of SOURCE/TARGET fixture pairs for an anchor verifier that compares VALUES: for every
provenance-anchored constant in TARGET C code, it compiles the cited SOURCE Fortran constant with
gfortran and the TARGET constant with clang and compares the two bit for bit. Each case is one
SOURCE constant, its TARGET rendering, and the verdict such a verifier must give. The corpus holds
no verifier code; a verifier is ready when it gives every case its expected verdict in every
regime the case lists.

The cases cover situations a textual anchor verifier must special-case one by one. Scalars and
expressions: kind suffixes, integer and real operands, dual-precision builds, powers, computed
and conditional constants, intrinsics, names, run-time values. Aggregates and anchors: arrays,
derived-type constants, designated and context initializers, null pointer defaults, logicals,
declarations laid out over several lines, and how anchors bind. Several verdicts differ from what
a textual reading suggests, because the verdict is the bits: a hard-coded value with the bits of
an intrinsic is a pass, a constant power rendered as the pair table's run-time product tree can be
a mismatch, and an omitted designator is a mismatch even when C's zero fill stores the same
bits.

## Layout

One case per directory, `<category>/<NN>-<short-slug>/`, holding exactly three files:

| File | Content |
|---|---|
| `source.F90` | A minimal free-form Fortran module declaring the SOURCE constant(s), preprocessed (`gfortran -cpp`). Generic names only. |
| `target.c` (or `target.h` for a header-only rendering) | The self-contained C rendering, carrying the anchor grammar below. |
| `case.yaml` | What is compared and the expected verdict. |

`case.yaml`:

```yaml
description: <one line: the case>
situation: <slug naming the situation the case belongs to, shared within its category>
source: {file: source.F90, line: <int>, name: <SOURCE name or component path>}
target: {file: target.c, line: <int>, name: <C name or member path>}
regimes: [dp]            # precision builds the verdict holds in: [dp], [sp] or [dp, sp]
expect: pass             # pass | mismatch | not-comparable | invalid-anchor
mismatch: value          # ONLY when expect: mismatch -> value | kind | type | shape
at: <optional element/field path of the first difference>
why: <one or two lines: what a verifier must get right, and the wrong verdict a naive one gives>
```

- `situation` groups the cases of a category that render one SOURCE construct - the faithful
  rendering and its plausible wrong ones (`trailing-point-kind`, `designator-set`, `anchor-below`).
  Every situation holding a `pass` or `mismatch` case holds at least one `pass` case and at least
  one case of another verdict. A situation with neither - its cases all `not-comparable` or
  `invalid-anchor` - is exempt: no rendering of a run-time value can pass, and the counterpart of a
  wrong anchor is every correctly anchored case.
- `source` names the SOURCE constant the TARGET renders and the line that declares (or assigns)
  it; `target` names the TARGET entity and the line that declares (or assigns) it. A name may be
  a path (`T%A`, `TAB(2)`, `ctx.a`, `ctx->a`, `tab[1]`); the cited line must contain one of its
  identifiers (SOURCE: any case; TARGET: exact case).
- **A citation is to a single-statement line.** Every SOURCE line a case cites - `source.line`
  and every line an anchor cites - holds exactly one statement: no `;` statement separator outside
  character context, on the line or on the other lines of its statement. A statement continued
  with `&` is one statement over its lines: a citation may name any of them, its right-hand side is
  that of the whole statement, and the quoted text must stand on the cited line. A cited `DATA`
  statement holds exactly one object-list/value-list set (one `/.../` pair); a repeated value is
  written within that set, as in `DATA A / 3*1.0_WP /`. The validator rejects a case that breaks
  either rule, whatever its verdict.
- An aggregate whose fields are anchored one by one - a designated initializer, a context
  initializer, a struct object holding module variables - is ONE case at the aggregate level:
  `source` is the `TYPE` statement (for a type's default initialization) or the `MODULE`
  statement (for module variables), `target` is the line declaring the object or `#define`, and
  `at` names the first differing field.
- `at` locates the first difference inside an aggregate, zero-based and in storage order: `[3]`
  is the fourth stored element (column-major for a Fortran array of rank 2 or more), `.b.c` a
  nested field, `.k[2]` an element of an array member. A scalar case has no `at`.
- For an `invalid-anchor` case, `source` and `target` still name the true pair; an anchor bound to
  the TARGET is what is wrong.

## Anchor grammar and binding

Two anchor forms occur:

- the constant anchor `/* src: source.F90:<line> = <literal-as-read> */`, where
  `<literal-as-read>` is exactly one of two things, standing on the cited SOURCE line:
  (a) one numeric or logical literal of the line, whole - with its exponent and kind suffix, so
  `0.1_WP` and never `0.1`, `1.E3_WP` and never `1.E3`; or (b) the whole right-hand side of the
  cited statement, compared with whitespace removed: the value of an initialized entity (`NB + 1`
  in `NC = NB + 1`; a pointer default `=> NULL()` gives `NULL()`), of an assignment, or the value
  list of a `DATA` statement. Nothing in between: no part of an expression, no operator, and no name
  unless it is the whole right-hand side. A pointer default is anchored `= NULL()`; `=>` is not part
  of the grammar;
- the module header anchor `/* src: source.F90:<line> (module <NAME>) */`, citing the `MODULE`
  statement, and only on a context initializer `<NAME>_CTX_INIT` (for `{0}`, which has no
  literal; a designated context initializer may carry it beside its field anchors).

An anchor opens and closes on one physical line. It binds to one TARGET entity or to nothing:

1. **Within a declaration.** An anchor on any line of a declaration - from its first line (a type
   wrapped above the name counts) to its last (the initializer's closing line, or the last
   continued line of a `#define`) - binds to that declaration. When the line belongs to several
   (two declarators of one statement, a declaration inside a function), it binds to the one whose
   name is on that line, else to the innermost. Declaration extents are the compiler's (clang's
   AST), so layout does not change them. This is where field anchors of an aggregate sit.
2. **Below a declaration.** An anchor alone on its line (nothing else but closing punctuation
   `}`, `)`, `]`, `;`, `,`) directly below a declaration's last line binds to that declaration,
   unless a declaration starts on the next line.
3. **Nowhere else.** A comment line directly above a declaration binds to nothing, and so does an
   anchor on a line of code that declares nothing. A run-time case whose TARGET is an assignment
   statement carries its anchor on that statement's line.

An anchor bound to the TARGET is valid when it has one of the two forms, cites `source.F90`,
cites an existing line, and is not a copy of another anchor on its line; a constant anchor must
also cite a line of the case's SOURCE scope and quote, on that line, one literal or the whole
right-hand side of its statement, as above. The SOURCE
scope is the statement `source.line` belongs to, with its `&` continuation lines; for a `TYPE`
statement, the type definition and the definitions of the types of its components; for a
`MODULE` statement, the module. At least one anchor must bind to the TARGET, and at least one
constant anchor unless the TARGET is a context initializer. A case is `invalid-anchor` exactly
when one of these rules fails.

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

A case lists the regimes its verdict was measured and holds in. A case whose result cannot
depend on the build (a fixed kind, an integer, a logical) may list both regimes or `[dp]` alone. A
verdict that holds in one build only lists that build: a float literal for a working-precision
constant is a `mismatch` in `[dp]` and correct in `sp`.

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

**Precedence.** An anchor problem is reported first: an `invalid-anchor` case is never compared.
Then `not-comparable`. Among mismatches the verdict names the first of `shape`, `type`, `kind`,
`value`, and `at` the element or field where it occurs.

**Shape before values.** An initializer must give exactly the elements and fields the SOURCE
spells out. An omitted element or designator is `shape` even when C's zero fill stores the same
bits, and so are an excess element that clang drops with a warning, a duplicated designator
whose last value is right, a wrong designator, and a designator for a component that has no
default. Two zero fills are accepted, because they render a SOURCE rule rather than drop a value:
a `NULL()`-defaulted pointer member left to the fill (pair table T32), and a `{0}` context
initializer over a module that also has variables without an initial value (their zero is a
consequence of initializing the struct, not compared).

**What is compared.** The value each compiler gives the constant: a PARAMETER or initializer
folded by gfortran; an object, enumerator or object-like macro evaluated by the compiled C program
(a macro holding a brace list through an object it initializes). A TARGET entity may be a
file-scope object, an enumerator, an object-like macro (including one that calls a math function),
a struct member reached through its path, or a block-scope constant whose initializer is a
constant expression. A mutable variable with an initializer is compared through its initial
value. Reals, integers and complex values compare by bits; logicals by truth value (a Fortran
logical and a C `bool` differ in size); pointers by association (null or not); arrays element by
element in storage order, after their counts.

**Renderings the corpus assumes.** A LOGICAL renders as `bool`, so a logical rendered as `int` is
a `type` mismatch; trap T14 also permits `int`, which a verifier supporting it takes as
configuration. An integer parameter renders as an enumerator (trap T21), except where a case is
about declaration layout or anchor binding, which use `static const int`. A pointer default
`=> NULL()` renders as `NULL`, `0` or the zero fill.

**Constant powers.** The Fortran compiler folds a power in a PARAMETER or initializer at compile
time; GNU Fortran, measured here, folds it correctly rounded at the kind's precision (the standard
does not prescribe how). The pair table's T3 (`references/pairs/fortran-to-c.md`) gives the
renderings of a power evaluated at run time - product trees, the integer-power helper - and is
the rule there. For a CONSTANT power such a rendering can differ from the folded value in the last
bit, and the corpus judges it by its bits like any other rendering (`power/`).

## How the expected verdicts were established

Every `pass` and `mismatch` verdict was measured, not assumed, by two scratch harnesses kept
outside the repository, both run over the whole corpus in every listed regime with
`gfortran -cpp -O0 -ffp-contract=off` and `clang -std=c17 -O0 -ffp-contract=off -lm`:

- **A scalar harness** runs a program on each side that prints the named constant's type, kind and
  bit pattern: on the SOURCE side the constant is passed to a `CLASS(*)` dummy, classified with
  `SELECT TYPE` and printed with `TRANSFER` to an integer in hexadecimal; on the TARGET side it is
  classified with `_Generic` and printed through `memcpy` to `uint32_t` or `uint64_t`. For an
  aggregate it prints every element or field the same way.
- **An aggregate harness** prints each element or component as its type and `TRANSFER` bit
  pattern from a Fortran probe that `USE`s the module (a default-initialized variable for a type's
  defaults), and the same leaves from a C probe that includes the TARGET (a holder object for a
  macro). It takes the structure - which elements and fields carry a value - from
  `gfortran -fdump-fortran-original` (a type's default initialization, a module's initialized
  variables, a parameter's value) against clang's JSON AST (`ImplicitValueInitExpr` marks the zero
  fill) and clang's override and excess-element diagnostics, and it binds anchors with the
  declaration extents of clang's AST. A `not-comparable` TARGET value is shown to fail as a static
  initializer ("initializer element is not a compile-time constant").

Both classify a same-kind real difference as `kind` only when it disappears once the TARGET's
literal precision alone is moved (every `f` suffix dropped, or every unsuffixed literal given one),
else `value`. A block-scope constant is read through the function that returns it, a pointer
through its association status. `shape` verdicts hidden by the zero fill come from the structure.
`not-comparable` and `invalid-anchor` verdicts follow from their definitions and are stated in
each case's `why`; an `invalid-anchor` case keeps the two values equal where it can, so that only
the anchor is wrong.

### What is guaranteed and what is only measured

Every verdict was measured on x86-64 Linux with GNU Fortran 16.2.1, clang 23.1.3 and GNU libc
2.44, and is established for that toolchain. What carries over to another one depends on what a
case rests on:

- **Guaranteed by the standards.** IEEE 754 requires addition, subtraction, multiplication,
  division and square root to be correctly rounded. Fortran defines `ABS`, `INT` (truncation),
  `NINT` (half away from zero), `MOD` and `MODULO` exactly, and C defines `fabs`, conversion to an
  integer (truncation), `lround` (half away from zero) and `rint` (the current rounding direction,
  to nearest even by default) exactly. Decimal literals are converted correctly rounded by both
  compilers measured here; both languages leave that to the implementation (C recommends it).
  The other assumptions of every case: IEEE 754 binary32 and binary64 arithmetic (in C, Annex F),
  the default rounding direction, evaluation in the declared precision (`FLT_EVAL_METHOD` 0), no
  contraction into fused multiply-adds, and a Fortran compiler that folds a constant expression
  rounding each operation at the kind's precision, as GNU Fortran does.
- **What GNU Fortran does, not what Fortran requires.** The standard does not say how an intrinsic
  or `**` is evaluated in a constant expression. GNU Fortran 16.2.1 folded every such constant in
  the corpus - `SQRT`, `EXP`, `LOG`, `ATAN`, `ATAN2`, `COS`, `TANH`, integer and real powers - to
  the correctly rounded result in both precisions (each folded value checked against an 80-digit
  reference), and folded `MAX(-0.0, 0.0)` to its first argument, -0.0, where the standard leaves
  the choice between equal arguments to the processor.
- **What GNU libc does, not what C requires.** C does not require `exp`, `log`, `cos`, `tanh`,
  `atan2` or `pow` to be correctly rounded. GNU libc 2.44 returned, for every argument used here
  and in both precisions, the correctly rounded result, the same bits gfortran folds. `sqrt` is
  correctly rounded wherever the C implementation follows IEEE 754 (Annex F); its run-time value,
  too, was measured on this toolchain only.

On another toolchain, re-measure the cases resting on the last two groups: those whose SOURCE folds
an intrinsic or a power (`intrinsics/`, `power/`, the pi cases of `computed/`), whose TARGET calls a
math function (`sqrt` included), and the signed-zero `MAX` cases.

## What the corpus deliberately does not cover

- Properties of a verifier run rather than of one SOURCE/TARGET pair: state carried from one file
  to the next, work split across parallel processes.
- A TARGET constant with no SOURCE counterpart at all: every case starts from a SOURCE constant
  (an extra element or member of an aggregate is covered, as `shape`).
- Where the dual-precision wrapper is defined (which header, through which include directory):
  every TARGET is one self-contained file.
- Anchors for runtime helpers and lists of declared helper files, which are project
  configuration.
- Character constants and string literals, including `**` inside a string.
- Values that depend on which of two context structs of one type, or which temporary of a closed
  block, a function reads at run time: only `not-comparable` could be said of them.
- `{0}` over a module whose only explicit default is zero (the pair table does not settle it), a
  routine anchor citing the `MODULE` line of a `{0}` initializer, and a second constant anchor below
  a declaration that already has one.

## Validation

`tools/tests/test-verify-anchors-cases.sh` (run by `tools/tests/run.sh` and CI) validates every
case: `case.yaml` parses and uses only the keys and values above (`mismatch` exactly with
`expect: mismatch`, `at` only with it and in the form above); the three files exist; the cited
lines exist and name the symbol; every cited SOURCE line holds one statement and every cited
`DATA` statement one set; the anchor rules hold for every case but an `invalid-anchor` one,
and fail for every `invalid-anchor` case; the TARGET passes `clang -std=c17 -fsyntax-only` and the
SOURCE `gfortran -cpp -fsyntax-only` in each listed regime; every situation holding a `pass` or
`mismatch` case holds a `pass` case and another, as above; and every category holds at least one
`pass` case and at least one other. A missing compiler fails the test. The test also runs the
validator on seeded malformed cases and requires each to be rejected for its own reason.

The validator decides the anchor rules but does not measure values: a new `pass` or `mismatch`
case needs its verdict measured as described above before it is added.

## Adding a case

1. Pick the category and the situation, or create them (lowercase, hyphenated): a new category
   needs a `pass` case and another, and so does a new situation of comparable values. Number the
   case after the last one in its category.
2. Write `source.F90` (module `MOD_A`, generic names: `A`, `B`, `X1`, `NPTS`, `WP`) and the
   TARGET with its anchors; keep both minimal and free of comments other than anchors. An
   aggregate anchored field by field follows the aggregate convention above.
3. Write `case.yaml`; say in `why` what a verifier must get right and which wrong verdict a
   naive one gives.
4. Measure the verdict in every listed regime (pass and mismatch cases), then run
   `bash tools/tests/test-verify-anchors-cases.sh`.
5. Give every faithful rendering a plausible wrong one in its situation, and every wrong one a
   faithful counterpart; the validator rejects a situation that lacks either.

## Categories

One row per category; add one when adding a category.

| Category | Situations |
|---|---|
| `literals-kinds/` | Kind suffixes (trailing point, exponent after the point, numeric kinds), D and E exponents, f-suffixed literals for double constants, integer kinds, an integer rendered as a logical, digit strings, anchor text against code. |
| `int-real/` | Integer and real operands, integer division into a real constant, whole values written as integers, integer constants rendered real and the reverse. |
| `precision/` | The dual-precision wrapper; a missing wrapper (harmless on a lone literal, wrong in an expression); a wrapper on a fixed-kind constant; a wrong typedef or wrapper definition; default-real literals inside working-precision expressions. |
| `power/` | `**` with integer exponents as products, folded correctly rounded in a constant; precedence and grouping; unary minus; zero and negative exponents; real exponents through `pow`; renderings the pair table does not prescribe, and mathematically equal forms that round differently. |
| `computed/` | A literal that is the whole right-hand side or one term of it; constants computed from other constants; pi from an intrinsic; derived constants and the kind of their intermediates; a statement split over `const` temporaries. |
| `intrinsics/` | SQRT, LOG, EXP, ATAN2, COS, SIN, TANH, ABS, MAX (signed zero), MOD and MODULO, REAL, NINT, INT; the wrong intrinsic or argument; a macro alias spelled like the SOURCE; a call replaced by a hard-coded value. |
| `conditional/` | MERGE rendered as a conditional, both branches, swapped branches, a negated or different condition, the selected branch hard-coded. |
| `names/` | A constant defined as another; C names differing only in case; an enumerator or macro shadowing a name; module variables as the members of a context struct object; the comma operator. |
| `runtime/` | Values assigned at run time, write-once locals, allocator-initialized pointers (`not-comparable`); initialized module variables, which are compile-time values. |
| `arrays/` | `(/ ... /)` and `[ ... ]` constructors, sized and unsized C arrays, missing, extra and truncated elements, `#define` brace lists, rank-2 storage order (reversed extents and a flat array pass, a row-by-row transposition does not), `RESHAPE` with `ORDER`, `DATA` repeat counts, implied-DO constructors, element kind and type, elements written without the dual-precision wrapper. |
| `structs/` | A derived-type parameter compared component by component: positional, designated and keyword constructors, nested constants, a constructor relying on a component default, an array component, a member the SOURCE type lacks. |
| `designated/` | A type's default initialization as a designated initializer with one anchor per field: reordered, missing (also with a zero default), extra, duplicated and wrong designators, nested types, a component default overriding its type's defaults, compound defaults, member type and kind, positional elements after a designator. |
| `context/` | `<MODULE>_CTX_INIT` as `{0}` (pair table T32) and as a designated initializer with its module header anchor; non-zero and invented defaults, a field anchored to another module, two variables of one SOURCE line, a variable initialized by `DATA`, module anchors on the wrong line or naming the wrong module. |
| `pointers/` | `=> NULL()` as `NULL`, `0` or the zero fill, a module pointer kept null or preset, a non-null address, an integer handle member, an identifier spelled `NULL` that is a parameter. |
| `logicals/` | `true`, `false`, `1` and `0` in a `bool`, the wrong truth value, an `int` rendering, the keyword in an inherited comment, named and digit-string kind suffixes, logical arrays and fields. |
| `layout/` | Wrapped initializers; formatter-wrapped declarations with the anchor on the name line, the type line, the line below, and alone above; backslash-continued `#define` values (a value on the continued line, a token split by the splice, a brace list closed on the continued line); `=` starting a continued line; two declarators; an anchor after an enum's closing brace; a SOURCE declaration continued with `&`. |
| `anchors/` | Duplicated anchors, an anchor list in one comment, commas inside a literal-as-read, anchors below and above a declaration, a neighbour's anchor, wrong and out-of-range cited lines, routine and module header grammar on a constant, a formatter-wrapped anchor, anchors on statement lines. |
