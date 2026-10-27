---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Independent fidelity review of the units awaiting review - send back, defer, or mark proven
---

Review ported units for fidelity, independently. A unit is never reviewed by a session that wrote
it: the review runs in a separate session (required), on a different model from the author's where
possible (recommended). This command is the one home of the review procedure; the `port-review`
agent follows it.

Units to review (empty: the whole queue): $ARGUMENTS

## Who does what

- **The session running this command** (normally Ptah-Orchestrator) finds the queue, starts one
  background `port-review` subagent per review unit, and as each result arrives gathers it, applies
  its disposition, and records and commits it. It does not review: a unit it authored goes to a
  subagent like any other. The one exception is a fresh session that authored nothing in the queue,
  which may review a single unit itself and record it too.
- **A `port-review` subagent** reviews one unit, writes only its report, and returns its verdict,
  report path and findings. It never writes TRACE, fragments or the handoff, and never commits. It
  cannot see its own session id and never looks for it: running `opencode session ...` to find it
  can stall the session.
- Give each reviewer only objective inputs: its unit's SOURCE and TARGET files, the charter,
  `port/conventions/<source>-to-<target>.md`, and the unit's TRACE entry or fragment. Never the
  author's account of why the code is right.

## Find the queue

- A unit awaits review when its TRACE entry has a `proof` and a `status` other than `proven`:
  `review: null` owes a first review, a `review` whose verdict is violations owes a re-review. The
  handoffs' "Awaiting independent review" lines point at the same set. Only `status: proven` takes a
  unit off the queue.
- Group tightly coupled entries (a module and the helpers only it uses, per its plan card) into one
  review unit with one report; independent deliverables stay separate.
- If `$ARGUMENTS` names units, keep only those. State the set in one line ("3 units to review: ...")
  and go on; if it is empty, say so.

## Dispatch and gather

- Start one `port-review` subagent per unit in the background, the queue in one message, and handle
  each result as it arrives; never wait for the slowest. A re-review resumes the reviewer's own
  session, and every dispatch is marked in the thread ledger (`/port-autodrive` step 6, "Sessions").
- Take each reviewer's session id from its subagent result, never from the reviewer. If it is one of
  the unit's `author_sessions`, discard that review and dispatch a fresh reviewer.
- When all have returned, apply the dispositions and write the records yourself, serially, and add
  each "Source findings" item to `port/SOURCE-FINDINGS.md`.

## Review one unit

1. Load charter sections 4 (named exceptions), 5 (mechanical transformations) and 6
   (placeholders), `port/conventions/<source>-to-<target>.md` with its trap table, and the unit's
   TRACE entry or fragment and plan card.
2. Walk TARGET against SOURCE, line by line, and classify every deviation: *mechanical* (a section 5
   transformation), *exception* (a section 4 exception or a registered placeholder), or *violation*:
   anything else, "harmless improvements" included (B1). If you catch yourself arguing that one is
   harmless, that is the finding.
3. Check the trap table at every site it applies to.
4. Check the constants: every TARGET constant has its SOURCE constant's value.
   `tools/conformance/verify-anchors.sh` compares them, each bound by name or by an anchor: its RED
   is a finding, its NOTEs are notes. Comments, anchors and their placement are notes, never
   findings.
5. Check vacuity: does the proof run exercise this unit? For each rendering choice the unit's tests
   claim to tell apart (B23), change the production code to the rejected alternative in a throwaway
   copy, rebuild, and confirm a committed assertion fails; then make sure the tree is clean again.
   Never judge this from the test text or the author's log. Reject an assertion bound to a test-local
   stand-in (local temporaries, a check on a test-declared entity, an expected value computed through
   the production helper, a partial copy of the outputs). The fixture must be able to see the choice:
   on the boundary for a comparator, distinct extents for an index or a layout, an isolated term with
   a wide spread of magnitudes for a grouping. A site shown to be indistinguishable by construction,
   with its measured difference, is a note; a site never tried is a finding.
6. Run the proof-evidence audit (below) and write the report.

A Phase-1 tool is reviewed as a tool instead: it detects what it claims (its seeded red-then-green
record and its run on the real SOURCE), it fails closed and is not vacuous, and its `tools/README.md`
row is accurate.

**Proof-evidence audit**, cited item by item in the report: the proof tier is R1 or higher, never
R0; it ran against the unit's current target state, not a stale build; it passed and its evidence is
under `docs/evidence/`; for a compiled TARGET, the runtime checks its `langs/` file requires ran on
the unit's tests at the same commit with no report (for C, every sanitizer build); the proof has a current red-then-green seeded-bug record (`/port-seed`); and
it exercised the unit (step 5). If an item fails, the unit cannot be marked proven.

## The report

- Path: `docs/evidence/<date>-review-<unit>/report.md` (for a Phase-1 tool,
  `docs/evidence/phase1/<id>/review.md`), in the unit's worktree (`WORKBENCH_ROOT`, on `work/<id>`),
  committed there on its own, the report alone. The review runs in the background while
  Ptah-Orchestrator writes `main`, so it never writes the main worktree; Ptah-Orchestrator gathers
  the report.
- Its header states that the reviewer is a clean context that did not author the unit and was given
  only objective inputs.
- One verdict line, plain text: `verdict: clean` or `verdict: violations`. The tools read it
  literally (`**clean**` does not count), and any other line where "verdict" is followed by
  "violation" or "not clean" reads as violations, so use the word "verdict" on that line only.
- Any finding makes the verdict `violations`. Each finding cites SOURCE and TARGET file:line and
  gives a remediation: where the problem is now, the file to change, the options with their
  consequences, and a recommendation. A governance finding (faithful but not authorized) names the
  charter section, placeholder or lesson to reconcile.
- **A small finding comes with its fix.** When you can state the exact fix, and it is small - at
  most 10 changed lines in at most 3 places of the unit's own TARGET files (its `target` list; for a
  Phase-1 tool, its tool files), never its tests, proof, build or conventions - write it as
  `fix.patch` beside the report and add the line `patch: fix.patch`. Make it in a throwaway worktree
  of the reviewed commit (`git -C "$PRODUCT_ROOT" worktree add --detach <tmp> <commit>`, edit there,
  `git -C <tmp> diff > fix.patch`, then remove the worktree); never edit the unit's own worktree.
  The verdict stays `violations`, and each finding the patch fixes says so. Several small findings
  may share one patch within the limits; a larger fix, or one you cannot state exactly, is an
  ordinary finding.
- A preference about wording or layout that neither the charter nor the conventions make binding is
  a note: never a violation, and never a reason for a new check (B27). So are comments, anchors and
  their placement: a missing, misplaced or wrong comment or anchor never makes the verdict
  `violations` and never sends a unit back. Binding rules still block: a wrong constant value (the
  verifier's RED, or one you find), an accurate rendering of the SOURCE (B2), no process talk in the
  product, and every conformance check.
- A probable bug in the SOURCE that the port reproduces faithfully is not a violation. List it under
  "Source findings" (`[low|medium|high|severe]`, `source path:line`, plain words). Only a deviation
  the human ratified belongs in `port/KNOWN-DIVERGENCES.md`.
- Bind the report to the product commit whose bytes you reviewed, never the workbench HEAD. The
  verdict holds until the unit's own target files change; a rebase that leaves them byte-identical
  keeps it (`tools/coordination/review_revalidate.sh <id>` decides). Cite only facts that stay true as
  other units land: TARGET file:line at that commit, unit-scope counts, SOURCE file:line; never
  whole-product totals (B28).
- Propose lessons, if any.

## Disposition

- **Violations with a review patch: apply it.** Resume the unit's Kha-Worker with the patch: it
  applies it verbatim (`git apply`), commits it alone and re-runs `/port-prove`. Then check it:
  `python3 tools/coordination/review_patch.py --repo <the unit's product worktree> --reviewed <the
  reviewed commit> --applied <its new proof.commit> --patch <the patch> --allow <the unit's target
  files>` (for a Phase-1 tool: its workbench worktree and its tool files). GREEN: resume the same
  reviewer with that output; it confirms the patch fixes its findings and writes `verdict: clean` in
  a new report naming the patch and the commit it was applied in. No full re-review is needed: every
  changed line was written by the reviewer and checked by the worker and the proof. Refused, or the
  proof red: send back, as below. A Phase-1 tool's `reviewed_commit` then names the applied commit.
- **Violations that need a code change: send back.** No question to the human; this is the rework
  loop. The worker fixes the findings in its own claim and session, re-runs `/port-prove`, and the
  unit gets a fresh independent re-review. If it keeps failing (autodrive's `max_rework`, or a few
  rounds by hand), a human looks.
- **A governance-only finding: defer.** The code is faithful and unchanged, but a departure is not
  authorized (B8, B10). Ask the human once to ratify it. When they record the row in
  `port/KNOWN-DIVERGENCES.md`, resume the same reviewer to confirm the row covers the finding and to
  write `verdict: clean` in a new report citing it; no fresh review is needed, since no code changed.
  A fix that needs another decision of theirs (a charter exception, an unset acceptance standard, a
  surface outside the unit's claim) is deferred the same way, with the literal-fidelity choice
  recommended.
- **Clean: mark proven**, once the audit passes. The human decides, in one question for the clean
  units waiting at that moment; under
  the charter's `auto-prove: clean-only` policy (AGENTS.md) it is recorded without asking. A question
  not yet answered holds back only the units it concerns.

Marking proven is how a unit becomes `proven`; nothing else records it. It is audited and can be
rolled back: the proof, the review and the reviewer's session stay in the record.

## Record and commit

- **TRACE only** (no `port/status/`): in the unit's TRACE entry, `review:` is the report path (a
  plain path) and `reviewer_session` a separate field. Marked proven: `status: proven`, with the R1+
  proof cited in `proof`.
- **Fragments** (`port/status/` exists): never edit the generated `port/TRACE.yaml`. If the workbench
  mainline does not yet carry the unit's fragment and review report exactly as `work/<id>` has them,
  gather them first (`git checkout work/<id> -- port/status/<id>.yaml docs/evidence/<date>-review-<unit>`,
  committed on their own; teardown looks for that commit) and stamp the author (`tools/coordination/stamp_author_id.py <id>`). Then set
  `review.evidence`, `reviewer_id` and `reviewer_session`. Marked proven: `status: proven`,
  `proof.tier`, `proof.commit`, `proof.evidence`, and `review.targets` set to a copy of `target`
  (what `review_revalidate.sh` compares against). Run `tools/coordination/generate_trace.py`.
- **A Phase-1 tool**: commit the report and the unit's `evidence.review`, `reviewer_id`,
  `reviewed_commit` (the `work/<id>` commit reviewed) and, marked proven, `accepted: true` on
  `work/<id>`, in its worktree, once its worker has handed off. `integrate_land.sh` judges the landed
  branch, so the records travel with it, and it refuses any other change made after
  `reviewed_commit`: a fix after the review needs a new review.
- Set each unit's "Awaiting independent review" line in the handoff to its outcome; re-read the
  handoff just before, and touch only those lines.
- Commit once, `docs(review): record review of <units>`, staging exactly the reports, the TRACE or
  fragments, and the handoff (with the commit checks of `/port-sprint-end` step 6), then push
  `main`. A unit marked proven is ready for `/port-land`.

Never run `/port-sprint-end` from a review: it would rewrite the author's handoff and NEXT TASK.
