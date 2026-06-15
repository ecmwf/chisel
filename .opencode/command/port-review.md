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
  - Spawning is via the task/subagent mechanism: the `.opencode/agents/port-review.md`
    agent, ideally on a model different from the author's (a different model strengthens
    the independence the disjoint session already enforces; e.g. `openai/gpt-5.5`). It is
    the same review in a separate agent, NOT a re-run of this command.

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
- **Team mode (generated canonical TRACE).** When `port/status/` fragments exist and
  `port/TRACE.yaml` is GENERATED from them (the shard-and-generate model in
  `references/team-coordination.md`), every "write the TRACE entry" instruction below instead
  means write the unit's status fragment `port/status/<trace-id>.yaml`
  (`assets/status-fragment.template.yaml`) and stage THAT - never the generated
  `port/TRACE.yaml` by hand (the drift check fails if canonical TRACE is hand-edited). Field
  mapping: report path -> `review.evidence`; reviewer session -> `reviewer_session` (plus
  `reviewer_id`); a `gate` disposition -> `status: gated` with `gate.tier` / `gate.commit` /
  `gate.evidence`. The integrator's generator regenerates canonical TRACE from the fragment,
  and the drift check guards it. Reads of TRACE (queue detection) are unchanged. A solo port
  with no fragments writes the TRACE entry directly, as described below.
- Independence is checked, not assumed: each reviewer compares its session against the
  `author_sessions` recorded in the TRACE entry and asserts no overlap in its report
  header; it aborts if it is an author session.
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
      (clean | violations) and the classified deviation list - each finding with its citations
      AND its remediation block (recorded-now / must-change file / options / recommendation) -
      plus proposed LESSONS entries if any. The reviewer always does this; distinct paths make
      it parallel-safe.
   b. Record the review metadata in the unit's TRACE entry: the report path as the scalar
      `review:` field (this is exactly what `check-trace-evidence.sh` parses), and the
      `reviewer_session` as a SIBLING field (never folded into `review:`). (Batch: the
      orchestrator does this serially for all units; single: the reviewer does its own. Team
      mode: write the unit's fragment, not generated TRACE - see the team-mode ground rule.)
   c. Decide and APPLY the disposition (per "Verdict, decision, and gating" below): present the
      menu and get the human's choice (or apply the charter's `auto-gate: clean-only` policy for
      a fully clean unit), then write it - for `gate`, set `status: gated` and cite the gate
      (R1+) and review evidence AFTER the gate-evidence audit passes; for `defer` / `send back`,
      leave `status: in-progress` and set the handoff "Awaiting independent review" line to the
      outcome (deferred-with-reason / needs-fixes). Re-read the handoff immediately before
      editing and touch only that line (one-writer-per-worktree guard). This happens BEFORE the
      commit (step 7), so the commit captures the disposition.
7. Commit the review evidence - the review commits ITSELF. An independent review runs in a
   separate session after the author's sprint already committed, so its output has no
   `/port-sprint-end` to ride on: left uncommitted, it is lost. Make ONE project-layer commit
   (`docs(review): record review of <unit(s)>`) staging exactly the review report(s),
   `port/TRACE.yaml` (the review metadata AND the applied disposition from step 6c - a `gated`
   status with its gate+review evidence, or the unchanged `in-progress`), and the touched
   handoff(s). The disposition is decided and applied in 6c BEFORE this commit, so the commit
   captures it in one atomic record - never a gated transition left uncommitted. The ORCHESTRATOR commits once for the whole
   batch - never the reviewer subagents (concurrent committers collide exactly as concurrent
   writers do). Re-read HEAD and the state files immediately before committing (a concurrent
   porting commit may have moved them), verify no merge is pending, stage only the review
   files, and verify the new commit's parent is the HEAD you reconciled against. Do NOT run
   `/port-sprint-end` from a review session: that is author-lane (it rewrites the porting
   handoff and NEXT TASK and drives status transitions the reviewer must not own); review
   commits only its own evidence.

## Verdict, decision, and gating

Verdict rules: any finding means **not clean**; the unit cannot move to `gated` until it is
resolved - the owning workstream for a numeric/translation finding, the human's charter
ratification for a governance finding - and a re-review passes. Never fix-and-pass in the same
review.

**The command drives the decision; the human never hand-edits `gated`.** Hand-writing TRACE
gating metadata is error-prone, so after the review the command PRESENTS the decision and then
APPLIES the human's choice itself:

1. Present the consolidated round: per unit, the verdict and (if any) the findings with their
   remediation blocks.
2. For each unit, offer a disposition menu and let the human pick (one batched interaction):
   - **gate** - flip `status: gated` (offered ONLY for a clean unit with present, non-vacuous
     R1+ gate evidence; the recommended choice for a clean unit);
   - **defer** - leave it in the queue with a recorded reason (e.g. "blocked on charter
     ratification F1"); status stays `in-progress`;
   - **send back** - return it to the owning workstream with the findings/remediation; status
     stays `in-progress`, handoff marked "needs fixes" (recommended when there are findings).
   For a unit with findings, **gate is NOT offered** until the findings are resolved.
3. APPLY the chosen disposition to TRACE/handoff (the command writes; the human decided),
   citing the gate (tier R1+, never R0) and review evidence for any unit gated.

**Gate-evidence audit (run before offering OR applying `gate`, default or auto-gate alike).**
Confirm and cite in the report ALL of:
- the gate **tier is R1-R5, never R0** (`validation-ladder.md`: R0 may never gate an entry);
- the gate ran against the unit's **CURRENT target state**, not a stale artifact (a gate that
  compared yesterday's build is a false pass);
- it **exited passing**, and its evidence pack exists under `docs/evidence/`;
- the gate has a **current red-then-green seeded-bug record** (`/port-seed`);
- the run **actually exercised the unit** (the step-5 non-vacuity check - invocation/coverage,
  not a path that dodges the seam).
Any item missing or unprovable → `gate` is **not offered** (default) and **blocked** (auto-gate);
the unit goes to `defer` / `send back`. After a fix, the prior gate evidence is stale: re-run
`/port-gate` to produce fresh evidence before the unit is gate-eligible again.

**Opt-in `auto-gate: clean-only`** (recorded in the charter, default off, with who authorized it,
the date, its scope, and how to revoke) removes the
prompt for the easy case only: a **fully clean** review whose unit has **present, non-vacuous R1+
gate evidence** is gated automatically (step 2 skipped for it), so a long autonomous run is not
blocked on a human for every clean unit. It relocates the human's checkpoint, it does not remove
it: units with ANY finding still go through the decision menu, and milestone acceptance + tags
remain the human's `SIGNOFF.md`.

Gating guardrails (a violation of any is a bug in the gate, not a shortcut):
- **Clean-only.** ANY finding - numeric OR governance (faithful-but-unratified) - blocks the gate
  and routes the unit to the decision menu with its remediation blocks.
- **The gate is the numeric net.** Gating requires present, non-vacuous R1+ gate evidence (it
  actually exercised the unit - step 5). A missing, R0-only, or vacuous gate blocks gating,
  however clean the read.
- **Independence unchanged.** The reviewer is a session disjoint from `author_sessions`, ideally a
  different model; gating is the independent reviewer recording results, never an author blessing
  its own work.
- **Audited and revocable.** Every gate leaves the gate+review evidence and `reviewer_session` in
  TRACE; any gated unit can be audited and rolled back.
- **Off by default.** Absent the charter policy line, clean units still go through the decision
  menu (the command writes the chosen disposition; the human always decides).
