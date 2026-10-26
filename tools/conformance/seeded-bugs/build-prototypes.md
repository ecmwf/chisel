# SEEDED-BUG DEMONSTRATION - build-checks/check-prototypes

- Date: 2026-10-26 (new detector: trap T33 across the whole build)
- Detector: tools/build-checks/check-prototypes.py
- Failure class targeted: T33 - a call from one unit into another rendered with a prototype the
  caller writes for itself. It compiles and links even when it disagrees with the definition
  (another arity, pointer level or qualifier): undefined behaviour no per-unit proof sees and a test
  that mocks the callee hides. Even a matching local prototype can drift later; the rendering rule is
  the callee's own header.
- Exit-code contract: 0 GREEN (one type per external name, no caller-local prototype), 1 RED (a name
  declared with two types, or a function declared without a body in a .c file), 2 UNRELIABLE (no,
  unreadable or empty database; a TU libclang cannot parse; libclang missing).

## Seeded defects and red proofs (replayed by tools/tests/test-build-prototypes.sh)

`a.c` defines `double scale(double x, int n)`; `b.c` calls it.

| Seeded defect in b.c | Verdict |
|---|---|
| `double scale(double x, int n);` (matches) | RED: `a caller-local prototype` |
| `double scale(double x);` | RED: `scale is declared with 2 types` |
| `double scale(double *x, int n);` | RED: `scale is declared with 2 types` |
| `double scale();` (no prototype) | RED: `scale is declared with 2 types` |
| `extern long count;` against `int count = 0;` in a.c | RED: `count is declared with 2 types` |
| a syntax error | UNRELIABLE (exit 2) |

## Green proofs

`b.c` including the callee's header `scale.h`; a definition spelled with a typedef of the same type;
two `static` functions of one name in different files (internal linkage, no conflict).

## Comparison-logic version

Every C TU of the database is parsed with libclang using its own `-D`/`-I`/`-std` flags (and clang's
resource directory). Every function and variable declaration with external linkage is grouped by
name; more than one canonical type for a name is RED. A function declaration without a body located
in a `.c` file is RED.
