<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Parallel Phase 2 (the bulk translation, many workers at once)

How to port the bulk of the SOURCE with many workers in parallel without weakening any fidelity
guarantee. This is the execution roadmap on top of the coordination substrate
(`references/team-coordination.md`) and the Phase-1 tooling (`references/parallel-phase-1.md`). It
assumes Phase 1 is finished: the reference run, the differential tooling, the proofs and conformance
checks, and the dependency map exist, or a worker's proof has nothing to check against.

A **piece** is one coherent deliverable - a module, the helpers only it uses, and its product-owned
tests under `tests/` - claimed, ported, proven, reviewed and integrated as one unit. Its tests ship
in the product, never orphaned in the workbench (`check-product-tests.sh`). The partition, owners,
widths and cadence of a given port live in its charter.

## Non-negotiables (parallelism changes throughput, not the bar)

- Every piece earns `proven` the same way (AGENTS.md): an R1+ proof and a clean independent review,
  with evidence recorded. No piece lands on speed.
- The reviewer is always a separate session, never in the piece's `author_sessions`; it should run
  on a different model, and at human scale be a different person or team.
- The seeded-bug rule holds for every new check.
- The numerical safety net is the differential proofs, per piece and again at integration. Review
  catches structural and literal-translation faults; it is not the backstop for silent numerical
  drift. Both run, and neither is dropped for speed.
- Protected surfaces are off-limits to leaf work: the proof, diff and conformance tooling,
  `reference/` and the tolerances, `source/`, the conventions, the charter with its acceptance
  criteria and named exceptions, `KNOWN-DIVERGENCES.md`, the map, generator and dashboard, the
  status schema, the interface contracts, and the epoch and audit logic. Touching one is an owned
  tooling change: an owner, a seeded proof, an independent review and its own land.
- Milestones are sealed only by `finalize.sh` (AGENTS.md; for L2 and L3, `auto-mode.md`).

## The four roles, kept distinct

- **Kha-Worker** (`.opencode/agents/kha-worker.md`) - the standard sprint agent, porting one piece
  in its own `work/<id>` branch and `.worktrees/<id>` worktree (plus a separate product worktree in
  the two-repo layout), provisioned by Ptah-Orchestrator before dispatch (`team-coordination.md`,
  "Worker isolation"). It authors and proves its piece and commits on its own branch; it never
  reviews it, never merges and never pushes. Many run in parallel.
- **port-review** (`.opencode/agents/port-review.md`) - an independent reviewer of a finished piece,
  in its own session. Many run in parallel.
- **Ptah-Orchestrator** (`.opencode/agents/ptah-orchestrator.md`) - the scheduler and the human's
  front door. It derives the ready-set from the map, the generated TRACE and the claims, dispatches
  the workers and the reviewers (a subagent cannot start another), gathers verdicts, and regularly
  reports derived status by running the dashboard: a work-items table, an active-agents table, what
  changed, and the parallelism numbers. It never reviews, merges or self-certifies.
- **Seshat-Integrator** (`.opencode/agents/seshat-integrator.md`) - the single land funnel for the
  canonical line: dependency-ordered, rejecting stale bases, landing only through the guarded scripts
  (`/port-land`, which Ptah-Orchestrator runs), then running the integration epoch and regenerating
  canonical TRACE. It is a role, not a person; the point is one funnel.

Dispatch stays parallel; only the land is serial. Fast checks guard every land, and the expensive
integration epoch runs on a cadence.

## Two-repo wiring

Each piece's code lands in the **product** repo (one clean commit, its `tests/` included); its
evidence - the review report, the proof logs, the status fragment - lands in the **workbench**.
`integrate_product.sh <id>` re-checks that the planner is ready to integrate it and that the full
conformance suite is green across both roots (C6), refuses unless the `work/<id>` tip is the
fragment's `proof.commit` (C4), squash-merges it onto the product mainline (C5), re-runs the suite on
the merge result and rolls back on red, then pushes the product. Record the printed
`product.main_commit` and `integration.state: integrated` in the fragment. Nothing lands the
workbench evidence for you: Ptah-Orchestrator gathers it onto the workbench mainline and commits it
before teardown, and `provision_worker.sh remove <id>` refuses while the worktree holds an
uncommitted file or `work/<id>` carries evidence the mainline lacks. An assembly-proven deliverable
lands as one reviewed assembly piece through `integrate_assembly.sh`, never member by member
(`two-repo-architecture.md`; failure mode B7). The cross-piece epoch runs from the workbench against
the product checkout at the charter's cadence.

## The wave protocol (the repeating loop)

1. **Compute the ready-set** from canonical TRACE and the map: pieces whose dependencies are all
   `integration.state: integrated` (landed through the guarded script, each on its own green R1
   proof - not merely `proven` on an unmerged branch), with no structural guard (owned foundation or
   shared surface), and unclaimed. Launch the whole set at once (capped only by an explicit
   `max_in_flight`) and keep that width filled as slots free ("Keep the pipeline full"). The build
   schedule (`tools/coordination/schedule.py`) orders the set, critical path first, and names the
   cycles, whose units only an assembly can prove.
1b. **Hoist the wave's shared surfaces before dispatching any consumer.** Dependency readiness cannot
   see what each piece must *construct* on the TARGET side: two pieces with no edge between them
   still collide if both need the same index helper, precision contract or intrinsic wrapper (B26).
   Before launching, derive each ready piece's TARGET-side construct needs from its source - ask a
   parser, not a pattern, with the pair's trap table as the vocabulary - and intersect them across the
   wave. Anything needed by more than one piece becomes an owned prerequisite, built and reviewed
   first, which the others consume. A piece whose needs cannot be determined runs alone rather than
   guess. Cap the wave on collision-freedom as well as on `max_in_flight`. This is cheap and not
   optional: otherwise one piece's ad-hoc helper silently becomes the port's standard.
2. **Dispatch workers.** First confirm the piece has not already landed (below). Provisioning the
   worktree writes the claim; the worker runs the normal single-piece sprint loop on its branch and
   never touches another piece's files or the central status.
3. **Checks.** The worker runs the piece's proof and the conformance suite in its own worktree; a red
   check keeps the piece out until fixed.
4. **Independent review, in parallel** - a separate session, clean context, not in
   `author_sessions`; a report and a verdict.
5. **Land in dependency order** through the single funnel. A stale base is rejected: the worker
   rebases and re-proves, and owes a fresh review only if the rebase changed its own target files
   (`review_revalidate.sh <id>` decides, fail-closed). Canonical TRACE is regenerated from the
   fragments by the deterministic generator, so a crashed wave is re-runnable. Seshat-Integrator lands
   cleanly or not at all: a merge that needs a code change is a new authored change (its session
   joins `author_sessions`, then re-prove and re-review), never an unreviewed integrator edit.
6. **Run the integration checks** at the charter's cadence: the differential comparison against the
   reference run at integration level (the silent-drift backstop) plus fast structural checks. A
   completed full differential run over a set of landed commits is an **integration epoch**, recorded
   as an **epoch certificate** (commit range and exact HEAD, reference-run id and checksum, proof
   script and logic commit, tier, configuration, duration, per-field tolerances, evidence path,
   pass or fail). A green certificate, not "merged", shows the wave safe; a failure is bisected to the
   piece.
7. **Harvest and ratchet.** Triage every new trap (below); a must-mechanize trap gets its
   seeded-proven check before the next wave fans out that kind.
8. **Wave checkpoint.** The wave audit summary is the human's view of the wave, an aggregate rather
   than piece by piece. Hand-driven, they look at it at the sprint boundary; under autodrive it is
   committed for later review and the run does not wait. A checkpoint is never milestone acceptance
   (no tag, no `SIGNOFF.md`).

A crashed or abandoned worker does not free its claim: it goes to triage. A rollback is a land
event, not an edit: Seshat-Integrator reverts the land through the funnel, the generator marks
transitive dependents as needing a re-prove, and invalidated evidence is kept but no longer counted.
Every wave leaves an **audit summary** linking its evidence and `product.main_commit`s, the epoch
certificate, the land order, any late bugs, rollbacks, queue age and cost.

### Keep the pipeline full - the wave is a frame, not a barrier

"Parallel by default" (below) says how wide to dispatch; this says how to keep that width filled.
The wave is a bookkeeping frame (the checkpoint, the audit summary), never a barrier: do not drain a
whole cohort before starting the next.

- **Backfill every freed slot at once.** When a piece lands, returns from review or goes back for
  rework, refill its slot from the ready queue; never idle a slot waiting for the slowest member.
- **Provision one wave ahead, in a message before the dispatch.** Calls in one message run
  concurrently, so a worker launched beside its provisioning can start before its worktree exists
  and fail its isolation check.
- **Bookkeeping never takes a slot.** Landing, reconciling status and provisioning run alongside
  the in-flight workers. The land queue is the one serial stage: shorten each land rather than batch
  behind it.
- **Under budget, name the blocker.** Fewer in flight than allowed (`max_in_flight` in autodrive;
  hand-driven, the whole ready-set) is legitimate only for a real constraint, stated exactly (an
  unintegrated dependency, an unhoisted shared surface, an unrepresented kind's first unit).
- **Check already-landed before provisioning.** Status can miss work an earlier session did. If the
  piece's target files are on the canonical line (or the bring-up preview, where the port lands there
  first), it has landed: reconcile its status, do not re-port. A prior branch whose files did not land
  is rebased, re-proven, reviewed (or its review revalidated) and landed - never re-authored.

## Disposition of a reviewed piece

`/port-review` records the outcome. Any finding blocks `proven`; a fixable finding goes back to the
worker automatically (work, review and rework repeat to convergence with no per-unit question);
**defer** only for a genuine human or governance decision, which parks that piece alone; **mark
proven** only a clean piece that passes the proof-evidence audit, by the human's choice or the
charter's `auto-prove: clean-only`. Recording `proven` never lands anything: `/port-land` does that.

## Mechanize the traps before you fan out (what makes wide fan-out safe)

Parallel workers do not share lessons mid-flight, so a loose worker is safe only for mistakes an
automatic check would catch anyway: parallel width is bounded by how many of the codebase's traps are
machine-caught. Triage each trap: **must-mechanize** (a clear failure class, cheap, near-zero false
alarms, seedable: build the seeded check), **reviewer checklist** (real but not cheaply mechanizable:
the trap table, checked by every reviewer), or **owned/serial** (safe only under an owner: out of
the loose pool). Do not build a check for every trap; check sprawl is its own failure. Width comes
from check coverage, not from a calendar: once a kind's traps are machine-caught, the whole set of
that kind fans out at once.

## Staged build order

- **Stage 0 - machinery:** the substrate works for one worker end to end (claim, branch, checks,
  independent review, land, regenerated TRACE, no hand-edited central status, a correct dashboard).
- **Stage 0b - the dependency map:** the extractor records the file inventory, the proven in-tree
  edges, and the structural surfaces (a unit imported by two or more units is an owned foundation;
  global state shared by two or more is a shared surface; with the compiler graph, only the units
  that write it are guarded - one writer owns it, and a unit that only reads it waits for its
  writers and stays in the pool). It does not guess: a reference it cannot
  resolve draws no edge. "No edge found" is not "no coupling", so the loose pool is not a safety
  claim; the R1 proof and the independent review catch a hidden coupling on every piece before it
  lands.
- **Stage 1 - trap-harvest pilot:** port a representative slice serially or with very few workers to
  surface traps - a representation matrix of pure kernel, wide-footprint routine, seam,
  shared-layout code, configuration-selected path, I/O path, constants or table, and
  generated or registry code. A kind not yet represented gets no loose-pool width until one of it is
  proven.
- **Stage 1.5 - the fan-out entry check (hard).** No parallel work until all hold: status sharded and
  generated (central writes refused in team mode); the protected-surface detector built and seeded;
  evidence commit-bound; the integration epoch runnable on demand; every coordination detector
  seeded; the dependency map live and the dashboard listing the ready (unguarded, unclaimed) pieces;
  and the shared infrastructure every worker depends on (index and layout helpers, build and
  formatter configuration, common headers) created and integrated first, as Layer-0 equivalents.
  Isolated workers cannot create or edit a shared file without racing, so a shared file born mid-wave
  is a coordination bug. A missing line here is a hole a silent error fits through.
- **Stage 2 - first wave:** fan out the safe ready-set; the first wave also proves the parallel
  substrate end to end with one green epoch. A large ready-set is fine; the only cap is an explicit
  `max_in_flight`.
- **Stage 3 - parallel by default:** keep fanning out the whole safe ready-set every wave.
- **Stage 4 - the coupled core:** owned, contract-checked, near-serial. A foundation is
  `integrated` before the wave that depends on it, then frozen for that wave (changing it mid-flight
  invalidates every dependent).

## Parallelizability assessment (once, up front; lives in the charter)

Before wide parallelism, write a short assessment of this codebase: the **shape of the map** (a wide
independent base, or a tangled, cyclic, global-state-heavy core with little safe parallelism - then
expect more serial work and invest in seams and contracts first); **how much is guarded** (owned
foundations and shared surfaces against free leaves); the **trap surface** (how many recurring traps,
how many already machine-caught); and the **integration cost** (how expensive an epoch is, hence the
cadence). Its output is a realistic ceiling on parallel width and an honest list of what stays
serial. Do not promise speed the codebase's shape cannot give.

## Parallel by default - fan out the full safe ready-set

Every wave dispatches the whole safe ready-set at once; there is no earned-width ramp. "Safe" is
decided by ground truth, not caution: a unit is ready when its real dependencies are integrated, it
carries no structural guard, and it is unclaimed. The only cap is an explicit `budgets.max_in_flight`,
a resource ceiling, never a trust ramp. The planner computes the set; the job is to launch it.

**The serial-by-habit pitfall.** The common failure is dispatching too narrow while believing you
are parallel. Three traps cause it:
1. *Foundation-first read as serial.* A shared foundation (an owned surface, a shared header, Layer
   0) must integrate before its dependents - a one-time ordering. Dependents that do not depend on
   each other are siblings, not a chain: the moment the foundation integrates, they are all ready.
2. *Dispatch spread across turns.* Fan-out is one turn: every worker in one message, provisioned in
   the message before. Workers leaving in consecutive turns is serial work with a parallel label.
3. *Ptah-Orchestrator as author (the throughput illusion).* The width is the fan-out, never your own
   throughput. You author no units: you provision one worktree per ready unit and dispatch one
   worker per unit, all in one message. "Authoring N units at once is a lot, I'll do fewer" is a
   category error; the only question is how many are ready.

Before launching any single worker, re-derive the ready-set and ask what else is ready right now.
Only real constraints hold a unit back, never generic caution:
- **Layer 0 first.** The differential harness everything compares through is proven before the pool
  opens.
- **Real dependency order.** A unit waits only for the dependencies it actually consumes.
- **One of an unrepresented kind first.** The first unit of a never-ported construct is proven
  before the rest of its kind fans out, so a systematic trap is caught once instead of fifty times;
  then the whole rest of that kind launches at once.

A late bug, vacuity or violation does not narrow the wave: mechanize the missing check and rework the
affected cohort in parallel. A piece lands on its own proof (R1+ and a clean review); the epoch is
the cross-piece backstop that clears the checkpoint (red: bisect, roll back the offending piece).
Non-vacuity stays a machine artifact stored in the fragment and read mechanically - invocation counts
for an R1 twin, fixture or read-set coverage, a seam-probe activation record, or an explicit
declarations-only proof - so "exercised" is proven, never assumed.

## When several people share the project

The mechanics hold once identity, authorization and claim lifecycle are explicit, because the system
coordinates on ground truth (claims, the map, generated TRACE), not on who drives. Pushed claim refs
become the cross-operator collision detector, and a worker may open a product pull request that the
Seshat-Integrator merges instead of landing from a local branch. Each person drives their own workers; the
atomic claim arbitrates races. Orchestration is federated (one per person, computing the same
ready-set) or one shared scheduler. Independence gains a human dimension: the reviewer comes from
outside the author's team, made machine-checkable by the fragment's `author_team` and
`reviewer_team`. The land funnel stays one shared queue (a rotating duty or a charter-authorized
bot). Specific people own the coupled-core surfaces; the leaf base is self-serve. New with people:
explicit identity and attribution, charter-recorded authority (who may mark proven, land and sign),
permissions (who may push a claim, touch a protected surface, run the queue), contract changes
serialized by the owner, abandoned claims sent to triage, and stronger lesson mechanization, since
the checks are the team's shared memory. Independence is not waivable: an author-team expert may add
an advisory science review, never the `proven` verdict.

## Done-when

The build order holds end to end on the two-repo model: one worker runs the full loop (Stage 0); the
map lists the ready unguarded pieces (0b); the pilot is proven with the matrix filled, the
must-mechanize traps mechanized and the parallelizability assessment approved (1); the entry check
holds (1.5); the first wave reaches proven and integrated under a green epoch (2); the whole safe
ready-set fans out in parallel (3); and the coupled core reaches the Phase 2 milestone through owned,
contract-checked changes with full evidence (4).
