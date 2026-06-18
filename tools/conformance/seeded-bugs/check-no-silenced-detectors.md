# SEEDED-BUG DEMONSTRATION - conformance/check-no-silenced-detectors

- Date: 2026-06-18 (initial seeding; comparison-logic version: initial commit)
- Detector: tools/conformance/check-no-silenced-detectors.sh
- Failure class targeted: silenced detector / suppressed warning (AGENTS.md hard rule
  "Never silence a detector": "No suppression annotations, pragmas, or casts to quiet a
  warning, lint, sanitizer finding, or probe; fix the root cause, or record a charter
  exception."). Example: a `#pragma GCC diagnostic ignore "-Wconversion"` placed to silence
  a type-conversion warning instead of fixing the underlying precision/overflow trap.
- Exit-code contract: 0 GREEN (no suppression), 1 RED (suppression found),
  2 UNRELIABLE (could not run).

The detector scans TARGET `*.c`/`*.h` with extended-regex patterns (the C/C++ default set),
whitespace-tolerant and covering line- AND block-comment forms:
  - `#pragma[[:space:]]+GCC[[:space:]]+diagnostic[[:space:]]+(ignored?|push)`
  - `#pragma[[:space:]]+clang[[:space:]]+diagnostic[[:space:]]+(ignored?|push)`
  - `(//|/\*)[[:space:]]*NOLINT` (covers `// NOLINT`, `// NOLINTNEXTLINE`, `/* NOLINT */`)
`push` frames an ignore region; the regex matches any inter-token whitespace, so
`#pragma  GCC   diagnostic   ignored` (extra spaces) is caught - the earlier fixed-string
(`grep -F`) patterns missed it, and missed `/* NOLINT */` block comments entirely. With no
product wired yet, the check skips vacuously (exit 0); the demonstration runs against
fixtures. A non-C/C++ TARGET instantiates the patterns and file glob for its own language's
suppression syntax.

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
  [FAIL] seeded_suppress.c: 3:#pragma GCC diagnostic ignored "-Wconversion"  (pattern: '#pragma GCC diagnostic ignore')
  [FAIL] seeded_suppress.c: 2:#pragma GCC diagnostic push  (pattern: '#pragma GCC diagnostic push')
  check-no-silenced-detectors: 5 line(s) scanned in 1 file(s); 2 suppression(s) found.
  RESULT: RED (exit 1) - suppression annotation(s) found.
  ```
  Detector fired on both the push and the ignore lines. Exit 1 confirmed.

- **Whitespace-tolerance and block-comment fixtures** (the cases the fixed-string patterns
  missed). Fixture `nsd_whitespace.c`:
  ```c
  int g(void) { return 0; }
  #pragma  GCC   diagnostic   ignored "-Wconversion"
  int f(const char *p) { return 0; }   /* NOLINT */
  int h(void) { return 0; }   // NOLINTNEXTLINE
  ```
  Result (exit 1): three FAILs - the extra-whitespace pragma (line 2), the block-comment
  `/* NOLINT */` (line 3), and the line-comment `// NOLINTNEXTLINE` (line 4) - each reported
  with its matching regex. The pre-fix `grep -F` patterns silently passed lines 2 and 3.

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

The three patterns are searched independently with `grep -nE` (extended regex). The patterns
are authored constants (not user input), so there is no injection surface; the only regex
metacharacters used are character classes, `+`, `?`, alternation, and an escaped `\*`. A
`#pragma GCC diagnostic pop` without a paired ignore/push is not flagged (not in the pattern
list); this is conservative (a pop alone is harmless).

## Comparison-logic version

Extended-regex (`grep -nE`) matching of the three whitespace-tolerant patterns listed above
(GCC/clang `ignored?|push`, and line-or-block-comment `NOLINT`). Re-run this demonstration
after any change to the PATTERNS array or the grep invocation in the script.
