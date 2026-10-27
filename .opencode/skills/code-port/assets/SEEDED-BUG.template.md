# SEEDED-BUG DEMONSTRATION - <proof/probe ID>

> A proof or probe is trusted only after it has been seen to fail. This record is
> created before the detector's first real use and RENEWED after any change to its
> comparison logic. Without a complete red-then-green record the detector's results
> do not count.

- Detector: <script path>
- Detector logic version: <commit hash containing the comparison logic>
- Failure class targeted: <failure-mode / trap IDs, e.g., L4, T6>
- Seeded defect: <description + where the patch/fixture is stored>
  The defect MUST be representative of the targeted class (a wrong constant for an
  anchor verifier, a stride swap for a kernel proof), never a trivial syntax error -
  a weak seed proves only that the script can fail, not that it detects the class.
  For a BIT-EXACT differential, the perturbation must change the value's MACHINE
  REPRESENTATION, not merely its textual form: a decimal edit beyond the type's
  significant-digit limit rounds back to the identical bits and yields a false green
  that proves nothing. Perturb a significant digit (or flip a representable bit).
- Expected failure signature: <what the detector should report>

## Red proof
- Run: <command, date>
- Result: <nonzero exit + observed signature; must match expected>

## Removal
- Defect removed: <commit / cleanup proof>

## Green proof
- Run: <command, date>
- Result: <exit 0 on the clean tree>

- Recorded by session: <id>
- Human acknowledged: <name/date | pending>
