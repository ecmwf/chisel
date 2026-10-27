<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Fortran to C - the language-pair rulebook

How a Fortran SOURCE construct becomes C: the translation rules and the semantic
trap table. This is the **pair** rulebook - everything here is about rendering
Fortran *into* C. C-the-language guidance that is independent of the SOURCE (standard
pinning, formatter, linter, sanitizers, build flags) lives in `../langs/c.md`; reading
gotchas of Fortran as a SOURCE live in `../langs/fortran.md`.

Project-specific decisions instantiated from this file go to `port/conventions/<source>-to-<target>.md`;
this reference holds the rationale and the defaults. Trap IDs (T1...) are stable so
conformance scripts, reviews, and LESSONS can cite them.

## Naming (default: preserve SOURCE names)

- SOURCE procedure and variable names are preserved, lowercased, with characters
  illegal in C sanitized by a fixed rule (record the rule; apply it by script).
- Fortran is case-insensitive; C is not. Normalize everything to lowercase BEFORE
  collision checking; any residual collision is resolved by a fixed suffix rule,
  recorded in the naming map, never ad hoc.
- Module-scoped names get the module name as prefix (`<module>_<name>`) when they
  enter C's single global namespace.
- File mapping: one SOURCE file to one `.c` file plus one `.h` interface, same stem,
  mirrored in `port/TRACE.yaml`.
- The naming map is a committed artifact (script or table in `tools/`), not a habit.

## Comment policy (C syntax for the two kinds)

- Provenance anchors, mandatory on every ported routine and every nontrivial
  constant. The grammar is strict so a script can parse it:
  ```c
  /* src: <path>:<line> */                      routine anchor
  /* src: <path>:<line> = <literal-as-read> */  constant anchor
  /* src: <path>:<line> (module <NAME>) */      module header anchor
  ```
  Example:
  ```c
  static const double cw = 0.1;  /* src: source_unit.F90:212 = 0.1_WP */
  ```
  The constant anchor quotes the SOURCE as read: one literal of the cited line,
  whole - with its exponent and kind suffix (`0.1_WP`, never `0.1`) - or the whole
  right-hand side of the cited statement. It sits on a line of the declaration it
  anchors, or alone on the line directly below it; on a comment line above the
  declaration it anchors nothing. The module header anchor cites a `MODULE`
  statement; on a constant it belongs only to that module's `<MODULE>_CTX_INIT`.
  An anchor is not decoration; it is the machine-checkable record that the line
  was read, and the pairing the anchor verifier compares by value.
- Inherited SOURCE comments are ported verbatim, marked untrusted:
  ```c
  /* [SOURCE COMMENT, UNVERIFIED] ... original text ... */
  ```
   STRING LITERALS are program output: preserve them byte-verbatim, since altering
   one would change what the program prints and corrupt reference comparisons.
  If a comment is noticed to contradict the code it annotates, upgrade the marker
  in the same sprint and log a LESSONS entry:
  ```c
  /* [SOURCE COMMENT, CONTRADICTS CODE - see L-00NN] ... original text ... */
  ```
- No new explanatory comments that paraphrase SOURCE intent. If something needs
  explaining, it goes in the plan or LESSONS with a file:line citation.

### The anchor verifier (tools/conformance/verify-anchors.sh)

The verifier reads the SOURCE at the import commit (`port/TRACE.yaml` meta `source_commit`, or
`SOURCE_PIN_REF` / `--ref`), never the working tree, so instrumentation added to `source/` later
cannot shift a line under an anchor. It compares values, not text; its full rules (grammar,
binding, verdicts) are the anchor-verifier corpus, `tools/conformance/seeded-bugs/verify-anchors/README.md`.
Over the TARGET tree it checks that:
1. every anchor cites an existing line of the pinned SOURCE and binds to a declaration as above;
2. each anchored TARGET constant renders the SOURCE entity of its cited statement whose name
   matches by the naming rule: the SOURCE name or `<module>_<name>`, case-insensitive;
   `<TYPE>_INIT` for a type's default initialization; `<MODULE>_CTX_INIT` for a module's context
   initializer. A name that maps to an entity of another statement is invalid-anchor; any other
   name no rule gives is listed in `port/conventions/anchors.yaml` (`names`), or the verdict is
   UNRELIABLE;
3. its value equals the SOURCE constant's bit for bit - type, kind, shape and value - in every
   precision build of `port/conventions/anchors.yaml` (`regimes`), gfortran evaluating the SOURCE
   and clang the TARGET. No literal-equivalence table is needed: `1.d-2` rendered `1.0e-2` is the
   same bits. A value the SOURCE sets only at run time is UNVERIFIED, never a pass, and an anchor
   on a TARGET statement may cite only such a value: a SOURCE constant (a PARAMETER, an
   initializer, DATA) is rendered as a declared TARGET constant, so citing one from a statement
   is invalid-anchor;
4. every comparable TARGET constant carries a constant anchor: an object of numbers (every leaf a
   number or bool, a pointer only inside an aggregate) with an initializer at file scope, or at
   block scope `const` or `static` with a numeric literal in it; an enumerator with an explicit
   value; an object-like macro holding a numeric literal or a brace list, or one clang evaluates
   to a constant number or bool that the product defines - not one built only from C-library
   macros, keywords or `sizeof` (`EXIT_SUCCESS`, `DBL_EPSILON`). A `{0}` context initializer
   carries its module header anchor. The files listed in `port/declared-helpers.yaml` implement a
   language contract rather than a SOURCE statement: each of their comparable constants carries a
   `/* runtime-helper: <TRAP> - <language contract> */` anchor citing a trap row instead.

A header is judged inside each file that includes it; a header no TARGET file includes must be
self-contained, or its anchors and coverage are UNRELIABLE. The verifier exits 0 GREEN, 1 RED (a
mismatch, a broken anchor rule, a missing anchor) or 2 UNRELIABLE (anything it cannot judge), and
runs in CI and at every commit that adds anchored TARGET code. It is sound because `source/` is
pinned and read-only, and it turns the citation directive into a check that catches a wrong
constant at commit time instead of after a full-length run.

## Types and precision

- Numeric types are explicit: `double` for SOURCE double precision, `float` only
  where the SOURCE is genuinely single precision, fixed-width integer types
  (`int32_t`, `int64_t`) chosen to match SOURCE kinds. Record the kind-mapping
  table in `port/conventions/<source>-to-<target>.md`.
- Literal suffix policy follows the trap table below (T1): the rendered literal must
  have the same precision the SOURCE literal had in context.
- No implicit conversions that a warning flag can catch; `-Wconversion` stays on
  (the warning floor is set in `../langs/c.md`).

## Mechanical-surface idioms

- **Context structs** (de-globalized state): one struct per SOURCE module, fields
  preserving SOURCE names, passed as an explicit argument. Allocation/init in one
  place per struct.
- **Declaration-only modules** (a `module` with no executable statements: the data modules a
  large port has many of, ported early because everything depends on them). Their contract, stated
  here because the wrong renderings are the ones that come to mind first:
  - An integer `parameter` becomes a C `enum` constant (T21) - not `#define`, and not
    `static const int`, which is not a constant expression.
  - `<module>_CTX_INIT` carries exactly the SOURCE's explicit default initializers and nothing
    more. Never invent an `*_init()` constructor or `*_free()` destructor the SOURCE does not have
    (a module without executable statements has nothing to mirror), and never delete the
    initializer macro, which loses the SOURCE's defaults - the worse of the two errors.
  - T32 is narrower than "zero everything": it zero-initializes a derived type's ALLOCATABLE
    components (and POINTER components the type initializes `=> NULL()`), because Fortran
    initializes those. A plain scalar the SOURCE leaves uninitialized is undefined in Fortran too;
    zeroing it invents a state the SOURCE does not promise.
  - C has no partial aggregate initialization: naming any member zeroes the rest (C17 6.7.9p21).
    That is a property of C, not an invented value: record it as an accepted consequence, never
    as a defect to code around or a reason to delete the macro.
  - Prove kind fidelity with `_Generic` (type identity), never `sizeof` alone: a `sizeof` test
    accepts `int32_t` -> `uint32_t` and `bool` -> `unsigned char`, proving the width and nothing
    about the type.
  - Module data is not rendered as globals, so such a module owns no instance: implied SAVE and
    program-wide sharing come from whoever declares one. The module's evidence names what
    guarantees that this owner uses `<module>_CTX_INIT`; an unenforced assumption in a
    foundation module reaches every consumer of it.
- **Index helpers**: all multi-dimensional and base-shifted indexing through the
  central helpers, functions or macros defined in `idx.h` / `idx.c`. No ad-hoc
  index arithmetic at call sites - run `tools/conformance/check-index-helpers.sh`
  in CI and at every commit that adds translated array access. The detector reads
  the C through libclang, so it checks subscripts and pointer offsets (also those a
  macro produces), never a declaration's array size or a comment; every product
  file must parse cleanly (with the product's compile_commands.json, or with
  `-I` for every product directory), or the check is UNRELIABLE. A helper set other
  than the check's default is listed in `tools/conformance/project/index-helper-names.txt`;
  each listed name must be defined in `idx.h` / `idx.c`, and each of those two files must
  parse with only the other's directory on the include path (so no generated header).
- **Allocation**: one allocation idiom (checked, typed, sized from the allocation
  shape recorded next to it). Strides always derive from the allocation shape.
- **Error handling**: pick one pattern (return codes with a check macro is the
  usual fit for ported numerical code) and use it everywhere.
- **Cross-unit calls and seams**: a call into another unit goes through that unit's
  declaring header, never a caller-local prototype (T33); a called-but-unported routine
  is a bare shared declaration, never an inlined or partial port (T34); a hook seam is
  rendered only where the SOURCE unit has the hook calls (T35). Per-unit proofs cannot
  see a seam mismatch - these renderings are what make the build see it.

## The Fortran-to-C semantic trap table

Constructs that compile cleanly in C and silently mean something else. Consult
DURING translation; each entry names the mandatory rendering. IDs are stable so
conformance scripts, reviews, and LESSONS can cite them.

| ID | SOURCE construct (Fortran) | The trap | Mandatory rendering in C |
|---|---|---|---|
| T1 | Real literals: `0.1` is SINGLE precision by default; `0.1d0` is double | C's `0.1` is double; naive copying silently *raises* precision of single-precision SOURCE constants (and vice versa for `float` contexts), changing arithmetic | Render with the precision the literal had in SOURCE context: Fortran `0.1` (default real) into `0.1f` if the expression was single; `0.1d0` into `0.1`. Decide per literal, cite the SOURCE line |
| T2 | `MOD(a,b)` / `MODULO(a,b)` | Two different functions: `MOD` truncates (sign of a), `MODULO` floors (sign of b); C `%` matches `MOD` only, and only since C99 for negatives | `MOD` for integers: `%`. `MODULO`: explicit floored-modulo helper. For reals: `fmod` matches `MOD`; write a helper for `MODULO` |
| T3 | `a ** b` | C has no power operator, and both obvious renderings (`pow`, a left-to-right product) can be wrong in the last bits. What the SOURCE computes depends on the operands and on its build: (a) a small integer literal exponent is expanded inline from smaller powers by an optimizing build and passed to the integer-power helper by a non-optimizing one, and the two trees differ for some exponents; (b) an integer variable exponent calls the toolchain's integer-power helper, not `pow`; (c) when both operands are compile-time constants the compiler folds the power, and the fold need not equal either tree of (a) | (a) Reproduce the tree of the pinned SOURCE build, chosen by the optimization flags on that file's compile line: the inline tree, or a call to the shared helper of (b). (b) One shared binary-exponentiation helper, verified bit-identical to the toolchain's across the exponent range in every precision; `pow()` only for a real exponent. (c) The folded value as an exact literal in the SOURCE kind (T1), one per precision; the anchor still quotes the expression as read, and the anchor verifier compares the value. Tell the cases apart by the operands, not the statement, and verify rather than assume: "T3 in detail" below |
| T4 | `SIGN(a,b)` | Transfers the sign of b onto \|a\|; handles signed zero in IEEE mode; hand-rolled ternaries get zero and NaN cases wrong | `copysign(a,b)` for reals; explicit helper for integers. For a mainstream same-vendor compiler pair this has been MEASURED to agree bit-for-bit across both precisions, including signed-zero and NaN operands - so `copysign` is the default rendering, not a candidate needing per-port justification. Re-probe (see below) only if your pair is unusual |
| T5 | `MAX`/`MIN` | C's `fmax`/`fmin` have IEEE NaN-absorbing semantics (return the non-NaN operand); real `MAX`/`MIN` DO diverge from them - this is measured for a mainstream same-vendor pair, not hypothetical, and it diverges on TWO axes, not one: NaN propagation AND signed zero (`MAX(-0.0, +0.0)` need not agree with `fmax(-0.0, +0.0)`). Signed zero is the axis usually forgotten, and unlike NaN it arises in code that is working perfectly well. This is the notable exception to the general rule that real-intrinsic renderings agree bit-for-bit | Do NOT reach for `fmax`/`fmin` reflexively - they are the wrong default here. Render to match the SOURCE build's MEASURED behavior on both axes, record the verdict once, and route every site through ONE helper so the choice is changeable in a single place |
| T6 | Initialized locals: `integer :: n = 0` inside a procedure | Implies SAVE in Fortran: initialized ONCE, value persists across calls. C auto locals re-initialize every call | Render as `static` with the initializer, with a provenance comment noting the implied SAVE. Audit every initialized local for this |
| T7 | `SAVE` variables / module variables holding state across calls | Hidden persistent state that the de-globalization transform must not lose | Fields of the context struct (or file-scope `static` if charter-listed), never re-initialized per call |
| T8 | Uninitialized variables | Some Fortran builds zero-initialize (a flag, not the standard); C stack variables hold garbage | Match the reference build's semantics explicitly: if it ran with zero-init flags, initialize explicitly to zero; record the decision in the charter. Never leave it to luck. The SOURCE hygiene probe (`../langs/fortran.md`, "Running it with checks") shows which values the reference relies on |
| T9 | Array arguments, `INTENT` aliasing rules | Fortran forbids aliased dummy arguments, compilers optimize accordingly; C pointers may alias. `restrict` reproduces Fortran's assumption but turns any port bug into undefined behavior | No `restrict` during the port (roughly performance-neutral for a literal port). Revisit in the performance phase under the regression proof |
| T10 | Column-major storage, 1-based and arbitrary lower bounds | The classic pair; covered by the charter's mechanical transforms | All indexing through the central helpers; stride from the allocation shape; conformance-checked (failure mode N4) |
| T11 | Array syntax: `a = b + c`, sections `a(2:n)`, `WHERE`, elemental procedures | Must become explicit loops; loop ORDER and association change the floating-point result | Loop order follows storage order the SOURCE compiler effectively used; preserve the SOURCE's association and parenthesization exactly; never fuse or split loops during translation |
| T12 | Parentheses in floating-point expressions | Fortran compilers may reassociate except across parentheses; C honors parentheses but flags like fast-math break everything | Copy expressions token-for-token including parentheses; forbid fast-math; pin `-ffp-contract=off` on the deterministic build |
| T13 | Integer division and overflow | Fortran integer division truncates toward zero (= C since C99). But signed overflow: typically wraps in practice under Fortran compilers, UNDEFINED in C | Division: direct. Any computation that can overflow: render with explicit width and defined semantics (unsigned arithmetic or checked helpers); flag suspicious sites with provenance comments |
| T14 | `LOGICAL` | Fortran logicals are full words with compiler-defined representations; binary I/O and equivalence tricks leak the representation | `bool`/`int` for logic is fine; any code that reads/writes logicals as bytes or overlays them follows the SOURCE representation, documented at the site |
| T15 | `CHARACTER(LEN=n)` fixed-width, blank-padded | C strings are NUL-terminated; comparisons and assignments differ (padding vs termination). A faithful render is `char[N]` of EXACTLY N bytes (not N+1); under `-Wextra`, GCC/Clang's `-Wunterminated-string-initialization` then fires on the non-NUL initializer - tempting a worker to widen to `[N+1]` (which changes the representation) or to `// NOLINT` (which silences a detector) | Fixed-size `char[N]` arrays with explicit-length helpers (pad-aware `memcmp`/copy of N bytes); never `strcmp`/`strcpy` on ported character data. Quiet the warning with `__attribute__((nonstring))` (or the TARGET's equivalent): it AFFIRMS the field is a fixed non-NUL-terminated buffer and makes the compiler ENFORCE length-explicit use - a semantic choice stated at the site, not detector-silencing. Never widen the width or suppress the warning |
| T16 | `COMMON` / `EQUIVALENCE` | Memory overlay semantics; "same bytes, two names." A naive struct-per-name rendering silently breaks the overlay | COMMON blocks: one struct, one definition, shared by reference. EQUIVALENCE: explicit unions with a provenance comment, or charter-listed exception if the overlay is dead in the pinned configuration (but when the aliased views differ in SHAPE under a column-major->row-major transform, unions are unsound - see T27) |
| T17 | Intrinsics: `EPSILON`, `HUGE`, `TINY`, `NINT`, `INT`, `ANINT`, `AINT` | Each has an exact C counterpart that is easy to get *almost* right: `NINT` rounds half away from zero (`lround`), `INT` truncates, `AINT`/`ANINT` are `trunc`/`round`; `EPSILON` is `DBL_EPSILON` only for the matching kind | Use the exact mapping table; never approximate a rounding intrinsic with casts plus arithmetic |
| T18 | `GOTO`, computed GOTO, arithmetic IF, alternate returns | Restructuring control flow "more cleanly" is improvement (B1) and changes paths | Render control flow literally (C `goto` with the SOURCE labels is acceptable and traceable); restructuring is post-port work |
| T19 | List-directed and formatted I/O | Output formatting differs subtly; chasing byte-equal text wastes time, and I/O is often a charter-named exception anyway | Follow the charter: if I/O is a named exception, route through the port's I/O layer; if not, compare numerically, not textually |
| T20 | Implicit typing (`IMPLICIT NONE` absent) | Variables typed by first letter (I-N integer); a missed declaration silently changes a type | Before translating any file without `IMPLICIT NONE`, build the complete explicit type list for it and record it; render everything explicitly typed |
| T21 | Integer `parameter` used as an array dimension or to define another parameter (`integer, parameter :: n = 30`) | A C `static const int` is NOT a constant-expression: it cannot size an array or initialize another file-scope constant, so compile-time use breaks. The type/precision table's `int32_t` mapping is for integer VARIABLES, not compile-time parameters | Render integer `parameter`s as C `enum` constants (genuine `int` constant-expressions), value preserved; keep `int32_t` for integer variables |
| T22 | Derived `parameter` defined from other parameters (`real(p), parameter :: c = a*b`) | Two traps at once: C forbids referencing const-qualified vars in a file-scope initializer, AND the intermediate's KIND follows its operands - two double parameters form a DOUBLE product, so substituting their default-single literal spellings naively computes it in single and differs in the low bits | Substitute each referent's kind-correct literal and form every intermediate in the operands' kind (a double-precision operand widens before the operation); verify against the SOURCE with the R0 constant bit-equivalence check. A `**` in the definition is a constant power: render it per T3 (c), not as a product |
| T23 | Module variable with an initializer but NOT `parameter` (`real(p) :: x = 0.5`), even when never written in the live subset | Rendering it `const` because "nothing modifies it" asserts an immutability the SOURCE never declares - failure mode B1 (a silent improvement a reviewer must flag) | Render as mutable module state (a context-struct field, T7), never `static const`; const-ness is a SOURCE property (`parameter`), not an optimization to infer from observed non-mutation |
| T24 | A function-LOCAL variable declared mutable (`real(p) :: x`, not `parameter`) but assigned exactly once and never re-written in the routine | The sibling of T23, with the opposite resolution. T23 forbids `const` on MODULE STATE because that is shared - a producer elsewhere may write it. A closed-scope, write-once LOCAL has no such hazard, and the assertion is compiler-enforced: a wrong `const` is a build error, never a silent divergence | Render as C `const` (zero runtime effect; the write-once fact is local and machine-checked). Classify by SCOPE: module state goes to T23 (never `const`); a write-once local takes `const` faithfully. Render mutable if the local is ever reassigned |
| T25 | An intrinsic applied to a bare default-real (single) literal argument, e.g. `log(0.99)`, whose result flows into a double expression | A Fortran intrinsic's result KIND follows its ARGUMENT's kind: a default-real literal makes the intrinsic evaluate in SINGLE precision, then widen. Rendering the double intrinsic on a widened literal (`log((double)0.99f)`) silently *raises* precision the SOURCE never had - a T1 divergence a constants-only review misses, because the value lives in a runtime expression, not a named constant | Render the single-precision intrinsic on the float literal, then widen the RESULT (`(double)logf(0.99f)`); never the double intrinsic on a widened literal. An intrinsic on a double-kind argument (a `real(p)` variable) is correctly the double intrinsic. A capture-replay (R1) check catches the divergence; a constants (R0) check may not |
| T26 | `stop`/`error stop <msg>` (program termination) inside a guard, e.g. `if (x == 0.) stop 'singular'` | C has no exceptions; rendering it as a graceful return silently downgrades ABORT to a recoverable error (failure mode B1), and a unit test that asserts the return code bakes the deviation in so the proof cannot catch it - only a line-by-line review against SOURCE control flow does | Render as a C error-return code propagated to the caller (the error-handling idiom), AND require the CONSUMER to reproduce the SOURCE's program termination (abort on that code): a consumer that swallows the code and continues is a port bug. Register as a charter named exception (a behavioral departure), not a silent rendering choice |
| T27 | One buffer reinterpreted as multiple differently-shaped arrays - EQUIVALENCE/overlay (T16), or a work buffer reused and RESHAPED between calls by a driver | The column-major->row-major transform (T10) applied per-array is UNSOUND here: each view's independent row-major linearization disagrees on byte layout, so elements that alias in the SOURCE column-major storage no longer alias - per-unit tests pass while the composition corrupts (failure mode N9). A `union` of the differently-shaped arrays does NOT rescue it (the row-major members still disagree) | Preserve the SOURCE storage order for the aliased buffers: a charter-listed column-major carve-out in the central index helpers (every view's offset computed in SOURCE storage order), or one shared flat-index scheme used by all views. Make storage order a whole-subsystem decision taken BEFORE porting the first aliased routine; prove the composition end-to-end (code-port `references/validation-ladder.md`, "Rules of thumb") |
| T28 | Pseudo-random numbers: `random_number` / `random_seed` (the compiler's intrinsic PRNG) | The intrinsic generator is a SPECIFIC algorithm (e.g. modern gfortran's `xoshiro256**`), NOT interchangeable with the TARGET's library PRNG (C `rand()`): identical seeds produce DIFFERENT streams from the first draw, so any RNG-driven trajectory (optimizer, Monte-Carlo, sampler) diverges and a same-seed run is NOT reproducible across the languages | If reproducibility is required, REIMPLEMENT the SOURCE compiler's PRNG algorithm and its seed scrambling in the TARGET (it is deterministic and documented); otherwise record the RNG-stream difference as a KNOWN-DIVERGENCE and validate the stochastic code by DETERMINISTIC fixed-input differentials, never by comparing full stochastic runs (failure mode N10) |
| T29 | `SUBROUTINE` / `FUNCTION` positional argument order vs the `INTENT` declaration block order | Fortran dummy arguments are bound POSITIONALLY at the call site, in the order they appear in the `SUBROUTINE` / `FUNCTION` statement - NOT in the order they are declared in the dummy-declaration / `INTENT` block (which can differ). A C port that copies the param order from the declaration block silently swaps actuals, and a bit-identical twin can pass if the swapped args happen to carry the same type + the test inputs are symmetric in the swapped positions | Copy the C parameter order from the `SUBROUTINE` / `FUNCTION` statement line (the call signature), never the `INTENT` declaration block. The declaration block fixes const-ness (via `const` on the C param), never order. Verify with a twin whose inputs are pairwise DISTINCT in every forwarded position (injective inputs), so any swap is detectable |
| T30 | Array with explicit lower bound 0: `real :: a(0:N)` | Fortran index `n` in a `(0:U)` array maps to C 0-based slot `n` (the lower bound IS 0, so no shift). But the central index helper `idx1(i)` computes `i-1` (designed for 1-based arrays), so `a(n)` in SOURCE becomes `arr[idx1(n+1)]` in TARGET, NOT `arr[idx1(n)]`. The tell is to cross-check against the PRODUCER's own indexing: if the producer fills `a(j)` as `arr[idx1(j+1)]`, the consumer must match | For a `(0:U)` array, always `idx1(fortran_index + 1)`; only `(1:U)` / default-lower-bound arrays use `idx1(fortran_index)` directly. Cross-check every lb-0 array against its producer's indexing convention. Sweep a finding across structurally-identical siblings when one instance is caught |
| T31 | A dimension-aware binary I/O library called through both its Fortran and C bindings (classically HDF5: `h5sselect_hyperslab_f` / `h5dread_f` reading a multi-dimensional dataset) | The Fortran binding presents (and the C binding does NOT) dataset dimensions in REVERSED order: the Fortran wrapper internally reverses the hyperslab `start`/`count` and the memory-space extents to match Fortran column-major, so SOURCE code passes dims in Fortran-logical order and it works. The C API takes dims in the file's native (row-major) order. A C port that copies the SOURCE's dimension order verbatim selects a transposed/out-of-range hyperslab - it either aborts (extent overrun) or silently reads a transposed buffer. R0 tests on synthetic in-memory buffers MISS it; it surfaces only on the first real file read (often at assembly/whole-program bring-up) | Reproduce what the Fortran binding does implicitly: REVERSE the dimension order of `start`/`count` and the memory dataspace at the C I/O boundary (the reader wrapper), so the bytes land in the buffer in the SAME flat order the Fortran binding produced. Localize the reversal to the I/O wrapper; leave the callers' Fortran-logical dims faithful. Make the unit's R0 test read the REAL reference dataset (not a synthetic buffer) so the dimension contract is exercised before composition |
| T32 | A derived-type variable with `ALLOCATABLE` components, declared but not explicitly initialized: `TYPE(STATE) :: S` whose components are filled later by a loader (a `POINTER` component has the SAME hazard ONLY when the type default-initializes it `=> NULL()`; a plain pointer with no default init is undefined in Fortran too, so it is not this trap) | Fortran auto-initializes a derived-type variable's ALLOCATABLE components to UNALLOCATED by language rule; a loader that does `if (.not. allocated(x)) allocate(x)` relies on that. C gives a plain `struct` variable INDETERMINATE members, so the equivalent allocate-on-NULL path is skipped and the loader writes through a garbage pointer - a wild write that R0 stub tests (which never run the real allocate path) do not catch | Zero-initialize the struct at declaration (`state s = {0};`), the literal C analogue of Fortran's auto-UNALLOCATED contract - it nulls the members so the allocate-on-NULL path fires as the SOURCE intends. It is a faithful rendering of declaration semantics, not an added feature; do NOT add a constructor the SOURCE lacks. A structural R0 assertion that the struct is zero before the loader runs catches a regression |
| T33 | A call from one SOURCE unit to a procedure defined in ANOTHER unit (a `CALL` or function reference across files/modules) | Where the SOURCE has an explicit interface (a module procedure reached by `USE`, an interface block), the Fortran compiler checks every call against it. C checks a call only against the prototype in scope in the CALLER's translation unit, and separate compilation never compares that prototype with the callee's definition. A caller that writes its OWN prototype - typically from the SOURCE interface, while the callee is still unported - links cleanly against a definition that differs in arity, pointer level or qualifiers: undefined behavior no per-unit proof sees. Unit tests hide it: each mocks the callee with the CALLER's view, so every unit is self-consistent and the set is mutually inconsistent. Observed: once every unit had landed, the whole program linked while caller-callee seams disagreed with the callee's definition | Every cross-unit call goes through the callee's DECLARING HEADER (`#include "<callee-unit>.h"`); a caller NEVER declares its own prototype for a ported routine. The callee's `.c` includes the same header (a missing-prototype warning such as `-Wmissing-prototypes` makes that mandatory), so the strict-warnings build checks definition and every call site against ONE declaration. Test mocks are compiled against that header too, so a mock that drifts from the real ABI fails to compile. Mechanized: `tools/build-checks/check-prototypes.py` parses every translation unit of the build's compilation database and requires one type for every external function and variable, and no function declared inside a `.c` file without its body (`../langs/c.md`, "Build checks") |
| T34 | A call to a SOURCE routine that is not ported (its unit not yet translated or not yet landed when the caller is ported) | Both tempting renderings create an UNREVIEWED second port surface: INLINING the callee's body into the caller, or PARTIAL-PORTING it inside the caller's unit. Either invites simplification across the boundary (failure mode B1), and the caller's test then mocks the partial body, so whatever it dropped is never exercised. Observed: a partial port silently dropped a SOURCE assignment, and the test mocking that partial body stayed green | Render a BARE SEAM: ONE shared declaration of the callee, no body, with the SOURCE interface's exact signature (order per T29), placed in the header the callee's own unit will own (its file-mapping stem), so every caller includes it (T33) and the callee's eventual port replaces that header without touching a call site. Anchor the declaration to the SOURCE DEFINITION with the routine anchor (`/* src: <path>:<line> */`); the unported status lives in the callee's TRACE row, not in a product comment (no time-bound markers - comment policy). Tests mock the seam against that declaration. Never a body, never an inlined copy, never a caller-local declaration. If more than one piece in a wave calls the same unported routine, its seam header is a shared surface - hoist it before dispatch (code-port `references/parallel-phase-2.md`, step 1b) |
| T35 | Profiling/tracing hook calls the SOURCE wraps around SOME routine bodies (an entry/exit hook pair, typically switched by a global flag) | The port's convention renders such hooks as guarded seams, and it is tempting to apply that convention to EVERY routine. In a unit whose SOURCE has no hook calls, the seam adds a flag parameter (the de-globalized switch), an include, and calls the SOURCE never had - changing the routine's signature and ABI: an unauthorized behavioral addition (failure mode B1) that every caller and mock then inherits | Before rendering a hook seam, search THIS SOURCE unit for the hook calls (every spelling the codebase uses). Render the guarded seam only where the SOURCE has the calls, at the same sites. No occurrence -> no seam, no flag parameter, no include: the TARGET signature's arity follows the SOURCE (T29), and the ABSENCE of a hook is as load-bearing as its presence |

Grow the table: when a port bug traces to a language-pair semantics difference not
listed here, add the entry (with its LESSONS ID) in the same sprint - this table
is to the language pair what code-port's `references/failure-modes.md` is to the methodology.

### T3 in detail: `a ** b`

**(a) A small integer literal exponent.** The compiler does not expand it left-to-right, and WHICH
tree it uses depends on the SOURCE build's optimization level. An optimized build expands it inline
from smaller powers, reusing `x*x`: `x**5` becomes `(x*x*x)*(x*x)` - `x**3` times `x**2` - NOT
`((((x*x)*x)*x)*x)`. Floating-point multiplication is not associative, so a naive product chain
differs in the last bit. Measured: the left-to-right rendering produced a 1-ULP divergence in a
single-precision build that was initially, and wrongly, attributed to "single-precision rounding" -
it is not rounding, it is a different expression tree. Without that expansion the literal is passed
as the count to the integer-power helper of (b), which squares from the low bit up: `x**5` becomes
`x*((x*x)*(x*x))` - `x**4` then one more multiply - a third tree, neither the inline one nor the
left-to-right chain.

Measured (GNU Fortran, base read at run time):

- `-O1`, `-O2` and `-O3` inlined every literal probed (n=2..16; -1, -2, -3, -5); `-O0`, `-Og` and
  `-Os` called the helper for all of them except `x**2` (`x*x`) and `x**(-1)` (`1/x`).
- The inline and helper trees agreed bit-for-bit for n=2, 3, 4, 7, 8, 16, -1, -2 and -3, and
  differed for n=5, 6, 9..15 and -5: by up to 2 ULP at n=5 and 3 ULP at n=6, in about a third of the
  bases probed at n=5 and about half at n=6, at about the same rate in both precisions - so an
  exponent that agrees proves nothing about the next one.
- Value-changing flags (`-ffast-math`, `-funsafe-math-optimizations`) moved the lowering again:
  `-O0` then inlined, `-O2` used the helper's tree for n=5, and some negative exponents matched
  neither tree - a build that uses them needs its own measurement.

For an inlining build, reproduce its tree: `n=2` -> `x*x`; `n=3` -> `x*x*x`; `n=4` ->
`(x*x)*(x*x)`; `n=5` -> `(x*x*x)*(x*x)`; measured further, `n=6` -> `(x*x*x)*(x*x*x)`, `n=7` ->
`(x*x*x)*((x*x)*(x*x))`, `n=8` -> `((x*x)*(x*x))*((x*x)*(x*x))`; a negative literal -> the reciprocal
of the positive tree. For a helper-calling build (`-O0`, `-Og`, `-Os` above), call the shared helper
of (b) with the literal as the count, as the SOURCE build does - do not hand-expand it; `x**2` and
`x**(-1)` stay `x*x` and `1/x`.

**(b) An integer variable exponent.** The compiler does NOT call `pow` either: it calls its own
integer-power helpers (in the GNU toolchain `__powidf2` / `__powisf2`), doing repeated squaring on an
integer count. Measured: a divergence from `powf` at exponent 5 in single precision. Provide ONE
shared helper implementing binary exponentiation (with a reciprocal for negative counts) and verify
it bit-identical against the toolchain's integer-power helper across the exponent range in every
precision - do not call `pow`. `pow()` is correct ONLY when the exponent is genuinely REAL.

**(c) Both operands compile-time constants.** A base that is a literal, a named constant or an
expression of them, raised to a literal or named-constant exponent - `REAL(WP), PARAMETER :: P =
1.1_WP**5`, or `C**5` with `C` a `PARAMETER` - is not evaluated at run time: the compiler FOLDS the
power, and the folded value need not equal either tree of (a). Measured (GNU Fortran): the fold
happens in the front end, so it is the same in a `PARAMETER` and in an executable statement and at
every optimization level probed, and it equalled the correctly rounded power in every case probed,
in both precisions, for integer and REAL exponents alike; the inline tree of (a) missed it by 1-2 ULP
in close to half the cases probed with n=3..5 - `1.1**5` in both precisions, `0.9**5` in single
only, so one agreeing case proves nothing. Only n=2 agrees by construction (`x*x` is one rounding).
Writing the tree as a C constant expression does not help: the C compiler folds it one rounded
multiply at a time, the same bits as at run time. libm `pow` agreed in every case probed, but it is
not required to be correctly rounded, so that is one library's behaviour, not a guarantee.

Reproduce the folded VALUE, not a tree: obtain it from the SOURCE compiler by printing its bit
pattern, and render it as an exact literal - a hex-float, exact by the C standard, or a round-trip
decimal verified bit-identical - in the SOURCE kind (T1). A build compiled in two precisions needs
each precision's own fold: the single fold is not the double fold rounded to single (measured: they
differed in most cases probed). The constant anchor still quotes the SOURCE expression as read
(`/* src: <path>:<line> = 1.1_WP**5 */`), never the folded value, which is not on the SOURCE line;
the anchor verifier compares the TARGET constant with the SOURCE compiler's fold, bit for bit, in
every precision build. Keep an expression instead only if it is verified bit-identical to the fold
in every precision - judge it by its value, not its tree.

**Telling the cases apart, and checking.** Tell them apart by the OPERANDS, not the statement: a
constant base with a constant exponent folds wherever it appears; if either operand is a variable
the power is evaluated at run time and (a), (b) or `pow` applies as above, even when the other
operand is a named constant. Read the effective flags on the file's compile line, verify rather
than assume for any exponent you have not personally checked, and disassemble, link-probe or print
the bits to confirm which lowering - or fold - your compiler actually uses; the answer is a property
of the toolchain and its flags, not of the standard.

## Which C tool catches which trap
The tools and how to run them are in `../langs/c.md`, "Build checks" and "Runtime sanitizers".

| Tool | Traps and failure classes |
|---|---|
| `check-build-flags.py --objects` (the build contract; no fused multiply-add in an object) | T12, T1 |
| `check-sanitized.py`: AddressSanitizer | T10, T30, N4 (an index past its extent) |
| `check-sanitized.py`: UBSan | T13 (signed overflow wraps in practice under Fortran compilers and is undefined in C), T17 (`INT`/`NINT` of a value out of range; `float-cast-overflow`) |
| `check-sanitized.py --sanitizers memory`: MemorySanitizer | T8 (a SOURCE build may zero-initialize; a C stack variable holds garbage) |
| `check-prototypes.py` | T33 |

## Settle the intrinsic traps MECHANICALLY, once, at Phase 1

T4, T5 and T17 all have the same shape: an intrinsic whose C counterpart is *nearly* the
same function. The tempting approach is to resolve each one as translation reaches it. That
is the expensive order - the question resurfaces per routine, each answer is argued from
documentation rather than measured, and a wrong call surfaces later as a divergence hunt
where the intrinsic is the last thing suspected.

Settle them in one pass instead, during Phase 1, before any translation. Enumerate the
intrinsics the port actually uses, compile the SOURCE intrinsic and the candidate TARGET
rendering under the PINNED flags, feed both the same operands - including the awkward ones
(signed zeros, NaN, infinities, subnormals, the extremes of the type) - and compare RAW BIT
PATTERNS, not printed values or tolerances. Do it for every precision the build supports;
agreement in one precision does not imply agreement in another. Record the result as a
verdict table the proofs can cite.

What such a probe typically shows, and why it is worth the day it costs:

- The large majority of real intrinsics agree BIT-FOR-BIT between a same-vendor Fortran and
  C compiler. That is the useful half - it retires a long list of "we should check this
  someday" doubts with evidence instead of assumption, and it means a later divergence can be
  attributed elsewhere with confidence.
- The exceptions are few, specific, and NOT the ones intuition nominates. `MAX`/`MIN`
  diverge; `SIGN` does not. Nothing about the documentation makes that obvious in advance.
- The verdict is bound to a toolchain. Record WHAT it was measured against (compiler
  identities, flags, and a content-derived identity for the runtime math libraries) alongside
  the table, or a later toolchain change silently invalidates it - see code-port
  `references/failure-modes.md`, B19. A parity table with no recorded binding is a guess with a timestamp.

The negative results are the durable output here. "These agree, measured, under this
toolchain" is what lets a later investigation skip an entire class of suspect - which is
worth more than the two or three divergences the probe also finds.

