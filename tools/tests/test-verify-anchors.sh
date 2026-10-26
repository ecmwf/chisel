#!/usr/bin/env bash
# The anchor verifier over a product: tools/conformance/verify-anchors.sh and lib/anchor_driver.py,
# copied into a throwaway workbench git repo whose SOURCE is imported in a commit recorded as
# port/TRACE.yaml meta.source_commit, run over product trees written here. Each case asserts the
# exit code and the finding line (or the summary of a green run).
#
# The SOURCE: a kinds module (a fixed double kind, a working-precision kind switched by a define,
# a derived type), a module whose procedure calls an external routine no SOURCE file defines, a
# module USEing both, a file fparser cannot parse and a module USEing a module no file defines.
# A missing compiler or parser fails this test; it never skips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
unset SOURCE_PIN_REF SOURCE_SUBDIR TARGET_DIR PRODUCT_ROOT

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() {
	printf 'not ok - %s\n' "$1" >&2
	[ -z "${2:-}" ] || sed 's/^/    /' "$2" >&2
	failures=$((failures + 1))
}

for tool in gfortran clang ar git; do
	command -v "$tool" >/dev/null 2>&1 || not_ok "$tool is installed (the verifier needs it)"
done
python3 -c 'import yaml, fparser, clang.cindex as ci; ci.Index.create()' 2>/dev/null \
	|| not_ok "python3 imports yaml, fparser and clang.cindex with its native library"
[ "$failures" -eq 0 ] || exit 1

# ---- the workbench -----------------------------------------------------------------------------
WB="$TMP/wb"
mkdir -p "$WB/tools/conformance" "$WB/port/conventions" "$WB/source/src" \
	"$WB/.opencode/skill/target-conventions/references/pairs"
cp "$ROOT/tools/conformance/verify-anchors.sh" "$WB/tools/conformance/"
cp -R "$ROOT/tools/conformance/lib" "$WB/tools/conformance/"
printf '| T1 | a synthetic trap row |\n| T19 | a synthetic trap row |\n' \
	>"$WB/.opencode/skill/target-conventions/references/pairs/fortran-to-c.md"
printf -- '- f_runtime.h\n' >"$WB/port/declared-helpers.yaml"

cat >"$WB/source/src/kinds.F90" <<'EOF'
MODULE MOD_KINDS
  IMPLICIT NONE
  INTEGER, PARAMETER :: DP = SELECTED_REAL_KIND(13, 300)
#ifdef FIXTURE_DP
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(13, 300)
#else
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(6, 37)
#endif
  TYPE PT
    REAL(WP) :: X = 1.5_WP
    INTEGER :: N = 2
  END TYPE PT
END MODULE MOD_KINDS
EOF
cat >"$WB/source/src/mod_b.F90" <<'EOF'
MODULE MOD_B
  IMPLICIT NONE
  INTEGER, PARAMETER :: NB = 4
  REAL(8) :: SCALE = 0.5D0
  INTEGER, PARAMETER :: NQ = 4
  REAL(8), PARAMETER :: R4 = ((1.0D0 + 0.5D0) / (1.0D0 - 0.5D0))**4
CONTAINS
  SUBROUTINE STEP_B(Y)
    REAL(8), INTENT(INOUT) :: Y
    CALL EXT_ROUTINE(Y)
    Y = Y * SCALE
  END SUBROUTINE STEP_B
END MODULE MOD_B
EOF
cat >"$WB/source/src/mod_a.F90" <<'EOF'
MODULE MOD_A
  USE MOD_KINDS, ONLY: DP, WP, PT
  USE MOD_B, ONLY: SCALE
  IMPLICIT NONE
  REAL(DP), PARAMETER :: G = 9.81_DP
  INTEGER, PARAMETER :: NLEV = 60
  REAL(DP), PARAMETER :: TAB(3) = (/ 1.0_DP, 2.5_DP, 4.0_DP /)
  TYPE(PT), PARAMETER :: P0 = PT(2.5_WP, 3)
  REAL(WP), PARAMETER :: A = 0.1_WP
  REAL(DP) :: XS
CONTAINS
  SUBROUTINE INIT_A(X)
    REAL(DP), INTENT(IN) :: X
    XS = 2.0_DP * X * SCALE
  END SUBROUTINE INIT_A
END MODULE MOD_A
EOF
cat >"$WB/source/src/broken.F90" <<'EOF'
MODULE MOD_BROKEN
  INTEGER, PARAMETER :: K = 3
  INTEGER, PARAMETER :: L = (
END MODULE MOD_BROKEN
EOF
cat >"$WB/source/src/lonely.F90" <<'EOF'
MODULE MOD_LONELY
  USE MOD_MISSING
  INTEGER, PARAMETER :: L = 1
END MODULE MOD_LONELY
EOF
git -C "$WB" init -q -b main
git -C "$WB" config user.name tester
git -C "$WB" config user.email tester@example.invalid
git -C "$WB" add source
git -C "$WB" commit -q -m "import synthetic source"
printf 'meta:\n  source_root: source/\n  source_commit: %s\nfiles: []\n' "$(git -C "$WB" rev-parse HEAD)" \
	>"$WB/port/TRACE.yaml"

# ---- the products --------------------------------------------------------------------------------
P="$TMP/p"
file() { # file CASE PATH - stdin to the product file CASE/PATH
	mkdir -p "$(dirname "$P/$1/$2")"
	cat >"$P/$1/$2"
}
kinds_h() { # kinds_h CASE - the working-precision type and the derived type of MOD_KINDS
	file "$1" include/mod_kinds.h <<'EOF'
#ifndef MOD_KINDS_H
#define MOD_KINDS_H
#ifdef FIXTURE_DP
typedef double real_t;
#else
typedef float real_t;
#endif
typedef struct pt {
	real_t x;
	int n;
} pt;
#endif
EOF
}
mod_a() { # mod_a CASE - MOD_A rendered faithfully, then edited by the sed script $2 (optional)
	kinds_h "$1"
	file "$1" src/mod_a.c <<'EOF'
#include "mod_kinds.h"
static const double mod_a_g = 9.81; /* src: src/mod_a.F90:5 = 9.81_DP */
enum { mod_a_nlev = 60 }; /* src: src/mod_a.F90:6 = 60 */
static const double mod_a_tab[3] = {1.0, 2.5, 4.0}; /* src: src/mod_a.F90:7 = (/ 1.0_DP, 2.5_DP, 4.0_DP /) */
#define MOD_A_P0 {2.5f, 3} /* src: src/mod_a.F90:8 = PT(2.5_WP, 3) */
static const real_t mod_a_a = 0.1f; /* src: src/mod_a.F90:9 = 0.1_WP */
EOF
	[ -z "${2:-}" ] || sed -i "$2" "$P/$1/src/mod_a.c"
}

# expect LABEL EXIT PATTERN CASE [ARGS...] - run the verifier over the product CASE (`-`: no product
# wired, so the default target/); require EXIT and an output line matching the extended regex PATTERN.
expect() {
	local label="$1" want="$2" pattern="$3" case="$4" got=0
	shift 4
	[ "$case" = - ] || set -- --target-dir "$P/$case" "$@"
	(cd "$WB" && bash tools/conformance/verify-anchors.sh "$@") >"$TMP/out.log" 2>&1 || got=$?
	if [ "$got" -ne "$want" ]; then
		not_ok "$label: expected exit $want, got $got" "$TMP/out.log"
	elif ! grep -qE -- "$pattern" "$TMP/out.log"; then
		not_ok "$label: exit $got, but no output line matches: $pattern" "$TMP/out.log"
	else
		ok "$label (exit $got)"
	fi
}
# refute LABEL PATTERN - the last run printed no line matching PATTERN.
refute() {
	if grep -qE -- "$1" "$TMP/out.log"; then not_ok "$2" "$TMP/out.log"; else ok "$2"; fi
}

# ---- GREEN ----------------------------------------------------------------------------------------
# Every rendering faithful: a scalar, an enumerator, an array, a brace-list macro of a derived type
# defined in another SOURCE file, a working-precision constant, a module variable of a module whose
# procedure calls an external routine, and a declared helper file with an unanchored constant.
mod_a green
file green src/mod_b.c <<'EOF'
enum { mod_b_nb = 4 }; /* src: src/mod_b.F90:3 = 4 */
static const double mod_b_scale = 0.5; /* src: src/mod_b.F90:4 = 0.5D0 */
EOF
file green src/f_runtime.h <<'EOF'
static const int f_runtime_unit = 6; /* runtime-helper: T19 - list-directed output unit */
static const int f_runtime_width = 80;
EOF
expect "every anchored constant equal to its SOURCE value is GREEN" 0 \
	'^SUMMARY \[default\]: 7 verified, 0 unverified, 0 red, 0 unreliable$' green

# ---- RED: values ----------------------------------------------------------------------------------
mod_a value 's/mod_a_g = 9.81;/mod_a_g = 9.80;/'
expect "a wrong constant is RED (value)" 1 \
	'^RED src/mod_a\.c:2 mod_a_g \[default\]: mismatch value - SOURCE src/mod_a\.F90:5 G$' value
mod_a kind 's/mod_a_g = 9.81;/mod_a_g = 9.81f;/'
expect "a float literal for a double is RED (kind)" 1 \
	'^RED src/mod_a\.c:2 mod_a_g \[default\]: mismatch kind - SOURCE src/mod_a\.F90:5 G$' kind
mod_a shape 's/{1.0, 2.5, 4.0}/{1.0, 2.5}/'
expect "a missing array element is RED (shape)" 1 \
	'^RED src/mod_a\.c:4 mod_a_tab \[default\]: mismatch shape at \[2\] - SOURCE src/mod_a\.F90:7 TAB$' shape

# ---- RED: anchors and coverage ------------------------------------------------------------------------
mod_a wrongline 's/mod_a\.F90:5 = 9\.81_DP/mod_a.F90:6 = 9.81_DP/'
expect "an anchor citing a wrong line is RED (invalid-anchor)" 1 \
	'^RED src/mod_a\.c:2 mod_a_g \[default\]: invalid-anchor - src/mod_a\.c:2: /\* src: src/mod_a\.F90:6 = 9\.81_DP \*/: the literal-as-read is not on src/mod_a\.F90:6$' wrongline
mod_a cover 's|enum { mod_a_nlev = 60 }; /\* src: src/mod_a.F90:6 = 60 \*/|#define MOD_A_NLEV 60|'
expect "an unanchored constant is RED (coverage)" 1 \
	'^RED src/mod_a\.c:3 MOD_A_NLEV \[default\]: coverage - no anchor binds to MOD_A_NLEV' cover

# ---- UNVERIFIED -----------------------------------------------------------------------------------
file runtime src/mod_a.c <<'EOF'
double mod_a_xs;
double ext_scale(void);
void mod_a_init_a(double x)
{
	mod_a_xs = 2.0 * x * ext_scale(); /* src: src/mod_a.F90:14 = 2.0_DP */
}
EOF
expect "a run-time assignment anchor is UNVERIFIED, never RED or a pass" 0 \
	'^UNVERIFIED src/mod_a\.c:5 \[default\]: not-comparable - the anchor is on a statement' runtime
expect "  ... and counted in the summary" 0 '^SUMMARY \[default\]: 0 verified, 1 unverified, 0 red, 0 unreliable$' runtime

# ---- the USE closure and linking --------------------------------------------------------------------
kinds_h closure
file closure src/mod_a.c <<'EOF'
#include "mod_kinds.h"
static const pt mod_a_p0 = {2.5f, 3}; /* src: src/mod_a.F90:8 = PT(2.5_WP, 3) */
EOF
expect "a constant whose type is defined in a module of another file passes (closure compiled)" 0 \
	'^SUMMARY \[default\]: 1 verified, 0 unverified, 0 red, 0 unreliable$' closure
file external src/mod_b.c <<'EOF'
double ext_c_routine(double);
static const double mod_b_scale = 0.5; /* src: src/mod_b.F90:4 = 0.5D0 */
double mod_b_step_b(double y)
{
	return ext_c_routine(y) * mod_b_scale;
}
EOF
expect "a module procedure and a TARGET function calling routines defined elsewhere still link" 0 \
	'^SUMMARY \[default\]: 1 verified, 0 unverified, 0 red, 0 unreliable$' external

# ---- two regimes --------------------------------------------------------------------------------------
cat >"$WB/port/conventions/anchors.yaml" <<'EOF'
regimes:
  dp: {source_flags: [-DFIXTURE_DP], target_flags: [-DFIXTURE_DP]}
  sp: {}
include: [include]
EOF
kinds_h regimes
file regimes src/mod_a.c <<'EOF'
#include "mod_kinds.h"
static const real_t mod_a_a = 0.1f; /* src: src/mod_a.F90:9 = 0.1_WP */
EOF
expect "a rendering right in one regime and wrong in the other is RED in that regime only" 1 \
	'^RED src/mod_a\.c:2 mod_a_a \[dp\]: mismatch kind - SOURCE src/mod_a\.F90:9 A$' regimes
refute 'RED .*\[[^]]*sp' "  ... and not RED in the other"
expect "  ... where it passes" 1 '^SUMMARY \[sp\]: 1 verified, 0 unverified, 0 red, 0 unreliable$' regimes
printf 'regimes: [dp, sp]\n' >"$WB/port/conventions/anchors.yaml"
expect "a malformed anchors.yaml is UNRELIABLE" 2 \
	'UNRELIABLE - port/conventions/anchors\.yaml is malformed: regimes is not a non-empty mapping' regimes
rm "$WB/port/conventions/anchors.yaml"

# ---- pairing ----------------------------------------------------------------------------------------
file names src/mod_a.c <<'EOF'
static const double mod_a_gravity = 9.81; /* src: src/mod_a.F90:5 = 9.81_DP */
EOF
expect "a TARGET name the naming rule does not give is UNRELIABLE" 2 \
	'^UNRELIABLE src/mod_a\.c:1 mod_a_gravity \[default\]: no SOURCE entity of the cited statement\(s\) is named mod_a_gravity by the naming rule \(they declare G, MOD_A\)' names
printf 'names:\n  mod_a_gravity: G\n' >"$WB/port/conventions/anchors.yaml"
expect "  ... and pairs through anchors.yaml names" 0 '^SUMMARY \[default\]: 1 verified' names
printf 'names:\n  mod_a_gravity: NLEV\n' >"$WB/port/conventions/anchors.yaml"
expect "  ... where an entity declared by another statement is RED" 1 \
	'^RED src/mod_a\.c:1 mod_a_gravity \[default\]: invalid-anchor - src/mod_a\.c:1: /\* src: src/mod_a\.F90:5 = 9\.81_DP \*/ cites line 5, which declares G; NLEV is declared at line 6$' names
printf 'names:\n  mod_a_gravity: GRAVITY\n' >"$WB/port/conventions/anchors.yaml"
expect "  ... and one no SOURCE file declares is UNRELIABLE" 2 \
	'^UNRELIABLE src/mod_a\.c:1 mod_a_gravity \[default\]: port/conventions/anchors\.yaml pairs mod_a_gravity with GRAVITY, which no cited SOURCE file declares' names
rm "$WB/port/conventions/anchors.yaml"
# The naming rule gives mod_b_nq the SOURCE NQ, declared at line 5; its anchor cites line 3, NB's,
# which holds the same literal.
file sameliteral src/mod_b.c <<'EOF'
enum { mod_b_nq = 4 }; /* src: src/mod_b.F90:3 = 4 */
EOF
expect "an anchor citing another constant's line that holds the same literal is RED (invalid-anchor)" 1 \
	'^RED src/mod_b\.c:1 mod_b_nq \[default\]: invalid-anchor - src/mod_b\.c:1: /\* src: src/mod_b\.F90:3 = 4 \*/ cites line 3, which declares NB; NQ is declared at line 5$' sameliteral

# ---- temporaries ------------------------------------------------------------------------------
# R4's statement split over TARGET constants: mod_b_r and mod_b_r2 render no SOURCE entity, but the
# initializer of mod_b_r4, which renders R4, reaches them; they are verified through it.
temporaries() { # temporaries CASE R-INITIALIZER R2-QUOTE
	file "$1" src/mod_b.c <<EOF
static const double mod_b_r = $2; /* src: src/mod_b.F90:6 = 1.0D0 */
static const double mod_b_r2 = mod_b_r * mod_b_r; /* src: src/mod_b.F90:6 = $3 */
static const double mod_b_r4 = mod_b_r2 * mod_b_r2; /* src: src/mod_b.F90:6 = ((1.0D0 + 0.5D0) / (1.0D0 - 0.5D0))**4 */
EOF
}
temporaries temps '(1.0 + 0.5) / (1.0 - 0.5)' 0.5D0
expect "temporaries of a constant split over several are verified through it" 0 \
	'^SUMMARY \[default\]: 3 verified, 0 unverified, 0 red, 0 unreliable$' temps
temporaries wrongtemp '(1.0 - 0.5) / (1.0 + 0.5)' 0.5D0
expect "  ... and a wrong temporary is RED through it" 1 \
	'^RED src/mod_b\.c:1 mod_b_r \[default\]: temporary of mod_b_r4 \(line 3\): mismatch value - SOURCE src/mod_b\.F90:6 R4$' wrongtemp
temporaries tempanchor '(1.0 + 0.5) / (1.0 - 0.5)' 2.0D0
expect "  ... and a temporary's anchor is held to the anchor rules" 1 \
	'^RED src/mod_b\.c:2 mod_b_r2 \[default\]: invalid-anchor - .*: the literal-as-read is not on src/mod_b\.F90:6$' tempanchor
file notreached src/mod_b.c <<'EOF'
static const double mod_b_half = 0.5; /* src: src/mod_b.F90:6 = 0.5D0 */
static const double mod_b_r4 = 81.0; /* src: src/mod_b.F90:6 = ((1.0D0 + 0.5D0) / (1.0D0 - 0.5D0))**4 */
EOF
expect "  ... but a constant the paired one does not reach stays UNRELIABLE" 2 \
	'^UNRELIABLE src/mod_b\.c:1 mod_b_half \[default\]: no SOURCE entity of the cited statement\(s\) is named mod_b_half' notreached

# ---- UNRELIABLE: the SOURCE -----------------------------------------------------------------------------
file unparsed src/broken.c <<'EOF'
enum { mod_broken_k = 3 }; /* src: src/broken.F90:2 = 3 */
EOF
expect "an anchor citing a SOURCE file that does not parse is UNRELIABLE" 2 \
	'^UNRELIABLE src/broken\.c:1 mod_broken_k \[default\]: SOURCE src/broken\.F90 cannot be read in regime default: fparser cannot parse' unparsed
file nomodule src/lonely.c <<'EOF'
enum { mod_lonely_l = 1 }; /* src: src/lonely.F90:3 = 1 */
EOF
expect "a USEd module no SOURCE file defines is UNRELIABLE" 2 \
	'^UNRELIABLE src/lonely\.c:1 mod_lonely_l \[default\]: src/lonely\.F90:3 L: module MOD_MISSING, USEd by src/lonely\.F90, is defined by no SOURCE file$' nomodule

# ---- the pin -------------------------------------------------------------------------------------------
# Anchors resolve against the import commit: a working-tree edit that shifts the SOURCE lines changes
# nothing, and a pin that does not resolve is UNRELIABLE.
cp "$WB/source/src/mod_a.F90" "$TMP/mod_a.F90"
{ printf '! a line added after the import\n'; cat "$TMP/mod_a.F90"; } >"$WB/source/src/mod_a.F90"
expect "anchors are read at the pinned commit, never in the working tree" 0 \
	'^SUMMARY \[default\]: 7 verified, 0 unverified, 0 red, 0 unreliable$' green
cp "$TMP/mod_a.F90" "$WB/source/src/mod_a.F90"
expect "a SOURCE pin that does not resolve is UNRELIABLE" 2 \
	"SOURCE pin ref 'no-such-ref' does not resolve" green --ref no-such-ref

# ---- no TARGET code yet ----------------------------------------------------------------------------------
# No product wired (no port/product.yaml) and no target/ tree: nothing to verify. A wired product whose
# checkout is missing is UNRELIABLE.
expect "no TARGET code yet is a clean skip" 0 'no TARGET source tree at .* yet - nothing to verify \(skipping\)' -
expect "a product root that does not exist is UNRELIABLE" 2 'is not present beside the workbench' none

# ---- runtime-helper anchors ------------------------------------------------------------------------------
file helper src/f_runtime.h <<'EOF'
static const int f_runtime_unit = 6; /* runtime-helper: T19 - list-directed output unit */
static const int f_runtime_width = 80;
EOF
expect "a declared helper file with a runtime-helper anchor is GREEN (and exempt from coverage)" 0 \
	'^RESULT: GREEN' helper
file badtrap src/f_runtime.h <<'EOF'
static const int f_runtime_unit = 6; /* runtime-helper: T99 - an invented trap row */
EOF
expect "a runtime-helper anchor citing a missing trap row is RED" 1 \
	'^RED src/f_runtime\.h:1: invalid-anchor - the runtime-helper anchor cites trap T99, which no trap row' badtrap
file undeclared src/other.h <<'EOF'
static const int other_unit = 6; /* runtime-helper: T19 - list-directed output unit */
EOF
expect "a runtime-helper anchor outside a declared helper file is RED" 1 \
	'^RED src/other\.h:1: invalid-anchor - a runtime-helper anchor is valid only in a file listed in port/declared-helpers\.yaml' undeclared

if [ "$failures" -ne 0 ]; then
	printf '# test-verify-anchors: %d assertion(s) failed\n' "$failures" >&2
	exit 1
fi
printf '# test-verify-anchors: all assertions passed\n'
