---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Independent fidelity review of the pending unit(s) - autonomic queue detection, batch-parallel by default (required before proven)
---

Perform an independent, read-only fidelity review of one or more ported units. This is
independence insurance against translator failure modes (B1/B2/B3): each review MUST run
in a session that did not produce the translation under review. If this session wrote a
unit, it cannot review that unit - spawn a fresh reviewer for it instead.

Units to review (optional - leave empty to review the whole pending queue): $ARGUMENTS

## Autonomic queue detection (what to review)

Never ask blindly and never make the human enumerate the work. Compute the pending-review
set yourself:
- Read each workstream handoff `port/handoffs/<workstream>.md` for its "Awaiting
  independent review" pointers.
- Query `port/TRACE.yaml` for the review queue: entries with a `proof` set and `status` not
  yet `proven` (they passed their proof but are not proven, so they still owe a clean review -
  `review: null` = never reviewed, or `review` set to a violations verdict = reviewed, not
  clean). A unit deferred for a governance-only finding (a faithful, unregistered departure)
  is "reviewed, not clean" too, but its resolution is the human's ratification of a
  `KNOWN-DIVERGENCES` row - after which the verdict is recorded clean and it is proven, NOT a fresh
  review of unchanged code (see "Verdict, decision, and marking proven").
- **Group queue entries into review UNITS.** The review unit is a coherent deliverable - a
  module and its tightly-coupled helpers reviewed together as ONE report (each covered
  entry's TRACE `review` field points at it), never a single file. Entries that are
  tightly coupled (a module and the helpers only it uses, per the plan card / TRACE
  grouping) collapse into one unit; independent deliverables stay separate units.
- If `$ARGUMENTS` names units, restrict to those; otherwise take the whole queue.
- Drop any unit whose `author_sessions` includes THIS session (this session cannot review
  its own work; a subagent on a clean session reviews it instead).

Present the resulting SET once - "N units pending review: ..." - and proceed on a single
confirmation. Do NOT ask unit-by-unit. If the queue is empty, say so plainly (and if
`files:` is empty, that no port is in progress here).

## How to run it (one consolidated round, never N)

Independence is satisfied by any session whose reasoning did not produce the translation.
Two shapes, same guarantee:

- **Batch / parallel (the default for more than one unit).** The session running this
  command is the ORCHESTRATOR. It spawns one **`port-review`** subagent per unit, IN
  PARALLEL (background tasks), each with a clean context and - ideally - a model different
  from the author's. Parallelism does not weaken independence; it strengthens it (no
  cross-unit contamination). Give each subagent only objective inputs (its unit's
  SOURCE/TARGET files, charter, `port/conventions/<source>-to-<target>.md`, the TRACE entry), never the
  author's "why it is fine" narrative.
  - Each reviewer writes ONLY its own report to
    `docs/evidence/<date>-review-<unit>/report.md` (distinct paths, so parallel writes
    never collide) and RETURNS its result to the orchestrator: verdict (clean | violations),
    report path, and the classified findings. It does NOT return (or try to find) its own
    session id: a dispatched subagent CANNOT see its own `ses_` id - it is surfaced only in the
    Task RESULT the orchestrator reads, NOT inside the subagent's environment - so it must never
    hunt for it and never run `opencode session ...` or any opencode CLI to discover it (that
    cannot identify the running session and can STALL it). The orchestrator captures the
    reviewer's `ses_` from that Task result, exactly as it does the worker's.
  - Reviewers do NOT each write `port/TRACE.yaml` or the handoff - concurrent writes to one
    file clobber each other (one writer per worktree). After ALL reviewers return, the
    orchestrator applies every TRACE `review`-field update and every handoff "Awaiting
    independent review" line SERIALLY, in one pass, recording each unit's report path and its
    `reviewer_session`/`reviewer_id` - the `ses_` id the ORCHESTRATOR captured from that
    reviewer's Task result (never a session id the reviewer reports about itself).
  - The orchestrator then reports ONE consolidated round: a table
    {unit -> verdict -> report path}, clean units ready to be marked proven, violations units flagged
    with their findings. Violation units are sent back to rework MECHANICALLY (the
    work->review->rework loop, no per-unit ask); the human interacts ONCE for the batch only to mark
    the clean units proven (unless `auto-prove: clean-only`) and for any genuine blocked/governance decision.
  - Spawning is via the task/subagent mechanism: the `.opencode/agents/port-review.md`
    agent, ideally on a model different from the author's (a different model strengthens
    the independence the disjoint session already enforces; e.g. a GPT model when the author ran
    on Claude). It is
    the same review in a separate agent, NOT a re-run of this command.

- **Single fresh session.** For one unit, a fresh chat session runs this command,
  self-orients as above, and does the whole procedure itself including its own TRACE +
  handoff write (one writer, no contention).

The batch shape changes HOW and in HOW MANY ROUNDS the review runs, never WHO accepts it:
still no self-approval, each unit still gets its own independent reviewer, its own report,
and its own verdict - the human's decision point is batched, the reviews are never blurred
together. Milestone acceptance is sealed by `finalize.sh` (hand-driven the human's `SIGNOFF.md`; in L2/L3 auto-mode `finalize.sh --auto` after full conformance green at HEAD).

Ground rules:
- Read-only with precise write exceptions: the review report under `docs/evidence/`, the
  review metadata (report path, reviewer session) in the unit's TRACE entry, and the unit's
  "Awaiting independent review" line in the handoff. In batch mode the TRACE and handoff
  writes are the orchestrator's, applied serially after the parallel reviews and committed
   once (step 7); a reviewer subagent writes only its report and never commits. No edits to
   `source/`, the product code, or anything else. No fixes ever: findings go in the report; fixes
   belong to the owning workstream.
- **A probable bug in the SOURCE is a finding, not a verdict-blocker.** If the line-by-line walk
  reveals a real defect in the ORIGINAL (not a translation error - an off-by-one, a missing guard, a
  wrong constant) that the port FAITHFULLY reproduces, that is NOT a violation: note it in your report
  under a "Source findings" heading (`[low|medium|high|severe]`, `source path:line`, plain terms). The
 orchestrator appends it to `port/SOURCE-FINDINGS.md` during its serial consolidation pass (the
   one-writer rule - a reviewer never writes the shared log). A faithful render of a buggy source is
   correct; only a deliberate, human-ratified deviation belongs in `KNOWN-DIVERGENCES`.
 - **A finding that bears on NEITHER the acceptance bar NOR a binding rule is a note, not a
   verdict-blocker.** The bar is FIDELITY - the charter's acceptance criteria (literal rendering;
   correct kinds, extents, and constants; the whole-run band). A reviewer's own PRESENTATIONAL
   preference about phrasing, layout, or word choice that the charter and the base do not make
   normative is at most an advisory note in the report - NEVER a `violations` verdict, never grounds
   to send a unit back, and never a reason to propose a new check for it (failure mode B27). This is
   NOT a licence to wave through binding conventions: provenance/anchor correctness and the constant
   rule, accurate representation of the SOURCE (B2), the no-process-meta-in-product rule, and any
   conformance check remain normative and still block. Scope your attention to whether the TARGET
   faithfully renders the SOURCE; treat only genuinely non-normative preferences as out of scope.
- **Team mode (generated canonical TRACE).** When `port/status/` fragments exist and
  `port/TRACE.yaml` is GENERATED from them (the shard-and-generate model in
  `references/team-coordination.md`), every "write the TRACE entry" instruction below instead
  means write the unit's status fragment `port/status/<trace-id>.yaml`
  (`assets/status-fragment.template.yaml`) and stage THAT - never the generated
  `port/TRACE.yaml` by hand (the drift check fails if canonical TRACE is hand-edited). Field
  mapping: report path -> `review.evidence`; reviewer session -> `reviewer_session` (plus
  `reviewer_id`); a `mark proven` disposition -> `status: proven` with `proof.tier` / `proof.commit` /
  `proof.evidence`. The integrator's generator regenerates canonical TRACE from the fragment,
  and the drift check guards it. Reads of TRACE (queue detection) are unchanged. A solo port
  with no fragments writes the TRACE entry directly, as described below.
- Independence is checked, not assumed - but a dispatched reviewer cannot see its own `ses_` id,
  so it does NOT compare ids. The reviewer asserts in its report header only what it CAN know: that
  it is a clean, independent context that did NOT author this unit and was given only objective
  inputs (SOURCE/TARGET/charter/conventions), never the author's reasoning. The mechanical
  `reviewer_session not in author_sessions` / `reviewer_id != author_id` check is the ORCHESTRATOR's:
  it dispatched both the author and the reviewer as SEPARATE Task sessions (distinct `ses_` by
  construction), captured each `ses_` from its Task result, and records them disjoint - and
  `check-status-fragments` enforces `reviewer_id != author_id` on the committed fragment. If the
  orchestrator ever finds the reviewer's `ses_` equals an author session, it re-dispatches a fresh
  reviewer; the reviewer never has to (and cannot) self-verify this.
- Citation duty: every finding cites SOURCE file:line and TARGET file:line pairs. A finding
  without citations is not a finding.
- Actionable findings: every finding carries a **remediation block** - *recorded-now* (the
  file:line where the issue lives today), *must-change* (the file the human edits to resolve
  it), *options* (the concrete choices, each with its consequence), and a *recommendation*. A
  finding that only diagnoses - without saying what to edit and what the options are - is half
  a finding. A governance/exception finding (the rendering is faithful but unratified) names
  the charter section / placeholder / LESSONS id to reconcile.
- No vibes: "looks fine" is not a verdict. The checklist below is walked completely, per
  unit.

Procedure (per unit):
1. Load context: charter §5 (permitted mechanical transforms) and §4 (named exceptions),
   the placeholder table (§6), `port/conventions/<source>-to-<target>.md` including the semantic trap table,
   and the unit's TRACE entry and plan card.
2. Walk TARGET against SOURCE side by side, line by line. Classify EVERY deviation:
   - mechanical-OK: matches a charter §5 transform
   - exception-OK: matches a §4 named exception or a registered placeholder
   - VIOLATION: anything else, explicitly including "harmless improvements" (B1).
     If you catch yourself rationalizing one as harmless, that is the finding.
3. Check trap-table application at every applicable site (literal precision T1, implied
   SAVE T6, loop order and association T11/T12, intrinsic mappings T17, ...).
4. Check anchors: every nontrivial constant has a provenance anchor whose literal-as-read is
   on the cited SOURCE line (whole, with its kind suffix) and is what the TARGET renders
   (`tools/conformance/verify-anchors.sh` compares the values).
5. Check for vacuity: will the run that proves this unit actually exercise it? If not, flag
   it - a passing proof would be vacuous.
   - **Test-level vacuity (failure mode B23 and its refinements).** For each rendering choice
     the unit's tests claim to discriminate, mutate the PRODUCTION entity to the exact rejected
     alternative - the expression, a parameter's type, a shared helper - in a throwaway copy
     (never committed; confirm the tree is clean afterwards), rebuild, and confirm a COMMITTED
     assertion reddens; never judge it by reading the test or the author's red log. Reject any
     assertion bound to a test-local stand-in (two local temporaries, a kind check on a
     test-declared entity, an expected value computed through the production helper, a shadow
     copy or partial set of the outputs, a precomputed boolean). Check the fixture can observe
     the choice: exactly on the boundary for a comparator, distinct extents for an index or
     layout, an isolated term with a wide magnitude spread for a grouping. A site documented as
     non-discriminable by construction, with its measured delta in each precision, is a note; a
     site never attempted is a finding.
6. Record the outcome:
   a. Write the report to `docs/evidence/<date>-review-<unit>/report.md`: the verdict as a
      canonical, machine-readable line - `verdict: clean` or `verdict: violations`, PLAIN text
      with NO markdown emphasis (a downstream planner/check matches the exact token, so `**clean**`
      does NOT match) - plus the classified deviation list, each finding with its citations
      AND its remediation block (recorded-now / must-change file / options / recommendation), and
       proposed LESSONS entries if any. Bind the report to the commit reviewed (record the PRODUCT
       commit whose target bytes you reviewed, never the workbench HEAD); a verdict is superseded
       only when the piece's OWN target-file bytes change, not merely because the commit SHA
       moved - a rebase that leaves the piece byte-identical keeps the review valid
       (`tools/coordination/review_revalidate.sh <id>` confirms this fail-closed). Cite only facts
       that stay true after the report is committed and unrelated units land - TARGET file:line
       read at that commit, unit-scope counts, SOURCE file:line - never a whole-product aggregate;
       a self-staling fact in the author's evidence is a request to remove it, not to refresh it
       (failure mode B28). The reviewer always does this; distinct paths make it parallel-safe.
   b. Record the review metadata in the unit's TRACE entry: the report path as the scalar
      `review:` field (this is exactly what `check-trace-evidence.sh` parses), and the
      `reviewer_session` as a SIBLING field (never folded into `review:`). (Batch: the
      orchestrator does this serially for all units; single: the reviewer does its own. Team
      mode: write the unit's fragment, not generated TRACE - see the team-mode ground rule.)
   c. Decide and APPLY the disposition (per "Verdict, decision, and marking proven" below): a unit with
      findings is `send back` MECHANICALLY (no human ask - it is the rework loop); the human is asked
      only to mark a CLEAN unit proven (or `auto-prove: clean-only` applies) or for a genuine blocked/governance
      decision. Then write it - for `mark proven`, set `status: proven`, cite the proof
       (R1+) and review evidence AFTER the proof-evidence audit passes, AND (fragment/team mode) set
       `review.targets` to a copy of the unit's `target` list - the immutable coverage snapshot
       `review_revalidate.sh` uses to reuse this review across a clean rebase (and to detect a later
       target-list change); for `defer` / `send back`,
      leave `status: in-progress` and set the handoff "Awaiting independent review" line to the
      outcome (deferred-with-reason / needs-fixes). Re-read the handoff immediately before
      editing and touch only that line (one-writer-per-worktree guard). This happens BEFORE the
      commit (step 7), so the commit captures the disposition.
7. Commit the review evidence - the review commits ITSELF. An independent review runs in a
   separate session after the author's sprint already committed, so its output has no
   `/port-sprint-end` to ride on: left uncommitted, it is lost. Make ONE project-layer commit
   (`docs(review): record review of <unit(s)>`) staging exactly the review report(s),
   `port/TRACE.yaml` (the review metadata AND the applied disposition from step 6c - a `proven`
   status with its proof+review evidence, or the unchanged `in-progress`), and the touched
   handoff(s). The disposition is decided and applied in 6c BEFORE this commit, so the commit
   captures it in one atomic record - never a proven transition left uncommitted. The ORCHESTRATOR commits once for the whole
   batch - never the reviewer subagents (concurrent committers collide exactly as concurrent
   writers do). Re-read HEAD and the state files immediately before committing (a concurrent
   porting commit may have moved them), verify no merge is pending, stage only the review
   files, and verify the new commit's parent is the HEAD you reconciled against. Do NOT run
   `/port-sprint-end` from a review session: that is author-lane (it rewrites the porting
   handoff and NEXT TASK and drives status transitions the reviewer must not own); review
   commits only its own evidence.

## Verdict, decision, and marking proven

Verdict rules: any finding means **not clean**; the unit cannot move to `proven` until the
finding is RESOLVED. A **numeric/translation** finding is resolved by the owning workstream
(a code change) AND a fresh independent re-review. A **governance-only** finding - the code is
faithful and UNCHANGED, an unregistered seam or behaviour-neutral departure (B8/B10) - is
resolved by the human's charter ratification of a `KNOWN-DIVERGENCES` row: the reviewer records
`verdict: violations` with the remediation "human ratifies departure X" and `defer`s to the
human (no send-back - there is nothing for a worker to fix). Registering the human-authorized
row CLEARS the finding; the code is unchanged and already carries this review's faithful
assessment, so the disposition then becomes a `clean` verdict citing the proof, the review, and
the ratified row, and the unit is proven - with NO fresh independent re-review (no code changed for
one to assess). Never fix-and-pass in the same review: a code fix always owes a fresh re-review,
but ratifying an unchanged, faithful departure is a governance decision, not a code fix.

**The command drives the decision; the human never hand-edits `proven`.** Hand-writing TRACE
proven-status metadata is error-prone, so the command APPLIES the disposition itself - `send back` is
mechanical for a unit with findings (the rework loop), and the human's choice is asked only to mark a
clean unit proven or for a genuine blocked/governance decision:

1. Present the consolidated round: per unit, the verdict and (if any) the findings with their
   remediation blocks.
2. Apply the disposition. A unit with findings can NEVER be proven, so its disposition is MECHANICAL and
   needs no human ask: **send back** to the worker, who fixes the findings IN ITS OWN CLAIM and
   requests a fresh independent re-review - the work->review->rework loop repeats AUTOMATICALLY until
   the re-review is clean (or a piece churns past a few cycles without converging, which a human
   looks at). Do NOT stop to ask "shall I send it back" - that is the loop, not a decision. The human
   is surfaced ONLY:
   - a finding whose fix needs a GENUINE decision - a charter named exception (e.g. keeping a compiler
     flag the SOURCE does not set), an UN-SET acceptance standard, or a surface OUTSIDE the unit's
     claim: RECOMMEND the literal-fidelity default (e.g. remove the non-SOURCE flag to match SOURCE per
     charter §1) and PROCEED unless the human overrides; **defer** only if truly blocked on the human;
   - **marking** a CLEAN unit **proven**: offered ONLY for a clean unit with present, non-vacuous R1+ proof
     evidence, confirmed by the human once for the batch - or recorded automatically under the
     charter's opt-in `auto-prove: clean-only`.
3. APPLY each disposition to TRACE/handoff (the command writes), citing the proof (tier R1+, never R0)
   and review evidence for any unit proven. A `send back` loops to rework (a code fix is proven only after a
   clean re-review); a governance-only finding instead `defer`s to the human, and on ratification of
   the divergence row the finding clears and the unit is proven with a clean verdict - no fresh re-review
   (no code changed).

**Proof-evidence audit (run before offering OR applying `mark proven`, default or auto-prove alike).**
Confirm and cite in the report ALL of:
- the proof **tier is R1-R5, never R0** (`validation-ladder.md`: R0 may never prove an entry);
- the proof ran against the unit's **CURRENT target state**, not a stale artifact (a proof that
  compared yesterday's build is a false pass);
- it **exited passing**, and its evidence pack exists under `docs/evidence/`;
- the proof has a **current red-then-green seeded-bug record** (`/port-seed`);
- the run **actually exercised the unit** (the step-5 non-vacuity check - invocation/coverage,
  not a path that dodges the seam).
Any item missing or unprovable → `mark proven` is **not offered** (default) and **blocked** (auto-prove);
the unit goes to `defer` / `send back`. After a fix, the prior proof evidence is stale: re-run
`/port-prove` to produce fresh evidence before the unit is eligible to be marked proven again.

**Opt-in `auto-prove: clean-only`** (recorded in the charter, default off, with who authorized it,
the date, its scope, and how to revoke) removes the
prompt for the easy case only: a **fully clean** review whose unit has **present, non-vacuous R1+
proof evidence** is proven automatically (step 2 skipped for it), so a long autonomous run is not
blocked on a human for every clean unit. It relocates the human's checkpoint, it does not remove
it: a unit with ANY finding is still sent back to rework (the work->review->rework loop, never proven),
and milestone acceptance + tags are sealed by `finalize.sh` (hand-driven, a human `SIGNOFF.md`;
in L2/L3 auto-mode, `finalize.sh --auto` after full conformance green at HEAD).

Marking-proven guardrails (a violation of any is a bug in the procedure, not a shortcut):
- **Clean-only.** ANY unresolved finding blocks marking it proven. A NUMERIC finding routes the unit to
  `send back` (rework) with its remediation blocks, and is marked proven only after a clean re-review. A
  GOVERNANCE-only finding (faithful-but-unregistered departure, no code change) `defer`s to the
  human for charter ratification of the `KNOWN-DIVERGENCES` row; once the row is ratified the
  finding is cleared and the unit is proven with a clean verdict - no rework and no fresh re-review.
- **The proof is the numeric net.** Marking proven requires present, non-vacuous R1+ proof evidence (it
  actually exercised the unit - step 5). A missing, R0-only, or vacuous proof blocks marking it proven,
  however clean the read.
- **Independence unchanged.** The reviewer is a session disjoint from `author_sessions`, ideally a
  different model; marking proven is the independent reviewer recording results, never an author blessing
  its own work.
- **Audited and revocable.** Every mark-proven leaves the proof+review evidence and `reviewer_session` in
  TRACE; any proven unit can be audited and rolled back.
- **Off by default.** Absent the charter policy line, clean units still go through the decision
  menu (the command writes the chosen disposition; the human always decides).
