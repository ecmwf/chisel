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
  ```
  Example:
  ```c
  double cw = 0.1;  /* src: source_unit.F90:212 = 0.1 */
  ```
  The constant anchor embeds the literal exactly as read from the SOURCE line. It
  is not decoration; it is the machine-checkable record that the line was read.
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

Anchors cite the PINNED SOURCE COMMIT, not the working tree: the verifier reads
the cited line via the pinned commit (e.g., `git show <source_commit>:<path>`), so
later instrumentation edits to `source/` can never shift line numbers under
existing anchors. For every anchor in the TARGET tree, the verifier checks:
1. the cited path and line exist in the pinned SOURCE commit;
2. for constant anchors: the cited SOURCE line (at the pinned commit) contains
   `<literal-as-read>` textually;
3. for constant anchors: the TARGET line carries the agreed rendering of that
   literal (per the type/precision table and trap T1 - e.g., Fortran `1.d-2`
   rendered as `1.0e-2`, with the equivalence table recorded in
   port/conventions/<source>-to-<target>.md);
4. every nontrivial constant definition in TARGET code has an anchor (coverage
   direction, so the check cannot be dodged by omitting anchors). General
   assignments in implementation files are not constants and are not anchor
   coverage gaps.
The methodology ships this verifier as `tools/conformance/verify-anchors.sh` (it reads
the pinned ref from `port/TRACE.yaml` meta `source_commit`, overridable via `SOURCE_PIN_REF`
or `--ref`); run it in CI and at every commit that adds anchored TARGET code. Any failure
is a CI failure. The verifier is sound because `source/` is pinned and read-only: anchors
cannot rot. This converts the citation directive from a
behavioral rule into a gate, and catches the wrong-constant class at commit time
instead of after a full-length run.

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
- **Index helpers**: all multi-dimensional and base-shifted indexing through the
  central helpers (inline functions or macros defined in one header). No ad-hoc
  index arithmetic at call sites - run `tools/conformance/check-index-helpers.sh`
  in CI and at every commit that adds translated array access. The detector skips
  array-size brackets in declarations, but still checks initializer expressions
  on declaration lines.
- **Allocation**: one allocation idiom (checked, typed, sized from the allocation
  shape recorded next to it). Strides always derive from the allocation shape.
- **Error handling**: pick one pattern (return codes with a check macro is the
  usual fit for ported numerical code) and use it everywhere.

## The Fortran-to-C semantic trap table

Constructs that compile cleanly in C and silently mean something else. Consult
DURING translation; each entry names the mandatory rendering. IDs are stable so
conformance scripts, reviews, and LESSONS can cite them.

| ID | SOURCE construct (Fortran) | The trap | Mandatory rendering in C |
|---|---|---|---|
| T1 | Real literals: `0.1` is SINGLE precision by default; `0.1d0` is double | C's `0.1` is double; naive copying silently *raises* precision of single-precision SOURCE constants (and vice versa for `float` contexts), changing arithmetic | Render with the precision the literal had in SOURCE context: Fortran `0.1` (default real) into `0.1f` if the expression was single; `0.1d0` into `0.1`. Decide per literal, cite the SOURCE line |
| T2 | `MOD(a,b)` / `MODULO(a,b)` | Two different functions: `MOD` truncates (sign of a), `MODULO` floors (sign of b); C `%` matches `MOD` only, and only since C99 for negatives | `MOD` for integers: `%`. `MODULO`: explicit floored-modulo helper. For reals: `fmod` matches `MOD`; write a helper for `MODULO` |
| T3 | `a ** b` | No C operator, and BOTH obvious renderings are wrong in a way that costs last bits. (a) For a small INTEGER LITERAL exponent the compiler does not expand left-to-right: it uses BINARY EXPONENTIATION, so `x**5` becomes `(x*x*x)*(x*x)` - i.e. `x**4 = (x*x)*(x*x)` then one more multiply - NOT `((((x*x)*x)*x)*x)`. Floating-point multiplication is not associative, so a naive product chain differs in the last bit. Measured: the left-to-right rendering produced a 1-ULP divergence in a single-precision build that was initially, and wrongly, attributed to "single-precision rounding" - it is not rounding, it is a different expression tree. (b) For an INTEGER VARIABLE exponent the compiler does NOT call `pow` either: it calls its own integer-power helpers (in the GNU toolchain `__powidf2` / `__powisf2`), doing repeated squaring on an integer count. Measured divergence from `powf` at exponent 5 in single precision | Reproduce the compiler's tree, and verify rather than assume for any exponent you have not personally checked: `n=2` -> `x*x`; `n=3` -> `x*x*x`; `n=4` -> `(x*x)*(x*x)`; `n=5` -> `(x*x*x)*(x*x)`. For an integer VARIABLE exponent, provide ONE shared helper implementing binary exponentiation (with a reciprocal for negative counts) and verify it bit-identical against the toolchain's integer-power helper across the exponent range in every precision - do not call `pow`. `pow()` is correct ONLY when the exponent is genuinely REAL. Disassemble or link-probe to confirm which lowering your compiler actually uses; the answer is a property of the toolchain, not of the standard |
| T4 | `SIGN(a,b)` | Transfers the sign of b onto \|a\|; handles signed zero in IEEE mode; hand-rolled ternaries get zero and NaN cases wrong | `copysign(a,b)` for reals; explicit helper for integers. For a mainstream same-vendor compiler pair this has been MEASURED to agree bit-for-bit across both precisions, including signed-zero and NaN operands - so `copysign` is the default rendering, not a candidate needing per-port justification. Re-probe (see below) only if your pair is unusual |
| T5 | `MAX`/`MIN` | C's `fmax`/`fmin` have IEEE NaN-absorbing semantics (return the non-NaN operand); real `MAX`/`MIN` DO diverge from them - this is measured for a mainstream same-vendor pair, not hypothetical, and it diverges on TWO axes, not one: NaN propagation AND signed zero (`MAX(-0.0, +0.0)` need not agree with `fmax(-0.0, +0.0)`). Signed zero is the axis usually forgotten, and unlike NaN it arises in code that is working perfectly well. This is the notable exception to the general rule that real-intrinsic renderings agree bit-for-bit | Do NOT reach for `fmax`/`fmin` reflexively - they are the wrong default here. Render to match the SOURCE build's MEASURED behavior on both axes, record the verdict once, and route every site through ONE helper so the choice is changeable in a single place |
| T6 | Initialized locals: `integer :: n = 0` inside a procedure | Implies SAVE in Fortran: initialized ONCE, value persists across calls. C auto locals re-initialize every call | Render as `static` with the initializer, with a provenance comment noting the implied SAVE. Audit every initialized local for this |
| T7 | `SAVE` variables / module variables holding state across calls | Hidden persistent state that the de-globalization transform must not lose | Fields of the context struct (or file-scope `static` if charter-listed), never re-initialized per call |
| T8 | Uninitialized variables | Some Fortran builds zero-initialize (a flag, not the standard); C stack variables hold garbage | Match the reference build's semantics explicitly: if it ran with zero-init flags, initialize explicitly to zero; record the decision in the charter. Never leave it to luck |
| T9 | Array arguments, `INTENT` aliasing rules | Fortran forbids aliased dummy arguments, compilers optimize accordingly; C pointers may alias. `restrict` reproduces Fortran's assumption but turns any port bug into undefined behavior | No `restrict` during the port (roughly performance-neutral for a literal port). Revisit in the performance phase under the regression gate |
| T10 | Column-major storage, 1-based and arbitrary lower bounds | The classic pair; covered by the charter's mechanical transforms | All indexing through the central helpers; stride from the allocation shape; conformance-checked (failure mode L4) |
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
| T22 | Derived `parameter` defined from other parameters (`real(p), parameter :: c = a*b`) | Two traps at once: C forbids referencing const-qualified vars in a file-scope initializer, AND the intermediate's KIND follows its operands - two double parameters form a DOUBLE product, so substituting their default-single literal spellings naively computes it in single and differs in the low bits | Substitute each referent's kind-correct literal and form every intermediate in the operands' kind (a double-precision operand widens before the operation); verify against the SOURCE with the R0 constant bit-equivalence check |
| T23 | Module variable with an initializer but NOT `parameter` (`real(p) :: x = 0.5`), even when never written in the live subset | Rendering it `const` because "nothing modifies it" asserts an immutability the SOURCE never declares - failure mode B1 (a silent improvement a reviewer must flag) | Render as mutable module state (a context-struct field, T7), never `static const`; const-ness is a SOURCE property (`parameter`), not an optimization to infer from observed non-mutation |
| T24 | A function-LOCAL variable declared mutable (`real(p) :: x`, not `parameter`) but assigned exactly once and never re-written in the routine | The sibling of T23, with the opposite resolution. T23 forbids `const` on MODULE STATE because that is shared - a producer elsewhere may write it. A closed-scope, write-once LOCAL has no such hazard, and the assertion is compiler-enforced: a wrong `const` is a build error, never a silent divergence | Render as C `const` (zero runtime effect; the write-once fact is local and machine-checked). Classify by SCOPE: module state goes to T23 (never `const`); a write-once local takes `const` faithfully. Render mutable if the local is ever reassigned |
| T25 | An intrinsic applied to a bare default-real (single) literal argument, e.g. `log(0.99)`, whose result flows into a double expression | A Fortran intrinsic's result KIND follows its ARGUMENT's kind: a default-real literal makes the intrinsic evaluate in SINGLE precision, then widen. Rendering the double intrinsic on a widened literal (`log((double)0.99f)`) silently *raises* precision the SOURCE never had - a T1 divergence a constants-only review misses, because the value lives in a runtime expression, not a named constant | Render the single-precision intrinsic on the float literal, then widen the RESULT (`(double)logf(0.99f)`); never the double intrinsic on a widened literal. An intrinsic on a double-kind argument (a `real(p)` variable) is correctly the double intrinsic. A capture-replay (R1) check catches the divergence; a constants (R0) check may not |
| T26 | `stop`/`error stop <msg>` (program termination) inside a guard, e.g. `if (x == 0.) stop 'singular'` | C has no exceptions; rendering it as a graceful return silently downgrades ABORT to a recoverable error (failure mode B1), and a unit test that asserts the return code bakes the deviation in so the gate cannot catch it - only a line-by-line review against SOURCE control flow does | Render as a C error-return code propagated to the caller (the error-handling idiom), AND require the CONSUMER to reproduce the SOURCE's program termination (abort on that code): a consumer that swallows the code and continues is a port bug. Register as a charter named exception (a behavioral departure), not a silent rendering choice |
| T27 | One buffer reinterpreted as multiple differently-shaped arrays - EQUIVALENCE/overlay (T16), or a work buffer reused and RESHAPED between calls by a driver | The column-major->row-major transform (T10) applied per-array is UNSOUND here: each view's independent row-major linearization disagrees on byte layout, so elements that alias in the SOURCE column-major storage no longer alias - per-unit tests pass while the composition corrupts (failure mode L9). A `union` of the differently-shaped arrays does NOT rescue it (the row-major members still disagree) | Preserve the SOURCE storage order for the aliased buffers: a charter-listed column-major carve-out in the central index helpers (every view's offset computed in SOURCE storage order), or one shared flat-index scheme used by all views. Make storage order a whole-subsystem decision taken BEFORE porting the first aliased routine; gate the composition end-to-end (validation-ladder.md) |
| T28 | Pseudo-random numbers: `random_number` / `random_seed` (the compiler's intrinsic PRNG) | The intrinsic generator is a SPECIFIC algorithm (e.g. modern gfortran's `xoshiro256**`), NOT interchangeable with the TARGET's library PRNG (C `rand()`): identical seeds produce DIFFERENT streams from the first draw, so any RNG-driven trajectory (optimizer, Monte-Carlo, sampler) diverges and a same-seed run is NOT reproducible across the languages | If reproducibility is required, REIMPLEMENT the SOURCE compiler's PRNG algorithm and its seed scrambling in the TARGET (it is deterministic and documented); otherwise record the RNG-stream difference as a KNOWN-DIVERGENCE and validate the stochastic code by DETERMINISTIC fixed-input differentials, never by comparing full stochastic runs (failure mode L10) |
| T29 | `SUBROUTINE` / `FUNCTION` positional argument order vs the `INTENT` declaration block order | Fortran dummy arguments are bound POSITIONALLY at the call site, in the order they appear in the `SUBROUTINE` / `FUNCTION` statement - NOT in the order they are declared in the dummy-declaration / `INTENT` block (which can differ). A C port that copies the param order from the declaration block silently swaps actuals, and a bit-identical twin can pass if the swapped args happen to carry the same type + the test inputs are symmetric in the swapped positions | Copy the C parameter order from the `SUBROUTINE` / `FUNCTION` statement line (the call signature), never the `INTENT` declaration block. The declaration block fixes const-ness (via `const` on the C param), never order. Verify with a twin whose inputs are pairwise DISTINCT in every forwarded position (injective inputs), so any swap is detectable |
| T30 | Array with explicit lower bound 0: `real :: a(0:N)` | Fortran index `n` in a `(0:U)` array maps to C 0-based slot `n` (the lower bound IS 0, so no shift). But the central index helper `idx1(i)` computes `i-1` (designed for 1-based arrays), so `a(n)` in SOURCE becomes `arr[idx1(n+1)]` in TARGET, NOT `arr[idx1(n)]`. The tell is to cross-check against the PRODUCER's own indexing: if the producer fills `a(j)` as `arr[idx1(j+1)]`, the consumer must match | For a `(0:U)` array, always `idx1(fortran_index + 1)`; only `(1:U)` / default-lower-bound arrays use `idx1(fortran_index)` directly. Cross-check every lb-0 array against its producer's indexing convention. Sweep a finding across structurally-identical siblings when one instance is caught |
| T31 | A dimension-aware binary I/O library called through both its Fortran and C bindings (classically HDF5: `h5sselect_hyperslab_f` / `h5dread_f` reading a multi-dimensional dataset) | The Fortran binding presents (and the C binding does NOT) dataset dimensions in REVERSED order: the Fortran wrapper internally reverses the hyperslab `start`/`count` and the memory-space extents to match Fortran column-major, so SOURCE code passes dims in Fortran-logical order and it works. The C API takes dims in the file's native (row-major) order. A C port that copies the SOURCE's dimension order verbatim selects a transposed/out-of-range hyperslab - it either aborts (extent overrun) or silently reads a transposed buffer. R0 tests on synthetic in-memory buffers MISS it; it surfaces only on the first real file read (often at assembly/whole-program bring-up) | Reproduce what the Fortran binding does implicitly: REVERSE the dimension order of `start`/`count` and the memory dataspace at the C I/O boundary (the reader wrapper), so the bytes land in the buffer in the SAME flat order the Fortran binding produced. Localize the reversal to the I/O wrapper; leave the callers' Fortran-logical dims faithful. Make the unit's R0 test read the REAL reference dataset (not a synthetic buffer) so the dimension contract is exercised before composition |
| T32 | A derived-type variable with `ALLOCATABLE` components, declared but not explicitly initialized: `TYPE(STATE) :: S` whose components are filled later by a loader (a `POINTER` component has the SAME hazard ONLY when the type default-initializes it `=> NULL()`; a plain pointer with no default init is undefined in Fortran too, so it is not this trap) | Fortran auto-initializes a derived-type variable's ALLOCATABLE components to UNALLOCATED by language rule; a loader that does `if (.not. allocated(x)) allocate(x)` relies on that. C gives a plain `struct` variable INDETERMINATE members, so the equivalent allocate-on-NULL path is skipped and the loader writes through a garbage pointer - a wild write that R0 stub tests (which never run the real allocate path) do not catch | Zero-initialize the struct at declaration (`state s = {0};`), the literal C analogue of Fortran's auto-UNALLOCATED contract - it nulls the members so the allocate-on-NULL path fires as the SOURCE intends. It is a faithful rendering of declaration semantics, not an added feature; do NOT add a constructor the SOURCE lacks. A structural R0 assertion that the struct is zero before the loader runs catches a regression |

Grow the table: when a port bug traces to a language-pair semantics difference not
listed here, add the entry (with its LESSONS ID) in the same sprint - this table
is to the language pair what `failure-modes.md` is to the methodology.

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
verdict table the gates can cite.

What such a probe typically shows, and why it is worth the day it costs:

- The large majority of real intrinsics agree BIT-FOR-BIT between a same-vendor Fortran and
  C compiler. That is the useful half - it retires a long list of "we should check this
  someday" doubts with evidence instead of assumption, and it means a later divergence can be
  attributed elsewhere with confidence.
- The exceptions are few, specific, and NOT the ones intuition nominates. `MAX`/`MIN`
  diverge; `SIGN` does not. Nothing about the documentation makes that obvious in advance.
- The verdict is bound to a toolchain. Record WHAT it was measured against (compiler
  identities, flags, and a content-derived identity for the runtime math libraries) alongside
  the table, or a later toolchain change silently invalidates it - see `failure-modes.md`
  B19. A parity table with no recorded binding is a guess with a timestamp.

The negative results are the durable output here. "These agree, measured, under this
toolchain" is what lets a later investigation skip an entire class of suspect - which is
worth more than the two or three divergences the probe also finds.

