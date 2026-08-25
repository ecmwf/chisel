#!/usr/bin/env bash
#
# check-swap-residue.sh - detect an UNRESTORED swap-and-fail mutation left in TARGET code.
#
# Sibling of check-no-silenced-detectors.sh, and a different property: that one catches
# suppression ANNOTATIONS (pragmas, NOLINT) quieting a detector; this one catches disabled
# PRODUCT LOGIC. Both are "the code is not what it appears to be", from opposite directions.
#
# Why it exists (references/failure-modes.md, B23's corollary): B23 requires a swap-and-fail -
# substitute the rejected rendering, show the test go red, restore, show it green. That obligation
# makes deliberate mutation of the product a ROUTINE step for every unit, which creates a hazard the
# rule itself introduces: eventually a mutation is committed because the restore was forgotten. It
# is not hypothetical - a product commit shipped a neutralised policy check while its author
# reported a fully passing suite; the real result at that commit was two failing tests, and the
# author's own attached log contained the contradiction.
#
# Cheaply detectable, because a short-circuit literal in a condition is never a legitimate rendering
# of any SOURCE construct: no source language's `if` idiom translates to "and false". So any
# occurrence is either mutation residue or dead code that should have been deleted outright.
#
# Detected (whitespace-tolerant):
#   - a condition neutralised by a short-circuit literal:  if (false && ...) / while (true || ...)
#   - an unconditionally dead preprocessor guard:          #if 0
#
# The default pattern set targets a C/C++ TARGET and scans *.c/*.h; instantiate the patterns and
# the file glob per TARGET language, the way the index-helper and naming-map checks are. On a TARGET
# with no matching files the check skips (vacuous green), so it is harmless to ship enabled.
#
# Any build tree is EXCLUDED: generated build-system files legitimately contain `if(0)`-shaped
# content and would poison the scan - the same reason other product-facing checks exclude it.
#
# Exit: 0 GREEN (no residue, or no matching files), 1 RED (residue found), 2 UNRELIABLE (cannot
# examine the product root - never silently green).
set -uo pipefail

# PRODUCT_ROOT is resolved once by the runner and EXPORTED; the flag is the explicit override.
# Reading only the flag makes this report UNRELIABLE inside the suite even when the product is
# present - a real defect found in this check's first deployment.
PRODUCT_ROOT="${PRODUCT_ROOT:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --product-root)   PRODUCT_ROOT="${2:-}"; shift 2 ;;
        --product-root=*) PRODUCT_ROOT="${1#*=}"; shift ;;
        *) shift ;;
    esac
done

if [ -z "$PRODUCT_ROOT" ]; then
    echo "check-swap-residue: PRODUCT_ROOT not resolved -> UNRELIABLE" >&2
    exit 2
fi
if [ ! -d "$PRODUCT_ROOT" ]; then
    echo "check-swap-residue: product root '$PRODUCT_ROOT' absent -> UNRELIABLE" >&2
    exit 2
fi

violations=0
scanned=0

while IFS= read -r f; do
    scanned=$((scanned + 1))

    while IFS=: read -r lineno text; do
        [ -n "$lineno" ] || continue
        echo "[FAIL] ${f#"$PRODUCT_ROOT"/}:$lineno neutralised condition (swap residue):${text}"
        violations=$((violations + 1))
    done < <(grep -nE '(if|while)[[:space:]]*\([[:space:]]*(false[[:space:]]*&&|true[[:space:]]*\|\|)' "$f" 2>/dev/null)

    while IFS=: read -r lineno text; do
        [ -n "$lineno" ] || continue
        echo "[FAIL] ${f#"$PRODUCT_ROOT"/}:$lineno dead guard (swap residue):${text}"
        violations=$((violations + 1))
    done < <(grep -nE '^[[:space:]]*#[[:space:]]*if[[:space:]]+0([[:space:]]|$)' "$f" 2>/dev/null)
done < <(find "$PRODUCT_ROOT" -type d -name build -prune -o \
              -type f \( -name '*.c' -o -name '*.h' \) -print 2>/dev/null | sort)

if [ "$scanned" -eq 0 ]; then
    echo "check-swap-residue: no matching TARGET files under '$PRODUCT_ROOT' - NOT APPLICABLE -> GREEN"
    exit 0
fi

if [ "$violations" -gt 0 ]; then
    echo "check-swap-residue: scanned $scanned file(s); $violations residue site(s) -> RED"
    echo "  A swap-and-fail mutation appears to have been committed without restoring."
    echo "  Restore the condition; if the code is genuinely dead, delete it rather than guarding it."
    exit 1
fi

echo "check-swap-residue: scanned $scanned file(s); 0 residue site(s) -> GREEN"
exit 0
