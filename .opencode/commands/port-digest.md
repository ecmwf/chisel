---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Prepare a milestone's evidence for sign-off, record the human's decision, and seal it with finalize.sh
---

Compile and cross-check the evidence for a phase or milestone, so the human's time goes to judgment,
not collation. You prepare the sign-off and record the human's decision; you never make it.

Scope (phase or milestone): $ARGUMENTS

Cross-check, and name every discrepancy:
1. **Charter criteria against proof evidence.** Every criterion of the relevant charter section has a
   proof run at the required configuration, with its evidence paths. Classify each deliverable by
   what it acts on: one that acts on a later phase's output (a tool that checks code not yet written)
   cannot exist yet. Flag it for that phase's entry check rather than as missing, and put the
   boundary to the human (re-scope or defer).
2. **TRACE against reality.** Statuses agree with the tags and the evidence; no `proven` entry lacks
   proof or review evidence; no proven entry's proof is R0; no session is both author and reviewer.
3. **Seeded-bug records.** Every detector this phase relied on has a current red-then-green record
   for its present logic version.
4. **Placeholders.** None open that affect this scope (charter section 6).
5. **Lessons.** The phase retrospective is drafted, standing rules are pruned or mechanized where due,
   and closed ledger entries are staged for `port/lessons-archive/`.
6. **Known divergences.** Everything a proof relied on is registered and signed in
   `port/KNOWN-DIVERGENCES.md`.
7. **The product, at a product milestone or handover only** (otherwise write "product README and run
   assets: not due at this phase"):
   - its README is written for a consumer - what it does, a link to the original, exact build and run
     commands, no placeholders, no methodology words: `tools/conformance/check-product-readme.sh
     --require-filled`. Its owner writes it as the product becomes usable; the integrator never does.
   - a fresh clone builds and runs: the example inputs, sample data, runtime configs and test fixtures
     the README's `## Run` and `## Test` use are in the product and pushed. They land through
     `tools/coordination/integrate_assets.sh <branch>`. Name any that are missing.

Then write `docs/evidence/<date>-digest-<scope>/`:

- **report.md**: the cross-check results, every discrepancy named, and a verification runbook per
  criterion. For a mechanical one (bit-identity, an exact proof, a passing check), write "exact
  proof, nothing to check by hand" and link the evidence. For one that needs judgment (statistical
  equivalence, whether a residual matters, a visual comparison), give the exact command or file and
  the good-versus-bad signature, e.g. "a difference confined to high-variability regions is
  expected; a smooth, large-scale gradient is a bias - reject". Show the human how to look; never
  tell them what to conclude.
- **SIGNOFF.md**, from the code-port skill's `assets/SIGNOFF.template.md`, filled down to and
  including "Agent recommendation": the verdict you recommend, why in plain words, the honest risks,
  and which runbook steps the human should check.

Ask the human one question about the outcome. When you recommend a clean accept: "Accept in full?
(`yes` / `accept with conditions: <...>` / `no: <reason>`)", so a bare `yes` means accept in full;
when your recommendation has conditions, ask them to pick the outcome. Transcribe their explicit
answer into "Human decision": the Decision as a plain token (`accept-in-full`,
`accept-with-conditions` or `reject`; `finalize.sh` reads it literally, so no emphasis, and conditions
go in Notes), What I checked (their words, or "confirmed, mechanical proof"), and Signed with their
`git config user.name`, confirmed with them, and the date. Never invent a decision or read a vague
reply as one.

On an accept, seal it for them (auto-land, the charter default): commit the phase artifacts and
SIGNOFF.md, then run `tools/coordination/finalize.sh <milestone-tag> --signoff <path> [--sync
<sync-branch>]`. It refuses without a committed accept at HEAD; then it tags, lands any pending
methodology sync, pushes, and removes the sync worktree.

In autodrive the digest is still written as the evidence pack, but no one is asked:
`/port-autodrive` step 8 seals the milestone with `finalize.sh <tag> --auto`.
