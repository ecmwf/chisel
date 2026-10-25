# SEEDED-BUG DEMONSTRATION - conformance/check-status-fragments

- Date: 2026-06-15 (new detector, WS-E0; hardened after independent review)
- Detector: tools/conformance/check-status-fragments.sh
- Failure class targeted: a malformed or independence-violating status fragment feeding
  the (generated) canonical TRACE. In a many-contributor port each work item's status
  lives in its own branch as `port/status/<trace-id>.yaml`, and canonical TRACE is
  generated from these. A fragment that is `proven` without a real independent reviewer,
  one whose reviewer shares a session with the author, a duplicate/unknown-key fragment,
  or an `integrated` fragment with no `product.main_commit` would silently corrupt canonical
  status or defeat independent review.
- Exit-code contract: 0 GREEN (all fragments well-formed, or none), 1 RED (a violation),
  2 UNRELIABLE (no tooling / not a git repo).

The detector parses each fragment fail-closed (section-qualified, trimmed, dequoted;
duplicate keys and unknown keys are rejected; lists use block `- item` form) and applies
status-dependent rules. Command: `bash tools/conformance/check-status-fragments.sh
<fragment.yaml>`; the default scans `port/status/*.yaml` EXCEPT `_meta.yaml` (which holds
the TRACE meta block for the generator, not a work item - matching `generate_trace.py`).

## Per-arm red proofs (each fixture isolates the arm under test)

- **Independence - no reviewer on proven:** a `status: proven` fragment with
  `reviewer_id: null`, `reviewer_session: null` -> RED: `proven requires reviewer_id`,
  `proven requires reviewer_session`. (The pre-hardening check passed this - the trust-core
  gap an independent review caught.)
- **Independence - reviewer_id == author_id:** both `alice` -> RED: `reviewer_id ==
  author_id ... independence violated`.
- **Independence - shared session:** `reviewer_session: ses-2` while `author_sessions`
  contains `ses-2` -> RED: `reviewer_session 'ses-2' appears in author_sessions`. This is
  the team-scale form of the existing "reviewer session not in author_sessions" rule.
- **Proof tier / binding:** `proof.tier: R0` on a proven row -> RED: `R0 cannot proof`. Missing
  `proof.commit` (the product commit the proof ran against), `proof.evidence`, or
  `review.evidence` on a proven row -> RED, one per missing field.
- **Target shape:** `target` set as a bare scalar (`target: a.c`) instead of a list
  (`target: [a.c]`) -> RED: `target must be a list` (the TRACE generator requires a list).
- **Owner names a surface:** `ownership.kind: owned` without `ownership.workstream`, or
  without `ownership.owned_surface` -> RED, one per missing field.
- **Parser fail-closed - duplicate key:** two `status:` lines (`done` then `proven`) ->
  RED: `duplicate key 'status'`. (Pre-hardening the valid duplicate silently won and the
  fragment passed.)
- **Parser fail-closed - unknown key:** a `bogus_key:` -> RED: `unknown key 'bogus_key'`.
- **Enums:** `status: done`, `claim.state: spinning`, `integration.state: merged`,
  `proof.validation: bogus` -> RED, one per invalid enum. (`proof.validation` accepts only
  `transitive` or null - the declaration-only marker the planner reads to PARK a unit that
  has no behavior to differentially test in isolation; null = a normal unit proven at R1+.)
- **Integration consistency:** `integration.state: integrated` without
  `product.main_commit` -> RED; `integrated` with `status`
  other than `proven` -> RED; ANY non-null `integration.state` (e.g. `staged`) while
  `status` is not `proven` -> RED (a piece integrates only after it proofs).
- **Status-dependent required:** an `in-progress` row missing `target`/`claim.*`/
  `author_id` -> RED naming each.

## Green proof (defect removed)

- A well-formed proven fragment: distinct `author_id`/`reviewer_id`, `reviewer_session`
  not in `author_sessions` (block list, non-empty), `target` a list (`[geometry.c]`),
  `claim.state: active`, `proof.tier: R1` with `proof.commit`, `proof.evidence`, and
  `review.evidence`, `ownership.kind: leaf` (or `owned` with both `workstream` and
  `owned_surface`): GREEN, exit 0. Single-quoted scalars (`status: 'proven'`) and trailing
  spaces are accepted.
- An `excluded` row with a `notes` reason and minimal fields: GREEN (status-dependent -
  an excluded item is not being ported, so claim/author/review are not required). The reason may
  be a scalar string `notes: <reason>` (legacy) OR a block list `notes:\n  - <reason>` (preferred);
  both satisfy the requirement. An excluded row with `notes: []` / `notes: ""` (no reason) is RED.
  Backward-compat note (2026-06-20): `notes` is now in BOTH `KNOWN_SCALAR` and `KNOWN_LIST`, so a
  synced instance's existing string `notes` (even multi-line) still passes; the list is additive.
- The base repo (no `port/status/`): GREEN, exit 0 (skip). The template
  (`assets/status-fragment.template.yaml`) is the schema, not scanned.
- A fragment copied VERBATIM from the template - with the empty list keys written inline as
  `depends_on: []` / `consumes_contracts: []` (the template default) - is GREEN: a `KNOWN_LIST`
  key in inline `key: []` form is accepted as that empty list. Regression fix (2026-06-16):
  these were previously rejected as `unknown key`, so a template-copy fragment failed at the
  first step; the implementation now matches the documented "inline is treated as empty" rule.
- A proven fragment carrying `review.targets` (the reviewed-coverage snapshot, e.g. `[geometry.c]`):
  GREEN. Known-key addition (2026-06-20): `review.targets` joined `KNOWN_SCALAR` so a fragment that
  records what the review covered (for `review_revalidate.sh`) is not rejected as an unknown key; a
  genuinely unknown key (e.g. `bogus_key:`) is still RED.

## Scope / non-defect signals confirmed

- Independence here is the **syntactic check**: `reviewer_id != author_id` and
  `reviewer_session not in author_sessions`. The independence control that makes it real is the
  reviewer agent dispatched on a different model (a solo+agents port); there is no contributor
  registry - that machinery only ever existed to police a multi-human team, and is not part of this
  system. Documented, not claimed.
- Lists (`author_sessions`, `depends_on`, `consumes_contracts`) are read in block form;
  inline `[a, b]` is treated as empty (fail-closed for the proven author_sessions rule).

## Comparison-logic version

The comparison logic is: a fail-closed awk parser (trim + dequote; duplicate-key and
unknown-key rejection against the known schema; block-list members); the status/
ownership/claim/integration enums; `target` must be a list when set; `ownership.kind:
owned` requires both `workstream` and `owned_surface`; status-dependent required fields;
a non-null `integration.state` requires `status: proven`; and - the fidelity invariant -
on `proven`: a tier-R1+ proof with a `proof.commit`, proof evidence, and a review report, and
an independent reviewer (`reviewer_id != author_id`, `reviewer_session not in
author_sessions`, non-empty `author_sessions`); on `integrated`: `status: proven` plus
`product.main_commit`. Re-run this demonstration after any
change to the schema or these rules (standing seeded-bug rule).
