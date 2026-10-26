# SEEDED-BUG DEMONSTRATION - conformance/check-index-helpers

- Date: 2026-06-20 (re-seeded after the comparison-logic change: balanced-bracket extraction,
  `idx4` whitelisted, and the allow rule scoped to the multi-dimensional FLATTEN per the
  convention - single linear 1-D accesses no longer flagged); re-seeded 2026-10-26 when the
  detection moved from an awk subscript scanner to libclang's parse (see "Accesses read from
  libclang's parse" below - it supersedes the text-scanning details of the earlier sections).
- Detector: tools/conformance/check-index-helpers.sh (with lib/index_accesses.py and
  lib/product_tu.py)
- Failure class targeted: ad-hoc index arithmetic. An open-coded MULTI-DIMENSIONAL flatten -
  `a[i + j*nx]`, or the same offset added to a pointer - that does NOT go through a central index
  helper (CONVENTIONS section 6 / the charter index-base + storage-order transforms). A
  hand-written stride multiply silently reintroduces the storage-order/index-base assumptions the
  helpers exist to localize.
- Exit-code contract: 0 GREEN (no open-coded flatten), 1 RED (an ad-hoc stride flatten),
  2 UNRELIABLE (could not run, or a file does not parse cleanly).

The detector checks the shipped TRANSLATED TARGET `*.c`/`*.h` (a product `tests/` subtree is pruned -
test scaffolding is verified by its tests passing; a `tests`-NAMED file under `src/` is still
checked). It parses every file with libclang - the product's `compile_commands.json` entry when the
product root has one, otherwise `-std=c17` with `-I` for every directory of the product tree - and
judges every ACCESS after macro expansion: an array subscript, or pointer arithmetic (`p + e`,
`p - e`, `p += e`, also inside a dereference `*(p + e)`). An access is flagged when its index
contains a multiplication outside a helper call or helper macro expansion (`idx0`, `idx1`, `idx2`,
`idx3`, `idx4`, `idx1_stride`, `idxlb` by default, or the port's list - with all their arguments).
Allowed without a helper: literals, bare indices, an index +/- an offset, casts, dereferences -
anything with no multiply. Base-shift correctness of a bare 1-D access is the fidelity reviewer's
call (and, for proven code, already proven bit-identical by the proof); the mechanical net catches
the stride-multiply flatten. A declaration's array size is not an access, and comments are not
code. A file that does not parse cleanly is UNRELIABLE. With no product wired (no TARGET C) the
check skips (exit 0); the demonstration runs against fixtures.

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
(`^[0-9]+$`); OR a whole call to a declared helper (`^(<helper names>)\s*[(]` whose first `(`
balances at the final non-space char; names: see "Helper names" below); OR carries no binary
stride multiply (no
`[A-Za-z0-9_)]\s*\*`). Re-run this demonstration after any change to that allow rule or the
extraction logic (standing seeded-bug rule): tightening or widening it must keep the RED on the
open-coded flatten, and any form whose disposition changes must be shown moving across the
PRE/POST boundary on the fixture.

## Multi-line subscripts (hardened 2026-06-21, re-seeded 2026-10-25)

A subscript split across physical lines must not be skipped - a multi-line flatten could otherwise
hide. The first hardening FAILED CLOSED on every unbalanced `[`, which also refused a correct helper
call that a formatter's column limit had wrapped, forcing either an over-long line or a waiver. The
extractor now JOINS the following lines (comments and string literals stripped, the continuation's
indentation collapsed to one space) until the bracket balances, and checks the joined subscript as
one unit, reported at the line that opens it:

- Fixture `wrapped_flatten.c`: `z[i +` / `j * nx] = 0.0;` - RED, exit 1,
  `[FAIL] wrapped_flatten.c:3: ad-hoc subscript '[i + j * nx]'`. The flatten is still caught.
- Fixture `wrapped_helper.c`: `z[idx2(nx, ny,` / `i, j)] = 0.0;` (and a three-line wrap with a
  comment inside) - GREEN, exit 0.
- Fixture `wrapped_then_flatten.c`: a wrapped helper call followed on the continuation line by
  `= w[i + j * nx];` - RED at line 4: text after the joined subscript is still scanned.
- Fixture `wrapped_decl.c`: `scalar_t buf[n *` / `m] = {0};` - GREEN: a wrapped declaration size is
  still a declaration.
- A subscript still open at end of file, or after 64 continuation lines (a stray `[`, e.g. in a
  character literal, must not join the rest of the file) - RED, exit 1, `subscript never closed
  before end of file` / `subscript not closed within 64 continuation lines`, at the opening line.
  (Since 2026-10-26 the parser decides both: an unclosed subscript is a file that does not parse -
  UNRELIABLE, exit 2 - and a `[` in a character literal is not a subscript - GREEN.)
- Causal: the PRE-change detector reports `wrapped_helper.c` RED (`multi-line subscript - put it on
  one line to verify`) and `wrapped_flatten.c` RED only as an unreadable multi-line subscript; the
  change moves the helper call to GREEN while the flatten stays RED, now reported as the flatten.
- Executable form: `tools/tests/test-index-helpers.sh`.

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

## Helper names (re-seeded 2026-10-25)

- Detector change: the helper whitelist is no longer a fixed regex. The default set stays
  `idx0`..`idx4`, `idx1_stride`, `idxlb`; a port whose convention defines a different set lists it,
  one exact C identifier per line, in `tools/conformance/project/index-helper-names.txt` (project
  layer, or `$INDEX_HELPER_NAMES`), and that list REPLACES the default. Every listed name must be
  DEFINED in the central helper header/source (`idx.h` / `idx.c`) among the checked files. That is
  decided from a libclang parse of each central file as compiled with no command-line macros
  (`lib/index_helper_defs.py`), never from its text: a name counts only for a file-scope
  `FUNCTION_DECL` (a definition or a prototype) or `MACRO_DEFINITION` of exactly that name in that
  file. Calls, comments and inactive `#if` branches never produce one, and a declaration in another
  (included) file does not count. A line that is not a C identifier (e.g. a pattern `idx[0-9]+`), a
  list naming no helper, an `INDEX_HELPER_NAMES` path that cannot be read, a listed name with no
  central definition, a central file that does not parse cleanly on its own (a call to an
  undeclared function is an error), or a missing python3/libclang is UNRELIABLE (exit 2). The
  default set is not cross-checked this way (but see "Helpers are the central ones" below: the scan
  itself accepts only a helper the parse shows declared in idx.h / idx.c).
- Why: the helper set is a convention of the port, and the check is methodology layer (replaced on
  sync), so a port could only add a helper - another arity, say - by editing a file it does not own.
  Requiring the central definition keeps the list from whitelisting an arbitrary spelling, such as a
  local function that open-codes a flatten.
- Red: `helpers.c` with `a[idx5(n1, n2, n3, n4, i, j, k, l, 2 * m)]` and `b[idx2(n1, i, 2 * j)]`,
  default set - RED, `[FAIL] helpers.c:3: ad-hoc subscript '[idx5(...)]'`. With a list naming only
  `at2` and a helper header defining it: `idx2(...)` is RED and so is `at2x(n, i, 2 * j)` (exact
  names only), while `at2(...)` passes.
- Undefined names (`at2_only.c`, whose `at2(n, i, 2 * j)` call is GREEN only if `at2` is a real
  helper): with no helper header; with an `idx.c` that only CALLS `at2` (declared in another
  header); with an `idx.h` holding `long at2(...);` and `#define at2(...)` only inside comments;
  with an `idx.h` holding them only under `#if 0` / an unset `#ifdef`; with a header defining other
  helpers; or with `at2` defined in the calling file instead - UNRELIABLE, `listed helper(s) with no
  definition in the central helper header/source`. An `idx.c` calling an undeclared `at2`, or a
  central file with a syntax error - UNRELIABLE, `does not parse cleanly`. Without libclang -
  UNRELIABLE. The same holds in scan mode when the product tree has no `idx.h` defining the names.
- Green: `at2_only.c` with an `idx.h` defining `at2` as a function with a body, as a prototype, as
  a declarator wrapped onto its own line, or as a `#define` - GREEN, exit 0. `helpers.c` checked
  together with an `idx.h` defining the default set plus `idx5`, and a project list naming them -
  GREEN; in scan mode, a product whose `src/idx.h` defines the listed names - GREEN.
- Causal: against the PRE-change detector the project list is ignored (`helpers.c` stays RED), a
  malformed, empty or missing list is not detected (exit 1 instead of 2), and a listed name with no
  definition is accepted (exit 0, or 1 only for a different subscript). Against the intermediate
  line-regex recognizer, the bare call, the code-shaped comment and the `#if 0` prototype were each
  accepted as definitions (exit 0); the libclang parse moves all three to UNRELIABLE.
- Executable form: `tools/tests/test-index-helpers.sh`.

## Accesses read from libclang's parse (re-seeded 2026-10-26)

- Detector change: the awk subscript scanner is replaced by libclang's parse of each file
  (`lib/index_accesses.py`, files parsed by `lib/product_tu.py`). The allow rule is the same - a
  multiplication outside a helper is a flatten - but it is judged on the parse, after macro
  expansion: what an access is, what its index is, and whether a `*` is a multiply are the
  compiler's answers. Pointer arithmetic is an access. A flatten a macro produces is reported at
  the line that uses the macro, naming it. A file that does not parse cleanly (a syntax error, a
  missing header, a call to an undeclared function, an unknown flag in its compile command) is
  UNRELIABLE with its first error. The waiver format is unchanged; its content is the text the
  report quotes.
- Why: the text scanner had verified misses and false REDs that a parse answers exactly.

### Red proof (misses the text scanner had)

- `deref_flatten.c`: `*(a + i + j * n) = 0.0;` - RED, `[FAIL] deref_flatten.c:3: ad-hoc pointer
  offset 'a + i + j * n'`.
- `column_pointer.c`: `double *col = a + j * n;` - RED, `ad-hoc pointer offset 'a + j * n'`.
- `macro/use.c` including `layout.h` (`#define AT(a, i, j) (a)[(i) + (j) * n]`,
  `#define STRIDE(j) ((j) * n)`): `AT(z, i, j) = 1.0;` - RED at the use site,
  `use.c:5: ad-hoc subscript in the expansion of macro 'AT': 'AT(z, i, j)'`; `z[i + STRIDE(j)]` -
  RED, `use.c:6: ad-hoc subscript '[i + STRIDE(j)]' (the multiply comes from macro 'STRIDE')`.
- Scan mode over a product whose `compile_commands.json` defines `-DSTRIDE(j)=((j)*nx)`:
  `z[i + STRIDE(j)]` - RED, `step.c:3`. Without the database the file does not parse - UNRELIABLE.
- `unterminated.c` (a subscript never closed) and `undeclared.c` (a call to an undeclared
  function) - UNRELIABLE, exit 2, `does not parse cleanly`.

### Green proof (false REDs the text scanner had)

- `typedef_decl.c`: `real_wp t[3 * 4];` with `typedef double real_wp;` - GREEN (a declaration's
  size, whatever its type's name).
- `cast_index.c`: `b[(int)*p] = 1.0;` - GREEN (a cast and a dereference, not a multiply).
- `comment.c`: `// a[i*n] was the old layout` and `/* b[i*n] too */` above `a[i] = 0.0;` - GREEN.
- `pointer_ok.c`: `a + i`, `p += 1`, `*(p - 1)`, `end - a` - GREEN (pointer arithmetic with no
  stride).
- `stray_bracket.c`: `if (c == '[')` - GREEN (a character literal).

### Unchanged verdicts

- Every earlier fixture keeps its verdict and report (the wrapped flatten, the wrapped helper
  call, declarations, `_t` names, the helper-name list and its definition checks, scan mode,
  waivers), each now written as C that compiles. `fixtures/prefix_bad.c` takes its argument by
  value so it compiles; it stays RED, and `fixtures/decl_ok.c` stays GREEN.

### Causal proof

- The same test file against the PRE-change detector (`git archive origin/main tools`, the new
  `tools/tests/test-index-helpers.sh` run over it): the misses above are GREEN (exit 0), the false
  REDs are RED (exit 1), the unparseable files are RED or GREEN instead of UNRELIABLE, and the
  macro flatten is not reported at its use site. The only other difference on that test file is the
  waiver report's wording (`[WAIVE] m.c:3: ad-hoc subscript '[i + j * nx]'` where it printed
  `'[i + j * nx]'`); its other cases - with their fixtures rewritten as C that compiles - pass on
  both.
- The test file did not show everything the change moved. Beyond it: every product file must now
  parse, so any file that does not is UNRELIABLE where the text scanner gave a verdict; a subscript
  in a preprocessor branch the build skips, which the text scanner read, was not judged at all
  (fixed below, "Inactive preprocessor branches"); an access nested in a helper call's arguments is
  judged on its own, where the scanner allowed the whole call; arithmetic next to a helper call
  (`a[idx2(n, i, 2 * j) + 1]`) is GREEN, where the scanner saw the multiply in the arguments; and a
  Latin-1 string in a macro argument crashed the scan (fixed below, "Text that is not UTF-8").
- Executable form: `tools/tests/test-index-helpers.sh` (run by `tools/tests/run.sh`).

## Inactive preprocessor branches (re-seeded 2026-10-26)

- Detector change: a branch the parse skips has no AST, so it was never judged: `#if 0` or an
  `#ifdef` the build does not set could hold an open-coded flatten that another configuration
  compiles. The branches come from `clang_getAllSkippedRanges` (`product_tu.Unit.skipped`), and
  their tokens are judged: a subscript `x[...]`, or a dereference `*(...)` holding a `+` or `-`,
  whose brackets hold a binary `*` is RED, "in an inactive preprocessor branch". A `[` after a
  type is a declaration size and a `*` after a cast's parentheses a dereference, so neither is
  flagged; pointer arithmetic outside a dereference is not seen in a skipped branch. Brackets that
  do not close inside the branch cannot be judged: UNRELIABLE. A branch one unit skips and another
  compiles (a header included under two configurations) is judged once, on the parse of the unit
  that compiles it.
- Red: `inactive.c` - `#if 0` `a[i + j * n]` (line 4) and `#elif defined(A_FLAG_NOBODY_SETS)`
  `*(a + i + j * n)` (line 6) RED; the `#ifdef` branch with `double t[n * m];` and `a[(int)*p]`
  adds nothing (2 violations). `split_branch.c` (a subscript opened in `#if 0` and closed after
  `#endif`) - UNRELIABLE.
- Guard: `layout.h` included by `a.c` (`-DLAYOUT_FLAT`) and `b.c` (not) - one violation, at
  `layout.h:4`, from `a.c`'s parse.
- Causal: against the previous commit the first four cases are GREEN (exit 0); the guard passes on
  both.

## Helpers are the central ones; a one-index helper's argument is judged (re-seeded 2026-10-26)

- Detector change: a call or macro expansion counted as a helper by its NAME alone, so a local
  `static long idx2(...)` that open-codes the flatten, or a `#define idx2(...)` in the calling file,
  whitelisted every use, and every helper's arguments were exempt, so `idx0(i + j*n)` passed a
  flattened index straight through a one-index helper. Now a helper is a function whose declaration
  (`referenced`, or its first declaration) or a macro whose definition the parse places in `idx.h` /
  `idx.c`. The index argument (the first) of a one-index helper - `idx0`, `idx1`, `idxlb`,
  `idx1_stride`, or a listed helper with one parameter - is judged like a subscript; the other
  arguments of a helper (a multi-index helper's per-dimension indices, `idx1_stride`'s stride)
  stay the helper's.
- Red: `central/one_index.c` including `central/idx.h` - `a[idx0(i + j * n)]` (line 4,
  `(in the index argument of one-index helper 'idx0')`) and `a[idxlb(i + j * n, 1)]` (line 5) RED,
  `a[idx1_stride(k, nx * ny)]` and `a[idx2(n, i, 2 * j)]` not (2 violations). `central/shadow.c`
  (`static long idx2(...)`, `a[idx2(i, 2 * j, n)]`) and `central/local_macro.c` (`#define idx2`
  in the file) - RED.
- Green: `central_macro/use.c` with `#define idx2(...)` in its `idx.h` - GREEN. The fixtures of
  the helper-name cases include their central header (`full/idx.h`, `at2/idx.h`, each form's
  `idx.h`) instead of declaring the helpers locally, and keep their verdicts.
- Causal: against the previous commit the five red cases are GREEN (exit 0).

## A helper macro's arguments are the caller's (re-seeded 2026-10-26)

- Detector change: everything inside a helper macro's use was the helper's, so an access the caller
  wrote in its arguments (`t[idx2(nx, map[i + j*nx], k)]` with `idx2` a macro) passed, while the
  same access in a helper function's arguments was RED. Spans are now read with
  `clang_getFileLocation`: an expression the caller wrote in an argument has its own place in the
  file, one the body produces spans the whole use. A helper macro covers only an index it is used
  within, so an access written in its argument is judged on its own; a multiply written in a
  one-index helper macro's index argument is judged as for a helper function; the body, and a
  multi-index helper's arguments, stay the helper's.
- Red: `macro_args/use.c` (helper macros in `macro_args/idx.h`) - `t[idx2(nx, map[i + j * nx], k)]`
  RED at line 4, `[i + j * nx]`; `t[idxlb(i + j * nx, 1)]` RED at line 6; `t[idx2(nx, i, 2 * k)]`
  and `t[idxlb(i, 1)]` not (2 violations).
- Causal: against the previous commit the three cases are GREEN (exit 0).

## Only an integer, non-constant product is a stride (re-seeded 2026-10-26)

- Detector change: every binary `*` in an index counted, so a lookup `tab[(int)(x * inv_dx)]` (a
  floating product converted to an index) and a constant `a[3 * 4]` were RED. A multiply counts now
  only when its type is an integer type and clang's evaluator (`clang_Cursor_Evaluate`) cannot fold
  it to a constant. In an inactive branch, where no types exist, a product of two number literals
  or one with a floating literal does not count.
- Decision: a constant times an index (`z[2 * k]`, `z[2 * k + 1]`, `buf[i * sizeof(x)]`) stays RED.
  It is the flatten of interleaved data - a complex pair stored as two reals, a byte offset - with
  its stride written at the access instead of in a helper; a port that keeps such an access
  records it as a waiver.
- Red: `products.c` - `z[2 * k]` (line 6) and `buf[i * sizeof(x)]` (line 7) RED; `a[3 * 4]`,
  `tab[(int)(x * inv_dx)]`, `a[NX * 2]` and the same in an `#if 0` branch are not (2 violations).
- Causal: against the previous commit `products.c` has 7 violations instead of 2.

## An end pointer compared against is a bound (re-seeded 2026-10-26)

- Detector change: `p < a + n*m` (a loop's end pointer) was RED as a pointer offset. Pointer
  arithmetic whose value is only an operand of a comparison (`<`, `<=`, `>`, `>=`, `==`, `!=`,
  through parentheses and casts) addresses no element, so it is not an access.
- Decision, from the methodology's intent (the helpers own multi-dimensional addressing): a pointer
  that is formed and kept - a row or column pointer `rows[j] = data + j * n`, `double *col = a +
  j * n` - fixes the storage order, so it stays an access and RED; so does an end pointer stored in
  a variable, which the parse cannot tell from a row pointer (compare against the expression, or
  waive it).
- Red / green: `bounds.c` - `rows[j] = data + j * n` RED at line 7; `p < a + n * m` and
  `(q) != (a + (n * m))` not (1 violation).
- Causal: against the previous commit `bounds.c` has 3 violations.

## Every included file of the product tree (re-seeded 2026-10-26)

- Detector change: only the listed `*.c` / `*.h` were judged, so a `.inc` included into a function
  body hid its flatten. Every file under the product tree (the root, or with explicit files their
  directories) that a unit includes is judged now, except the central helper files and a product
  `tests/` directory; it is reported by its real path.
- Red: `inc-product/src/b.c` with `#include "kernel.inc"` in `h()`'s body - RED at
  `src/kernel.inc:1`, in scan mode and with `b.c` given alone.
- Causal: against the previous commit both are GREEN (exit 0).

## Text that is not UTF-8 (re-seeded 2026-10-26)

- Detector change: quoting an access read libclang's token spelling, which must be UTF-8, so a
  Latin-1 string in a macro argument crashed the scan (exit 2 with a traceback, a failure nobody
  can act on). Token text is read from the file's bytes now, and a parse error whose message is not
  UTF-8 is still reported as one.
- Red: `latin1.c` - `AT(a, i, j, n, "\351t\351")` (line 3) and `a[i + j * n + (int)sizeof("caf\351")]`
  (line 4) RED (exit 1).
- Causal: against the previous commit both exit 2 (`UnicodeDecodeError`).

## A missing file or a directory is UNRELIABLE (re-seeded 2026-10-26)

- Detector change: an explicit file that does not exist, or a directory passed as a file, was
  counted as one violation (RED, `NOT FOUND`) - a verdict on content that was never read. It is
  UNRELIABLE (exit 2) now, naming the path; a directory is scanned with `--target-dir`.
- Red / UNRELIABLE: `no_such_file.c` - `does not exist`; the fixture directory - `is a directory,
  not a file`.
- Causal: against the previous commit both exit 1.

## A helper's name declared outside the central files (re-seeded 2026-10-26)

- Detector change: since a helper must be declared centrally, a local `static long idx2(long i,
  long j, long n) { return i + j * n; }` is ordinary code - but its calls (`a[idx2(i, j, n)]`)
  show no multiply, so the flatten in its body passed at every call. A function or macro of a
  helper name declared or defined in a judged product file outside `idx.h` / `idx.c` is reported
  where it is declared (a waiver quotes the name). The wrapped-subscript fixtures take their
  `idx2` prototype from a central `wrap/idx.h` instead of declaring it locally.
- Red: `central/shadow_quiet.c` - RED at line 1, `function 'idx2' has an index helper's name but
  is declared here`.
- Causal: against the previous commit GREEN (exit 0).
