#!/usr/bin/env bash
#
# verify-anchors.sh - provenance-anchor verifier for TARGET code.
#
# Specified in port/conventions/<source>-to-<target>.md section 4 (comment policy / anchor verifier).
# For every anchor comment in TARGET code it checks:
#   (1) the cited path:line exists at the pinned SOURCE ref;
#   (2) constant anchors: the SOURCE line contains the literal-as-read textually
#       (module-header anchors: the SOURCE line declares that module);
#   (3) the TARGET line carries the agreed rendering (trap T1: a default-single
#       Fortran literal must render f-suffixed; integers unsuffixed; logicals mapped);
#   (4) coverage: every nontrivial TARGET constant carries an anchor.
#
# Anchor grammar recognised (CONVENTIONS section 4 plus the forms in the headers):
#   constant      /* src: <path>:<line> = <literal-as-read> */
#   module header /* src: <path>:<line> (module <name>) */
#   routine       /* src: <path>:<line> */
# <path> is relative to the pinned SOURCE subtree (SOURCE_SUBDIR below).
#
# SOURCE pin resolution: anchors resolve against an IN-REPO ref - the LOCAL import
# commit that introduced the imported SOURCE (recorded as meta.source_commit in
# port/TRACE.yaml), NOT the upstream commit hash. After a plain copy of the SOURCE the upstream
# hash is provenance only and is not an object in this repo, so `git show <upstream>:...`
# fails; always resolve against the local import commit (or a tag pointing at it). The
# ref is read from port/TRACE.yaml meta (source_commit); override with --ref or
# SOURCE_PIN_REF. It fails loud (exit 2) if the ref does not resolve.
#
# Exit-code contract (lesson L-0001 - a detector must distinguish "clean" from
# "could not run"):
#   0  GREEN       all anchors valid, coverage complete
#   1  RED         at least one anchor or coverage violation
#   2  UNRELIABLE  detector could not run (missing ref/tooling) or met a literal
#                  form whose rendering rule is not yet seed-tested here (rule 7)
#
# A detector is trusted only after it is seen to fail (standing rule 7); this script
# is demonstrated red-then-green on seeded bugs before first real use.

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/product-root.sh"

# ---- configuration (overridable by env or flags) ----------------------------
# Defaults read from port/TRACE.yaml meta: source_commit (the local import commit) and
# source_root (the pinned SOURCE subtree). Override with env or the flags below.
TRACE_FILE="${TRACE_FILE:-port/TRACE.yaml}"
_trace_meta() { sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" "$TRACE_FILE" 2>/dev/null | awk '{print $1}' | head -1; }
SOURCE_PIN_REF="${SOURCE_PIN_REF:-$(_trace_meta source_commit)}"
SOURCE_SUBDIR="${SOURCE_SUBDIR:-$(_trace_meta source_root)}"
SOURCE_SUBDIR="${SOURCE_SUBDIR:-source}"
SOURCE_SUBDIR="${SOURCE_SUBDIR%/}"
TARGET_DIR="${TARGET_DIR:-}"

# A project may PERSIST its kind aliases in a file (so CI honors them without setting env on
# every invocation - the .github workflow is base-owned and cannot export per-project env).
# The file is sourced and may set VERIFY_ANCHORS_DOUBLE_KINDS / VERIFY_ANCHORS_SINGLE_KINDS.
VERIFY_ANCHORS_KINDS_FILE="${VERIFY_ANCHORS_KINDS_FILE:-.verify-anchors-kinds}"
[ -f "$VERIFY_ANCHORS_KINDS_FILE" ] && . "$VERIFY_ANCHORS_KINDS_FILE"

# Fortran kind-suffix -> precision map. The standard width kinds are built in; a
# project adds its own kind ALIASES (e.g. a `p` parameter defined as `dp` in the
# SOURCE) via the env vars below (space-separated kind names, no leading underscore),
# or persistently via the kinds file above.
# A literal's explicit kind suffix overrides default typing (trap T1): a kind-suffixed
# double literal must render WITHOUT an f suffix; a single one WITH it.
DOUBLE_KINDS="dp real64 8 ${VERIFY_ANCHORS_DOUBLE_KINDS:-}"
SINGLE_KINDS="sp real32 4 ${VERIFY_ANCHORS_SINGLE_KINDS:-}"

# Default (UNSUFFIXED) Fortran real precision for this SOURCE. The Fortran standard default real is
# single, but a project compiled under a promote-default-real regime (a DOUBLE_PRECISION build, where
# a bare `2.`/`1.` is a double and an f suffix would lose precision / trip a double-promotion warning -
# a charter-ratifiable rendering policy) renders bare reals as plain doubles.
# `double` makes check3 accept the plain (no-f) rendering of a bare real, as it already does for an
# explicitly double-kinded literal; the standard `single` keeps the f-suffix requirement (trap T1).
DEFAULT_REAL="${VERIFY_ANCHORS_DEFAULT_REAL:-single}"

usage() {
	cat <<'USAGE'
Usage: verify-anchors.sh [--ref <git-ref>] [--target-dir <dir>] [files...]

  --ref <git-ref>      In-repo ref holding the pristine pinned SOURCE.
                       Default: port/TRACE.yaml meta source_commit (local import commit).
  --target-dir <dir>   Root to scan for TARGET *.c / *.h. Default: the product checkout (port/product.yaml), else target/.
  files...             Explicit TARGET files to check (overrides the scan).

Exit: 0 GREEN, 1 RED (violation), 2 UNRELIABLE (cannot run / untested form).
USAGE
}

EXPLICIT_FILES=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--ref)
		SOURCE_PIN_REF="${2:?--ref needs a value}"
		shift 2
		;;
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
		echo "verify-anchors: unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	*)
		EXPLICIT_FILES+=("$1")
		shift
		;;
	esac
done

# ---- preflight: tools -------------------------------------------------------
command -v git >/dev/null 2>&1 || {
	echo "verify-anchors: git not found" >&2
	exit 2
}
command -v awk >/dev/null 2>&1 || {
	echo "verify-anchors: awk not found" >&2
	exit 2
}

# ---- target file set --------------------------------------------------------
# Gather TARGET files BEFORE requiring the SOURCE pin: with no TARGET code there are no
# anchors to resolve and no constants to cover, so the invariant holds vacuously. That is
# a clean SKIP (exit 0), not a "could not run" (exit 2) - the methodology repo and every
# instance before TARGET code exists run this in CI with nothing to check.
FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
	FILES=("${EXPLICIT_FILES[@]}")
else
	if [[ -z "$TARGET_DIR" ]]; then
		TARGET_DIR="$(default_product_root)"
		_prc=$?
		[[ "$_prc" -eq 2 ]] && {
			echo "verify-anchors: port/product.yaml present but its checkout is unset/placeholder (UNRELIABLE)." >&2
			exit 2
		}
	else
		_prc=0
	fi
	if [[ "$_prc" -eq 0 && ! -d "$TARGET_DIR" ]]; then
		echo "verify-anchors: product is wired but its checkout '${TARGET_DIR}' is not present beside the workbench - clone it; refusing to skip (UNRELIABLE)." >&2
		exit 2
	fi
	while IFS= read -r f; do FILES+=("$f"); done \
		< <(find "$TARGET_DIR" -type f \( -name '*.c' -o -name '*.h' \) 2>/dev/null | sort)
fi
if [[ ${#FILES[@]} -eq 0 ]]; then
	echo "verify-anchors: no TARGET *.c/*.h files under '${TARGET_DIR}' yet - nothing to verify (skipping)."
	exit 0
fi

# ---- the pin ref must resolve once there IS TARGET code to check -------------
# Anchors may now exist, so an unresolvable pin is a genuine "cannot run" (exit 2).
if ! git rev-parse --verify --quiet "${SOURCE_PIN_REF}^{commit}" >/dev/null; then
	cat >&2 <<EOF
verify-anchors: SOURCE pin ref '${SOURCE_PIN_REF}' does not resolve in this repo.
  Set port/TRACE.yaml meta source_commit (or SOURCE_PIN_REF / --ref) to the LOCAL import
  commit that introduced the imported SOURCE (or a tag pointing at it). The upstream
  commit hash is provenance only and is not necessarily an object in this repo.
EOF
	exit 2
fi
PIN_SHA="$(git rev-parse --short "${SOURCE_PIN_REF}^{commit}")"

# ---- scratch + source cache -------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
declare -A SRC_TOTAL # path -> line count, or -1 if absent at the pin ref
declare -A SRC_SEEN

ensure_src() {
	local path="$1"
	[[ -n "${SRC_SEEN[$path]:-}" ]] && return 0
	SRC_SEEN[$path]=1
	local out="$TMP/src/$path"
	mkdir -p "$(dirname "$out")"
	if git show "${SOURCE_PIN_REF}:${SOURCE_SUBDIR}/${path}" >"$out" 2>/dev/null; then
		SRC_TOTAL[$path]="$(wc -l <"$out")"
	else
		SRC_TOTAL[$path]=-1
	fi
}
src_line() { sed -n "${2}p" "$TMP/src/$1"; }

# ---- numeric-literal tokenizer ----------------------------------------------
# Emits each numeric literal in a literal-as-read, one per line. Identifiers are
# consumed whole, so digits embedded in a name (real32, real64) are NOT emitted.
extract_numerics() {
	awk -v s="$1" '
    BEGIN {
        n = length(s); i = 1
        while (i <= n) {
            c = substr(s, i, 1)
            if (c ~ /[A-Za-z_]/) {
                while (i <= n && substr(s, i, 1) ~ /[A-Za-z0-9_]/) i++
            } else if (c ~ /[0-9.]/) {
                tok = ""
                while (i <= n && substr(s, i, 1) ~ /[0-9.]/) { tok = tok substr(s, i, 1); i++ }
                ch = substr(s, i, 1)
                if (ch ~ /[eEdD]/) {
                    nx = substr(s, i+1, 1); nx2 = substr(s, i+2, 1)
                    if (nx ~ /[0-9]/ || (nx ~ /[+-]/ && nx2 ~ /[0-9]/)) {
                        tok = tok ch; i++
                        if (substr(s, i, 1) ~ /[+-]/) { tok = tok substr(s, i, 1); i++ }
                        while (i <= n && substr(s, i, 1) ~ /[0-9]/) { tok = tok substr(s, i, 1); i++ }
                    }
                }
                if (tok ~ /[0-9]/) print tok
            } else {
                i++
            }
        }
    }'
}

# A numeric value is "present" in the target line if its literal text appears, OR an
# arithmetically-equal floating spelling does: Fortran writes exponents as `E+100` / `E-100`,
# C house style as `e100` / `e-100` (lowercase e, the `+` dropped). Same value, different
# spelling; an exact substring test would spuriously miss it. Returns 0 if present.
value_present() {
	local n="$1" tline="$2" alt
	[[ "$tline" == *"$n"* ]] && return 0
	if [[ "$n" == *[eEdD]* ]]; then
		alt="${n//[EeDd]/e}" # normalize exponent marker to lowercase e
		alt="${alt//e+/e}"   # drop the redundant + after the exponent marker
		[[ "$tline" == *"$alt"* ]] && return 0
	fi
	return 1
}

# ---- check 3: TARGET rendering ----------------------------------------------
# Sets RENDER_REASON; returns 0 ok, 1 violation, 2 untested literal form.
check_rendering() {
	local literal="$1" tline="$2" is_def="${3:-1}" n kindp kw
	RENDER_REASON=""
	# Nothing rendered on this line (a stand-alone /* src: ... */ documentation anchor leaves the
	# code part empty once the comment is stripped): the value, if any, is rendered - and
	# gate-checked - on the code line it annotates, not here. Nothing to assert on this line.
	[[ "$tline" =~ [^[:space:]] ]] || return 0
	case "$literal" in
	.false. | .FALSE.)
		[[ "$tline" == *false* ]] && return 0
		RENDER_REASON="logical .false. should render as 'false'"
		return 1
		;;
	.true. | .TRUE.)
		[[ "$tline" == *true* ]] && return 0
		RENDER_REASON="logical .true. should render as 'true'"
		return 1
		;;
	esac
	local nums
	nums="$(extract_numerics "$literal")"
	# No numeric literals: type alias (real32/dp), derived constant (akap*cp), or a
	# pure reference. Rendering is governed by the typedef / the R0 bit-equivalence
	# gate / the naming map, not by a literal here (lesson L-0009). Nothing to assert.
	[[ -z "$nums" ]] && return 0
	while IFS= read -r n; do
		[[ -z "$n" ]] && continue
		# An explicit kind suffix on this number overrides default typing.
		kindp=""
		for kw in $DOUBLE_KINDS; do
			[[ "$literal" == *"${n}_${kw}"* || "$literal" == *"${n}_${kw^^}"* ]] && {
				kindp=double
				break
			}
		done
		if [[ -z "$kindp" ]]; then
			for kw in $SINGLE_KINDS; do
				[[ "$literal" == *"${n}_${kw}"* || "$literal" == *"${n}_${kw^^}"* ]] && {
					kindp=single
					break
				}
			done
		fi
		if [[ "$kindp" == double ]]; then
			if [[ "$tline" == *"${n}f"* ]]; then
				RENDER_REASON="kind-suffixed double literal '${n}' must render as a double ('${n}', no f suffix); an f suffix rounds to float (trap T1)"
				return 1
			fi
			value_present "$n" "$tline" && continue
			[[ "$is_def" -eq 1 ]] || continue # non-definition line: rendering is gate-governed
			RENDER_REASON="kind-suffixed double literal '${n}' not found in TARGET line"
			return 1
		elif [[ "$kindp" == single ]]; then
			[[ "$tline" == *"${n}f"* ]] && continue
			RENDER_REASON="kind-suffixed single literal '${n}' must render f-suffixed ('${n}f') in TARGET (trap T1)"
			return 1
		fi
		if [[ "$n" == *[dD]* ]]; then
			RENDER_REASON="double-exponent literal '$n': its d->e rendering rule (CONVENTIONS section 4) is not seed-tested in this verifier; extend and seed-test before relying on it (rule 7)"
			return 2
		elif [[ "$n" == *.* || "$n" == *[eE]* ]]; then
			# default (unsuffixed) Fortran real. Under a double-default regime it renders as a
			# plain double (no f); under the standard single default it must render f-suffixed (T1).
			if [[ "$DEFAULT_REAL" == double ]]; then
				if [[ "$tline" == *"${n}f"* ]]; then
					RENDER_REASON="default-real literal '${n}' (double-default regime) must render as a double ('${n}', no f suffix); an f suffix rounds to float (trap T1)"
					return 1
				fi
				value_present "$n" "$tline" && continue
				[[ "$is_def" -eq 1 ]] || continue # non-definition line: rendering is gate-governed
				RENDER_REASON="default-real literal '$n' not found in TARGET line"
				return 1
			fi
			[[ "$tline" == *"${n}f"* ]] && continue
			RENDER_REASON="default-single literal '$n' must render f-suffixed ('${n}f') in TARGET (trap T1)"
			return 1
		else
			# integer literal -> must appear unsuffixed
			value_present "$n" "$tline" && continue
			[[ "$is_def" -eq 1 ]] || continue # non-definition line: rendering is gate-governed
			RENDER_REASON="integer literal '$n' not found in TARGET line"
			return 1
		fi
	done <<<"$nums"
	return 0
}

# ---- anchor + coverage extraction (single awk pass per file) ----------------
# Emits TAB-separated records:
#   A <lineno> <payload> <code-only>     anchor; payload is the text between "/* src:"
#       and "*/"; code-only is the target line with the /* src: ... */ anchor comment
#       removed. check3 compares against THIS, so the anchor text (which embeds the
#       SOURCE literal verbatim) cannot mask a wrong initializer. code-only is the LAST
#       field on purpose: a literal tab inside the target line then cannot shift it
#       across the read split and re-admit the comment (the full line is not emitted -
#       no check needs it).
#   C <lineno> <full-target-line>               (a constant-def line with no anchor)
# Comment state persists across lines (st) so multi-line comments are stripped; C
# uses code with comments AND string literals removed, so ` = ` inside a comment or a
# string (e.g. a _Static_assert message "(p = dp)") is never mistaken for a constant.
AWK_PROG='
function strip_cs(s,   out, i, n) {
    out = ""; i = 1; n = length(s)
    while (i <= n) {
        if (st == 1) { if (substr(s, i, 2) == "*/") { st = 0; i += 2 } else i++ }
        else        { if (substr(s, i, 2) == "/*") { st = 1; i += 2 } else { out = out substr(s, i, 1); i++ } }
    }
    return out
}
{
    line = $0
    if (match(line, /\/\* src:.*\*\//)) {
        mstart = RSTART; mlen = RLENGTH
        payload = substr(line, mstart, mlen)
        sub(/^\/\* src:[ \t]*/, "", payload)
        sub(/[ \t]*\*\/$/, "", payload)
        code_part = substr(line, 1, mstart - 1) substr(line, mstart + mlen)
        printf "A\t%d\t%s\t%s\n", FNR, payload, code_part
    }
    code = strip_cs(line)
    gsub(/"[^"]*"/, "", code)
    if (index(code, " = ") > 0 && line !~ /\/\* src:/) {
        # Coverage check: flag only lines that define a constant/enum/static/
        # preprocessor binding. General assignments in implementation files are
        # not constants and do not need anchors; their literals are checked at
        # the constant definitions that supply them. This keeps the coverage
        # check useful for .c files while preserving the original header check.
        if (code ~ /(^|[[:space:]])(const|enum|static)[[:space:]]/ || code ~ /^[[:space:]]*#[[:space:]]*define[[:space:]]/)
            printf "C\t%d\t%s\n", FNR, line
    }
}'

# ---- drive the checks -------------------------------------------------------
fails=0
unreliable=0
anchors=0
coverage_gaps=0

echo "verify-anchors: pin ref = ${SOURCE_PIN_REF} (${PIN_SHA}); SOURCE subdir = ${SOURCE_SUBDIR}"
echo "verify-anchors: scanning ${#FILES[@]} TARGET file(s)"
echo

for file in "${FILES[@]}"; do
	[[ -f "$file" ]] || {
		echo "  ${file}: NOT FOUND" >&2
		fails=$((fails + 1))
		continue
	}
	echo "== ${file} =="
	file_anchors=0
	while IFS=$'\t' read -r rec a b c; do
		case "$rec" in
		A)
			lineno="$a"
			payload="$b"
			tcode="$c"
			anchors=$((anchors + 1))
			file_anchors=$((file_anchors + 1))
			pathline="${payload%% *}"
			rest="${payload#"$pathline"}"
			rest="${rest# }"
			path="${pathline%%:*}"
			srcline="${pathline##*:}"

			if [[ "$pathline" != *:* || ! "$srcline" =~ ^[0-9]+$ ]]; then
				echo "  [FAIL] line ${lineno}: malformed anchor payload '${payload}'"
				fails=$((fails + 1))
				continue
			fi

			ensure_src "$path"
			total="${SRC_TOTAL[$path]}"
			# check 1: path:line exists at the pin ref
			if [[ "$total" -lt 0 ]]; then
				echo "  [FAIL] line ${lineno}: check1 - SOURCE '${path}' absent at ${SOURCE_PIN_REF}"
				fails=$((fails + 1))
				continue
			fi
			if [[ "$srcline" -lt 1 || "$srcline" -gt "$total" ]]; then
				echo "  [FAIL] line ${lineno}: check1 - ${path}:${srcline} out of range (1..${total})"
				fails=$((fails + 1))
				continue
			fi
			stext="$(src_line "$path" "$srcline")"

			if [[ "$rest" == "= "* ]]; then
				literal="${rest#= }"
				# check 2: SOURCE line contains the literal-as-read
				if [[ "$stext" != *"$literal"* ]]; then
					echo "  [FAIL] line ${lineno}: check2 - ${path}:${srcline} lacks literal '${literal}'"
					echo "         SOURCE: ${stext}"
					fails=$((fails + 1))
					continue
				fi
				# check 3: TARGET rendering - use tcode (anchor comment stripped)
				# so the anchor text itself cannot mask a wrong initializer value.
				# is_def marks a CONSTANT-DEFINITION line (same shape check4 keys on): there the
				# value MUST be present (a wrong/missing constant is a real defect). On a general
				# expression/statement/format line the literal can legitimately be absent from THIS
				# physical line (rendered on a sibling line of a multi-line statement, an algebraic
				# rewrite like 2.0*x*x -> x*x+x*x, or a Fortran FORMAT repeat count) - its value is
				# gate-governed, not line-token-checkable; only a value that IS present is T1-checked.
				is_def=0
				if [[ "$tcode" =~ (^|[^A-Za-z_])(const|enum|static)([^A-Za-z_]) || "$tcode" =~ ^[[:space:]]*#[[:space:]]*define[[:space:]] ]]; then
					is_def=1
				fi
				check_rendering "$literal" "$tcode" "$is_def"
				rc=$?
				if [[ "$rc" -eq 1 ]]; then
					echo "  [FAIL] line ${lineno}: check3 - ${RENDER_REASON}"
					fails=$((fails + 1))
					continue
				elif [[ "$rc" -eq 2 ]]; then
					echo "  [WARN] line ${lineno}: check3 UNRELIABLE - ${RENDER_REASON}"
					unreliable=$((unreliable + 1))
					continue
				fi
				echo "  [OK]   line ${lineno}: ${path}:${srcline} = ${literal}"
			elif [[ "$rest" == "(module "* ]]; then
				modname="${rest#(module }"
				modname="${modname%)}"
				# check 2 (header): SOURCE line declares the module. Fortran is
				# case-INSENSITIVE (and writes the keyword either case, e.g. uppercase
				# `MODULE FOO`), so compare lowercased - a case-sensitive match for
				# `module` silently fails every uppercase-MODULE codebase.
				if [[ "${stext,,}" != *"module ${modname,,}"* ]]; then
					echo "  [FAIL] line ${lineno}: check2 - ${path}:${srcline} does not declare 'module ${modname}'"
					echo "         SOURCE: ${stext}"
					fails=$((fails + 1))
					continue
				fi
				echo "  [OK]   line ${lineno}: ${path}:${srcline} (module ${modname})"
			elif [[ -z "$rest" ]]; then
				echo "  [OK]   line ${lineno}: ${path}:${srcline} (routine anchor; existence only)"
			else
				echo "  [OK]   line ${lineno}: ${path}:${srcline} ${rest} (note anchor; existence only)"
			fi
			;;
		C)
			lineno="$a"
			tline="$b"
			echo "  [FAIL] line ${lineno}: check4 - constant definition lacks a provenance anchor"
			echo "         TARGET: ${tline}"
			fails=$((fails + 1))
			coverage_gaps=$((coverage_gaps + 1))
			;;
		esac
	done < <(awk "$AWK_PROG" "$file")
	echo "   (${file_anchors} anchor(s))"
	echo
done

# ---- verdict ----------------------------------------------------------------
echo "------------------------------------------------------------"
echo "SUMMARY: ${anchors} anchor(s) checked; ${fails} violation(s); ${coverage_gaps} coverage gap(s); ${unreliable} unreliable."
if [[ "$unreliable" -gt 0 ]]; then
	echo "RESULT: UNRELIABLE (exit 2) - a literal form is not seed-tested; extend the verifier."
	exit 2
elif [[ "$fails" -gt 0 ]]; then
	echo "RESULT: RED (exit 1) - provenance/rendering/coverage violation."
	exit 1
fi
echo "RESULT: GREEN (exit 0) - all anchors resolve, render, and cover."
exit 0
