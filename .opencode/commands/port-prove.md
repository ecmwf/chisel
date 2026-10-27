---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Run a validation-ladder proof and record its evidence
---

Run a proof and handle its result.

Proof (e.g. `R1 <kernel>`, `R2`, or a `tools/proofs/` script): $ARGUMENTS

1. **Find it.** The script is in `tools/proofs/`, its acceptance criterion in charter section 7. If
   no script exists yet, say so and propose building it: proofs are scripts. A new or changed proof
   needs a current red-then-green seeded-bug record before its result counts (`/port-seed`). A proof
   judged by a tolerance (a statistical band, an atol/rtol, a ceiling) needs that band set in section
   7 with calibration evidence first (`/port-calibrate`).
2. **Run it on the right trees.** A dispatched Kha-Worker uses its own roots - `roots="$(bash
   tools/coordination/assert_isolated.sh <id> --export)" && eval "$roots"` - and writes its evidence
   under its contract's `EVIDENCE_PREFIX` (`docs/evidence/<id>/`; a Phase-1 tool,
   `docs/evidence/phase1/<id>/`). Never the shared checkout: parallel proofs would race on one product
   tree. Otherwise resolve the product from `port/product.yaml` with
   `tools/conformance/lib/product-root.sh` (a product wired but absent is unreliable, not a pass) and
   write to `docs/evidence/<date>-proof-<subject>/`. Export what the proof scripts read:
   `WORKBENCH_ROOT`, `PRODUCT_ROOT`, `SOURCE_PIN_REF` and `SOURCE_SUBDIR` (the pinned SOURCE), and
   `REFERENCE_RUN_ID`. Capture the full output, and record those values and the product commit the
   proof ran against in the pack. Cite only facts that stay true as other units land: that product
   commit, unit-scope counts, SOURCE file:line; never the workbench HEAD, whole-product totals, or a
   TARGET line not tied to the cited commit (B28). An R1 proof of a unit also runs the TARGET's
   runtime checks on the unit's tests (`references/validation-ladder.md`, R1; for C,
   `check-sanitized.py` on the ASan + UBSan build and on the MSan build) and keeps their output in
   the same pack; a red one fails the proof.
3. **If it passes**, record the evidence in the unit's `proof` (with fragments: `proof.tier`,
   `proof.commit`, `proof.evidence`). Do not set `proven`: that takes a clean independent review
   (`/port-review`), and R0 never proves. If it completes a milestone, tick the plan and prepare
   `/port-digest`.
4. **If it fails**, follow the proof-failure workflow before reading any code
   (`references/differential-tooling.md`): check `port/KNOWN-DIVERGENCES.md`; bracket the subsystem
   with disable-switches; find the first diverging substep with a staged dump; tell a wrong kernel
   from a wrong input with an identical-input replay; test a staleness suspicion with the poison
   discriminator; only then read code, citing file:line.
5. **After a fix**, rerun the per-kernel proof, then the tier that failed and every tier above it, and
   record the lesson (`/port-lesson`).
6. Report the result and the evidence path.
