#!/usr/bin/env bash
# review_verdict.sh - ONE shared parser for the machine-readable review verdict.
#
# The methodology defines an exact first-line token at .opencode/command/port-review.md:147-150:
#   verdict: clean
#   verdict: violations
# PLAIN text, no markdown emphasis, case-sensitive, line 1 only.
# Every consumer of this token must use this parser - never a substring test.
#
# API:
#   source this file, then:
#     verdict=$(review_verdict_parse <path>)
#     rc=$?
#   rc 0 + stdout "clean" | "violations"  -> parsed
#   rc 1 + stdout "unparsable"            -> readable but not the canonical token (fail closed)
#   rc 2 + stdout "missing"               -> missing/unreadable/empty first line missing (fail closed)
#
# Trims ONLY leading/trailing ASCII whitespace (space, tab, CR) around the canonical
# token. Anything else - trailing comment, markdown, wrong case, extra words - is unparsable.
set -uo pipefail

review_verdict_parse() {
    local file="${1:-}"
    [ -n "$file" ] || { echo "missing"; return 2; }
    [ -f "$file" ] || { echo "missing"; return 2; }
    [ -r "$file" ] || { echo "missing"; return 2; }
    local raw
    # Read only line 1, without interpreting backslashes; empty file -> raw empty
    IFS= read -r raw < "$file" 2>/dev/null || raw=""
    # head fallback for files without newline? IFS read handles first line; if file empty, raw empty
    # But if file has content but read failed due to no newline, try head
    if [ -z "$raw" ] && [ -s "$file" ]; then
        raw="$(head -n 1 "$file" 2>/dev/null || true)"
    fi
    # Strip trailing CR (CRLF)
    raw="${raw%$'\r'}"
    # If file is empty or first line is empty -> unparsable (fail closed), but
    # missing vs unparsable distinction: empty file is unparsable, not missing
    # Only actual missing file is "missing".
    # Trim leading/trailing whitespace (space, tab, also handles CR already stripped)
    local trimmed
    trimmed="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    # Empty trimmed -> unparsable (empty first line)
    if [ -z "$trimmed" ]; then
        echo "unparsable"
        return 1
    fi
    if [ "$trimmed" = "verdict: clean" ]; then
        echo "clean"
        return 0
    fi
    if [ "$trimmed" = "verdict: violations" ]; then
        echo "violations"
        return 0
    fi
    echo "unparsable"
    return 1
}

# Standalone mode: parse file given as argument and print verdict, exit with rc.
if [ "${BASH_SOURCE[0]:-}" = "$0" ] || [[ "$0" == *"review_verdict.sh" ]]; then
    if [ $# -eq 1 ]; then
        review_verdict_parse "$1"
        exit $?
    elif [ $# -gt 1 ]; then
        echo "usage: $0 <report-file>" >&2; exit 2
    fi
fi
