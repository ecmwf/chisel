#!/usr/bin/env bash
# check-completeness joins the SOURCE inventory (dependency-map nodes) to TRACE rows. A row is
# identified by its `id` (generated rows carry one) or, in the hand-written TRACE template's shape,
# which has no `id`, by the map node whose `source` it names. A join on a SET of ids is blind to two
# defects a bad merge or a hand edit produces:
#   - a DUPLICATED unit: two rows (or two map nodes) claim one unit, and the set silently keeps one,
#     so the census stays green while the rows disagree about the unit's status;
#   - a RELABELLED row: a row keeps a unit's id but its `source` names another unit's file, so the
#     unit is counted as accounted for while no row describes its file.
# Each case drives the real check on a throwaway map + TRACE (+ assemblies registry) and asserts the
# verdict; the assembly exemption, a harmless path spelling, and the template's id-less rows must
# stay GREEN.
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
expect 0 "RESULT: GREEN" "a complete, correctly bound TRACE is GREEN" \
	--map "$TMP/map.yaml" --trace "$TMP/ok.yaml" --assemblies "$none"

trace "$TMP/spelled.yaml" alpha:./alpha.f90 beta:sub//beta.f90
expect 0 "RESULT: GREEN" "a source spelled differently but naming the same file is GREEN" \
	--map "$TMP/map.yaml" --trace "$TMP/spelled.yaml" --assemblies "$none"

trace "$TMP/dup-trace.yaml" alpha:alpha.f90 alpha:alpha.f90 beta:sub/beta.f90
expect 1 "TRACE has 2 rows for unit 'alpha'" "a duplicated TRACE id is RED" \
	--map "$TMP/map.yaml" --trace "$TMP/dup-trace.yaml" --assemblies "$none"

cp "$TMP/map.yaml" "$TMP/dup-map.yaml"
printf '  - id: beta\n    source: sub/beta.f90\n' >>"$TMP/dup-map.yaml"
expect 1 "dependency map has 2 nodes with id 'beta'" "a duplicated map id is RED" \
	--map "$TMP/dup-map.yaml" --trace "$TMP/ok.yaml" --assemblies "$none"

trace "$TMP/relabel.yaml" alpha:sub/beta.f90 beta:sub/beta.f90
expect 1 "TRACE row 'alpha' source 'sub/beta.f90' does not match" \
	"a row whose source is another unit's file is RED" \
	--map "$TMP/map.yaml" --trace "$TMP/relabel.yaml" --assemblies "$none"

trace "$TMP/elsewhere.yaml" alpha:alpha_old.f90 beta:sub/beta.f90
expect 1 "TRACE row 'alpha' source 'alpha_old.f90' does not match" \
	"a row whose source is not its unit's file is RED" \
	--map "$TMP/map.yaml" --trace "$TMP/elsewhere.yaml" --assemblies "$none"

printf 'meta:\n  source_root: source/\nfiles:\n  - id: alpha\n    status: unmapped\n  - id: beta\n    source: sub/beta.f90\n    status: unmapped\n' \
	>"$TMP/nosource.yaml"
expect 1 "TRACE row 'alpha' source '' does not match" "a unit row with no source is RED" \
	--map "$TMP/map.yaml" --trace "$TMP/nosource.yaml" --assemblies "$none"

cat >"$TMP/assemblies.yaml" <<'EOF'
assemblies:
  - id: bundle
    members: [alpha, beta]
EOF
trace "$TMP/assembly.yaml" alpha:alpha.f90 beta:sub/beta.f90 bundle:alpha.f90
expect 0 "1 declared assembly row(s) accepted" \
	"a declared assembly row is still exempt, whatever source it names" \
	--map "$TMP/map.yaml" --trace "$TMP/assembly.yaml" --assemblies "$TMP/assemblies.yaml"

# ---- the hand-written TRACE template's own shape: rows keyed by `source`, no `id` ----------------
TEMPLATE="$ROOT/.opencode/skill/code-port/assets/TRACE.template.yaml"
ROW1='source: <path/relative/to/source_root.F90>'
ROW2='source: <unused/module.F90>'
grep -qF "$ROW1" "$TEMPLATE" && grep -qF "$ROW2" "$TEMPLATE" \
	|| failt "the TRACE template's row placeholders changed - update this test"

# template <file> <first-row source> <second-row source>: the template with its two rows filled in.
template() {
	sed -e "s|$ROW1|source: $2|" -e "s|$ROW2|source: $3|" "$TEMPLATE" >"$1"
}

template "$TMP/tpl.yaml" alpha.f90 sub/beta.f90
python3 - "$TMP/tpl.yaml" <<'PY' || failt "the template's rows carry an id - keep an id-less case here"
import sys, yaml
rows = yaml.safe_load(open(sys.argv[1]))["files"]
sys.exit(0 if len(rows) == 2 and not any("id" in r for r in rows) else 1)
PY
expect 0 "RESULT: GREEN" "template shape: a complete id-less TRACE is GREEN" \
	--map "$TMP/map.yaml" --trace "$TMP/tpl.yaml" --assemblies "$none"

template "$TMP/tpl-spelled.yaml" ./alpha.f90 sub//beta.f90
expect 0 "RESULT: GREEN" "template shape: a source spelled differently is still its unit" \
	--map "$TMP/map.yaml" --trace "$TMP/tpl-spelled.yaml" --assemblies "$none"

template "$TMP/tpl-dup.yaml" alpha.f90 ./alpha.f90
expect 1 "TRACE has 2 rows for unit 'alpha'" "template shape: two rows naming one unit's file are RED" \
	--map "$TMP/map.yaml" --trace "$TMP/tpl-dup.yaml" --assemblies "$none"

template "$TMP/tpl-gone.yaml" alpha.f90 gone.f90
expect 1 "TRACE row #2 has no id and its source 'gone.f90' is no SOURCE unit" \
	"template shape: a row naming no unit's file is RED" \
	--map "$TMP/map.yaml" --trace "$TMP/tpl-gone.yaml" --assemblies "$none"

template "$TMP/tpl-mixed.yaml" alpha.f90 sub/beta.f90
printf '  - id: alpha\n    source: alpha.f90\n    status: unmapped\n' >>"$TMP/tpl-mixed.yaml"
expect 1 "TRACE has 2 rows for unit 'alpha'" \
	"template shape: an id-less row and an id row for one unit are RED" \
	--map "$TMP/map.yaml" --trace "$TMP/tpl-mixed.yaml" --assemblies "$none"

template "$TMP/tpl-assembly.yaml" alpha.f90 sub/beta.f90
printf '  - id: bundle\n    source: alpha.f90\n    status: unmapped\n' >>"$TMP/tpl-assembly.yaml"
expect 0 "1 declared assembly row(s) accepted" \
	"template shape: a declared assembly row beside id-less rows is GREEN" \
	--map "$TMP/map.yaml" --trace "$TMP/tpl-assembly.yaml" --assemblies "$TMP/assemblies.yaml"

printf 'files:\n  - id: alpha\n    source: alpha.f90\n  - id: beta\n    source: sub/beta.f90\n  - status: unmapped\n' \
	>"$TMP/anonymous.yaml"
expect 1 "TRACE row #3 has neither an id nor a source" "a row with neither an id nor a source is RED" \
	--map "$TMP/map.yaml" --trace "$TMP/anonymous.yaml" --assemblies "$none"
