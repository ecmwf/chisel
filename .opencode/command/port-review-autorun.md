---
description: Independent review of an auto-driven run (replay the planner; never the orchestrator session)
---

Independently review an auto-run, so an auto-driven port clears the same human/separate-agent
ceiling a hand-driven one does. The full procedure is the code-port skill's `references/auto-mode.md`
("Independently reviewing an auto-run"); this command runs it. The run to review (a
`docs/evidence/autodrive/<run-id>/` dir, or the latest): $ARGUMENTS

INDEPENDENCE: run this in a FRESH session that did NOT drive the run - the orchestrator never
reviews its own run, exactly as it never reviews code it dispatched. Ideally a different model than
the orchestrator used.

1. **Machine floor.** Run `check-autodrive-integrity` (must be green) and the FULL conformance suite
   at HEAD (all green). A red anywhere is a finding - stop and report it. The end state passing every
   gate is the single strongest evidence the run is sound.
2. **Planner replay.** Read the run's `ledger.yaml`. For each decision (or a representative sample),
   check out its `planned_at_commit` in an ephemeral `.worktrees/replay` worktree, run the planner
   the run used at that commit (`python3 tools/coordination/phase1_drive.py` for a Phase-1 run, else
   `python3 tools/coordination/autodrive.py`), and confirm the decision's `action <unit>` is in that
   plan's DO list. An action the planner never recommended is a finding. (TRACE/map-derived decisions replay
   exactly; for a `claim` decision, confirm the live `refs/claims/*` reflog + the recorded `result`
   instead, since claim refs are not snapshotted per commit.) Tear the worktree down when done.
3. **Independence spot-check.** For each `mark-gated`/`integrate` decision, confirm the ledger's
   `dispatched` reviewer is a registered identity DISTINCT from the unit's author (ideally a
   different model) and matches the fragment's recorded reviewer - the run dispatched a separate
   reviewer, not the orchestrator.
4. **Ledger read.** Every decision's `conformance_after` is green (the fail-closed rule held), the
   `verdict` matches the final state, and no decision drove past a red check.
5. **Record the verdict.** Write `VERDICT: clean` or the findings to
   `docs/evidence/autodrive/<run-id>/review.md`. A run with findings goes back like a unit with a
   violations review. At L3, the human's COUNTERSIGN of `BOT_ATTESTATION.md` - and the milestone tag
   - is contingent on this review being clean; never countersign a run you have not cleared here.

You never countersign on the human's behalf and never tag a milestone; you produce the independent
verdict the human (or the charter's recorded rule) acts on.
