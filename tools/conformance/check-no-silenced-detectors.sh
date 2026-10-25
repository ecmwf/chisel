#!/usr/bin/env bash
#
# check-no-silenced-detectors.sh - prohibit warning/sanitizer/lint suppression.
#
# AGENTS.md hard rule "Never silence a detector": "No suppression annotations, pragmas, or
# casts to quiet a warning, lint, sanitizer finding, or probe; fix the root cause, or record
# a charter exception. Suppression is allowed only when it is itself the correct semantic
# choice, stated in a comment at the site." This mechanizes that rule for TARGET code.
#
# The default pattern set targets a C/C++ TARGET (the compiler/clang-tidy suppressions below)
# and scans *.c/*.h; instantiate the patterns and the file glob per TARGET language, the way
# the index-helper and naming-map checks are instantiated per TARGET. On a TARGET with no
# matching files the check skips (vacuous green), so it is harmless to ship enabled.
#
# Detected suppressions (whitespace-tolerant; line- AND block-comment forms):
#   - #pragma GCC/clang diagnostic ignored|push (any inter-token whitespace; push frames an ignore region)
#   - // NOLINT / // NOLINTNEXTLINE / /* NOLINT */ (clang-tidy suppression, line or block comment)
#
# Legitimate exceptions must be recorded as charter §4 named exceptions. Until a named
# exception exists, any occurrence is a violation.
#
# Exit-code contract:
#   0  GREEN       no suppression annotations found
#   1  RED         at least one suppression annotation found
#   2  UNRELIABLE  detector could not run (missing files / tooling)
#
# A detector is trusted only after it is seen to fail (the seeded-bug rule).
# Seeded-bug record: tools/conformance/seeded-bugs/check-no-silenced-detectors.md

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/product-root.sh"

# Precedence: --target-dir > TARGET_DIR env > the suite-wide PRODUCT_ROOT env (resolved once and
# exported by tools/run-conformance.sh, or set by a worker for its own product worktree) >
# port/product.yaml.
TARGET_DIR="${TARGET_DIR:-${PRODUCT_ROOT:-}}"

usage() {
    cat <<'USAGE'
Usage: check-no-silenced-detectors.sh [--target-dir <dir>] [files...]

  --target-dir <dir>   Root to scan for TARGET *.c/*.h. Default: $TARGET_DIR, else $PRODUCT_ROOT,
                       else the product checkout (port/product.yaml), else target/.
  files...             Explicit files to check (overrides the scan).

Exit: 0 GREEN, 1 RED (suppression annotation found), 2 UNRELIABLE.
USAGE
}

EXPLICIT_FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-dir) TARGET_DIR="${2:?--target-dir needs a value}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; while [[ $# -gt 0 ]]; do EXPLICIT_FILES+=("$1"); shift; done ;;
        -*)           echo "check-no-silenced-detectors: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)            EXPLICIT_FILES+=("$1"); shift ;;
    esac
done

command -v grep >/dev/null 2>&1 || { echo "check-no-silenced-detectors: grep not found" >&2; exit 2; }

FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
    FILES=("${EXPLICIT_FILES[@]}")
else
    # product_root_for_scan validates whichever root is selected - an explicit TARGET_DIR /
    # PRODUCT_ROOT or the port/product.yaml default - against this invocation's own sibling product
    # worktree: an explicit root takes precedence but is not exempt from that validation.
    TARGET_DIR="$(product_root_for_scan "$TARGET_DIR")"; _prc=$?
    case "$_prc" in
        2) echo "check-no-silenced-detectors: port/product.yaml present but checkout unset/placeholder (UNRELIABLE)." >&2; exit 2 ;;
        3) exit 2 ;; # product_root_for_scan already printed the wrong-tree diagnosis (names both trees)
    esac
    if [[ "$_prc" -eq 0 && ! -d "$TARGET_DIR" ]]; then
        echo "check-no-silenced-detectors: product is wired but its checkout '${TARGET_DIR}' is not present - clone it; refusing to skip (UNRELIABLE)." >&2
        exit 2
    fi
    if [[ "$_prc" -eq 0 ]]; then
        _unread="$(_pr_unreadable_msg "$TARGET_DIR")"
        [[ -n "$_unread" ]] && { echo "check-no-silenced-detectors: ${_unread} (UNRELIABLE)." >&2; exit 2; }
    fi
    # pr_confirm_find fails closed when the walk does not complete cleanly (e.g. an unreadable
    # subdirectory) instead of reporting the partial file list as the whole tree.
    if [[ -d "$TARGET_DIR" ]]; then
        RAW_FILES=()
        if ! pr_confirm_find "$TARGET_DIR" RAW_FILES SCAN_ERR -- -type f \( -name '*.c' -o -name '*.h' \); then
            echo "check-no-silenced-detectors: ${SCAN_ERR} (UNRELIABLE)." >&2
            exit 2
        fi
        # Guard the empty case: printf '%s\n' with no arguments still prints one empty line.
        if [[ ${#RAW_FILES[@]} -gt 0 ]]; then
            while IFS= read -r f; do FILES+=("$f"); done < <(printf '%s\n' "${RAW_FILES[@]}" | sort)
        fi
    fi
    # A TARGET_DIR that does not exist here is the not-wired target/ fallback (exit code 10 above):
    # FILES stays empty and the clean skip below applies.
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "check-no-silenced-detectors: no TARGET *.c/*.h files under '${TARGET_DIR:-<scanned>}' - nothing to check (skipping)."
    exit 0
fi

# Patterns to detect suppression annotations. Extended-regex (authored constants, not user input),
# tolerant of pragma whitespace and covering line- AND block-comment clang-tidy forms - fixed strings
# missed `#pragma  GCC diagnostic ignored` (extra spaces) and `/* NOLINT */`. Each searched separately.
PATTERNS=(
    '#pragma[[:space:]]+GCC[[:space:]]+diagnostic[[:space:]]+(ignored?|push)'
    '#pragma[[:space:]]+clang[[:space:]]+diagnostic[[:space:]]+(ignored?|push)'
    '(//|/\*)[[:space:]]*NOLINT'
)

fails=0
total_lines=0

for file in "${FILES[@]}"; do
    [[ -f "$file" ]] || { echo "  ${file}: NOT FOUND" >&2; fails=$((fails+1)); continue; }
    file_lines=$(wc -l < "$file" 2>/dev/null || echo 0)
    total_lines=$((total_lines + file_lines))

    for pat in "${PATTERNS[@]}"; do
        # grep -nE: line number + extended regex; --: end of options
        hits=$(grep -nE -- "$pat" "$file" 2>/dev/null) || true
        if [[ -n "$hits" ]]; then
            while IFS= read -r hit; do
                echo "[FAIL] ${file}: ${hit}  (pattern: '${pat}')"
                fails=$((fails+1))
            done <<< "$hits"
        fi
    done
done

echo "check-no-silenced-detectors: ${total_lines} line(s) scanned in ${#FILES[@]} file(s); ${fails} suppression(s) found."
if [[ "$fails" -gt 0 ]]; then
    echo "RESULT: RED (exit 1) - suppression annotation(s) found."
    exit 1
fi
echo "RESULT: GREEN (exit 0) - no suppression annotations found."
exit 0
