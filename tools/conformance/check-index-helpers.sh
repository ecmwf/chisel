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
# nested brackets, so a helper call carrying a nested subscript reads as one unit, and joining
# a subscript wrapped across physical lines), and
# flags any that is an open-coded MULTI-DIMENSIONAL FLATTEN - a binary `*` stride outside a
# helper, the construct that reintroduces the storage-order/index-base assumptions the
# helpers localize. Allowed without a helper: numeric literals, whitelisted helper calls
# (by default idx0..idx4 / idx1_stride / idxlb; a port declares its own set, see HELPER NAMES
# below), and single linear 1-D accesses (a bare index or an index +/- a literal, which carry
# no stride). The helper header/source are excluded because they define the helpers themselves.
#
# HELPER NAMES: which helpers exist is a convention of the port (port/conventions/, "Index
# helpers"), not of this script. A port whose helper set differs from the default - another
# arity, other names - lists it in tools/conformance/project/index-helper-names.txt (project
# layer; override the path with INDEX_HELPER_NAMES): one exact C identifier per line, `#`
# comments and blank lines ignored. The list REPLACES the default. Patterns are not accepted, and
# every listed name must be DEFINED - a function definition or prototype, or a #define - in the
# central helper header/source (idx.h / idx.c) among the checked files, so the list can only name
# helpers that exist where the convention puts them. Definitions are read from a libclang parse
# (lib/index_helper_defs.py), never from text, so a call, a comment or an inactive #if branch does
# not count. A malformed or empty list, an unreadable INDEX_HELPER_NAMES path, a listed name with
# no such definition, a central file that does not parse cleanly, or a missing python3/libclang is
# UNRELIABLE. (The default set is not cross-checked this way; it is the reference convention the
# base ships, and checking it needs no parser.)
#
# Exit-code contract:
#   0  GREEN       all subscripts use the helper idiom
#   1  RED         at least one ad-hoc subscript found
#   2  UNRELIABLE  detector could not run (missing files/tooling, malformed helper-name list,
#                  a listed helper with no central definition, libclang unavailable for that)
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

# The helper set (see HELPER NAMES in the header), read before any scan so a malformed list is
# reported even when there is nothing to scan yet.
HELPERS=(idx0 idx1 idx2 idx3 idx4 idx1_stride idxlb)
HELPERS_LISTED=0
HELPER_NAMES_FILE="${INDEX_HELPER_NAMES:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/project/index-helper-names.txt}"
if [[ -n "${INDEX_HELPER_NAMES:-}" || -e "$HELPER_NAMES_FILE" ]]; then
	[[ -f "$HELPER_NAMES_FILE" && -r "$HELPER_NAMES_FILE" ]] || {
		echo "check-index-helpers: helper-name list '${HELPER_NAMES_FILE}' is missing or unreadable (UNRELIABLE)." >&2
		exit 2
	}
	HELPERS=()
	HELPERS_LISTED=1
	while IFS= read -r ln || [[ -n "$ln" ]]; do
		ln="${ln%%#*}"
		ln="${ln#"${ln%%[![:space:]]*}"}"
		ln="${ln%"${ln##*[![:space:]]}"}"
		[[ -n "$ln" ]] || continue
		[[ "$ln" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
			echo "check-index-helpers: '${ln}' in '${HELPER_NAMES_FILE}' is not a C identifier - list exact helper names, one per line (UNRELIABLE)." >&2
			exit 2
		}
		HELPERS+=("$ln")
	done <"$HELPER_NAMES_FILE"
	[[ ${#HELPERS[@]} -gt 0 ]] || {
		echo "check-index-helpers: helper-name list '${HELPER_NAMES_FILE}' names no helper (UNRELIABLE)." >&2
		exit 2
	}
	echo "check-index-helpers: helper names from '${HELPER_NAMES_FILE}': ${HELPERS[*]}"
fi
# The awk side matches a whole helper name followed by "(": the names are plain identifiers
# (validated above), so they are safe to join into a regex alternation.
HELPER_RE="^($(
	IFS='|'
	printf '%s' "${HELPERS[*]}"
))[[:space:]]*[(]"

FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
	FILES=("${EXPLICIT_FILES[@]}")
else
	# product_root_for_scan validates whichever root is selected - an explicit TARGET_DIR /
	# PRODUCT_ROOT or the port/product.yaml default - against this invocation's own sibling product
	# worktree: an explicit root takes precedence but is not exempt from that validation.
	TARGET_DIR="$(product_root_for_scan "$TARGET_DIR")"
	_prc=$?
	case "$_prc" in
	2)
		echo "check-index-helpers: $(pr_checkout_problem) (UNRELIABLE)." >&2
		exit 2
		;;
	3) exit 2 ;; # product_root_for_scan already printed the wrong-tree diagnosis (names both trees)
	esac
	if [[ "$_prc" -eq 0 && ! -d "$TARGET_DIR" ]]; then
		echo "check-index-helpers: product is wired but its checkout '${TARGET_DIR}' is not present beside the workbench - clone it; refusing to skip (UNRELIABLE)." >&2
		exit 2
	fi
	if [[ "$_prc" -eq 0 ]]; then
		_unread="$(_pr_unreadable_msg "$TARGET_DIR")"
		[[ -n "$_unread" ]] && {
			echo "check-index-helpers: ${_unread} (UNRELIABLE)." >&2
			exit 2
		}
	fi
	# Scope: check the shipped TRANSLATED sources only. A product `tests/` subtree is product-owned
	# test SCAFFOLDING (verified by its tests passing), not translated arrays - a fixture buffer SIZE
	# like `buf[100*137]` is a declaration, not a ported-array subscript, so the helper rule would
	# false-positive on it. Prune any directory named `tests` (its whole subtree); a `tests`-NAMED FILE
	# is still scanned. pr_confirm_target_files fails closed when the walk does not complete cleanly
	# (e.g. an unreadable subdirectory) instead of reporting the partial file list as the whole tree.
	if [[ -d "$TARGET_DIR" ]]; then
		if ! pr_confirm_target_files "$TARGET_DIR" FILES SCAN_ERR; then
			echo "check-index-helpers: ${SCAN_ERR} (UNRELIABLE)." >&2
			exit 2
		fi
		# A readable but unsearchable directory lists its entries and fails every read through it.
		if ! pr_confirm_searchable "$TARGET_DIR" SEARCH_ERR; then
			echo "check-index-helpers: ${SEARCH_ERR} (UNRELIABLE)." >&2
			exit 2
		fi
	fi
	# A TARGET_DIR that does not exist here is the not-wired target/ fallback (exit code 10 above):
	# FILES stays empty and the clean skip below applies.
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
	echo "check-index-helpers: no TARGET *.c/*.h files under '${TARGET_DIR}' - nothing to check (skipping)."
	exit 0
fi

# A LISTED helper name is trusted only once it is DEFINED in the central helper header/source -
# idx.h / idx.c, the files excluded below because they define the helpers - among the files being
# checked. Without that, the list could whitelist any spelling (including a local function that
# open-codes a flatten), so a listed name with no central definition is UNRELIABLE. Whether a file
# defines a name is a question about the program, not its text: lib/index_helper_defs.py parses
# each central file with libclang (as compiled with no command-line macros) and accepts a name
# only for a file-scope FUNCTION_DECL (a definition or a prototype) or MACRO_DEFINITION of exactly
# that name in that file. Calls, comments and inactive preprocessor branches never count. A central
# file that does not parse cleanly on its own, or a missing libclang, is UNRELIABLE, never GREEN.
if [[ "$HELPERS_LISTED" -eq 1 ]]; then
	DEF_FILES=()
	for f in "${FILES[@]}"; do
		case "$(basename -- "$f")" in idx.h | idx.c) DEF_FILES+=("$f") ;; esac
	done
	if [[ ${#DEF_FILES[@]} -eq 0 ]]; then
		echo "check-index-helpers: listed helper(s) with no definition in the central helper header/source (idx.h / idx.c) among the checked files: ${HELPERS[*]} - no idx.h / idx.c is among them; define the helpers there or remove them from '${HELPER_NAMES_FILE}' (UNRELIABLE)." >&2
		exit 2
	fi
	command -v python3 >/dev/null 2>&1 || {
		echo "check-index-helpers: python3 not found - required (with libclang) to verify the listed helper names (UNRELIABLE)." >&2
		exit 2
	}
	DEFS_TOOL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/index_helper_defs.py"
	DEFS_ARGS=()
	[[ -n "${TARGET_DIR:-}" && -d "$TARGET_DIR" && ${#EXPLICIT_FILES[@]} -eq 0 ]] && DEFS_ARGS+=(-I "$TARGET_DIR")
	DEFS_ERR="$(mktemp)" || {
		echo "check-index-helpers: mktemp failed - cannot verify the listed helper names (UNRELIABLE)." >&2
		exit 2
	}
	UNDEFINED="$(python3 "$DEFS_TOOL" ${DEFS_ARGS[@]+"${DEFS_ARGS[@]}"} "${HELPERS[@]}" -- "${DEF_FILES[@]}" 2>"$DEFS_ERR")"
	_drc=$?
	case "$_drc" in
	0) rm -f "$DEFS_ERR" ;;
	1)
		rm -f "$DEFS_ERR"
		echo "check-index-helpers: listed helper(s) with no definition in the central helper header/source (idx.h / idx.c) among the checked files: $(printf '%s' "$UNDEFINED" | paste -sd ' ' -) - define them there or remove them from '${HELPER_NAMES_FILE}' (UNRELIABLE)." >&2
		exit 2
		;;
	*)
		echo "check-index-helpers: could not verify the listed helper names against the central helper header/source (UNRELIABLE):" >&2
		sed 's/^/  /' "$DEFS_ERR" >&2
		rm -f "$DEFS_ERR"
		exit 2
		;;
	esac
fi

# A subscript is allowed when it is (a) a numeric literal, (b) a whitelisted central-helper
# call (one of HELPERS, with arbitrary nested ()/[] in the arguments), or
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
	# awk reads the file below inside a process substitution, where its exit status is lost.
	[[ -r "$file" ]] || {
		echo "check-index-helpers: cannot read '${file}' - its subscripts were never examined (UNRELIABLE)." >&2
		exit 2
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
	done < <(awk -v waiver_file="$WAIVER_FILE" -v helper_re="$HELPER_RE" '
        BEGIN {
            max_join = 64
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
            # Heuristic: line starts with a C type or storage-class keyword, or with a `_t`
            # typedef name (a project precision type such as scalar_t) followed by the declared
            # name. Each keyword must end at a token boundary: an identifier that merely BEGINS
            # with one (integral[...], doublet[...]) is a statement, and misreading it as a
            # declaration would skip its subscripts.
            if (s ~ /^[[:space:]]*(static|const|extern|typedef|double|float|int|int8_t|int16_t|int32_t|int64_t|char|bool|void|size_t)([^A-Za-z0-9_]|$)/) return 1
            # A pointer star must sit on the declared name: `zq_t * pz[...]` is a product.
            return (s ~ /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*_t[[:space:]]+[*]*[A-Za-z_]/)
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
            if (c !~ helper_re) return 0
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
            n = length(orig); i = 1; joined = 0
            while (i <= n) {
                if (substr(orig, i, 1) == "[") {
                    startfnr = FNR
                    depth = 1; j = i + 1
                    while (1) {
                        while (j <= n) {
                            cj = substr(orig, j, 1)
                            if (cj == "[") depth++
                            else if (cj == "]") { depth--; if (depth == 0) break }
                            j++
                        }
                        if (depth == 0) break
                        # A subscript wrapped across physical lines (a formatter column limit
                        # does this to long helper calls): join the next line and keep scanning,
                        # so the subscript is checked as ONE unit. A wrapped flatten
                        # (z[i +\n j * nx]) still shows its stride once joined and stays RED. The
                        # indentation of the continuation collapses to one space, so the joined text
                        # reads (and is waived) as if written on one line. A statement wraps over a
                        # handful of lines; the join cap keeps a stray "[" (e.g. in a character
                        # literal) from joining the rest of the file.
                        if (joined >= max_join) { unclosed = "not closed within " max_join " continuation lines"; break }
                        if ((getline extra) <= 0) { unclosed = "never closed before end of file"; break }
                        joined++
                        extra = strip_comments(extra)
                        gsub(/"[^"]*"/, "", extra)
                        sub(/^[[:space:]]+/, "", extra)
                        sub(/[[:space:]]+$/, "", orig)
                        j = length(orig) + 1
                        orig = orig " " extra
                        n = length(orig)
                        eq_pos = first_assignment(orig)
                    }
                    if (depth != 0) {
                        # Nothing left to join: fail CLOSED rather than skip it - an unread
                        # subscript could hide a flatten.
                        total++
                        printf "FAIL\t%d\t%s\n", startfnr, ("subscript " unclosed ": " substr(orig, i, 80))
                        break
                    }
                    inner = substr(orig, i + 1, j - i - 1)
                    before = substr(orig, 1, i - 1)
                    if (!decl || j >= eq_pos || before ~ /\{/) {
                        total++
                        if (!is_allowed(inner))
                            printf "%s\t%d\t%s\n", (is_waived(inner) ? "WAIVE" : "FAIL"), startfnr, inner
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
