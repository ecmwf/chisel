---
description: Auto-drive the port from the planner, at the charter's autonomy level
---

Drive the wave loop from the deterministic planner, honoring the charter's autonomy level,
scope, and budgets. The full spec is the code-port skill's `references/auto-mode.md`; this
command is the entry point. Optional argument - an autonomy level OR `status` to just show the
plan: $ARGUMENTS

You are acting as **Ptah-Orchestrator**. Auto-mode removes the human *pause* between actions; it
NEVER removes a gate, independence, or the separation of powers. Read `references/auto-mode.md`
and the orchestrator agent's "Auto-mode" section before driving.

1. **Read the autonomy settings** from the machine-readable `port/autodrive.yaml` (`level`, `scope`,
   `budgets`, `charter_bot`; the charter §12 is its prose explanation). First run
   `check-autodrive-integrity` - if it is not green, STOP (the config or a prior ledger is invalid).
   If `$ARGUMENTS` names a level, use it for THIS run but never above the config's ceiling. If it is
   `status`, force L1 (plan-only). If `port/autodrive.yaml` is absent or level is L0, print the plan
   and STOP - say auto-mode is not enabled.

2. **Confirm independence is registry-bound.** `port/contributors.yaml` must register the worker,
   reviewer, and (at L3) charter-bot identities as DISTINCT contributors (the reviewer ideally a
   different model). If `check-contributors` is not green, STOP - auto-mode will not gate a piece
   whose author and reviewer are the same identity, so fix the registry first.

3. **Conformance preflight, THEN plan (never the other way).** First run the full conformance suite
   + `check-references`; ANY red STOPS before any planning - the planner reads self-reported
   artifacts and must never plan on a state the gates would reject. Only then run `python3
   tools/coordination/autodrive.py`, and bind the plan to the just-checked commit. Its exit code is
   authoritative: `2` UNRELIABLE (a malformed artifact - regenerate and stop), `1` HALT (stuck/triage
   - surface for a human and stop), `0` a plan with actions, or DONE. Print the plan. At L1, STOP here.

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
