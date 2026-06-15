# SEEDED-BUG DEMONSTRATION - conformance/check-status-fragments

- Date: 2026-06-15 (new detector, WS-E0: shard-and-generate status fragments)
- Detector: tools/conformance/check-status-fragments.sh
- Failure class targeted: a malformed or independence-violating status fragment feeding
  the (generated) canonical TRACE. In a many-contributor port each work item's status
  lives in its own branch as `port/status/<trace-id>.yaml`, and canonical TRACE is
  generated from these. A fragment with a bad status, a bad enum, a missing field, or -
  worst - the SAME id as author and reviewer would silently corrupt canonical status or
  defeat independent review.
- Exit-code contract: 0 GREEN (all fragments well-formed, or none), 1 RED (a violation),
  2 UNRELIABLE (no tooling).

The detector parses each fragment (section-qualified, so `claim.state` and
`integration.state` are disambiguated by parent) and validates required fields, the
enums, the owned-needs-owner rule, and - the fidelity invariant - that `reviewer_id`
differs from `author_id`. Explicit file arguments validate just those files (used here);
the default scans `port/status/*.yaml`.

## Seeded defects and per-arm red proofs

Each fixture isolates one arm so a red proves the arm under test.

- **Independence (the crown jewel):** a fragment with `author_id: alice` and
  `reviewer_id: alice` -> RED, exit 1, one FAIL: `reviewer_id == author_id ('alice') -
  independence violated`. This is the team-scale form of the existing "reviewer session
  not in author_sessions" rule.
- **Enums + owned-without-owner:** a fragment with `status: done`, `claim.state:
  spinning`, `integration.state: merged`, and `ownership.kind: owned` with
  `workstream: null` -> RED, exit 1, four FAILs (invalid status, invalid claim.state,
  invalid integration.state, owned-but-no-workstream). The valid sibling values
  (`unmapped|in-progress|gated|excluded`, `created|active|stale`, `gated|integrated`)
  pass.
- **Missing required fields:** a fragment lacking `source:` and `claim.ref:` -> RED,
  exit 1, two FAILs naming the missing fields. Placeholders (`<...>`) count as unset.

## Green proof (defect removed)

- A well-formed fragment (`id: m001`, `source`, `target`, `status: gated`,
  `ownership.kind: leaf`, distinct `author_id`/`reviewer_id`, a `refs/claims/m001`
  claim, `integration.state: gated`): GREEN, exit 0 - `0 violation(s)`.
- The base repo (no `port/status/` yet): GREEN, exit 0 - nothing to check (skip). The
  fragments are project-layer; the template (`assets/status-fragment.template.yaml`) is
  not scanned (it is the schema, not an instance).

## Scope / non-defect signals confirmed

- The independence check fires only when BOTH ids are set (an in-progress fragment with
  no reviewer yet is not failed for that arm).
- Optional/null fields (e.g. `ownership.workstream: null` for a leaf, `integration`
  fields before integration) are accepted; enums are validated only when set.
- This validates a fragment's SCHEMA. Binding the fragment to its claim ref and to the
  generated canonical TRACE (the claim-schema, branch-diff-vs-claim, and fragment->TRACE
  drift detectors) are separate checks, built with the generator/dashboard.

## Comparison-logic version

The comparison logic is: an awk parser emitting section-qualified `key=value`; required
set = {id, source, status, ownership.kind, claim.ref}; enums = status
{unmapped,in-progress,gated,excluded}, ownership.kind {owned,leaf}, claim.state
{created,active,stale}, integration.state {gated,integrated}; owned => workstream set;
and reviewer_id != author_id when both set. Re-run this demonstration after any change
to the schema or these rules (standing seeded-bug rule): the independence violation and
each malformed enum/missing field must go RED, and a well-formed fragment must stay GREEN.
