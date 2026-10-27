---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Record a lesson in port/LESSONS.md now, in the sprint that paid for it
---

Add a lesson to `port/LESSONS.md` the moment it happens, never later at sprint end. This only
captures: run it yourself, without being asked, and report what you wrote. Only the promotion to a
standing rule or to a check (step 2) is a proposal the human decides. Do not record an expected
result or a lesson the ledger already has.

A dispatched Kha-Worker writes the entry, without a number, to `lessons.md` in its evidence folder
and names it in its report; Ptah-Orchestrator numbers it into `port/LESSONS.md` when it gathers, so
parallel workers never take the same number.

Context from the user (may be empty): $ARGUMENTS

1. Take the next L-number; check `port/lessons-archive/` too, since L-numbers are never reused. Tag
   the entry with its failure-class and trap IDs (N2, B1, T6, ..., or `-`) so a search finds it.
   Fill every field of the ledger format: Symptom, Root cause (with file:line), Fix (with the commit,
   if there is one), Prevention (the rule or detector that would have caught it earlier), Action.
2. State the Action:
   - none (a one-off);
   - propose promoting it to the STANDING RULES (general or recurring; keep that block to about 20
     rules);
   - propose a check (a probe, proof or conformance script in `tools/`), the strongest option. If the
     detector that should have caught it does not exist, say so and propose building it.
3. A failed or removed optimization goes under NEGATIVE RESULTS, with the measurement that ruled it
   out.
4. If the lesson is not tied to this program, add "upstream candidate" to its Action, so
   `/port-contribute-to-base` finds it; the human approves what goes upstream.
