#!/usr/bin/env bash
# Test the contract of tools/coordination/yaml_get.py, the one YAML reader of the shell tools.
#
# It must read the data the Python tools read, not the text: an alias reads as the value it points
# to, a nested key is not the top-level key, a scalar keeps the text written in the file. A key that
# is absent or null exits 3 with nothing printed. Anything it cannot answer - malformed YAML, a
# repeated key, no PyYAML, a mapping or list where a scalar is expected - exits 2, so a caller can
# never mistake it for an empty value. Each exit-2 case asserts the reader's own reason on stderr: a
# bare exit 2 proves nothing, because python3 also exits 2 when it cannot open the script at all.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GET="$ROOT/tools/coordination/yaml_get.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# KEEP_GOING=1 reports every failing case instead of stopping at the first (for a red demonstration).
failed=0
pass() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; [ -n "${KEEP_GOING:-}" ] || exit 1; failed=$((failed + 1)); }

# expect <exit-code> <expected> <label> <yaml-text> <args...>: write the YAML to a file and run
# yaml_get on it; "{}" in the args stands for that file. For exit 0 and 3, <expected> is the exact
# stdout and stderr must be empty. For exit 2, stdout must be empty and <expected> is the reason the
# reader gives on stderr, after its "yaml_get: " prefix.
n=0
expect() {
	local want="$1" expected="$2" label="$3" text="$4" out rc a args=()
	shift 4
	n=$((n + 1))
	printf '%s' "$text" >"$TMP/f$n.yaml"
	for a in "$@"; do [ "$a" = "{}" ] && args+=("$TMP/f$n.yaml") || args+=("$a"); done
	set +e; out="$(env ${GET_ENV:+"$GET_ENV"} python3 "$GET" "${args[@]}" 2>"$TMP/err")"; rc=$?; set -e
	if [ "$rc" != "$want" ]; then
		bad "$label (expected exit $want, got $rc)"; sed 's/^/#   /' "$TMP/err" >&2
	elif [ "$rc" = 2 ]; then
		if [ -n "$out" ]; then
			bad "$label (exit 2, but printed '$out')"
		elif ! grep -q '^yaml_get: ' "$TMP/err" || ! grep -qF -- "$expected" "$TMP/err"; then
			bad "$label (exit 2, but stderr lacks the reason 'yaml_get: ... $expected')"; sed 's/^/#   /' "$TMP/err" >&2
		else
			pass "$label"
		fi
	elif [ "$out" != "$expected" ]; then
		bad "$label (exit $rc as expected, but printed '$out', expected '$expected')"
	elif [ -s "$TMP/err" ]; then
		bad "$label (exit $rc as expected, but stderr is not empty)"; sed 's/^/#   /' "$TMP/err" >&2
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
expect 2 "is a mapping, not a scalar" "a mapping where a scalar is expected" $'checkout:\n  path: ../p\n' {} checkout
expect 2 "is a list, not a scalar" "a list where a scalar is expected" $'checkout: [../p]\n' {} checkout
expect 2 "is not a mapping, so it has no key 'source_commit'" "a step through a scalar" $'meta: abc\n' {} meta.source_commit
expect 2 "the document in" "a document that is not a mapping" $'- a\n- b\n' {} checkout
expect 2 "duplicate key 'level'" "a repeated key" $'level: L0\nlevel: L3\n' {} level
expect 2 "duplicate key 'a'" "a repeated nested key" $'meta:\n  a: 1\n  a: 2\nlevel: L1\n' {} level
expect 2 "is not valid YAML" "malformed YAML" $'level: [L3\n' {} level
expect 2 "tag:yaml.org,2002:merge" "a merge key (not read by the shared loader)" $'b: &b {x: 1}\nm:\n  <<: *b\n' {} m.x
expect 2 "spans more than one line" "a value over more than one line" $'note: |\n  one\n  two\n' {} note
expect 2 "holds the control character U+0000" "a NUL escape (a shell would drop it: L3\\0 read as L3)" \
	$'level: "L3\\0"\n' {} level
expect 2 "holds the control character U+001B" "an ESC escape" $'checkout: "../p\\eq"\n' {} checkout
expect 2 "holds the control character U+007F" "a DEL character" $'checkout: "../p\\x7f"\n' {} checkout
expect 2 "holds the control character U+0085" "a NEL (C1 control) escape" $'checkout: "../p\\N"\n' {} checkout
expect 0 $'a\tb' "a tab is allowed" $'note: "a\\tb"\n' {} note
expect 2 "cannot read" "a missing file" '' "$TMP/absent.yaml" checkout
expect 2 "usage: yaml_get.py" "no KEY.PATH" $'a: 1\n' {}
expect 2 "bad KEY.PATH 'a..b'" "an empty step in KEY.PATH" $'a: 1\n' {} a..b
mkdir -p "$TMP/noyaml"
printf 'raise ImportError("PyYAML hidden by the test")\n' >"$TMP/noyaml/yaml.py"
GET_ENV="PYTHONPATH=$TMP/noyaml" expect 2 "PyYAML is not available" "PyYAML missing" $'checkout: ../p\n' {} checkout

# ---- --list ------------------------------------------------------------------------------------------
expect 0 $'a.h\nb.h' "a block list, one item per line" $'helpers:\n  - a.h\n  - b.h\n' --list {} helpers
expect 0 $'a.h\nb.h' "a flow list reads the same" $'helpers: [a.h, b.h]\n' --list {} helpers
expect 0 "" "an empty list prints nothing" $'helpers: []\n' --list {} helpers
expect 3 "" "an absent list" $'other: 1\n' --list {} helpers
expect 2 "is not a list" "a scalar where a list is expected" $'helpers: a.h\n' --list {} helpers
expect 2 "item 1 is a mapping, not a scalar" "a list item that is a mapping" $'helpers:\n  - name: a.h\n' --list {} helpers
expect 2 "item 2 is null" "a null list item" $'helpers:\n  - a.h\n  -\n' --list {} helpers
expect 2 "item 1 holds the control character U+0000" "a list item with a NUL escape" \
	$'helpers:\n  - "a\\0.h"\n' --list {} helpers

[ "$failed" -eq 0 ] || { printf '# test-yaml-get: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-yaml-get: all assertions passed\n'
