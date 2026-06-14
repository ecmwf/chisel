# SEEDED-BUG DEMONSTRATION - conformance/check-trace-evidence

- Date: 2026-06-14
- Detector: tools/conformance/check-trace-evidence.sh
- Failure class targeted: TRACE-to-evidence desync. A module recorded `gated` (or citing a
  gate/review path) without the durable report the hard rule requires existing under
  docs/evidence/. Recollection that "it was reviewed" must never outweigh a missing report.
- Exit-code contract: 0 clean, 1 integrity violation, 2 could not run.

The in-repo TRACE has no live entries (`files: []`), so the check skips there (exit 0).
The demonstration runs against fixtures with the same layout the script expects.

## Seeded defects (representative of the class)

Defect A - gated without a durable review:
- A TRACE entry with `status: gated` and `review: null`.
- Expected signature: `[FAIL] <src>: gated but review is null`; exit 1.

Defect B - a cited report does not exist:
- A `gated` entry whose `review` points to docs/evidence/.../report.md that is absent.
- Expected signature: `[FAIL] <src>: review cites a report that does not exist: <path>`; exit 1.

## Red proof

- Defect A: RED, exit 1.
  `[FAIL] geometry.f90: gated but review is null (independent review report required)`
- Defect B: RED, exit 1.
  `[FAIL] geometry.f90: review cites a report that does not exist: docs/evidence/review-geom-MISSING/report.md`

## Green proof (defect removed)

- Clean fixture: a `gated` entry whose gate AND review paths both exist, plus an entry with
  `gate` set and `review: null` (the legitimate review queue). Result: GREEN, exit 0,
  `1 gated, 1 awaiting review, 0 integrity violation(s)`. The queue entry is listed, not failed.

## Scope / non-defect signals confirmed

- An entry with `gate` set, `review: null`, status not `gated` is the review queue: listed,
  never failed (this is the normal "passed its gate, awaiting independent review" state).
- A missing TRACE file and an empty `files: []` both skip with exit 0.

## Comparison-logic version

Parses source/status/gate/review per file entry (4-space fields; the nested symbols block
and `notes` are ignored). Fails on `(status == gated AND gate|review is null)` or `(any
cited gate|review path does not resolve on disk)`. Re-run this demonstration after any
change to that comparison logic (standing seeded-bug rule).
