#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

#
# check-completeness.sh - TRACE accounts for every SOURCE unit the dependency map knows.
#
# The drift check (check-trace-drift.sh) proves the canonical TRACE matches the fragments that
# EXIST; it cannot see a fragment that is MISSING. Since TRACE is generated from whatever
# fragments are present, a SOURCE unit with no fragment is simply absent from TRACE and nothing
# flags it - a whole module can drop out of the trust accounting with every other check green.
# The dependency map (tools/scoping/dependency-map.yaml, drift-checked by check-depmap.sh) is the
# canonical SOURCE inventory; this check requires every map node to have a TRACE row (unmapped,
# in-progress, proven, or excluded - an unstarted unit is `unmapped`, not absent). Reverse direction:
# every TRACE row must correspond to a real map node EXCEPT a declared assembly row in
# tools/scoping/assemblies.yaml, which is accepted only when every declared member is a real map
# node (no phantom/empty-member smuggling). A row is identified by its `id`, or - a hand-written
# row in the TRACE template's shape, which has none - by the map node its `source` names. A unit
# claimed by two rows (or an id carried by two map nodes) is RED, never silently collapsed, and a
# row with an `id` must name the same `source` as that unit's map node (a row relabelled onto
# another file does not account for its unit). A thin wrapper over
# tools/coordination/check_completeness.py. Until both the map and the generated TRACE exist there
# is nothing to compare, so it skips.
#
# Exit-code contract:
#   0  GREEN       every SOURCE unit has a TRACE row and every row is a real unit or valid assembly
#   1  RED         missing SOURCE row, non-unit TRACE row (incl. an id-less row naming no unit),
#                  duplicate unit or id, a row bound to another file, or invalid assembly membership
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / git / malformed input)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-completeness: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-completeness: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-completeness: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/check_completeness.py" "$@"
