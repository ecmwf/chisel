<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# C as a TARGET language

Per-language guidance for rendering a numerical port into C: standard pinning, the
warning floor, the formatter/linter, sanitizers, and the build-flag contract. This is
the **language** file - it is about writing C well and deterministically, independent
of which SOURCE language is being ported. How a SOURCE language is rendered into C - the
translation rules, the semantic trap table, and which of the tools below catches which trap -
lives in that pair's rulebook in `../pairs/` (e.g. `../pairs/fortran-to-c.md`).

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
  `-fno-honor-infinities`, `-fno-signed-zeros`, `-fapprox-func`, and no flush-to-zero for the whole
  process (`-mdaz-ftz`; "The floating-point environment" below). The numbers must not
  depend on the machine that built them: no `-march=native`, `-mtune=native` or
  `-mcpu=native`.
- Record the exact standard and flags once, in the port's build contract
  (`port/conventions/build-contract.yaml`, which `tools/build-checks/check-build-flags.py`
  reads), and cite it from the charter. This list is the default contract:
  `tools/tests/test-build-flags.sh` fails if it and the check's defaults drift apart. The file
  only adds to the defaults (a contract never removes a default):
  ```yaml
  std: [c17]                          # replaces the default standards
  required: [-Wmissing-prototypes]    # added to the warning floor
  forbidden: [-fopenmp]               # added to the forbidden flags; a trailing * matches a prefix
  allowed:                            # a warning taken back, with the reason it is wrong here
    -Wno-float-equal: <why this warning is wrong for this code>
  ```

## Vector math without fast-math

A C compiler calls a math function (`exp`, `log`, `pow`, `sin`, ...) one value at a time unless it
knows a vector version exists and that the call has no side effect. Fast-math tells it both, but it
also reorders arithmetic, so it stays forbidden. Two routes keep the arithmetic as written:

- **glibc's vector math library (libmvec).** Declare each function once, in one product header, and
  build every unit with `-fopenmp-simd -fno-math-errno`:

  ```c
  #include <math.h>

  #pragma omp declare simd notinbranch
  double exp(double);
  ```

  Neither flag changes a value: `-fopenmp-simd` turns on the OpenMP SIMD pragmas alone, with no
  threads and no runtime, and `-fno-math-errno` stops math functions setting `errno`, so the product
  never reads `errno` after one. GCC vectorizes the calls; without `-fopenmp-simd` the warning floor
  refuses the pragma (`-Wunknown-pragmas`). Clang ignores the pragma and takes
  `-fveclib=libmvec -fno-math-errno` instead, vectorizing every function it knows. The vector
  versions are less exact than the scalar ones, and their bits depend on the vector width (`-march`)
  and the glibc version. Each vector function arrived in its own glibc release (some only in 2.35),
  and a build records the versions of the glibc it was built on, so it does not load on an older
  one: build on the oldest glibc the product must run on, or use SLEEF.
- **SLEEF**, a vector math library under the Boost licence. Its `_u10` functions are accurate to
  1 ULP, and its results do not depend on the vector width. Call its scalar functions; GCC
  vectorizes the calls under `-fopenmp-simd`, and clang does not on x86_64:

  ```c
  #define SLEEF_ENABLE_OMP_SIMD
  #include <sleef.h>

  y[i] = Sleef_exp_u10(x[i]);
  ```

  Link it as an installed library, built outside the product's build: it uses fused multiply-add on
  purpose, so neither its units nor its inline headers belong in the product's objects, which the
  build check refuses with one (below). Its bits match neither libm nor libmvec, so a product that
  adopts it is judged against the acceptance bands, and confirms on each machine it runs on that
  the bits do not change. Adopting it is the human's decision (charter section 1).

Neither belongs in a bit-identity proof: vector results depend on the vector width, the compiler
and the library's version, so that proof builds both sides without vector math (code-port
`references/validation-ladder.md`). Which route a port takes, and when, is its pair's rule
(`../pairs/`) and the performance campaign's (code-port `references/performance-campaign.md`,
rule 13). `tools/tests/test-build-flags.sh`
keeps the flags of both routes on the build contract.

## The floating-point environment

A subnormal number (below the smallest normal one, about 1.2e-38 in single precision) takes a slow
path through the processor: a kernel whose values decay toward zero can run several times slower
(measured: three to four times on one single-precision kernel, about a seventh of a model's time).
Flush-to-zero (FTZ, for results) and denormals-are-zero (DAZ, for inputs) avoid it, and they are
part of a build's numbers: Intel's compilers turn them on by default, GNU and LLVM do not.

- Match the reference build. Its setting is recorded in charter section 1, and both sides of a
  bit-identity proof run with it.
- Turning it on is value-changing in general, and bit-neutral only if no subnormal reaches a
  result: prove it (code-port `references/performance-campaign.md`, rules 11 and 14).
- Set it in code, scoped: for a program, at the start of `main`; for a library a host program calls,
  on entry to each call and back to the caller's setting on exit, on every thread that runs the
  library (`_mm_getcsr`/`_mm_setcsr` on x86, the FZ bit of FPCR on AArch64). Never process-wide:
  `-mdaz-ftz`, or `-ffast-math` at link time, sets it for the whole process at start-up, and in one
  port that changed the host program's own results.

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
| clang-format | Zero-debate layout; config committed at repo root | Pin the version: output drifts between releases, and a version bump must never mix formatting noise into real diffs. Set `ReflowComments: false`, so a provenance anchor is never split across lines |
| clang-tidy | `readability-identifier-naming` enforces the naming map mechanically; `bugprone-*` and `clang-analyzer-*` catch real defects | Allowlist only, never the default set; all `modernize-*` and rewrite-style `readability-*` checks stay off; template `../../assets/clang-tidy.template.yaml`, checked by `tools/build-checks/check-tidy.py` |

### Runtime sanitizers (required: part of every R1 proof)
| Tool | Catches |
|---|---|
| AddressSanitizer | Out-of-bounds reads and writes: a wrong stride or extent (N4) and cross-module sizing bugs, at first touch |
| UBSan, with `float-cast-overflow` named (GCC leaves it out of `undefined`) | Signed-integer overflow, a float-to-integer conversion out of range, and other undefined arithmetic such as an out-of-range shift |
| MemorySanitizer (clang; a build of its own, it does not combine with ASan) | Reads of uninitialized memory |
| ThreadSanitizer (a build of its own; once the execution model adds threads) | Data races between threads |

All three are required: every R1 proof of a unit runs its tests on an ASan + UBSan build and on an
MSan build, and a unit with a sanitizer report is not proven (code-port
`references/validation-ladder.md`, R1). MSan needs clang on Linux. A sanitizer build is a
diagnostic build, so it may use clang when the pinned compiler is another, and it runs in CI where
the workstation has no MSan. Acceptance comparisons run only on the pinned-flag deterministic build.
When the execution model adds threads (charter section 1), a ThreadSanitizer build
(`--sanitizers thread`) joins them. With OpenMP, build it with clang and its libomp, whose Archer
tool tells ThreadSanitizer about OpenMP's synchronization; GCC's libgomp does not, and false
reports follow. Run the sanitizer builds on the fast rig in CI, so every commit gets them cheaply.

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

| Tool | Checks |
|---|---|
| `check-build-flags.py --objects` | Every C translation unit is on the contract above, and no product header is made a system header (`-isystem`/`-idirafter` into the product, `--system-header-prefix`), which would silence its warnings; no object holds a fused multiply-add instruction (a compiler may contract `a*b + c` unasked, and only the object shows it) |
| `check-sanitized.py` | Every unit of the sanitizer build carries ASan, UBSan and `float-cast-overflow` (or, with `--sanitizers memory`, MemorySanitizer) and takes none back (`-fno-sanitize=`, an ignore-list, a `suppressions=` file in the runtime options); the tests pass with the runtimes set to stop at the first report |
| `check-prototypes.py` | One type for every external function and variable across all units; no external function declared in a `.c` file without its body, unless that unit defines it |

```sh
cmake --preset reference && cmake --build --preset reference
python3 tools/build-checks/check-build-flags.py --objects \
  --compile-commands build/reference/compile_commands.json \
  --contract port/conventions/build-contract.yaml
python3 tools/build-checks/check-prototypes.py --compile-commands build/reference/compile_commands.json
cmake --preset sanitize && cmake --build --preset sanitize
python3 tools/build-checks/check-sanitized.py --compile-commands build/sanitize/compile_commands.json \
  -- ctest --test-dir build/sanitize --no-tests=error
cmake --preset msan && cmake --build --preset msan   # clang, -fsanitize=memory
python3 tools/build-checks/check-sanitized.py --sanitizers memory \
  --compile-commands build/msan/compile_commands.json -- ctest --test-dir build/msan --no-tests=error
```

### Methodology hooks
- **Coverage (gcov / llvm-cov)**, both sides: live-subset determination at Phase 0
  (SOURCE side), and the vacuity check in module review ("does the proving run
  actually exercise this module?") becomes a measurement instead of a judgment.
- **compile_commands.json** (build-system export or `bear`): needed by all the clang
  tooling; set it up on day one. Keep it (or a link to it) at the product root: the product's
  C checks (index helpers, silenced detectors) parse each file with its entry, and a file they
  cannot parse that way - one the database does not list, a link to a removed build, a flag
  clang does not know - is UNRELIABLE. Without a database they parse with `-std=c17` and `-I`
  for every product directory, and a file that does not parse is UNRELIABLE.

### Deliberately skipped
Heavyweight floating-point analysis tools (the ladder owns that ground),
include-what-you-use (noise during a port), and anything that suggests
restructuring.
