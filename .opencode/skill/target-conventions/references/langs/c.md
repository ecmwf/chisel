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

- Pin the standard explicitly (`-std=c11` or `-std=c17` recommended), the same in every
  translation unit. No compiler extensions in portable code unless charter-listed.
- Warnings are errors. Recommended floor: `-Wall`, `-Wextra`, `-Wconversion`, `-Wshadow`,
  `-Wdouble-promotion`, `-Werror` (tune the exact set once, in Phase 1). Nothing takes a
  warning back: no `-w`, no `-Wno-error` or `-Wno-error=*`, and a `-Wno-<warning>` only
  where the build contract records why that warning is wrong for this code.
- Floating-point determinism flags are part of the build contract, not advice: pin FMA
  contraction off (`-ffp-contract=off`) on the deterministic reference build, and turn on
  no value-changing math mode, under any spelling: `-ffast-math`, `-Ofast`,
  `-ffp-model=fast`, `-ffp-model=aggressive`, `-funsafe-math-optimizations`,
  `-fassociative-math`, `-freciprocal-math`, `-ffinite-math-only`, `-fno-honor-nans`,
  `-fno-honor-infinities`, `-fno-signed-zeros`, `-fapprox-func` (T12). The numbers must not
  depend on the machine that built them: no `-march=native`, `-mtune=native` or
  `-mcpu=native`.
- Record the exact standard and flags once, in the port's build contract
  (`port/conventions/build-contract.yaml`, which `tools/build-checks/check-build-flags.py`
  reads), and cite it from the charter. This list is the default contract:
  `tools/tests/test-build-flags.sh` fails if it and the check's defaults drift apart.

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

### Build checks (on the build's own compilation database)
The contract is checked on what the compiler really did, never on build files or cache
variables: three base tools in `tools/build-checks/` read the build's
`compile_commands.json`, and the flags check asks the compiler driver what each command
means (`-###`), so a response file, a long option or `-ffp-model=fast` is judged by its
effect. They read a build (the objects, the sanitized tests; the prototype check only the
database a configured build writes), so they are not conformance checks. The port's proof
script builds unconditionally (never a "the build exists" shortcut), then runs them, in CI
on every commit. Each exits 0 GREEN, 1 RED, 2 UNRELIABLE. With CMake, set
`CMAKE_C_EXTENSIONS OFF`: by default CMake passes `-std=gnu17`, which is not a pinned ISO
standard.

| Tool | Checks | Mechanizes |
|---|---|---|
| `check-build-flags.py --objects` | Every C translation unit is on the contract above, and no product header is made a system header (`-isystem`/`-idirafter` into the product, `--system-header-prefix`), which would silence its warnings; no object holds a fused multiply-add instruction (a compiler may contract `a*b + c` unasked, and only the object shows it) | T12, T1 |
| `check-sanitized.py` | Every unit of the sanitizer build carries ASan and UBSan and takes none back (`-fno-sanitize=`, an ignore-list, a `suppressions=` file in the runtime options); the tests pass with the runtimes set to stop at the first report | L4, T10, T30, T13 |
| `check-prototypes.py` | One type for every external function and variable across all units; no external function declared in a `.c` file without its body, unless that unit defines it | T33 |

```sh
cmake --preset reference && cmake --build --preset reference
python3 tools/build-checks/check-build-flags.py --objects \
  --compile-commands build/reference/compile_commands.json \
  --contract port/conventions/build-contract.yaml
python3 tools/build-checks/check-prototypes.py --compile-commands build/reference/compile_commands.json
cmake --preset sanitize && cmake --build --preset sanitize
python3 tools/build-checks/check-sanitized.py --compile-commands build/sanitize/compile_commands.json \
  -- ctest --test-dir build/sanitize --no-tests=error
```

### Methodology hooks
- **Coverage (gcov / llvm-cov)**, both sides: live-subset determination at Phase 0
  (SOURCE side), and the vacuity check in module review ("does the proving run
  actually exercise this module?") becomes a measurement instead of a judgment.
- **compile_commands.json** (build-system export or `bear`): prerequisite for all
  clang tooling; set up on day one. Keep it (or a link to it) at the product root:
  the product C checks (index helpers, silenced detectors) parse each file with its
  entry (its flags are judged by `check-build-flags.py`, "Build checks"); a source it does not
  list, or a link to a removed build, is UNRELIABLE. Only the flags that shape the parse are
  used (macros, include paths, the standard, and those that change predefined macros: the
  target and its `-m` options, `-O`, `-fopenmp`, `-ffast-math`, `-funsigned-char`, `-pthread`,
  `-ansi`); a gcc-only one clang does not know, such as `-mpreferred-stack-boundary=`, makes
  the parse UNRELIABLE, with clang naming it. Without it they parse with `-std=c17` and `-I` for
  every product directory, and a file that does not parse is UNRELIABLE.

### Deliberately skipped
Heavyweight floating-point analysis tools (the ladder owns that ground),
include-what-you-use (noise during a port), and anything that suggests
restructuring.
