---
description: End a port session - persist all state, write handoff, commit
---

Close out the current porting session. Nothing may be left only in conversation memory:

1. Update `port/plan/` checkboxes and any module cards touched this session.
2. Update `port/TRACE.yaml` statuses for every file whose state changed
   (unmapped → in-progress → gated), including gate evidence paths and tags.
3. Append any uncaptured lessons to `port/LESSONS.md` (if a bug was found, a gate
   failed, an assumption broke, or an approach was abandoned, an entry is MANDATORY).
   Mechanization sweep: did this session create or reveal an enforceable invariant
   (new idiom, contract, structural property)? If yes, add one line to the
   MECHANIZATION CANDIDATES block citing what it would guard. Record only; building
   happens at the retrospective triage, never now.
4. If a divergence was accepted this session (human signed off), record it in
   `port/KNOWN-DIVERGENCES.md`.
5. Rewrite `port/handoffs/<workstream>.md` from its template: current state, last
   passing gate, the exact single NEXT TASK, in-flight anomalies, do-not-touch, notes
   for the human.
6. Commit the state files together with the code. If a milestone gate passed this
   session, create the git tag named in the plan.
7. Report to the user: what was completed, what gate evidence was produced (paths in
   `docs/evidence/`), and what the next session will do.

Arguments (optional): $ARGUMENTS
