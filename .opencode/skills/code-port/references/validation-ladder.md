<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Designing the Validation Ladder

The ladder is the spine of the port. It is a sequence of comparison proofs, ordered from
narrowest scope (one kernel) to widest (a full-scale run), each with an acceptance criterion set at
**the strictest level that comparison can physically meet**. A regression at any tier is caught
before it can reach the science.

## The bit-identity rule: match the bar to the transformation

There are exactly two regimes, and confusing them fails in both directions. This section is the one
statement of the rule; the rest of the skill points here.

**Bit-identity is the bar only when nothing that affects arithmetic changes.** When both sides share
the compiler, the flags, the math library and the order of operations, on a deterministic (serial)
backend, exact byte equality is achievable and therefore required: any nonzero difference is a bug.
This covers a same-language stage (a portability-layer rewrite, a backend swap, a refactor, a pure
recompile), the serial twin kept inside the TARGET tree in Phase 3, and a target platform that
preserves arithmetic. Accepting "close enough" there throws away your most precise instrument.

**Everything else is never assumed bit-identical, and bit-identity is never required.** A change of
language, compiler, flags, math library or operation order generally makes byte equality
unattainable, and demanding it wastes the project. The bar is then:
- the SOURCE's own validation criterion at the SOURCE's own declared tolerance, where it has one.
  Before choosing any bar, ask what the SOURCE achieves against itself: mature codes often ship
  acceptance values with a relative tolerance and reproduce the tolerance but not the bits. Read the
  tolerance from that validation data rather than choosing one (failure mode B21);
- otherwise, statistical equivalence of long full-scale runs, designed with the human in charter
  section 7: integrated quantities track the reference within agreed tolerances; the *difference*
  between the runs shows no growing drift (a shared physical drift is fine); residual differences sit
  where the system is naturally most variable or sensitive, not in a systematic large-scale bias;
  conserved quantities are conserved to the same degree. Each metric names the field, the statistic,
  the window, the tolerance with its calibration evidence (a tolerance without evidence is a guess),
  and the failure rule. The human judges acceptance.

Where a cross-language comparison does reproduce bits (pure IEEE arithmetic with floating-point
contraction off often does), record that as evidence: it is a strong regression detector, and a later
change that loses it is a signal to investigate. Observing it is useful; requiring it is not. Never
massage a faithful port to force a bit match it cannot have, and never invent a tolerance to hide a
divergence a faithful port should not have. A charter may set exact equality for a cross-language
stage only after proving it attainable.

**Comparison in the tolerance regime is approximate equality.** Two values match when
`|a - b| <= atol + rtol*|b|`: an absolute bound that dominates near zero plus a relative bound that
scales with magnitude. Both are required and both are set per field, because fields differ in scale
and sensitivity. The agent recommends each pair from measured evidence (the floating-point floor, the
SOURCE's own seed-to-seed spread, the physical scale) and the human confirms or adjusts it through
the calibration brief (`/port-calibrate`). Only the human sets these bands. This applies to every
non-bit-identical comparison: cross-language, the accelerator proof (R4 ceilings are atol/rtol), and
each platform that changes arithmetic. Record the pair next to each metric in the charter.

**Determinism is a runtime property.** Linking a deterministic library does not pin it if another
build shares its SONAME: the loader can resolve a different implementation. Verify the actual runtime
linkage (`ldd` or the platform equivalent) and control it (RPATH or the loader path); a bit-identity
claim on the wrong runtime library is a false pass no seeded bug will catch.

**Chain the two regimes.** If port B is statistically equivalent to SOURCE and port C is
bit-identical to B on a deterministic backend, C inherits B's equivalence with no further proof.
This is why the staged architecture works, and why the serial reference stays alive inside the
TARGET tree.

**The platform axis (Phase 5) follows the same rule.** A platform that preserves arithmetic (same
CPU architecture and compiler family, deterministic backend) is held to bit-identity against the
canonical reference; one that changes it (another architecture, compiler, math library or accelerator
vendor, changing rounding, FMA contraction, intrinsics or reduction order) is held to statistical
parity with its floating-point floor recorded. Chaining carries the home validation onto each.

## A canonical ladder (instantiate per project, in the charter)

- **R0 - Intrinsic acceptance (bring-up only).** Before any differential comparison exists,
  modules are accepted by intrinsic checks agreed with the human (bring-up-strategy.md). R0 is
  scaffolding: R0 evidence never fills the proof field of a `proven` entry, and every R0-accepted
  module later sits under R2 or R5. Fixtures here, and the unit tests of the per-procedure policy,
  start any sub-range away from its array's declared lower bound and pass arrays at their full
  allocated layout; a range starting at the lower bound hides index-base and stride errors (N4).
- **R1 - Per-routine differential.** The lowest tier that can prove a piece. It has two forms, one
  per regime:
  - *Phase-2 R1, the cross-language twin.* The fixture generator (workbench, `tools/diff/`)
    instruments the SOURCE on the reference run and records each routine's inputs and outputs as
    exact bit patterns. The replay driver (product, `tests/`) runs the TARGET routine on those inputs,
    and the comparator checks every output field at the routine's recorded atol/rtol, reporting
    whether the bits also matched. A pure, narrow routine may use a classic unit test against direct
    evaluation of the SOURCE function instead (the per-procedure policy below). This harness is built
    once, with the first translated module, in the bring-up harness sprint (bring-up-strategy.md).
  - *Phase-3 R1, the serial twin.* Every ported kernel keeps its serial reference twin in the TARGET
    tree. A runtime verify mode (switch-controlled) runs both on live state at every invocation,
    records max |Δ|, and restores the reference result so the run is undisturbed; it can stay on for a
    whole full-scale run. Acceptance on a deterministic backend: **max |Δ| = 0**.
  Either way the twin keeps its own copy of every coefficient, so a mistyped constant fails at once.
  For a compiled TARGET, R1 also runs the TARGET's runtime checks - the ones its target-conventions
  `references/langs/<target>.md` requires (for C, the sanitizer builds) - on the unit's tests at the
  same commit. A differential that matches does not show a read past an array or of an uninitialized
  value that happened to hold the right bits; a unit with a runtime-check report is not proven.
- **R2 - Whole-model acceptance.** The full port, deterministic backend, at a fixed process count,
  over a full-length run. A bit-identity stage: byte-identical to the reference, every field of every
  snapshot. A cross-language stage: the charter section 7 acceptance (the SOURCE's own validation in
  every configuration the port builds, or the statistical test design), with the exact-sensitive
  artifacts byte-compared as a reported signal. Make the verdict machine-readable and bind it to the
  artifact actually run (path plus content hash), so the proof cannot certify the reference binary
  while claiming to test the port.
- **R3 - Threaded backend.** Kernels that only map or gather: identical to R2. Kernels that reduce
  across threads: a small per-step floor reflecting summation order only, calibrated and recorded.
- **R4 - Accelerator pre-commit proof.** A mandatory short run (tens of steps) of the realistic
  configuration with all subsystems active, compared field by field against the deterministic
  reference with per-field ceilings calibrated against the recorded floating-point floor (a real bug
  usually saturates orders of magnitude above it). Record the steady floor pattern in
  `KNOWN-DIVERGENCES.md`. Mandatory before any commit that touches device data movement.
- **R5 - Multi-run statistical parity.** Full-length runs compared against both the original SOURCE
  and the intermediate reference with the Phase-2 statistical metrics. The accelerator's drift should
  sit orders of magnitude below the cross-language uncertainty established in Phase 2.

**Choose the compared artifact for exactness.** A whole-run comparison is only as sensitive as the
artifact you diff. Quantized or post-processed outputs can absorb a real last-bit defect: in one
measured case a one-ULP perturbation left every gridded output byte-identical and passed the
tolerance validator, while the run's statistics log and final restart files showed it. Diff the
exact-sensitive artifacts and treat a byte difference there as a signal to investigate; that is what
lets one proof tolerate legitimate cross-language variation and still see a one-bit regression.
Wherever exact comparison is the bar, compare bit representations as same-width integers, never
through a formatted round-trip (the pair reference shows how in each language).

## Per-procedure verification policy

Hand-written isolated unit tests are impractical only for *wide-footprint* routines, whose inputs
are slices of a large, invariant-laden global state and whose only honest oracle is the reference
itself. Classify every routine by state footprint and verify it accordingly:

| Routine class | Verification | Oracle |
|---|---|---|
| Pure / narrow-footprint (math kernels, formulae, interpolation, utilities) | Classic unit tests, hand-written or generated; run in CI forever | Direct evaluation of the SOURCE function |
| Wide-footprint / stateful | Capture-replay: record the full read-set and outputs from the instrumented reference run, replay the inputs into the ported routine, compare at a recorded per-routine tolerance | The reference dump |
| Seams / composition (interfaces, call order, exchange timing) | The ladder tiers (staged dumps, whole-run proofs) | The canonical reference run |

- Capture-replay at routine granularity is per-function testing: the live model generates the
  fixtures and the dump is the oracle. Over a full-scale run it checks the routine against the real
  distribution of states, stronger than any finite hand-written set.
- A wrong read-set silently tests less than you think. Extract read-sets with tooling (compiler
  interface audits, access tracing), not by hand, and record each next to its fixture.
- Error amplification varies widely between routines (cancellation-heavy code amplifies, smooth maps
  do not). Record each per-routine tolerance with its calibration evidence, set it by the bit-identity
  rule above, and surface it to the human as a decision.
- Routines with communication inside do not replay in one process; they belong to the seam row.
- A stage that turns global state into explicit arguments makes the TARGET far more unit-testable
  than the SOURCE; exploit it, since those tests keep paying after the port ships.
- Tests are product-owned: drivers in the product's `tests/unit/`, the vectors they replay in
  `tests/fixtures/`, built and run by the product's own test command, so a clone is self-testing.
  The fixture generator, which instruments the SOURCE, stays in the workbench. Small, non-sensitive
  fixtures ship with the product; large or SOURCE-sensitive ones stay in the workbench and run from
  workbench CI. Never author tests into a workbench `tests/` that the product build reaches into;
  `check-product-tests.sh` enforces both halves.
- Friction is an empirical question: measure harness cost, read-set effort and tolerance effort on
  the first routines, and let that set the policy boundary for the rest.

## The accepted-divergence registry

Some differences are correct and must not be chased: partition-dependent reduction order,
iteration-order tie-breaking, documented SOURCE nondeterminism, the recorded accelerator floor.
Record each once, with human sign-off, in `port/KNOWN-DIVERGENCES.md` with its magnitude, signature
and the evidence that it is benign. Every debugging workflow starts there, and every proof report
subtracts it (failure mode B4).

## Rules of thumb

- **Bit-identity is process-count-specific.** Exchange and global-sum order depend on the
  decomposition: record the canonical rank and thread count and test identity there. Separately,
  test statistical invariance across rank counts (and byte-identity where the algorithm allows), since
  silent boundary bugs appear only at some decompositions. Make the canonical configuration itself
  multi-chunk (partition size below the points per rank) and run the whole-run proof at two or more
  decompositions: one chunk on one rank hides index-base and stride errors (N4).
- **Validate at full-scale settings.** The real inputs, sizes and duration the code is run at, never
  a smoke test or a small "representative" sample. Latent bugs (N1) are invisible at short or small
  settings. At least one R2 or R5 run uses the real settings over a full-length run.
- **Proofs detect; tools localize.** The ladder says a tier failed; the differential tooling says
  where. Build both in Phase 1.
- **Inertness checks at phase boundaries.** With new code behind a switch set off, the model
  reproduces the previous tagged commit's outputs byte for byte (results, not the executable;
  differential-tooling.md).
- **Expected accelerator divergence has two named causes:** fused multiply-add or builtin-intrinsic
  rounding, and reduction order. Any other attribution is a bug. Pin FMA behavior in the build rather
  than relying on a compiler default.
- **Proofs are scripts, not rituals.** Every tier lives in `tools/proofs/` with exit-code semantics
  and runs in CI where feasible. Evidence (logs, diff reports, floor recordings) goes to
  `docs/evidence/`.
- **A proof never compares stale artifacts** (AGENTS.md). The same holds for dump and fixture
  generation: regenerate or verify freshness, never assume.
- **A proof is trusted only after it has been seen to fail.** Before first real use, every proof and
  probe fires on a seeded bug representative of the failure class it targets (never a syntax error),
  recorded with `assets/SEEDED-BUG.template.md` through `/port-seed`, and re-demonstrated after any
  change to its comparison logic. A buggy always-pass proof is worse than none.
- **A per-unit proof is necessary but not sufficient for composed units.** When units are chained
  through a shared or reinterpreted buffer, each can pass its own capture-replay proof while the
  composition is broken. The binding proof is end-to-end over the composed pipeline, with inputs that
  force two or more units in sequence (N9).
- **A bring-up proof includes every build-free conformance check that applies to its artifact**
  (naming, index helpers, anchor coverage), wired in as stages, so a proven artifact cannot violate a
  check that only runs elsewhere. CI automates the same set.
- **A driver proof exercises every branch it wires.** When a proof drives a routine that dispatches
  to proven leaves under a runtime condition, it enters each major branch, not only the default. A
  leaf's own proof does not show the driver called it correctly (argument order, leading dimensions,
  pre-zeroing).
- **A proof that routes values uses distinct inputs.** A proof of forwarding, slicing or transposing
  must give every forwarded value a pairwise distinct value and fold each with a distinct weight;
  equal values hide a swap or an omission, so a proof that passes only on uniform inputs has not
  proven the routing.
