---
description: Independent fidelity review of the pending unit(s) - autonomic queue detection, batch-parallel by default (required before gated)
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
- Query `port/TRACE.yaml` for the review queue: entries with a `gate` set and `status` not
  yet `gated` (they passed their gate but are not gated, so they still owe a clean review -
  `review: null` = never reviewed, or `review` set to a violations verdict = reviewed, not
  clean).
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
  SOURCE/TARGET files, charter, `target/CONVENTIONS.md`, the TRACE entry), never the
  author's "why it is fine" narrative.
  - Each reviewer writes ONLY its own report to
    `docs/evidence/<date>-review-<unit>/report.md` (distinct paths, so parallel writes
    never collide) and RETURNS its result to the orchestrator: verdict (clean | violations),
    report path, `reviewer_session`, and the classified findings.
  - Reviewers do NOT each write `port/TRACE.yaml` or the handoff - concurrent writes to one
    file clobber each other (one writer per worktree). After ALL reviewers return, the
    orchestrator applies every TRACE `review`-field update and every handoff "Awaiting
    independent review" line SERIALLY, in one pass, transcribing each unit's returned
    `reviewer_session` and report path.
  - The orchestrator then presents ONE consolidated round: a table
    {unit -> verdict -> report path}, clean units ready to gate, violations units flagged
    with their findings. The human accepts or queries ONCE, not per unit.
  - Spawning is via the task/subagent mechanism, defined per tool since the model differs:
    `.opencode/agents/port-review.md` (e.g. `openai/gpt-5.5`) and
    `.claude/agents/port-review.md` (a Claude model). It is the same review in a separate
    agent, NOT a re-run of this command.

- **Single fresh session.** For one unit, a fresh chat session runs this command,
  self-orients as above, and does the whole procedure itself including its own TRACE +
  handoff write (one writer, no contention).

The batch shape changes HOW and in HOW MANY ROUNDS the review runs, never WHO accepts it:
still no self-approval, each unit still gets its own independent reviewer, its own report,
and its own verdict - the human's decision point is batched, the reviews are never blurred
together. Milestone sign-off remains the human's.

Ground rules:
- Read-only with precise write exceptions: the review report under `docs/evidence/`, the
  review metadata (report path, reviewer session) in the unit's TRACE entry, and the unit's
  "Awaiting independent review" line in the handoff. In batch mode the TRACE and handoff
  writes are the orchestrator's, applied serially after the parallel reviews and committed
  once (step 7); a reviewer subagent writes only its report and never commits. No edits to
  `source/`, `target/`, or anything else. No fixes ever: findings go in the report; fixes
  belong to the owning workstream.
- Independence is checked, not assumed: each reviewer compares its session against the
  `author_sessions` recorded in the TRACE entry and asserts no overlap in its report
  header; it aborts if it is an author session.
- Citation duty: every finding cites SOURCE file:line and TARGET file:line pairs. A finding
  without citations is not a finding.
- No vibes: "looks fine" is not a verdict. The checklist below is walked completely, per
  unit.

Procedure (per unit):
1. Load context: charter §5 (permitted mechanical transforms) and §4 (named exceptions),
   the placeholder table (§6), `target/CONVENTIONS.md` including the semantic trap table,
   and the unit's TRACE entry and plan card.
2. Walk TARGET against SOURCE side by side, line by line. Classify EVERY deviation:
   - mechanical-OK: matches a charter §5 transform
   - exception-OK: matches a §4 named exception or a registered placeholder
   - VIOLATION: anything else, explicitly including "harmless improvements" (B1).
     If you catch yourself rationalizing one as harmless, that is the finding.
3. Check trap-table application at every applicable site (literal precision T1, implied
   SAVE T6, loop order and association T11/T12, intrinsic mappings T17, ...).
4. Check anchors: every nontrivial constant has a provenance anchor and its embedded
   literal matches both the cited SOURCE line and the TARGET rendering.
5. Check for vacuity: will the run that gates this unit actually exercise it? If not, flag
   it - a passing gate would be vacuous.
6. Record the outcome:
   a. Write the report to `docs/evidence/<date>-review-<unit>/report.md`: verdict
      (clean | violations), the classified deviation list with citations, proposed LESSONS
      entries if any. The reviewer always does this; distinct paths make it parallel-safe.
   b. Record the report path and `reviewer_session` in each covered entry's TRACE `review`
      field, and update that unit's "Awaiting independent review" line in
      `port/handoffs/<workstream>.md` to the outcome (clean -> reviewed, ready to gate;
      violations -> reviewed, needs fixes), citing the report path. Re-read the handoff
      immediately before this edit and touch only that line (one-writer-per-worktree
      stale-write guard). In BATCH mode the orchestrator does 6b for all units serially
      after the parallel reviews; in single mode the reviewer does its own.
7. Commit the review evidence - the review commits ITSELF. An independent review runs in a
   separate session after the author's sprint already committed, so its output has no
   `/port-sprint-end` to ride on: left uncommitted, it is lost. Make ONE project-layer commit
   (`docs(review): record review of <unit(s)>`) staging exactly the review report(s),
   `port/TRACE.yaml`, and the touched handoff(s). The ORCHESTRATOR commits once for the whole
   batch - never the reviewer subagents (concurrent committers collide exactly as concurrent
   writers do). Re-read HEAD and the state files immediately before committing (a concurrent
   porting commit may have moved them), verify no merge is pending, stage only the review
   files, and verify the new commit's parent is the HEAD you reconciled against. Do NOT run
   `/port-sprint-end` from a review session: that is author-lane (it rewrites the porting
   handoff and NEXT TASK and drives status transitions the reviewer must not own); review
   commits only its own evidence.

Verdict rules: any VIOLATION means not clean; the unit cannot move to `gated` until the
owning workstream resolves it and a re-review passes. Never fix-and-pass in the same review.
