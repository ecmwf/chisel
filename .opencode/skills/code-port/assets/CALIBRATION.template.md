# Calibration brief - <metric / proof>

The evidence for an acceptance tolerance that is not bit-identity, so the human sets the band from
measured data rather than a guess. Only the human sets it. `/port-calibrate` writes one brief per
metric or field to `docs/evidence/<date>-calibration-<metric>/`; the confirmed band goes next to its
metric in charter section 7, citing the brief, and the brief is the band's calibration evidence
(a tolerance without evidence is a guess - references/validation-ladder.md).

## 1. The decision, in plain terms

- **Metric / field:** <e.g. the time-mean of a diagnosed field, over N seeds>
- **Proof it feeds:** <the statistical whole-program comparison (charter section 7) | R1 per-field atol/rtol | R4 accelerator ceiling>
- **What you are setting:** the acceptance band that rejects a port whose <metric> drifts from SOURCE
  by more than this. Form: `<|Δmean| <= ?, with CI overlap + KS p >= ?>` (stochastic) or
  `<atol + rtol*|b|>` (a smooth field).
- **Why it matters:** the band is the line between noise and drift. Set too tight, it rejects on
  <stochastic seed noise / the floating-point floor>; set too loose, a real bias slips through.

## 2. Measured evidence (what the recommendation is drawn from)

- **Floating-point floor:** <recorded fp floor - e.g. the deterministic energy R1 reproduced at rel 5e-4>
- **SOURCE's own stochastic spread:** <the reference's seed-to-seed variation: mean, sd, 95% CI over
  N=<n> seeds> - the irreducible noise the band must sit above (run the reference; never guess it).
- **Physical scale:** <the field's magnitude + unit; what a physically-meaningful delta would be>
- **Reference run:** <reference/runs.md ID + output checksum the band is calibrated against>

## 3. Agent recommendation (a recommendation, not the decision)

- **Recommended band:** <the concrete value(s)>
- **Reasoning (plain terms):** <e.g. just above the SOURCE's own seed spread (so noise passes) and
  well below a physically meaningful shift (so real drift fails); about <k> times the fp floor>.
- **Honest risks:** <what this band could miss, or could falsely fail>.
- **How to sanity-check it yourself (good-vs-bad signature):** <e.g. "PASS looks like: |Δmean| inside
  the band, the port and SOURCE 95% CIs overlap, KS p >= <t>, the residual sign is mixed. FAIL looks
  like: |Δmean| outside the band, or tight non-overlapping CIs, or KS p < <t> with a consistent-sign
  shift - that is a real bias, reject."> The point is to show you how to look, never what to conclude.

## 4. Human decision (yours - the agent writes down your answer word for word)

<One outcome-framed question, e.g. "Confirm the band `<X>`? (`yes` / `adjust to <band>` / `defer: <why>`)">

- **Decision:** <confirm `<band>` | adjust to `<band>` | defer> - a plain token; conditions/why go in Notes.
- **Notes:**
- **Signed:** <your name - from git config, the agent confirms it, never invents it>   **Date:** <date>
- **Calibrates:** charter section 7 <metric line> against reference run <ID>
