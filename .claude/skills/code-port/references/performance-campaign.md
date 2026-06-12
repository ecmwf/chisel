# The Performance Campaign

Performance work begins only after the correctness ladder holds, and proceeds **under
the ladder as a constraint**: every optimization must keep the deterministic backend
bit-identical (or re-pass the relevant tier). This turns the ladder from a porting tool
into a permanent regression harness.

## Parity tracking during the language port (long before any campaign)

A literal port of compiled numerical code is roughly performance-neutral, and that
expectation is itself a checkable invariant: **track wall-clock parity from the first
milestone**, do not wait for Phase 4.

- At every milestone gate run, record the wall-clock time of the SOURCE and TARGET
  builds on the same run, same machine, pinned flags, in the gate's evidence pack.
  The fast rig gives a cheap per-session signal; milestone runs give the durable
  series.
- Agree a parity band with the human in the charter (calibrate; a literal port
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
2. **Profile at the production workload, with a real profiler.** A per-phase wall-clock
   timer cannot separate computation from data movement within a phase; use a timeline
   profiler. And profile at the production problem size, not the fast development rig -
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
   RESULTS block) so no later session retries it.
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
   elsewhere (failure mode L7), producing a correct-but-slow port that looks like a
   hardware deficit.
8. **Define the production target before tuning.** Express it in domain throughput
   (e.g., simulated time per wall-clock day, items per second), agree it with the
   human, and stop the campaign when the target is met across the intended platforms -
   further tuning is a separate, deliberately-scoped project.
9. **Port to a second platform early.** Bring-up on a different machine/vendor is cheap
   once the code is portable - typically hours, not weeks - and is itself a
   diagnostic: it exposes hidden platform assumptions and gives a second profile that
   separates code properties from machine properties (e.g., a tightly-coupled
   host–device link making the residency problem vanish).
