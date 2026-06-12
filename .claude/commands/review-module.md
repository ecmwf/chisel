---
description: Independent fidelity review of a ported module (required before gated)
---

Perform an independent, read-only fidelity review of a ported module. This is
independence insurance against translator failure modes (B1/B2/B3): it MUST run in a
session that did not produce the translation under review. If this session wrote any
of it, stop and report that a fresh session is required.

Module to review (SOURCE file, TARGET file, or TRACE entry): $ARGUMENTS

Ground rules:
- Read-only. No edits, no fixes. Findings go in the report; fixes belong to the
  owning workstream.
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
   LESSONS entries if any. Record the report path in the module's TRACE entry.

Verdict rules: any VIOLATION means not clean; the module cannot move to `gated`
until the owning workstream resolves it and a re-review passes. Never fix-and-pass
in the same review.
