#!/usr/bin/env bash
#
# check-threads.sh - the per-piece subagent THREAD resume handles are valid (0.5.0 thread continuity).
#
# When the orchestrator resumes a worker's thread for a rework, or a reviewer's thread for a re-review,
# the resume handle stored in port/claims/<id>.yaml (`threads: {worker, reviewer}`) must be the opencode
# SESSION id (`ses_...`), and no id may be reused across (piece, role). This guards two failure modes:
#   - a COMPOSED display name (kha-worker-<unit>-<date>) stored as a handle - it COLLIDES across split
#     work, so resuming it would land in the wrong thread;
#   - one session id under two (piece, role) keys - resuming a WORKER's thread as the REVIEWER's would
#     hand the reviewer the author's context (an independence breach).
# The handles are operational (the local, gitignored claim), retired with the claim at integration; the
# committed fragment still carries reviewer_id != author_id for the fidelity audit. See
# docs/dev/0.5.0-thread-continuity.md and tools/coordination/thread_ledger.py.
#
# Before any claim has a `threads` block (single-operator / pre-dispatch) there is nothing to check, so
# it is GREEN with zero recorded handles; if there is no claims dir at all it skips. Either way it is not
# RED. Fixtures/tests pass --claims-dir DIR.
#
# Exit-code contract:
#   0  GREEN       all handles are ses-form, distinct per (piece, role), no cross-reuse (or none yet)
#   1  RED         a non-ses handle, a cross-(piece, role) reuse, or a malformed claim
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / git)
set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-threads: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-threads: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-threads: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/thread_ledger.py" --check "$@"
