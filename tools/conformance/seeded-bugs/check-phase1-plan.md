# SEEDED-BUG DEMONSTRATION - conformance/check-phase1-plan

- Date: 2026-06-18 (new detector: the phase-1-plan shard-and-generate drift gate)
- Detector: tools/conformance/check-phase1-plan.sh (wraps tools/coordination/generate_phase1_plan.py --check)
- Failure class targeted: the canonical `port/phase1-plan.yaml` drifting from the per-unit
  fragments. In a parallel Phase 1, contributors write `port/phase1/units/<id>.yaml`
  fragments in their own branches and the canonical plan is GENERATED from them; if someone
  hand-edits the canonical plan, or changes a fragment without regenerating, the plan the
  driver reads silently disagrees with the units. This is the shared-registry collision
  class that corrupts one central plan with NO conflict signal (a rebase drops a "patch
  already upstream" hunk; a plain merge picks one side). The check regenerates from the
  fragments and fails on any disagreement - the guard that makes shard-and-generate
  trustworthy for the phase-1 plan, exactly as check-trace-drift does for TRACE.
- Exit-code contract: 0 GREEN (committed plan matches the fragments, or there are no
  fragments yet), 1 RED (drift), 2 UNRELIABLE (no python3 / PyYAML / meta / not a git repo).

The generator is deterministic (the same fragments + meta always produce the same plan).
The check compares parsed DATA MODELS (robust to formatting and comments). Fixtures use
`--units-dir` / `--meta` / `--plan`; the default scans `port/phase1/units/` + `port/phase1/_meta.yaml`
against `port/phase1-plan.yaml`.

## Seeded defects and red proofs

- **Fragment changed without regenerating:** generate the plan, then flip a fragment's
  `accepted: true -> false` and re-run `--check` against the unchanged committed plan ->
  RED, exit 1: `unit[0] id=harness key=accepted differs (gen=False committed=True)`.
- **Canonical plan hand-edited (a unit dropped):** delete a unit stanza from the committed
  plan and re-run -> RED, exit 1: `unit count differs (generated=9 committed=8)`. A changed
  scalar inside a kept stanza is reported symmetrically as `unit[i] id=<id> key=<k> differs`.

## Green proof (defect removed)

- Regenerate the canonical plan from the fragments
  (`generate_phase1_plan.py --output port/phase1-plan.yaml`), then `--check`: GREEN, exit 0 -
  `committed plan matches N fragment(s)`.
- The base repo (no `port/phase1/units/` fragments): GREEN, exit 0 - nothing to generate, so
  the check skips; a monolithic scaffolded plan is untouched.

## Causal proof (the generator is what canonicalizes)

The committed plan that passes is exactly the generator's output; any later divergence - in a
fragment, in `_meta.yaml`, or in the committed file - moves the verdict from GREEN to RED. So
"passed" always means "the committed plan equals the deterministic projection of the
fragments," never "someone said it was fine."

## Scope / non-defect signals confirmed

- Determinism: units are emitted in the `_meta.yaml` `ordering`, with a fixed field order and
  flow lists, so the same fragments always produce byte-identical output and the check never flaps.
- Comparison is on DATA, so reformatting or re-commenting the committed plan without changing
  the data stays GREEN; only a real data disagreement is RED. A fragment's `note:` key is
  discarded by the generator and excluded from the comparison.
- Fail-closed UNRELIABLE (exit 2), kept distinct from RED: a duplicate unit id; a fragment
  with no non-empty `id`; an unknown unit/evidence key; `_meta.yaml` missing a required key
  (`schema_version`/`source_signed`/`ordering`) or with an `ordering`/fragment-set mismatch; a
  **duplicate id in `ordering`** (caught in `load_meta` with a clear message - it would otherwise
  emit the same unit twice); a duplicate YAML key anywhere; PyYAML absent; or the committed plan
  missing while fragments exist.
- **Driver-validity (shared validator, exit 2):** before returning, `build_model` renders the
  model and runs it through `phase1_drive.py`'s OWN `load_plan` validator; if the driver would
  reject the plan as malformed, the generator fails closed rather than greenlighting it. This is
  reused, not re-implemented, so the generator can never drift more permissive than the driver.
  Confirmed: a fragment with an unknown `kind` (e.g. `bogus`) or a boolean `layer` (`layer: true`)
  - both accepted by the generator's own per-fragment checks - now fail with
  `the generated plan is malformed per phase1_drive.py's validator`. A fully-formed plan
  (every unit with a known kind and non-negative integer layer) passes and regenerates GREEN.

## Comparison-logic version

The comparison logic is: `build_model(fragments + _meta.yaml)` -> a `{schema_version,
source_signed, units[]}` model, versus the parsed committed plan compared unit-by-unit in
`ordering` sequence; equal -> GREEN, unequal -> RED. `build_model` additionally validates the
rendered model through `phase1_drive.load_plan` (the driver's own loader) and a duplicate
`ordering` id in `load_meta`, both fail-closed (exit 2). Re-run this demonstration after any
change to the fragment->unit mapping, the renderer, the comparison, or the shared driver
validator (standing seeded-bug rule): a changed fragment and a hand-edited plan must both go
RED, a malformed-for-the-driver plan must go exit-2, and a freshly regenerated plan must stay
GREEN.
