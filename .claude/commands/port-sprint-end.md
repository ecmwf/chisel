---
description: End a port sprint - persist all state, write handoff, commit
---

Close out the current porting sprint. Run this when the handoff's task is done,
when the task ballooned and must split, when the conversation has grown long, or
when the human steps away - ending early is never wrong, and an interrupted task
ends too (record its in-flight state; the next sprint resumes it). Nothing may
be left only in conversation memory:

Before persisting anything, re-check the repo for movement since sprint start
(HEAD and every state file you read): concurrent commits may have changed them
mid-sprint, and a whole-file rewrite from a stale read silently discards their
changes - no merge conflict fires. Reconcile what moved, then write; after
committing, verify the commit's parent is the HEAD you reconciled against.

1. Update `port/plan/` checkboxes and any module cards touched this sprint.
2. Update `port/TRACE.yaml` statuses for every file whose state changed
   (unmapped → in-progress → gated), including gate evidence paths and tags.
3. Append any uncaptured lessons to `port/LESSONS.md` (if a bug was found, a gate
   failed, an assumption broke, or an approach was abandoned, an entry is MANDATORY).
   Mechanization sweep: did this sprint create or reveal an enforceable invariant
   (new idiom, contract, structural property)? If yes, add one line to the
   MECHANIZATION CANDIDATES block citing what it would guard. Record only; building
   happens at the retrospective triage, never now.
4. If a divergence was accepted this sprint (human signed off), record it in
   `port/KNOWN-DIVERGENCES.md`.
5. Rewrite `port/handoffs/<workstream>.md` from its template: current state, last
   passing gate, the exact single NEXT TASK, in-flight anomalies, do-not-touch, notes
   for the human. Rebuild the handoff's "Awaiting independent review" field FROM TRACE so
   it is never stale: list exactly the modules with `gate` set, `review: null`, and status
   not yet `gated` (each with its TRACE entry and gate evidence path); if none, write
   "none". This is the review baton: a fresh session or a background sub-agent must be
   able to find what to review from files alone, never from this conversation. Because it
   is derived from TRACE, a module reviewed since the last handoff drops off automatically.
6. Commit the state files together with the code. Before each commit, verify no
   merge is pending (a plain commit silently concludes one and sweeps its content
   in under your message) and that the staged set contains exactly the files you
   mean to commit; immediately after, verify the commit's parent hash is the HEAD
   you reconciled against. If a milestone gate passed this sprint, prepare
   sign-off with /port-digest; the git tag is created ONLY after the human's
   SIGNOFF.md exists in the evidence pack, never before.
7. Report to the user: what was completed, what gate evidence was produced (paths in
   `docs/evidence/`), and what the next sprint will do. If a module is awaiting
   independent review, recommend running `/port-review` (a fresh session or a background
   sub-agent task); do not self-run it - the independence layer is never self-driven.

Arguments (optional): $ARGUMENTS
