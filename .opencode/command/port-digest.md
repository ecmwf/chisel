---
description: Phase-boundary evidence pre-digest ahead of human sign-off
---

Compile and cross-check the evidence pack for a phase or milestone so the human's
bandwidth goes to judgment, not collation. This PREPARES sign-off; it never grants
it.

Scope (phase / milestone): $ARGUMENTS

Cross-check, and report every discrepancy found:
1. Charter criteria vs gate evidence: every criterion in the relevant charter
   section has a gate run at the required configuration, with evidence paths.
   Classify each deliverable by WHAT IT ACTS ON: an item operating on THIS phase's own
   artifacts can be satisfied now; an item operating on a LATER phase's OUTPUT (e.g.
   tooling that checks code a later phase produces) cannot exist yet and must NOT read as
   an incomplete deliverable - flag it for relocation to that later phase's bring-up/entry
   gate. A deliverable list bundled by THEME rather than by what-each-acts-on makes a
   milestone falsely un-closable; surface the boundary to the human (re-scope vs defer) as
   a named discrepancy rather than silently failing or silently passing it.
2. TRACE vs reality: statuses consistent with tags and evidence; no entry `gated`
   without both gate and review evidence; no R0 evidence in any gated entry's gate
   field; author/reviewer session fields show no overlap.
3. Seeded-bug records: every detector this phase relied on has a current
   red-then-green record matching its present logic version.
4. Placeholders: none open that affect this scope (charter placeholder table).
5. Lessons: phase retrospective drafted; standing rules pruned or mechanized where
   due; closed ledger entries staged for `port/lessons-archive/`.
6. Known divergences: everything a gate report relied on is registered and signed
   in KNOWN-DIVERGENCES.md.

Then produce, in `docs/evidence/<date>-digest-<scope>/`:

A. **report.md** - the cross-check results above, every discrepancy named.

B. **A HUMAN VERIFICATION RUNBOOK inside report.md.** For each criterion, tell the
   human exactly how to see it for themselves:
   - Fully mechanical criterion (bit-identity, exact-match gate, a passing
     conformance script): state "exact gate, nothing to check by hand" and link
     the evidence. Do not invent busywork.
   - Criterion needing human judgment (statistical equivalence, "is this residual
     physically meaningful", a visual comparison): give the EXACT steps - the
     command to run or the file to open, and crucially the GOOD-vs-BAD signature
     ("if the difference is confined to high-variability regions it is expected;
     a smooth basin-wide gradient is a bias - reject"). Show the human how to
     look; never tell them what to conclude.

C. **SIGNOFF.md** (from the code-port skill assets), filled by you DOWN TO AND
   INCLUDING the "Agent recommendation" block: your recommended verdict, the
   plain-terms reasoning, the honest risks, and which runbook steps the human should check.
   Then make the sign-off EASY (interactive only): present the recommendation and ASK the human ONE
   outcome-framed question. When you recommend a clean accept, ask "Accept in full? (`yes` / `accept
   with conditions: <...>` / `no: <reason>`)" so a bare `yes` maps unambiguously to accept-in-full;
   when your own recommendation is conditional, ask them to pick the outcome explicitly. On their
   EXPLICIT answer, TRANSCRIBE it into the "Human decision" block - Decision (a PLAIN accept token:
   `accept-in-full` / `accept-with-conditions` / `reject`, with NO markdown emphasis - `finalize.sh`
   matches the exact token, so `**accept-in-full**` is REFUSED; conditions go in the Notes line, never
   in the Decision value), What-I-checked (from their reply, or "confirmed, mechanical gate"),
   Signed = their name from `port/contributors.yaml`
   or `git config user.name` (confirm it, never invent it), Date, and the commit being signed. Then
   AUTO-LAND (the charter default), so the human types no git: commit the signed state (the phase
   artifacts + this SIGNOFF.md), then run `tools/coordination/finalize.sh <milestone-tag> --signoff
   <path> [--sync <pending-sync-branch>]`. It re-checks the gate (a committed accept-SIGNOFF.md),
   tags the signed commit, ff-lands any pending methodology sync, pushes, and tears the sync worktree
   down. The human's RECORDED accept is the gate, not their keystrokes: finalize.sh REFUSES without a
   committed accept-signoff, so never fabricate a decision or read a vague reply as acceptance. (Auto-
   mode runs with no human to ask, so DURING the run a bot writes BOT_ATTESTATION.md - its
   recommendation - and never a SIGNOFF.md DECISION. When the human RETURNS to countersign, do NOT ask
   whether to prepare the sign-off: SCAFFOLD the SIGNOFF.md from the template down to and including the
   recommendation (mirroring BOT_ATTESTATION.md), then present the SAME one outcome-framed question -
   "Accept in full? (`yes` / `accept with conditions: <...>` / `no: <reason>`)" - and on their explicit
   answer transcribe it and auto-land the tag. Scaffolding the form is preparation, not the decision;
   only the decision stays the human's, and finalize.sh still refuses without a committed
   accept-SIGNOFF.md.)
