# SEEDED-BUG DEMONSTRATION - build-checks/check-build-flags

- Date: 2026-10-26 (new detector: the C build contract on the flags each translation unit received)
- Detector: tools/build-checks/check-build-flags.py
- Failure class targeted: the deterministic build silently drifting from its contract - floating-
  point contraction on (T12: `a*b + c` fused into one rounding, a last-bit divergence), a
  value-changing math mode (fast-math and its parts, T12), the warning floor missing or a warning
  taken back (the floor's `-Wdouble-promotion` and `-Wconversion` catch T1's silent precision
  changes), a machine-dependent build, or an unpinned or mixed C standard. The flags in a build
  file or a cache variable are not the evidence: only the compilation database records what each TU
  received, and only the object shows whether the compiler contracted anyway.
- Exit-code contract: 0 GREEN (every C TU on the contract; with --objects, no fused multiply-add),
  1 RED (a TU breaks the contract or an object holds an FMA), 2 UNRELIABLE (no, unreadable or empty
  database, no C TU, a missing object, an unknown architecture, objdump or PyYAML missing, a
  malformed contract).

## Seeded defects and red proofs (replayed by tools/tests/test-build-flags.sh)

A two-file project (`a.c` holds `a * b + c`) is built with the flags of each case; the database
lists exactly those flags.

| Seeded defect | Verdict |
|---|---|
| `a.c` without `-ffp-contract=off` | RED: `a.c: -ffp-contract=off is missing` |
| `-ffast-math` in one TU | RED: `-ffast-math is forbidden` |
| `-ffp-contract=off ... -ffp-contract=fast` (the last one wins) | RED: `contraction must be off` |
| `-Wno-conversion` | RED: `-Wno-conversion takes a warning back` |
| `-Wno-sign-conversion`, `-Wno-unused-parameter` (not floor flags themselves) | RED: `takes a warning back` |
| an `allowed:` entry with an empty reason | UNRELIABLE (exit 2) |
| no `-Werror` | RED: `-Werror is missing` |
| `-std=c17` and `-std=c11` in one build | RED: `the TUs use different standards` |
| no `-std=` | RED: `no -std= flag` |
| `a.c` built `-O2 -march=haswell -ffp-contract=fast`, checked with --objects | RED: `fused multiply-add instruction(s) in fma_candidate` |
| the same object under a database entry that claims contraction off | RED: the object is the evidence |
| a missing object, database, or C TU; a malformed contract | UNRELIABLE (exit 2) |

## Green proofs

The same project on the contract (`-std=c17`, the warning floor with `-Werror`,
`-ffp-contract=off`) is GREEN, with --objects too; a port's contract file (`std: [c11]`,
`required: [-Wall, -Werror]`) replaces the default floor; the `command` string form of an entry is
read like the `arguments` form; a `-Wno-` the contract lists under `allowed:` with its reason is
GREEN. The test also holds the default contract to the floor written in
`references/langs/c.md` ("Language pinning"), in both directions.

## Comparison-logic version

Per C TU: the last `-std=` is one of the contract's standards and the same in every TU; every
required flag is present; no forbidden flag (exact, or a prefix ending in `*`) and no
`-Wno-<warning>` the contract does not list under `allowed:`; the last `-ffp-contract=` is `off`.
With --objects: `objdump -d` of each TU's object (the entry's `output`, else its `-o`) holds no fused multiply-add mnemonic (x86: `vfmadd*`,
`vfmsub*`, `vfnmadd*`, `vfnmsub*`, `vfmaddsub*`, `vfmsubadd*`; AArch64: `fmadd`, `fmsub`,
`fnmadd`, `fnmsub`, `fmla`, `fmls`).
