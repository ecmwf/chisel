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
   (unmapped → in-progress → proven), including proof evidence paths and tags.
3. Append any uncaptured lessons to `port/LESSONS.md` (if a bug was found, a proof
   failed, an assumption broke, or an approach was abandoned, an entry is MANDATORY).
   Mechanization sweep: did this sprint create or reveal an enforceable invariant
   (new idiom, contract, structural property)? If yes, add one line to the
   MECHANIZATION CANDIDATES block citing what it would guard. Record only; building
   happens at the retrospective triage, never now.
4. If a divergence was accepted this sprint (human signed off), record it in
   `port/KNOWN-DIVERGENCES.md`.
5. Rewrite `port/handoffs/<workstream>.md` from its template: current state, last
   passing proof, the exact single NEXT TASK, in-flight anomalies, do-not-touch, notes
   for the human. Rebuild the handoff's "Awaiting independent review" field FROM TRACE so
   it is never stale: list exactly the modules with a `proof` set and status not yet `proven`
   (each with its TRACE entry and proof evidence path) - that is the set blocked on a clean
   review. For each, mark which kind it owes: a FIRST review (`review: null`) or a clean
   RE-review (`review` set to a violations verdict that was resolved, e.g. by a registered
   exception; status stays `in-progress` until a clean re-review confirms it). Do NOT drop
   a module just because `review` is non-null - only `status: proven` clears it from the
   queue. If none, write "none". This is the review baton: a fresh session or a background
   sub-agent must find what to review from files alone, never from this conversation.
6. Commit the state files together with the code. Before each commit, verify no
   merge is pending (a plain commit silently concludes one and sweeps its content
   in under your message) and that the staged set contains exactly the files you
   mean to commit; immediately after, verify the commit's parent hash is the HEAD
    you reconciled against. If a milestone proof passed this sprint, prepare
    sign-off with /port-digest; after the human's accept it AUTO-LANDS via
    `tools/coordination/finalize.sh` (tag + push + land any pending sync). The tag is
    created only by finalize.sh, which REFUSES without a committed accept-SIGNOFF.md, so
    the human's recorded decision still proofs it - and you hand the human no git commands.
6b. **Land EVERY proven piece automatically before you close - this is a mechanical close step, not a
    recommendation you surface and not a thing to ask about.** Enumerate from TRACE every piece now in
    the landable state - an R1+ proof green + seeded-bug-proven, an INDEPENDENT review recorded clean, and
    its divergences ratified in `port/KNOWN-DIVERGENCES.md` - and run `/port-land <id>` on EACH to proof
    AND integrate it, WITHOUT asking, so progress reaches the product mainline at sprint close. This is
    exactly what autodrive does when the planner drives `mark-proven` -> `integrate`; the ONLY difference
    here is that you are hand-driven, so you sweep the landable set yourself piece by piece instead of a
    planner emitting it. The land scripts are themselves fail-closed (each is conformance-checked and rolls
    back on red), so landing is safe to do automatically. (A piece this sprint AUTHORED is not yet
    independently reviewed, so it lands at the close of the sprint that REVIEWS it, or once the human signs
    off its divergences - never review-and-land in one session; the independence layer is never
    self-driven.) The ONLY thing that ever defers a landable piece is an UNRATIFIED divergence: that one
    human sign-off is the single genuine wait - name it and land the rest; never hold back the mechanical
    land of the others, and never invent a separate "integration sprint" for it.
7. Report to the user: what was completed, what proof evidence was produced (paths in
   `docs/evidence/`), and the next move. **Bias toward action, not a menu:** where the next
   action is MECHANICAL and within this session's authority (not a genuine human decision and
   not the independence boundary), just DO it / chain into it rather than hand it back as a
   recommendation - stopping to ask is the annoyance to avoid. When you do stop, LEAD with ONE
   recommended next action and WHY (the rationale that makes it the right next step), then any
   alternatives briefly - never a flat "how would you like to proceed?" menu without a
   recommendation. Reserve the stop for a GENUINE human decision (a divergence sign-off, a
   milestone accept) or the independence boundary: if a module is awaiting independent review,
   the action is `/port-review` (a fresh session or a background sub-agent task); do not self-run
   it - the independence layer is never self-driven.

Arguments (optional): $ARGUMENTS
