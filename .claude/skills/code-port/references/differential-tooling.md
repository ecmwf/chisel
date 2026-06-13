# Differential-Testing and Debugging Tools

Build these in Phase 1, **before translating any code**, and instrument BOTH sides -
the original SOURCE included. Each tool compares port against reference at a finer grain
than the ladder tier above it. Build them once, during the language stage, and expect to
reuse them unchanged for the execution-model stage - the cost amortizes across the whole
project.

## Design rules

- Every tool is **gated so the reference is unperturbed when it is off**, and the
  inertness guarantee is on RESULTS, not on the executable: with all instrumentation off,
  the build reproduces the reference run's outputs byte-for-byte (the same comparison the
  ladder uses). Instrumentation that perturbs the reference invalidates every comparison.
  Prefer compile-time gating (a preprocessor switch that removes the tool when unset) so
  it cannot perturb ANY run, not only the one you measured; a runtime environment variable
  is acceptable only when the off-path is provably side-effect-free. Do NOT require a
  hash-identical binary: reproducible builds are a separate discipline (timestamps, paths,
  build-ids, Fortran `.mod` stamps) and binary identity is not what inertness needs. For a
  stronger "not in the binary" proof, compare deterministic artifacts (preprocessed
  source, object `.text`/`.data` sections, or stripped binaries under reproducible-build
  flags), never a whole-binary hash.
- Dump formats are raw, exactly specified (endianness, record layout, tagging), and read
  back exactly by the other side. Tag every record with step / substep / location / field.
- Keep each tool a small, separate module in `tools/diff/`. Resist merging them.
- **Recognize native tooling before building.** A mature SOURCE often already implements
  a tool class as a production safeguard - a sanity/range guard, a conservation monitor,
  an assertion. Building a duplicate adds code the SOURCE does not have (a
  literal-translation violation) and wastes effort. Before building a class, look for a
  native implementation; if one exists, RECOGNIZE it, reproduce it in the port, and prove
  it with a seeded bug, rather than building a parallel tool. "Build the tooling" is
  satisfied by native tooling where it exists.

## The six tool classes

### 1. Staged reference dump (localizes in *time*)
The main iteration of a numerical code - a timestep, solver iteration, or sweep -
decomposes into an ordered sequence of substeps (operators). After each substep, dump a
few state variables at a handful of fixed probe locations. A small script then reports
**the first substep at which port and reference disagree**. On a chaotic or
error-amplifying system, "the run diverges by iteration two" carries no information
about cause; "substep 11 of iteration 2 is the first divergence" names the guilty
operator. Subsystems that iterate internally (solvers, sub-cycled components, startup)
need their own interior dump points.

### 2. Identical-input operator diff (localizes in *space of causes*)
A whole-run difference cannot distinguish a wrong kernel from a correct kernel fed
slightly different input - both diverge. Remove the input difference: feed a prescribed
field, identical on both sides by construction, run the kernel once, compare outputs
pointwise. Add a **replay variant** for kernels sitting just downstream of
difference-amplifying steps: overwrite the port's inputs with the reference's dumped
inputs immediately before the routine, leaving only the arithmetic under test.

### 3. Always-on sanity probes (catches *silent* corruption)
For every field with a known physical range, a one-line check that writes to stderr
whenever a value leaves that range. Cheap enough to leave on everywhere. This is the
detector for the "allocated but never computed" class: a field that sits at zero passes
every differential comparison (the reference's field is also untouched at that phase)
and only the range probe flags it before a later phase consumes it.

### 4. Boundary/communication probe (the distributed-memory specialist)
The most common distributed-memory fault is a stale exchange region: a write loop that
covers the owned points but not the halo/ghost points. Detection: copy the field,
perform the exchange on the copy, compare copy with original over the exchange region -
any point that changed was stale. Run it over the whole candidate field list at once, so
a single short run names the guilty fields directly. Generalize to whatever the
communication construct is (halos, ghost cells, overlap regions, shared boundaries).

### 5. Subsystem disable-switches (bisects by *subsystem*)
Give every subsystem an environment switch that turns it into a no-op (freeze this set
of variables, zero that forcing or source term, skip this operator). The switches
compose: three or four short runs bracket a divergence to a single subsystem **before
any code is read**. They double as inertness checks at phase boundaries: with the new
subsystem off, the model must reproduce the previous tagged commit's outputs byte-for-byte
(results, not the binary).

### 6. Executable contracts (makes implicit invariants *abort instead of corrupt*)
Whenever the port introduces an implicit contract - which memory space is authoritative
for each field at each point in the step, which fields must be synchronized before a
phase, which arrays must be sized owned-plus-halo - write the contract down as a map
AND build an optional mode that **aborts the run on violation**. Acceptance for the
phase that introduces the contract is then "a full run with the guard armed, provably
unable to fire." A documented contract depends on being remembered; an executable one
does not. (Reference-project instance: the host-authoritative sync map for the
host/device data layer, enforced by a build that aborts if the host reads a field whose
device copy is authoritative.)

## The poison discriminator ("poison, don't perturb")

For staleness and data-flow suspicions on a chaotic system, the obvious test - toggle a
synchronization/exchange and see whether the answer changes - is **confounded**:
removing a sync also removes a fence/ordering point, which by itself reorders the
arithmetic enough to move the trajectory. You learn nothing.

The discriminator that works: **keep every synchronization in place** (so scheduling and
ordering are unchanged) and instead overwrite the suspect copy with NaN (or another
poison) *after* the point where it should have been refreshed - without marking it
modified. The authoritative copy stays correct; only a genuine read of the stale copy
sees the poison and fails immediately and loudly. Suspects that are never actually read
from the stale side change nothing when poisoned; the one genuine stale reader fails
instantly and is the bug.

Generalize: to test "is X ever actually read here?", never remove X - poison it,
changing nothing about execution order. NaN works for floating-point; use trap
representations, canary values, or mprotect for other types.

## Workflow when a gate fails

1. Check `port/KNOWN-DIVERGENCES.md` first: is this the recorded floor/signature?
2. Disable-switches: bracket to a subsystem (minutes, no code read).
3. Staged dump: name the first diverging substep within it.
4. Identical-input / replay diff: decide wrong-kernel vs wrong-input.
5. For staleness/data-flow hypotheses: poison discriminator, not sync-toggling.
6. Only now read code - with file:line citation discipline (Prime Directive 3).
7. Fix; rerun the per-kernel gate, then the tier that failed, then every tier above it.
8. Append the lesson to LESSONS.md, including the detector that caught it (or the
   detector that *should* have existed - then build it and add it here).
