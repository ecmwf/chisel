---
description: Demonstrate a gate/probe fires on a seeded bug (required before trust)
---

Run the seeded-bug demonstration for a detector and produce its evidence record.
A detector without a complete red-then-green record is unproven and its results do
not count.

Detector (gate/probe script path or ID): $ARGUMENTS

1. Identify the failure class the detector claims to catch (failure-mode IDs from
   the code-port skill, trap IDs from the conventions skill). Design a seeded
   defect REPRESENTATIVE of that class - a wrong constant for the anchor verifier,
   a stride swap for a kernel gate, a stale exchange region for the boundary probe.
   Never a trivial syntax error: a weak seed proves only that the script can fail.
2. Instantiate `SEEDED-BUG.template.md` (code-port skill assets) into
   `docs/evidence/<date>-seeded-<detector>/`.
3. Inject the defect. Run the detector. Capture the RED result: nonzero exit and a
   signature matching the expected one. If it stays green, the detector is broken:
   stop, fix the detector, record the lesson (/port-lesson) - this is the rule earning
   its keep.
4. Remove the defect (prove removal). Rerun. Capture the GREEN result.
5. Record the detector's logic version (commit hash). The demonstration must be
   renewed after any change to the comparison logic.
6. Report the evidence path. Only a complete red-then-green record marks the
   detector trusted.
