---
description: Land a PROVEN piece - finalize its gated status and integrate it to the product, in one step
---

Gate AND integrate ONE piece that is already proven, in a single step - the hand-driven analogue of the
planner's `mark-gated` -> `integrate`, so a reviewed, gate-green piece reaches the product mainline
WITHOUT a separate sprint. Under `/port-autodrive` the planner drives this exact sequence
automatically; this is the same act for the hand-driven / pilot operator. Argument: the piece's
trace-id (`$ARGUMENTS`).

Run it the moment a piece is PROVEN. It is fail-closed: it verifies the three preconditions, and any
missing one STOPS with that specific blocker named - it never gates on R0, a vacuous gate, an
unfinished review, or an unratified divergence.

1. **Verify the piece is landable** (the gate-evidence audit + the independence + the governance gate):
   - **Gate**: an R1+ gate (tier R1-R5, NEVER R0 - validation-ladder R0 may never gate) whose evidence
     is present under `docs/evidence/`, ran against the unit's CURRENT target state, exited passing, has
     a current red-then-green seeded-bug record, and actually exercised the unit (non-vacuous).
   - **Independent review**: a review report recorded CLEAN (`verdict: clean`), by a DISTINCT reviewer
     (`reviewer_id != author_id`, `reviewer_session` not in `author_sessions`) on a different model. If
     the review is missing or not clean -> STOP and recommend `/port-review` (a fresh session or a
     background sub-agent); the independence layer is NEVER self-driven, so do not review-and-land in one
     session.
   - **Divergences ratified**: every divergence the gate relies on (the KNOWN-DIVERGENCES the comparator
     subtracts) is signed off in `port/KNOWN-DIVERGENCES.md` (the human's acceptance - a fidelity
     decision). If any is unratified -> STOP and surface it for the human's sign-off; do not land over an
     open governance finding (B8/B10). (Ratifying an already-clean, code-unchanged divergence does NOT
     owe a fresh review - #116; it just clears the finding.)
2. **mark-gated**: set `status: gated` in the piece's fragment (`port/status/<id>.yaml`), citing the gate
   (tier R1+) and the review evidence. Regenerate canonical `port/TRACE.yaml`
   (`tools/coordination/generate_trace.py`). Commit project-layer (`docs(trace): gate <id>`).
3. **integrate**: run `tools/coordination/integrate_product.sh <id>` (or `integrate_assembly.sh` for an
   assembly piece) - the sanctioned land that re-verifies planner-readiness + full two-root conformance
   at HEAD AND on the merge result, SQUASH-lands onto the product mainline, rolls back on red, and pushes
   from inside the script. Record the printed `product.main_commit` + `integration: integrated` in the
   fragment, regenerate TRACE, and tear down the worktree (`provision_worker.sh remove <id>`).
4. **Report**: `<id>` gated + integrated, the `product.main_commit`, the mainline pushed - and, if more
   pieces are now landable, name them (or, in a sprint, land them too before sprint end).

Arguments (the trace-id, required): $ARGUMENTS
