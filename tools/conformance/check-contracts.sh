#!/usr/bin/env bash
#
# check-contracts.sh - interface contracts between work items are honored.
#
# references/team-coordination.md ("Interface contracts and foundation-change invalidation"):
# two independently proven modules can each pass their own proof while encoding conflicting
# assumptions (layout, units, indexing, halos, init order, precision, IO schema) - a silent
# semantic conflict no merge conflict flags. So shared seams get VERSIONED interface contracts,
# enforced producer-before-consumer (a consumer proofs against a PROVEN producer contract, not a
# moving target), and proof evidence is commit-bound, so a consumer goes STALE when its producer's
# contract moves. Over the per-piece fragments' provides_contract / consumes_contracts, this
# requires every consumed contract to be provided by exactly one PROVEN producer at the consumer's
# current version.
#
# A thin wrapper over tools/coordination/check_contracts.py. Before any fragments exist there is
# nothing to check, so it skips. Fixtures/tests pass --status-dir DIR.
#
# Exit-code contract:
#   0  GREEN       every consumed contract is provided by a proven producer at the current version (or no fragments)
#   1  RED         a consumed contract has no producer, an ungated producer, a stale/nonexistent version, or a forked contract
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / git)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-contracts: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-contracts: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-contracts: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/check_contracts.py" "$@"
