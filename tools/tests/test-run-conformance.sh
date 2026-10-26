#!/usr/bin/env bash
# Regression tests for tools/run-conformance.sh: it runs every tools/conformance/*.sh and
# tools/conformance/project/*.sh check, and its serial fallback is the same runner with one job.
#
# Drives a byte copy of the runner (and the conformance lib/ it sources) in a throwaway workbench
# whose tools/conformance/ holds synthetic checks, so every verdict is known in advance. A check
# that runs leaves a marker file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset PRODUCT_ROOT _PR_LOAD_CWD
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
# expect EXIT LABEL [REQUIRED-TEXT...] - run the runner and require the exit code and every
# REQUIRED-TEXT.
expect() {
	local expected="$1" label="$2" output rc want
	shift 2
	rm -f "$TMP/ran"/*
	set +e
	output="$(cd "$WB" && bash tools/run-conformance.sh 2>&1)"
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
did_run() {
	if [ -e "$TMP/ran/$1" ]; then
		printf 'ok - %s ran\n' "$1"
	else
		printf 'not ok - %s did not run\n' "$1" >&2
		failures=$((failures + 1))
	fi
}

# 1. Every check runs, the project checks included, and a red one fails the run.
expect 1 "a red check fails the run" "GREEN      check-green.sh (exit 0)" \
	"GREEN      check-local.sh (exit 0)" "RED        check-red.sh (exit 1)" "1 of 3 check(s) NOT green"
did_run check-local.sh

# 2. The serial fallback is the runner with one job: it runs every check, project checks included.
#    A hand-written loop over tools/conformance/*.sh would miss the project checks and the single
#    product-root resolution, so the documentation must name the runner, not such a loop.
export CONFORMANCE_JOBS=1
expect 1 "CONFORMANCE_JOBS=1 runs every check, one at a time" \
	"GREEN      check-local.sh (exit 0)" "RED        check-red.sh (exit 1)" "1 of 3 check(s) NOT green"
did_run check-local.sh
export CONFORMANCE_JOBS=2
for doc in tools/README.md tools/run-conformance.sh; do
	if grep -qF 'for s in tools/conformance/*.sh' "$ROOT/$doc"; then
		printf 'not ok - %s offers a loop over tools/conformance/*.sh as a fallback\n' "$doc" >&2
		failures=$((failures + 1))
	elif ! grep -qF 'CONFORMANCE_JOBS=1 bash tools/run-conformance.sh' "$ROOT/$doc"; then
		printf 'not ok - %s does not name the runner as the serial fallback\n' "$doc" >&2
		failures=$((failures + 1))
	else
		printf 'ok - %s names the runner with one job as the serial fallback\n' "$doc"
	fi
done

if [ "$failures" -gt 0 ]; then
	printf '%s run-conformance case(s) failed\n' "$failures" >&2
	exit 1
fi
