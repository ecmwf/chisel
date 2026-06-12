# Designing the Validation Ladder

The ladder is the spine of the port. It is a sequence of comparison gates, ordered from
narrowest scope (one kernel) to widest (a full production-scale run), each with an
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
bar is **statistical equivalence of long, production-configuration runs**:
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

**Same-compiler, deterministic-backend comparisons can and must be bit-for-bit.** When
the reference and the port share a compiler and flags and the backend is deterministic
(serial), exact byte equality is achievable - and therefore required, because it is a
*perfect* detector: any nonzero difference is a bug, full stop. Accepting "close enough"
here throws away your most precise instrument.

**Chain the two regimes:** if port B is statistically equivalent to SOURCE, and port C
is bit-identical to B on a deterministic backend, then C inherits B's statistical
equivalence with no further proof. This chaining is why the staged architecture works,
and why the deterministic reference must be kept alive inside the TARGET tree.

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
  undisturbed - it can stay on for an entire production run. Deterministic backend
  acceptance: **max |Δ| = 0**. The twin keeps its own copy of every coefficient, so a
  mistyped constant fails the gate immediately.
- **R2 - Whole-model deterministic identity.** The full port, deterministic backend,
  byte-identical to the reference over a full production-duration run, at a fixed
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
- **R5 - Multi-run statistical parity.** Production-duration runs compared against BOTH
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
  fixture generator and the dump is the oracle. Over a production run it checks the
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
registry; every gate report subtracts it. Without the registry, every new session (and
every parallel workstream) re-investigates the same ghosts.

## Rules of thumb

- **Bit-identity is process-count-specific.** Exchange order and global-sum order depend
  on the domain decomposition; record the canonical rank/thread count and test identity
  there. A *separate* useful gate: statistical invariance across rank counts (and
  byte-identity across rank counts where the algorithm permits) - silent boundary bugs
  often appear only at some decompositions.
- **Validate at production settings.** Latent bugs (mis-ported constants, marginal
  stability) can be invisible at the short timestep / coarse resolution of a smoke test
  and ruinous at production settings. At least one R2/R5 run must be at the production
  timestep, resolution, and a production-relevant duration.
- **Gates detect; tools localize.** The ladder tells you a tier failed; the differential
  tooling tells you where. Build both in Phase 1.
- **Inertness checks at phase boundaries.** When new code lands behind a switch, the
  model with the switch OFF must reproduce the previous tagged commit byte-for-byte.
  This proves the new code is inert when it should be and catches gating mistakes.
- **Expected accelerator divergence has two named causes** - fused-multiply-add /
  builtin-intrinsic rounding, and reduction-order change. If you find yourself
  attributing a divergence to anything else, it is a bug. Pin FMA behavior explicitly
  in the build (e.g., keep host FMA off as the portable determinism setting) rather
  than relying on a compiler default.
- **Gates are scripts, not rituals.** Every tier lives in `tools/gates/` with exit-code
  semantics and runs in CI where feasible. Evidence (logs, diff reports, floor
  recordings) goes to `docs/evidence/` and is linked from the plan at sign-off.
- **A gate is trusted only after it has been seen to fail.** Before first real use,
  every gate and probe demonstrates firing on a seeded bug (inject a known error,
  show the gate goes red, remove it, show green); record the demonstration using
  `assets/SEEDED-BUG.template.md` (the /seeded-bug command runs the whole
  procedure). The seeded defect must be representative of the failure class the
  detector targets, never a trivial syntax error. A buggy always-pass gate is worse
  than no gate, and this is the cheap way to rule one out. Re-demonstrate after any
  change to comparison logic.
