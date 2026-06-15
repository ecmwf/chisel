---
description: Run a validation-ladder gate and record the evidence
---

Run a validation gate and handle the result with full discipline.

Gate to run (e.g. R1 <kernel>, R2, R4 - or a tools/gates/ script name): $ARGUMENTS

1. Locate the gate script in `tools/gates/` and its acceptance criterion in
   `port/plan/00-charter.md` §7. If no script exists yet for this tier, say so and
   propose building it first (gates are scripts, not rituals). A new or changed gate
   must have a current red-then-green seeded-bug record before its result counts
   (run /port-seed if missing).
2. **Two-root preflight, then run it.** Resolve the product checkout (from `port/product.yaml`
   via `tools/conformance/lib/product-root.sh`; a wired-but-absent product is UNRELIABLE, not a
   pass) and export the env vars the gate scripts read under the two-root contract:
   `WORKBENCH_ROOT` (this workbench), `PRODUCT_ROOT` (the product checkout), `SOURCE_PIN_REF` +
   `SOURCE_SUBDIR` (the pinned SOURCE), `REFERENCE_RUN_ID` (the canonical reference run). Record
   the product commit + tree the gate ran against, then run the gate and capture the full output
   to `docs/evidence/<date>-gate-<short-desc>/` (record those env values in the pack so the
   evidence is bound to the exact product tree).
3. **If it passes:** record the gate evidence path in the TRACE entry's `gate`
   field. Do NOT set `status: gated` here: gated additionally requires a clean
   independent fidelity review (/port-review). R0 evidence may NEVER populate the
   gate field of a gated entry. If this completes a milestone, update the plan
   checkbox and prepare for sign-off (/port-digest); the milestone tag is
   created only after the human's SIGNOFF.md is recorded. Never self-certify.
4. **If it fails:** before reading any code, follow the gate-failure workflow from the
   skill's `references/differential-tooling.md`:
   check KNOWN-DIVERGENCES first → disable-switches to bracket the subsystem → staged
   dump to name the first diverging substep → identical-input/replay diff to decide
   wrong-kernel vs wrong-input → poison discriminator for staleness hypotheses → only
   then read code, with file:line citations.
5. After any fix: rerun the per-kernel gate, then the tier that failed, then every tier
   above it. Capture the lesson (/port-lesson) in this same sprint.
