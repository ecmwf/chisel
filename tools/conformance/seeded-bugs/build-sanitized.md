# SEEDED-BUG DEMONSTRATION - build-checks/check-sanitized

- Date: 2026-10-26 (new detector: the product's tests on a sanitizer build)
- Detector: tools/build-checks/check-sanitized.py
- Failure class targeted: memory and undefined-behaviour defects a passing test does not show - an
  out-of-bounds access from a wrong stride, extent or index base (L4, T10, T30), a signed-integer
  overflow that Fortran wrapped and C leaves undefined (T13), an out-of-range float-to-integer
  conversion. AddressSanitizer and UndefinedBehaviorSanitizer stop at the first one when the
  runtimes are told to; a sanitizer build that is not really sanitized proves nothing.
- Exit-code contract: 0 GREEN (every C TU carries the sanitizers, takes none back, and the test
  command passes with no report), 1 RED (a TU without them or with a `-fno-sanitize=` - tests not
  run -, or a failing test command, or a sanitizer report in its output), 2 UNRELIABLE (no,
  unreadable or empty database; a malformed entry; no sanitizer named; no test command; a command
  not found).

## Seeded defects and red proofs (replayed by tools/tests/test-build-sanitized.sh)

| Seeded defect | Verdict |
|---|---|
| `p[4] = 1` on a 4-element heap array, built `-fsanitize=address,undefined` | RED: `AddressSanitizer` (heap-buffer-overflow) |
| `INT_MAX + argc` | RED: `runtime error` (signed integer overflow) |
| the TU built without `-fsanitize` | RED: `not built with -fsanitize=address,undefined`, tests not run |
| `-fsanitize=address,undefined -fno-sanitize=undefined` | RED: `takes a sanitizer back` |
| `INT_MAX + argc` built `... -fno-sanitize=signed-integer-overflow` (part of `undefined`) | RED: `takes a sanitizer back` |
| `-fno-sanitize=all` | RED: `takes a sanitizer back` |
| `-fsanitize-ignorelist=ignore.txt`, `-fsanitize-blacklist=ignore.txt` | RED: `exempts code from the sanitizers` |
| `UBSAN_OPTIONS=...:suppressions=<file>` in the environment | RED: `a suppressions file hides sanitizer reports` |
| the heap overflow run by a runner that prefixes each line and exits 0, with `ASAN_OPTIONS=log_path=<file>` set | RED: `AddressSanitizer` |
| `--sanitizers ""` | UNRELIABLE (exit 2) |
| a test command that does not exist; none at all; a missing database | UNRELIABLE (exit 2) |

## Green proof

A clean program built `-fsanitize=address,undefined` runs under the same options and is GREEN.

## Comparison-logic version

Per C TU, with its response files expanded: the sanitizers on are the union of every `-fsanitize=`;
the required ones (address and undefined by default) must all be on, and any `-fno-sanitize=`,
`-fsanitize-ignorelist=` or `-fsanitize-blacklist=` is RED, as is a non-empty `suppressions=` in
ASAN_OPTIONS, UBSAN_OPTIONS, LSAN_OPTIONS, MSAN_OPTIONS or TSAN_OPTIONS.
The test command runs with `ASAN_OPTIONS=...:halt_on_error=1:abort_on_error=1:detect_leaks=1:log_path=stderr`
and `UBSAN_OPTIONS=...:halt_on_error=1:print_stacktrace=1:log_path=stderr` (appended to any the
caller set, so these win); a non-zero exit, or `==<pid>==ERROR: <Address|Leak|Memory|Thread>Sanitizer`
or `: runtime error: ` anywhere on a line of its output, is RED.
