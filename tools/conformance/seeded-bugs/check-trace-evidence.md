# SEEDED-BUG DEMONSTRATION - conformance/check-trace-evidence

- Date: 2026-06-14 (re-seeded after the clean-vs-violations comparison-logic change)
- Detector: tools/conformance/check-trace-evidence.sh
- Failure class targeted: TRACE-to-evidence desync. A module recorded `gated` (or citing a
  gate/review path) without the durable CLEAN review the hard rule requires. Recollection
  that "it was reviewed" must never outweigh a missing - or violations - report.
- Exit-code contract: 0 clean, 1 integrity violation, 2 could not run.

The in-repo TRACE has no live entries (`files: []`), so the check skips there (exit 0).
The demonstration runs against fixtures with the same layout the script expects.

## Seeded defects (representative of the class)

Defect A - gated without a durable review:
- A TRACE entry with `status: gated` and `review: null`.
- Expected: `[FAIL] <src>: gated but review is null`; exit 1.

Defect B - a cited report does not exist:
- A `gated` entry whose `review` points to a docs/evidence/.../report.md that is absent.
- Expected: `[FAIL] <src>: review cites a report that does not exist: <path>`; exit 1.

Defect C - gated on a VIOLATIONS review (gated by omission of the clean re-review):
- A `gated` entry whose `review` report records a violations verdict (e.g.
  `## VERDICT: VIOLATIONS (not clean)`). `gated` requires a CLEAN review; a violations
  verdict leaves the module owing a clean re-review.
- Expected: `[FAIL] <src>: gated but its review report records a VIOLATIONS verdict`; exit 1.

Defect D - gated without a recorded tier/commit binding:
- A `gated` entry missing `gate_tier`, or with `gate_tier: R0` (R0 can never gate), or
  missing `gate_commit` (the product commit the gate ran against). The solo-TRACE backstop
  now re-verifies the binding the fragment schema enforces, so a TRACE generated outside the
  fragment path cannot record "gated" without naming the tier and the state it passed at.
- Expected: `[FAIL] <src>: gated requires gate_tier (R1+)`, `... gate_tier 'R0' must be R1 or
  higher`, or `... gated requires gate_commit`; exit 1.

Defect E - gated on a report with NO explicit clean verdict (silence is not a clean review):
- A `gated` entry whose `review` report EXISTS and is not a violations verdict, but records no
  explicit clean verdict at all (an empty file, or prose like "looks fine" with no VERDICT line).
  Absence of a violations verdict is not the same as a recorded clean one; "it was reviewed" must
  be written down, not assumed.
- Expected: `[FAIL] <src>: gated but its review report records no explicit clean verdict (a gated
  review must state e.g. 'VERDICT: clean')`; exit 1.

## Red proof

- Defect A: RED, exit 1 - `[FAIL] geometry.f90: gated but review is null (independent review report required)`.
- Defect B: RED, exit 1 - `[FAIL] geometry.f90: review cites a report that does not exist: docs/evidence/review-geom-MISSING/report.md`.
- Defect C: RED, exit 1 - `[FAIL] geometry.f90: gated but its review report records a VIOLATIONS verdict - a clean re-review is required before gating: docs/evidence/review-bad/report.md`.
- Defect D: RED, exit 1 - `[FAIL] geometry.f90: gated requires gate_tier (R1+)` (tier absent); `gated gate_tier 'R0' must be R1 or higher (R0 cannot gate)` (R0); `gated requires gate_commit (the product commit the gate ran against)` (commit absent).
- Defect E: RED, exit 1 - `[FAIL] geometry.f90: gated but its review report records no explicit clean verdict (a gated review must state e.g. 'VERDICT: clean')`.

## Green proof (defects removed)

- Clean fixture: a `gated` entry whose gate AND review paths exist, whose review report
  records an EXPLICIT clean verdict (e.g. a `VERDICT: clean` line, not mere silence), and
  that records `gate_tier: R1` (or higher) and a `gate_commit`; plus the
  review queue - one module with a `gate` and a VIOLATIONS review but status `in-progress`
  (reviewed-not-clean), and one with `gate` set and `review: null` (first review). Result:
  GREEN, exit 0, `1 gated, 2 awaiting review, 0 integrity violation(s)`. Both queue entries
  are LISTED, not failed. (`gate_tier`/`gate_commit` are checked only on `gated` rows, so
  the queue entries need not carry them.)

## Scope / non-defect signals confirmed

- The review queue is `gate set AND status != gated` (regardless of `review`): a
  reviewed-with-violations module (review set, in-progress) and a never-reviewed module
  (review null) are BOTH listed as owing a clean review, never failed. Only `status: gated`
  clears a module from the queue.
- A missing TRACE file and an empty `files: []` both skip with exit 0.

## Comparison-logic version (re-seeded 2026-06-17)

Parses source/status/gate/review/gate_tier/gate_commit per file entry (4-space fields;
nested symbols block and `notes` ignored). FAILS on: `gated` AND (`gate`|`review` null);
any cited `gate`|`review` path that does not resolve; `gated` AND its review report matches
a violations verdict (`grep -iE 'verdict[: ].*violation|violations \(not clean\)'`); `gated`
AND its review report records NO explicit clean verdict (not `grep -iE 'verdict[: ].*clean'`);
`gated` AND (`gate_tier` unset, or not `^R[1-9][0-9]*$`); `gated` AND `gate_commit` unset.
LISTS as queue (never fails): `gate` set AND status not `gated`. Re-run this demonstration
after any change to that comparison logic (standing seeded-bug rule).
