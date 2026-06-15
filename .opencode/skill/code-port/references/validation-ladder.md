# Designing the Validation Ladder

The ladder is the spine of the port. It is a sequence of comparison gates, ordered from
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
human CONFIRMS or adjusts them. This applies to every non-bit-identical comparison in
the project - cross-language (this regime), the accelerator gate (R4 per-field
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
  module must later sit under R2/R5, and R0 evidence may NEVER populate the gate
  field of a `gated` TRACE entry. See `bring-up-strategy.md`.
- **R1 - Per-kernel twin check.** Every ported kernel keeps its reference twin in the
  source. A runtime verify mode (environment-switched) runs both on live state at every
  invocation, records max |Δ|, and restores the reference result so the run is
  undisturbed - it can stay on for an entire full-scale run. Deterministic backend
  acceptance: **max |Δ| = 0**. The twin keeps its own copy of every coefficient, so a
  mistyped constant fails the gate immediately.
- **R2 - Whole-model deterministic identity.** The full port, deterministic backend,
  byte-identical to the reference over a full full-length run, at a fixed
  process count, comparing every field of every output snapshot.
- **R3 - Threaded backend.** Kernels that only map/gather: identical to R2. Kernels
  that reduce across threads: a small per-step floor reflecting summation reorder only
  (calibrate the value per project and record it).
- **R4 - Accelerator pre-commit gate.** Mandatory short run (tens of steps) of the
  *realistic* configuration with all subsystems active, compared field-by-field against
  the deterministic reference with per-field ceilings. Calibrate ceilings against the
  recorded floating-point floor: a real bug typically saturates orders of magnitude
  above it, so the gate separates last-bit divergence from error cleanly. Record the steady-state floor
  pattern in KNOWN-DIVERGENCES.md so regressions stand out against it. This gate is
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
| Seams / composition (interfaces, call order, exchange timing) | The ladder tiers (staged dumps, whole-run gates) | The canonical reference run |

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
- Routines with communication inside do not replay meaningfully in a single process;
  they belong to the seam row.
- A port stage that removes global state (globals to explicit context arguments) makes
  the TARGET side dramatically more unit-testable than the SOURCE. Exploit this:
  classic unit tests written against the port keep paying after the port ships.
- Friction is an empirical question. On a pilot, measure harness cost per routine,
  read-set extraction effort, and tolerance-selection effort, and let that evidence
  set the policy boundary for the large port.

## The accepted-divergence registry

Some differences are *correct* and must not be chased: partition-dependent reduction
order, tie-breaking that depends on iteration order, documented SOURCE nondeterminism,
the recorded accelerator floating-point floor. Record each in
`port/KNOWN-DIVERGENCES.md` with its magnitude, signature, and the evidence that it is
benign - once, with human sign-off. Every debugging workflow starts by checking the
registry; every gate report subtracts it. Without the registry, every new sprint (and
every parallel workstream) re-investigates the same ghosts.

## Rules of thumb

- **Bit-identity is process-count-specific.** Exchange order and global-sum order depend
  on the domain decomposition; record the canonical rank/thread count and test identity
  there. A *separate* useful gate: statistical invariance across rank counts (and
  byte-identity across rank counts where the algorithm permits) - silent boundary bugs
  often appear only at some decompositions.
- **Validate at full-scale settings.** The full-scale, real-use configuration means
  the actual inputs, sizes, and duration the code is genuinely run at - never a quick
  smoke test (and never a small "representative" sample; full scale is the point).
  Latent bugs (mis-ported constants, marginal stability) can be invisible at the
  small or short settings of a smoke test and ruinous at full scale. At least one
  R2/R5 run must be at the real settings (for a simulation, e.g., the full timestep
  and resolution; for other code, the real input sizes) over a full-length run.
- **Gates detect; tools localize.** The ladder tells you a tier failed; the differential
  tooling tells you where. Build both in Phase 1.
- **Inertness checks at phase boundaries.** When new code lands behind a switch, the
  model with the switch OFF must reproduce the previous tagged commit's outputs
  byte-for-byte (results, not the executable - see `differential-tooling.md`). This
  proves the new code is inert when it should be and catches gating mistakes.
- **Expected accelerator divergence has two named causes** - fused-multiply-add /
  builtin-intrinsic rounding, and reduction-order change. If you find yourself
  attributing a divergence to anything else, it is a bug. Pin FMA behavior explicitly
  in the build (e.g., keep host FMA off as the portable determinism setting) rather
  than relying on a compiler default.
- **Gates are scripts, not rituals.** Every tier lives in `tools/gates/` with exit-code
  semantics and runs in CI where feasible. Evidence (logs, diff reports, floor
  recordings) goes to `docs/evidence/` and is linked from the plan at sign-off.
- **A gate never compares stale artifacts.** A gate script that wraps the SOURCE
  or TARGET build invokes it unconditionally - never keyed on "output exists" or
  an mtime check, because the inner build tool already knows what is stale and
  the wrapper does not. A gate comparing a stale binary against current code is
  a false-pass machine, and the seeded-bug demonstration will not catch it (the
  demonstration rebuilds). Same rule for dump/fixture generation: regenerate or
  verify freshness, never assume.
- **A gate is trusted only after it has been seen to fail.** Before first real use,
  every gate and probe demonstrates firing on a seeded bug (inject a known error,
  show the gate goes red, remove it, show green); record the demonstration using
  `assets/SEEDED-BUG.template.md` (the /port-seed command runs the whole
  procedure). The seeded defect must be representative of the failure class the
  detector targets, never a trivial syntax error. A buggy always-pass gate is worse
  than no gate, and this is the cheap way to rule one out. Re-demonstrate after any
  change to comparison logic.
- **A per-unit gate is necessary but not sufficient for a COMPOSED unit.** When units are
  chained through a shared or reinterpreted buffer - one pass's output is the next's input
  through the same scratch memory, possibly reshaped - each unit can pass its own isolated
  capture-replay gate while their composition is broken: the isolated gate certifies the
  unit against its own inputs, not against the byte layout the next unit expects. The
  BINDING gate is the end-to-end one over the composed pipeline, and its inputs must be
  chosen to FORCE multi-unit composition (paths or sizes that exercise two or more units in
  sequence, never the single-unit paths that dodge the seam). Build it before trusting the
  unit gates; a suite of green unit gates over a broken composition is the exact shape of
  false confidence (failure mode L9 in `failure-modes.md`).
