---
description: End a port session - persist all state, write handoff, commit
---

Close out the current porting session. Run this when the handoff's task is done,
when the task ballooned and must split, when the conversation has grown long, or
when the human steps away - ending early is never wrong, and an interrupted task
ends too (record its in-flight state; the next session resumes it). Nothing may
be left only in conversation memory:

Before persisting anything, re-check the repo for movement since session start
(HEAD and every state file you read): concurrent commits may have changed them
mid-session, and a whole-file rewrite from a stale read silently discards their
changes - no merge conflict fires. Reconcile what moved, then write; after
committing, verify the commit's parent is the HEAD you reconciled against.

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
   session, prepare sign-off with /evidence-digest; the git tag is created ONLY
   after the human's SIGNOFF.md exists in the evidence pack, never before.
7. Report to the user: what was completed, what gate evidence was produced (paths in
   `docs/evidence/`), and what the next session will do.

Arguments (optional): $ARGUMENTS
