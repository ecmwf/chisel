#!/usr/bin/env bash
# Regression tests for tools/run-conformance.sh's exclusion handling.
#
# Drives a byte copy of the runner (and the conformance lib/ it sources) in a throwaway workbench
# whose tools/conformance/ holds synthetic checks, so every verdict is known in advance. A check
# that runs leaves a marker file, so "excluded" can be told apart from "ran and was ignored".
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset CONFORMANCE_SKIP PRODUCT_ROOT _PR_LOAD_CWD
export CONFORMANCE_JOBS=2

WB="$TMP/wb"
C="$WB/tools/conformance"
mkdir -p "$C/project" "$TMP/ran"
cp "$ROOT/tools/run-conformance.sh" "$WB/tools/"
cp -R "$ROOT/tools/conformance/lib" "$C/"
# synthetic_check NAME EXIT - a check that records that it ran, prints a line, and exits EXIT.
synthetic_check() {
	printf '#!/usr/bin/env bash\ntouch "%s/%s"\necho "%s output"\nexit %s\n' \
		"$TMP/ran" "$(basename "$1")" "$(basename "$1")" "$2" >"$C/$1"
}
synthetic_check check-green.sh 0
synthetic_check check-red.sh 1
synthetic_check project/check-local.sh 0
git -C "$WB" init -q -b main

failures=0
# expect EXIT LABEL SKIP-VALUE [REQUIRED-TEXT...] - run the runner with CONFORMANCE_SKIP set to
# SKIP-VALUE ("-" leaves it unset) and require the exit code and every REQUIRED-TEXT.
expect() {
	local expected="$1" label="$2" skip="$3" output rc want
	shift 3
	rm -f "$TMP/ran"/*
	set +e
	if [ "$skip" = "-" ]; then
		output="$(cd "$WB" && bash tools/run-conformance.sh 2>&1)"
	else
		output="$(cd "$WB" && CONFORMANCE_SKIP="$skip" bash tools/run-conformance.sh 2>&1)"
	fi
	rc=$?
	set -e
	if [ "$rc" -ne "$expected" ]; then
		printf 'not ok - %s (expected exit %s, got %s)\n%s\n' "$label" "$expected" "$rc" "$output" >&2
		failures=$((failures + 1))
		return 0
	fi
	for want in "$@"; do
		if ! grep -qF -- "$want" <<<"$output"; then
			printf 'not ok - %s (output lacks %s)\n%s\n' "$label" "$want" "$output" >&2
			failures=$((failures + 1))
			return 0
		fi
	done
	printf 'ok - %s\n' "$label"
}
ran() { [ -e "$TMP/ran/$1" ]; }
not_ran() {
	if ran "$1"; then
		printf 'not ok - %s was excluded but ran\n' "$1" >&2
		failures=$((failures + 1))
	else
		printf 'ok - %s did not run\n' "$1"
	fi
}

# 1. Without an exclusion every check runs and the red one decides the exit code.
expect 1 "no exclusion: the red check fails the run" - "RED        check-red.sh (exit 1)"
expect 1 "an empty CONFORMANCE_SKIP excludes nothing" "" "RED        check-red.sh (exit 1)"

# 2. A named check is excluded: not run, listed up front, a SKIP line in the summary, and counted
#    in the final line; the remaining checks still decide the exit code.
expect 0 "an excluded red check does not fail the run" check-red.sh \
	"CONFORMANCE_SKIP excludes 1 check(s): check-red.sh" \
	"SKIP       check-red.sh (excluded by CONFORMANCE_SKIP)" \
	"all 2 check(s) run GREEN; 1 skipped"
not_ran check-red.sh
expect 0 "comma- and space-separated names, including a project check" "check-red.sh, check-local.sh" \
	"SKIP       check-local.sh (excluded by CONFORMANCE_SKIP)" "1 check(s) run GREEN; 2 skipped"
not_ran check-local.sh
expect 1 "excluding a green check leaves the red one failing" check-green.sh \
	"SKIP       check-green.sh" "1 of 2 check(s) run NOT green; 1 skipped"

# 3. Names only, each matching exactly one check; a list that would run nothing is refused.
expect 2 "an unknown name is refused" "check-red.sh check-typo.sh" "'check-typo.sh', which matches 0 checks"
expect 2 "a pattern is not a name" 'check-*.sh' "which matches 0 checks"
expect 2 "excluding every check is refused" "check-green.sh check-red.sh check-local.sh" "nothing would run"
synthetic_check project/check-green.sh 0
expect 2 "a name shared by two checks is refused" check-green.sh "'check-green.sh', which matches 2 checks"
rm -f "$C/project/check-green.sh"

if [ "$failures" -gt 0 ]; then
	printf '%s run-conformance case(s) failed\n' "$failures" >&2
	exit 1
fi
