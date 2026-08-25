#!/usr/bin/env bash
# test_review_verdict.sh - discriminating test for the ONE shared verdict parser (R04).
#
# Must cover at least:
#   - verdict: violations # not clean (trailing comment containing clean)
#   - violations report whose body mentions the clean token
#   - leading/trailing whitespace
#   - wrong case
#   - empty or missing first line
# Also covers: markdown emphasis, mixed case, extra words.
#
# This is the committed evidence that the three trust decisions
# (record_review, release_claim) cannot be exploited
# via substring matching.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PARSER="$REPO_ROOT/tools/coordination/lib/review_verdict.sh"
# When running from workbench root, relative path still works; fallback
[ -f "$PARSER" ] || PARSER="$SCRIPT_DIR/../lib/review_verdict.sh"
# shellcheck source=../lib/review_verdict.sh
. "$PARSER"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() {
    local label="$1" expected_rc="$2" expected_out="$3" content="$4"
    local file="$TMP/report.md"
    printf '%s' "$content" > "$file"
    local out rc
    out="$(review_verdict_parse "$file" 2>/dev/null || true)"
    rc=$?
    # review_verdict_parse prints verdict string; capture rc via $? above needs separate
    # Re-run to get rc correctly
    review_verdict_parse "$file" >/tmp/_out 2>/dev/null; rc=$?
    out="$(cat /tmp/_out 2>/dev/null || true)"
    if [ "$rc" -eq "$expected_rc" ] && [ "$out" = "$expected_out" ]; then
        echo "[PASS] $label -> rc $rc / '$out'"
        pass=$((pass+1))
    else
        echo "[FAIL] $label -> got rc $rc / '$out' expected rc $expected_rc / '$expected_out' content: $(printf '%q' "$content")"
        fail=$((fail+1))
    fi
}
check_missing() {
    local label="$1" path="$2"
    local out rc
    review_verdict_parse "$path" >/tmp/_out 2>/dev/null; rc=$?
    out="$(cat /tmp/_out 2>/dev/null || true)"
    if [ "$rc" -eq 2 ] && [ "$out" = "missing" ]; then
        echo "[PASS] $label -> rc 2 missing"
        pass=$((pass+1))
    else
        echo "[FAIL] $label -> got rc $rc / '$out' expected rc 2 / 'missing'"
        fail=$((fail+1))
    fi
}

echo "=== verdict parser discriminating tests ==="
# The crafted exploit that previously recorded as clean: substring clean inside violations line
check "exploit: violations # not clean" 1 "unparsable" "verdict: violations # not clean
body"
# Violations report whose body mentions clean token - must still be violations (line1 only)
check "violations with body mentioning clean" 0 "violations" "verdict: violations
remediation: replace with \`verdict: clean\`"
# Clean with body mentioning violations - must be clean
check "clean with body mentioning violations" 0 "clean" "verdict: clean
prior discussion of violations"
# Leading/trailing whitespace allowed
check "leading/trailing whitespace clean" 0 "clean" "  verdict: clean  "
check "leading/trailing whitespace violations" 0 "violations" "	verdict: violations	"
check "leading/trailing whitespace + CRLF" 0 "clean" $'  verdict: clean  \r'
# Wrong case -> unparsable
check "wrong case Verdict" 1 "unparsable" "Verdict: clean"
check "wrong case VERDICT" 1 "unparsable" "VERDICT: CLEAN"
# Empty first line -> unparsable
check "empty first line" 1 "unparsable" ""
check "empty first line with newline" 1 "unparsable" "
second line verdict: clean"
check "whitespace only" 1 "unparsable" "   "
# Markdown emphasis must NOT match
check "markdown bold clean" 1 "unparsable" "**verdict: clean**"
check "markdown emphasis violations" 1 "unparsable" "*verdict: violations*"
# Extra words after token -> unparsable
check "extra words after clean" 1 "unparsable" "verdict: clean # ok"
check "extra words violations clean" 1 "unparsable" "verdict: violations not clean"
# Missing file
check_missing "missing file" "/no/such/file.md"
# Exact tokens still pass
check "exact clean" 0 "clean" "verdict: clean"
check "exact violations" 0 "violations" "verdict: violations"
# Body-only clean must not count when line1 is violations
check "violations line1 body has clean token earlier" 0 "violations" "verdict: violations
verdict: clean"

echo
echo "=== summary: $pass passed, $fail failed ==="
if [ "$fail" -gt 0 ]; then
    echo "RESULT: RED"
    exit 1
fi
echo "RESULT: GREEN - shared parser is exact and fail-closed"
exit 0
