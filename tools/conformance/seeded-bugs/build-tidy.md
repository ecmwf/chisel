# SEEDED-BUG DEMONSTRATION - build-checks/check-tidy

- Date: 2026-10-27 (new detector: the port's clang-tidy allowlist over the build)
- Detector: tools/build-checks/check-tidy.py, with the config the port commits (template:
  .opencode/skill/target-conventions/assets/clang-tidy.template.yaml)
- Failure class targeted: defects clang-tidy proves that the compiler does not warn about - a
  path-sensitive division by zero, null dereference or uninitialized read (`clang-analyzer-*`), a
  stray semicolon, a misused `sizeof`, a suspicious string compare (`bugprone-*`) - and naming that
  drifts from the conventions (`readability-identifier-naming`); and a config that is not an
  allowlist: a check that proposes rewriting the code (`modernize-*`, readability checks other than
  identifier naming) is failure mode B1 automated.
- Exit-code contract: 0 GREEN (no finding; no rewriting check enabled), 1 RED (a finding, in a unit
  or in a product header it includes, or a rewriting check enabled), 2 UNRELIABLE (no, unreadable or
  empty database; a malformed entry; clang-tidy missing; a missing config, one clang-tidy cannot
  read, or one enabling no check; a unit clang-tidy cannot compile).

## Seeded defects and red proofs (replayed by tools/tests/test-build-tidy.sh)

| Seeded defect | Verdict |
|---|---|
| `int z = 0; return 1 / z;` | RED: `[clang-analyzer-core.DivideZero]` |
| `if (x); { return 1; }` | RED: `[bugprone-suspicious-semicolon]` |
| the same in a `static inline` function of a product header | RED, at `include/k.h:2` |
| `1.0 + n / 2` under a config enabling `bugprone-integer-division` | RED: `[bugprone-integer-division]` |
| a config enabling `modernize-use-nullptr` | RED: `a check that rewrites the code` |
| a config enabling `readability-braces-around-statements` | RED (while `readability-identifier-naming` is allowed) |
| a config enabling no check; a missing config; a unit that does not compile; no clang-tidy | UNRELIABLE (exit 2) |

## Green proofs

Clean code with the template config; `1.0 + n / 2` (integer division in a floating context, kept by
a literal translation) with the template, which turns `bugprone-integer-division` off; a database
whose commands carry gcc-only flags (`-fipa-pta -ftree-loop-vectorize -Wlogical-op`).

## Comparison-logic version

`clang-tidy --list-checks --config-file=<config>` gives the enabled checks; one matching
`modernize-*` or `readability-*` other than `readability-identifier-naming` is RED. Each C unit of
the database is run as `clang-tidy -p <dir> --config-file=<config> --quiet <unit>` over a database
holding only the flags that shape parsing (`-D`, `-U`, `-I` and the other include flags, `-std`,
`-x`, ...); every `<file>:<line>:<col>: warning|error: <message> [<check>]` is a finding, deduplicated
across units, except an error from a `clang-diagnostic-*` check, which means the unit does not
compile (UNRELIABLE).
