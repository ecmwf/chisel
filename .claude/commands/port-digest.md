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

Produce `docs/evidence/<date>-digest-<scope>/report.md` plus a prefilled
SIGNOFF.md (from the code-port skill assets) with the verdict section left empty
for the human.
