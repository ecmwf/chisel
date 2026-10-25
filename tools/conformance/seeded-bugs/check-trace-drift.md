# SEEDED-BUG DEMONSTRATION - conformance/check-trace-drift

- Date: 2026-06-15 (new detector, WS-E0: the shard-and-generate cutover check)
- Detector: tools/conformance/check-trace-drift.sh (wraps tools/coordination/generate_trace.py --check)
- Failure class targeted: canonical TRACE drifting from the per-work-item fragments. In a
  many-contributor port, contributors write `port/status/<id>.yaml` fragments in their own
  branches and the canonical `port/TRACE.yaml` is GENERATED from them; if someone
  hand-edits canonical TRACE, or changes a fragment without regenerating, canonical status
  silently disagrees with the work. This check regenerates from the fragments and fails on
  any disagreement - the guard that makes shard-and-generate trustworthy, and the cutover
  check (until it is live and seeded, the central-write commands stay serial).
- Exit-code contract: 0 GREEN (committed TRACE matches the fragments, or there are no
  fragments yet), 1 RED (drift), 2 UNRELIABLE (no python3 / PyYAML / meta / not a git repo).

The generator is deterministic (the same fragments always produce the same TRACE - what a
re-runnable wave relies on). The check compares parsed DATA MODELS (robust to formatting
and comments), normalizing row order by work-item id. Fixtures use `--status-dir` /
`--trace`; the default scans `port/status/` against `port/TRACE.yaml`.

## Seeded defects and red proofs

- **Fragment changed without regenerating:** generate TRACE from a fragment, then flip the
  fragment's `status: proven -> in-progress` and re-run `--check` against the unchanged
  committed TRACE -> RED, exit 1: `row 'm001' differs from what its fragment generates.`
- **Canonical TRACE hand-edited:** append a `ghost` row (no backing fragment) to the
  committed TRACE and re-run -> RED, exit 1: `committed TRACE row 'ghost' has no fragment.`
  (A missing row - a fragment with no committed row - is reported symmetrically, as is a
  differing `meta` block.)

## Green proof (defect removed)

- Regenerate canonical TRACE from the fragments (`generate_trace.py > TRACE.yaml`), then
  `--check`: GREEN, exit 0 - `committed TRACE matches the N fragment(s)`.
- The base repo (no `port/status/` fragments): GREEN, exit 0 - nothing to generate, so the
  check skips; the single-operator pilot's hand-maintained TRACE is untouched.

## Causal proof (the generator is what canonicalizes)

The committed TRACE that passes is exactly the generator's output; any later divergence -
in a fragment or in the committed file - moves the verdict from GREEN to RED. So "passed"
always means "canonical TRACE equals the deterministic projection of the fragments," never
"someone said it was fine."

## Scope / non-defect signals confirmed

- Determinism: rows are sorted by `(id, source)` and emitted in a fixed field order with
  indented block sequences, so the same fragments always produce byte-identical TRACE and
  the check never flaps.
- The generated TRACE uses the canonical template format (`  - source:` first, 4-space
  fields, `proof`/`review` as bare evidence PATHS), so the awk evidence checker
  (`check-trace-evidence.sh`) SEES and validates generated rows - verified: a generated
  proven row reports `1 proven, 0 integrity violation(s)`, not the silent `no file entries`
  it gave before this fix. Generated rows also carry `id`, `integration`, `proof_tier`,
  `proof_commit`, which name-keyed consumers ignore.
- Comparison is on DATA, so reformatting or re-commenting the committed TRACE without
  changing the data stays GREEN; only a real data disagreement is RED.
- Fail-closed UNRELIABLE (exit 2), kept distinct from RED: a duplicate work-item id; a
  fragment with no non-empty `id`/`source`, or a non-list `target`; meta missing a
  required key (`source_root`/`target_root`/`source_commit`); a duplicate YAML key
  anywhere; PyYAML absent; or the committed TRACE missing while fragments exist.

## Comparison-logic version

The comparison logic is: `build_trace(fragments + _meta.yaml)` -> a `{meta, files[]}`
model (one row per fragment via the fixed mapping in `generate_trace.py`), versus the
parsed committed TRACE normalized by row id; equal -> GREEN, unequal -> RED. Re-run this
demonstration after any change to the fragment->row mapping or the comparison (standing
seeded-bug rule): a changed fragment and a hand-edited TRACE must both go RED, and a
freshly regenerated TRACE must stay GREEN.
