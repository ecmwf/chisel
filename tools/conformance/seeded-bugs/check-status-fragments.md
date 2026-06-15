# SEEDED-BUG DEMONSTRATION - conformance/check-status-fragments

- Date: 2026-06-15 (new detector, WS-E0; hardened after independent review)
- Detector: tools/conformance/check-status-fragments.sh
- Failure class targeted: a malformed or independence-violating status fragment feeding
  the (generated) canonical TRACE. In a many-contributor port each work item's status
  lives in its own branch as `port/status/<trace-id>.yaml`, and canonical TRACE is
  generated from these. A fragment that is `gated` without a real independent reviewer,
  one whose reviewer shares a session with the author, a duplicate/unknown-key fragment,
  or an `integrated` fragment with no manifest binding would silently corrupt canonical
  status or defeat independent review.
- Exit-code contract: 0 GREEN (all fragments well-formed, or none), 1 RED (a violation),
  2 UNRELIABLE (no tooling / not a git repo).

The detector parses each fragment fail-closed (section-qualified, trimmed, dequoted;
duplicate keys and unknown keys are rejected; lists use block `- item` form) and applies
status-dependent rules. Command: `bash tools/conformance/check-status-fragments.sh
<fragment.yaml>`; the default scans `port/status/*.yaml` EXCEPT `_meta.yaml` (which holds
the TRACE meta block for the generator, not a work item - matching `generate_trace.py`).

## Per-arm red proofs (each fixture isolates the arm under test)

- **Independence - no reviewer on gated:** a `status: gated` fragment with
  `reviewer_id: null`, `reviewer_session: null` -> RED: `gated requires reviewer_id`,
  `gated requires reviewer_session`. (The pre-hardening check passed this - the trust-core
  gap an independent review caught.)
- **Independence - reviewer_id == author_id:** both `alice` -> RED: `reviewer_id ==
  author_id ... independence violated`.
- **Independence - shared session:** `reviewer_session: ses-2` while `author_sessions`
  contains `ses-2` -> RED: `reviewer_session 'ses-2' appears in author_sessions`. This is
  the team-scale form of the existing "reviewer session not in author_sessions" rule.
- **Gate tier:** `gate.tier: R0` on a gated row -> RED: `R0 cannot gate`. Missing
  `gate.evidence` / `review.evidence` on a gated row -> RED.
- **Parser fail-closed - duplicate key:** two `status:` lines (`done` then `gated`) ->
  RED: `duplicate key 'status'`. (Pre-hardening the valid duplicate silently won and the
  fragment passed.)
- **Parser fail-closed - unknown key:** a `bogus_key:` -> RED: `unknown key 'bogus_key'`.
- **Enums:** `status: done`, `claim.state: spinning`, `integration.state: merged` ->
  RED, one per invalid enum.
- **Integration consistency:** `integration.state: integrated` without
  `product.main_commit` and `workbench_manifest` -> RED; `integrated` with `status`
  other than `gated` -> RED.
- **Status-dependent required:** an `in-progress` row missing `target`/`claim.*`/
  `author_id` -> RED naming each.

## Green proof (defect removed)

- A well-formed gated fragment: distinct `author_id`/`reviewer_id`, `reviewer_session`
  not in `author_sessions` (block list, non-empty), `claim.state: active`, `gate.tier:
  R1` with `gate.evidence` and `review.evidence`, `integration.state: gated`: GREEN,
  exit 0. Single-quoted scalars (`status: 'gated'`) and trailing spaces are accepted.
- An `excluded` row with a `notes` reason and minimal fields: GREEN (status-dependent -
  an excluded item is not being ported, so claim/author/review are not required).
- The base repo (no `port/status/`): GREEN, exit 0 (skip). The template
  (`assets/status-fragment.template.yaml`) is the schema, not scanned.

## Scope / non-defect signals confirmed

- Independence here is **syntactic only**: `reviewer_id != author_id` and
  `reviewer_session not in author_sessions`. A single human under two ids
  (`alice-main`/`alice-review`), or team collusion, is NOT caught by the schema - that
  needs a canonical contributor/session identity registry (a charter/project artifact)
  plus a deferred detector that checks ids/sessions against it. Documented, not claimed.
- Lists (`author_sessions`, `depends_on`, `consumes_contracts`) are read in block form;
  inline `[a, b]` is treated as empty (fail-closed for the gated author_sessions rule).

## Comparison-logic version

The comparison logic is: a fail-closed awk parser (trim + dequote; duplicate-key and
unknown-key rejection against the known schema; block-list members); the status/
ownership/claim/integration enums; status-dependent required fields; and - the fidelity
invariant - on `gated`: a tier-R1+ gate with evidence and a review report, and an
independent reviewer (`reviewer_id != author_id`, `reviewer_session not in
author_sessions`, non-empty `author_sessions`); on `integrated`: `status: gated` plus
`product.main_commit` and `workbench_manifest`. Re-run this demonstration after any
change to the schema or these rules (standing seeded-bug rule).
