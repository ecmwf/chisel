---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Phase-boundary evidence pre-digest ahead of human sign-off
---

Compile and cross-check the evidence pack for a phase or milestone so the human's
bandwidth goes to judgment, not collation. This PREPARES sign-off; it never grants
it.

Scope (phase / milestone): $ARGUMENTS

Cross-check, and report every discrepancy found:
1. Charter criteria vs proof evidence: every criterion in the relevant charter
   section has a proof run at the required configuration, with evidence paths.
   Classify each deliverable by WHAT IT ACTS ON: an item operating on THIS phase's own
   artifacts can be satisfied now; an item operating on a LATER phase's OUTPUT (e.g.
   tooling that checks code a later phase produces) cannot exist yet and must NOT read as
   an incomplete deliverable - flag it for relocation to that later phase's bring-up/entry check. A deliverable list bundled by THEME rather than by what-each-acts-on makes a
   milestone falsely un-closable; surface the boundary to the human (re-scope vs defer) as
   a named discrepancy rather than silently failing or silently passing it.
2. TRACE vs reality: statuses consistent with tags and evidence; no entry `proven`
   without both proof and review evidence; no R0 evidence in any proven entry's proof
   field; author/reviewer session fields show no overlap.
3. Seeded-bug records: every detector this phase relied on has a current
   red-then-green record matching its present logic version.
4. Placeholders: none open that affect this scope (charter placeholder table).
5. Lessons: phase retrospective drafted; standing rules pruned or mechanized where
   due; closed ledger entries staged for `port/lessons-archive/`.
6. Known divergences: everything a proof report relied on is registered and signed
   in KNOWN-DIVERGENCES.md.
7. Product README WRITTEN for a consumer (two-repo, at a PRODUCT milestone / handover - not
   Phase 0/1, where it is rightly still a stub): run `tools/conformance/check-product-readme.sh
   --require-filled`. The product's `README.md` must be real consumer docs - what it does, a link
   to the original, and exact build + run commands - with no unfilled `<...>` placeholders and no
   methodology vocabulary. The README is a reviewed product deliverable (an owner writes it as the
   product becomes usable; the integrator never hand-authors it - #111); a RED here means it was
   never written. If the milestone is not a product/handover one, state "README: stub OK at this
   phase" rather than flagging it.
8. Product is clone-build-RUN-able (two-repo, at a PRODUCT milestone / handover): the product is not
   "done" when the code compiles - a fresh clone must BUILD AND RUN from what is in it. Confirm the
   run assets a consumer needs are PRESENT in the product and PUSHED: the example inputs / sample data
   the README's `## Run` and `## Test` reference, runtime configs, and the self-test fixtures. These
   are NON-CODE assets (no SOURCE file, no fidelity review) and land via
   `tools/coordination/integrate_assets.sh <branch>` (conformance-checked; it refuses code/build files,
   which take the reviewed code-land). A milestone where the program builds but a fresh clone cannot
   run the documented example is NOT done - name the missing assets. If the milestone is not a
   product/handover one, state "run assets: N/A at this phase".

Then produce, in `docs/evidence/<date>-digest-<scope>/`:

A. **report.md** - the cross-check results above, every discrepancy named.

B. **A HUMAN VERIFICATION RUNBOOK inside report.md.** For each criterion, tell the
   human exactly how to see it for themselves:
   - Fully mechanical criterion (bit-identity, exact-match proof, a passing
     conformance script): state "exact proof, nothing to check by hand" and link
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
    in the Decision value), What-I-checked (from their reply, or "confirmed, mechanical proof"),
    Signed = their name from `git config user.name` (confirm it, never invent it), Date, and the commit being signed. Then
   AUTO-LAND (the charter default), so the human types no git: commit the signed state (the phase
   artifacts + this SIGNOFF.md), then run `tools/coordination/finalize.sh <milestone-tag> --signoff
   <path> [--sync <pending-sync-branch>]`. It re-checks the sign-off (a committed accept-SIGNOFF.md),
   tags the signed commit, ff-lands any pending methodology sync, pushes, and tears the sync worktree
   down. The human's RECORDED accept is the checkpoint, not their keystrokes: finalize.sh REFUSES without a
    committed accept-signoff, so never fabricate a decision or read a vague reply as acceptance. (In
   AUTO-MODE the milestone is sealed by `finalize.sh <tag> --auto` instead - no human to ask: it
   refuses unless autodrive is L2/L3 and the full conformance suite is green at HEAD. The acceptance
   authority is those checks, the per-piece independent reviews bound to each proven commit, plus the §7
   standard the human set ONCE in the charter; the digest is still produced as the evidence pack, but
   no per-milestone countersign is required.)
