#!/usr/bin/env bash
#
# check-index-helpers.sh - enforce the central-index-helper idiom.
#
# Specified in target/CONVENTIONS.md section 6 (mechanical-surface idioms) and
# the charter's index-base / storage-order transforms. Every multi-dimensional or
# base-shifted array access in target/ must go through the project's central
# helpers.
#
# The script scans TARGET *.c / *.h, extracts every [] subscript expression, and
# flags any that is neither (a) a numeric literal nor (b) a call to one of the
# whitelisted helpers. The helper header/source are excluded because they define
# the helpers themselves.
#
# Exit-code contract:
#   0  GREEN       all subscripts use the helper idiom
#   1  RED         at least one ad-hoc subscript found
#   2  UNRELIABLE  detector could not run (missing files/tooling)
#
# A detector is trusted only after it is seen to fail; demonstrate this script on
# a seeded bug before first real use and after any matching-logic change.

set -uo pipefail

TARGET_DIR="${TARGET_DIR:-target}"

usage() {
    cat <<'USAGE'
Usage: check-index-helpers.sh [--target-dir <dir>] [files...]

  --target-dir <dir>   Root to scan for TARGET *.c/*.h. Default: target/.
  files...             Explicit files to check (overrides the scan).

Exit: 0 GREEN, 1 RED (ad-hoc subscript), 2 UNRELIABLE.
USAGE
}

EXPLICIT_FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-dir) TARGET_DIR="${2:?--target-dir needs a value}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; while [[ $# -gt 0 ]]; do EXPLICIT_FILES+=("$1"); shift; done ;;
        -*)           echo "check-index-helpers: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)            EXPLICIT_FILES+=("$1"); shift ;;
    esac
done

command -v awk >/dev/null 2>&1 || { echo "check-index-helpers: awk not found" >&2; exit 2; }

FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
    FILES=("${EXPLICIT_FILES[@]}")
else
    while IFS= read -r f; do FILES+=("$f"); done \
        < <(find "$TARGET_DIR" -type f \( -name '*.c' -o -name '*.h' \) 2>/dev/null | sort)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "check-index-helpers: no TARGET *.c/*.h files under '${TARGET_DIR}' - nothing to check (skipping)."
    exit 0
fi

# Subscript content must be either a numeric literal or a whitelisted helper call.
ALLOWED_RE='^[[:space:]]*([0-9]+|idx1[[:space:]]*\([^)]*\)|idx2[[:space:]]*\([^)]*\)|idx1_stride[[:space:]]*\([^)]*\))[[:space:]]*$'

fails=0
total=0

for file in "${FILES[@]}"; do
    [[ -f "$file" ]] || { echo "  ${file}: NOT FOUND" >&2; fails=$((fails+1)); continue; }

    # idx.h / idx.c contain the helper definitions themselves; exclude them.
    case "$file" in
        */idx.h|*/idx.c) continue ;;
    esac

    while IFS=$'\t' read -r lineno content; do
        total=$((total+1))
        if [[ ! "$content" =~ $ALLOWED_RE ]]; then
            echo "[FAIL] ${file}:${lineno}: ad-hoc subscript '[${content}]'"
            fails=$((fails+1))
        fi
    done < <(awk '
        function strip_comments(s,    out, i, n) {
            out = ""; i = 1; n = length(s)
            while (i <= n) {
                if (st == 1) { if (substr(s, i, 2) == "*/") { st = 0; i += 2 } else i++ }
                else        { if (substr(s, i, 2) == "/*") { st = 1; i += 2 } else { out = out substr(s, i, 1); i++ } }
            }
            return out
        }
        function is_declaration(s) {
            # Array declarations (e.g. double vv[nmax];) are not ad-hoc indexing.
            # Heuristic: line starts with a C type or storage-class keyword.
            return (s ~ /^[[:space:]]*(static|const|extern|typedef|double|float|int|int8_t|int16_t|int32_t|int64_t|char|bool|void|size_t)/)
        }
        function first_assignment(s,    i, n) {
            n = length(s)
            for (i = 1; i <= n - 2; i++) {
                if (substr(s, i, 3) == " = ") return i
            }
            return n + 1
        }
        {
            orig = strip_comments($0)
            # Also remove string literals so [..] inside them is not flagged.
            gsub(/"[^"]*"/, "", orig)
            decl = is_declaration(orig)
            eq_pos = first_assignment(orig)
            line = orig
            while (match(line, /\[[^\]]+\]/)) {
                inner = substr(line, RSTART+1, RLENGTH-2)
                gsub(/\n/, "", inner)
                sub_end = RSTART + RLENGTH - 1
                before = substr(line, 1, RSTART - 1)
                if (!decl || sub_end >= eq_pos || before ~ /\{/) {
                    printf "%d\t%s\n", FNR, inner
                }
                line = substr(line, RSTART+RLENGTH)
            }
        }
    ' "$file")
done

echo "check-index-helpers: ${total} subscript(s) checked in ${#FILES[@]} file(s); ${fails} violation(s)."
if [[ "$fails" -gt 0 ]]; then
    echo "RESULT: RED (exit 1) - ad-hoc index arithmetic detected."
    exit 1
fi
echo "RESULT: GREEN (exit 0) - all subscripts use central helpers."
exit 0
