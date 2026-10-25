#!/usr/bin/env bash
#
# check-index-helpers.sh - enforce the central-index-helper idiom.
#
# Specified in port/conventions/<source>-to-<target>.md section 6 (mechanical-surface idioms) and
# the charter's index-base / storage-order transforms. Every multi-dimensional or
# base-shifted array access in target/ must go through the project's central
# helpers.
#
# The script scans TARGET *.c / *.h, extracts every [] subscript expression (balancing
# nested brackets, so a helper call carrying a nested subscript reads as one unit), and
# flags any that is an open-coded MULTI-DIMENSIONAL FLATTEN - a binary `*` stride outside a
# helper, the construct that reintroduces the storage-order/index-base assumptions the
# helpers localize. Allowed without a helper: numeric literals, whitelisted helper calls
# (idx0..idx4 / idx1_stride / idxlb), and single linear 1-D accesses (a bare index or an
# index +/- a literal, which carry no stride). The helper header/source are excluded because
# they define the helpers themselves.
#
# Exit-code contract:
#   0  GREEN       all subscripts use the helper idiom
#   1  RED         at least one ad-hoc subscript found
#   2  UNRELIABLE  detector could not run (missing files/tooling)
#
# A detector is trusted only after it is seen to fail; demonstrate this script on
# a seeded bug before first real use and after any matching-logic change.

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/product-root.sh"

# Precedence: --target-dir > TARGET_DIR env > the suite-wide PRODUCT_ROOT env (resolved once and
# exported by tools/run-conformance.sh, or set by a worker for its own product worktree) >
# port/product.yaml.
TARGET_DIR="${TARGET_DIR:-${PRODUCT_ROOT:-}}"

usage() {
	cat <<'USAGE'
Usage: check-index-helpers.sh [--target-dir <dir>] [files...]

  --target-dir <dir>   Root to scan for TARGET *.c/*.h. Default: $TARGET_DIR, else $PRODUCT_ROOT,
                       else the product checkout (port/product.yaml), else target/.
  files...             Explicit files to check (overrides the scan).

Exit: 0 GREEN, 1 RED (ad-hoc subscript), 2 UNRELIABLE.
USAGE
}

EXPLICIT_FILES=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--target-dir)
		TARGET_DIR="${2:?--target-dir needs a value}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		while [[ $# -gt 0 ]]; do
			EXPLICIT_FILES+=("$1")
			shift
		done
		;;
	-*)
		echo "check-index-helpers: unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	*)
		EXPLICIT_FILES+=("$1")
		shift
		;;
	esac
done

command -v awk >/dev/null 2>&1 || {
	echo "check-index-helpers: awk not found" >&2
	exit 2
}

FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
	FILES=("${EXPLICIT_FILES[@]}")
else
	if [[ -z "$TARGET_DIR" ]]; then
		TARGET_DIR="$(default_product_root)"
		_prc=$?
		[[ "$_prc" -eq 2 ]] && {
			echo "check-index-helpers: port/product.yaml present but its checkout is unset/placeholder (UNRELIABLE)." >&2
			exit 2
		}
	else
		_prc=0
	fi
	if [[ "$_prc" -eq 0 && ! -d "$TARGET_DIR" ]]; then
		echo "check-index-helpers: product is wired but its checkout '${TARGET_DIR}' is not present beside the workbench - clone it; refusing to skip (UNRELIABLE)." >&2
		exit 2
	fi
	# Scope: check the shipped TRANSLATED sources only. A product `tests/` subtree is product-owned
	# test SCAFFOLDING (verified by its tests passing), not translated arrays - a fixture buffer SIZE
	# like `buf[100*137]` is a declaration, not a ported-array subscript, so the helper rule would
	# false-positive on it. Prune any directory named `tests` (its whole subtree); a `tests`-NAMED FILE
	# is still scanned.
	while IFS= read -r f; do FILES+=("$f"); done \
		< <(find "$TARGET_DIR" -type d -name tests -prune -o -type f \( -name '*.c' -o -name '*.h' \) -print 2>/dev/null | sort)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
	echo "check-index-helpers: no TARGET *.c/*.h files under '${TARGET_DIR}' - nothing to check (skipping)."
	exit 0
fi

# A subscript is allowed when it is (a) a numeric literal, (b) a whitelisted central-helper
# call (idx0..idx4 / idx1_stride / idxlb, with arbitrary nested ()/[] in the arguments), or
# (c) a SINGLE LINEAR access carrying no storage-order stride - a bare index, an index +/- a
# literal, a cast index. What the convention (<source>-to-<target>.md section 6: "multi-dimensional
# and base-shifted indexing") actually forbids open-coded is the MULTI-DIMENSIONAL FLATTEN -
# `i + j*stride` - whose tell is a binary `*` outside a helper; that is what reintroduces the
# storage-order/index-base assumptions the helpers localize. Base-shift correctness of a bare
# 1-D access is the fidelity reviewer's call (and, for proven code, already proven by the proof);
# the mechanical net flags the stride-multiply flatten. The allow decision lives in awk because
# recognizing a helper call requires balancing its parentheses (a regex cannot), and the
# subscript extractor balances brackets so nested `a[idxN(.., b[j], ..)]` is read as one unit.
#
# Per-site WAIVERS: a project may carry an explicit waiver list at
# tools/conformance/project/index-helper-waivers.txt (project layer). Each non-comment line is
# `<path-substring><TAB><exact subscript content>`; a flagged subscript whose file path contains
# the substring AND whose trimmed content equals the entry is reported `[WAIVE]` and does not
# fail the check. A waiver is a recorded, justified convention-exception (e.g. an open-coded
# flatten in already-attested code the proof has proven bit-identical and that policy declines to
# churn) - never a silent bypass; the waiver file documents each entry's reason.
WAIVER_FILE="${INDEX_HELPER_WAIVERS:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project/index-helper-waivers.txt}"
[[ -f "$WAIVER_FILE" ]] || WAIVER_FILE=""

fails=0
total=0
waived=0

for file in "${FILES[@]}"; do
	[[ -f "$file" ]] || {
		echo "  ${file}: NOT FOUND" >&2
		fails=$((fails + 1))
		continue
	}

	# idx.h / idx.c contain the helper definitions themselves; exclude them.
	case "$file" in
	*/idx.h | */idx.c) continue ;;
	esac

	while IFS=$'\t' read -r tag lineno content; do
		if [[ "$tag" == "TOTAL" ]]; then
			total=$((total + lineno))
		elif [[ "$tag" == "WAIVE" ]]; then
			echo "[WAIVE] ${file}:${lineno}: '[${content}]' (recorded convention-exception)"
			waived=$((waived + 1))
		elif [[ "$tag" == "FAIL" ]]; then
			echo "[FAIL] ${file}:${lineno}: ad-hoc subscript '[${content}]'"
			fails=$((fails + 1))
		fi
	done < <(awk -v waiver_file="$WAIVER_FILE" '
        BEGIN {
            nw = 0
            if (waiver_file != "") {
                while ((getline ln < waiver_file) > 0) {
                    if (ln ~ /^[[:space:]]*#/ || ln ~ /^[[:space:]]*$/) continue
                    ti = index(ln, "\t"); if (ti == 0) continue
                    wp[nw] = substr(ln, 1, ti - 1)
                    wc[nw] = substr(ln, ti + 1)
                    gsub(/^[[:space:]]+|[[:space:]]+$/, "", wc[nw])
                    nw++
                }
                close(waiver_file)
            }
        }
        function is_waived(content,    k, t) {
            t = content; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t)
            for (k = 0; k < nw; k++)
                if (index(FILENAME, wp[k]) > 0 && t == wc[k]) return 1
            return 0
        }
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
        # A whitelisted helper call that spans the WHOLE subscript: starts with a helper name
        # immediately followed by "(", and that "(" balances exactly at the final non-space char
        # (so nested "()" / "[]" in the arguments are part of the one helper call).
        function is_helper_call(c,    i, n, depth, ch, rest) {
            if (c !~ /^idx(0|1|2|3|4|1_stride|lb)[[:space:]]*\(/) return 0
            i = index(c, "("); if (i == 0) return 0
            depth = 0; n = length(c)
            for (; i <= n; i++) {
                ch = substr(c, i, 1)
                if (ch == "(") depth++
                else if (ch == ")") { depth--; if (depth == 0) break }
            }
            if (depth != 0) return 0
            rest = substr(c, i + 1); gsub(/[[:space:]]/, "", rest)
            return (rest == "")
        }
        function is_allowed(c,    t) {
            t = c; gsub(/^[[:space:]]+/, "", t); gsub(/[[:space:]]+$/, "", t)
            if (t ~ /^[0-9]+$/) return 1
            if (is_helper_call(t)) return 1
            # a binary "*" (multiplicand on its left) outside a helper is the storage-order stride
            if (t ~ /[A-Za-z0-9_)][[:space:]]*\*/) return 0
            return 1
        }
        {
            orig = strip_comments($0)
            # Also remove string literals so [..] inside them is not flagged.
            gsub(/"[^"]*"/, "", orig)
            decl = is_declaration(orig)
            eq_pos = first_assignment(orig)
            n = length(orig); i = 1
            while (i <= n) {
                if (substr(orig, i, 1) == "[") {
                    depth = 1; j = i + 1
                    while (j <= n) {
                        cj = substr(orig, j, 1)
                        if (cj == "[") depth++
                        else if (cj == "]") { depth--; if (depth == 0) break }
                        j++
                    }
                    if (depth != 0) {
                        # Unbalanced [: a multi-line subscript the per-line scan cannot read as
                        # one unit. Fail CLOSED rather than silently skip it - a multi-line flatten
                        # (z[i +\n j*nx]) would otherwise hide. Flag it; put the subscript on one
                        # physical line so it can be checked (then helper/literal/waiver as usual).
                        total++
                        printf "FAIL\t%d\t%s\n", FNR, ("multi-line subscript - put it on one line to verify: " substr(orig, i))
                        break
                    }
                    inner = substr(orig, i + 1, j - i - 1)
                    before = substr(orig, 1, i - 1)
                    if (!decl || j >= eq_pos || before ~ /\{/) {
                        total++
                        if (!is_allowed(inner))
                            printf "%s\t%d\t%s\n", (is_waived(inner) ? "WAIVE" : "FAIL"), FNR, inner
                    }
                    i = j + 1
                } else i++
            }
        }
        END { printf "TOTAL\t%d\n", total }
    ' "$file")
done

echo "check-index-helpers: ${total} subscript(s) checked in ${#FILES[@]} file(s); ${fails} violation(s); ${waived} waived."
if [[ "$fails" -gt 0 ]]; then
	echo "RESULT: RED (exit 1) - ad-hoc index arithmetic detected."
	exit 1
fi
echo "RESULT: GREEN (exit 0) - all subscripts use central helpers."
exit 0
