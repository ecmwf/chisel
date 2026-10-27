---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Auto-drive the port from the planner, at the charter's autonomy level
---

Drive the wave loop from the deterministic planner, honoring the charter's autonomy level,
scope, and budgets. The full spec is the code-port skill's `references/auto-mode.md`; this
command is the entry point. Optional argument - `enable [L1|L2|L3]` to turn auto-mode ON by
scaffolding the config, an autonomy level to run at, or `status` to just show the plan: $ARGUMENTS

You are acting as **Ptah-Orchestrator**. Auto-mode removes the human *pause* between actions; it
NEVER removes a check, independence, or the separation of powers. Read `references/auto-mode.md`
and the orchestrator agent's "Auto-mode" section before driving.

0. **If `$ARGUMENTS` begins with `enable`** (the toggle that turns auto-mode ON): auto-mode is
   configured by `port/autodrive.yaml`. WRITE it directly from `assets/autodrive.template.yaml` (the
   template documents every field) - set `level` to the level given (else L1, plan-and-stop), `scope`
   to the actions allowed (default the full set), and `budgets`. Budgets all DEFAULT, so `enable L3`
   needs nothing else; L2/L3 require `max_waves > 0` and a `max_wall_clock` (default 24h) - fill those.
   It is a 15-line YAML; the only validation is that the planner reads `level`, so there is nothing to
   "run" and nothing to scaffold. There is NO contributor registry and NO identity to set up:
   independence is the different-model reviewer, recorded per unit. Report what you wrote, then STOP -
   enabling is a config act, not a drive; they re-run `/port-autodrive` (no argument) to drive.

1. **Read the autonomy settings** from the machine-readable `port/autodrive.yaml` (`level`, `scope`,
   `budgets`; the charter §12 is its prose explanation). If `$ARGUMENTS` names a level, use it
   for THIS run but never above the config's ceiling. If it is `status`, force L1 (plan-only). If
   `port/autodrive.yaml` is absent or level is L0, print the plan and STOP - say auto-mode is not
   enabled, and tell the human to turn it on with `/port-autodrive enable L1` (which writes
   `port/autodrive.yaml` from the template).

2. **Conformance preflight, THEN plan (never the other way).** First run the full conformance suite
   (`bash tools/run-conformance.sh`); ANY red STOPS before any planning - the planner reads self-reported
   artifacts and must never plan on a state the checks would reject. Only then run the planner FOR THE
   CURRENT PHASE, binding the plan to the just-checked commit, and pick the phase by STATE - never
   fall through to Phase 2 over a Phase 1 that was never built. Run `python3
   tools/coordination/phase1_drive.py` (Phase 1, the tool-build loop) when `port/phase1-plan.yaml`
   exists and its units are not all integrated. When that plan is ABSENT, do NOT fall through to Phase 2.
   First require a VERIFIED Phase 0 sign-off - the `phase0-signed` tag, an ancestor of HEAD; without
   it HALT and name Phase 0 sign-off as the blocker (never scaffold-and-drive over an unsigned Phase
   0). With it, Phase 1 simply has not been planned yet: scaffold it with `python3
   tools/coordination/scaffold_phase1_plan.py` (the methodology's canonical representative unit set,
   valid by construction). At L1/`status` this is `--dry-run` ONLY - print the would-be plan and STOP,
   writing nothing (L1 executes nothing). At L2/L3, announce the setup, write it, commit
   `port/phase1-plan.yaml` as a setup act, then RE-PLAN at the new HEAD by running `phase1_drive.py` to
    drive Layer 0 - so the loop has the harness to claim instead of an all-guarded Phase-2 plan. Only when Phase 1 is complete run `python3
    tools/coordination/autodrive.py` (Phase 2 - translation). If that planner HALTs **"no coordination
    substrate"** with a `port/TRACE.yaml` PRESENT, a hand-driven Phase 0/1 left a SOURCE-keyed pilot TRACE
    (id-less rows the planner's id-keyed join drops) and no fragments/map - so BUILD the substrate first,
    the Phase-2 analogue of the Phase-1 scaffold (deterministic derive-and-proceed, not a human decision):
    for each LIVE, UNMAPPED TRACE row, WRITE one minimal `port/status/<id>.yaml` fragment (id = stem(source);
    `id`/`source`/`target`/`status: unmapped`/`ownership.kind: leaf` - the form in
    `assets/status-fragment.template.yaml`), plus `port/status/_meta.yaml` (the TRACE meta:
    source_root/target_root/commits). NEVER fabricate a fragment for a row already `in-progress`/`proven` -
    its claim/author/independent-review evidence is REAL and must be authored by hand, never invented
    (`check-trace-evidence` would catch an invented one). Then `python3 tools/coordination/extract_dependencies.py
    > tools/scoping/dependency-map.yaml` (the live dependency map) and `python3 tools/coordination/generate_trace.py`
    (regenerate the id-keyed canonical TRACE); `check-status-fragments` validates every fragment you wrote.
    At L1/`status` print the would-be steps and STOP (write nothing); at L2/L3 announce,
    do it, commit the substrate as a setup act, and RE-PLAN at the new HEAD. The ONE genuine
    decision the build cannot derive: if `extract_dependencies.py` fails with a **duplicate file stem** (a
    multi-variant SOURCE - several build variants share a stem, and which is the LIVE one is a scoping call),
    HALT and name `tools/scoping/source-exclude.yaml` (declare the dead variants coarsely; template
    `assets/source-exclude.template.yaml`) - never auto-pick a variant. With the substrate present, re-run the planner: if that plan comes back all-guarded or
     unmapped, the blockers are unit scoping and the §7 whole-program acceptance criterion (the parity
    band + tolerance table) - and at L2/L3 you DERIVE-AND-PROCEED on them, never hand back a bare
    blocker list, never stop for a per-setup OK. For the §7 criterion: derive a concrete per-field
    parity band (approx-eq atol/rtol per field) PRINCIPLED from the reference-run fields, the Phase-1
    tooling baseline's tolerances, and the conventions, recording that derivation as the rationale, and
    write it into charter §7. For scoping: the only guards the map now carries are STRUCTURAL (the
    extractor does not guess - it emits only those structural guards). An `owned-foundation` -> `assign`
    it to its owner as the bootstrap wave and record the assignment so the pool opens. A `shared-surface`
    (an unowned common block / shared seam) -> the human scopes the seam (it is real coupling, not a
    parser artifact, so there is nothing to "clear"). Then RE-PLAN at the new HEAD. **The fidelity
    safety on this auto-derivation: the §7 band is committed and checked by the differential proofs at
    every land, so the standard is derived principled-ly, never silently invented; and a unit auto-claimed
    from the pool that turns out to have a real hidden coupling fails its R1 differential or the
    independent review.** At **L1/`status`** the opposite: RECOMMEND each with rationale
    and STOP for the human's explicit OK before writing anything. HALT (even at L2/L3) only on a GENUINE
    decision the checks cannot derive - a real shared-surface seam to scope, a conflicting
    standard. A *retrospective* is NEVER one of those decisions: an accumulated list of mechanization
    candidates (recurring manual steps worth a future tool) is RECORDED and the loop keeps DRIVING -
    build the candidates at a phase boundary, never stop mid-run to design new scoping machinery.
    And never mis-classify a wave-unblock (the assign-bootstrap above) as a deferred candidate: it is
    derive-and-proceed work you do NOW to widen
    the wave, not a tool to build later. **One specific stop is DRIVABLE work, not a wall - so DRIVE it, do not halt:** when the
    FIRST translated piece is R0-clean and independently reviewed but cannot be proven because proving needs R1
    (a real differential against SOURCE) and the cross-language capture-replay harness / R1 proof does not
    exist yet (a charter that defers it to co-develop with the first TARGET code simply has not built it),
    recognize this is a **deferred PHASE-1 TOOLING** unit: the R1 proof (`proofs-r1`) and its harness are
    MODELED Phase-1 tooling units (`tools/coordination/scaffold_phase1_plan.py`), driven by the SAME
    audited loop as the rest of the tooling. So at L2/L3 DRIVE it - ensure a Phase-1 tooling plan covers
    the deferred R1 units (scaffold it if absent), then run `python3 tools/coordination/phase1_drive.py`
    to build them through the normal tooling lifecycle - claim -> work (build + the seeded-bug red->green
    demo) -> INDEPENDENT review (a distinct reviewer on a different model) -> integrate - parallelized
    across the ready-set. It is auto-BUILT but never auto-TRUSTED: each proof/check carries its
    **seeded-bug evidence + an independent review** before it is trusted (the meta-check discipline), all
    committed to the git history (`references/auto-mode.md`). Then re-run the Phase-2 planner: the R0-clean piece is proven at R1, the wave
    widens, and it **FLOWS** - no stop. (`port/bring-up-harness.md`, instantiated from
    `assets/BRING-UP-HARNESS.template.md`, is the human-readable spec of the same deliverables.) **The
    STRUCTURAL version of this is the SAME DRIVE, not a halt:** when the planner exits stuck because every
    FOUNDATION is declaration-only (`validation: transitive` -> `park` -> never individually proven at R0,
    since R0 can never prove) and so the numeric consumers stay `blocked` behind foundations that never
    integrate per-id, that is NOT a deadlock to hand back and NOT a "decision the checks cannot derive" -
    it is the ASSEMBLY-PROVING case, and the structure DERIVES it. At L2/L3 DRIVE all of it: derive the
    assembly membership from the dependency closure (the numeric units - kernel -> driver -> entry - plus
    their transitive declaration-only foundations); build the deferred R1 twin harness as above
    (`phase1_drive.py`); port the foundations (assign-bootstrap, dependency order) and the numeric units;
    prove the whole closure at R1; and land it as ONE reviewed assembly via
    `tools/coordination/integrate_assembly.sh <assembly-id> --members "<id> ..."`, which transitively
    validates the parked foundations. Do NOT stop to "scope the assembly" or to ask permission to
    "assembly-prove" - recording the derived assembly id + members is a setup act, the §7 band is already
    set, and `integrate_assembly` is the guarded land. The ONLY thing that ever halts here is a GENUINE
    non-derivable decision (a real shared-surface seam whose owner is a human call, a conflicting
    standard) - never the deadlock itself. Still NEVER
    mark a unit proven on R0 (R0 may never prove). At **L1/`status`** the opposite: instantiate that spec, RECOMMEND the
    bring-up sprint, and STOP. Both share the exit-code contract and the autonomy levels; only the unit
   lifecycle differs. The exit code is authoritative, but exit `1` is NOT an automatic human-halt at
   L2/L3: `2` UNRELIABLE (a malformed artifact - regenerate and stop); `1` STUCK - at L2/L3 this is the
   DERIVE-AND-PROCEED trigger (assign-bootstrap the foundations, derive the §7 band, build the deferred
   tooling, assembly-prove the closure - all above), and you HALT only when what remains is a GENUINE
   decision the artifacts cannot derive, never the bare exit code; `0` a plan with actions, or DONE.
   Print the plan. At L1, STOP here.

3. **Before every dispatch, RESOLVE the live facts - never cite a SHA from memory.** Run
   `bash tools/coordination/unit_state.sh <id> ...`: it prints, per unit, the workbench HEAD, the
   product HEAD, commits behind the mainline and the dirty count, plus the mainline SHA and the live
   conformance-check count. A rebase REWRITES commits, so a brief citing a remembered SHA sends a
   worker or reviewer to a tree that does not match its instructions - they then reconstruct reality
   themselves, which wastes the dispatch and quietly erodes trust in the brief. Cite only what this
   prints. Same rule as session handles (step 3's thread-continuity note): ask the source of truth.

3. **Execute the wave by trust class**, within `autodrive.scope` and budget (a withheld action is
   surfaced and pauses the loop, even at L3). SETTLE the state-mutating `mark-proven`/`integrate`
   SERIALLY - one at a time, RE-PLANNING between (an integrate moves the base; Seshat-Integrator
   rejects a stale branch). Then FAN OUT the isolated `claim`/`work`/`review`/`rework` CONCURRENTLY - launch the WHOLE
   safe ready-set in ONE turn as parallel background subagent tasks (fan out is automatic; cap only with
   `budgets.max_in_flight`). Parallel is the default (full rules in `references/parallel-phase-2.md`): no
   earned-width ramp, and foundation-first ORDERS units without serializing independent siblings -
   re-derive and launch the newly-unblocked set together after every integrate. A late bug does not
   narrow the wave (mechanize the check + rework the cohort in parallel; each piece's own proof still
   guards what LANDS). Keep `claim` serial + atomic (`check-claims` green before its worker), and GATHER
   through one writer - a per-branch claim + owned-surface check before accepting each piece, then commit
   the batch's fragments once. Per action:
   - `claim <id>` -> PROVISION its worktree (`provision_worker.sh add <id>`), which writes the local
     claim `port/claims/<id>.yaml` (the worktree IS the lock) and prints the contract, then dispatch a
     worker (Kha-Worker) WITH that contract into its own
     `.worktrees/<id>` worktree - never dispatch a worker without its provisioned worktree (it races the
     shared product tree); the worker runs `assert_isolated.sh` first and refuses if unprovisioned. `work <id>` -> the worker ports + runs `/port-prove` and records
     the fragment. You never author.
   - `review <id>` -> dispatch the SEPARATE `port-review` agent in its own session (a distinct
     reviewer on a different model - the independence control). You never review. A VIOLATIONS verdict is NOT a
     halt - it is the normal review->rework->review loop: the next wave emits `rework`, and you DRIVE it
     (back to the worker, who fixes in its own worktree; then re-review) like any other isolated action,
     never auto-proven and never pausing for a human. Keep looping until the piece is clean or it exceeds
     `budgets.max_rework` (then HALT that piece). A rework whose fix needs a surface OUTSIDE its claim,
      or a charter decision not yet set (an acceptance standard, a withheld scope action), is surfaced as
      that unit's blocker while the rest keep driving.
    - **Thread continuity - RESUME the per-role thread, do not re-dispatch cold.** When you dispatch a
      worker (`work`) or reviewer (`review`), CAPTURE the opencode SESSION id (`ses_...`) from the Task
      result and record it: `python3 tools/coordination/thread_ledger.py record <id> --role
      worker|reviewer --task-id <ses_...>`. On a REVISIT - a `rework` (the worker) or a re-review (the
      reviewer) - RESUME that thread: `thread_ledger.py resume <id> --role <role>` prints the recorded
      `ses_` id; pass it as the Task       `task_id` to continue the SAME session (the worker still knows the
      piece; the reviewer still knows what it flagged - context preserved, no rebuild). On exit 0 use the
      printed id; on ANY non-zero (3 = none recorded, or 1 = `resume` REFUSED a cross-reused/bad handle)
      dispatch FRESH with a brief - never a halt, never a silent skip. **RESOLVE THE HANDLE FROM THE LEDGER, NEVER FROM THE
      CONVERSATION.** Reading a `ses_` id out of the transcript is how a cross-thread breach
      actually happens: while driving several units at once the ids look alike, and the mistake is
      invisible until a session is asked to review work it wrote. Observed: a rework dispatched to
      the REVIEWER's session, which then authored a methodology-layer fix and, asked to confirm it,
      correctly refused - the control held only because that session was honest about its own
      history. `resume` exists to make this mechanical: call it at dispatch time, every time, the
      same way a piece's SHA is resolved from the tree rather than recalled. **NEVER
      CROSS THREADS:** the WORKER's id only for `rework`, the REVIEWER's only for re-review - resuming a
      worker's thread as the reviewer hands the reviewer the author's context (an independence breach;
      `check-threads` enforces it). The handle is ALWAYS the `ses_` session id, NEVER a composed display
      name (`kha-worker-<unit>-<date>` collides across split work).
    - `mark-proven <id>` -> the independent review is recorded clean; run `/port-review`'s
     proof-evidence audit (present, non-vacuous R1+ proof evidence + the explicit clean verdict) and
     record `status: proven` ONLY if it passes. You transcribe the reviewer's recorded outcome into
     the fragment - you never author or produce the verdict yourself.
     - `integrate <id>` -> hand to Seshat-Integrator (the integrator): land the reviewed piece and record
       `integration.state: integrated` (`product.main_commit` binds the landed commit). A WORKBENCH
       (Phase-1 tooling) integration lands the guarded fast-forward via
       `tools/coordination/integrate_land.sh <id>`; a PHASE-2 product piece lands via its analogue
       `tools/coordination/integrate_product.sh <id>` (guarded SQUASH onto the product mainline, two-root
       conformance at HEAD AND on the merge result, stale-base rejection, roll-back-on-red, then pushes
       the product - so the target repo fills incrementally as pieces land). An ASSEMBLY-PROVEN deliverable
       (proof links several modules; full-closure work branches - see two-repo-architecture.md) does NOT
       land per-id; land the whole member group as ONE reviewed assembly piece via
       `tools/coordination/integrate_assembly.sh <assembly-id> --members "<id> ..."` (same fail-closed
       contract, no manifest). All are no-manual-git and fail-closed; record the printed
       `product.main_commit` into the fragment(s) + regenerate TRACE.
   - `guarded` / `assign` / `blocked` / `triage` -> NOT auto-driven; report them.
   - In a **Phase-1** run the same verbs act on a TOOLING unit (references/parallel-phase-1.md):
     `work` = build the tool + seed it red->green + record the F3 evidence (source-demo,
     inertness/non-vacuity, the README enforcement row); `review` = an INDEPENDENT review of the tool;
      `mark-proven` = record acceptance once all five F3 records hold; `integrate` =
      Seshat-Integrator merges it into the WORKBENCH (no product land) and then RELEASES the unit's now-done claim
      (`tools/coordination/release_claim.sh <id>`) so the completed tooling claim cannot linger into
      Phase 2. Layer 0 (the harness) is proven before the pool opens.

3b. **Keep the TARGET repo current - it is the deliverable, not a final-land surprise.** As pieces
    clear independent review, LAND them on the product `bring-up` PREVIEW branch with
    `tools/coordination/integrate_bringup.sh <id>` (conformance-checked, relaxed - no R1/proven/planner-
    readiness - and NEVER the certified mainline), so the target repo visibly FILLS UP, stays
    clone-build-runnable, and is PUSHED throughout the run. This matters most in an ASSEMBLY bring-up:
    nothing reaches the proven mainline until the assembly is R1-proven, so without the preview the target
    sits empty and unpushed for the WHOLE run - exactly the wrong thing for the actual deliverable. A
    piece graduates to the mainline UNCHANGED when it (or its assembly) is R1-proven
    (`integrate_product.sh` / `integrate_assembly.sh`); the preview is the in-flight buildable view.
    And WRITE + keep current the product README (`assets/PRODUCT-README.template.md` -> the product's
    `README`, authored per `references/product-readme.md`; `tools/conformance/check-product-readme.sh
    --require-filled` is the check that rejects an unfilled placeholder): it is a deliverable kept CURRENT as the product fills -
    the clone-build-run guide for a consumer, describing the honest supported subset during bring-up -
    never deferred to the end. (At L1/`status`, RECOMMEND these; do not push.)

4. **The land scripts ARE the conformance check - you do not re-run the suite by hand each action.**
   `integrate_product.sh`/`integrate_land.sh`/`integrate_assembly.sh` run two-root conformance at HEAD
   AND on the merge result and ROLL BACK on any red, so a piece can never land over a red check. ANY red
   surfaced by a land HALTS the run - never auto-repair a trust violation. (One conformance preflight at
   the start of the drive, step 2, guards against planning on a drifted state; between there and a land,
   the isolated worktree work touches nothing the suite checks.)

5. **Loop** (re-run the planner) until DONE or HALT. On DONE, AUTO-FINALIZE the milestone with
   `tools/coordination/finalize.sh <tag> --auto` (at L2 the current phase, at L3 each phase boundary):
   it seals the tag + land with NO human keystroke, refusing unless autodrive is L2/L3 and the full
   conformance suite is green at HEAD. The acceptance authority is those checks, the per-piece INDEPENDENT
   review already bound to every proven commit (check-trace-evidence), and the §7 whole-program criterion
   the human set ONCE in the charter - not a per-milestone countersign. At L3, continue into the next
   phase; at L2, stop at the phase boundary. On HALT, tell the human exactly what is waiting and why (the
   git history is the record).

5b. **DONE means a WORKING TARGET REPO, not just code-integrated - so the PORT is not DONE until the
    target is handover-ready.** The planner's "DONE" (every SOURCE unit integrated) is CODE-complete; it
    is NOT handover-complete, because the RUN ASSETS a consumer needs to actually build and run have no
    SOURCE file, so the planner never recommends them and they FALL THROUGH. At the FINAL milestone (port
    completion), before the final `finalize.sh --auto`, DRIVE the target to a runnable repo - this is your
    job, not the planner's: (a) bring over the NON-CODE run assets a consumer needs - example/reference
    INPUTS, sample data, runtime configs, example scripts, docs - and land them on the product mainline
    via `tools/coordination/integrate_assets.sh <branch>` (conformance-checked; it REFUSES any
    fidelity-reviewed source OR build file, since those determine numerical behavior - the build files
    /scaffolding ride their own proven CODE pieces under review via `integrate_product.sh` /
    `integrate_assembly.sh`, NEVER the asset path; see `references/two-repo-architecture.md` "Product run
    assets"); (b) EVERY per-unit test we built ships INSIDE the product and is wired into its build -
    `check-product-tests.sh` enforces that no test is a workbench orphan AND (arm 3) that no shipped test
    source is left unregistered by the build, but it cannot know a test that was never composed at all, so
    you must positively CONFIRM each ported unit's test is present (a composition that pulled `src/` + CMake
    but not `tests/` silently drops them - see "assembly piece"); (c) the product README is FILLED
    (`check-product-readme.sh --require-filled`); (d) VERIFY a FRESH CLONE of the product builds and runs its
    self-test, and that `ctest` runs a test for EACH ported unit (not just one) - a clone that runs 1 of N
    tests is not self-testing. Only then is the deliverable handover-ready.
    At L1/`status`, RECOMMEND this checklist; do not land.

The planner is pure and deterministic, so anyone can re-run `autodrive.py` at any committed state
and get the same plan the bot acted on - the git history plus the committed artifacts (proof evidence,
recorded reviews, fragments, TRACE) make the whole run auditable.
