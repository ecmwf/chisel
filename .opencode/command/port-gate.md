---
description: Run a validation-ladder gate and record the evidence
---

Run a validation gate and handle the result with full discipline.

Gate to run (e.g. R1 <kernel>, R2, R4 - or a tools/gates/ script name): $ARGUMENTS

1. Locate the gate script in `tools/gates/` and its acceptance criterion in
   `port/plan/00-charter.md` §7. If no script exists yet for this tier, say so and
   propose building it first (gates are scripts, not rituals). A new or changed gate
   must have a current red-then-green seeded-bug record before its result counts
   (run /port-seed if missing). If this is a NON-bit-identical gate (a Tier-B/R-CANON
   distributional band, or an atol/rtol/ceiling) whose tolerance is not yet set in §7
   WITH calibration evidence, run `/port-calibrate <metric>` FIRST - a gate has nothing
   trustworthy to compare against until its band is a human-confirmed, evidence-backed value.
2. **Two-root preflight, then run it.** If you are a dispatched worker, gate against YOUR
   provisioned roots: export `WORKBENCH_ROOT` and `PRODUCT_ROOT` from your dispatch contract (your
   `.worktrees/<id>` and your own product worktree), NOT the shared checkout - the gate/conformance
   scripts honor an explicit `PRODUCT_ROOT` over `port/product.yaml`, so this is what keeps parallel
   gates from racing on one product tree. Otherwise (a solo/orchestrator run) resolve the product
   checkout from `port/product.yaml` via `tools/conformance/lib/product-root.sh` (a wired-but-absent
   product is UNRELIABLE, not a pass). Either way export the env vars the gate scripts read under the
   two-root contract: `WORKBENCH_ROOT`, `PRODUCT_ROOT`, `SOURCE_PIN_REF` + `SOURCE_SUBDIR` (the
   pinned SOURCE), `REFERENCE_RUN_ID` (the canonical reference run). Record the product commit + tree
   the gate ran against, then run the gate and capture the full output to
   `docs/evidence/<date>-gate-<short-desc>/` (record those env values in the pack so the evidence is
   bound to the exact product tree). Cite in the pack only facts that stay true once it is committed
   and other units land - that product commit, unit-scope counts, SOURCE file:line - never the
   workbench HEAD, a whole-product aggregate, or a TARGET line number not tied to the cited commit
   (failure mode B28).
3. **If it passes:** record the gate evidence path in the TRACE entry's `gate`
   field. Do NOT set `status: gated` here: gated additionally requires a clean
   independent fidelity review (/port-review). R0 evidence may NEVER populate the
   gate field of a gated entry. If this completes a milestone, update the plan
   checkbox and prepare the digest (/port-digest); the milestone tag is gate-sealed by
   `finalize.sh` - hand-driven, the human's SIGNOFF.md; in L2/L3 auto-mode, `finalize.sh --auto`
   after full conformance green at HEAD. Never self-certify.
4. **If it fails:** before reading any code, follow the gate-failure workflow from the
   skill's `references/differential-tooling.md`:
   check KNOWN-DIVERGENCES first → disable-switches to bracket the subsystem → staged
   dump to name the first diverging substep → identical-input/replay diff to decide
   wrong-kernel vs wrong-input → poison discriminator for staleness hypotheses → only
   then read code, with file:line citations.
5. After any fix: rerun the per-kernel gate, then the tier that failed, then every tier
   above it. Capture the lesson (/port-lesson) in this same sprint.
