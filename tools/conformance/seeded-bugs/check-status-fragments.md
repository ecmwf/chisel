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
  2 UNRELIABLE (no tooling - git, python3 with PyYAML - / not a git repo).

The detector reads each fragment as YAML data with the strict loader the TRACE generator uses
(`tools/conformance/lib/status_fragments.py`: repeated keys rejected and named with their section,
every scalar kept as written, old vocabulary mapped by `modern()`), checks it against a closed
two-level schema (unknown keys and deeper nesting rejected) and applies status-dependent rules. Command: `bash tools/conformance/check-status-fragments.sh
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
- **Proof tier / binding:** `proof.tier: R0` on a proven row -> RED: `R0 cannot prove`. Missing
  `proof.commit` (the product commit the proof ran against), `proof.evidence`, or
  `review.evidence` on a proven row -> RED, one per missing field.
- **Target shape:** `target` set as a bare scalar (`target: a.c`) instead of a list
  (`target: [a.c]`) -> RED: `target must be a list` (the TRACE generator requires a list).
- **Owner names a surface:** `ownership.kind: owned` without `ownership.workstream`, or
  without `ownership.owned_surface` -> RED, one per missing field.
- **Parser fail-closed - duplicate key:** two `status:` lines (`done` then `proven`) ->
  RED: `duplicate key 'status'`; a repeated key in a section is named with it (`duplicate key
  'claim.claimant'`). (Pre-hardening the valid duplicate silently won and the fragment passed.) A
  fragment that holds one block under its old and its new name -> RED: `duplicate key: both ... are
  set`.
- **Parser fail-closed - unknown key:** a `bogus_key:` -> RED: `unknown key 'bogus_key'`.
- **Enums:** `status: done`, `claim.state: spinning`, `integration.state: merged`,
  `proof.validation: bogus` -> RED, one per invalid enum. (`proof.validation` accepts only
  `transitive` or null - the declaration-only marker the planner reads to PARK a unit that
  has no behavior to differentially test in isolation; null = a normal unit proven at R1+.)
- **Integration consistency:** `integration.state: integrated` without
  `product.main_commit` -> RED; `integrated` with `status`
  other than `proven` -> RED; ANY non-null `integration.state` (e.g. `staged`) while
  `status` is not `proven` -> RED (a piece integrates only after it is proven).
- **Status-dependent required:** an `in-progress` row missing `target`/`claim.*` -> RED naming
  each; a `proven` row missing any of those or `author_id` -> RED naming each.
- **Null author_id while in-progress:** an `in-progress` row with `author_id: null` is GREEN. A
  dispatched worker cannot see its own session id; the orchestrator records `author_id` from the
  worker's Task result. Requiring it on an in-progress row (as the check once did) REDs the expected
  state and pushes a worker to invent an identity to get the check green. The same row with
  `status: proven` -> RED: `status 'proven' requires 'author_id'`. Automated in
  `tools/tests/test-status-fragment-identity.sh`.
- **Claim of another unit:** fragment `id: u3` citing `claim.ref: port/claims/u9.yaml` -> RED:
  `claim.ref 'port/claims/u9.yaml' is not this unit's claim`, with or without an `author_id`; the
  same for a pushed ref `refs/claims/u9`. A fragment copied from a sibling keeps the sibling's claim
  and so binds itself to a reservation that does not cover it. The unit's own
  `port/claims/<id>.yaml` or `refs/claims/<id>` is GREEN. Automated in the same test.
- **author_id not from the dispatch:** `author_id: ses_typedByHand` while the local claim
  `port/claims/<id>.yaml` records `threads: {worker: ses_workerA1}` -> RED: `author_id ... does not
  match the worker session 'ses_workerA1' recorded in port/claims/<id>.yaml threads.worker`. The
  orchestrator writes both from the same Task result, so a mismatch is an identity typed by hand,
  guessed by the worker, or pasted from another unit. Only `threads.worker` counts: a stray
  top-level `worker:` key in the claim is ignored, so an `author_id` matching only that key is RED
  against the recorded `threads.worker`. The claim is read through `thread_ledger.py resume`, which
  validates the whole claims dir first, so a claim it cannot read (a duplicate key, `threads` not a
  mapping), a worker thread that is not a session id (even one equal to `author_id`), or a session
  recorded as the worker of two pieces -> RED: `the claims ledger cannot vouch for author_id`. With
  python3/PyYAML unavailable and a claim present -> UNRELIABLE (exit 2), never a pass. GREEN when
  they match (block or flow style), and - because the claim is local and gitignored, absent in CI
  and once released - when the claim is absent, records no `threads`, records no `worker`, or the
  `author_id` is null. Automated in the same test.

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
  first step. Since the fragment is read as YAML data, an inline list is the same list as a block
  one.
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
- Lists (`author_sessions`, `depends_on`, `consumes_contracts`, `target`) are read as YAML data:
  block `- item` and inline `[a, b]` are the same list, as for the TRACE generator.

## Reading the fragment as YAML data (2026-10-26)

The check used to parse each fragment with awk, line by line, while the TRACE generator loads it
with PyYAML. The two disagreed, and the check was wrong each time:

| Fragment | awk parser | YAML data (now) |
|---|---|---|
| `author_id: &w ses_A1`, `reviewer_id: *w` (proven) | text differs: GREEN | same id: RED, `reviewer_id == author_id` |
| `author_sessions: [ses_A1, ses_R2]` with `reviewer_session: ses_R2` | inline list empty: RED for the wrong reason | RED: `appears in author_sessions` |
| `author_sessions: [ses_A1]` (proven) | inline list empty: RED | GREEN |
| `target:` as a block list | `unknown list key 'target'`: RED | GREEN (the generator accepts it) |
| `target: "[a.c]"` (a quoted string) | looks like a list: GREEN | RED: `target must be a list` |
| `notes: \|` whose lines read `reason: ...` | `unknown key 'notes.reason'`: RED | GREEN (it is text) |
| `proof.evidence:` holding a mapping (proven) | nested lines ignored: RED `requires proof.evidence` | RED: `nests deeper than the fragment schema allows` |
| `bogus_key:` with no value | ignored: GREEN | RED: `unknown key 'bogus_key'` |
| a tab-indented, invalid file | read in part: RED for missing fields | RED: `is not valid YAML` |

Python with PyYAML is now needed to read any fragment, so without it a fragment is UNRELIABLE
(exit 2) even when no claim sits beside it; the line parser had passed such a fragment. Automated
in `tools/tests/test-status-fragment-data.sh` (8 of 11 cases fail against the awk parser) and
`tools/tests/test-status-fragment-identity.sh` (the alias and no-PyYAML cases; 2 fail against it).
Every earlier arm keeps its verdict and message, apart from the `(block list)` note on the
non-empty `author_sessions` rule, which now says `(list)`.

## Comparison-logic version

The comparison logic is: the fragment read as YAML data by the shared strict loader (scalars as
written, `modern()` for the old vocabulary; duplicate keys named with their section; unknown keys
and nesting below a section rejected against the known schema; lists in either form); the status/
ownership/claim/integration enums; `target` must be a list when set; `ownership.kind:
owned` requires both `workstream` and `owned_surface`; status-dependent required fields
(`author_id` only once `proven`); `claim.ref`, when set, is `port/claims/<id>.yaml` or
`refs/claims/<id>` for the fragment's own `id`; a set `author_id` equals the `threads.worker` of
a present local claim `port/claims/<id>.yaml` that records one (read through `thread_ledger.py
resume`, which validates the whole claims dir; a ledger it refuses is RED, no PyYAML UNRELIABLE);
a non-null `integration.state` requires `status: proven`; and - the fidelity invariant -
on `proven`: a tier-R1+ proof with a `proof.commit`, proof evidence, and a review report, and
an independent reviewer (`reviewer_id != author_id`, `reviewer_session not in
author_sessions`, non-empty `author_sessions`); on `integrated`: `status: proven` plus
`product.main_commit`. Re-run this demonstration after any
change to the schema or these rules (standing seeded-bug rule).
