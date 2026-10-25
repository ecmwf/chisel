# C as a TARGET language

Per-language guidance for rendering a numerical port into C: standard pinning, the
warning floor, the formatter/linter, sanitizers, and the build-flag contract. This is
the **language** file - it is about writing C well and deterministically, independent
of which SOURCE language is being ported. The Fortran-to-C *translation* rules and the
semantic trap table live in the pair rulebook `../pairs/fortran-to-c.md`; trap IDs
(`T1`...) referenced below are defined there.

Project-specific decisions instantiated from this file go to `port/conventions/<source>-to-<target>.md`;
this reference holds the rationale and the defaults.

## Language pinning

- Pin the standard explicitly (C11 or C17 recommended; record it in the charter with
  the compiler and flags). No compiler extensions in portable code unless charter-listed.
- Warnings are errors. Recommended floor: `-Wall -Wextra -Wconversion -Wshadow
  -Wdouble-promotion -Werror` (tune the exact set once, in Phase 1, record it).
- Floating-point determinism flags are part of the build contract, not advice:
  disable fast-math entirely; pin FMA contraction off (`-ffp-contract=off`) on the
  deterministic reference build. Record the exact flags in the charter.

## Tooling baseline

Every tool here is a mechanized detector for a trap-table entry or failure mode: a
standing rule no sprint has to remember. Three rules make the toolchain safe rather
than fashionable: **pin versions and commit configs** (tool drift is config drift);
**allowlist-curate** every check (no tool that proposes improvements - a linter
pushing modernization during a literal port is failure mode B1 automated); **record
each tool in port/conventions/<source>-to-<target>.md** with its enforcement role, and per the
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
  (SOURCE side), and the vacuity check in module review ("does the proving run
  actually exercise this module?") becomes a measurement instead of a judgment.
- **compile_commands.json** (build-system export or `bear`): prerequisite for all
  clang tooling; set up on day one.

### Deliberately skipped
Heavyweight floating-point analysis tools (the ladder owns that ground),
include-what-you-use (noise during a port), and anything that suggests
restructuring.
