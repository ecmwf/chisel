#!/usr/bin/env bash
# Test the contract of tools/coordination/yaml_get.py, the one YAML reader of the shell tools.
#
# It must read the data the Python tools read, not the text: an alias reads as the value it points
# to, a nested key is not the top-level key, a scalar keeps the text written in the file. A key that
# is absent or null exits 3 with nothing printed. Anything it cannot answer - malformed YAML, a
# repeated key, no PyYAML, a mapping or list where a scalar is expected - exits 2, so a caller can
# never mistake it for an empty value.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GET="$ROOT/tools/coordination/yaml_get.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# KEEP_GOING=1 reports every failing case instead of stopping at the first (for a red demonstration).
failed=0
pass() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; [ -n "${KEEP_GOING:-}" ] || exit 1; failed=$((failed + 1)); }

# expect <exit-code> <expected-stdout> <label> <yaml-text> <args...>: write the YAML to a file and
# run yaml_get on it; "{}" in the args stands for that file.
n=0
expect() {
	local want="$1" want_out="$2" label="$3" text="$4" out rc a args=()
	shift 4
	n=$((n + 1))
	printf '%s' "$text" >"$TMP/f$n.yaml"
	for a in "$@"; do [ "$a" = "{}" ] && args+=("$TMP/f$n.yaml") || args+=("$a"); done
	set +e; out="$(env ${GET_ENV:+"$GET_ENV"} python3 "$GET" "${args[@]}" 2>"$TMP/err")"; rc=$?; set -e
	if [ "$rc" != "$want" ]; then
		bad "$label (expected exit $want, got $rc)"; sed 's/^/#   /' "$TMP/err" >&2
	elif [ "$out" != "$want_out" ]; then
		bad "$label (exit $rc as expected, but printed '$out', expected '$want_out')"
	elif [ "$rc" = 2 ] && [ ! -s "$TMP/err" ]; then
		bad "$label (exit 2 without a reason on stderr)"
	else
		pass "$label"
	fi
}

# ---- 0: a value, read as data ----------------------------------------------------------------------
expect 0 "../product" "a top-level scalar" $'repo: x\ncheckout: ../product\n' {} checkout
expect 0 "L3" "quotes and a comment are not part of the value" $'level: "L3"   # auto\n' {} level
expect 0 "abc123" "a nested key by its path" $'meta:\n  source_commit: abc123\n' {} meta.source_commit
expect 0 "L1" "a key nested under another mapping is not the top-level key" \
	$'budgets:\n  level: L3\nlevel: L1\n' {} level
expect 0 "ses_A1" "an alias reads as the value it points to" $'author_id: &w ses_A1\nreviewer_id: *w\n' {} reviewer_id
expect 0 "0001" "a number-like scalar keeps its text" $'id: 0001\n' {} id
expect 0 "0123456" "a commit id that looks octal keeps its text" $'commit: 0123456\n' {} commit
expect 0 "yes" "a bool-like scalar keeps its text" $'flag: yes\n' {} flag
expect 0 "" "an empty string is a value, not a missing key" $'checkout: ""\n' {} checkout

# ---- 3: no value -------------------------------------------------------------------------------------
expect 3 "" "an absent key" $'repo: x\n' {} checkout
expect 3 "" "a null value (null)" $'checkout: null\n' {} checkout
expect 3 "" "a null value (~)" $'checkout: ~\n' {} checkout
expect 3 "" "a null value (empty)" $'checkout:\nrepo: x\n' {} checkout
expect 3 "" "a null mapping on the path" $'meta:\nfiles: []\n' {} meta.source_commit
expect 3 "" "an empty document" '' {} checkout

# ---- 2: cannot answer --------------------------------------------------------------------------------
expect 2 "" "a mapping where a scalar is expected" $'checkout:\n  path: ../p\n' {} checkout
expect 2 "" "a list where a scalar is expected" $'checkout: [../p]\n' {} checkout
expect 2 "" "a step through a scalar" $'meta: abc\n' {} meta.source_commit
expect 2 "" "a document that is not a mapping" $'- a\n- b\n' {} checkout
expect 2 "" "a repeated key" $'level: L0\nlevel: L3\n' {} level
expect 2 "" "a repeated nested key" $'meta:\n  a: 1\n  a: 2\nlevel: L1\n' {} level
expect 2 "" "malformed YAML" $'level: [L3\n' {} level
expect 2 "" "a merge key (not read by the shared loader)" $'b: &b {x: 1}\nm:\n  <<: *b\n' {} m.x
expect 2 "" "a value over more than one line" $'note: |\n  one\n  two\n' {} note
expect 2 "" "a missing file" '' "$TMP/absent.yaml" checkout
expect 2 "" "no KEY.PATH" $'a: 1\n' {}
expect 2 "" "an empty step in KEY.PATH" $'a: 1\n' {} a..b
mkdir -p "$TMP/noyaml"
printf 'raise ImportError("PyYAML hidden by the test")\n' >"$TMP/noyaml/yaml.py"
GET_ENV="PYTHONPATH=$TMP/noyaml" expect 2 "" "PyYAML missing" $'checkout: ../p\n' {} checkout

# ---- --list ------------------------------------------------------------------------------------------
expect 0 $'a.h\nb.h' "a block list, one item per line" $'helpers:\n  - a.h\n  - b.h\n' --list {} helpers
expect 0 $'a.h\nb.h' "a flow list reads the same" $'helpers: [a.h, b.h]\n' --list {} helpers
expect 0 "" "an empty list prints nothing" $'helpers: []\n' --list {} helpers
expect 3 "" "an absent list" $'other: 1\n' --list {} helpers
expect 2 "" "a scalar where a list is expected" $'helpers: a.h\n' --list {} helpers
expect 2 "" "a list item that is a mapping" $'helpers:\n  - name: a.h\n' --list {} helpers
expect 2 "" "a null list item" $'helpers:\n  - a.h\n  -\n' --list {} helpers

[ "$failed" -eq 0 ] || { printf '# test-yaml-get: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-yaml-get: all assertions passed\n'
