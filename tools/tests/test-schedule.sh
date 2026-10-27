#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# schedule.py turns the dependency map and the TRACE into the build schedule, and the autodrive
# planner follows it. The fixture: a integrated, z excluded; b and c use a, d uses b and c; e and f
# use each other, g uses e; h uses x, which nothing defines. SOURCE sizes (lines): b 10, c 50, d 5,
# e 3, f 3, g 100, h 1. Expected: one cycle (e, f); waves [b c e f h] then [d g]; critical path
# e+f -> g (106 lines); priority e f g c b d h; h never ready. By unit count instead of lines, e and f
# still lead, then b, c. The planner claims c before b (priority, not the alphabet) and names the
# cycle; a malformed map is UNRELIABLE.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCHED="$ROOT/tools/coordination/schedule.py"
PLAN="$ROOT/tools/coordination/autodrive.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
check() {
	local name="$1"; shift
	if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name" >&2; failures=$((failures + 1)); fi
}

W="$TMP/wb"
mkdir -p "$W/port/claims" "$W/tools/scoping" "$W/source"
git init -q "$W"
for u in a:1 b:10 c:50 d:5 e:3 f:3 g:100 h:1 z:1; do
	python3 -c 'import sys; print("      x = 1\n" * int(sys.argv[1]), end="")' "${u#*:}" >"$W/source/${u%%:*}.f90"
done
{
	echo "files:"
	echo "  - {id: a, source: source/a.f90, status: proven, integration: integrated}"
	for u in b c d e f g h; do echo "  - {id: $u, source: source/$u.f90, status: pending}"; done
	echo "  - {id: z, source: source/z.f90, status: excluded}"
} >"$W/port/TRACE.yaml"
{
	echo "schema_version: 1"
	echo "source_root: source/"
	echo "nodes:"
	for u in a b c d e f g h z; do
		echo "  - {id: $u, source: $u.f90, role: unowned, self_serve_eligible: true, guarded_reasons: [], coverage: full, provides: []}"
	done
	echo "owned_surfaces: []"
	echo "edges:"
	for e in b:a c:a d:b d:c e:f f:e g:e h:x; do
		echo "  - {from: ${e%%:*}, to: ${e#*:}, kind: call, confidence: proven}"
	done
} >"$W/tools/scoping/dependency-map.yaml"

json() { (cd "$W" && python3 "$SCHED" --json "$@"); }
S="$(json)"
is() { python3 -c "import json,sys; s=json.loads(sys.argv[1]); sys.exit(0 if ($1) else 1)" "$S"; }
check "the cycle is found" is "s['cycles'] == [['e', 'f']]"
check "the waves follow the dependencies" is "s['waves'] == [['b', 'c', 'e', 'f', 'h'], ['d', 'g']]"
check "the critical path is the longest chain by lines" is "s['critical_path'] == [['e', 'f'], ['g']] and s['critical_size'] == 106"
check "the priority puts the critical path first" is "s['priority'] == ['e', 'f', 'g', 'c', 'b', 'd', 'h']"
check "integrated and excluded units are left out" is "'a' not in s['priority'] and 'z' not in s['priority']"
check "a dependency nothing defines is named" is "s['unknown'] == {'h': ['x']}"
S="$(json --weight units)"
check "by unit count, the cycle still leads, then b and c" is "s['priority'][:4] == ['e', 'f', 'b', 'c']"

out="$(cd "$W" && python3 "$SCHED")"
check "the printed schedule names the waves" grep -q '^   2  d, g$' <<<"$out"
check "the printed schedule names the critical path" grep -q '^critical path: e+f -> g$' <<<"$out"

rc=0; out="$(cd "$W" && python3 "$PLAN" --claims-dir "$W/port/claims" 2>&1)" || rc=$?
claims="$(awk '$1 == "claim" {print $2}' <<<"$out" | tr '\n' ' ')"
check "the planner claims by priority, c before b" [ "$claims" = "c b " ]
check "the planner names the cycle" grep -q '^  e, f$' <<<"$out"
check "the planner names the unit that can never be ready" grep -q 'NEVER READY: h depends on x' <<<"$out"

printf 'nodes: {a: 1}\n' >"$W/tools/scoping/dependency-map.yaml"
rc=0; (cd "$W" && python3 "$SCHED") >/dev/null 2>&1 || rc=$?
check "a malformed map is UNRELIABLE" [ "$rc" -eq 2 ]

[ "$failures" -eq 0 ] || { echo "# test-schedule: $failures failure(s)" >&2; exit 1; }
echo "# test-schedule: all assertions passed"
