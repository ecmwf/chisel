# SEEDED-BUG DEMONSTRATION - conformance/check-no-silenced-detectors

- Date: 2026-06-18 (initial seeding); re-seeded 2026-10-26 when the detection moved from grep
  patterns to libclang (see "Read through libclang" below).
- Detector: tools/conformance/check-no-silenced-detectors.sh (with lib/silenced_detectors.py and
  lib/product_tu.py)
- Failure class targeted: silenced detector / suppressed warning (AGENTS.md hard rule
  "Never silence a detector": "No suppression annotations, pragmas, or casts to quiet a
  warning, lint, sanitizer finding, or probe; fix the root cause, or record a charter
  exception."). Example: a `#pragma GCC diagnostic ignored "-Wconversion"` placed to silence
  a type-conversion warning instead of fixing the underlying precision/overflow trap.
- Exit-code contract: 0 GREEN (no suppression), 1 RED (suppression found),
  2 UNRELIABLE (could not run, or a file does not parse cleanly).

The detector reads the TARGET `*.c`/`*.h` as the compiler does. Every file is parsed with libclang
(the product's `compile_commands.json` entry when the product root has one, otherwise `-std=c17`
with `-I` for every directory of the product tree); a file that does not parse cleanly is
UNRELIABLE. It then reports:

- suppressing pragmas - `GCC|clang diagnostic ignored|ignored_attributes|warning|push` (`push`
  frames an ignore region; `warning` turns an error back into a warning), `GCC|clang
  system_header`, `warning(disable|suppress ...)`, a `clang attribute` pragma applying a
  suppressing attribute - from each file's raw tokens (every `#if` branch, any spacing, and
  `_Pragma("...")` also inside a macro definition) and from the preprocessed token stream (`clang -E`
  with the file's arguments), so a pragma a macro produces is reported where the macro is used;
- suppression attributes: `no_sanitize` and its variants and `clang::suppress`, in
  `__attribute__((...))` or `[[...]]`, from the preprocessed tokens (so through a macro, at the line
  that uses it, and also a GCC spelling clang does not implement, `no_sanitize_undefined`);
- clang-tidy suppressions (`NOLINT`, `NOLINTNEXTLINE`, `NOLINTBEGIN`, `NOLINTEND`) in comment and
  string tokens, anywhere in them, as clang-tidy reads them;
- compiler flags are not judged here: `tools/build-checks/check-build-flags.py` owns `-w` and
  `-Wno-*` (see "Flags belong to the build-flags check" below).

A pragma's words in a comment or a string are not a pragma. With no product wired yet, the check
skips vacuously (exit 0); the demonstration runs against fixtures. A non-C TARGET instantiates the
detection for its own language's suppression syntax.

## Seeded defect (representative of the class)

```c
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wconversion"
int f(const char *p) { return 0; }
#pragma GCC diagnostic pop
```
This is representative of silencing a `-Wconversion` warning arising from a precision or
integer-overflow trap instead of fixing the cast or widening the type.

## Red proof

- Fixture `seeded_suppress.c`:
  ```c
  int g(void) { return 0; }
  #pragma GCC diagnostic push
  #pragma GCC diagnostic ignored "-Wconversion"
  int f(const char *p) { return 0; }
  #pragma GCC diagnostic pop
  ```
- Command: `bash tools/conformance/check-no-silenced-detectors.sh seeded_suppress.c`
- Result (exit 1):
  ```
  [FAIL] seeded_suppress.c:2: pragma '#pragma GCC diagnostic push'
  [FAIL] seeded_suppress.c:3: pragma '#pragma GCC diagnostic ignored "-Wconversion"'
  check-no-silenced-detectors: 5 line(s) scanned in 1 file(s); 2 suppression(s) found.
  RESULT: RED (exit 1) - suppression annotation(s) found.
  ```
  Detector fired on both the push and the ignore lines. Exit 1 confirmed.

- **Whitespace-tolerance and block-comment fixtures.** Fixture `nsd_whitespace.c`:
  ```c
  int g(void) { return 0; }
  #pragma  GCC   diagnostic   ignored "-Wconversion"
  int f(const char *p) { return 0; }   /* NOLINT */
  int h(void) { return 0; }   // NOLINTNEXTLINE
  ```
  Result (exit 1): three FAILs - the extra-whitespace pragma (line 2), the block-comment
  `/* NOLINT */` (line 3), and the line-comment `// NOLINTNEXTLINE` (line 4). The first
  fixed-string (`grep -F`) patterns silently passed lines 2 and 3.

## Removal

Defect is in-memory only (fixture not committed). The pattern it demonstrates is the
important artifact, recorded here.

## Green proof (defect removed)

- Fixture `good_target.c` (same file without the pragmas):
  ```c
  int g(void) { return 0; }
  int f(const char *p) { return 0; }
  ```
- Command: `bash tools/conformance/check-no-silenced-detectors.sh good_target.c`
- Result (exit 0):
  ```
  check-no-silenced-detectors: 2 line(s) scanned in 1 file(s); 0 suppression(s) found.
  RESULT: GREEN (exit 0) - no suppression annotations found.
  ```

## Scope confirmed

A `#pragma GCC diagnostic pop` without a paired ignore/push is not flagged; this is conservative
(a pop alone is harmless). A pragma in an inactive `#if` branch, or a `_Pragma` in a macro that is
never used, is still reported: it silences a detector in some build. There is no per-site waiver:
a legitimate suppression is a charter §4 named exception.

## Read through libclang (re-seeded 2026-10-26)

- Detector change: the three `grep -nE` patterns are replaced by libclang's reading of the code
  (`lib/silenced_detectors.py`, files parsed by `lib/product_tu.py`), as listed at the top. A file
  that does not parse cleanly, a file `clang -E` cannot preprocess, or a missing python3, libclang
  or clang driver is UNRELIABLE.
- Why: grep missed a `_Pragma` inside a macro, suppression attributes and compile flags, and
  flagged a pragma's words in a comment.

### Red proof (what grep missed)

- `macro/use.c` including `quiet.h` (`#define QUIET_UNUSED _Pragma("GCC diagnostic ignored
  \"-Wunused-variable\"")`, `#define DO_PRAGMA(x) _Pragma(#x)`): RED,
  `use.c:4: pragma '#pragma GCC diagnostic ignored "-Wunused-variable"' (produced by a macro)` and
  `use.c:6: ... "-Wshadow"' (produced by a macro)`; `quiet.h` on its own: RED at line 1, the
  `_Pragma` in the definition.
- `attrs.c`: `NO_ASAN double first(...)` with `#define NO_ASAN __attribute__((no_sanitize("address")))`
  - RED at line 2, `attribute 'no_sanitize("address")'`; `__attribute__((no_sanitize_undefined))` -
  RED at line 3.
- `downgrade.c` (`#pragma GCC diagnostic warning "-Wconversion"`), `system_header.h`
  (`#pragma GCC system_header`), `nolint_mid.c` (`// kept as in the source NOLINT(...)`) - RED.
- A product whose `compile_commands.json` compiles `src/model.c` with `-DMODEL_BUILD` - GREEN, the
  file parsed with its entry; without the database - UNRELIABLE, `MODEL_BUILD is set by the build`.
  (This commit also reported `-Wno-*` / `-w` in that entry; that audit moved to the build-flags
  check, below.)
- `broken.c` (`return 0 }`) - UNRELIABLE, `does not parse cleanly`; without libclang - UNRELIABLE.

### Green proof (what grep flagged wrongly)

- `words.c`: `/* never write #pragma GCC diagnostic ignored here */`, `// #pragma clang diagnostic
  push`, and a string `"#pragma GCC diagnostic ignored is not allowed"` - GREEN.
- Unchanged: `pop.c` (`#pragma GCC diagnostic pop` alone) and `good.c` stay GREEN, and
  `// NOLINTED is not a directive` is not counted (clang-tidy reads only NOLINT, NOLINTNEXTLINE,
  NOLINTBEGIN, NOLINTEND).

### Causal proof

- The same test file (`tools/tests/test-no-silenced-detectors.sh`) against the PRE-change detector
  (`git archive origin/main tools`): every red and green case above changes exit code - the misses
  exit 0, the comment/string fixture exits 1, the unparseable file and the missing libclang exit 0
  instead of 2, and the flag cases exit 0. The seeded fixtures (`seeded.c`, `spacing.c` - its
  inactive-branch pragma included - and `nolint.c`) keep their verdicts and counts on both; only the
  report's wording differs (`file:line: pragma '...'` where it printed
  `file: line:text  (pattern: '...')`).
- Executable form: `tools/tests/test-no-silenced-detectors.sh` (run by `tools/tests/run.sh`).

## Every included file of the product tree (re-seeded 2026-10-26)

- Detector change: only the listed `*.c` / `*.h` were read, so a pragma in an included `.inc` was
  never seen. Every file under the product tree that a unit includes is read now (raw tokens and
  its lines of the preprocessed stream), reported by its real path.
- Red: `inc-product/src/c.c` with `#include "quiet.inc"` - RED at `src/quiet.inc:1`.
- Causal: against the previous commit GREEN (exit 0).

## Flags belong to the build-flags check (re-seeded 2026-10-26)

- Detector change: the audit of `-w` / `-Wno-*` in the product's `compile_commands.json` is removed.
  `tools/build-checks/check-build-flags.py` owns the flag rules, on the flags each unit really
  received (response files and the driver's own expansion included), with a contract that may allow
  a `-Wno-` with its reason - which this check could not honour, so it reported allowed flags RED.
- Flags that silence a detector without a `-W` spelling - a sanitizer ignore list
  (`-fsanitize-ignorelist=`, `-fsanitize-blacklist=`) and `-isystem` naming a product directory -
  belong to that check as well; it does not judge them yet.
- Green: the product compiled with `-Wall -Wno-unused-parameter -w` - GREEN here.
- Causal: against the previous commit it is RED (exit 1).
