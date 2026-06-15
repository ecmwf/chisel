# SEEDED-BUG DEMONSTRATION - conformance/check-contributors

- Date: 2026-06-16 (new detector, WS-I: contributor identity / anti-aliasing)
- Detector: tools/conformance/check-contributors.sh (wraps tools/coordination/check_contributors.py)
- Failure class targeted: independence is the trust core of the review - a piece is gated only
  when an INDEPENDENT reviewer (a different person, in a different session) signs off. The
  status-fragment check enforces only SYNTACTIC independence: `reviewer_id != author_id` and
  `reviewer_session not in author_sessions`. That is defeated by ALIASING (one human registers
  two ids and "reviews" their own work, even spelling the same human two ways), by COLLUSION
  (a reviewer working in the author's session), and by MALFORMED identity fields that a string
  comparison treats as absent. It also cannot notice an id/session that belongs to nobody
  registered. The contributor registry (port/contributors.yaml) names the underlying HUMAN and
  the sessions behind each id; this check resolves every fragment/claim identity against it.
- Exit-code contract: 0 GREEN (every identity resolves and every review is between distinct
  humans, or there is no registry yet), 1 RED (an id/session is malformed, unregistered,
  mis-owned, or a review was not independent), 2 UNRELIABLE (no python3 / PyYAML / git; an
  explicit `--registry`/`--status-dir`/`--claims-dir` that is missing or the wrong type).

Identity values are compared by a CANONICAL key (Unicode NFC, trimmed, casefolded) and must be
strings. The registry is read from port/contributors.yaml (or `--registry`); fragments from
port/status (or `--status-dir`); `--claims-dir` additionally resolves claimants. Shipped GOOD
fixtures: `tools/coordination/fixtures/contributors/` (registry + two well-formed fragments).

## Seeded defects and red proofs

Each defect is a one-field mutation of a good fixture; non-defective siblings stay unflagged.

### REGISTRY (the trust anchor must be consistent and well-typed)

- **One session owned by two contributors:** list `ses-a1` under both `alice` and `bob` -> RED:
  `[FAIL] registry: session 'ses-a1' is registered to both 'alice' and 'bob' (a session belongs to one contributor)`
- **schema_version that is not the integer 1:** `schema_version: true` (YAML bool, and `True == 1`
  in Python) -> RED: `[FAIL] registry: registry schema_version must be the integer 1`
- Also RED: a contributor missing a string `id`/`human`, a duplicate id (compared
  case/space-insensitively), or a duplicate YAML key (strict loader).

### MALFORMED IDENTITY FIELDS (present-but-non-string is RED, never "absent")

- **A non-scalar session:** a gated fragment with `reviewer_session: {borrowed: ses-a1}` -> RED:
  `[FAIL] f-nonscalar: reviewer_session must be a string identity (got dict)`
  (the awk fragment parser treats `{...}` as a non-empty value, so without this a non-scalar
  session would pass BOTH checks; author_id/reviewer_id and author_sessions items are guarded
  the same way.)

### RESOLUTION (ids and sessions must be registered, to the right owner)

- `[FAIL] f-unreg-id: author_id 'mallory' is not in the registry`
- `[FAIL] f-unreg-id: author_session 'ses-m1' is not in the registry`
- `[FAIL] f-wrongowner: author_session 'ses-a1' is registered to 'alice', not author_id 'bob'`
  (a session is owned by exactly one contributor; using another's session is caught even though
  the id and the session are each individually registered.)

### GATED COMPLETENESS (independence must be checkable)

- A gated fragment with `author_id: null` and empty `author_sessions` -> RED:
  - `[FAIL] f-gated-missing: a gated fragment needs a string author_id`
  - `[FAIL] f-gated-missing: a gated fragment needs a non-empty author_sessions`
  (so independence cannot be skipped by nulling a field; a string reviewer_id/reviewer_session
  are required the same way.)

### INDEPENDENCE (author and reviewer must be DISTINCT humans) - the crux

Both pass the syntactic fragment check (`reviewer_id != author_id`), yet:
- **Aliased reviewer:** `alice` authors, `alice2` reviews, both mapped to `human: person-alice`
  -> RED:
  - `[FAIL] f-alias: author 'alice' and reviewer 'alice2' are the same human 'person-alice' (aliased ids - not an independent review)`
  - `[FAIL] f-alias: reviewer_session 'ses-a3' belongs to the author's human 'person-alice' (not an independent review)`
- **Same human spelled two ways:** the registry maps `alice` to `human: "Person-Alice"` and
  `alice2` to `human: " person-alice "`; canonicalization unifies them -> RED:
  - `[FAIL] f-casealias: author 'alice' and reviewer 'alice2' are the same human 'person-alice' (aliased ids - not an independent review)`
- **Reviewer in the author's session:** `alice` authors (`ses-a1`), `bob` reviews but the
  recorded `reviewer_session` is `ses-a2`, owned by `alice` -> RED:
  - `[FAIL] f-revses-author: reviewer_session 'ses-a2' is registered to 'alice', not reviewer_id 'bob'`
  - `[FAIL] f-revses-author: reviewer_session 'ses-a2' belongs to the author's human 'person-alice' (not an independent review)`

### CLAIMS (`--claims-dir`)

- A claim with `claimant: {name: mallory}` -> RED:
  `[FAIL] claim c-badclaimant: claimant must be a string identity (got dict)`
  (a string-but-unregistered claimant is reported as `not in the registry`.)

### INVOCATION GUARDS (UNRELIABLE, exit 2 - distinct from RED)

- an explicit `--status-dir` that is not a directory -> `--status-dir '...' is not a directory`;
- an explicit `--registry` / `--claims-dir` that is missing or the wrong type; a default
  `port/contributors.yaml` that EXISTS but is not a regular file (e.g. a directory) -> exit 2,
  not a silent "no registry" skip.

## Green proof (defect removed)

- The shipped good fixtures (three distinct humans; `alice` authored + `bob` reviewed the gated
  `m001`; `carol` authored the unreviewed `m002`): GREEN, exit 0 -
  `registry of 3 contributor(s); checked 2 fragment(s); 0 violation(s)`.
- The base repo with no `port/contributors.yaml`: GREEN, exit 0 - `no registry ... skipping`; a
  single-operator pilot that has not adopted a registry is never blocked (the syntactic fragment
  check still applies).

## Causal proof (the check is what catches it)

A fragment passes only when its author/reviewer ids are registered strings, every session it
names is a registered string owned by the id that used it, and - for a reviewed/gated piece -
the author's human and the reviewer's human (compared canonically) differ and the reviewer's
session is not owned by the author's human. Map a second id to the author's human (however
spelled), borrow the author's session, or smuggle a non-string field, and the verdict moves
GREEN -> RED on that fragment. "Independent" therefore means "between two registered humans,"
not "two different strings in two fields."

## Scope / non-defect signals confirmed

- Canonical comparison (NFC + trim + casefold) on ids, humans, and sessions: the same human or
  session cannot be spelled two ways to look distinct, and ids differing only by case/space are
  rejected as duplicates. Comparison is on the `human` key, never the id string, so a legitimately
  distinct reviewer is never flagged and renaming an id does not evade the check.
- Two ids with the SAME human may coexist in the registry (a person can have two ids); the
  violation is raised only when they appear as author AND reviewer of the same piece.
- An unreviewed fragment (reviewer_id null) resolves only its author; no independence check
  applies, so it is not falsely flagged (good fixture `m002`).
- The registry is the OPT-IN charter artifact: a truly-absent default registry skips (GREEN) and
  only the syntactic fragment check applies - by design, documented, not a silent pass of a
  present registry (a present-but-non-file registry is exit 2).
- Trust boundary (honest): this enforces the distinctness the registry DECLARES and defeats
  accidental/spelling aliasing; it cannot prove a human did not register two distinct `human`
  keys. The registry is human-curated and reviewed like any protected surface.

## Comparison-logic version

The logic is: `load_registry` validates the registry (integer schema_version, string id/human,
unique canonical ids, one owner per canonical session) and builds {id->human, session->owner}
on canonical keys; per fragment `verify_identity` requires string identity fields (and full
identity on a gated piece), resolves author/reviewer ids and sessions against the index
(unregistered/mis-owned -> RED), and compares the canonical `human` of author vs reviewer and of
the reviewer_session's owner (equal -> RED); claimants resolve the same way. Empty violation list
-> GREEN, any violation -> RED, a bad environment/path -> UNRELIABLE. Re-run this demonstration
after any change to the registry schema, the canonicalization, the resolution rules, or the
independence comparison (standing seeded-bug rule): every listed defect must go RED and the good
fixtures stay GREEN.
