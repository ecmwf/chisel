# SEEDED-BUG DEMONSTRATION - conformance/no-emdash

> A gate or probe is trusted only after it has been seen to fail. This record is
> created before the detector's first real use and RENEWED after any change to its
> comparison logic.

- Detector: tools/conformance/no-emdash.sh
- Detector logic version: the commit introducing the exit-code contract (this
  evidence pack lands in the same commit)
- Failure class targeted: AGENTS.md no-em-dash hard rule (style invariant)
- Seeded defect: a one-line markdown file containing a literal em-dash, placed
  under docs/ (in scope) and separately under source/ (out of scope by design)
- Expected failure signature: nonzero exit, "FAIL: em-dash found:" plus the
  offending file:line

## Red proof
- Run: seeded file under docs/, `bash tools/conformance/no-emdash.sh`
- Result: exit 1, output named `./docs/_seed.md:1` - matches expected signature

## Scope proof
- Run: seeded file under source/ only
- Result: exit 0 (vendored SOURCE text is excluded by design)

## Removal
- Seeded files deleted; working tree clean

## Green proof
- Run: clean tree
- Result: exit 0, "OK: no em-dashes."

## Why this record exists (the finding that forced it)
The previous version of this script was a false-pass machine: `--` before the
pattern turned `--exclude-dir=.git` into a nonexistent file operand, grep exited
2 (error), and the success branch printed OK regardless of matches. It had never
detected anything, and CI was green on it. Discovered by seeding a defect - the
exact procedure the seeded-bug rule mandates, which this script predated. See
LESSONS L-0001.

- Recorded by session: repo-review (pre-pilot)
- Human acknowledged: pending
