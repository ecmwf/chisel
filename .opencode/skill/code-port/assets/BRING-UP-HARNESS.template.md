# Phase-2 bring-up harness - <FIRST-MODULE>

> Instantiated to `port/bring-up-harness.md` when the FIRST translated module is R0-clean and
> independently reviewed but cannot be proven, because proving needs R1 (a real differential against the
> SOURCE) and the cross-language harness does not exist yet. This is the one-time co-development sprint
> that stands up that harness against `<FIRST-MODULE>`. These are MODELED Phase-1 tooling deliverables,
> so under `/port-autodrive` at L2/L3 they are DRIVEN automatically (`phase1_drive.py`: claim -> work +
> seeded-bug demo -> INDEPENDENT review -> integrate, parallelized, each piece's evidence committed to git) - auto-BUILT but
> never auto-TRUSTED (each carries its seeded-bug + independent review before it proves anything). This file is the
> human-readable spec of those deliverables; at L1, or hand-driven, build it as a normal bounded sprint.
> Build it once; afterwards EVERY module is proven against it and the wave widens.
>
> Why this proof is non-negotiable: R0 proves the TARGET compiles and its internal invariants hold; the
> review proves it is structurally faithful. NEITHER proves it reproduces the SOURCE's numbers on real
> inputs - only the R1 differential does. Marking a unit proven before it exists would ship "faithful" on faith. (See
> `references/validation-ladder.md` R0/R1 and `references/bring-up-strategy.md`.)

Run this as a normal sprint (`/port-sprint-start`, or dispatch a worker), seeded-bug-demoing and
independently reviewing each proof/check before first use (the seeded-bug rule). Acceptance for the
whole sprint: `<FIRST-MODULE>` is PROVEN at R1 against the harness you build here, and `/port-autodrive`
resumes.

## 1. R1 capture-replay (cross-language twin) harness  [the binding deliverable]
The per-kernel R1 twin (`references/validation-ladder.md`, "A canonical ladder", R1):
- [ ] **Fixture generator** (workbench, e.g. `tools/diff/`): instrument the SOURCE on the reference run
      and record `<FIRST-MODULE>`'s inputs and outputs as committed I/O vectors (signed-integer bit
      patterns via `TRANSFER`/`memcpy` for floats - exact, no formatting round-trip).
- [ ] **Replay driver** (product, ships under `tests/`): build the TARGET `<FIRST-MODULE>` on the
      pinned acceptance flags (`-ffp-contract=off`, no fast-math) and run it on the recorded inputs,
      dumping outputs in the same format.
- [ ] **Differential comparator** (the R1 proof): diff SOURCE vs TARGET. Attempt **bit-identity first**
      (`max |Δ| = 0`); fall back to the charter §7 calibrated `atol/rtol` ONLY where the bit compare
      actually differs. Exit non-zero on a miss; record evidence under `docs/evidence/`.
- [ ] **Seeded-bug demo**: plant a wrong literal/value in the TARGET, show the comparator goes RED,
      then remove it -> GREEN. The proof is trusted only after it is seen to fail (`/port-seed`).
- [ ] **Independent review** of the harness itself (a different session/model; it is fidelity-critical
      tooling, reviewed like a piece).

## 2. The TARGET-side conformance checks  [wire existing checks onto the ported tree]
- [ ] **Naming-map check** exercised on the TARGET identifiers (`port/conventions/<source>-to-<target>.md`
      section 2; the deterministic naming map is now enforced against real ported C names).
- [ ] **Provenance-anchor verifier** on the TARGET: every comparable constant cites its SOURCE
      `file:line` with the literal embedded, its value compared with the SOURCE constant's
      (`references/pairs/<source>-to-<target>.md`, the comment/anchor policy).
- [ ] each seeded-bug-demoed where it is a detector, and run in CI on the product checkout (the
      two-root contract, `references/two-repo-architecture.md`).

## 3. Tooling baseline  [the TARGET build hygiene the proof runs on]
- [ ] formatter + linter with the warning floor as errors (`references/langs/<target>.md`);
- [ ] sanitizers (ASan/UBSan) on the test build; `compile_commands.json`; the deterministic
      build-flag contract pinned (compiler + flags), so the proof's result is reproducible - all
      three checked by `tools/build-checks/` after a fresh build (`references/langs/<target>.md`).

## Done when
- `<FIRST-MODULE>` is PROVEN at R1 (proof evidence + the independent review recorded, tier R1+), and
- re-running `/port-autodrive` advances it to integrated and widens the ready-set.
Land the harness/checks through the sanctioned path (reviewed deliverable), then re-drive.
