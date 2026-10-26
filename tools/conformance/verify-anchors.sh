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
#       Fortran literal must render f-suffixed; integers unsuffixed; logicals mapped) -
#       RCONST-AWARE: a project that renders its build-dependent default-real literals
#       through a dual-precision macro (VERIFY_ANCHORS_DEFAULT_REAL=rconst /
#       VERIFY_ANCHORS_RCONST_KINDS, e.g. this project's `RCONST(x)` -> plain `x` in a
#       double build, `x##f` token-pasted in a single build) is verified against BOTH
#       resulting tokens, not the ONE the invocation happens to compile under - a literal
#       rendered plain or bare-f-suffixed instead of macro-wrapped is correct in AT MOST
#       one of the two builds and WRONG, silently, in the other; a FIXED-precision
#       literal (double- or single-kinded) macro-wrapped is the same trap in reverse -
#       AND STRUCTURALLY EXACT (review rounds 1-2, F-01/F-05): magnitude-only matching
#       cannot tell a sign flip ('-50.0' rendered '50.0'), an operator substitution ('/'
#       rendered '*'), or a double negation ('-(-3.0)' rendered where '3.0' was meant)
#       from a correct rendering - a plausible paraphrase (B2) that the anchor exists
#       specifically to catch. TWO independent hand-rolled text tokenizers for this
#       question (round 1's sign/operator scanner, then its round-2 repair) both left an
#       enumerable class of real forms unhandled (unspaced initializers, repeated unary
#       operators). Round 3 replaces BOTH with a real C parser (libclang, via
#       lib/verify_anchors_ast.py's `structcmp`): the SOURCE literal-as-read and the
#       TARGET initializer are each parsed into an operator tree and compared for EXACT
#       structural equality (same operator at each position, same nesting - Prime
#       Directive 2 is literal translation, so even a mathematically-equivalent
#       restructuring, e.g. folding a double negation, is itself a defect, not a pass) -
#       failing UNRELIABLE, never silently, on any construct outside the supported
#       arithmetic subset (`+ - * /`, parens, numeral leaves, one level of macro-call
#       unwrapping);
#   (4) coverage: every nontrivial TARGET constant carries an anchor - determined by the
#       SAME real parser (`decls`), not a hand-rolled keyword/regex classifier: an
#       object-like `#define`, a constant declared without spaces around `=`, an
#       initializer containing `==` (review rounds 1-2, F-02/F-06), and an ordinary
#       MULTILINE `enum { ... }` body (F-06 - a line-based classifier cannot see an
#       enumerator whose `enum` keyword is on an earlier physical line; a real parser
#       sees the enumerator's own declaration regardless of line count) are all just
#       declaration/expression nodes to a real parser, not spellings to enumerate one at
#       a time. A constant-shaped line anchored with the wrong anchor GRAMMAR (routine/
#       module/note instead of `= <literal-as-read>`) is both a violation and a coverage
#       gap (review round 1, F-04) - now driven by the parser's declaration list instead
#       of the same line-based classifier, so it is no longer bypassable through the
#       classifier's OWN blind spots (review round 2, F-06's second half).
#
# AST/textual split (see lib/verify_anchors_ast.py's own header for the full reasoning):
# the anchor comment grammar, check1 (SOURCE path:line existence), check2 (the SOURCE
# line contains the literal-as-read - Prime Directive 3 is about the literal AS READ, so
# a textual substring check IS the correct check, not an approximation of one), logical
# (.TRUE./.FALSE.) rendering, and the RCONST dual-precision wrap-CORRECTNESS verdict
# (a project policy table, not a C-syntax fact) all stay exactly what they were - genuinely
# textual/git-based questions a parser has no special authority over. Only the two
# questions that are STRUCTURAL by nature - "what does this C file declare" and "does this
# expression have the same shape as that literal" - moved to a real parser, after two
# rounds of a hand-rolled approximation of each leaving an enumerable gap.
#
# Anchor grammar recognised (CONVENTIONS section 4 plus the forms in the headers):
#   constant       /* src: <path>:<line> = <literal-as-read> */
#   module header  /* src: <path>:<line> (module <name>) */
#   routine        /* src: <path>:<line> */
#   runtime-helper /* runtime-helper: <TRAP> - <language contract> */  (anchor-verifier-p002, closes the anchor-less-helper gap)
# A constant-SHAPED definition line (const/enum/static/#define with a value, per the AST
# `decls` scan) must use the constant grammar above; the module-header and routine forms
# are reserved for lines that are not themselves a constant definition (check4/F-04).
# A file implementing a Fortran LANGUAGE contract (not a translation of any SOURCE
# statement) uses runtime-helper instead of src: - cites TRAP row + F2018/language
# citation in place of file:line. Valid only in helper files (stem not matching any
# live SOURCE file), must cite an existing trap row, else RED (escape-hatch blocked).
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
# Exit-code contract (a detector must distinguish "clean" from "could not run" -
# one that reads an error as "no findings" reports OK without ever having looked):
#   0  GREEN       all anchors valid, coverage complete
#   1  RED         at least one anchor, coverage, structural, or malformed-anchor
#                 violation (a malformed anchor is a "/* src:" opening with no closing
#                  "*/" on the same physical line - e.g. an auto-formatter wrapped it)
#   2  UNRELIABLE  detector could not run (missing ref/tooling, including the AST
#                  dependency below), met a literal form whose rendering rule is not
#                  yet seed-tested here (rule 7), an expression construct outside the
#                  supported arithmetic subset, the TARGET file set could not be
#                  enumerated completely (a `find` error under the scan root - a
#                  truncated file set reported clean is a vacuous pass, not a real
#                  one), a TARGET file matched the scan but could not be read
#                  (permission denied), or ANY awk/python subprocess this script
#                  depends on for a verdict failed (review round 2, F-07: every such
#                  invocation is captured and its exit status checked - never silently
#                  counted as zero anchors/zero constants/zero declarations either way)
#
# Dependency (structural checks only - lib/verify_anchors_ast.py): `python3` with
# `clang.cindex` (libclang) importable. Checked ONCE, lazily - only once there is at
# least one TARGET file to actually check (never required for the "no TARGET code yet"
# clean skip below) - and its absence is UNRELIABLE (exit 2), never a silent
# degradation back to a weaker textual check (the exact vacuity every prior finding
# against this script traces back to).
#
# A detector is trusted only after it is seen to fail (standing rule 7); this script
# is demonstrated red-then-green on seeded bugs before first real use.
#
# Three states only ONE of which is a pass (this is the point of the exit-code
# contract above, restated for the coverage/rendering claim specifically): every
# nontrivial constant is anchored and every anchored literal renders correctly in
# EVERY precision the pinned build matrix compiles it under (GREEN); a violation is
# demonstrated (RED); or completeness/coverage/rendering could not be established
# (UNRELIABLE) - never reported as if it were the first.

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/product-root.sh"

# ---- configuration (overridable by env or flags) ----------------------------
# Defaults read from port/TRACE.yaml meta: source_commit (the local import commit) and
# source_root (the pinned SOURCE subtree). Override with env or the flags below.
TRACE_FILE="${TRACE_FILE:-port/TRACE.yaml}"
# The shared strict YAML reader (tools/coordination/yaml_get.py), so a TRACE meta value and the
# declared helpers are read as the Python tools read them: a `source_commit:` line under another key
# is not meta.source_commit, quotes and comments are not part of a value, a repeated key is an error.
_YAML_GET="$(cd "$(dirname "${BASH_SOURCE[0]}")/../coordination" 2>/dev/null && pwd)/yaml_get.py"
# _trace_meta KEY - print meta.KEY of TRACE_FILE; nothing for an absent TRACE or key. Returns 2 when
# the TRACE cannot be read (the reason is on stderr). Called only once there is TARGET code to check
# (the pin block below), like every other python3 dependency here.
_trace_meta() {
	local v rc
	[[ -f "$TRACE_FILE" ]] || return 0
	v="$(python3 "$_YAML_GET" "$TRACE_FILE" "meta.$1")"; rc=$?
	case "$rc" in 0) printf '%s' "$v" ;; 3) ;; *) return 2 ;; esac
}
# Precedence: --target-dir (this check's own flag) > TARGET_DIR env > the suite-wide PRODUCT_ROOT
# env (set once by tools/run-conformance.sh, or by a worker itself) > port/product.yaml.
TARGET_DIR="${TARGET_DIR:-${PRODUCT_ROOT:-}}"

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

# BUILD-DEPENDENT kind aliases (trap P1): a kind that READS as explicitly kinded (so it is
# tempting to treat it like a fixed DOUBLE_KINDS/SINGLE_KINDS entry) but is actually promoted
# in only ONE of the two pinned builds - e.g. a project's own "default real" alias autopromoted
# by a `-fdefault-real-8`-style flag in the double build only. Checked identically to a bare
# default-real literal (below) - RCONST-wrapped, both expansions verified. NEVER add one of
# these kinds to DOUBLE_KINDS above; that list is for kinds fixed to double in BOTH builds.
RCONST_KINDS="${VERIFY_ANCHORS_RCONST_KINDS:-}"

# The dual-precision literal MACRO a project's build-dependent literals render through - one
# SOURCE line, ONE TARGET token (the macro call), but TWO different expansions depending on
# which pinned-precision build compiles it (e.g. `RCONST(x)` -> plain `x` in a double build,
# `x##f` - x with an f suffix token-pasted on - in a single build). A plain f-suffix/no-suffix
# rendering rule cannot express this (it can only be right in ONE build); DEFAULT_REAL=rconst /
# a RCONST_KINDS match route the literal through check_rconst_literal, which verifies BOTH
# expansions from the ONE captured macro argument instead of assuming the macro is
# rendering-transparent. Defaults to "RCONST" whenever unset; an EXPLICIT empty override (a
# project deliberately turning RCONST-awareness off) is validated below, not silently allowed
# to reach the matcher - an empty macro name would match every call in every TARGET line.
RCONST_MACRO="${VERIFY_ANCHORS_RCONST_MACRO-RCONST}"

# Default (UNSUFFIXED) Fortran real precision for this SOURCE - three mutually exclusive
# regimes, never blended:
#   single   Fortran standard default; check3 requires a bare literal to render f-suffixed
#            in TARGET (trap T1). The base default.
#   double   a promote-default-real build (a DOUBLE_PRECISION regime, where a bare `2.`/`1.`
#            is a double and an f suffix would lose precision / trip a double-promotion
#            warning - a charter-ratifiable rendering policy): check3 accepts the plain
#            (no-f) rendering, as it already does for an explicitly double-kinded literal.
#   rconst   a DUAL-PRECISION build compiled BOTH ways from one TARGET tree (this project):
#            a bare literal is build-dependent EXACTLY like a bare literal always was, but
#            the correct TARGET spelling is the macro call above, not a static f-suffix
#            choice - check3 routes it to check_rconst_literal (both expansions verified).
DEFAULT_REAL="${VERIFY_ANCHORS_DEFAULT_REAL:-single}"
case "$DEFAULT_REAL" in
single | double | rconst) : ;;
*)
	echo "verify-anchors: VERIFY_ANCHORS_DEFAULT_REAL='${DEFAULT_REAL}' is not one of single|double|rconst - refusing to guess a rendering regime (UNRELIABLE)." >&2
	exit 2
	;;
esac
if [[ -z "$RCONST_MACRO" && ("$DEFAULT_REAL" == "rconst" || -n "${RCONST_KINDS// /}") ]]; then
	echo "verify-anchors: RCONST-aware checking is requested (VERIFY_ANCHORS_DEFAULT_REAL=rconst and/or a non-empty VERIFY_ANCHORS_RCONST_KINDS) but VERIFY_ANCHORS_RCONST_MACRO is explicitly empty - refusing to guess a macro name (UNRELIABLE)." >&2
	exit 2
fi
_RCONST_AWARE=0
[[ "$DEFAULT_REAL" == "rconst" || -n "${RCONST_KINDS// /}" ]] && _RCONST_AWARE=1

# The preprocessor DEFINE that switches the dual-precision macro's OWN two branches (e.g.
# a project-defined precision or feature macro, recorded in the project's conventions trap table) - needed ONLY for
# the real-macro-CONTRACT check (review round 4, F-13: isolated re-parse proves the TARGET
# invocation's SPELLING, never that the REAL macro actually implements the pinned identity/
# `##f` contract - a SEPARATE fact, checked by parsing the real header TWICE, once with this
# define set and once without, and confirming the compiler's OWN constant evaluator agrees).
# No default - a guard macro name is project-specific and does not belong in
# the base/methodology script; RCONST-aware checking without it is a genuinely unverified
# half of the "both expansions checked" claim, so it fails the SAME way an empty
# VERIFY_ANCHORS_RCONST_MACRO does - loud, at startup, never a silent narrower check.
RCONST_DP_DEFINE="${VERIFY_ANCHORS_RCONST_DP_DEFINE:-}"
if [[ "$_RCONST_AWARE" -eq 1 && -z "$RCONST_DP_DEFINE" ]]; then
	echo "verify-anchors: RCONST-aware checking is requested but VERIFY_ANCHORS_RCONST_DP_DEFINE is unset - the real-macro-contract check (review round 4, F-13) cannot know which preprocessor define switches the dp/sp branches; refusing to claim both expansions are verified without it (UNRELIABLE)." >&2
	exit 2
fi
# Exported (not just a local bash var) so the AST helper's own dp/sp-conditional guard
# (review round 5, F-14; charter P-002) can read it too - `decls`/`structcmp` refuse a
# file containing a conditional on this exact name rather than silently enumerating
# only the one regime this tool ever parses. Empty is fine (RCONST-unaware projects
# have no such switch to guard against); the AST helper treats empty as "guard off".
export VERIFY_ANCHORS_RCONST_DP_DEFINE="$RCONST_DP_DEFINE"

# ---- runtime-helper trap table (anchor-verifier-p002) -----------------------
# Load valid trap IDs from the methodology pair table + project conventions.
# A runtime-helper anchor must cite a trap-table row that exists; citing a
# non-existent row is RED. This prevents invented citations.
_VALID_TRAPS=""
_load_traps() {
	local script_dir
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	local wb_root
	wb_root="$(cd "$script_dir/../.." && pwd)"
	local pair_table="$wb_root/.opencode/skill/target-conventions/references/pairs/fortran-to-c.md"
	local proj_conv="$wb_root/port/conventions/fortran-to-c.md"
	local traps=""
	if [[ -f "$pair_table" ]]; then
		traps+=" $(grep -oE '\| T[0-9]+ \|' "$pair_table" 2>/dev/null | grep -oE 'T[0-9]+' | tr '\n' ' ')"
	fi
	if [[ -f "$proj_conv" ]]; then
		traps+=" $(grep -oE '\| P[0-9]+ \|' "$proj_conv" 2>/dev/null | grep -oE 'P[0-9]+' | tr '\n' ' ')"
		traps+=" $(grep -oE '\| T[0-9]+ \|' "$proj_conv" 2>/dev/null | grep -oE 'T[0-9]+' | tr '\n' ' ')"
	fi
	# Also allow P-traps from pair table if any (future)
	traps="$(echo "$traps" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
	_VALID_TRAPS="$traps"
}
_load_traps

# Declared helper classification (F-01): whether a file is helper vs translated is
# DECLARED, not inferred from stem. The file `port/declared-helpers.yaml` lists helper
# basenames explicitly; unlisted files are UNRELIABLE (fail-closed). Per-declaration
# helper anchors (runtime-helper on same line as the declaration) are the only exemption;
# a file-wide helper marker never suppresses siblings.
# The file lists the helper basenames either as a bare list or under a `helpers:` key, read as YAML
# data (one reader, yaml_get.py --list). Like the TRACE meta it is read only once there is TARGET code
# to check; a file that cannot be read in either form is UNRELIABLE, never an empty helper list. The
# names go into a set, one per line of the reader's output, so a name holding a space is one name.
declare -A _DECLARED_HELPER_SET=()
_load_declared_helpers() {
	local script_dir wb_root helper_file list rc h
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	wb_root="$(cd "$script_dir/../.." && pwd)"
	helper_file="$wb_root/port/declared-helpers.yaml"
	_DECLARED_HELPER_SET=()
	[[ -f "$helper_file" ]] || return 0
	# A bare list first; else the helpers: key. Each attempt keeps its own reason for the refusal.
	list="$(python3 "$_YAML_GET" --list "$helper_file" . 2>"$TMP/helpers-list.err")"; rc=$?
	if [[ "$rc" -ne 0 ]]; then
		list="$(python3 "$_YAML_GET" --list "$helper_file" helpers 2>"$TMP/helpers-key.err")"; rc=$?
	fi
	case "$rc" in
	0)
		while IFS= read -r h; do
			[[ -n "$h" ]] && _DECLARED_HELPER_SET["$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]')"]=1
		done <<<"$list"
		;;
	3) ;;
	*)
		echo "verify-anchors: cannot read the declared helpers from '${helper_file}' as a bare list or as a helpers: list (UNRELIABLE):" >&2
		sed 's/^/  /' "$TMP/helpers-list.err" "$TMP/helpers-key.err" >&2
		return 2
		;;
	esac
}

# Translated files are those that correspond to a SOURCE file in TRACE (declared translated): the
# `source:` of each `files:` entry, read as YAML data (yaml_get.py --each), never a `source:` line
# nested elsewhere. Read once there is TARGET code to check; a TRACE that cannot be read is
# UNRELIABLE. The stems go into a set, so a path holding a space is one stem.
declare -A _TRANSLATED_STEM_SET=()
_load_translated() {
	local script_dir wb_root trace list rc src stem
	script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	wb_root="$(cd "$script_dir/../.." && pwd)"
	trace="${TRACE_FILE:-port/TRACE.yaml}"
	if [[ ! -f "$trace" && -f "$wb_root/port/TRACE.yaml" ]]; then
		trace="$wb_root/port/TRACE.yaml"
	fi
	_TRANSLATED_STEM_SET=()
	[[ -f "$trace" ]] || return 0
	list="$(python3 "$_YAML_GET" --each source "$trace" files)"; rc=$?
	case "$rc" in
	0)
		while IFS= read -r src; do
			[[ -n "$src" ]] || continue
			stem="${src##*/}"; stem="${stem%.F90}"; stem="${stem%.fypp}"; stem="${stem%.h}"
			_TRANSLATED_STEM_SET["$(printf '%s' "$stem" | tr '[:upper:]' '[:lower:]')"]=1
		done <<<"$list"
		;;
	3) ;;
	*)
		echo "verify-anchors: cannot read the translated sources from '${trace}' (see above) (UNRELIABLE)." >&2
		return 2
		;;
	esac
}

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

# ---- scratch (created early: the file-set scan below needs it to capture `find`'s stderr
# without silently discarding it - see the truncation guard) ------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---- target file set --------------------------------------------------------
# Gather TARGET files BEFORE requiring the SOURCE pin: with no TARGET code there are no
# anchors to resolve and no constants to cover, so the invariant holds vacuously. That is
# a clean SKIP (exit 0), not a "could not run" (exit 2) - the methodology repo and every
# instance before TARGET code exists run this in CI with nothing to check.
FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
	FILES=("${EXPLICIT_FILES[@]}")
else
	# product_root_for_scan validates WHATEVER is selected - an explicit TARGET_DIR (flag/env) or
	# the port/product.yaml-configured default - against this invocation's own sibling product
	# worktree: explicit is higher PRECEDENCE, never exempt from that validation (F-02).
	TARGET_DIR="$(product_root_for_scan "$TARGET_DIR")"
	_prc=$?
	case "$_prc" in
	2) echo "verify-anchors: $(pr_checkout_problem) (UNRELIABLE)." >&2; exit 2 ;;
	3) exit 2 ;; # wrong-tree diagnosis already printed by product_root_for_scan (names both paths)
	esac
	if [[ "$_prc" -eq 0 && ! -d "$TARGET_DIR" ]]; then
		echo "verify-anchors: product is wired but its checkout '${TARGET_DIR}' is not present beside the workbench - clone it; refusing to skip (UNRELIABLE)." >&2
		exit 2
	fi
	if [[ "$_prc" -eq 0 ]]; then
		_unread="$(_pr_unreadable_msg "$TARGET_DIR")"
		[[ -n "$_unread" ]] && { echo "verify-anchors: ${_unread} (UNRELIABLE)." >&2; exit 2; }
	fi
	# Scope: scan the shipped TRANSLATED sources only. A product `tests/` subtree is product-owned
	# test SCAFFOLDING (verified by its tests passing), not translated SOURCE - its runtime const-locals
	# (a file descriptor, an sscanf result), fixture buffers, and path arrays have NO SOURCE file:line to
	# anchor, so the coverage check (4) would false-positive on them. Prune any directory named `tests`
	# (its whole subtree); a `tests`-NAMED FILE is still scanned.
	#
	# The scan is captured to a FILE, not piped straight into the read loop: `find`'s own exit
	# code and stderr were previously discarded (`2>/dev/null`, inside a `< <(...)` process
	# substitution whose exit status the shell never checks even with `pipefail`), so a
	# permission-denied subtree or a root that vanished mid-scan silently produced a SHORTER
	# file list with no signal at all - "0 violations" and "0 files under a directory `find`
	# could not fully read" are indistinguishable at that point, and the run reports GREEN on a
	# truncated (not complete) scan: a vacuous pass the coverage check exists specifically to
	# prevent (non-vacuity). Fail closed instead: a `find` error means the file set MAY be
	# incomplete, so it is never reported as if it were.
	#
	# ONE case is NOT truncation and must not be mistaken for it: the TARGET tree does not
	# EXIST yet. That is the normal state of a port before the first translation lands (and
	# the permanent state of a methodology repo, which carries the checks but never any
	# TARGET sources). `find` on a missing root exits non-zero, which is indistinguishable
	# from a half-read directory unless the root is probed FIRST. Distinguishing them is not
	# a loosening: a root that is absent was fully scanned - there was simply nothing in it -
	# whereas a root that is PRESENT and unreadable may be hiding files. Only the second is
	# UNRELIABLE. The empty-file-set path below already reports the first correctly.
	if [[ ! -e "$TARGET_DIR" ]]; then
		echo "verify-anchors: no TARGET source tree at '${TARGET_DIR}' yet - nothing to scan (skipping)."
		exit 0
	fi
	find "$TARGET_DIR" -type d -name tests -prune -o -type f \( -name '*.c' -o -name '*.h' \) -print \
		>"$TMP/files.raw" 2>"$TMP/find.err"
	_find_rc=$?
	if [[ "$_find_rc" -ne 0 || -s "$TMP/find.err" ]]; then
		echo "verify-anchors: scanning '${TARGET_DIR}' for TARGET *.c/*.h did not complete cleanly (find exit ${_find_rc}) - the file set may be TRUNCATED; refusing to report a possibly-incomplete scan as clean (UNRELIABLE)." >&2
		sed 's/^/  /' "$TMP/find.err" >&2
		exit 2
	fi
	while IFS= read -r f; do FILES+=("$f"); done < <(sort "$TMP/files.raw")
fi
if [[ ${#FILES[@]} -eq 0 ]]; then
	echo "verify-anchors: no TARGET *.c/*.h files under '${TARGET_DIR}' yet - nothing to verify (skipping)."
	exit 0
fi

# ---- AST dependency (structural checks - review round 2, F-01/F-02/F-04/F-05/F-06) --
# There IS TARGET code to check now, so the structural questions (declaration coverage,
# expression-shape fidelity) are about to be asked for real - checked HERE, once, lazily
# (never above: a repo with no TARGET code yet must not need this to reach its clean
# skip), and its absence is UNRELIABLE, never a silent fallback to a weaker textual
# approximation (the exact failure mode two prior rounds of hand-rolled text tokenizers
# both hit). See lib/verify_anchors_ast.py's own header for what moved to the AST and why.
AST_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/verify_anchors_ast.py"
if [[ ! -f "$AST_HELPER" ]]; then
	echo "verify-anchors: AST helper script missing at '${AST_HELPER}' - cannot run the structural/coverage checks (UNRELIABLE)." >&2
	exit 2
fi
command -v python3 >/dev/null 2>&1 || {
	echo "verify-anchors: python3 not found - required (with clang.cindex/libclang) for the structural/coverage checks; refusing to fall back to a weaker textual approximation (UNRELIABLE)." >&2
	exit 2
}
_ast_probe_err="$(mktemp)" || {
	echo "verify-anchors: mktemp failed - cannot probe the AST dependency (UNRELIABLE)." >&2
	exit 2
}
if ! python3 -c "import clang.cindex" >/dev/null 2>"$_ast_probe_err"; then
	echo "verify-anchors: python3's clang.cindex (libclang bindings) is not importable - required for the structural/coverage checks (UNRELIABLE)." >&2
	sed 's/^/  /' "$_ast_probe_err" >&2
	rm -f "$_ast_probe_err"
	exit 2
fi
rm -f "$_ast_probe_err"

# ---- compiler resource directory (review round 4, F-12) ----------------------------
# A SECOND, equally-required dependency, checked here alongside the clang.cindex probe
# above rather than per file: without it, libclang cannot resolve the compiler's OWN
# standard headers (`<stdbool.h>`, `<stdint.h>`, ...) even when they genuinely exist on
# this system (confirmed empirically this round - this tool's own prior invocation never
# passed this flag at all, so a REAL, present `<stdbool.h>` reported "file not found" for
# no reason but that), which would make EVERY real TARGET file's structural/coverage
# checks UNRELIABLE one file at a time. A broken/absent compiler toolchain is a
# whole-run dependency failure - fail loud HERE, not silently degrade per file.
_ast_probe_err="$(mktemp)" || {
	echo "verify-anchors: mktemp failed - cannot probe the compiler resource directory (UNRELIABLE)." >&2
	exit 2
}
# Captured to VERIFY_ANCHORS_RESOURCE_DIR and exported (below) so every subsequent
# decls/structcmp/rconst-contract invocation - each its OWN fresh python3 process, unlike
# the ONE-TIME probe here - reuses this ALREADY-DISCOVERED value instead of re-running
# `clang -print-resource-dir` itself on every single call; a performance optimization only,
# never a trust boundary (the python helper's own discovery is still exercised, and still
# authoritative, right here at startup).
if ! VERIFY_ANCHORS_RESOURCE_DIR="$(python3 "$AST_HELPER" resource-dir 2>"$_ast_probe_err")"; then
	echo "verify-anchors: could not discover the C compiler's resource directory (needed to resolve real standard headers - review round 4, F-12) - required for the structural/coverage checks (UNRELIABLE)." >&2
	sed 's/^/  /' "$_ast_probe_err" >&2
	rm -f "$_ast_probe_err"
	exit 2
fi
rm -f "$_ast_probe_err"
export VERIFY_ANCHORS_RESOURCE_DIR

# _run_ast SUBCOMMAND ARGS... - the ONE checked entry point for every python/libclang
# invocation (review round 2, F-07: "other verdict-critical invocations remain
# unchecked" - closed by never having more than one call site to check). Captures
# stdout/stderr, checks the exit code; prints stdout and returns 0 on success, prints
# nothing and returns 1 on ANY failure (the caller decides UNRELIABLE vs. something
# softer - here, always UNRELIABLE, there is no softer option for a structural question).
_run_ast() {
	local errf out rc
	errf="$(mktemp)" || {
		echo "verify-anchors: _run_ast: mktemp failed - cannot capture AST helper stderr" >&2
		return 1
	}
	out="$(python3 "$AST_HELPER" "$@" 2>"$errf")"
	rc=$?
	if [[ "$rc" -ne 0 ]]; then
		echo "verify-anchors: AST helper failed (exit ${rc}) for: $*" >&2
		sed 's/^/    /' "$errf" >&2
		rm -f "$errf"
		return 1
	fi
	rm -f "$errf"
	printf '%s' "$out"
	return 0
}

# ---- the pin ref must resolve once there IS TARGET code to check -------------
# Defaults from port/TRACE.yaml meta: source_commit (the local import commit) and source_root (the
# pinned SOURCE subtree); SOURCE_PIN_REF / --ref and SOURCE_SUBDIR override them. A TRACE that
# cannot be read is UNRELIABLE, never an empty default.
if [[ -z "${SOURCE_PIN_REF:-}" ]]; then
	SOURCE_PIN_REF="$(_trace_meta source_commit)" || {
		echo "verify-anchors: cannot read meta.source_commit from '${TRACE_FILE}' (see above) (UNRELIABLE)." >&2
		exit 2
	}
fi
if [[ -z "${SOURCE_SUBDIR:-}" ]]; then
	SOURCE_SUBDIR="$(_trace_meta source_root)" || {
		echo "verify-anchors: cannot read meta.source_root from '${TRACE_FILE}' (see above) (UNRELIABLE)." >&2
		exit 2
	}
fi
SOURCE_SUBDIR="${SOURCE_SUBDIR:-source}"
SOURCE_SUBDIR="${SOURCE_SUBDIR%/}"
_load_declared_helpers || exit 2
_load_translated || exit 2
# Anchors may now exist, so an unresolvable pin is a genuine "cannot run" (exit 2).
# No fallback: an explicitly requested pin that cannot be resolved is UNRELIABLE,
# naming it. TRACE meta records the local import commit, so a fallback is unnecessary
# and would mask a bad pin.
if ! git rev-parse --verify --quiet "${SOURCE_PIN_REF}^{commit}" >/dev/null; then
	cat >&2 <<EOF
verify-anchors: SOURCE pin ref '${SOURCE_PIN_REF}' does not resolve in this repo.
  Set port/TRACE.yaml meta source_commit (or SOURCE_PIN_REF / --ref) to the LOCAL import
  commit that introduced the imported SOURCE (or a tag pointing at it). The upstream
  commit (TRACE meta upstream_commit, port/provenance/<name>.yaml) is provenance only:
  once the SOURCE is copied in it is not an object in this repo. The local import commit
  is normally the oldest commit touching the SOURCE tree:
    git log --reverse --format=%H -- ${SOURCE_SUBDIR} | head -1
EOF
	exit 2
fi
PIN_SHA="$(git rev-parse --short "${SOURCE_PIN_REF}^{commit}")"

# ---- source cache (scratch itself already created above) --------------------
declare -A SRC_TOTAL # path -> line count, or -1 if absent at the pin ref
declare -A SRC_SEEN

ensure_src() {
	local path="$1"
	[[ -n "${SRC_SEEN[$path]:-}" ]] && return 0
	SRC_SEEN[$path]=1
	local out="$TMP/src/$path"
	mkdir -p "$(dirname "$out")"
	if git show "${SOURCE_PIN_REF}:${SOURCE_SUBDIR}/${path}" >"$out" 2>/dev/null; then
		# Correct line count: awk NR counts logical lines even without final newline
		# (wc -l counts newline bytes and undercounts by 1). No fallback to wc -l:
		# libclang is the authority for TARGET, awk NR is the single correct counter
		# for SOURCE (deleted wc -l path per B18).
		SRC_TOTAL[$path]="$(awk 'END{print NR}' "$out")"
	else
		SRC_TOTAL[$path]=-1
	fi
}
src_line() { sed -n "${2}p" "$TMP/src/$1"; }

# ---- checked awk invocation (review round 2, F-07) ---------------------------
# EVERY awk program this script still runs for a verdict-affecting purpose goes through
# this ONE choke point - never a bare `awk ...` - so a broken/shadowed interpreter
# (present and executable, but failing: a hostile PATH override, a wrong I/O condition)
# is NEVER indistinguishable from "this awk program legitimately produced no output".
# Round 1 closed this for the file-level anchor extractor (below) and `find`; round 2's
# review (F-07) found the SAME hole still open in every SMALLER helper - closed here for
# both of the two that remain in bash (extract_numerics, rconst_call_args below; the
# structural helpers that used to have the same shape - extract_connectors, rconst_unwrap,
# the connector normalizer - were RETIRED, not hardened: the question they existed to
# answer moved to the AST helper above, which doesn't have this failure class at all).
# Usage: _checked_awk <awk-args...> (exactly what you would pass to `awk`). Prints the
# program's stdout on success and returns 0; on ANY failure (nonzero exit OR non-empty
# stderr) prints nothing to stdout, prints the captured stderr to this process's stderr,
# and returns 1 - every caller below checks $? immediately (a command substitution's
# exit status is the exit status of the command that produced it).
_checked_awk() {
	local errf out rc
	errf="$(mktemp)" || {
		echo "verify-anchors: _checked_awk: mktemp failed - cannot capture awk stderr" >&2
		return 1
	}
	out="$(awk "$@" 2>"$errf")"
	rc=$?
	if [[ "$rc" -ne 0 || -s "$errf" ]]; then
		echo "verify-anchors: _checked_awk: awk failed (exit ${rc})" >&2
		sed 's/^/    /' "$errf" >&2
		rm -f "$errf"
		return 1
	fi
	rm -f "$errf"
	printf '%s' "$out"
	return 0
}

# ---- numeric-literal tokenizer ----------------------------------------------
# Emits each numeric literal in a literal-as-read, one per line. Identifiers are
# consumed whole, so digits embedded in a name (real32, real64) are NOT emitted.
# Non-zero exit (via _checked_awk) means the extraction FAILED - the caller must never
# treat that the same as "genuinely no numeric literals" (review round 2, F-07's own
# reproduction: an `awk` broken for exactly this call made a real sign defect GREEN).
extract_numerics() {
	_checked_awk -v s="$1" '
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

# A numeric value is "present" in the target line if its literal text appears at a NUMERIC TOKEN
# BOUNDARY (not merely as a substring), OR an arithmetically-equal floating spelling does. The
# boundary matters both ways: a LEFT-adjacent digit means a different value ('9.81' must NOT match
# inside '19.81', nor '8' inside '18'); on the RIGHT an INTEGER is bounded too ('8' != '80'), but a
# FLOAT carries value-preserving trailing zeros / exponent spelling (2. == 2.0 == 2.00; Fortran
# `E+100` == C `e100`), so its right side stays lenient. (A raw substring test PASSED a wrong value
# that merely contained the right one - a real false negative; the differential proof is the deeper
# backstop, but this check must not pass a wrong constant.) Returns 0 if present.
_vp_match() { # literal, tline -> 0 if the literal is present at a numeric token boundary
	local lit="$1" t="$2" e tail
	e="${lit//\\/\\\\}"
	e="${e//./\\.}"
	e="${e//+/\\+}"
	e="${e//\*/\\*}"
	# The boundary class excludes digit, dot, AND identifier chars (letter/underscore), so a literal
	# never matches inside a longer number ('9.81' in '19.81'), an identifier ('8' in 'n8'), or an
	# exponent token ('8' in '1e8'). The RIGHT tail allows only VALUE-PRESERVING spellings:
	if [[ "$lit" == *[eEdD]* ]]; then
		tail='([^0-9.A-Za-z_]|$)' # exponent literal: strict (every exponent digit is significant: 1.0e100 != 1.0e1000)
	elif [[ "$lit" == *.* ]]; then
		tail='0*([^0-9.A-Za-z_]|$)' # plain float: trailing fraction zeros only (2. == 2.0; 9.81 != 9.812, != 9.81e2)
	else
		tail='(\.0*)?([^0-9.A-Za-z_]|$)' # integer: may render as N.0 (8 == 8.0; 8 != 80, != 8.5, != 18)
	fi
	[[ "$t" =~ (^|[^0-9.A-Za-z_])${e}${tail} ]]
}
value_present() {
	local n="$1" tline="$2" alt
	_vp_match "$n" "$tline" && return 0
	if [[ "$n" == *[eEdD]* ]]; then
		alt="${n//[EeDd]/e}" # normalize exponent marker to lowercase e
		alt="${alt//e+/e}"   # drop the redundant + after the exponent marker
		_vp_match "$alt" "$tline" && return 0
	fi
	return 1
}

# ---- structural expression-shape fidelity: MOVED to lib/verify_anchors_ast.py --------
# Review round 1 (F-01) added a hand-rolled sign/operator connector tokenizer here; round
# 2 (F-05) found it still had false-GREEN paths (unspaced initializers bypassed its
# expression-boundary finder; repeated unary operators collapsed to one pending
# connector instead of being counted). Rather than patch the SAME approach a third time,
# this question - "does the TARGET expression have the same operator/sign STRUCTURE as
# the SOURCE literal-as-read text" - moved to a real C parser (libclang, via
# `_run_ast structcmp`, used below in check_rendering_ast). See this file's header and
# lib/verify_anchors_ast.py's own header for the full reasoning.

# ---- RCONST-aware dual-precision literal check (non-definition lines only - see
# check_rendering_ast below for the AST-confirmed-definition-line path) --------------
# rconst_call_args MACRO LINE - print each MACRO(...) call's argument text found in LINE, one
# per line (balanced-paren aware, so a nested-paren argument like `RCONST((a+b))` is captured
# whole rather than truncated at the first ")"). A plain awk scan, not a regex, because POSIX
# ERE (bash's own [[ =~ ]]) has no lookbehind to enforce the identifier BOUNDARY before the
# macro name (so a same-suffixed identifier, e.g. `MYRCONST(...)`, cannot be mistaken for a
# call to `RCONST`). Routed through _checked_awk (review round 2, F-07): a failure here must
# never be silently indistinguishable from "no macro call present" - the exact shape of the
# review's own reproduction (a broken awk made a wrongly-macro-wrapped fixed-kind literal,
# the reverse trap, read as correctly-unwrapped and pass).
rconst_call_args() {
	_checked_awk -v macro="$1" -v s="$2" '
    BEGIN {
        mlen = length(macro); i = 1; n = length(s)
        while (i <= n) {
            if (substr(s, i, mlen) == macro) {
                before = (i == 1) ? "" : substr(s, i - 1, 1)
                after = substr(s, i + mlen, 1)
                if (before !~ /[A-Za-z0-9_]/ && after == "(") {
                    j = i + mlen + 1; depth = 1; arg = ""
                    while (j <= n && depth > 0) {
                        ch = substr(s, j, 1)
                        if (ch == "(") depth++
                        else if (ch == ")") { depth--; if (depth == 0) break }
                        if (depth > 0) arg = arg ch
                        j++
                    }
                    print arg
                    i = j + 1
                    continue
                }
            }
            i++
        }
    }'
}
# rconst_wrapped_value MACRO N TLINE - THREE-state, never two (review round 2, F-07): 0 and
# prints the matching call's argument text if N's value is present (at a numeric token
# boundary, via _vp_match) as/within some MACRO(...) argument in TLINE; 1 if the scan
# genuinely completed and found no such call; 2 if the scan itself could not be completed
# (rconst_call_args failed) - a caller that only checked 0-vs-nonzero could not tell "not
# wrapped" from "could not determine if it is wrapped", which is exactly how a broken awk
# made a wrongly-wrapped fixed-kind literal (the reverse trap) read as correctly plain.
# Captured to a variable and iterated via a here-string (never `< <(...)`  process
# substitution): a process substitution's exit status cannot be checked reliably, which
# would silently reopen the same hole this rewrite closes.
rconst_wrapped_value() {
	local macro="$1" n="$2" tline="$3" args_out rc arg
	args_out="$(rconst_call_args "$macro" "$tline")"
	rc=$?
	[[ "$rc" -ne 0 ]] && return 2
	[[ -z "$args_out" ]] && return 1
	while IFS= read -r arg; do
		[[ -z "$arg" ]] && continue
		_vp_match "$n" "$arg" && {
			printf '%s' "$arg"
			return 0
		}
	done <<<"$args_out"
	return 1
}
# check_rconst_literal N TLINE IS_DEF - the ONLY correct TARGET rendering of a build-dependent
# literal (bare default-real under DEFAULT_REAL=rconst, or a literal kinded via RCONST_KINDS -
# trap P1) is <macro>(<value>): ONE token that expands to TWO different literals depending on
# which pinned-precision build compiles it (identity in the double build; the value with an f
# suffix token-pasted on in the single build - conventions section 6). This is verified
# against BOTH resulting expansions from the ONE captured argument - not just whichever
# rendering the invocation happens to statically resemble - because a plain (unwrapped) or a
# bare-f-suffixed rendering is correct in AT MOST one of the two builds and silently WRONG,
# every time, in the other: exactly the gap "conventions" left open (fortran-to-c.md section 4:
# "no notion of one SOURCE line, two different TARGET tokens depending on which of the two
# builds compiles it"). Sets RENDER_REASON; returns 0 ok, 1 violation, 2 UNRELIABLE.
check_rconst_literal() {
	local n="$1" tline="$2" is_def="$3" arg rc
	arg="$(rconst_wrapped_value "$RCONST_MACRO" "$n" "$tline")"
	rc=$?
	if [[ "$rc" -eq 2 ]]; then
		RENDER_REASON="build-dependent literal '${n}': could not determine whether it is macro-wrapped (the internal RCONST-argument scanner failed) - never silently treated as unwrapped"
		return 2
	fi
	if [[ "$rc" -eq 0 ]]; then
		# dp expansion: the argument itself (identity macro) - already value-matched by
		# rconst_wrapped_value above, so it is confirmed correct for the double build.
		# sp expansion: the SAME argument with an 'f' suffix token-pasted on - confirm it is
		# still a clean, value-preserving C floating-constant spelling (digits/'.'/exponent
		# only) rather than assume any captured argument text is safe to paste an 'f' onto.
		if [[ "$arg" == *[0-9]* && "$arg" =~ ^[0-9]*\.?[0-9]*([eE][+-]?[0-9]+)?$ ]]; then
			return 0
		fi
		RENDER_REASON="build-dependent literal '${n}' rendered '${RCONST_MACRO}(${arg})', but '${arg}' is not a clean numeral - its sp-build token-paste ('${arg}f') would not be a valid, value-preserving C float literal"
		return 1
	fi
	if [[ "$tline" == *"${n}f"* ]]; then
		RENDER_REASON="build-dependent literal '${n}' rendered bare f-suffixed ('${n}f'); correct ONLY in the sp build - WRONG (precision loss) in dp. Must render '${RCONST_MACRO}(${n})' (trap P1/T1)"
		return 1
	fi
	if value_present "$n" "$tline"; then
		[[ "$is_def" -eq 1 ]] || return 0 # non-definition line: rendering is proof-governed
		RENDER_REASON="build-dependent literal '${n}' rendered plain/unwrapped; correct ONLY in the dp build - WRONG (silently stays double, never rounded to float) in sp. Must render '${RCONST_MACRO}(${n})' (trap P1/T1)"
		return 1
	fi
	[[ "$is_def" -eq 1 ]] || return 0
	RENDER_REASON="build-dependent literal '${n}' not found in TARGET line (expected '${RCONST_MACRO}(${n})')"
	return 1
}

# ---- check 3: TARGET rendering ----------------------------------------------
# Sets RENDER_REASON; returns 0 ok, 1 violation, 2 untested literal form.
check_rendering() {
	local literal="$1" tline="$2" is_def="${3:-1}" n kindp kw arg _rwv_rc
	RENDER_REASON=""
	# Nothing rendered on this line (a stand-alone /* src: ... */ documentation anchor leaves the
	# code part empty once the comment is stripped): the value, if any, is rendered - and
	# checked - on the code line it annotates, not here. Nothing to assert on this line.
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
	# proof / the naming map, not by a literal here (lesson L-0009). Nothing to assert.
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
		if [[ -z "$kindp" ]]; then
			for kw in $RCONST_KINDS; do
				[[ "$literal" == *"${n}_${kw}"* || "$literal" == *"${n}_${kw^^}"* ]] && {
					kindp=rconst
					break
				}
			done
		fi
		if [[ "$kindp" == double ]]; then
			# RCONST-wrapping a FIXED-double literal is the trap in reverse: the macro's sp
			# expansion token-pastes an f suffix, which would silently turn this always-double
			# kind into a float in the sp build ONLY - checked before the plain-rendering path
			# below so the failure names the actual mistake, not a generic "not found". THREE
			# states (review round 2, F-07): rconst_wrapped_value's own scan failing must be
			# UNRELIABLE, never silently treated as "not wrapped" (the review's own
			# reproduction: exactly this fail-open made the reverse trap read as correct).
			arg="$(rconst_wrapped_value "$RCONST_MACRO" "$n" "$tline")"
			_rwv_rc=$?
			if [[ "$_rwv_rc" -eq 2 ]]; then
				RENDER_REASON="fixed-double literal '${n}': could not determine whether it is wrongly RCONST-wrapped (internal argument scanner failed) - never silently passed"
				return 2
			fi
			if [[ "$_rwv_rc" -eq 0 ]]; then
				RENDER_REASON="fixed-double literal '${n}' rendered via ${RCONST_MACRO}(${arg}); that macro token-pastes an f suffix in the sp build, which would WRONGLY turn this ALWAYS-double literal into a float in sp (trap P1) - render plain '${n}', no macro"
				return 1
			fi
			if [[ "$tline" == *"${n}f"* ]]; then
				RENDER_REASON="kind-suffixed double literal '${n}' must render as a double ('${n}', no f suffix); an f suffix rounds to float (trap T1)"
				return 1
			fi
			value_present "$n" "$tline" && continue
			[[ "$is_def" -eq 1 ]] || continue # non-definition line: rendering is proof-governed
			RENDER_REASON="kind-suffixed double literal '${n}' not found in TARGET line"
			return 1
		elif [[ "$kindp" == single ]]; then
			# Symmetric guard: RCONST-wrapping a FIXED-single literal renders PLAIN (no f) in
			# the dp expansion, which would WRONGLY turn this always-float kind into a double
			# in the dp build ONLY. Same three-state treatment as the double branch above.
			arg="$(rconst_wrapped_value "$RCONST_MACRO" "$n" "$tline")"
			_rwv_rc=$?
			if [[ "$_rwv_rc" -eq 2 ]]; then
				RENDER_REASON="fixed-single literal '${n}': could not determine whether it is wrongly RCONST-wrapped (internal argument scanner failed) - never silently passed"
				return 2
			fi
			if [[ "$_rwv_rc" -eq 0 ]]; then
				RENDER_REASON="fixed-single literal '${n}' rendered via ${RCONST_MACRO}(${arg}); that macro renders plain (no f) in the dp build, which would WRONGLY turn this ALWAYS-float literal into a double in dp (trap P1) - render f-suffixed '${n}f' directly, no macro"
				return 1
			fi
			[[ "$tline" == *"${n}f"* ]] && continue
			RENDER_REASON="kind-suffixed single literal '${n}' must render f-suffixed ('${n}f') in TARGET (trap T1)"
			return 1
		elif [[ "$kindp" == rconst ]]; then
			# Build-dependent, explicitly-kinded literal (trap P1) - identical treatment to a
			# bare default-real literal under DEFAULT_REAL=rconst, below. Propagate the ACTUAL
			# return code ($?, not a hardcoded 1) - check_rconst_literal can now return 2
			# (UNRELIABLE); collapsing that to 1 would misreport "could not determine" as RED.
			check_rconst_literal "$n" "$tline" "$is_def" || return $?
			continue
		fi
		if [[ "$n" == *[dD]* ]]; then
			RENDER_REASON="double-exponent literal '$n': its d->e rendering rule (CONVENTIONS section 4) is not seed-tested in this verifier; extend and seed-test before relying on it (rule 7)"
			return 2
		elif [[ "$n" == *.* || "$n" == *[eE]* ]]; then
			# default (unsuffixed) Fortran real - three mutually exclusive regimes (DEFAULT_REAL).
			if [[ "$DEFAULT_REAL" == rconst ]]; then
				check_rconst_literal "$n" "$tline" "$is_def" || return $?
				continue
			fi
			if [[ "$DEFAULT_REAL" == double ]]; then
				if [[ "$tline" == *"${n}f"* ]]; then
					RENDER_REASON="default-real literal '${n}' (double-default regime) must render as a double ('${n}', no f suffix); an f suffix rounds to float (trap T1)"
					return 1
				fi
				value_present "$n" "$tline" && continue
				[[ "$is_def" -eq 1 ]] || continue # non-definition line: rendering is proof-governed
				RENDER_REASON="default-real literal '$n' not found in TARGET line"
				return 1
			fi
			[[ "$tline" == *"${n}f"* ]] && continue
			RENDER_REASON="default-single literal '$n' must render f-suffixed ('${n}f') in TARGET (trap T1)"
			return 1
		else
			# integer literal -> must appear unsuffixed
			value_present "$n" "$tline" && continue
			[[ "$is_def" -eq 1 ]] || continue # non-definition line: rendering is proof-governed
			RENDER_REASON="integer literal '$n' not found in TARGET line"
			return 1
		fi
	done <<<"$nums"
	return 0
}

# ---- check 3, AST path: TARGET rendering for an AST-CONFIRMED definition line -------
# check_rendering_ast LITERAL FILE LINE - used ONLY when `decls` (the AST helper) has
# already confirmed a real VAR/ENUM/DEFINE constant-providing declaration sits at LINE in
# FILE (the driver decides is_def this way now - see the per-file loop below - not the old
# keyword-regex heuristic). Delegates the STRUCTURAL question (same operators, same
# nesting, same arity - trap B2, review F-01/F-05) to libclang via `_run_ast structcmp`,
# and keeps the VALUE/RCONST-wrap-correctness verdict here in bash (project policy - which
# kinds are DOUBLE_KINDS/SINGLE_KINDS/RCONST_KINDS - not a C-syntax fact; unchanged from
# round 1, just now driven by AST-confirmed leaf pairs instead of a hand-rolled scan of
# the raw line). Sets RENDER_REASON; returns 0 ok, 1 violation, 2 UNRELIABLE.
check_rendering_ast() {
	local literal="$1" file="$2" line="$3"
	case "$literal" in
	.false. | .FALSE. | .true. | .TRUE.)
		RENDER_REASON="internal error: a logical literal reached the AST structural path (should have been handled earlier)"
		return 2
		;;
	esac
	local nums _en_rc
	nums="$(extract_numerics "$literal")"
	_en_rc=$?
	if [[ "$_en_rc" -ne 0 ]]; then
		RENDER_REASON="numeric pre-check failed for '${literal}' (awk) - could not determine whether this literal needs structural comparison"
		return 2
	fi
	# No numeric literals: type alias (real32/dp), derived constant (akap*cp), or a pure
	# reference. Rendering is governed by the typedef / the R0 bit-equivalence proof / the
	# naming map, not by a literal here (lesson L-0009). Nothing to assert - unchanged.
	[[ -z "$nums" ]] && return 0

	local out rc
	out="$(_run_ast structcmp "$file" "$line" "$literal" "$RCONST_MACRO")"
	rc=$?
	if [[ "$rc" -ne 0 ]]; then
		RENDER_REASON="structural comparison could not be completed for '${literal}' at ${file}:${line} (AST helper failed - see stderr above)"
		return 2
	fi
	if [[ -z "$out" ]]; then
		RENDER_REASON="structural comparison for '${literal}' at ${file}:${line} produced no output (expected at least one LEAF or a MISMATCH row) - could not be determined"
		return 2
	fi

	local first_line="${out%%$'\n'*}"
	if [[ "$first_line" == MISMATCH$'\t'* ]]; then
		RENDER_REASON="structural mismatch: ${first_line#MISMATCH$'\t'}"
		return 1
	fi

	# LEAF rows, one per numeral in left-to-right order: <source-text> <target-text>
	# <0|1 was-inside-macro(...)>. Value + RCONST-wrap-correctness per leaf, reusing the
	# SAME kind classification (DOUBLE_KINDS/SINGLE_KINDS/RCONST_KINDS) as the non-AST
	# path above - unchanged project policy, just AST-confirmed pairing instead of a
	# hand-rolled scan of the raw TARGET line.
	local rec n tgt wrapped kindp kw
	while IFS=$'\t' read -r rec n tgt wrapped; do
		[[ "$rec" == "LEAF" ]] || continue
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
		if [[ -z "$kindp" ]]; then
			for kw in $RCONST_KINDS; do
				[[ "$literal" == *"${n}_${kw}"* || "$literal" == *"${n}_${kw^^}"* ]] && {
					kindp=rconst
					break
				}
			done
		fi
		if [[ -z "$kindp" ]]; then
			if [[ "$n" == *[dD]* ]]; then
				RENDER_REASON="double-exponent literal '${n}': its d->e rendering rule is not seed-tested here; extend and seed-test before relying on it (rule 7)"
				return 2
			elif [[ "$n" == *.* || "$n" == *[eE]* ]]; then
				kindp="$DEFAULT_REAL" # single|double|rconst - the SAME three-regime config
			else
				kindp="int"
			fi
		fi

		case "$kindp" in
		double)
			if [[ "$wrapped" -eq 1 ]]; then
				RENDER_REASON="fixed-double literal '${n}' rendered via ${RCONST_MACRO}(${tgt}); that macro token-pastes an f suffix in the sp build, which would WRONGLY turn this ALWAYS-double literal into a float in sp (trap P1) - render plain '${n}', no macro"
				return 1
			fi
			if [[ "$tgt" == *f ]]; then
				RENDER_REASON="fixed-double literal '${n}' rendered f-suffixed ('${tgt}'); an f suffix rounds to float (trap T1) - render plain '${n}'"
				return 1
			fi
			if ! value_present "$n" "$tgt"; then
				RENDER_REASON="fixed-double literal '${n}' rendered as '${tgt}' - values differ"
				return 1
			fi
			;;
		single)
			if [[ "$wrapped" -eq 1 ]]; then
				RENDER_REASON="fixed-single literal '${n}' rendered via ${RCONST_MACRO}(${tgt}); that macro renders plain (no f) in the dp build, which would WRONGLY turn this ALWAYS-float literal into a double in dp (trap P1) - render f-suffixed '${n}f' directly, no macro"
				return 1
			fi
			if [[ "$tgt" != *f ]]; then
				RENDER_REASON="fixed-single literal '${n}' rendered '${tgt}' without an f suffix (trap T1) - must render f-suffixed ('${n}f')"
				return 1
			fi
			if ! value_present "$n" "${tgt%f}"; then
				RENDER_REASON="fixed-single literal '${n}' rendered as '${tgt}' - values differ"
				return 1
			fi
			;;
		rconst)
			if [[ "$wrapped" -ne 1 ]]; then
				if [[ "$tgt" == *f ]]; then
					RENDER_REASON="build-dependent literal '${n}' rendered bare f-suffixed ('${tgt}'); correct ONLY in the sp build - WRONG (precision loss) in dp. Must render '${RCONST_MACRO}(${n})' (trap P1/T1)"
				else
					RENDER_REASON="build-dependent literal '${n}' rendered plain/unwrapped ('${tgt}'); correct ONLY in the dp build - WRONG (silently stays double, never rounded to float) in sp. Must render '${RCONST_MACRO}(${n})' (trap P1/T1)"
				fi
				return 1
			fi
			if [[ "$tgt" != *[0-9]* || ! "$tgt" =~ ^[0-9]*\.?[0-9]*([eE][+-]?[0-9]+)?$ ]]; then
				RENDER_REASON="build-dependent literal '${n}' rendered '${RCONST_MACRO}(${tgt})', but '${tgt}' is not a clean numeral - its sp-build token-paste would not be a valid, value-preserving C float literal"
				return 1
			fi
			if ! value_present "$n" "$tgt"; then
				RENDER_REASON="build-dependent literal '${n}' rendered '${RCONST_MACRO}(${tgt})' - values differ"
				return 1
			fi
			# anchor-verifier-p002 (P-002 CLOSED): the checks above prove invocation
			# spelling/structure; the REAL macro's contract is now PROVEN (not sampled)
			# via syntactic inspection of its defining header (rconst-contract-prove) -
			# both identity and x##f branches verified. Memoized per file.
			if [[ -z "${RCONST_CONTRACT_OK[$file]:-}" ]]; then
				if ! _run_ast rconst-contract-prove "$file" "$RCONST_MACRO" "$RCONST_DP_DEFINE" >/dev/null; then
					RENDER_REASON="the real '${RCONST_MACRO}' macro reachable from '${file}' does not PROVE the pinned dual-precision contract (both branches via header definition) - see stderr above (anchor-verifier-p002, P-002 proved)"
					return 2
				fi
				RCONST_CONTRACT_OK[$file]=1
			fi
			;;
		int)
			if [[ "$wrapped" -eq 1 ]]; then
				RENDER_REASON="integer literal '${n}' wrongly wrapped in ${RCONST_MACRO}(...) - integers are never macro-wrapped, in either build"
				return 1
			fi
			if ! value_present "$n" "$tgt"; then
				RENDER_REASON="integer literal '${n}' rendered as '${tgt}' - values differ"
				return 1
			fi
			;;
		esac
	done <<<"$out"
	return 0
}

# ---- anchor extraction (single awk pass per file) ----------------------------
# Emits TAB-separated records:
#   A <lineno> <payload> <code-only>     src anchor; payload is text between "/* src:"
#       and "*/"; code-only is target line with anchor comment removed.
#   H <lineno> <payload> <code-only>     runtime-helper anchor (new, anchor-verifier-p002).
#   D <lineno>                           malformed/wrapped anchor with no closing */
# check3 compares against code-only, so anchor text cannot mask wrong initializer.
# Coverage (F-02/F-06) and wrong-anchor-grammar (F-04) live in AST helper + driver.
#
# Two fixes vs prior:
#  - wc -l undercount fixed in ensure_src (above); this extractor now buffers a
#    wrapped anchor across up to 5 physical lines so clang-format reflow of a long
#    #define does not silently break an otherwise-valid anchor. A genuinely unterminated
#    anchor (no */ within 5 lines) remains D/RED, never silent.
#  - runtime-helper category (port/conventions section 4, trap-table citation).
# ---- anchor extraction via libclang (replaces hand-rolled awk + 5-line buffering hack) --------
# Comments are ONE token regardless of physical lines (B18). This replaces the awk
# buffering hack (up to 5 lines) and the wc -l trailing-newline workaround for TARGET.
# Uses lib/verify_anchors_ast.py `comments` subcommand: TokenKind.COMMENT with real
# extents and cursor.raw_comment binding, so clang-format reflow and missing newline
# are correct by construction, not by heuristic.
# No awk fallback: libclang is the single source of truth for anchor lexing.

# ---- drive the checks the checks -------------------------------------------------------
fails=0
unreliable=0
unreadable=0
extract_failed=0
ast_failed=0
anchors=0
coverage_gaps=0
declare -A DECL_KIND_AT DECL_NAME_AT SEEN_DECL_LINE DECL_AMBIGUOUS_AT DECL_ELEM_COUNT_AT ANCHOR_COUNT_AT HELPER_SEEN_AT
# Keyed by FILE (never reset per file, unlike the arrays above - the real macro contract is
# a whole-file, not a per-declaration, fact; review round 4, F-13).
declare -A RCONST_CONTRACT_OK

echo "verify-anchors: pin ref = ${SOURCE_PIN_REF} (${PIN_SHA}); SOURCE subdir = ${SOURCE_SUBDIR}"
echo "verify-anchors: scanning ${#FILES[@]} TARGET file(s)"
# SCOPE NOTICE (anchor-verifier-p002 closes charter placeholder P-002):
#  - Dual-regime declaration coverage is NOW exhaustive: files conditional on
#    PROJECT_DP are parsed under BOTH regimes and the union is required to be anchored
#    (a capability once proven by a throwaway script is now first-class via the
#    decls dual-regime union in verify_anchors_ast.py).
#  - RCONST contract is NOW PROVEN (not sampled) via syntactic inspection of the
#    dual-precision header (rconst-contract-prove) - both identity and x##f branches
#    verified, not just one sampled value.
#  - Runtime-helper category (port/conventions section 4) is now a complete, valid
#    disposition - GREEN, not UNRELIABLE - with trap-table validation and escape-hatch
#    prevention (see runtime-helper handling below).
if [[ "$_RCONST_AWARE" -eq 1 ]]; then
	echo "verify-anchors: SCOPE (P-002 CLOSED by anchor-verifier-p002): dual-regime coverage PROVEN (both PROJECT_DP regimes unioned); RCONST contract PROVEN via header definition (not sampled); runtime-helper anchors GREEN with trap validation."
else
	echo "verify-anchors: SCOPE (P-002 CLOSED for dual-regime; RCONST-awareness off, runtime-helper GREEN)."
fi
# F-02: RCONST proof must run unconditionally whenever header exists, not lazily.
# If header exists but cannot be located or does not prove, the run is UNRELIABLE.
if [[ "$_RCONST_AWARE" -eq 1 ]]; then
	export TARGET_DIR
	header_cands=()
	if [[ -n "${TARGET_DIR:-}" ]]; then
		header_cands+=("$TARGET_DIR/src/real_precision.h" "$TARGET_DIR/real_precision.h")
	fi
	# Also try via declared helpers file's directory
	_rh=""
	for cand in "${header_cands[@]}"; do
		if [[ -f "$cand" ]]; then _rh="$cand"; break; fi
	done
	if [[ -z "$_rh" && -n "${TARGET_DIR:-}" ]]; then
		_rh=$(find "$TARGET_DIR" -name "*.h" -type f -exec grep -l "define[[:space:]]*${RCONST_MACRO}[[:space:]]*(" {} \; 2>/dev/null | head -1)
	fi
	if [[ -n "$_rh" ]]; then
		echo "verify-anchors: RCONST header proof for '$_rh' (unconditional, F-02)..."
		if ! _run_ast rconst-contract-prove "$_rh" "$RCONST_MACRO" "$RCONST_DP_DEFINE" >/dev/null; then
			echo "verify-anchors: RCONST header '$_rh' does not prove contract (UNRELIABLE, F-02)" >&2
			unreliable=$((unreliable + 1))
		fi
	else
		# Only fail if there is at least one consumer in TARGET_DIR; otherwise header not required for this product
		if grep -r -q "${RCONST_MACRO}(" "$TARGET_DIR" --include="*.c" --include="*.h" 2>/dev/null; then
			echo "verify-anchors: RCONST-aware and TARGET contains ${RCONST_MACRO} consumers but no header defining ${RCONST_MACRO} found in TARGET_DIR (searched $TARGET_DIR/src/real_precision.h, $TARGET_DIR/real_precision.h and grep for define ${RCONST_MACRO} - UNRELIABLE, F-02)" >&2
			unreliable=$((unreliable + 1))
		else
			echo "verify-anchors: RCONST-aware but no header defining ${RCONST_MACRO} found and no consumers in TARGET_DIR - header proof not required for this product"
		fi
	fi
fi
echo

for file in "${FILES[@]}"; do
	[[ -f "$file" ]] || {
		echo "  ${file}: NOT FOUND" >&2
		fails=$((fails + 1))
		continue
	}
	# A file the scan found but cannot READ (permission denied) must not silently contribute
	# zero anchors and zero coverage gaps - indistinguishable from a genuinely clean file, and
	# exactly the vacuous-pass shape the truncation guard above closes for the SCAN itself; this
	# closes it for an individual FILE the scan did enumerate. Coverage could not be determined
	# here, so this run cannot certify GREEN - UNRELIABLE, not silently skipped.
	[[ -r "$file" ]] || {
		echo "  ${file}: UNREADABLE - cannot determine its anchors/coverage" >&2
		unreliable=$((unreliable + 1))
		unreadable=$((unreadable + 1))
		continue
	}
	echo "== ${file} =="
	# Project-internal headers a REAL `#include "..."` in THIS file might reference beyond
	# the quote-include-relative-to-the-file default (review round 4, F-12 - the AST helper
	# now needs a genuinely fair chance to resolve every real header before its
	# diagnostics-clean check means anything). This file's own directory covers the common
	# same-directory case (already the quote-include default, added again here for
	# robustness); TARGET_DIR (when known - the scan root, unset when explicit files were
	# passed with no scan) covers a project-root-relative include from a nested file.
	VERIFY_ANCHORS_INCLUDE_DIRS="$(dirname "$file")${TARGET_DIR:+:$TARGET_DIR}"
	export VERIFY_ANCHORS_INCLUDE_DIRS
	# Per-declaration helper tracking (F-01): a helper anchor only covers the
	# declaration on its own line, never siblings. Unanchored constants are always gaps,
	# regardless of file. The file's kind (helper vs translated) is DECLARED in
	# port/declared-helpers.yaml / TRACE, not inferred; unlisted basenames are UNRELIABLE.
	# Emptied per file, not redeclared: `declare -A` on an already-declared associative array
	# does NOT clear it, so an exemption keyed by an earlier file's line number would survive
	# into this file and exempt an unrelated declaration that happens to sit on that line.
	HELPER_SEEN_AT=()
	header_proven=0
	file_basename="$(basename "$file")"
	file_basename_lc="$(echo "$file_basename" | tr '[:upper:]' '[:lower:]')"
	file_stem_lc="$(echo "$file_basename" | sed -E 's/\.[^.]+$//' | tr '[:upper:]' '[:lower:]')"
	is_helper_declared=0
	is_translated_declared=0
	[[ -n "${_DECLARED_HELPER_SET["$file_basename_lc"]:-}" ]] && is_helper_declared=1
	[[ -n "${_TRANSLATED_STEM_SET["$file_stem_lc"]:-}" ]] && is_translated_declared=1
	is_undeclared=0
	if [[ "$is_helper_declared" -eq 0 && "$is_translated_declared" -eq 0 ]]; then
		is_undeclared=1
	fi
	# The extractor's own success must be checked, not assumed - the same fail-open shape as
	# the earlier `find` hole (review round 1, F-03): `awk "$AWK_PROG" "$file"` used to run
	# inside a bare `< <(...)` process substitution whose exit status was never inspected, so
	# a broken/failing `awk` (present on PATH - preflight's `command -v awk` only proves it
	# EXISTS, not that it runs correctly - a wrong I/O condition, an out-of-memory kill, or a
	# genuinely broken interpreter) produced ZERO records and the driver could not tell that
	# apart from a real, clean, anchor-free file: same "0 anchors, 0 violations, GREEN" shape
	# find's silent truncation had. Captured to files and checked, exactly like the find fix.
	# Anchor extraction via libclang (B18): TokenKind.COMMENT with real extents,
	# so a comment is ONE token regardless of physical lines. No awk, no 5-line buffer.
	_comments_out="$(_run_ast comments "$file")"
	_comments_rc=$?
	if [[ "$_comments_rc" -ne 0 ]]; then
		echo "  ${file}: comment extraction FAILED (AST helper exit ${_comments_rc}) - this file's anchors/coverage could not be determined" >&2
		unreliable=$((unreliable + 1))
		extract_failed=$((extract_failed + 1))
		echo
		continue
	fi
	printf '%s\n' "$_comments_out" >"$TMP/comments.out"
	# Also handle D-equivalent: libclang diagnostics for unterminated comments are already
	# captured via _diagnostics_are_clean in comments subcommand, so no separate D record needed
	# for that path; the comments subcommand itself fails UNRELIABLE on unterminated, which is correct.


	# AST declaration scan (review round 2, F-02/F-04/F-06; round 3 rework's own F-08/F-09/
	# F-10). A recursive, fail-closed real parse (lib/verify_anchors_ast.py's `decls`, moved
	# there so "what does this file declare" is answered EXACTLY once, correctly, for every
	# form and every scope - spaced/unspaced/`==`-bearing/multiline-enum/function-local -
	# instead of enumerated one hand-rolled regex at a time). Its own failure (including a
	# parse diagnostic it does not specifically tolerate - F-09) is UNRELIABLE for this
	# file's coverage/F-04 - never a silent "0 declarations". Each row also carries an
	# `ambiguous` flag (F-10): 1 when MORE THAN ONE constant-providing declaration shares
	# that row's physical line - the anchor grammar embeds exactly one literal-as-read per
	# line and cannot soundly cover two, so DECL_AMBIGUOUS_AT tracks this SEPARATELY from
	# (never folded into) DECL_KIND_AT/DECL_NAME_AT, whose line-keyed "last write wins"
	# would otherwise silently pick one of the colliding declarations as if it were the only
	# one - the exact F-10 defect.
	DECL_KIND_AT=()
	DECL_NAME_AT=()
	SEEN_DECL_LINE=()
	DECL_AMBIGUOUS_AT=()
	# Line-keyed aggregate bookkeeping is per file too: a stale element count or anchor tally
	# from an earlier file at the same line number would change this file's coverage verdict.
	DECL_ELEM_COUNT_AT=()
	ANCHOR_COUNT_AT=()
	_decls_out="$(_run_ast decls "$file")"
	_decls_rc=$?
	if [[ "$_decls_rc" -ne 0 ]]; then
		echo "  ${file}: AST declaration scan FAILED - this file's coverage/anchor-grammar checks could not be determined" >&2
		unreliable=$((unreliable + 1))
		ast_failed=$((ast_failed + 1))
		echo
		continue
	fi
	if [[ -n "$_decls_out" ]]; then
		while IFS=$'\t' read -r _drec _dline _dkind _dname _dambig _delem; do
			[[ "$_drec" == "DECL" ]] || continue
			DECL_KIND_AT["$_dline"]="$_dkind"
			DECL_NAME_AT["$_dline"]="$_dname"
			[[ "$_dambig" == "1" ]] && DECL_AMBIGUOUS_AT["$_dline"]=1
			# For aggregate initializers, _delem is element count for per-element coverage (review F-01/F-02)
			if [[ -n "$_delem" && "$_delem" != "1" ]]; then
				DECL_ELEM_COUNT_AT["$_dline"]="$_delem"
			fi
		done <<<"$_decls_out"
	fi

	file_anchors=0
	# has_helper is now per-line HELPER_SEEN_AT, not file-wide
	# HELPER_SEEN_AT is emptied per file above
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

			# is_def: is this anchor's line a REAL constant-providing declaration, per the
			# AST scan above (never a regex heuristic anymore)?
			# Wrapped anchor: libclang reports comment on next line (lineno) while decl is on previous line (lineno-1)
			is_def=0
			if [[ -n "${DECL_KIND_AT[$lineno]:-}" ]]; then
				is_def=1
			elif [[ -n "${DECL_KIND_AT[$((lineno-1))]:-}" ]]; then
				# Anchor on next line after declaration (wrapped) - treat as covering previous line
				is_def=1
				# For per-declaration tracking, mark previous line as seen
				lineno=$((lineno-1))
			fi

			# F-10: a line carrying MORE THAN ONE constant-providing declaration cannot be
			# unambiguously covered by ANY single anchor there - the anchor grammar embeds
			# exactly one literal-as-read per physical line. Checked FIRST, before the F-04
			# grammar check below: even an anchor that is itself grammatically a valid
			# constant anchor cannot establish WHICH of the colliding declarations it
			# covers, so this is its own distinct, always-a-violation state, never folded
			# into (and never let to silently satisfy) either the F-04 check or ordinary
			# coverage. Marks the line SEEN so the post-loop coverage scan does not ALSO
			# double-report it.
			if [[ -n "${DECL_AMBIGUOUS_AT[$lineno]:-}" ]]; then
				SEEN_DECL_LINE["$lineno"]=1
				echo "  [FAIL] line ${lineno}: check4 - line carries MORE THAN ONE constant-providing declaration; the anchor grammar embeds exactly one literal-as-read per physical line and cannot unambiguously cover more than one - split the declarations onto separate lines"
				fails=$((fails + 1))
				coverage_gaps=$((coverage_gaps + 1))
				continue
			fi

			# F-04: a line the AST scan confirms IS a constant-providing declaration must be
			# anchored with the CONSTANT grammar (`= <literal-as-read>`) - a routine/module/
			# note anchor there used to read as "OK" AND exempt the line from coverage (any
			# "/* src:" suppressed it), so check2/check3 never ran and no finding was ever
			# raised: a wrong anchor KIND silently defeated both provenance and coverage at
			# once. Checked before check1 - a grammar defect, not a resolution failure - and
			# reported as BOTH a violation and a coverage gap (no valid constant anchor
			# exists for this line); marks the line SEEN either way so the post-loop coverage
			# scan below does not ALSO double-report it.
			if [[ "$is_def" -eq 1 ]]; then
				SEEN_DECL_LINE["$lineno"]=1
				ANCHOR_COUNT_AT["$lineno"]=$((${ANCHOR_COUNT_AT["$lineno"]:-0} + 1))
				if [[ "$rest" != "= "* ]]; then
					echo "  [FAIL] line ${lineno}: check4 - constant-shaped definition ('${DECL_NAME_AT[$lineno]:-?}', AST kind ${DECL_KIND_AT[$lineno]:-?}) anchored with a non-constant anchor grammar (routine/module/note form); literal-as-read and TARGET rendering cannot be verified this way - use '/* src: <path>:<line> = <literal-as-read> */'"
					echo "         TARGET: ${tcode}"
					fails=$((fails + 1))
					coverage_gaps=$((coverage_gaps + 1))
					continue
				fi
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
				# check 3: TARGET rendering. A logical (.TRUE./.FALSE.) literal is ALWAYS a
				# plain keyword substitution - it has no operator/
				# sign SHAPE for the AST path to compare (check_rendering_ast's own defensive
				# case statement expects never to reach one) - so it is routed to the textual
				# check REGARDLESS of is_def. This distinction became reachable only after this
				# round's F-09 fix taught `decls` to see a `bool` declaration whose type/value
				# are themselves unresolved (no vendored `<stdbool.h>` in this standalone parse -
				# a real, disclosed limitation, not a fixture artifact): previously an AST blind
				# spot happened to leave every logical declaration's is_def at 0 by ACCIDENT, so
				# this branch was silently unexercised, not correctly handled by design.
				# Otherwise, is_def (AST-confirmed above) selects the path: a CONFIRMED
				# constant-providing declaration goes through the STRUCTURAL AST comparison
				# (check_rendering_ast - exact operator/sign shape, trap B2/F-01/F-05); anything
				# else (a general expression/statement/format line, where the literal can
				# legitimately be absent from THIS physical line - rendered on a sibling line of
				# a multi-line statement, or a Fortran FORMAT repeat count) keeps the lenient
				# magnitude-only path (check_rendering, unchanged, is_def=0).
				case "$literal" in
				.false. | .FALSE. | .true. | .TRUE.)
					check_rendering "$literal" "$tcode" 0
					;;
				*)
					if [[ "$is_def" -eq 1 ]]; then
						check_rendering_ast "$literal" "$file" "$lineno"
					else
						check_rendering "$literal" "$tcode" 0
					fi
					;;
				esac
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
		D)
			# Dangling/malformed anchor: "/* src:" or "/* runtime-helper:" opened with no closing "*/" within 5 lines
			lineno="$a"
			echo "  [FAIL] line ${lineno}: malformed/wrapped anchor - '/* src:' or '/* runtime-helper:' opens with no closing '*/' within 5 lines"
			echo "         (auto-formatter wrap beyond 5 lines?); keep the anchor on one physical line or within 5-line buffer"
			fails=$((fails + 1))
			;;
		H)
			lineno="$a"
			payload="$b"
			tcode="$c"
			anchors=$((anchors + 1))
			file_anchors=$((file_anchors + 1))
			# Payload for runtime-helper: "<TRAP> - <description>"
			trap_id="$(echo "$payload" | awk '{print $1}' 2>/dev/null)"
			trap_id="${trap_id%%[-:]*}"
			trap_id="${trap_id//[^A-Za-z0-9]/}"
			if [[ -z "$trap_id" || " $_VALID_TRAPS " != *" $trap_id "* ]]; then
				echo "  [FAIL] line ${lineno}: runtime-helper anchor cites unknown trap '${trap_id}' (payload: '${payload}') - must cite a valid trap-table row (e.g., T15, T5, P1); see port/conventions/fortran-to-c.md section 7"
				fails=$((fails + 1))
				continue
			fi
			# Declared helper check (F-01): file basename must be in declared helpers list
			fname_decl="$(basename "$file")"
			fname_decl_lc="$(echo "$fname_decl" | tr '[:upper:]' '[:lower:]')"
			if [[ -z "${_DECLARED_HELPER_SET["$fname_decl_lc"]:-}" ]]; then
				echo "  [FAIL] line ${lineno}: runtime-helper anchor in '${file}' whose basename '${fname_decl}' is not declared as helper in port/declared-helpers.yaml - undeclared helper is UNRELIABLE, never exempt (F-01, fail-closed; a translated file can never claim helper)" >&2
				unreliable=$((unreliable + 1))
				continue
			fi
			# Per-declaration helper: handle wrapped (comment on next line)
			helper_line="$lineno"
			if [[ -z "${DECL_KIND_AT[$lineno]:-}" && -n "${DECL_KIND_AT[$((lineno-1))]:-}" ]]; then
				helper_line=$((lineno-1))
			fi
			HELPER_SEEN_AT["$helper_line"]=1
			if [[ -n "${DECL_KIND_AT[$helper_line]:-}" ]]; then
				SEEN_DECL_LINE["$helper_line"]=1
			fi
			echo "  [OK]   line ${lineno}: runtime-helper ${trap_id} - ${payload} (helper per-declaration, trap validated, declared helper)"
			;;
		esac
	done < "$TMP/comments.out"

	# check 4, coverage (review round 2, F-02/F-06; round 3 rework's own F-10): every
	# AST-confirmed constant-providing declaration this file has that was NOT already
	# accounted for above (correctly anchored, flagged by F-04 for the wrong anchor
	# grammar, or already flagged above as an F-10 ambiguous line) lacks a provenance
	# anchor entirely. A line this file's ambiguity flag marks (F-10) but that the
	# per-anchor loop above never visited at all - no anchor of ANY form landed there -
	# gets the SAME distinct ambiguous finding here, not the ordinary "lacks a
	# provenance anchor" message: it is not merely uncovered, it is UNCOVERABLE by a
	# single anchor as written. Sorted for deterministic, reproducible output (bash
	# associative-array iteration order is unspecified).
	# Runtime-helper files (has_helper=1): a helper implementing a Fortran LANGUAGE
	# contract has no SOURCE file:line to anchor to, so a per-file runtime-helper
	# anchor covers its internal constants too. Coverage gaps are suppressed for such
	# files - but the file still needed a valid runtime-helper anchor (checked above);
	# a helper file with NO valid helper anchor remains uncovered and fails below
	# Per-declaration helper (F-01): only declarations with a valid runtime-helper
	# anchor on the SAME line are helper-covered. File-wide exemption is removed.
	# Unanchored constants are always gaps, regardless of file. TRACE must be present
	# for any mapping-dependent decision; missing/empty TRACE is UNRELIABLE.
	if [[ ! -f "${TRACE_FILE:-port/TRACE.yaml}" ]] || [[ ! -s "${TRACE_FILE:-port/TRACE.yaml}" ]]; then
		echo "  [WARN] TRACE ${TRACE_FILE:-port/TRACE.yaml} missing or empty - cannot determine helper vs translated mapping (F-01)" >&2
		unreliable=$((unreliable + 1))
		echo
		continue
	fi
	# Undeclared file: not in helpers nor translated -> UNRELIABLE, not RED (F-01)
	if [[ "$is_undeclared" -eq 1 ]]; then
		if [[ ${#DECL_KIND_AT[@]} -gt 0 ]]; then
			echo "  [FAIL] line ${!DECL_KIND_AT[*]}: undeclared file '${file_basename}' (not in port/declared-helpers.yaml nor in TRACE translated stems) carrying bare constant(s) is UNRELIABLE, not RED (F-01, fail-closed: DECLARE it)" >&2
			unreliable=$((unreliable + 1))
		else
			echo "  [FAIL] undeclared file '${file_basename}' (not in port/declared-helpers.yaml nor in TRACE) is UNRELIABLE, not exempt (F-01)" >&2
			unreliable=$((unreliable + 1))
		fi
		echo
		continue
	fi
	while IFS= read -r _dline; do
		[[ -n "$_dline" ]] || continue
		_expected_elems="${DECL_ELEM_COUNT_AT[$_dline]:-1}"
		if [[ "$_expected_elems" != "1" && -n "$_expected_elems" ]]; then
			_actual_anchors="${ANCHOR_COUNT_AT[$_dline]:-0}"
			if [[ "$_actual_anchors" -eq 0 ]]; then
				echo "  [FAIL] line ${_dline}: check4 - aggregate definition ('${DECL_NAME_AT[$_dline]}', ${DECL_ELEM_COUNT_AT[$_dline]} elements) lacks provenance anchors - requires ${DECL_ELEM_COUNT_AT[$_dline]} element-anchors, found 0"
				fails=$((fails + 1))
				coverage_gaps=$((coverage_gaps + 1))
				continue
			elif [[ "$_actual_anchors" -lt "$_expected_elems" ]]; then
				echo "  [FAIL] line ${_dline}: check4 - aggregate definition ('${DECL_NAME_AT[$_dline]}', ${DECL_ELEM_COUNT_AT[$_dline]} elements) has only ${_actual_anchors} anchor(s) - requires ${DECL_ELEM_COUNT_AT[$_dline]} per-element anchors, one per element"
				fails=$((fails + 1))
				coverage_gaps=$((coverage_gaps + 1))
				continue
			fi
			continue
		fi
		[[ -n "${SEEN_DECL_LINE[$_dline]:-}" ]] && continue
		# Wrapped anchor: helper/src on next line still covers this declaration (libclang comment on next line)
		if [[ -n "${HELPER_SEEN_AT[$_dline]:-}" || -n "${HELPER_SEEN_AT[$((_dline+1))]:-}" ]]; then
			continue
		fi
		if [[ -n "${SEEN_DECL_LINE[$((_dline+1))]:-}" ]]; then
			# Also check for src anchor on next line (wrapped)
			continue
		fi
		if [[ -n "${DECL_AMBIGUOUS_AT[$_dline]:-}" ]]; then
			echo "  [FAIL] line ${_dline}: check4 - line carries MORE THAN ONE constant-providing declaration; the anchor grammar embeds exactly one literal-as-read per physical line and cannot unambiguously cover more than one - split the declarations onto separate lines"
		else
			echo "  [FAIL] line ${_dline}: check4 - constant definition ('${DECL_NAME_AT[$_dline]}', AST kind ${DECL_KIND_AT[$_dline]}) lacks a provenance anchor (per-declaration helper required for helper constants)"
		fi
		fails=$((fails + 1))
		coverage_gaps=$((coverage_gaps + 1))
	done < <(printf '%s\n' "${!DECL_KIND_AT[@]}" | sort -n)

	echo "   (${file_anchors} anchor(s))"
	echo
done

# ---- verdict ----------------------------------------------------------------
echo "------------------------------------------------------------"
echo "SUMMARY: ${anchors} anchor(s) checked; ${fails} violation(s); ${coverage_gaps} coverage gap(s); ${unreliable} unreliable (${unreadable} unreadable file(s), ${extract_failed} extraction failure(s), ${ast_failed} AST-scan failure(s))."
if [[ "$unreliable" -gt 0 ]]; then
	if [[ "$ast_failed" -gt 0 ]]; then
		echo "RESULT: UNRELIABLE (exit 2) - ${ast_failed} file(s) failed the AST declaration scan; their coverage/anchor-grammar checks could not be determined - never counted as clean."
	elif [[ "$extract_failed" -gt 0 ]]; then
		echo "RESULT: UNRELIABLE (exit 2) - ${extract_failed} file(s) failed anchor/coverage extraction (awk); their anchors/coverage could not be determined - never counted as clean."
	elif [[ "$unreadable" -gt 0 ]]; then
		echo "RESULT: UNRELIABLE (exit 2) - ${unreadable} TARGET file(s) matched the scan but could not be read; their anchors/coverage could not be determined - never counted as clean."
	else
		echo "RESULT: UNRELIABLE (exit 2) - a literal form, or an expression construct, is not seed-tested/supported; extend the verifier."
	fi
	exit 2
elif [[ "$fails" -gt 0 ]]; then
	echo "RESULT: RED (exit 1) - provenance/rendering/coverage/structural violation."
	exit 1
fi
echo "RESULT: GREEN (exit 0) - all anchors resolve, render, cover, and structurally match (P-002 CLOSED: dual-regime union proven, RCONST contract PROVEN via header definition, runtime-helper validated)."
exit 0
