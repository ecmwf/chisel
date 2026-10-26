# SEEDED-BUG DEMONSTRATION - build-checks/check-build-flags

- Date: 2026-10-26 (new detector: the C build contract on the flags each translation unit received)
- Detector: tools/build-checks/check-build-flags.py
- Failure class targeted: the deterministic build silently drifting from its contract - floating-
  point contraction on (T12: `a*b + c` fused into one rounding, a last-bit divergence), a
  value-changing math mode (fast-math and its parts, T12), the warning floor missing or a warning
  taken back (the floor's `-Wdouble-promotion` and `-Wconversion` catch T1's silent precision
  changes), a machine-dependent build, or an unpinned or mixed C standard. The flags in a build
  file or a cache variable are not the evidence: only the compilation database records what each TU
  received, only the compiler driver (`-###`) says what a spelling means - a response file, a long
  option, clang's `-ffp-model=fast` - and only the object shows whether the compiler contracted.
- Exit-code contract: 0 GREEN (every C TU on the contract; with --objects, no fused multiply-add),
  1 RED (a TU breaks the contract or an object holds an FMA), 2 UNRELIABLE (no, unreadable or empty
  database, a malformed entry or response file, no C TU, a command the compiler refuses or a
  compiler other than gcc or clang, a missing or LTO object, an unknown architecture, objdump or
  PyYAML missing, a malformed contract).

## Seeded defects and red proofs (replayed by tools/tests/test-build-flags.sh)

A two-file project (`a.c` holds `a * b + c`) is built with the flags of each case; the database
lists exactly those flags.

| Seeded defect | Verdict |
|---|---|
| `a.c` without `-ffp-contract=off` | RED: `a.c: -ffp-contract=off is missing` |
| `-ffast-math` in one TU | RED: `-ffast-math is forbidden` |
| `-ffast-math` inside a response file `@fast.rsp` | RED: `-ffast-math is forbidden` |
| clang, no `-ffp-contract=` (its default is `on`) | RED: `the compiler runs -ffp-contract=on` |
| `-ffp-contract=off ... -ffp-contract=fast` (the last one wins) | RED: `contraction must be off` |
| clang `-ffp-contract=off -ffp-model=fast` | RED: `runs with -mreassociate`, `runs -ffp-contract=fast` |
| gcc `-ffp-model=fast` (gcc refuses the option) | UNRELIABLE (exit 2) |
| `-march=native`, `-mcpu=native` as written (gcc's driver replaces them) | RED: `is forbidden` |
| `--warn-no-conversion`, `--no-warnings` | RED: read as `-Wno-conversion`, `-w` |
| `-Wno-conversion` | RED: `-Wno-conversion takes a warning back` |
| `-Wno-sign-conversion`, `-Wno-unused-parameter` (not floor flags themselves) | RED: `takes a warning back` |
| an `allowed:` entry with an empty reason | UNRELIABLE (exit 2) |
| no `-Werror` | RED: `-Werror is missing` |
| `-std=c17` and `-std=c11` in one build | RED: `the TUs use different standards` |
| no `-std=` | RED: `no -std= reaches the compiler` |
| `-std=c17 -ansi`, `-std=c17 --std=gnu17` | RED: `the compiler runs -std=c90`, `-std=gnu17` |
| a contract adding `forbidden: [-fno-strict-aliasing]`, a build with `-ffast-math` | RED: the defaults stay |
| `a.c` built `-O2 -march=haswell -ffp-contract=fast`, checked with --objects | RED: `fused multiply-add instruction(s) in fma_candidate` |
| the same object under a database entry that claims contraction off | RED: the object is the evidence |
| `a.c` built with `-flto` | UNRELIABLE: `is an LTO object` |
| canned x86 and AArch64 (scalar, SIMD, SVE) disassembly | every FMA mnemonic matched; `call <vfmadd_ref>`, `fmul`, `fmov` not |
| `arguments` as a string, an unbalanced quote, a null file, a relative directory, a missing response file | UNRELIABLE (exit 2) |
| a missing object, database, or C TU; a malformed contract | UNRELIABLE (exit 2) |

## Green proofs

The same project on the contract (`-std=c17`, the warning floor with `-Werror`,
`-ffp-contract=off`) is GREEN with gcc and with clang, with --objects too; a contract's `std: [c11]`
replaces the standards; an allowed `-Wno-shadow` stands in for the required `-Wshadow`; the
`command` string form of an entry is read like the `arguments` form; a file compiled with `-x c` is
checked whatever its suffix; a `-Wno-` the contract lists under `allowed:` with its reason is
GREEN. The test also holds the default contract to the floor written in `references/langs/c.md`
("Language pinning"), in both directions and each flag in its role (standard, required, forbidden).

## Comparison-logic version

Per C TU, with its response files expanded, read twice: as written, and as the compiler driver hands
it on (`<cc> ... -###`). On the compiler's job: the last `-std=` (or `-ansi`, C90) is one of the
contract's standards and the same in every TU; the last `-ffp-contract=` is `off`; none of clang's
`-mreassociate`, `-menable-no-nans`, `-menable-no-infs`. On both: every required flag is present
(an allowed `-Wno-X` stands in for `-WX`); no forbidden flag (exact, or a prefix ending in `*`) and
no `-Wno-<warning>` the contract does not list under `allowed:`. A contract's `required` and
`forbidden` add to the defaults; its `std` replaces them.

With --objects: an object with `.gnu.lto_` sections, or one objdump cannot read, is UNRELIABLE.
Otherwise the mnemonic of every instruction in `objdump -d` of each TU's object (the entry's
`output`, else its `-o`) is matched against the fused multiply-add mnemonics. x86: `vfmadd*`,
`vfmsub*`, `vfnmadd*`, `vfnmsub*`, `vfmaddsub*`, `vfmsubadd*`, `vfmaddc*`, `vfcmaddc*`. AArch64:
`fmadd`, `fmsub`, `fnmadd`, `fnmsub`, `fmla`, `fmls`, `fmad`, `fmsb`, `fnmad`, `fnmsb`, `fnmla`,
`fnmls`, `fmlal*`, `fmlsl*`, `bfml*`, `fcmla`.
