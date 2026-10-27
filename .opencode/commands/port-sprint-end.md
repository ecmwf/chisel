---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: End a port sprint - save the state, write the handoff, commit and push, land proven pieces
---

End the sprint (AGENTS.md, "Sprint protocol", says when). An interrupted task ends here too, with
its in-flight state in the handoff. Nothing may stay only in the conversation.

Before writing, re-read HEAD and every state file you will rewrite. If one changed in a way you did
not make, stop and say so (AGENTS.md, "One writer per worktree"): rewriting it from your earlier read
would silently drop that change.

1. Update the `port/plan/` checkboxes and the module cards touched.
2. Update the status of every unit whose state changed (`unmapped` to `in-progress`), with its proof
   evidence. `proven` is recorded only by `/port-review`, never here. With fragments
   (`port/status/`), write the fragment and run `python3 tools/coordination/generate_trace.py`;
   never edit the generated TRACE.
3. Add every lesson not yet captured to `port/LESSONS.md` (`/port-lesson`): a bug found, a proof
   failed, an assumption broken or an approach abandoned each needs one. If the sprint created or
   exposed an invariant a check could enforce, add one line to MECHANIZATION CANDIDATES saying what
   it would guard; it is built at the retrospective, not now.
4. Record each divergence the human accepted this sprint in `port/KNOWN-DIVERGENCES.md`.
5. Rewrite `port/handoffs/<workstream>.md` from its template: current state, last passing proof, the
   single NEXT TASK, in-flight anomalies, do-not-touch, notes for the human. Rebuild "Awaiting
   independent review" from TRACE: every unit with a `proof` and a status other than `proven`, with
   its evidence path, marked as owing a first review (`review: null`) or a re-review. Write "none" if
   there are none. A fresh session must find the review queue in the files alone.
6. Commit the state with the code it describes. Before each commit, check that no merge is pending (a
   plain commit would conclude it) and that exactly the files you mean are staged; after it, check
   that its parent is the HEAD you read. Push `main` (AGENTS.md, "Git"). If a milestone proof passed,
   prepare the sign-off with `/port-digest`.
6b. Land every piece that is `proven` and not yet integrated: run `/port-land <id>` on each, without
    asking. A piece still waiting for the human (a mark-proven answer, a divergence to ratify) is named
    in the handoff; it never holds back the others.
7. Report what was done, the evidence produced (paths under `docs/evidence/`) and the next move. Do
   the next mechanical action yourself rather than hand it back; for a decision that is the human's,
   lead with one recommendation and why (AGENTS.md, "Sprint protocol"). Units awaiting review go to
   `/port-review`, never to the session that wrote them.

A dispatched Kha-Worker commits its work on `work/<id>` and reports to Ptah-Orchestrator; it skips
steps 5, 6 and 6b.

Arguments (optional, the workstream): $ARGUMENTS
