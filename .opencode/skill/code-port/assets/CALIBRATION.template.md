# Calibration brief - <metric / proof>

A guided, evidence-backed setting of a NON-bit-identical acceptance tolerance, so the human confirms
a band drawn from MEASURED data instead of guessing. Produced by `/port-calibrate`; the confirmed
band plus this brief ARE the tolerance's calibration evidence (a tolerance without evidence is a
guess - references/validation-ladder.md). One brief per metric/field. Write it to
`docs/evidence/<date>-calibration-<metric>/`, and record the confirmed band next to the metric in
the charter (§7), citing this brief.

## 1. The decision, in plain terms

- **Metric / field:** <e.g. final PSO+SA basin energy; the mean over N seeds>
- **Proof it feeds:** <R-CANON / Tier-B distributional | R1 per-field atol/rtol | R4 accelerator ceiling>
- **What you are setting:** the acceptance band that REJECTS a port whose <metric> drifts from SOURCE
  by more than this. Form: `<|Δmean| <= ?, with CI overlap + KS p >= ?>` (stochastic) or
  `<atol + rtol*|b|>` (a smooth field).
- **Why it matters:** the band is the line between NOISE and DRIFT. Set too TIGHT it false-rejects on
  <stochastic seed noise / the floating-point floor>; set too LOOSE a real bias slips through unseen.

## 2. Measured evidence (what the recommendation is drawn from - NOT a guess)

- **Floating-point floor:** <recorded fp floor - e.g. the deterministic energy R1 reproduced at rel 5e-4>
- **SOURCE's own stochastic spread:** <the reference's seed-to-seed variation: mean, sd, 95% CI over
  N=<n> seeds> - this is the irreducible noise the band must sit ABOVE (run the reference, do not guess it).
- **Physical scale:** <the field's magnitude + unit; what a physically-meaningful delta would be>
- **Reference run:** <reference/runs.md ID + output checksum the band is calibrated against>

## 3. Agent recommendation (a recommendation, NOT the decision)

- **Recommended band:** <the concrete value(s)>
- **Reasoning (plain terms):** <e.g. set just ABOVE SOURCE's own seed spread (so noise passes) and
  well BELOW a physically-meaningful shift (so real drift fails); ~<k>x the fp floor>.
- **Honest risks:** <what this band could miss, or could falsely fail>.
- **How to sanity-check it yourself (good-vs-bad signature):** <e.g. "PASS looks like: |Δmean| inside
  the band, the port and SOURCE 95% CIs overlap, KS p >= <t>, the residual sign is mixed. FAIL looks
  like: |Δmean| outside the band, OR tight non-overlapping CIs, OR KS p < <t> with a consistent-sign
  shift - that is a real bias, reject."> The point is to show you HOW to look, never to tell you what to conclude.

## 4. Human decision (yours - the agent transcribes your EXPLICIT answer)

<One outcome-framed question, e.g. "Confirm the band `<X>`? (`yes` / `adjust to <band>` / `defer: <why>`)">

- **Decision:** <confirm `<band>` | adjust to `<band>` | defer> - a plain token; conditions/why go in Notes.
- **Notes:**
- **Signed:** <your name - from git config, the agent confirms it, never invents it>   **Date:** <date>
- **Calibrates:** charter §7 <metric line> against reference run <ID>
