---
description: Run a validation-ladder gate and record the evidence
---

Run a validation gate and handle the result with full discipline.

Gate to run (e.g. R1 <kernel>, R2, R4 - or a tools/gates/ script name): $ARGUMENTS

1. Locate the gate script in `tools/gates/` and its acceptance criterion in
   `port/plan/00-charter.md` §7. If no script exists yet for this tier, say so and
   propose building it first (gates are scripts, not rituals).
2. Run it. Capture the full output to `docs/evidence/<date>-<gate>-<short-desc>/`.
3. **If it passes:** report the evidence path; if this completes a milestone, update
   the plan checkbox, update TRACE statuses, and remind about the git tag. Do NOT
   self-certify stage acceptance - present the evidence to the human and ask.
4. **If it fails:** before reading any code, follow the gate-failure workflow from the
   skill's `references/differential-tooling.md`:
   check KNOWN-DIVERGENCES first → disable-switches to bracket the subsystem → staged
   dump to name the first diverging substep → identical-input/replay diff to decide
   wrong-kernel vs wrong-input → poison discriminator for staleness hypotheses → only
   then read code, with file:line citations.
5. After any fix: rerun the per-kernel gate, then the tier that failed, then every tier
   above it. Capture the lesson (/lesson) in this same session.
