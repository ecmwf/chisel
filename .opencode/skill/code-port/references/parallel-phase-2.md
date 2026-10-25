# Parallel Phase 2 (the bulk translation, many workers at once)

How to port the bulk of the SOURCE with many LLM-driven workers in parallel, **without
weakening any fidelity guarantee**. This is the execution roadmap on top of the
coordination substrate (`references/team-coordination.md`) and the parallel-Phase-1
tooling (`references/parallel-phase-1.md`); it does not re-specify them. It assumes
**Phase 1 is finished**: a reference run, the differential tooling, the proofs (R0-R5) and
conformance checks, and the dependency map all exist - without them a
worker's proof has nothing to check against.

"**Piece**" = a coherent deliverable (a module, the helpers only it uses, AND its
product-owned tests under `tests/`), claimed, ported, proven, reviewed, and integrated as one
unit. The tests ship in the product, never orphaned in the workbench (the v1 trap;
`conformance/check-product-tests.sh`).

> Execution note: this is a protocol for a live, multi-contributor port. It runs on the
> two-repo model (WS-C) with the WS-E0 operational machinery (generator, dashboard,
> integrator/merge-queue) in place. The methodology here lands on the branch; the run is
> per-project (the partition, owners, widths, and cadence live in the charter).

## Non-negotiables (parallelism changes throughput, not the bar)

- Every piece earns `proven` the same way: its acceptance proof passes (tier R1+, never R0)
  AND an independent fidelity review is clean, evidence recorded. No piece merged on speed.
- Review independence is real: the reviewer is a separate session (ideally a different
  model; at human scale a different person/team), never in the piece's `author_sessions`.
- The seeded-bug rule holds for every new check; new checks are themselves proven.
- The numerical safety net is the **differential proofs**, not the review - per piece AND
  again at integration. The review catches structural/literal-translation faults; it is
  not the backstop for silent numerical drift. Both run; neither is dropped for speed.
- Protected surfaces are off-limits to leaf work (the proofs/diff/conformance tooling,
  `reference/` and tolerances, `source/`, the conventions, the charter and its acceptance
  criteria + named exceptions (`port/plan/00-charter.md`), `KNOWN-DIVERGENCES`, the map/
  generator/dashboard, the status schema, the interface contracts (`port/COORDINATION.md`),
  the epoch/audit logic). Touching them is an owned tooling change: owner + seeded proof +
  independent review + its own merge.
- Milestone acceptance is sealed by `finalize.sh` (hand-driven, a human `SIGNOFF.md`; in L2/L3
  auto-mode, `finalize.sh --auto` after green conformance at HEAD, the per-piece independent reviews
  bound to each proven commit being the acceptance). No program names leak into the methodology.

## The four roles, kept distinct

- **Worker = Kha-Worker** (`.opencode/agents/kha-worker.md`) - the standard sprint agent,
  porting one piece in its own branch + `.worktrees/` worktree, opening a PR. Many run in
  parallel. The orchestrator PROVISIONS that worktree (and, two-repo, a separate product worktree)
  before dispatch and hands over the contract roots, so workers never share a tree - see
  `team-coordination.md`, "Worker isolation: provisioned worktrees". It authors and proves its piece
  but never reviews it, never merges, and never pushes - publishing the branch and the claim is
  human-approved.
- **Reviewer** (`.opencode/agents/port-review.md`) - an independent agent (separate
  session, ideally a different model, never the author) reviewing a finished piece. Many
  run in parallel.
- **Orchestrator = Ptah-Orchestrator** (`.opencode/agents/ptah-orchestrator.md`) - the scheduler and the human's
  front door: derives the ready-set from the map + generated TRACE + claims, dispatches
  pieces to workers, gathers verdicts, and **regularly reports human-readable DERIVED
  status** - a work-items table + an active-agents table + what changed + the parallelism numbers,
  produced by running the dashboard, never narrated. It fans out and reports; it does
  **not** review, merge, or self-certify.
- **Integrator = Seshat-Integrator** (`.opencode/agents/seshat-integrator.md`) - the single integration funnel for the
  canonical line: takes reviewed-clean PRs through **one queue**, dependency-ordered,
  rejecting stale-base branches, then (after the guarded merge lands) running the integration
   epoch and regenerating canonical TRACE. A role, not an irreplaceable person; the point is
   one funnel. It LANDS through the sanctioned guarded scripts (which re-verify everything and
   push fail-closed); in autodrive it performs the land with no human keystroke - the checks are
   the authority, run by hand the human runs the same script.

It is PR-based: branch -> PR. Fast checks block every merge; the expensive integration
epoch runs on a cadence - dispatch stays parallel, only the final merge is serialized.

## Two-repo wiring (WS-C)

Each worker's piece lands in the **product** repo (clean code commits, the piece's `tests/`
included); its evidence - the review report, the proof logs, the status fragment - lands in the
**workbench**. The integrator lands the reviewed piece with the sanctioned
`tools/coordination/integrate_product.sh <id>`: it re-checks planner-ready + the full conformance
suite (the two-root contract C6: workbench checks + the product-facing checks against the product
checkout), SQUASH-merges the piece onto the product mainline as one clean commit (C5), re-runs the
suite on the merge RESULT and rolls back on red, then pushes the product - so the target fills one
reviewed piece at a time. The fragment's `product.main_commit` records that squashed product commit
(C4) and `integration.state` advances to `integrated`. **An ASSEMBLY-PROVEN deliverable** (its proof links
several modules so no member passes in isolation, and its work branches are full-closure trees that share
a build target - see two-repo-architecture.md) does NOT land the members per-id (a sibling land stales the
rest); land the whole deliverable as ONE reviewed assembly piece with `tools/coordination/integrate_assembly.sh
<assembly-id> --members "<id> ..."` (the assembled tree + glue under one integration-level review, bound by
check-trace-evidence - no manifest), then attest every member `integrated`. (Advanced multi-operator path: a
worker opens a product PR and the integrator merges it; the script is the default hands-off land.) The
cross-piece epoch then runs from the workbench against the product checkout at the charter's cadence.

## The wave protocol (the repeating loop)

1. **Compute the ready-set** from canonical TRACE + the map: pieces whose dependencies are
   all `integration.state: integrated` (merged onto the canonical line via the guarded land, each
   dep's own differential proof green - not merely `proven` on an unmerged branch), with **no structural
   guard** (no owned-foundation / shared-surface), and **unclaimed**. A dependent may build on an `integrated` dep because that
   dep passed its OWN R1 differential; the cross-piece integration epoch (step 6) is the cadence
   interaction backstop, not a per-dependency proof. Launch the WHOLE such set at once (cap only at
   an explicit `max_in_flight`).
1b. **HOIST the wave's shared surfaces before dispatching any consumer.** The ready-set above
   is computed from DEPENDENCY readiness, which cannot see what each piece will have to
   CONSTRUCT on the target side. Two pieces with no edge between them still collide if both
   need the same index helper, the same precision/type contract, or the same intrinsic wrapper
   that the language pair requires (failure mode **B26**). Before launching a wave: derive each
   ready piece's target-side construct requirements from its source - ask a parser, not a
   pattern - using the language pair's trap table as the vocabulary. Intersect across the wave.
   Anything required by MORE THAN ONE piece is a SHARED SURFACE: make it an owned prerequisite,
   build and review it FIRST, and have the consumers consume it. A construct you cannot
   determine for a piece makes that piece ineligible for a parallel wave - schedule it alone
   rather than let it guess. Then cap the wave on collision-freedom as well as on
   `max_in_flight`. This is cheap and it is not optional: first-use-wins means one piece's ad-hoc
   version of a subtle helper silently becomes the port's standard. If a worker reports wanting
   to factor a helper shared with another piece, that is this step having been skipped - provision
   the surface, do not let them create it.

2. **Dispatch workers.** Each piece is claimed by provisioning its worktree (which writes the local claim), opens
   an isolated branch, runs the normal single-piece sprint loop. Workers never touch each
   other's files or the central status.
3. **Checks in CI** per PR. A red check keeps the piece out; the worker fixes and re-runs.
4. **Independent review, in parallel** - separate reviewer (clean context, ideally a
   different model, session not in `author_sessions`); report + verdict.
5. **Integrate in dependency order.** The integrator merges reviewed-clean pieces through
   the single queue, rejecting any stale-base branch (the worker rebases and re-proves; a fresh
   independent re-review is owed only if the rebase changed the piece's own target files -
   `tools/coordination/review_revalidate.sh <id>` decides this fail-closed by byte-identity),
   and regenerates canonical TRACE from
   the fragments (the generator is **deterministic** - a crashed wave is re-runnable). The
   integrator merges cleanly only; if a merge needs a code change, that is a **new authored
   change** (its session goes in `author_sessions`; re-prove + re-review - the integrator
   must not become an unreviewed author).
6. **Run the integration checks** at the charter's cadence: the differential comparison
   against the reference run at integration level (the silent-drift backstop) plus fast
   structural checks. A completed full differential run over a set of merged commits is an
   **integration epoch**, recorded as an **epoch certificate** (commit range + exact HEAD,
   reference-run id + checksum, proof script + logic-commit, R-tier/config/duration,
   per-field tolerances, output-evidence path, pass/fail). Its GREEN certificate - not
   mere "merged" - proves the wave safe; a failure is bisected to the piece.
7. **Harvest and ratchet.** Any new trap is triaged (below); a must-mechanize trap gets its
   seeded-proven check **before the next wave fans out that kind**.
8. **Wave checkpoint.** The human (and subsystem owners) reviews an aggregate - not
   piece-by-piece - and approves *proceeding*. A checkpoint is "ok to proceed," NOT
   milestone acceptance (no tag, not the phase `SIGNOFF.md`). Then loop.

A crashed/abandoned worker does NOT free its claim: it goes to "needs triage." **Rollback
is a queue event, not an edit:** the integrator reverts the merge through the queue, the
generator marks transitive dependents stale/needs-reprove, and invalidated evidence is kept
but no longer counted current. **Every wave leaves a wave audit summary** - linking that
wave's per-deliverable evidence and `product.main_commit`s, the epoch certificate, the merge
order, any bugs-found-late, rollbacks/invalidations, queue age, and cost - the record a human
signs the checkpoint against.

## Disposition of a reviewed piece

Per unit (the v1 `/port-review` disposition carries forward): any finding blocks `mark proven`;
a fixable finding is **sent back** to the worker AUTOMATICALLY (the work->review->rework loop runs to
convergence without a per-unit ask); **defer** only for a genuine blocked/governance decision; **mark proven**
only a clean piece (proof-evidence
audit OK) - by human checkpoint, or the opt-in `auto-prove: clean-only` policy which records
`status: proven` but never merges.

## Mechanize the traps before you fan out (what makes wide fan-out safe)

A loose parallel worker is safe **only for mistakes an automatic check would catch
anyway** - parallel workers do not share mid-flight lessons. So parallel width is bounded
by how many of the codebase's traps are machine-caught. Triage each trap:
**must-mechanize** (clear failure class, cheap, near-zero false alarms, seedable -> build
the seeded check), **reviewer-checklist** (real but not cheaply mechanizable -> trap
table, every reviewer checks by hand), or **owned/serial** (only safe under an owner ->
out of the loose pool). Do not build a check for every trap (check sprawl is its own
failure). Wide fan-out is made safe by **check coverage**, not by a calendar or an earned-width ramp -
once a kind's traps are machine-caught, the whole set of that kind fans out at once.

## Staged build order

- **Stage 0 - machinery:** the WS-E0 substrate works for ONE worker end-to-end (claim ->
  branch -> CI checks -> independent review -> integrate -> regenerated TRACE, no hand-edited
  central status; dashboard correct).
- **Stage 0b - the dependency map:** the extractor records the file inventory, the PROVEN in-tree
  use/call edges, and the STRUCTURAL surfaces (a module USEd by >= 2 units is an owned foundation; a
  common block shared by >= 2 is a shared surface). It does not guess: a reference it cannot resolve
  in-tree draws no edge. "No edge found" is NOT "no coupling" - so the loose pool is not a safety
  claim; the R1 DIFFERENTIAL proof and the INDEPENDENT review are what catch a hidden coupling, on every
  piece, before it lands.
- **Stage 1 - trap-harvest pilot:** port a **representative** slice (a representation matrix:
  pure kernel, wide-footprint routine, seam, shared-layout, config-selected path, I/O path,
  constants/table, generated/registry) serially or with very few workers, to surface traps.
  An unrepresented kind gets loose-pool width 0 until one of its kind is proven.
- **Stage 1.5 - the fan-out entry check (hard):** do NOT start parallel work until ALL hold:
  status sharded+generated (central-write refuses in team mode); protected-surface detector
  built+seeded; evidence commit-bound; the integration epoch runnable on demand; every
   coordination detector seeded; the dependency map live and the dashboard lists the ready
   (unguarded, unclaimed) pieces; and the SHARED INFRASTRUCTURE every worker will depend
  on (index/layout helpers, build and formatter config, common headers) is created AND
  integrated FIRST - it is Layer-0-equivalent. Concurrent workers, each isolated in its own
  worktree, cannot create or edit a shared file without racing (two workers duplicate-create
  the same helper, or collide editing the build config), so a shared file born mid-fan-out is
  a coordination bug, not a translation; build it once, before the wave. A missing line is a
  hole a silent error fits through.
- **Stage 2 - first wave (the cold-start check):** fan out the safe ready-set; the first wave also
  proves the parallel substrate end-to-end with one completed green epoch. A genuinely large ready-set
  is fine - the cap is only an explicit `max_in_flight`, never an earned-width rule.
- **Stage 3 - parallel by default:** keep fanning out the whole safe ready-set every wave (see above).
- **Stage 4 - the coupled core:** owned, contract-checked, near-serial; a foundation is
  `integrated` **before** the wave that depends on it, then **frozen** for that wave's
  duration (changing it mid-flight invalidates every dependent).

## Parallelizability assessment (once, up front; lives in the charter)

Before wide parallelism, write a short assessment for THIS codebase: the **shape of the
map** (a wide independent base, or a tangled/cyclic/global-state-heavy core with little
safe parallelism - if the latter, expect more serial work and invest in seams/contracts
first); **how much is guarded** (how many units are owned foundations / shared surfaces vs free
leaves - the structural guards size the serial core); the **trap surface** (how many recurring traps, and how many already machine-caught); and
**integration cost** (how expensive a full epoch is, hence the cadence). Its output is a
**realistic ceiling** on parallel width and an honest list of what stays serial - do not
promise speed the codebase's shape cannot give.

## Parallel by default - fan out the full safe ready-set

Every wave dispatches the WHOLE safe-to-parallelize ready-set at once - there is **no earned-width
ramp**. "Safe to parallelize" is decided by GROUND TRUTH, not caution: a unit is ready when its real
dependencies are integrated, it carries no structural guard, and it is unclaimed. Everything that qualifies
launches concurrently; the only cap is an explicit `budgets.max_in_flight` the operator sets (a
resource/cost ceiling, never a trust ramp). The planner already computes this whole set - the job is
to LAUNCH it, not to hold proven pieces back.

**The serial-by-habit pitfall (name it so you avoid it).** The common failure is not dispatching too
wide - it is silently dispatching too NARROW while believing you are parallel. Three traps cause it:
(1) *Foundation-first read as serial.* A shared foundation (owned surface, shared header, Layer 0)
must integrate before its dependents - a one-time ORDERING constraint. But its dependents that do not
depend on EACH OTHER are siblings, not a chain: the instant the foundation integrates they are ALL
ready. Walking them one at a time "because they share a foundation" is the mistake. (2) *Dispatch
spread across turns.* Fan-out is ONE turn: launch the whole ready-set as multiple subagent tasks in a
single message. Workers leaving in consecutive turns is serial execution wearing a parallel label.
(3) *Orchestrator-as-author (the throughput illusion).* The width is the FAN-OUT, never your own
throughput: you author ZERO units - you provision one worktree per ready unit and dispatch one worker
subagent per unit, all in THIS turn. So "authoring N units in one turn is ambitious, I'll do fewer" is
a category error - you are not authoring them, N parallel workers are; the only question is how many are
READY, and every ready one goes out now (capped only by an explicit `max_in_flight`). Never narrow the
wave because doing the work yourself would be a lot - you are not doing the work.
Self-check before launching any single worker: re-derive the ready-set and ask "what else is ready
right now?" - if more than one, they go out together.

The only things that are not a free parallel launch are REAL constraints, never generic caution:
- **Layer 0 first.** The differential harness everything compares through is proven before the pool
  opens - a real dependency, not a ramp.
- **Real dependency order.** A unit waits only for the deps it actually consumes to be integrated.
- **Prove one of an UNREPRESENTED kind first (cheap insurance, not a throttle).** The first unit of a
  never-yet-ported construct gets proven before the rest of that kind fan out, so a systematic
  rendering trap is caught once instead of in fifty pieces. The instant one of a kind is proven, the
  whole rest of that kind launches at once. This throttles only the COLD START of a NEW pattern - it
  never holds proven, eligible pieces of an already-proven kind.

A late bug, vacuity, or violation does NOT narrow the wave: mechanize the missing check and rework the
affected cohort (in parallel, like any other work). A piece LANDS on its own per-piece proof (R1+ and a
clean review); the cadence integration epoch is the cross-piece backstop that clears the wave
CHECKPOINT (red -> bisect -> roll the offending piece back) - neither it nor a late bug limits how WIDE
you dispatch. Non-vacuity stays a machine artifact (stored in the
fragment, read mechanically - invocation counts for an R1 twin, fixture/read-set coverage,
a seam-probe activation record, or an explicit "declarations-only" proof), so "exercised" is proven,
never a vibe.

## When several people share the project

The mechanics survive once identity, authorization, and claim lifecycle are explicit,
because the system coordinates on ground truth (claims - pushed refs are the cross-operator
collision detector here - PRs, the map, generated
TRACE), not on who drives. Workers: each person drives their own fleet; the atomic claim
arbitrates races. Orchestrator: federates (one per person) computing the same ready-set,
or one shared scheduler. Reviewer: independence gains a **human dimension** - a different
person/team, made machine-checkable via the fragment's `author_id`/`author_team` +
`reviewer_id`/`reviewer_team` (reviewer outside the author team). Integrator: stays ONE
shared queue (rotating duty or charter-authorized bot). Owners: specific people own the
coupled-core surfaces; the leaf base is self-serve. New once the actors are people:
explicit identity/attribution, federated authority (charter-recorded who-may-mark-proven/merge/
sign), trust/permissions (who may push a claim, touch a protected surface, operate the
queue), the coupled core as the one place people must talk (contract-change PRs serialized
by the owner), claim-lifecycle abandonment = "needs triage", and harder lesson
mechanization (the checks are the team's shared memory). Independence is **not waivable**:
for a deep kernel an author-team expert may add an *advisory* science review, never the
`proven` verdict.

## Done-when

The build-order checklist is satisfied end-to-end on the two-repo model: one worker works
the full loop (Stage 0); the map lists the ready (unguarded) unclaimed pieces (Stage 0b);
the pilot is proven with the matrix filled and must-mechanize traps mechanized and the
parallelizability assessment approved (Stage 1); the entry check holds (Stage 1.5); the first
wave reaches proven+integrated under a green epoch (Stage 2); the whole safe ready-set fans out in
parallel (Stage 3); and the coupled core is ported through owned contract-checked
changes to the Phase 2 milestone with full evidence (Stage 4) - the fidelity trust core
intact throughout.
