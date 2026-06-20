---
description: Auto-drive the port from the planner, at the charter's autonomy level
---

Drive the wave loop from the deterministic planner, honoring the charter's autonomy level,
scope, and budgets. The full spec is the code-port skill's `references/auto-mode.md`; this
command is the entry point. Optional argument - `enable [L1|L2|L3]` to turn auto-mode ON by
scaffolding the config, an autonomy level to run at, or `status` to just show the plan: $ARGUMENTS

You are acting as **Ptah-Orchestrator**. Auto-mode removes the human *pause* between actions; it
NEVER removes a gate, independence, or the separation of powers. Read `references/auto-mode.md`
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
   artifacts and must never plan on a state the gates would reject. Only then run the planner FOR THE
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
    `python3 tools/coordination/adopt_substrate.py` (one id-keyed `port/status/<id>.yaml` per live unit,
    id = stem(source)), then `python3 tools/coordination/extract_dependencies.py > tools/scoping/dependency-map.yaml`
    (the live dependency map), then `python3 tools/coordination/generate_trace.py` (regenerate the id-keyed
    canonical TRACE). At L1/`status` print the would-be steps and STOP (write nothing); at L2/L3 announce,
    run them, commit the substrate as a setup act, and RE-PLAN at the new HEAD. The ONE genuine
    decision the build cannot derive: if `extract_dependencies.py` fails with a **duplicate file stem** (a
    multi-variant SOURCE - several build variants share a stem, and which is the LIVE one is a scoping call),
    HALT and name `tools/scoping/source-exclude.yaml` (declare the dead variants coarsely; template
    `assets/source-exclude.template.yaml`) - never auto-pick a variant. Adopt is idempotent, so re-run it
    after declaring exclusions. With the substrate present, re-run the planner: if that plan comes back all-guarded or
     unmapped, the blockers are unit scoping and the §7 whole-program acceptance criterion (the parity
    band + tolerance table) - and at L2/L3 you DERIVE-AND-PROCEED on them, never hand back a bare
    blocker list, never stop for a per-setup OK. For the §7 criterion: derive a concrete per-field
    parity band (approx-eq atol/rtol per field) PRINCIPLED from the reference-run fields, the Phase-1
    tooling baseline's tolerances, and the conventions, recording that derivation as the rationale, and
    write it into charter §7. For scoping: take the owned-foundation `assign` units as the bootstrap
    wave and record the assignment so the pool opens. For units `guarded` by a PARSER-ARTIFACT guard
    (`coverage-gap:*` / `suspected-coupling` - a continuation, a generic interface, an
    unresolved-but-absent reference, NOT a structural `shared-surface`/`owned-foundation`): AUDIT the
    SOURCE, and for each confirmed-false guard record a reviewed `tools/scoping/dependency-overlay.yaml`
    resolution (node + cleared reasons + justification + the node's `source_sha`); the extractor applies
    it and `check-depmap` stays green - one step opens a whole batch (the loader refuses any
    structural-guard clear; any later source change to an audited node fails closed). Then RE-PLAN at the
    new HEAD. **The fidelity safety on this auto-derivation: every piece of it - the §7 band, the overlay
    clears - is committed and gated. The overlay clears carry an INDEPENDENT (different-model) review and a
    content-bound `source_sha` stale-fail; the §7 band is checked by the differential gates at every land;
    so the standard is derived principled-ly and reviewed, never silently invented.** At **L1/`status`** the opposite: RECOMMEND each with rationale
    and STOP for the human's explicit OK before writing anything. HALT (even at L2/L3) only on a GENUINE
    decision the gates cannot derive - a real coupling that is NOT a parser artifact, a conflicting
    standard. A *retrospective* is NEVER one of those decisions: an accumulated list of mechanization
    candidates (recurring manual steps worth a future tool) is RECORDED and the loop keeps DRIVING -
    build the candidates at a phase boundary, never stop mid-run to "design an edge-resolution
    mechanism." And never mis-classify a wave-unblock (the audit-and-overlay-clear or the
    assign-bootstrap above) as a deferred candidate: it is derive-and-proceed work you do NOW to widen
    the wave, not a tool to build later. **One specific stop is DRIVABLE work, not a wall - so DRIVE it, do not halt:** when the
    FIRST translated piece is R0-clean and independently reviewed but cannot gate because gating needs R1
    (a real differential against SOURCE) and the cross-language capture-replay harness / R1 gate does not
    exist yet (a charter that defers it to co-develop with the first TARGET code simply has not built it),
    recognize this is a **deferred PHASE-1 TOOLING** unit: the R1 gate (`gates-r1`) and its harness are
    MODELED Phase-1 tooling units (`tools/coordination/scaffold_phase1_plan.py`), driven by the SAME
    audited loop as the rest of the tooling. So at L2/L3 DRIVE it - ensure a Phase-1 tooling plan covers
    the deferred R1 units (scaffold it if absent), then run `python3 tools/coordination/phase1_drive.py`
    to build them through the normal tooling lifecycle - claim -> work (build + the seeded-bug red->green
    demo) -> INDEPENDENT review (a distinct reviewer on a different model) -> integrate - parallelized
    across the ready-set. It is auto-BUILT but never auto-TRUSTED: each gate/check carries its
    **seeded-bug evidence + an independent review** before it is trusted (the meta-gate discipline), all
    committed to the git history (`references/auto-mode.md`). Then re-run the Phase-2 planner: the R0-clean piece gates at R1, the wave
    widens, and it **FLOWS** - no stop. (`port/bring-up-gate.md`, instantiated from
    `assets/BRING-UP-GATE.template.md`, is the human-readable spec of the same deliverables.) Still NEVER
    gate on R0 (R0 may never gate). At **L1/`status`** the opposite: instantiate that spec, RECOMMEND the
    bring-up sprint, and STOP. Both share the exit-code contract and the autonomy levels; only the unit
   lifecycle differs. The exit code is authoritative: `2`
   UNRELIABLE (a malformed artifact - regenerate and stop), `1` HALT (stuck/triage - surface for a
   human and stop), `0` a plan with actions, or DONE. Print the plan. At L1, STOP here.

3. **Execute the wave by trust class**, within `autodrive.scope` and budget (a withheld action is
   surfaced and pauses the loop, even at L3). SETTLE the state-mutating `mark-gated`/`integrate`
   SERIALLY - one at a time, RE-PLANNING between (an integrate moves the base; Seshat rejects a stale
   branch). Then FAN OUT the isolated `claim`/`work`/`review`/`rework` CONCURRENTLY - launch the WHOLE
   safe ready-set in ONE turn as parallel background subagent tasks (fan out is automatic; cap only with
   `budgets.max_in_flight`). Parallel is the default (full rules in `references/parallel-phase-2.md`): no
   earned-width ramp, and foundation-first ORDERS units without serializing independent siblings -
   re-derive and launch the newly-unblocked set together after every integrate. A late bug does not
   narrow the wave (mechanize the check + rework the cohort in parallel; each piece's own gate still
   gates what LANDS). Keep `claim` serial + atomic (`check-claims` green before its worker), and GATHER
   through one writer - a per-branch claim + owned-surface check before accepting each piece, then commit
   the batch's fragments once. Per action:
   - `claim <id>` -> PROVISION its worktree (`provision_worker.sh add <id>`), which writes the local
     claim `port/claims/<id>.yaml` (the worktree IS the lock) and prints the contract, then dispatch a
     worker (Kha-Worker) WITH that contract into its own
     `.worktrees/<id>` worktree - never dispatch a worker without its provisioned worktree (it races the
     shared product tree); the worker runs `assert_isolated.sh` first and refuses if unprovisioned. `work <id>` -> the worker ports + runs `/port-gate` and records
     the fragment. You never author.
   - `review <id>` -> dispatch the SEPARATE `port-review` agent in its own session (a distinct
     reviewer on a different model - the independence control). You never review. A VIOLATIONS verdict is NOT a
     halt - it is the normal review->rework->review loop: the next wave emits `rework`, and you DRIVE it
     (back to the worker, who fixes in its own worktree; then re-review) like any other isolated action,
     never auto-gated and never pausing for a human. Keep looping until the piece is clean or it exceeds
     `budgets.max_rework` (then HALT that piece). A rework whose fix needs a surface OUTSIDE its claim,
     or a charter decision not yet set (an acceptance standard, a withheld scope action), is surfaced as
     that unit's blocker while the rest keep driving.
   - `mark-gated <id>` -> the independent review is recorded clean; run `/port-review`'s
     gate-evidence audit (present, non-vacuous R1+ gate evidence + the explicit clean verdict) and
     record `status: gated` ONLY if it passes. You transcribe the reviewer's recorded outcome into
     the fragment - you never author or produce the verdict yourself.
     - `integrate <id>` -> hand to Seshat (the integrator): land the reviewed piece and record
       `integration.state: integrated` (`product.main_commit` binds the landed commit). A WORKBENCH
       (Phase-1 tooling) integration lands the gated fast-forward via
       `tools/coordination/integrate_land.sh <id>`; a PHASE-2 product piece lands via its analogue
       `tools/coordination/integrate_product.sh <id>` (gated SQUASH onto the product mainline, two-root
       conformance at HEAD AND on the merge result, stale-base rejection, roll-back-on-red, then pushes
       the product - so the target repo fills incrementally as pieces land). An ASSEMBLY-GATED deliverable
       (gate links several modules; full-closure work branches - see two-repo-architecture.md) does NOT
       land per-id; land the whole member group as ONE reviewed assembly piece via
       `tools/coordination/integrate_assembly.sh <assembly-id> --members "<id> ..."` (same fail-closed
       contract, no manifest). All are no-manual-git and fail-closed; record the printed
       `product.main_commit` into the fragment(s) + regenerate TRACE.
   - `guarded` / `assign` / `blocked` / `triage` -> NOT auto-driven; report them.
   - In a **Phase-1** run the same verbs act on a TOOLING unit (references/parallel-phase-1.md):
     `work` = build the tool + seed it red->green + record the F3 evidence (source-demo,
     inertness/non-vacuity, the README enforcement row); `review` = an INDEPENDENT review of the tool;
      `mark-gated` = record acceptance once all five F3 records hold; `integrate` = Seshat merges it
      into the WORKBENCH (no product land) and then RELEASES the unit's now-done claim
      (`tools/coordination/release_claim.sh <id>`) so the completed tooling claim cannot linger into
      Phase 2. Layer 0 (the harness) is gated before the pool opens.

4. **The land scripts ARE the conformance gate - you do not re-run the suite by hand each action.**
   `integrate_product.sh`/`integrate_land.sh`/`integrate_assembly.sh` run two-root conformance at HEAD
   AND on the merge result and ROLL BACK on any red, so a piece can never land over a red gate. ANY red
   surfaced by a land HALTS the run - never auto-repair a trust violation. (One conformance preflight at
   the start of the drive, step 2, guards against planning on a drifted state; between there and a land,
   the isolated worktree work touches nothing the suite gates.)

5. **Loop** (re-run the planner) until DONE or HALT. On DONE, AUTO-FINALIZE the milestone with
   `tools/coordination/finalize.sh <tag> --auto` (at L2 the current phase, at L3 each phase boundary):
   it seals the tag + land with NO human keystroke, refusing unless autodrive is L2/L3 and the full
   conformance suite is green at HEAD. The acceptance authority is those gates, the per-piece INDEPENDENT
   review already bound to every gated commit (check-trace-evidence), and the §7 whole-program criterion
   the human set ONCE in the charter - not a per-milestone countersign. At L3, continue into the next
   phase; at L2, stop at the phase boundary. On HALT, tell the human exactly what is waiting and why (the
   git history is the record).

The planner is pure and deterministic, so anyone can re-run `autodrive.py` at any committed state
and get the same plan the bot acted on - the git history plus the committed artifacts (gate evidence,
recorded reviews, fragments, TRACE) make the whole run auditable.
