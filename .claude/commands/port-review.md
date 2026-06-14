---
description: Independent fidelity review of a ported module (required before gated)
---

Perform an independent, read-only fidelity review of a ported module. This is
independence insurance against translator failure modes (B1/B2/B3): it MUST run in a
session that did not produce the translation under review. If this session wrote any
of it, stop and report that a fresh sprint is required.

Module to review (SOURCE file, TARGET file, or TRACE entry): $ARGUMENTS

**If no module is named, self-orient from state - never ask blindly.** A fresh review
session knows nothing from conversation, so discover the target from files:
- Read the workstream handoff `port/handoffs/<workstream>.md` for its
  "Awaiting independent review" pointer.
- Query `port/TRACE.yaml` for the review queue: entries with `gate` set, `review: null`,
  and `status` not yet `gated` (they passed their gate but lack an independent review),
  excluding any whose `author_sessions` includes THIS session.
- One candidate: propose it and proceed on confirmation. Several: list them and ask which.
  None: say so plainly (and if `files:` is empty, that no port is in progress here).

**Running it independently (two equivalent ways).** Independence is satisfied by any
session whose reasoning did not produce the translation:
- a fresh chat session, where you run this command and it self-orients as above; or
- a background sub-agent task: spawn the **`port-review`** subagent via the task/subagent
  mechanism (this is the same review running in a separate, model-pinned agent, NOT a
  re-run of this command). It is defined per tool, since the model differs:
  `.opencode/agents/port-review.md` pins it to a review model such as `openai/gpt-5.5`;
  `.claude/agents/port-review.md` pins it to a Claude model. It starts with a clean
  context, so it carries none of the author's rationalizations - the point of the
  independence - and a reviewer on a DIFFERENT model than the author is a stronger control
  group still. Give it only objective inputs (the module/deliverable, charter,
  `target/CONVENTIONS.md`, the TRACE entry), never the author's "why it is fine" narrative.
  It records its session id as `reviewer_session`, asserts that id is not in
  `author_sessions`, and aborts if it is. The background task changes HOW the review runs,
  not WHO accepts it: still never a self-approval, and milestone sign-off remains the
  human's.

Ground rules:
- Read-only with three precise exceptions: writing the review report under
  `docs/evidence/`, recording review metadata (report path, reviewer session) in the
  module's TRACE entry, and clearing this module's "Awaiting independent review" line in
  the workstream handoff (step 6). No edits to `source/`, `target/`, or anything else.
  No fixes ever: findings go in the report; fixes belong to the owning workstream.
- Independence is checked, not assumed: compare your session against the
  `author_sessions` recorded in the TRACE entry and assert no overlap in the
  report header.
- Citation duty: every finding cites SOURCE file:line and TARGET file:line pairs. A
  finding without citations is not a finding.
- No vibes: "looks fine" is not a verdict. The checklist below is walked completely.

Procedure:
1. Load context: charter §5 (permitted mechanical transforms) and §4 (named
   exceptions), the placeholder table (§6), `target/CONVENTIONS.md` including the
   semantic trap table, and the module's TRACE entry and plan card.
2. Walk TARGET against SOURCE side by side, line by line. Classify EVERY deviation:
   - mechanical-OK: matches a charter §5 transform
   - exception-OK: matches a §4 named exception or a registered placeholder
   - VIOLATION: anything else, explicitly including "harmless improvements" (B1).
     If you catch yourself rationalizing one as harmless, that is the finding.
3. Check trap-table application at every applicable site (literal precision T1,
   implied SAVE T6, loop order and association T11/T12, intrinsic mappings T17, ...).
4. Check anchors: every nontrivial constant has a provenance anchor and its embedded
   literal matches both the cited SOURCE line and the TARGET rendering.
5. Check for vacuity: will the run that gates this module actually exercise it? If
   not, flag it - a passing gate would be vacuous.
6. Write the report to `docs/evidence/<date>-review-<module>/report.md`: verdict
   (clean | violations), the classified deviation list with citations, proposed
   LESSONS entries if any. Record the report path in the module's TRACE entry (the
   `review` field) - TRACE is the source of truth for review status. Then close the loop
   so the next sprint is not misled: in `port/handoffs/<workstream>.md`, update this
   module's "Awaiting independent review" line to the outcome (clean -> reviewed, ready
   to gate; violations -> reviewed, needs fixes), citing the report path. Re-read the
   handoff immediately before this edit and touch only that line (one-writer-per-worktree
   stale-write guard).

Verdict rules: any VIOLATION means not clean; the module cannot move to `gated`
until the owning workstream resolves it and a re-review passes. Never fix-and-pass
in the same review.
