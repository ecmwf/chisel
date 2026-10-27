<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Designing the Validation Ladder

The ladder is the spine of the port. It is a sequence of comparison proofs, ordered from
narrowest scope (one kernel) to widest (a full-scale run), each with an
acceptance criterion set at **the strictest level that comparison can physically meet**.
A regression at any tier is caught before it can reach the science.

## The central principle: match the bar to the transformation

There are exactly two regimes, and confusing them fails in both directions.

**Cross-language / cross-compiler comparisons must never be assumed bit-for-bit.** A
change of language, compiler, optimization flags, math library, or arithmetic
ordering generally makes byte-level equality unattainable and meaningless, and
demanding it by default wastes the project. (If a particular project can genuinely
achieve exact equality, e.g. a shared compiler backend at pinned flags, the charter
may set that stricter bar; it must be proven attainable, never assumed.) The default
bar is **statistical equivalence of long, full-scale runs**:
- integrated/aggregate quantities track the reference within pre-agreed tolerances;
- the *difference* between the runs shows no growing drift (the two runs may share a
  physical drift - that is fine; their differential drift must be flat);
- residual spatial/structural differences are confined to the system's regions of
  strongest natural variability or sensitivity, rather than forming a systematic
  large-scale bias;
- conserved quantities are conserved to the same degree.
Define the test design in the charter *before* translation starts, with the domain
expert - per metric: the field, the exact statistic, the comparison window/duration,
the tolerance WITH its calibration evidence (a tolerance without evidence is a
guess), and the failure rule (what observation rejects equivalence). The human
judges acceptance.

**The comparison itself is approximate equality, never exact, in this regime.** Two
values match when `|a - b| <= atol + rtol*|b|`: an ABSOLUTE bound `atol` that
dominates near zero, plus a RELATIVE bound `rtol` that scales with magnitude. Both
are required - absolute-only is wrong for large values, relative-only is wrong near
zero - and both are set PER FIELD, because fields differ in scale and sensitivity; a
single global tolerance is a mistake. The agent RECOMMENDS the two bounds for each
field (from the recorded floating-point floor and the field's physical scale) and the
human CONFIRMS or adjusts them - as a guided, evidence-backed **calibration brief**
(`/port-calibrate`): the recommended band, the MEASURED evidence behind it (the fp floor,
SOURCE's own seed-to-seed spread, the physical scale), the risk both ways, and a good-vs-bad
signature, so a non-expert operator confirms a band rather than guessing a number. This applies to every non-bit-identical comparison in
the project - cross-language (this regime), the accelerator proof (R4 per-field
ceilings ARE atol/rtol), and each arithmetic-changing platform (Phase 5). Record the
`atol`/`rtol` pair next to each metric in the charter.

**Same-compiler, deterministic-backend comparisons can and must be bit-for-bit.** When
the reference and the port share a compiler and flags and the backend is deterministic
(serial), exact byte equality is achievable - and therefore required, because it is a
*perfect* detector: any nonzero difference is a bug, full stop. Accepting "close enough"
here throws away your most precise instrument.

**Determinism is a RUNTIME property, not only a link-time one.** Selecting a deterministic
library at link time does not pin it if another build shares the same SONAME - the loader
can resolve the runtime library to a different implementation (e.g. a reference vs an
optimized BLAS/LAPACK). Verify the ACTUAL runtime linkage (loader resolution, `ldd`) and
control it (RPATH or the loader search path); a bit-identity claim built on the wrong
runtime library is a false pass that no seeded-bug demonstration will catch.

**Chain the two regimes:** if port B is statistically equivalent to SOURCE, and port C
is bit-identical to B on a deterministic backend, then C inherits B's statistical
equivalence with no further proof. This chaining is why the staged architecture works,
and why the deterministic reference must be kept alive inside the TARGET tree.

**The two regimes apply to the platform axis too (Phase 5).** A new target platform is
classified the same way: a recompile that preserves arithmetic (same CPU architecture
and compiler family, deterministic backend) is held to bit-identity against the
canonical reference; a platform that changes arithmetic (different CPU architecture,
accelerator vendor, compiler, or math library - changing rounding, FMA contraction,
intrinsics, or reduction order) can never be bit-for-bit and is held to statistical
parity, with its floating-point floor recorded. Chaining carries the home-platform
validation onto each new platform within whichever bar that platform meets.

## A canonical ladder (instantiate per project, in the charter)

- **R0 - Intrinsic acceptance (bring-up only).** Before a differential comparison is
  even possible - early Phase 2, when only a fraction of the model exists - accept
  modules by *intrinsic* physical checks: an equilibrium state stays at equilibrium, a
  disturbance propagates at its known analytic speed, a long run of small steps stays
  stable, conserved quantities are conserved. R0 is scaffolding: every R0-accepted
  module must later sit under R2/R5, and R0 evidence may NEVER populate the proof
  field of a `proven` TRACE entry. See `bring-up-strategy.md`. Fixtures at this tier - and
  the classic unit tests of the per-procedure policy below - start any sub-range AWAY from
  its array's declared lower bound and pass arrays at their full allocation layout: a range
  starting at the lower bound makes index-base and stride errors bit-identical to correct
  code (failure mode L4 in `failure-modes.md`).
- **R1 - Per-kernel twin check.** Every ported kernel keeps its reference twin in the
  source. A runtime verify mode (environment-switched) runs both on live state at every
  invocation, records max |Δ|, and restores the reference result so the run is
  undisturbed - it can stay on for an entire full-scale run. Deterministic backend
  acceptance: **max |Δ| = 0**. The twin keeps its own copy of every coefficient, so a
  mistyped constant fails the proof immediately.

  **Cross-language R1: do NOT make bit-identity the admission bar.** When the TARGET
  language differs from the SOURCE, `max |Δ| = 0` is the wrong ACCEPTANCE criterion, and
  adopting it is an expensive mistake with a specific shape. Before setting any bar, ask
  what the SOURCE ITSELF achieves against itself: mature numerical codebases commonly ship
  their own acceptance values with a declared RELATIVE TOLERANCE, and a reference build
  frequently reproduces those tolerances while NOT reproducing the bit patterns. If the
  reference implementation does not reproduce itself to the bar you are enforcing, the bar
  is wrong - and no amount of correct work underneath a wrong bar becomes right.

  Published practice agrees: an LLM-assisted port of a production geophysical model
  (Fortran to C, then to a performance-portability layer) accepted its CROSS-LANGUAGE stage
  on long-term simulation statistics, on the explicit grounds that "bit-for-bit agreement
  across compilers and arithmetic orderings is neither attainable nor necessary" for a
  change of language - and reserved exact equality for the SAME-COMPILER stage, where it is
  both achievable and a precise detector of the errors that stage can introduce.

  So stage the ladder by what each stage can actually be held to:

  - **A cross-language stage** (SOURCE language -> TARGET language) is accepted on the
    SOURCE's own validation criterion at the SOURCE's own declared tolerance, for every
    entry, in every configuration the port builds. Read the tolerance FROM the source's
    validation data rather than choosing one - a bar you derive is a bar you can defend.
  - **A same-language, same-compiler stage** (a portability-layer rewrite, a backend swap,
    a refactor) IS held to `max |Δ| = 0`, because there the equality is attainable and any
    difference is a real defect in exactly the thing that stage changed.

  **Still attempt bit-identity, and still record it - as EVIDENCE, not as a licence.**
  A routine of pure IEEE arithmetic often does reproduce bit-for-bit across compilers with
  FP contraction disabled, and where it does, that is a strong regression detector and worth
  having. The distinction is that observing it is useful while REQUIRING it, per routine,
  against another language, is not.

  **Choose the compared artifact for exactness, not convenience.** Whatever the bar, a
  whole-run comparison is only as sensitive as the artifact you diff. Quantized or
  post-processed outputs can absorb a genuine last-bit defect entirely: in one measured case
  a one-ULP perturbation left every gridded output file byte-identical AND passed the
  tolerance validator, while the run's own statistics log and final restart files both
  showed it. Diff the exact-sensitive artifacts, and treat a byte difference there as a
  SIGNAL to investigate rather than an automatic failure - that separation is what lets the
  same proof be both tolerant of legitimate cross-language variation and sensitive to a
  one-bit regression.

  **The bit-pattern comparison technique remains correct** wherever exact comparison IS the
  bar: extract the bit representation on each side (in Fortran `TRANSFER(x, integer_kind)`,
  in C `memcpy` to a same-width integer) and compare the integers - exact, and free of any
  floating-point formatting round-trip.
- **R2 - Whole-model acceptance.** The full port, deterministic backend, at a fixed process
  count, over a full-length run. For a SAME-COMPILER stage: byte-identical to the reference,
  every field of every snapshot. For a CROSS-LANGUAGE stage: passing the SOURCE's own
  validation at the SOURCE's own declared tolerance, in every configuration the port builds,
  with the exact-sensitive artifacts (run statistics, final restart state) byte-compared as a
  reported SIGNAL rather than a pass/fail condition. Make the verdict machine-readable and
  bind it to the ARTIFACT ACTUALLY RUN - path plus content hash - so the proof cannot certify
  the reference binary while claiming to test the port.
- **R3 - Threaded backend.** Kernels that only map/gather: identical to R2. Kernels
  that reduce across threads: a small per-step floor reflecting summation reorder only
  (calibrate the value per project and record it).
- **R4 - Accelerator pre-commit proof.** Mandatory short run (tens of steps) of the
  *realistic* configuration with all subsystems active, compared field-by-field against
  the deterministic reference with per-field ceilings. Calibrate ceilings against the
  recorded floating-point floor: a real bug typically saturates orders of magnitude
  above it, so the proof separates last-bit divergence from error cleanly. Record the steady-state floor
  pattern in KNOWN-DIVERGENCES.md so regressions stand out against it. This proof is
  mandatory before any commit that touches device data movement: bugs in that layer can
  be invisible on the fast rig and surface only with all subsystems active.
- **R5 - Multi-run statistical parity.** Full-length runs compared against BOTH
  the original SOURCE and the intermediate reference, using the Phase-2 statistical
  metrics. The accelerator's drift should sit orders of magnitude below the
  cross-language uncertainty established in Phase 2.

## Per-procedure verification policy

"Unit testing is impractical for stateful numerical code" is an overstatement; the
accurate statement is that hand-written, isolated unit tests are impractical for
*wide-footprint* routines, because their inputs are slices of a large, invariant-laden
global state and their only honest oracle is the reference itself. Resolve this by
classifying every routine by **state footprint** and assigning the verification mode
accordingly:

| Routine class | Verification | Oracle |
|---|---|---|
| Pure / narrow-footprint (math kernels, formulae, interpolation, utilities) | Classic unit tests, hand-written or generated; run in CI forever | Direct evaluation of the SOURCE function |
| Wide-footprint / stateful | Systematic capture-replay: record the routine's full read-set and outputs from the instrumented reference run; replay the inputs into the ported routine; compare within a recorded per-routine tolerance | The reference dump |
| Seams / composition (interfaces, call order, exchange timing) | The ladder tiers (staged dumps, whole-run proofs) | The canonical reference run |

Notes and caveats, learned the hard way:

- Capture-replay at routine granularity IS per-function testing; the live model is the
  fixture generator and the dump is the oracle. Over a full-scale run it checks the
  routine against the full distribution of real states, which is stronger than any
  finite hand-written fixture set.
- Identifying the full read/write-set of a routine with global state is itself
  error-prone: get the read-set wrong and the replay silently tests less than you
  think. Treat read-set extraction as tooling (compiler interface audits, access
  tracing), not as a manual listing, and record the read-set next to the fixture.
- Per-routine tolerances across compilers are fiddly: error amplification varies
  wildly between routines (cancellation-heavy code amplifies; smooth maps do not).
  Record each tolerance with its calibration evidence; a tolerance without evidence
  is a guess.
- The regime is set PER ROUTINE by its OPERATION SET, not by the language pair alone.
  A routine of pure IEEE arithmetic (`+ - * /`, `sqrt`, integer powers, with FP
  contraction disabled) reproduces bit-for-bit even across a language change, and must
  be held to that exact bar - it is a perfect detector. A routine that calls a
  transcendental (`exp`, `log`, non-integer power, trig) cannot: the two languages'
  math libraries differ, so a faithful port diverges in the last bits and belongs in
  the tolerance regime (calibrated per routine). Classify each routine by what it
  computes. Refuse both failure directions: never massage a faithful port to force a
  bit-match it physically cannot have, and never invent a tolerance to paper over a
  divergence a faithful port should not have - record the achievable tier and surface
  the per-routine calibration as a decision for the human.
- Routines with communication inside do not replay meaningfully in a single process;
  they belong to the seam row.
- A port stage that removes global state (globals to explicit context arguments) makes
  the TARGET side dramatically more unit-testable than the SOURCE. Exploit this:
  classic unit tests written against the port keep paying after the port ships.
- Tests are **product-owned** so they actually ship and keep paying: the test drivers live
  in the product tree under `tests/` (`tests/unit/` for the drivers, `tests/fixtures/` for the
  captured input/output vectors they replay), built and run by the product's own build
  (`make test`), so a clone of the product is self-testing. The fixture GENERATOR - it
  instruments the SOURCE - stays in the workbench (`tools/diff/`); only the drivers and the
  vectors they replay are product-owned. Commit small/non-sensitive fixtures with the product;
  keep large or SOURCE-sensitive ones in the workbench and run those from workbench CI. Never
  author tests into a workbench `tests/` with the product build reaching out for them (the v1
  orphan trap) - `conformance/check-product-tests.sh` enforces both halves.
- Friction is an empirical question. On the first routines ported, measure harness
  cost per routine, read-set extraction effort, and tolerance-selection effort, and
  let that evidence set the policy boundary for the rest of the port.

## The accepted-divergence registry

Some differences are *correct* and must not be chased: partition-dependent reduction
order, tie-breaking that depends on iteration order, documented SOURCE nondeterminism,
the recorded accelerator floating-point floor. Record each in
`port/KNOWN-DIVERGENCES.md` with its magnitude, signature, and the evidence that it is
benign - once, with human sign-off. Every debugging workflow starts by checking the
registry; every proof report subtracts it. Without the registry, every new sprint (and
every parallel workstream) re-investigates the same ghosts.

## Rules of thumb

- **Bit-identity is process-count-specific.** Exchange order and global-sum order depend
  on the domain decomposition; record the canonical rank/thread count and test identity
  there. A *separate* useful proof: statistical invariance across rank counts (and
  byte-identity across rank counts where the algorithm permits) - silent boundary bugs
  often appear only at some decompositions. Make the canonical configuration itself
  MULTI-CHUNK (a partition size below the points per rank) and run the whole-run proof at
  two or more decompositions: with one chunk on one rank the only chunk starts at its arrays'
  lower bounds, which makes index-base and stride errors bit-identical to correct code -
  they have survived every per-unit proof and review that way (failure mode L4 in
  `failure-modes.md`).
- **Validate at full-scale settings.** The full-scale, real-use configuration means
  the actual inputs, sizes, and duration the code is genuinely run at - never a quick
  smoke test (and never a small "representative" sample; full scale is the point).
  Latent bugs (mis-ported constants, marginal stability) can be invisible at the
  small or short settings of a smoke test and ruinous at full scale. At least one
  R2/R5 run must be at the real settings (for a simulation, e.g., the full timestep
  and resolution; for other code, the real input sizes) over a full-length run.
- **Proofs detect; tools localize.** The ladder tells you a tier failed; the differential
  tooling tells you where. Build both in Phase 1.
- **Inertness checks at phase boundaries.** When new code lands behind a switch, the
  model with the switch OFF must reproduce the previous tagged commit's outputs
  byte-for-byte (results, not the executable - see `differential-tooling.md`). This
  proves the new code is inert when it should be and catches switching mistakes.
- **Expected accelerator divergence has two named causes** - fused-multiply-add /
  builtin-intrinsic rounding, and reduction-order change. If you find yourself
  attributing a divergence to anything else, it is a bug. Pin FMA behavior explicitly
  in the build (e.g., keep host FMA off as the portable determinism setting) rather
  than relying on a compiler default.
- **Proofs are scripts, not rituals.** Every tier lives in `tools/proofs/` with exit-code
  semantics and runs in CI where feasible. Evidence (logs, diff reports, floor
  recordings) goes to `docs/evidence/` and is linked from the plan at sign-off.
- **A proof never compares stale artifacts.** A proof script that wraps the SOURCE
  or TARGET build invokes it unconditionally - never keyed on "output exists" or
  an mtime check, because the inner build tool already knows what is stale and
  the wrapper does not. A proof comparing a stale binary against current code is
  a false-pass machine, and the seeded-bug demonstration will not catch it (the
  demonstration rebuilds). Same rule for dump/fixture generation: regenerate or
  verify freshness, never assume.
- **A proof is trusted only after it has been seen to fail.** Before first real use,
  every proof and probe demonstrates firing on a seeded bug (inject a known error,
  show the proof goes red, remove it, show green); record the demonstration using
  `assets/SEEDED-BUG.template.md` (the /port-seed command runs the whole
  procedure). The seeded defect must be representative of the failure class the
  detector targets, never a trivial syntax error. A buggy always-pass proof is worse
  than no proof, and this is the cheap way to rule one out. Re-demonstrate after any
  change to comparison logic.
- **A per-unit proof is necessary but not sufficient for a COMPOSED unit.** When units are
  chained through a shared or reinterpreted buffer - one pass's output is the next's input
  through the same scratch memory, possibly reshaped - each unit can pass its own isolated
  capture-replay proof while their composition is broken: the isolated proof certifies the
  unit against its own inputs, not against the byte layout the next unit expects. The
  BINDING proof is the end-to-end one over the composed pipeline, and its inputs must be
  chosen to FORCE multi-unit composition (paths or sizes that exercise two or more units in
  sequence, never the single-unit paths that dodge the seam). Build it before trusting the
  unit proofs; a suite of green unit proofs over a broken composition is the exact shape of
  false confidence (failure mode L9 in `failure-modes.md`).
- **A bring-up proof is a superset of every target-applicable conformance check.** When
  a build-free conformance check (naming, index helpers, anchor coverage, ...) applies
  to the artifact a proof covers, wire it INTO the proof as a stage. A proven artifact
  must not violate a check that runs only elsewhere (CI, a separate script) - if it
  can, "proven" understates conformance and the proof is lying about what it certifies.
  The proof's stages are the complete set of detectors the artifact must pass before
  its status flips; CI merely automates the same set.
- **An orchestrator proof exercises every conditional branch it wires.** When a proof
  drives an orchestrator that dispatches to proven leaves under a runtime condition
  (e.g., a field-count flag enabling a branch), the proof must exercise EACH major
  branch - not just the default path. A leaf's own proof covers the leaf; it does NOT
  prove the orchestrator called it correctly (argument order, leading-dimension
  threading, pre-zeroing). Construct inputs that enter each branch; a proof that
  fixes a condition false leaves the orchestrator's wiring of that branch
  unmeasured.
