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
   configured by `port/autodrive.yaml`, and this writes it for you - do NOT hand-author the YAML.
   Run `python3 tools/coordination/enable_autodrive.py --level <the level given, else L1>`. It
   scaffolds a valid, commented config from the template (L1 = plan-and-stop by default) and runs
   `check-autodrive-integrity`. Report what it wrote and what the gate said, then STOP - enabling is
   a config act, not a drive. For L2/L3 add `--max-waves N` and `--max-wall-clock 4h` (or
   `--max-cost`), and at L3 `--charter-bot <id>`; and remind the human those levels also need
   DISTINCT identities registered in `port/contributors.yaml` plus the substrate (status fragments,
   dependency map) before a real run. Tell them to re-run `/port-autodrive` (no argument) to drive.

1. **Read the autonomy settings** from the machine-readable `port/autodrive.yaml` (`level`, `scope`,
   `budgets`, `charter_bot`; the charter §12 is its prose explanation). First run
   `check-autodrive-integrity` - if it is not green, STOP (the config or a prior ledger is invalid).
   If `$ARGUMENTS` names a level, use it for THIS run but never above the config's ceiling. If it is
   `status`, force L1 (plan-only). If `port/autodrive.yaml` is absent or level is L0, print the plan
   and STOP - say auto-mode is not enabled, and tell the human to turn it on with
   `/port-autodrive enable L1` (or `python3 tools/coordination/enable_autodrive.py --level L1`).

2. **Confirm independence is registry-bound.** `port/contributors.yaml` must register the worker,
   reviewer, and (at L3) charter-bot identities as DISTINCT contributors (the reviewer ideally a
   different model). If `check-contributors` is not green, STOP - auto-mode will not gate a piece
   whose author and reviewer are the same identity, so fix the registry first.

3. **Conformance preflight, THEN plan (never the other way).** First run the full conformance suite
   + `check-references`; ANY red STOPS before any planning - the planner reads self-reported
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
   `port/phase1-plan.yaml` as a setup act, then RE-RUN the full conformance suite + `check-references`
   and re-bind to that new commit (you just moved HEAD) before running `phase1_drive.py` to drive
   Layer 0 - so the loop has the harness to claim instead of an all-guarded Phase-2 plan. Only when Phase 1 is complete run `python3
   tools/coordination/autodrive.py` (Phase 2 - translation); if that plan comes back all-guarded or
   unmapped, the blockers are unit scoping and the §7 whole-program acceptance criterion (the parity
   band + tolerance table) - name them and stop, because auto-mode cannot invent the standard the
   port is measured against. Both share the exit-code contract, the autonomy levels, the ledger, and
   `check-autodrive-integrity`; only the unit lifecycle differs. The exit code is authoritative: `2`
   UNRELIABLE (a malformed artifact - regenerate and stop), `1` HALT (stuck/triage - surface for a
   human and stop), `0` a plan with actions, or DONE. Print the plan. At L1, STOP here.

3b. **Open the ledger** for this run at `docs/evidence/autodrive/<run-id>/ledger.yaml` (run-id =
   timestamp; template `assets/autodrive-ledger.template.yaml`). Every decision below appends one
   entry (action, unit, the planner's rationale verbatim, the agent/command dispatched, the result,
   and the post-action `conformance_after`). `check-autodrive-integrity` audits this file, so keep
   the fail-closed invariant: a non-green `conformance_after` may appear only on the LAST decision of
   a `verdict: halt` run.

4. **Execute each DO action** in order, only within `autodrive.scope` and budget (a withheld action
   is surfaced and pauses the loop, even at L3):
   - `claim <id>` -> prepare + push `refs/claims/<id>`, then dispatch a worker (Kha-Worker) in its
     own `.worktrees/<id>` worktree. `work <id>` -> the worker ports + runs `/port-gate` and records
     the fragment. You never author.
   - `review <id>` -> dispatch the SEPARATE `port-review` agent in its own session (a distinct
     registered reviewer, ideally a different model). You never review. A VIOLATIONS verdict ->
     `rework` (back to the worker), never auto-gated.
   - `mark-gated <id>` -> the independent review is recorded clean; run `/port-review`'s
     gate-evidence audit (present, non-vacuous R1+ gate evidence + the explicit clean verdict) and
     record `status: gated` ONLY if it passes. You transcribe the reviewer's recorded outcome into
     the fragment - you never author or produce the verdict yourself.
   - `integrate <id>` -> hand to Seshat (the integrator): build the audit manifest, land the product,
     record `integration.state: integrated`. You never merge.
   - `guarded` / `assign` / `blocked` / `triage` -> NOT auto-driven; report them.
   - In a **Phase-1** run the same verbs act on a TOOLING unit (references/parallel-phase-1.md):
     `work` = build the tool + seed it red->green + record the F3 evidence (source-demo,
     inertness/non-vacuity, the README enforcement row); `review` = an INDEPENDENT review of the tool;
     `mark-gated` = record acceptance once all five F3 records hold; `integrate` = Seshat merges it
     into the WORKBENCH (no product manifest). Layer 0 (the harness) is gated before the pool opens.

5. **Re-run the conformance suite after each wave.** ANY red HALTS the run and is surfaced - never
   auto-repair a trust violation. Record the verdict in the ledger.

6. **Loop** (re-run the planner) until DONE or HALT. On DONE, the run must clear an INDEPENDENT
   auto-run review before its results are trusted: `/port-review-autorun` in a FRESH session (replays
   the planner at each `planned_at_commit`, spot-checks reviewer independence, confirms no decision
   drove past a red). Then prepare `/port-digest`; at L3 the charter-bot records a `BOT_ATTESTATION.md`
   (NEVER `SIGNOFF.md`) and the milestone git-tag + final phase acceptance still require a human
   COUNTERSIGN of that attestation - contingent on a clean auto-run review, the one human touch
   auto-mode never forges. On HALT, leave everything recorded in the ledger and tell the human exactly
   what is waiting and why.

The planner is pure and deterministic, so anyone can replay `autodrive.py` at any committed state
and get the same plan the bot acted on - the ledger plus the artifacts make the whole run auditable.
