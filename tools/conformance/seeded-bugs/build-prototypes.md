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
| `extern const double tab[4];` against `const double tab[3]` | RED: `tab is declared with 2 types` |
| a syntax error; a unit whose file does not exist | UNRELIABLE (exit 2) |

## Green proofs

`b.c` including the callee's header `scale.h`; a definition spelled with a typedef of the same type;
two `static` functions of one name in different files (internal linkage, no conflict); `main` with
two signatures in two executables; `extern const double tab[];` against the sized definition;
`strerror_r` from `<string.h>` read under `_GNU_SOURCE` in one unit and `_POSIX_C_SOURCE` in the
other (a system header is not compared - with the skip removed this case is RED); a forward
declaration of a function its own file defines; C99 `extern inline` of a header's inline
definition; a unit compiled with gcc-only flags (`-Wlogical-op -Wduplicated-cond -fanalyzer`).

## Comparison-logic version

Every C TU of the database is parsed with libclang using only the flags that shape parsing (`-D`,
`-U`, `-I`, `-iquote`, `-isystem`, `-idirafter`, `-include`, `-imacros`, `-std`, `--sysroot`,
`-isysroot`, `-x`) and clang's resource directory. Every function and variable declaration with
external linkage, outside system headers and other than `main`, is grouped by name; more than one
canonical type for a name is RED, an array declared without its size counting as the sized type of
the same element. A function declaration without a body, in a `.c` file, of a function that unit
does not define, is RED.
