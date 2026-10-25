#!/usr/bin/env bash
# check-completeness joins the SOURCE inventory (dependency-map nodes) to TRACE rows by id. A join on
# a SET of ids is blind to a DUPLICATED id - two rows (or two map nodes) claiming one unit, the kind
# of defect a bad merge or a hand edit produces: the set silently keeps one, so the census stays
# green while the rows disagree about the unit's status.
# Each case drives the real check on a throwaway map + TRACE (+ assemblies registry) and asserts the
# verdict; the assembly exemption must stay GREEN.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/coordination/check_completeness.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
failt() { printf 'not ok - %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }

cat >"$TMP/map.yaml" <<'EOF'
schema_version: 1
source_root: source/
nodes:
  - id: alpha
    source: alpha.f90
  - id: beta
    source: sub/beta.f90
EOF

# trace <file> <id:source>...: write a TRACE with one row per pair.
trace() {
	local f="$1" pair
	shift
	printf 'meta:\n  source_root: source/\nfiles:\n' >"$f"
	for pair in "$@"; do
		printf '  - id: %s\n    source: %s\n    status: unmapped\n' "${pair%%:*}" "${pair#*:}" >>"$f"
	done
}

# expect <exit> <needle> <label> <args...>: run the check; assert the exit code and a needle in the output.
expect() {
	local want="$1" needle="$2" label="$3" out rc
	shift 3
	set +e
	out="$(python3 "$CHECK" "$@" 2>&1)"
	rc=$?
	set -e
	[ "$rc" = "$want" ] || failt "$label (expected exit $want, got $rc)" "$out"
	case "$out" in *"$needle"*) ;; *) failt "$label (output lacks '$needle')" "$out" ;; esac
	pass "$label"
}

none="$TMP/no-assemblies.yaml"

trace "$TMP/ok.yaml" alpha:alpha.f90 beta:sub/beta.f90
expect 0 "RESULT: GREEN" "a complete TRACE is GREEN" \
	--map "$TMP/map.yaml" --trace "$TMP/ok.yaml" --assemblies "$none"

trace "$TMP/dup-trace.yaml" alpha:alpha.f90 alpha:alpha.f90 beta:sub/beta.f90
expect 1 "TRACE has 2 rows with id 'alpha'" "a duplicated TRACE id is RED" \
	--map "$TMP/map.yaml" --trace "$TMP/dup-trace.yaml" --assemblies "$none"

cp "$TMP/map.yaml" "$TMP/dup-map.yaml"
printf '  - id: beta\n    source: sub/beta.f90\n' >>"$TMP/dup-map.yaml"
expect 1 "dependency map has 2 nodes with id 'beta'" "a duplicated map id is RED" \
	--map "$TMP/dup-map.yaml" --trace "$TMP/ok.yaml" --assemblies "$none"

cat >"$TMP/assemblies.yaml" <<'EOF'
assemblies:
  - id: bundle
    members: [alpha, beta]
EOF
trace "$TMP/assembly.yaml" alpha:alpha.f90 beta:sub/beta.f90 bundle:alpha.f90
expect 0 "1 declared assembly row(s) accepted" "a declared assembly row is still exempt" \
	--map "$TMP/map.yaml" --trace "$TMP/assembly.yaml" --assemblies "$TMP/assemblies.yaml"
