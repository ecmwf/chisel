# SEEDED-BUG DEMONSTRATION - conformance/check-threads

- Date: 2026-06-22 (new detector, 0.5.0: subagent thread-continuity resume handles)
- Detector: tools/conformance/check-threads.sh (wraps tools/coordination/thread_ledger.py --check)
- Failure class targeted: a per-piece subagent resume handle that would CROSS threads. When the
  orchestrator resumes a worker's thread for a rework or a reviewer's thread for a re-review, the handle
  in `port/claims/<id>.yaml` (`threads: {worker, reviewer}`) must be the opencode SESSION id (`ses_...`)
  and unique per `(piece, role)`. Two ways it goes wrong:
    1. a COMPOSED display name (`kha-worker-<unit>-<date>`) stored as a handle - it COLLIDES across split
       work (two sub-pieces of one unit on the same day share the name), so resuming it lands in the
       WRONG thread;
    2. one session id under two `(piece, role)` keys - resuming a WORKER's thread as the REVIEWER's hands
       the reviewer the author's context, breaking independence.
- Exit-code contract: 0 GREEN (all handles ses-form, distinct per (piece, role), no cross-reuse, or none
  recorded yet), 1 RED (a non-ses handle / a cross-(piece, role) reuse / a malformed claim), 2 UNRELIABLE
  (no python3/PyYAML/git).

The resume handle is the `ses_` session id captured from the subagent result - it is UNIQUE per dispatch
(empirically: two identically-NAMED workers still get distinct ses ids and resume to their own thread;
see docs/dev/0.5.0-thread-continuity.md). The composed name is at most a non-key label. The handles are
operational (the local, gitignored claim, retired with the claim at integration); the committed fragment
keeps `reviewer_id != author_id` for the fidelity audit.

## Shipped GOOD fixture

`tools/coordination/fixtures/threads/good/` - three claims: `module_a` (worker + reviewer ses ids),
`module_b` (worker only), and `module_b_part2` (a SPLIT sub-piece with its OWN id and OWN distinct ses
ids - its composed display name would collide with module_b's, the ses id does not). GREEN: `5 recorded
thread id(s) across 5 (piece, role) key(s); all ses-form, distinct per (piece, role), no cross-reuse.
RESULT: GREEN`.

## Seeded defects and red proofs (against the GOOD fixture, restored after each)

- **Cross-(piece, role) reuse (the independence breach):** add a claim `ghost` with
  `threads.reviewer: ses_aaa111worker` - the SAME id already recorded as `module_a`'s worker thread -> RED,
  exit 1: `session id 'ses_aaa111worker' is recorded under BOTH ('ghost', 'reviewer') and ('module_a',
  'worker') - one thread cannot be two (piece, role)s ...`. Resuming it for the reviewer would hand the
  reviewer the author's context.
- **Composed-name handle (the split-work collision):** a claim with
  `threads.worker: kha-worker-module_a-20260622` -> RED, exit 1: `... is not a session id (must match
  ses_<alnum>); a composed name like kha-worker-<unit>-<date> COLLIDES across split work and must never be
  a resume key`.
- **`record` refuses the same defects at write time** (so a bad handle never reaches a committed claim):
  `thread_ledger.py record <id> --role reviewer --session-id <a composed name>` -> exit 1; `record` an id
  already bound to a different (piece, role) -> exit 1.
- **`resume` refuses at the POINT OF USE** (defense in depth - it does not trust that `--check` ran):
  with `a.yaml threads.worker: ses_same` and `b.yaml threads.reviewer: ses_same`, `resume b --role
  reviewer` -> exit 1 (it validates the whole dir first and REFUSES rather than printing the cross-reused
  id), so a worker's thread can never be resumed as the reviewer's. The orchestrator treats ANY non-zero
  `resume` exit as "dispatch fresh", so a refusal degrades safely.

## Green / skip proofs

- The GOOD fixture: GREEN, exit 0.
- The base repo / any repo with claims but no `threads` block in any of them (single-operator,
  pre-dispatch): GREEN, exit 0 - `0 recorded thread id(s) ... RESULT: GREEN` (nothing recorded yet). With
  no claims dir at all it also exits 0, printing that it is skipping. Either way it is never RED.
- `resume <id> --role <r>` with no recorded thread exits 3 -> the orchestrator dispatches FRESH (graceful
  fallback, never a halt, never a silent skip of the work).

## Scope / non-defect signals confirmed

- A SPLIT sub-piece with its own trace-id and its own ses ids is GREEN - splitting work is fine; only a
  shared NAME-as-handle or a shared id across roles is the defect.
- Re-run this demonstration after any change to `thread_ledger.py`'s `SES_RE`, the `_scan` cross-reuse
  invariant, or the `threads` schema (standing seeded-bug rule): the cross-reuse and composed-name defects
  must stay RED and the GOOD fixture GREEN.
