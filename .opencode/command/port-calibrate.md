---
description: Produce a guided, evidence-backed calibration brief for a non-bit-identical tolerance, then record the human-confirmed band
---

Set or confirm a NON-bit-identical acceptance tolerance the GUIDED way - a Tier-B / R-CANON
distributional band (`|Δmean|` + CI/KS over N seeds), or an atol/rtol per field for a smooth metric,
or an R4 ceiling. The band is RECOMMENDED from MEASURED data and the human CONFIRMS it: never a blind
guess, never the agent self-certifying the number. This is the mid-flight analogue of `/port-digest`
for a single tolerance - so an operator who does not read the ported code can still set the band with
confidence, because the recommendation comes with its evidence and a way to sanity-check it.

Metric to calibrate: $ARGUMENTS

1. **Identify the decision.** Name the metric/field, the gate it feeds (charter §7), and the band
   FORM (`|Δmean|` + CI/KS for a stochastic metric; atol/rtol for a smooth field; a ceiling for R4).
   If the band is ALREADY set in §7 with calibration evidence and nothing it depends on changed, say
   so and STOP - do not re-litigate a settled band.

2. **Gather the MEASURED evidence (measure each; never substitute a guess):**
   - the recorded floating-point FLOOR (from a deterministic gate already passed - e.g. the energy R1);
   - SOURCE's OWN stochastic spread: run the canonical reference run (`reference/runs.md`) for N seeds
     and compute mean, sd, 95% CI - this is the irreducible noise the band must sit ABOVE;
   - the field's PHYSICAL scale (magnitude/unit; what a physically-meaningful delta is);
   - the reference-run ID + output checksum the band calibrates against.
   If a piece genuinely cannot be measured yet, say WHICH and WHY and what it blocks - never paper
   over a missing measurement with a number.

3. **Recommend the band** from that evidence: set it just ABOVE SOURCE's own seed spread / the fp
   floor (so noise passes) and BELOW a physically-meaningful shift (so real drift fails). Write the
   reasoning in plain terms, the honest risks, and a GOOD-vs-BAD signature the human can check by eye.

4. **Write the brief** to `docs/evidence/<date>-calibration-<metric>/` from
   `assets/CALIBRATION.template.md`, filled down to and including the Agent recommendation.

5. **Make the decision EASY (interactive).** Present the recommendation and ASK ONE outcome-framed
   question ("Confirm the band `<X>`? `yes` / `adjust to <band>` / `defer: <why>`"). On the human's
   EXPLICIT answer, TRANSCRIBE it into the brief's Human-decision block (a plain token; never invent a
   name or a number), and record the CONFIRMED band next to the metric in charter §7, citing this
   brief as its calibration evidence. The human's recorded confirmation is what SETS the band - never
   write a band they did not confirm, and never read a vague reply as confirmation. (Then a `/port-gate`
   run for that metric compares against the recorded band.)

6. **In auto-mode there is no human to ask - so the agent does NOT invent a band.** It still produces
   the brief with its recommendation, but SURFACES it as an un-set charter standard the run pauses on
   (a withheld `autodrive.scope` decision), exactly like any other §7 acceptance criterion the human
   sets once - the band is a human-domain input the agent recommends but never forges.

The band is recorded ONCE in the charter (like the §7 acceptance standard); changing it later
SUPERSEDES this brief with a new one, and a superseded reference run gets a NEW id in `reference/runs.md`
(a used run row is never edited). Calibration is judgment with evidence, not a knob to retune until a
gate passes - a band moved to make a failing port pass is a red flag, recorded as such.
