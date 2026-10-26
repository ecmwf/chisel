# SEEDED-BUG DEMONSTRATION - build-checks/check-sanitized

- Date: 2026-10-26 (new detector: the product's tests on a sanitizer build)
- Detector: tools/build-checks/check-sanitized.py
- Failure class targeted: memory and undefined-behaviour defects a passing test does not show - an
  out-of-bounds access from a wrong stride, extent or index base (L4, T10, T30), a signed-integer
  overflow that Fortran wrapped and C leaves undefined (T13), an out-of-range float-to-integer
  conversion. AddressSanitizer and UndefinedBehaviorSanitizer stop at the first one when the
  runtimes are told to; a sanitizer build that is not really sanitized proves nothing.
- Exit-code contract: 0 GREEN (every C TU carries the sanitizers and the test command passes with no
  report), 1 RED (a TU without them - tests not run -, or a failing test command, or a sanitizer
  report in its output), 2 UNRELIABLE (no, unreadable or empty database; no test command; a command
  not found).

## Seeded defects and red proofs (replayed by tools/tests/test-build-sanitized.sh)

| Seeded defect | Verdict |
|---|---|
| `p[4] = 1` on a 4-element heap array, built `-fsanitize=address,undefined` | RED: `AddressSanitizer` (heap-buffer-overflow) |
| `INT_MAX + argc` | RED: `runtime error` (signed integer overflow) |
| the TU built without `-fsanitize` | RED: `not built with -fsanitize=address,undefined`, tests not run |
| `-fsanitize=address,undefined -fno-sanitize=undefined` | RED: `not built with -fsanitize=undefined` |
| a test command that does not exist; none at all; a missing database | UNRELIABLE (exit 2) |

## Green proof

A clean program built `-fsanitize=address,undefined` runs under the same options and is GREEN.

## Comparison-logic version

Per C TU, the sanitizers on are the union of every `-fsanitize=` minus every `-fno-sanitize=`; the
required ones (address and undefined by default) must all be on. The test command runs with
`ASAN_OPTIONS=halt_on_error=1:abort_on_error=1:detect_leaks=1` and
`UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1` appended to any the caller set; a non-zero exit,
or a line starting `==<pid>==ERROR: <Address|Leak|Memory|Thread>Sanitizer` or holding
`: runtime error: `, is RED.
