---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Show that a proof or check fails on a planted bug, before its results are trusted
---

Run the seeded-bug demonstration for a detector and record it. A detector without a complete
red-then-green record is not trusted, and its results do not count.

Detector (script path or ID): $ARGUMENTS

1. Name the failure class the detector claims to catch (failure-mode IDs from the code-port skill,
   trap IDs from the target-conventions skill) and design a defect typical of it: a wrong constant
   for the anchor verifier, a swapped stride for a kernel proof, a stale exchange region for a
   boundary probe. Never a syntax error: a weak seed only shows that the script can fail.
2. Start the record from the code-port skill's `assets/SEEDED-BUG.template.md`. A dispatched
   Kha-Worker writes it under its contract's `EVIDENCE_PREFIX` (a Phase-1 tool: the `seeded` record
   in `docs/evidence/phase1/<id>/`); otherwise it goes in `docs/evidence/<date>-seeded-<detector>/`.
   A conformance check also keeps a compact record in `tools/conformance/seeded-bugs/`, or for a
   port's own check in `tools/conformance/project/`.
3. Plant the defect and run the detector. Capture the red result: a non-zero exit with the expected
   signature. If it stays green, the detector is broken: stop, fix it, and record the lesson
   (`/port-lesson`).
4. Remove the defect, show that it is gone, rerun, and capture the green result.
5. Record the detector's logic version (the commit). Renew the demonstration after any change to its
   comparison logic.
6. Report the record's path. Only a complete red-then-green record makes the detector trusted.
