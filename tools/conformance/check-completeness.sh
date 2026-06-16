#!/usr/bin/env bash
#
# check-completeness.sh - TRACE accounts for every SOURCE unit the dependency map knows.
#
# The drift check (check-trace-drift.sh) proves the canonical TRACE matches the fragments that
# EXIST; it cannot see a fragment that is MISSING. Since TRACE is generated from whatever
# fragments are present, a SOURCE unit with no fragment is simply absent from TRACE and nothing
# flags it - a whole module can drop out of the trust accounting with every other check green.
# The dependency map (tools/scoping/dependency-map.yaml, drift-checked by check-depmap.sh) is the
# canonical SOURCE inventory; this gate requires every map node to have a TRACE row (unmapped,
# in-progress, gated, or excluded - an unstarted unit is `unmapped`, not absent) and every TRACE
# row to correspond to a real map node. A thin wrapper over tools/coordination/check_completeness.py.
# Until both the map and the generated TRACE exist there is nothing to compare, so it skips.
#
# Exit-code contract:
#   0  GREEN       every SOURCE unit has a TRACE row and every row is a real unit (or nothing wired)
#   1  RED         a SOURCE unit is missing from TRACE, or a TRACE row has no SOURCE unit
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / git / malformed input)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-completeness: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-completeness: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-completeness: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/check_completeness.py" "$@"
