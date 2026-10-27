#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

#
# check-status-fragments.sh - validate the per-work-item status fragments.
#
# In a many-contributor port, each work item's status lives in its own branch as
# port/status/<trace-id>.yaml (shard-and-generate; see references/team-coordination.md),
# and the canonical TRACE is generated from these. This check validates a fragment
# BEFORE it feeds the generator, fail-closed, so a malformed or independence-violating
# fragment never silently corrupts canonical status or defeats independent review.
#
# It checks, per fragment, on the YAML data the TRACE generator reads (lib/status_fragments.py:
# the shared strict loader, every scalar kept as written, the old vocabulary mapped by modern()), so
# an alias is the value it points to and a list reads the same in block or flow form:
#   - the YAML is valid and a known subset: no duplicate keys, no unknown keys, at most two levels
#     (a section such as ownership: holds scalars or lists of scalars) (fail-closed);
#   - enums: status {unmapped,in-progress,proven,excluded}; ownership.kind {owned,leaf};
#     claim.state {created,active,stale}; integration.state {proven,integrated};
#   - status-dependent required fields (an excluded row needs only a reason; an
#     in-progress row needs target/claim; a proven row needs target/claim/author_id - a
#     dispatched worker cannot see its own session id, so author_id stays null until the
#     orchestrator records it from the worker's subagent result);
#   - claim.ref, when set, names this unit's own claim: port/claims/<id>.yaml or refs/claims/<id>;
#   - a set author_id equals the worker session the local claim port/claims/<id>.yaml records
#     under threads.worker. The orchestrator writes both from the same subagent result, so a mismatch
#     is an identity that did not come from the dispatch. The claim is local and gitignored -
#     absent in CI and once released - so an absent claim, or one with no recorded worker, is not
#     checked; a claims ledger that thread_ledger.py refuses (an unreadable claim, a non-session or
#     shared worker thread) is RED;
#   - proven => a real, INDEPENDENT review: reviewer_id set and != author_id;
#     reviewer_session set and NOT in author_sessions; author_sessions non-empty; a
#     tier-R1+ proof with evidence and a review report. (The syntactic check; the independence
#     control is the reviewer agent dispatched on a different model - there is no identity registry.)
#   - integrated => status proven, product.main_commit set.
#
# Exit-code contract:
#   0  GREEN       every fragment is well-formed (or there are none)
#   1  RED         at least one fragment violates the schema
#   2  UNRELIABLE  detector could not run (missing tooling - git, python3 with PyYAML - or not a
#                  git repo)

set -uo pipefail

command -v git >/dev/null 2>&1 || { echo "check-status-fragments: git not found" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

EXPLICIT_FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) echo "Usage: check-status-fragments.sh [fragment.yaml ...]"; exit 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do EXPLICIT_FILES+=("$1"); shift; done ;;
        -*) echo "check-status-fragments: unknown option: $1" >&2; exit 2 ;;
        *) EXPLICIT_FILES+=("$1"); shift ;;
    esac
done

ORIG_PWD="$PWD"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-status-fragments: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || { echo "check-status-fragments: cannot enter repo root '${ROOT}'" >&2; exit 2; }

FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
    for f in "${EXPLICIT_FILES[@]}"; do
        case "$f" in /*) FILES+=("$f") ;; *) FILES+=("$ORIG_PWD/$f") ;; esac
    done
else
    while IFS= read -r f; do FILES+=("$f"); done \
        < <(find port/status -type f -name '*.yaml' ! -name '_meta.yaml' 2>/dev/null | sort)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "check-status-fragments: no fragments under port/status/ - nothing to check (skipping)."
    exit 0
fi

command -v python3 >/dev/null 2>&1 \
    || { echo "check-status-fragments: python3 not found - cannot read the fragments (UNRELIABLE)" >&2; exit 2; }
# The rules run on each fragment's loaded YAML data (lib/status_fragments.py), the data the TRACE
# generator reads; the helper prints the report and exits with the contract above.
exec python3 "$HERE/lib/status_fragments.py" "${FILES[@]}"
