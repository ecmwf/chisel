---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Recommend a tolerance band from measured evidence, and record it once the human confirms it
---

Set a tolerance where exact agreement is not the bar: a statistical band (the mean difference with a
confidence interval or KS test over N seeds), an atol/rtol per field, or an R4 ceiling. You recommend
the band from measured data; only the human sets it, in charter section 7. The recommendation comes
with its evidence and a way to check it by eye, so someone who does not read the ported code can
still decide with confidence.

Metric: $ARGUMENTS

1. **The decision.** Name the metric or field, the proof it feeds (charter section 7) and the form of
   the band. If section 7 already holds the band with calibration evidence and nothing it depends on
   has changed, say so and stop.
2. **Measure** each input; never substitute a guess:
   - the recorded floating-point floor, from a deterministic proof already passed;
   - the SOURCE's own spread: run the canonical reference run (`reference/runs.md`) for N seeds and
     compute the mean, standard deviation and 95% confidence interval - the noise the band must sit
     above;
   - the field's physical scale: its magnitude and unit, and what a meaningful change would be;
   - the reference run's ID and output checksum.

   If something cannot be measured yet, say what, why, and what it blocks.
3. **Recommend** a band just above the SOURCE's spread and the floor (so noise passes) and below a
   meaningful change (so real drift fails), with the reasoning in plain words, the honest risks, and a
   good-versus-bad signature the human can check by eye.
4. **Write the brief** in `docs/evidence/<date>-calibration-<metric>/` from the code-port skill's
   `assets/CALIBRATION.template.md`, down to and including the agent recommendation.
5. **Ask once:** "Confirm the band `<X>`? (`yes` / `adjust to <band>` / `defer: <why>`)". Transcribe
   the human's explicit answer into the brief's human decision (a plain token; never invent a name or
   a number), and record the confirmed band next to the metric in charter section 7, citing the brief.
   Never write a band they did not confirm, or read a vague reply as a confirmation. `/port-prove`
   then compares against it.
6. **In autodrive**, write the brief and ask the same question once; never write the band yourself.
   Until the human answers, only the units whose proof needs this band wait; the rest keeps driving.

A band is set once. Changing it later supersedes the brief with a new one, and a superseded reference
run gets a new ID in `reference/runs.md` (a used row is never edited). Calibration is judgment with
evidence, not a knob to turn until a proof passes: a band moved to make a failing port pass is a red
flag, recorded as one.
