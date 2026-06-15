# Parallel Phase 2 (the bulk translation, many workers at once)

How to port the bulk of the SOURCE with many LLM-driven workers in parallel, **without
weakening any fidelity guarantee**. This is the execution roadmap on top of the
coordination substrate (`references/team-coordination.md`) and the parallel-Phase-1
tooling (`references/parallel-phase-1.md`); it does not re-specify them. It assumes
**Phase 1 is finished**: a reference run, the differential tooling, the gates (R0–R5) and
conformance checks, and the confidence-labeled dependency map all exist - without them a
worker's gate has nothing to check against.

"**Piece**" = a coherent deliverable (a module plus the helpers only it uses), claimed,
ported, gated, reviewed, and integrated as one unit.

> Execution note: this is a protocol for a live, multi-contributor port. It runs on the
> two-repo model (WS-C) with the WS-E0 operational machinery (generator, dashboard,
> integrator/merge-queue) in place. The methodology here lands on the branch; the run is
> per-project (the partition, owners, widths, and cadence live in the charter).

## Non-negotiables (parallelism changes throughput, not the bar)

- Every piece earns `gated` the same way: its acceptance gate passes (tier R1+, never R0)
  AND an independent fidelity review is clean, evidence recorded. No piece merged on speed.
- Review independence is real: the reviewer is a separate session (ideally a different
  model; at human scale a different person/team), never in the piece's `author_sessions`.
- The seeded-bug rule holds for every new check; new checks are themselves gated.
- The numerical safety net is the **differential gates**, not the review - per piece AND
  again at integration. The review catches structural/literal-translation faults; it is
  not the backstop for silent numerical drift. Both run; neither is dropped for speed.
- Protected surfaces are off-limits to leaf work (the gates/diff/conformance tooling,
  `reference/` and tolerances, `source/`, the conventions, the charter and its acceptance
  criteria + named exceptions (`port/plan/00-charter.md`), `KNOWN-DIVERGENCES`, the map/
  generator/dashboard, the status schema, the interface contracts (`port/COORDINATION.md`),
  the epoch/audit logic). Touching them is an owned tooling change: owner + seeded proof +
  independent review + its own merge.
- The human still decides milestone acceptance (`SIGNOFF.md`); parallelism batches the
  human's decisions, never self-certifies. No program names leak into the methodology.

## The four roles, kept distinct

- **Worker** - the standard sprint agent, porting one piece in its own branch +
  `.worktrees/` worktree, opening a PR. Many run in parallel.
- **Reviewer** (`.opencode/agents/port-review.md`) - an independent agent (separate
  session, ideally a different model, never the author) reviewing a finished piece. Many
  run in parallel.
- **Orchestrator = Ptah** (`.opencode/agents/ptah.md`) - the scheduler and the human's
  front door: derives the ready-set from the map + generated TRACE + claims, dispatches
  pieces to workers, gathers verdicts, and **regularly reports human-readable DERIVED
  status** - a work-items table + an active-agents table + what changed + the ramp numbers,
  produced by running the dashboard, never narrated. It fans out and reports; it does
  **not** review, merge, or self-certify.
- **Integrator** (`.opencode/agents/integrator.md`) - the single writer of the canonical
  line: merges reviewed-clean PRs through **one queue**, dependency-ordered, rejecting
  stale-base branches, running the integration epoch, regenerating canonical TRACE. A role,
  not an irreplaceable person (it rotates, or is a charter-authorized merge-queue bot); the
  point is one funnel. It PREPARES the merge; the actual merge/push is human/charter-bot-run
  - `auto-gate` authorizes recording `status: gated`, NOT merging.

It is PR-based: branch -> PR. Fast gates block every merge; the expensive integration
epoch runs on a cadence - dispatch stays parallel, only the final merge is serialized.

## Two-repo wiring (WS-C)

Worker PRs land in the **product** repo (clean code commits). Their evidence - the review
report, the gate logs, the status fragment - lands in the **workbench**. The integrator
merges the product PR **and** records the workbench audit manifest
(`assets/audit-manifest.template.yaml`) as one logical step: the manifest binds the
squashed product commit to its evidence (C4), and `port/product.yaml`'s `attested_commit`
advances. The fidelity gates and the epoch run from the workbench against the product
checkout (the two-root contract, C6).

## The wave protocol (the repeating loop)

1. **Compute the ready-set** from canonical TRACE + the map: pieces whose dependencies are
   all `integration.state: integrated` (merged AND covered by a green epoch - not merely
   `gated` on an unmerged branch), whose couplings are **all proven**, and **unclaimed**.
   Cap at the current allowed width.
2. **Dispatch workers.** Each claims its piece (pushed claim ref, human-confirmed), opens
   an isolated branch, runs the normal single-piece sprint loop. Workers never touch each
   other's files or the central status.
3. **Gate in CI** per PR. A red gate keeps the piece out; the worker fixes and re-runs.
4. **Independent review, in parallel** - separate reviewer (clean context, ideally a
   different model, session not in `author_sessions`); report + verdict.
5. **Integrate in dependency order.** The integrator merges reviewed-clean pieces through
   the single queue, rejecting any stale-base branch, and regenerates canonical TRACE from
   the fragments (the generator is **deterministic** - a crashed wave is re-runnable). The
   integrator merges cleanly only; if a merge needs a code change, that is a **new authored
   change** (its session goes in `author_sessions`; re-gate + re-review - the integrator
   must not become an unreviewed author).
6. **Run the integration checks** at the charter's cadence: the differential comparison
   against the reference run at integration level (the silent-drift backstop) plus fast
   structural checks. A completed full differential run over a set of merged commits is an
   **integration epoch**, recorded as an **epoch certificate** (commit range + exact HEAD,
   reference-run id + checksum, gate script + logic-commit, R-tier/config/duration,
   per-field tolerances, output-evidence path, pass/fail). Its GREEN certificate - not
   mere "merged" - proves the wave safe; a failure is bisected to the piece.
7. **Harvest and ratchet.** Any new trap is triaged (below); a must-mechanize trap gets its
   seeded-proven check **before the next wave widens**.
8. **Wave checkpoint.** The human (and subsystem owners) reviews an aggregate - not
   piece-by-piece - and approves *proceeding*. A checkpoint is "ok to proceed," NOT
   milestone acceptance (no tag, not the phase `SIGNOFF.md`). Then loop.

A crashed/abandoned worker does NOT free its claim: it goes to "needs triage." **Rollback
is a queue event, not an edit:** the integrator reverts the merge through the queue, the
generator marks transitive dependents stale/needs-regate, and invalidated evidence is kept
but no longer counted current. **Every wave leaves a wave audit summary** - linking that
wave's per-deliverable audit manifests, the epoch certificate, the merge order, any
bugs-found-late, rollbacks/invalidations, queue age, and cost - the record a human signs
the checkpoint against (distinct from the per-deliverable WS-C audit manifest).

## Disposition of a reviewed piece

Per unit (the v1 `/port-review` disposition carries forward): any finding blocks `gate`;
**send back** a fixable finding to the worker; **defer** with a recorded reason for a
blocked/governance case (stays in the queue); **gate** only a clean piece (gate-evidence
audit OK) - by human gate, or the opt-in `auto-gate: clean-only` policy which records
`status: gated` but never merges.

## Mechanize the traps before you fan out (the ramp's driver)

A loose parallel worker is safe **only for mistakes an automatic check would catch
anyway** - parallel workers do not share mid-flight lessons. So parallel width is bounded
by how many of the codebase's traps are machine-caught. Triage each trap:
**must-mechanize** (clear failure class, cheap, near-zero false alarms, seedable -> build
the seeded check), **reviewer-checklist** (real but not cheaply mechanizable -> trap
table, every reviewer checks by hand), or **owned/serial** (only safe under an owner ->
out of the loose pool). Do not build a check for every trap (check sprawl is its own
failure). The ramp is driven by **check coverage**, not a calendar.

## Staged build order

- **Stage 0 - machinery:** the WS-E0 substrate works for ONE worker end-to-end (claim ->
  branch -> CI gate -> independent review -> integrate -> regenerated TRACE, no hand-edited
  central status; dashboard correct).
- **Stage 0b - map + confidence:** the extractor labels coupling proven/suspected/unknown
  **per piece AND per coupling class** (build, call, globals/shared data, I/O schema,
  generated sources, conditional compilation, runtime dispatch, config-selected paths). Any
  class with no analysis is `unknown`. A piece is loose-pool-eligible only if **every** class
  is proven. "No edge found" is never "no coupling."
- **Stage 1 - trap-harvest pilot:** port a **representative** slice (a representation matrix:
  pure kernel, wide-footprint routine, seam, shared-layout, config-selected path, I/O path,
  constants/table, generated/registry) serially or with very few workers, to surface traps.
  An unrepresented kind gets loose-pool width 0 until one of its kind is gated.
- **Stage 1.5 - the fan-out entry gate (hard):** do NOT start parallel work until ALL hold:
  status sharded+generated (central-write refuses in team mode); protected-surface detector
  built+seeded; evidence commit-bound; the integration epoch runnable on demand; every
  coordination detector seeded; the map confidence model live and the dashboard lists
  "all couplings proven, unclaimed." A missing line is a hole a silent error fits through.
- **Stage 2 - first capped wave (3–5 workers):** the full loop end-to-end incl. a completed
  green epoch.
- **Stage 3 - widen** per the ramp rule.
- **Stage 4 - the coupled core:** owned, contract-gated, near-serial; a foundation is
  `integrated` **before** the wave that depends on it, then **frozen** for that wave's
  duration (changing it mid-flight invalidates every dependent).

## Parallelizability assessment (once, up front; lives in the charter)

Before wide parallelism, write a short assessment for THIS codebase: the **shape of the
map** (a wide independent base, or a tangled/cyclic/global-state-heavy core with little
safe parallelism - if the latter, expect more serial work and invest in seams/contracts
first); **map coverage** (proven vs suspected vs unknown - unknown caps the loose pool);
the **trap surface** (how many recurring traps, and how many already machine-caught); and
**integration cost** (how expensive a full epoch is, hence the cadence). Its output is a
**realistic ceiling** on parallel width and an honest list of what stays serial - do not
promise speed the codebase's shape cannot give.

## The ramp rule (width is earned on completed epochs)

Start small, on all-couplings-proven pieces. **Widen only after a clean *completed
integration epoch*** over the last wave's commits - "merged and fast checks green" is not
enough; the slow differential proof must have happened, with every piece gated+integrated,
**no bug found late**, gates **non-vacuous**, the queue bounded, and no review violations.
**Narrow immediately** on any of those failing (a late bug means a must-mechanize trap is
unmechanized - build the check before widening). **Hard-cap** at the parallelizability
ceiling (the assessment above). The widening barrier: every commit dispatched at the
current width is merged or abandoned and covered by one green epoch certificate before widening.

**Non-vacuity must be a machine artifact, not a vibe** - stored in the fragment/manifest
and read mechanically by the ramp (invocation counts for an R1 twin, fixture/read-set
coverage for capture-replay, a seam-probe activation record, or an explicit
"declarations-only" proof). The reviewer's vacuity flag stays; the ramp keys off the artifact.

## When several people share the project

The mechanics survive once identity, authorization, and claim lifecycle are explicit,
because the system coordinates on ground truth (pushed claim refs, PRs, the map, generated
TRACE), not on who drives. Workers: each person drives their own fleet; the atomic claim
arbitrates races. Orchestrator: federates (one per person) computing the same ready-set,
or one shared scheduler. Reviewer: independence gains a **human dimension** - a different
person/team, made machine-checkable via the fragment's `author_id`/`author_team` +
`reviewer_id`/`reviewer_team` (reviewer outside the author team). Integrator: stays ONE
shared queue (rotating duty or charter-authorized bot). Owners: specific people own the
coupled-core surfaces; the leaf base is self-serve. New once the actors are people:
explicit identity/attribution, federated authority (charter-recorded who-may-gate/merge/
sign), trust/permissions (who may push a claim, touch a protected surface, operate the
queue), the coupled core as the one place people must talk (contract-change PRs serialized
by the owner), claim-lifecycle abandonment = "needs triage", and harder lesson
mechanization (the gates are the team's shared memory). Independence is **not waivable**:
for a deep kernel an author-team expert may add an *advisory* science review, never the
`gated` verdict.

## Done-when

The build-order checklist is satisfied end-to-end on the two-repo model: one worker works
the full loop (Stage 0); the map lists all-couplings-proven unclaimed pieces (Stage 0b);
the pilot is gated with the matrix filled and must-mechanize traps mechanized and the
parallelizability assessment approved (Stage 1); the entry gate holds (Stage 1.5); a capped
wave reaches gated+integrated under a green epoch (Stage 2); the ramp gates width on
completed epochs (Stage 3); and the coupled core is ported through owned contract-gated
changes to the Phase 2 milestone with full evidence (Stage 4) - the fidelity trust core
intact throughout.
