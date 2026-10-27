<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# The Performance Campaign

Performance work begins only after the correctness ladder holds, and proceeds **under
the ladder as a constraint**: every optimization must keep the deterministic backend
bit-identical (or re-pass the relevant tier). This turns the ladder from a porting tool
into a permanent regression harness.

## Parity tracking during the language port (long before any campaign)

A literal port of compiled numerical code is roughly performance-neutral, and that
expectation is itself a checkable invariant: **track wall-clock parity from the first
milestone**, do not wait for Phase 4.

- At every milestone proof run, record the wall-clock time of the SOURCE and TARGET
  builds on the same run, same machine, pinned flags, in the proof's evidence pack -
  after running the fair-field check below on both builds.
  The fast rig gives a cheap per-sprint signal; milestone runs give the durable
  series.
- Agree a performance parity band with the human in the charter (a literal port
  should sit within a few percent once builds are matched). A deviation outside the
  band is a FINDING, not a tuning opportunity: investigate the cause - mismatched
  compiler flags, a debug build leaking into the comparison, an accidental copy or
  allocation in a hot loop, a rendering that changed loop structure. The usual
  culprits are build configuration and translation bugs, and several of them
  (changed loop order, introduced copies) are correctness smells in a literal port.
- Never optimize during translation. A parity fix must itself be literal: correct
  the build, correct the rendering to match the SOURCE structure, or record a
  charter exception. Anything beyond that waits for the campaign, under the ladder.
- Record the parity series; it becomes the Phase 4 baseline and the honest answer
  to "did the port cost us performance" (it should not have).

## The fair-field check (run before EVERY SOURCE-vs-TARGET comparison)

A timing comparison - a parity entry, a campaign ledger row, a speed claim in a report -
measures the two builds before it measures the port. Before recording or reporting one,
execute these steps on BOTH sides; skipping them has produced a speedup claim that had to
be withdrawn.

1. **Read the EFFECTIVE flags from the generated compile command.** For each binary, pick a
   hot translation unit (one the profile says matters) and read its actual compile line from
   the build system's generated record (a compilation database, a verbose build log): the
   optimization level, the floating-point mode (contraction, fast-math class), and the
   architecture targeting. Never take them from a cache variable, a configure summary, or the
   flags you believe you set. Observed: a project's build wrapper ignored the
   standard compiler-flags variable in favor of its own wrapper variable; the cache showed the
   intended flags while the compile lines carried no optimization at all.
2. **Make every timed variant fresh against the last configure.** After any reconfigure,
   rebuild EVERY variant you will time (each precision, each backend) - invoke the build
   unconditionally, never trust that a binary exists. When auditing a comparison already
   made, check each variant's objects against the last configure: one that predates it is
   stale from the earlier configuration.
3. **Distrust a physically inverted ratio.** A cheaper variant slower than a dearer one (a
   single-precision build slower than its double-precision twin, a smaller problem slower than
   a larger) means a stale or unoptimized build until proven otherwise: return to steps 1-2,
   do not explain it.
4. **Record what you verified** next to the number: the effective compile line (or its key
   flags) for each side and the configure/build it came from. A comparison without that
   record is unverified and is not reported as a result.

## Set expectations honestly (and say this to the human)

- **The language change itself is roughly performance-neutral.** A literal
  transliteration of well-written compiled numerical code into another compiled
  language lands within a few percent of the original -
  sometimes marginally faster, sometimes slower. Do not promise speedups from the
  language change; if anyone claims the SOURCE language is "slow", correct the framing:
  its liabilities are tooling, ecosystem, developer pool, and hardware reach, not
  runtime.
- **Portability layers carry an overhead.** Expect a modest constant overhead over the
  plain serial port on CPU, largest where per-rank work is smallest and shrinking as it
  grows; measure it early and record it.
- **Time-to-solution gains come from the hardware the new language unlocks**, and they
  are conditional: workload-size- and scale-dependent, and they have to be earned by an
  optimization campaign. Expect the first full accelerator run to be markedly *slower*
  per node than the CPU baseline, and the post-campaign advantage to be strongest on
  large problems at low node counts where each device is saturated, eroding as
  subdomains thin. Identify the crossover problem size for your code and report it.

## Campaign rules

1. **Profile before every change.** The limiting factor moves after almost every fix -
   expect it to move at nearly every step of the campaign. Never optimize from
   intuition or from last week's profile.
2. **Profile at the real workload, with a real profiler.** A per-phase wall-clock
   timer cannot separate computation from data movement within a phase; use a timeline
   profiler. And profile at the full-scale problem size, not the fast development rig -
   the bottleneck structure is different. (The classic first accelerator profile:
   compute kernels at a single-digit percentage of the step, the rest spent shuttling
   fields between host and device.)
3. **Expect data movement first.** The classic first fix: keep communicated fields
   **device-resident** and exchange device-to-device instead of staging through the
   host. This single class of fix can dominate the entire campaign and by itself flip
   the CPU/GPU comparison. Only after that does compute optimization (memory coalescing,
   scratch reuse so working sets stay in fast memory) pay.
4. **Measure, keep, or delete.** Plausible optimizations frequently target time that
   isn't there (commonly tried and then *deleted*: comm/compute overlap, persistent
   communication requests, kernel-launch fusion - the targeted time turns out to be
   small, or to be load imbalance). An optimization that doesn't measure as a win is
   complexity debt: delete it and record the negative result in LESSONS.md (NEGATIVE
   RESULTS block) so no later sprint retries it.
5. **Build scale proxies.** When the bottleneck is governed by an intensive quantity
   (work per rank, points per device, message size), reproduce the expensive at-scale
   regime cheaply: a smaller problem at the *same per-worker workload* reproduces the
   communication-bound regime of the large one in minutes. Know what the proxy does NOT
   preserve (e.g., a solver's iteration count, set by the conditioning of the actual
   problem) and measure those terms at scale.
6. **Keep an optimization ledger.** One row per milestone: lever, change, measured
   step time, Δ%, and whether it survived. Reverted attempts stay in the ledger as
   negative results. This is the evidence pack for the campaign and the input to the
   next port's expectations.
7. **Guard for neutrality across vendors.** Any platform-conditional fast path must be
   guarded by a *capability* flag covering all intended backends, never a
   vendor-specific one - a vendor-specific guard silently disables the fast path
   elsewhere (failure mode N7), producing a correct-but-slow port that looks like a
   hardware deficit.
8. **Define the throughput target before tuning.** Express it in domain throughput
   (e.g., simulated time per wall-clock day, items per second), agree it with the
   human, and stop the campaign when the target is met across the intended platforms -
   further tuning is a separate, deliberately-scoped project.
9. **Port to a second platform early.** Bring-up on a different machine/vendor is cheap
   once the code is portable - typically hours, not weeks - and is itself a
   diagnostic: it exposes hidden platform assumptions and gives a second profile that
   separates code properties from machine properties (e.g., a tightly-coupled
   host-device link making the residency problem vanish).
10. **Classify the bottleneck from hardware counters, not from the shape of the code.**
   "Memory-bound", "compute-bound", "allocation-bound" are MEASURED verdicts -
   instructions-per-cycle, last-level-cache miss rate, page-fault rate, achieved memory
   bandwidth - never inferences from what a kernel looks like. A table-interpolation kernel
   "obviously" memory-bound is often compute-bound while its tables sit in cache; a kernel
   "obviously" needing wider math can be allocation-fault-bound (failure mode N11). Acting on
   the assumed class is wasted campaign - reduced precision buys nothing on a kernel whose real
   limiter is the allocator or the page-fault path. Read the counters, then spend effort only on
   the lever the counters justify.
11. **Know which optimizations keep bit-identity and which spend it.** Under the ladder, an
   optimization that keeps the deterministic backend bit-identical is free to keep; one that changes
   the arithmetic must be proven against the charter's acceptance band. A lever is bit-identical only
   under the deterministic build's floating-point contract (contraction off, no fast-math, fixed
   rounding) and only if it changes neither the operation set nor its order: wider SIMD lanes
   qualify unless they also reorder a reduction, enable contraction or switch to a different vector
   math routine; forced vectorization qualifies only for a loop with no carried dependency,
   reduction, aliasing or side effect. A "widen", native-architecture or higher-optimization step
   often turns on contraction or reassociation silently, so re-run the deterministic proof
   (max |Δ| = 0) after each such change instead of assuming. Contraction and fast-math reassociation
   always move the result: keep one only if it measures as a win and holds the band. Report the
   bit-identical wins as the honest baseline and any band-spending win separately, with its band.
12. **Benchmark the TARGET against the SOURCE built the same way.** A TARGET tuned for the host
   against a stock SOURCE build measures the flags, not the port, and equalizing them often closes or
   flips an apparent TARGET win. Most generic levers (wider SIMD, the allocator policy of N11) help
   both languages, so claim a TARGET advantage only after the SOURCE carries every flag the TARGET
   does, state the flags with any number, and run the fair-field check on both binaries first.
13. **When bit-identity is the bar, get vectorized math without fast-math.** A fast-math-class flag
   bundles the vector-math permission with reassociation and other relaxations; in the observed case
   the drift that left the acceptance band came from the reassociation, not the vector math. Call the
   platform's vector-math entry points explicitly, behind an opt-in build option with contraction and
   fast-math off, and keep it only if the deterministic proof shows max |Δ| = 0 on the canonical run
   in every precision (otherwise it is a band-spending lever under rule 11). Record the fast-math
   attempt as a negative result.
