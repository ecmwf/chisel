---
description: Capture a lesson into port/LESSONS.md right now (same-sprint rule)
---

Append a lesson entry to `port/LESSONS.md` immediately - lessons are captured in the
sprint that pays for them, never deferred to sprint end.

Context/hint from the user (may be empty): $ARGUMENTS

1. Use the next L-#### number (check the archive in `port/lessons-archive/` too -
   L-numbers are permanent and never reused). Tag the entry with its failure-class
   and trap IDs (L2, B1, T6, ... or `-`) so it is findable by grep. Fill every field
   of the ledger format: Symptom, Root cause (with file:line), Fix (with commit if
   available), Prevention (the rule or detector that would have caught it earlier),
   Action.
2. Decide and state the Action explicitly:
   - none (one-off), or
   - propose promotion to STANDING RULES (if general or recurring - keep the block
     ≤ ~20 rules), or
   - propose mechanization (a probe/port-gate/conformance script in `tools/`) - the
     strongest option; if the detector that should have caught this doesn't exist,
     say so and propose building it.
3. If it is a failed/removed optimization, record it under NEGATIVE RESULTS with the
   measurement that killed it.
4. If the lesson looks project-agnostic, note it as a candidate for the skill's
   failure-modes reference (human approval required).
