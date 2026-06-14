# C as a TARGET language (numerical ports)

Concrete conventions for rendering a numerical port into C, including the
Fortran-to-C semantic trap table. Project-specific decisions instantiated from this
file go to `target/CONVENTIONS.md`; this reference holds the rationale and the
defaults.

## Language pinning

- Pin the standard explicitly (C11 or C17 recommended; record it in the charter with
  the compiler and flags). No compiler extensions in portable code unless charter-listed.
- Warnings are errors. Recommended floor: `-Wall -Wextra -Wconversion -Wshadow
  -Wdouble-promotion -Werror` (tune the exact set once, in Phase 1, record it).
- Floating-point determinism flags are part of the build contract, not advice:
  disable fast-math entirely; pin FMA contraction off (`-ffp-contract=off`) on the
  deterministic reference build. Record the exact flags in the charter.

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
  double cw = 0.1;  /* src: oce_ale.F90:212 = 0.1 */
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
   target/CONVENTIONS.md);
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
  table in `target/CONVENTIONS.md`.
- Literal suffix policy follows the trap table below (T1): the rendered literal must
  have the same precision the SOURCE literal had in context.
- No implicit conversions that a warning flag can catch; `-Wconversion` stays on.

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

## Tooling baseline

Every tool here is a mechanized detector for a trap-table entry or failure mode: a
standing rule no sprint has to remember. Three rules make the toolchain safe rather
than fashionable: **pin versions and commit configs** (tool drift is config drift);
**allowlist-curate** every check (no tool that proposes improvements - a linter
pushing modernization during a literal port is failure mode B1 automated); **record
each tool in target/CONVENTIONS.md** with its enforcement role, and per the
seeded-bug rule, demonstrate each CI job failing once before trusting it.

### Format and lint
| Tool | Role | Discipline |
|---|---|---|
| clang-format | Zero-debate layout; config committed at repo root | Pin the version: output drifts between releases, and a version bump must never mix formatting noise into real diffs |
| clang-tidy | `readability-identifier-naming` enforces the naming map mechanically; `bugprone-*` and `clang-analyzer-*` catch real defects | Allowlist only, never the default set; all `modernize-*` and rewrite-style `readability-*` checks stay off |

### Runtime sanitizers (diagnostic builds, fast rig, separate CI jobs)
| Tool | Catches | Mechanizes |
|---|---|---|
| AddressSanitizer | Out-of-bounds reads/writes | L4 (wrong stride/extent) and cross-module sizing bugs, at first touch |
| UBSan | Signed-integer overflow, shift UB | T13 (Fortran wrapped; C is undefined) |
| valgrind memcheck (or MSan) | Uninitialized reads | T8 (SOURCE build zero-inits; C stack is garbage) |

Sanitizer builds are diagnostic builds only: acceptance comparisons run exclusively
on the pinned-flag deterministic build. Run sanitizers on the fast rig in CI so every
commit gets a pass cheaply.

### Methodology hooks
- **Coverage (gcov / llvm-cov)**, both sides: live-subset determination at Phase 0
  (SOURCE side), and the vacuity check in module review ("does the gating run
  actually exercise this module?") becomes a measurement instead of a judgment.
- **compile_commands.json** (build-system export or `bear`): prerequisite for all
  clang tooling; set up on day one.

### Deliberately skipped
Heavyweight floating-point analysis tools (the ladder owns that ground),
include-what-you-use (noise during a port), and anything that suggests
restructuring.

## The Fortran-to-C semantic trap table

Constructs that compile cleanly in C and silently mean something else. Consult
DURING translation; each entry names the mandatory rendering. IDs are stable so
conformance scripts, reviews, and LESSONS can cite them.

| ID | SOURCE construct (Fortran) | The trap | Mandatory rendering in C |
|---|---|---|---|
| T1 | Real literals: `0.1` is SINGLE precision by default; `0.1d0` is double | C's `0.1` is double; naive copying silently *raises* precision of single-precision SOURCE constants (and vice versa for `float` contexts), changing arithmetic | Render with the precision the literal had in SOURCE context: Fortran `0.1` (default real) into `0.1f` if the expression was single; `0.1d0` into `0.1`. Decide per literal, cite the SOURCE line |
| T2 | `MOD(a,b)` / `MODULO(a,b)` | Two different functions: `MOD` truncates (sign of a), `MODULO` floors (sign of b); C `%` matches `MOD` only, and only since C99 for negatives | `MOD` for integers: `%`. `MODULO`: explicit floored-modulo helper. For reals: `fmod` matches `MOD`; write a helper for `MODULO` |
| T3 | `a ** b` | No C operator; `pow()` for integer exponents loses bit-equivalence vs repeated multiplication and is slower | Integer constant exponents: explicit multiplication (`x*x`, `x*x*x`). Variable/real exponents: `pow`, noted, since the SOURCE compiler also calls a pow routine there. Record the policy boundary |
| T4 | `SIGN(a,b)` | Transfers the sign of b onto |a|; handles signed zero in IEEE mode; hand-rolled ternaries get zero and NaN cases wrong | `copysign(a,b)` for reals (after verifying the SOURCE build's signed-zero behavior); explicit helper for integers |
| T5 | `MAX`/`MIN` | C's `fmax`/`fmin` have IEEE NaN-absorbing semantics (return the non-NaN operand); a Fortran compiler's `MAX` may propagate NaN. Divergence appears exactly when something is already wrong | Pick the rendering that matches the SOURCE build's observed behavior; record it once; use one helper everywhere so the choice is changeable in one place |
| T6 | Initialized locals: `integer :: n = 0` inside a procedure | Implies SAVE in Fortran: initialized ONCE, value persists across calls. C auto locals re-initialize every call | Render as `static` with the initializer, with a provenance comment noting the implied SAVE. Audit every initialized local for this |
| T7 | `SAVE` variables / module variables holding state across calls | Hidden persistent state that the de-globalization transform must not lose | Fields of the context struct (or file-scope `static` if charter-listed), never re-initialized per call |
| T8 | Uninitialized variables | Some Fortran builds zero-initialize (a flag, not the standard); C stack variables hold garbage | Match the reference build's semantics explicitly: if it ran with zero-init flags, initialize explicitly to zero; record the decision in the charter. Never leave it to luck |
| T9 | Array arguments, `INTENT` aliasing rules | Fortran forbids aliased dummy arguments, compilers optimize accordingly; C pointers may alias. `restrict` reproduces Fortran's assumption but turns any port bug into undefined behavior | No `restrict` during the port (roughly performance-neutral for a literal port). Revisit in the performance phase under the regression gate |
| T10 | Column-major storage, 1-based and arbitrary lower bounds | The classic pair; covered by the charter's mechanical transforms | All indexing through the central helpers; stride from the allocation shape; conformance-checked (failure mode L4) |
| T11 | Array syntax: `a = b + c`, sections `a(2:n)`, `WHERE`, elemental procedures | Must become explicit loops; loop ORDER and association change the floating-point result | Loop order follows storage order the SOURCE compiler effectively used; preserve the SOURCE's association and parenthesization exactly; never fuse or split loops during translation |
| T12 | Parentheses in floating-point expressions | Fortran compilers may reassociate except across parentheses; C honors parentheses but flags like fast-math break everything | Copy expressions token-for-token including parentheses; forbid fast-math; pin `-ffp-contract=off` on the deterministic build |
| T13 | Integer division and overflow | Fortran integer division truncates toward zero (= C since C99). But signed overflow: typically wraps in practice under Fortran compilers, UNDEFINED in C | Division: direct. Any computation that can overflow: render with explicit width and defined semantics (unsigned arithmetic or checked helpers); flag suspicious sites with provenance comments |
| T14 | `LOGICAL` | Fortran logicals are full words with compiler-defined representations; binary I/O and equivalence tricks leak the representation | `bool`/`int` for logic is fine; any code that reads/writes logicals as bytes or overlays them follows the SOURCE representation, documented at the site |
| T15 | `CHARACTER(LEN=n)` fixed-width, blank-padded | C strings are NUL-terminated; comparisons and assignments differ (padding vs termination) | Fixed-size char arrays with explicit-length helpers (pad-aware compare/copy); never `strcmp`/`strcpy` on ported character data |
| T16 | `COMMON` / `EQUIVALENCE` | Memory overlay semantics; "same bytes, two names." A naive struct-per-name rendering silently breaks the overlay | COMMON blocks: one struct, one definition, shared by reference. EQUIVALENCE: explicit unions with a provenance comment, or charter-listed exception if the overlay is dead in the pinned configuration |
| T17 | Intrinsics: `EPSILON`, `HUGE`, `TINY`, `NINT`, `INT`, `ANINT`, `AINT` | Each has an exact C counterpart that is easy to get *almost* right: `NINT` rounds half away from zero (`lround`), `INT` truncates, `AINT`/`ANINT` are `trunc`/`round`; `EPSILON` is `DBL_EPSILON` only for the matching kind | Use the exact mapping table; never approximate a rounding intrinsic with casts plus arithmetic |
| T18 | `GOTO`, computed GOTO, arithmetic IF, alternate returns | Restructuring control flow "more cleanly" is improvement (B1) and changes paths | Render control flow literally (C `goto` with the SOURCE labels is acceptable and traceable); restructuring is post-port work |
| T19 | List-directed and formatted I/O | Output formatting differs subtly; chasing byte-equal text wastes time, and I/O is often a charter-named exception anyway | Follow the charter: if I/O is a named exception, route through the port's I/O layer; if not, compare numerically, not textually |
| T20 | Implicit typing (`IMPLICIT NONE` absent) | Variables typed by first letter (I-N integer); a missed declaration silently changes a type | Before translating any file without `IMPLICIT NONE`, build the complete explicit type list for it and record it; render everything explicitly typed |
| T21 | Integer `parameter` used as an array dimension or to define another parameter (`integer, parameter :: n = 30`) | A C `static const int` is NOT a constant-expression: it cannot size an array or initialize another file-scope constant, so compile-time use breaks. The type/precision table's `int32_t` mapping is for integer VARIABLES, not compile-time parameters | Render integer `parameter`s as C `enum` constants (genuine `int` constant-expressions), value preserved; keep `int32_t` for integer variables |
| T22 | Derived `parameter` defined from other parameters (`real(p), parameter :: c = a*b`) | Two traps at once: C forbids referencing const-qualified vars in a file-scope initializer, AND the intermediate's KIND follows its operands - two double parameters form a DOUBLE product, so substituting their default-single literal spellings naively computes it in single and differs in the low bits | Substitute each referent's kind-correct literal and form every intermediate in the operands' kind (a double-precision operand widens before the operation); verify against the SOURCE with the R0 constant bit-equivalence check |
| T23 | Module variable with an initializer but NOT `parameter` (`real(p) :: x = 0.5`), even when never written in the live subset | Rendering it `const` because "nothing modifies it" asserts an immutability the SOURCE never declares - failure mode B1 (a silent improvement a reviewer must flag) | Render as mutable module state (a context-struct field, T7), never `static const`; const-ness is a SOURCE property (`parameter`), not an optimization to infer from observed non-mutation |

Grow the table: when a port bug traces to a language-pair semantics difference not
listed here, add the entry (with its LESSONS ID) in the same sprint - this table
is to the language pair what `failure-modes.md` is to the methodology.
