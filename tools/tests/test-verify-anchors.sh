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
SIGDIR="$(mktemp -d)"  # a TMPDIR of its own for the SIGTERM case, beside TMP: paths no longer than the caller's
trap 'rm -rf "$TMP" "$SIGDIR"' EXIT
unset SOURCE_PIN_REF SOURCE_SUBDIR TARGET_DIR PRODUCT_ROOT

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() {
	printf 'not ok - %s\n' "$1" >&2
	[ -z "${2:-}" ] || sed 's/^/    /' "$2" >&2
	failures=$((failures + 1))
}

for tool in gfortran clang ar objcopy git; do
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
# The shared strict YAML reader, which the verifier and product-root.sh read the workbench files with.
mkdir -p "$WB/tools/coordination"
cp "$ROOT/tools/coordination/yaml_get.py" "$ROOT/tools/coordination/_chisel_lib.py" "$WB/tools/coordination/"
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
# Namesakes in other scopes: an interface dummy N before the module's N, a procedure's own C after
# the module's C, and NP made a constant by a PARAMETER statement.
cat >"$WB/source/src/scopes.F90" <<'EOF'
MODULE SCOPES
  IMPLICIT NONE
  INTERFACE
    SUBROUTINE EXT(N)
      INTEGER, INTENT(IN) :: N
    END SUBROUTINE EXT
  END INTERFACE
  INTEGER, PARAMETER :: N = 4
  REAL(8), PARAMETER :: C = 1.0D0
  INTEGER NP
  PARAMETER (NP = 7)
CONTAINS
  SUBROUTINE S(Y)
    REAL(8), INTENT(INOUT) :: Y
    REAL(8), PARAMETER :: C = 2.0D0
    Y = Y * C
  END SUBROUTINE S
END MODULE SCOPES
EOF
# A module with two files: the current one fparser cannot parse, a stale one under legacy/ it can.
# A module two files define, and one whose only file fparser cannot parse.
mkdir -p "$WB/source/legacy"
cat >"$WB/source/src/stale.F90" <<'EOF'
MODULE MOD_STALE
  IMPLICIT NONE
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(13, 300)
  INTEGER, PARAMETER :: BAD = (
END MODULE MOD_STALE
EOF
cat >"$WB/source/legacy/stale_old.F90" <<'EOF'
MODULE MOD_STALE
  IMPLICIT NONE
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(6, 37)
END MODULE MOD_STALE
EOF
cat >"$WB/source/src/stale_user.F90" <<'EOF'
MODULE MOD_SU
  USE MOD_STALE, ONLY: WP
  IMPLICIT NONE
  REAL(WP), PARAMETER :: A = 0.1_WP
END MODULE MOD_SU
EOF
for f in dup_a dup_b; do
	printf 'MODULE MOD_DUP\n  INTEGER, PARAMETER :: K = 1\nEND MODULE MOD_DUP\n' >"$WB/source/src/$f.F90"
done
printf 'MODULE MOD_DU\n  USE MOD_DUP\n  INTEGER, PARAMETER :: L = K + 1\nEND MODULE MOD_DU\n' >"$WB/source/src/dup_user.F90"
printf 'MODULE MOD_UNREAD\n  INTEGER, PARAMETER :: K = (\nEND MODULE MOD_UNREAD\n' >"$WB/source/src/unread.F90"
printf 'MODULE MOD_UU\n  USE MOD_UNREAD\n  INTEGER, PARAMETER :: L = 2\nEND MODULE MOD_UU\n' >"$WB/source/src/unread_user.F90"
# Fixed form: a declaration continued in column 6 is one statement.
cat >"$WB/source/src/fixed.f" <<'EOF'
C     A FIXED-FORM MODULE
      MODULE FIXM
      IMPLICIT NONE
      DOUBLE PRECISION, PARAMETER :: A = 1.25D0,
     &                               B = 2.5D0
      INTEGER, PARAMETER :: K = 7
      END MODULE FIXM
EOF
# PRIVATE constants: a module PRIVATE by default with a PUBLIC exception, and a PRIVATE attribute
# in a second module of the file.
cat >"$WB/source/src/priv.F90" <<'EOF'
MODULE PRIV
  IMPLICIT NONE
  PRIVATE
  PUBLIC :: NPUB
  REAL(8), PARAMETER :: C = 1.5D0
  INTEGER, PARAMETER :: NPUB = 3
END MODULE PRIV
MODULE PRIV2
  IMPLICIT NONE
  REAL(8), PARAMETER, PRIVATE :: H = 0.25D0
END MODULE PRIV2
EOF
# A derived type and a kind known under local names (USE ..., ONLY: POINT => PT).
cat >"$WB/source/src/renamed.F90" <<'EOF'
MODULE RENAMED
  USE MOD_KINDS, ONLY: WPK => WP, POINT => PT
  IMPLICIT NONE
  TYPE(POINT), PARAMETER :: P0 = POINT(2.5_WPK, 3)
  TYPE(POINT), PARAMETER :: P1 = POINT(1.5_WPK, 4)
END MODULE RENAMED
EOF
# A module and a PROGRAM in one file, and a module whose procedure reaches the module's variable, so
# its probe links that file's object.
cat >"$WB/source/src/withmain.F90" <<'EOF'
MODULE WITHMAIN
  IMPLICIT NONE
  INTEGER, PARAMETER :: NW = 12
  INTEGER :: COUNTER = 0
END MODULE WITHMAIN
PROGRAM RUNNER
  USE WITHMAIN
  PRINT *, NW
END PROGRAM RUNNER
EOF
cat >"$WB/source/src/wm_user.F90" <<'EOF'
MODULE WM_USER
  USE WITHMAIN
  INTEGER, PARAMETER :: NU = NW + 1
CONTAINS
  SUBROUTINE TICK
    COUNTER = COUNTER + 1
  END SUBROUTINE TICK
END MODULE WM_USER
EOF
# A preprocessor include from a directory the regime names.
mkdir -p "$WB/source/src/inc"
printf '#define GVAL 9.81D0\n' >"$WB/source/src/inc/consts.h"
cat >"$WB/source/src/withinc.F90" <<'EOF'
MODULE WITHINC
#include "consts.h"
  IMPLICIT NONE
  REAL(8), PARAMETER :: G = GVAL
END MODULE WITHINC
EOF
# A Fortran INCLUDE file and the module that INCLUDEs it.
printf '      INTEGER NMAX\n      PARAMETER (NMAX = 100)\n' >"$WB/source/src/consts.inc"
printf "MODULE INCM\n  IMPLICIT NONE\n  INCLUDE 'consts.inc'\nEND MODULE INCM\n" >"$WB/source/src/incm.F90"
# A chain of USEs whose first module fparser reads but gfortran does not compile.
printf "MODULE CHAIN_A\n  INTEGER, PARAMETER :: K = 'x'\nEND MODULE CHAIN_A\n" >"$WB/source/src/chain_a.F90"
printf 'MODULE CHAIN_B\n  USE CHAIN_A\n  INTEGER, PARAMETER :: KB = 2\nEND MODULE CHAIN_B\n' >"$WB/source/src/chain_b.F90"
printf 'MODULE CHAIN_C\n  USE CHAIN_B\n  INTEGER, PARAMETER :: C1 = 3\n  INTEGER, PARAMETER :: C2 = 4\nEND MODULE CHAIN_C\n' \
	>"$WB/source/src/chain_c.F90"
# Fixed form read to column 72: a card-sequenced file (sequence numbers in columns 73-80). Statements
# the PRIVATE-stripped copy rebuilds longer than a line of their form: fixed form (a character
# literal crossing column 72 too) and free form.
python3 - "$WB/source/src/seq.f" "$WB/source/src/seq1.f" <<'PY'
import sys
lines = ['C     CARD-SEQUENCED MODULE', '      MODULE SEQM', '      IMPLICIT NONE',
         '      DOUBLE PRECISION, PARAMETER :: A = 1.5D0', '      INTEGER, PARAMETER :: N = 4', '      END MODULE SEQM']
open(sys.argv[1], 'w').write(''.join(ln.ljust(72) + f'{10 * k:08d}\n' for k, ln in enumerate(lines, 1)))
# the same module with only its constant's card numbered
open(sys.argv[2], 'w').write(''.join((ln.ljust(72) + '00000040' if 'A = ' in ln else ln) + '\n'
                                     for ln in lines).replace('SEQM', 'SEQ1'))
PY
cat >"$WB/source/src/fpriv.f" <<'EOF'
      MODULE FPRIV
      IMPLICIT NONE
      DOUBLE PRECISION, PARAMETER, PRIVATE :: A = 1.25D0, B = 2.5D0,
     &  CC = 3.75D0, DD = 4.125D0
      CHARACTER(LEN=*), PARAMETER, PRIVATE :: S = 'ABCDEFGHIJKLMNOPQRST
     &UVWXYZ0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'
      END MODULE FPRIV
EOF
cat >"$WB/source/src/lpriv.F90" <<'EOF'
MODULE LPRIV
  IMPLICIT NONE
  REAL(8), PARAMETER, PRIVATE :: X1 = 1.0D0, X2 = 2.0D0, X3 = 3.0D0, X4 = 4.0D0, X5 = 5.0D0, &
                                 X6 = 6.0D0, X7 = 7.0D0, X8 = 8.0D0, X9 = 9.0D0, X10 = 10.0D0
  CHARACTER(LEN=*), PARAMETER, PRIVATE :: S = 'abcdefghijklmnopqrstuvwxyz0123456789abcdefghijklmnopqrstuvwxyz&
                                              &0123456789abcdefghijklmnopqrstuvwxyz0123456789'
END MODULE LPRIV
EOF
# Modules of one file: TWO_A PRIVATE by default, TWO_B USEing it with a namesake of its private N,
# TWO_C USEing it with its own PRIVATE default and namesake.
cat >"$WB/source/src/twomods.F90" <<'EOF'
MODULE TWO_A
  IMPLICIT NONE
  PRIVATE
  INTEGER, PARAMETER :: N = 1
  INTEGER, PARAMETER, PUBLIC :: M = N + 1
END MODULE TWO_A
MODULE TWO_B
  USE TWO_A
  IMPLICIT NONE
  INTEGER, PARAMETER :: N = 5
END MODULE TWO_B
MODULE TWO_C
  USE TWO_A
  IMPLICIT NONE
  PRIVATE
  INTEGER, PARAMETER :: N = 9
END MODULE TWO_C
EOF
# Constants typed implicitly: PARAMETER statements with no type declaration, by the default rule and
# under an IMPLICIT statement, one an array shaped by a DIMENSION statement.
cat >"$WB/source/src/oldm.f" <<'EOF'
      MODULE OLDM
      PARAMETER (NMAX = 100, PI = 3.14159)
      END MODULE OLDM
EOF
cat >"$WB/source/src/oldd.f" <<'EOF'
      MODULE OLDD
      IMPLICIT DOUBLE PRECISION (A-H, O-Z)
      DIMENSION TAB(3)
      PARAMETER (PI = 3.14159D0)
      PARAMETER (TAB = (/ 1.0D0, 2.0D0, 3.0D0 /))
      PARAMETER (KQ = 7, XR = 2.5)
      END MODULE OLDD
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
# procedure calls an external routine, and a declared helper file whose constants each carry a
# runtime-helper anchor.
mod_a green
file green src/mod_b.c <<'EOF'
enum { mod_b_nb = 4 }; /* src: src/mod_b.F90:3 = 4 */
static const double mod_b_scale = 0.5; /* src: src/mod_b.F90:4 = 0.5D0 */
EOF
file green src/f_runtime.h <<'EOF'
static const int f_runtime_unit = 6; /* runtime-helper: T19 - list-directed output unit */
static const int f_runtime_width = 80; /* runtime-helper: T19 - list-directed record width */
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

# Objects holding no number to compare - a string, a pointer, a table of function pointers - are not
# constants the coverage rule asks an anchor for; an aggregate of numbers with a pointer member is.
file nonnumeric src/log.c <<'EOF'
#include <stdio.h>
static const char *const log_fmt = "%g\n";
static FILE *log_stream = NULL;
static void (*const log_hooks[])(void) = {0};
static const char log_tag[] = "solver";
EOF
expect "a string, a pointer or a function table is not a comparable constant" 0 '^RESULT: GREEN' nonnumeric
file aggptr src/log.c <<'EOF'
static const struct { double scale; double *buf; } log_ctx = {1.0, 0};
EOF
expect "  ... but an aggregate of numbers with a pointer member is" 1 \
	'^RED src/log\.c:1 log_ctx \[default\]: coverage - no anchor binds to log_ctx' aggptr

# Macros clang evaluates to a constant number or bool count too, though no literal is in their body;
# a type name or a variable behind a macro does not.
file macros src/mod_a.c <<'EOF'
#define _DEFAULT_SOURCE
#include <stdbool.h>
#include <math.h>
enum { mod_a_nlev = 60 }; /* src: src/mod_a.F90:6 = 60 */
#define MOD_A_TWICE (mod_a_nlev + mod_a_nlev)
#define MOD_A_DEBUG false
#define MOD_A_PI M_PI
#define MOD_A_REAL double
double mod_a_state;
#define MOD_A_STATE mod_a_state
EOF
expect "a macro clang evaluates to a constant without a literal in it needs an anchor" 1 \
	'^RED src/mod_a\.c:6 MOD_A_DEBUG \[default\]: coverage - no anchor binds to MOD_A_DEBUG' macros
for m in MOD_A_TWICE:5 MOD_A_PI:7; do
	grep -q "^RED src/mod_a\.c:${m#*:} ${m%%:*} \[default\]: coverage" "$TMP/out.log" \
		&& ok "  ... ${m%%:*} too" || not_ok "  ... ${m%%:*} too" "$TMP/out.log"
done
refute 'MOD_A_REAL|MOD_A_STATE' "  ... but neither a type name nor a variable behind a macro"

# The file set: a header named .H and a link to a .c file are read; a fragment a TARGET file includes
# that is no .c or .h file is read inside the file that includes it.
mkdir -p "$TMP/elsewhere" "$P/scanset/src"
printf 'static const double mod_a_gl = 9.80;\n' >"$TMP/elsewhere/x.c"
ln -s "$TMP/elsewhere/x.c" "$P/scanset/src/link.c"
file scanset src/a.c <<'EOF'
#include "a_consts.inc"
enum { mod_a_nlev = 60 }; /* src: src/mod_a.F90:6 = 60 */
EOF
file scanset src/a_consts.inc <<'EOF'
static const double mod_a_g = 9.80; /* src: src/mod_a.F90:5 = 9.81_DP */
EOF
file scanset src/b.H <<'EOF'
static const double mod_a_gb = 9.80;
EOF
expect "a .H header is read" 1 '^RED src/b\.H:1 mod_a_gb \[default\]: coverage - no anchor binds to mod_a_gb' scanset
grep -q '^RED src/link\.c:1 mod_a_gl \[default\]: coverage' "$TMP/out.log" && ok "  ... and a link to a .c file" \
	|| not_ok "  ... and a link to a .c file" "$TMP/out.log"
grep -q '^RED src/a_consts\.inc:1 (in src/a\.c) mod_a_g \[default\]: mismatch value - SOURCE src/mod_a\.F90:5 G$' \
	"$TMP/out.log" && ok "  ... and so is an included fragment that is neither: its wrong value is RED" \
	|| not_ok "  ... and so is an included fragment that is neither: its wrong value is RED" "$TMP/out.log"
# Links to directories: one inside the product tree is followed (a directory reached only through it
# is read; a link back up reads nothing twice); one leading out of the tree is refused.
mkdir -p "$P/dirlink/tests/gen" "$P/dirlink/inner" "$TMP/outside"
file dirlink src/a.c <<'EOF'
enum { mod_a_nlev = 60 }; /* src: src/mod_a.F90:6 = 60 */
EOF
printf 'static const double mod_a_gg = 9.80;\n' >"$P/dirlink/tests/gen/g.c"
ln -s ../tests/gen "$P/dirlink/src/gen"
ln -s ../src "$P/dirlink/inner/loop"
expect "a link to a directory inside the product tree is followed, a link back up read once" 1 \
	'^RED src/gen/g\.c:1 mod_a_gg \[default\]: coverage - no anchor binds to mod_a_gg' dirlink
grep -q '^SUMMARY \[default\]: 1 verified, 0 unverified, 1 red, 0 unreliable$' "$TMP/out.log" \
	&& ok "  ... each file read once" || not_ok "  ... each file read once" "$TMP/out.log"
printf 'static const double mod_a_g = 9.80; /* src: src/mod_a.F90:5 = 9.81_DP */\n' >"$TMP/outside/b.c"
ln -s "$TMP/outside" "$P/dirlink/src/shared"
expect "  ... and one leading out of the tree is UNRELIABLE, never skipped" 2 \
	'UNRELIABLE - scanning .* did not complete: .*/src/shared: a link to a directory out of the product tree' dirlink
# A fragment is read inside the file including it, so it need not be self-contained; its constants
# are held to coverage like any other.
file fragment src/a.c <<'EOF'
#define MOD_A_REAL double
#include "a_consts.inc"
enum { mod_a_nlev = 60 }; /* src: src/mod_a.F90:6 = 60 */
EOF
file fragment src/a_consts.inc <<'EOF'
static const MOD_A_REAL mod_a_g = 9.81; /* src: src/mod_a.F90:5 = 9.81_DP */
EOF
expect "a fragment that is not self-contained is read inside the file including it" 0 \
	'^SUMMARY \[default\]: 2 verified, 0 unverified, 0 red, 0 unreliable$' fragment
printf 'static const MOD_A_REAL mod_a_gx = 9.80;\n' >>"$P/fragment/src/a_consts.inc"
expect "  ... and its unanchored constant is RED (coverage)" 1 \
	'^RED src/a_consts\.inc:2 \(in src/a\.c\) mod_a_gx \[default\]: coverage - no anchor binds to mod_a_gx' fragment
# A fragment stamped into two units - double in one, float in the other - is two renderings: each
# is judged inside its unit, and named with it.
file stamped src/kernel.inc <<'EOF'
static const REAL mod_a_g = 9.81; /* src: src/mod_a.F90:5 = 9.81_DP */
EOF
file stamped src/kernel_dp.c <<'EOF'
#define REAL double
#include "kernel.inc"
EOF
file stamped src/kernel_sp.c <<'EOF'
#define REAL float
#include "kernel.inc"
EOF
expect "a fragment included by two units is judged inside each: the float rendering is RED" 1 \
	'^RED src/kernel\.inc:1 \(in src/kernel_sp\.c\) mod_a_g \[default\]: mismatch kind - SOURCE src/mod_a\.F90:5 G$' stamped
grep -q '^SUMMARY \[default\]: 1 verified, 0 unverified, 1 red, 0 unreliable$' "$TMP/out.log" \
	&& ok "  ... and the double one passes" || not_ok "  ... and the double one passes" "$TMP/out.log"

# Two declarations named on one line: each anchor binds to the name nearest before it.
file twonames src/mod_b.c <<'EOF'
enum { mod_b_nb = 4, /* src: src/mod_b.F90:3 = 4 */ mod_b_nq = 4 /* src: src/mod_b.F90:5 = 4 */ };
EOF
expect "two declarations named on one line: each anchor binds to the name before it" 0 \
	'^SUMMARY \[default\]: 2 verified, 0 unverified, 0 red, 0 unreliable$' twonames
file twoafter src/mod_b.c <<'EOF'
enum { mod_b_nb = 4, mod_b_nq = 4 }; /* src: src/mod_b.F90:3 = 4 */ /* src: src/mod_b.F90:5 = 4 */
EOF
expect "  ... and two anchors after both names bind to the names their cited statements pair with" 0 \
	'^SUMMARY \[default\]: 2 verified, 0 unverified, 0 red, 0 unreliable$' twoafter

# An anchor in a branch no regime builds is never judged: UNRELIABLE, not a binding error.
file nobranch src/mod_a.c <<'EOF'
#ifdef FIXTURE_DP
static const double mod_a_g = 9.81; /* src: src/mod_a.F90:5 = 9.81_DP */
#endif
EOF
expect "an anchor in a branch no regime builds is UNRELIABLE" 2 \
	'^UNRELIABLE src/mod_a\.c:2: no regime builds this branch' nobranch
file ifzero src/mod_a.c <<'EOF'
static const double mod_a_g = 9.81; /* src: src/mod_a.F90:5 = 9.81_DP */
#if 0
static const double mod_a_g_old = 9.8; /* src: src/mod_a.F90:5 = 9.81_DP */
#endif
EOF
expect "  ... and one under #if 0 is in a branch never built: no regime to add" 2 \
	'^UNRELIABLE src/mod_a\.c:3: this branch is never built \(#if 0\).* remove the dead code or its anchor$' ifzero

# Anchors are comments: anchor text in a string literal - at file scope or in a statement - is none.
file instring src/mod_a.c <<'EOF'
#include <stdio.h>
static const char *const mod_a_note = "/* src: src/mod_a.F90:5 = 9.81_DP */";
void mod_a_show(void)
{
	puts("/* src: src/mod_a.F90:5 = 9.81_DP */");
}
EOF
expect "anchor text in a string literal is not an anchor" 0 '^RESULT: GREEN' instring

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

file inlined src/mod_a.c <<'EOF'
double mod_a_weight(double m)
{
	return m * 9.81; /* src: src/mod_a.F90:5 = 9.81_DP */
}
EOF
expect "an anchor on a statement citing a SOURCE constant is RED: the constant is never compared" 1 \
	'^RED src/mod_a\.c:3 \[default\]: invalid-anchor - src/mod_a\.c:3: /\* src: src/mod_a\.F90:5 = 9\.81_DP \*/ is on a statement but cites G, a value the SOURCE gives at compile time' inlined

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

# ---- the cited statement selects the SOURCE declaration ------------------------------------------
scopes() { # scopes CASE N-VALUE
	file "$1" src/scopes.c <<EOF
enum { scopes_n = $2 }; /* src: src/scopes.F90:8 = 4 */
static const double scopes_c = 1.0; /* src: src/scopes.F90:9 = 1.0D0 */
enum { scopes_np = 7 }; /* src: src/scopes.F90:11 = 7 */
EOF
}
scopes scopes 4
expect "the cited declaration is compared, not a namesake of an interface body; a PARAMETER statement makes a constant" 0 \
	'^SUMMARY \[default\]: 3 verified, 0 unverified, 0 red, 0 unreliable$' scopes
scopes scopeswrong 5
expect "  ... so a wrong value of it is RED" 1 \
	'^RED src/scopes\.c:1 scopes_n \[default\]: mismatch value - SOURCE src/scopes\.F90:8 N$' scopeswrong
file localc src/scopes.c <<'EOF'
void scopes_s(double *y)
{
	const double c = 1.0; /* src: src/scopes.F90:15 = 2.0D0 */
	*y = *y * c;
}
EOF
expect "a procedure's own constant is never compared with the module's namesake: UNRELIABLE" 2 \
	'^UNRELIABLE src/scopes\.c:3 c \[default\]: src/scopes\.F90:15 C: C is a procedure-local constant; the probe cannot reach it$' localc

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
file unevaluated src/mod_b.c <<'EOF'
static const double mod_b_r = 123.0; /* src: src/mod_b.F90:6 = 1.0D0 */
static const double mod_b_r4 = 1 ? 81.0 : mod_b_r; /* src: src/mod_b.F90:6 = ((1.0D0 + 0.5D0) / (1.0D0 - 0.5D0))**4 */
EOF
expect "  ... but one the paired constant names in an arm never taken is not verified through it" 2 \
	'^UNRELIABLE src/mod_b\.c:1 mod_b_r \[default\]: mod_b_r4 refers to mod_b_r, but its value does not change' unevaluated
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

file stale src/stale_user.c <<'EOF'
static const float mod_su_a = 0.1f; /* src: src/stale_user.F90:4 = 0.1_WP */
EOF
expect "a USEd module whose current file fparser cannot parse is UNRELIABLE, never read from a stale copy" 2 \
	'^UNRELIABLE src/stale_user\.c:1 mod_su_a \[default\]: src/stale_user\.F90:4 A: src/stale\.F90 has a MODULE MOD_STALE line but cannot be read in regime default: fparser cannot parse' stale
file unread src/unread_user.c <<'EOF'
enum { mod_uu_l = 2 }; /* src: src/unread_user.F90:3 = 2 */
EOF
expect "  ... and so is one whose only file fparser cannot parse, with the parse error" 2 \
	'^UNRELIABLE src/unread_user\.c:1 mod_uu_l \[default\]: src/unread_user\.F90:3 L: src/unread\.F90 has a MODULE MOD_UNREAD line but cannot be read' unread
file dup src/dup_user.c <<'EOF'
enum { mod_du_l = 2 }; /* src: src/dup_user.F90:3 = K + 1 */
EOF
expect "  ... and one two SOURCE files define" 2 \
	'^UNRELIABLE src/dup_user\.c:1 mod_du_l \[default\]: src/dup_user\.F90:3 L: module MOD_DUP is defined by more than one SOURCE file: src/dup_a\.F90, src/dup_b\.F90$' dup

file fixed src/fixed.c <<'EOF'
static const double fixm_a = 1.25; /* src: src/fixed.f:4 = 1.25D0 */
static const double fixm_b = 2.5; /* src: src/fixed.f:5 = 2.5D0 */
enum { fixm_k = 7 }; /* src: src/fixed.f:6 = 7 */
EOF
expect "a fixed-form declaration continued in column 6 is one statement" 0 \
	'^SUMMARY \[default\]: 3 verified, 0 unverified, 0 red, 0 unreliable$' fixed

private() { # private CASE C-VALUE
	file "$1" src/priv.c <<EOF
static const double priv_c = $2; /* src: src/priv.F90:5 = 1.5D0 */
enum { priv_npub = 3 }; /* src: src/priv.F90:6 = 3 */
static const double priv2_h = 0.25; /* src: src/priv.F90:10 = 0.25D0 */
EOF
}
private private 1.5
expect "PRIVATE constants are compared: a PRIVATE default with a PUBLIC exception, a PRIVATE attribute" 0 \
	'^SUMMARY \[default\]: 3 verified, 0 unverified, 0 red, 0 unreliable$' private
private privatewrong 1.6
expect "  ... so a wrong PRIVATE constant is RED" 1 \
	'^RED src/priv\.c:1 priv_c \[default\]: mismatch value - SOURCE src/priv\.F90:5 C$' privatewrong

kinds_h renamed
file renamed src/renamed.c <<'EOF'
#include "mod_kinds.h"
static const pt renamed_p0 = {2.5f, 3}; /* src: src/renamed.F90:4 = POINT(2.5_WPK, 3) */
#define RENAMED_P1 {1.5f, 4} /* src: src/renamed.F90:5 = POINT(1.5_WPK, 4) */
EOF
expect "a derived type renamed by a USE is resolved" 0 '^SUMMARY \[default\]: 2 verified, 0 unverified, 0 red, 0 unreliable$' renamed

file withmain src/withmain.c <<'EOF'
enum { withmain_nw = 12 }; /* src: src/withmain.F90:3 = 12 */
enum { wm_user_nu = 13 }; /* src: src/wm_user.F90:3 = NW + 1 */
EOF
expect "a SOURCE file holding a PROGRAM beside its module links, cited or USEd" 0 \
	'^SUMMARY \[default\]: 2 verified, 0 unverified, 0 red, 0 unreliable$' withmain

file include src/incm.c <<'EOF'
enum { incm_nmax = 100 }; /* src: src/consts.inc:2 = 100 */
EOF
expect "an anchor citing a Fortran INCLUDE file is UNRELIABLE, and says why" 2 \
	'^UNRELIABLE src/incm\.c:1 incm_nmax \[default\]: src/consts\.inc holds no program unit \(an INCLUDE file\?\)' include

file chain src/chain_c.c <<'EOF'
enum { chain_c_c1 = 3 }; /* src: src/chain_c.F90:3 = 3 */
enum { chain_c_c2 = 4 }; /* src: src/chain_c.F90:4 = 4 */
EOF
expect "a module of the USE closure that does not compile makes its dependents UNRELIABLE" 2 \
	'^UNRELIABLE src/chain_c\.c:1 chain_c_c1 \[default\]: src/chain_c\.F90:3 C1: src/chain_a\.F90, in its USE closure, does not compile' chain
n="$(grep -c 'compiling chain_a.F90 with gfortran failed' "$TMP/out.log" || true)"
[ "$n" -eq 1 ] && ok "  ... and gives the compiler's reason once, not once per pair" \
	|| not_ok "  ... and gives the compiler's reason once, not once per pair ($n times)" "$TMP/out.log"

file twomods src/twomods.c <<'EOF'
enum { two_a_n = 1 }; /* src: src/twomods.F90:4 = 1 */
enum { two_a_m = 2 }; /* src: src/twomods.F90:5 = N + 1 */
enum { two_b_n = 5 }; /* src: src/twomods.F90:10 = 5 */
enum { two_c_n = 9 }; /* src: src/twomods.F90:16 = 9 */
EOF
expect "access specifiers are stripped in the probed module only: a later module's namesake does not clash" 0 \
	'^SUMMARY \[default\]: 4 verified, 0 unverified, 0 red, 0 unreliable$' twomods

implicit() { # implicit CASE PI-TYPE
	file "$1" src/old.c <<EOF
enum { oldm_nmax = 100 }; /* src: src/oldm.f:2 = 100 */
static const $2 oldm_pi = 3.14159f; /* src: src/oldm.f:2 = 3.14159 */
static const double oldd_pi = 3.14159; /* src: src/oldd.f:4 = 3.14159D0 */
static const double oldd_tab[3] = {1.0, 2.0, 3.0}; /* src: src/oldd.f:5 = 1.0D0 */
enum { oldd_kq = 7 }; /* src: src/oldd.f:6 = 7 */
static const double oldd_xr = 2.5; /* src: src/oldd.f:6 = 2.5 */
EOF
}
implicit implicit float
expect "an implicitly typed constant has its implicit type: I-N integer, else real, or an IMPLICIT statement's" 0 \
	'^SUMMARY \[default\]: 6 verified, 0 unverified, 0 red, 0 unreliable$' implicit
implicit implicitwrong double
expect "  ... so a default real rendered double is RED" 1 \
	'^RED src/old\.c:2 oldm_pi \[default\]: mismatch kind - SOURCE src/oldm\.f:2 PI$' implicitwrong

file seq src/seq.c <<'EOF'
static const double seqm_a = 1.5; /* src: src/seq.f:4 = 1.5D0 */
enum { seqm_n = 4 }; /* src: src/seq.f:5 = 4 */
EOF
file seq src/seq1.c <<'EOF'
static const double seq1_a = 1.5; /* src: src/seq1.f:4 = 1.5D0 */
EOF
expect "a fixed-form file is read to column 72: card sequence numbers are not code" 0 \
	'^SUMMARY \[default\]: 3 verified, 0 unverified, 0 red, 0 unreliable$' seq
file longpriv src/priv.c <<'EOF'
static const double fpriv_dd = 4.125; /* src: src/fpriv.f:4 = 4.125D0 */
static const double lpriv_x10 = 10.0; /* src: src/lpriv.F90:4 = 10.0D0 */
EOF
expect "  ... and a PRIVATE-stripped copy wraps the statements it rebuilds, fixed and free form" 0 \
	'^SUMMARY \[default\]: 2 verified, 0 unverified, 0 red, 0 unreliable$' longpriv

# ---- the pin -------------------------------------------------------------------------------------------
# Anchors resolve against the import commit: a working-tree edit that shifts the SOURCE lines changes
# nothing, and a pin that does not resolve is UNRELIABLE.
cp "$WB/source/src/mod_a.F90" "$TMP/mod_a.F90"
{ printf '! a line added after the import\n'; cat "$TMP/mod_a.F90"; } >"$WB/source/src/mod_a.F90"
expect "anchors are read at the pinned commit, never in the working tree" 0 \
	'^SUMMARY \[default\]: 7 verified, 0 unverified, 0 red, 0 unreliable$' green
cp "$TMP/mod_a.F90" "$WB/source/src/mod_a.F90"
expect "a SOURCE pin that does not resolve is UNRELIABLE, with git's own reason" 2 \
	"SOURCE pin ref 'no-such-ref' does not resolve in this repo \\(git: fatal: " green --ref no-such-ref
# A later commit whose SOURCE holds a link to an absolute path: never followed, never a traceback.
ln -s /usr/include "$WB/source/sysinc"
git -C "$WB" add source/sysinc
git -C "$WB" commit -q -m "a link out of the SOURCE tree"
expect "a SOURCE holding a link out of its tree is UNRELIABLE, not a crash" 2 \
	"UNRELIABLE - the SOURCE at the pin [0-9a-f]+ cannot be extracted: 'source/sysinc' is a link to an absolute path" \
	green --ref HEAD
git -C "$WB" rm -q source/sysinc
git -C "$WB" commit -q -m "drop the link"

# Include directories: relative to the pinned SOURCE root, so the pin's header is read even when the
# working tree's differs; an absolute one into the working SOURCE tree is refused.
file withinc src/withinc.c <<'EOF'
static const double withinc_g = 9.81; /* src: src/withinc.F90:4 = GVAL */
EOF
printf '#define GVAL 9.80D0\n' >"$WB/source/src/inc/consts.h"
printf 'regimes:\n  default: {source_flags: [-Isrc/inc]}\n' >"$WB/port/conventions/anchors.yaml"
expect "a relative include directory is read from the pinned SOURCE" 0 \
	'^SUMMARY \[default\]: 1 verified, 0 unverified, 0 red, 0 unreliable$' withinc
printf 'regimes:\n  default: {source_flags: [-I%s]}\n' "$WB/source/src/inc" >"$WB/port/conventions/anchors.yaml"
expect "  ... and an absolute one into the working SOURCE tree is UNRELIABLE" 2 \
	'UNRELIABLE - port/conventions/anchors\.yaml: regime default includes .*/source/src/inc, in the working SOURCE tree, not the pinned SOURCE' withinc
rm "$WB/port/conventions/anchors.yaml"
git -C "$WB" checkout -q -- source/src/inc/consts.h

# A stop by SIGTERM is UNRELIABLE and leaves no scratch directory behind.
(cd "$WB" && TMPDIR="$SIGDIR" exec bash tools/conformance/verify-anchors.sh --target-dir "$P/green") >"$TMP/term.log" 2>&1 &
pid=$!
for _ in $(seq 200); do
	ls "$SIGDIR" | grep -q '^verify-anchors-' && break
	sleep 0.05
done
kill -TERM "$pid"
rc=0
wait "$pid" || rc=$?
if [ "$rc" -eq 2 ] && ! ls "$SIGDIR" | grep -q '^verify-anchors-'; then
	ok "a stop by SIGTERM is UNRELIABLE (exit 2) and leaves no scratch directory"
else
	not_ok "a stop by SIGTERM is UNRELIABLE (exit 2) and leaves no scratch directory (exit $rc; left: $(ls "$SIGDIR"))" "$TMP/term.log"
fi

# ---- the workbench files, read as YAML data --------------------------------------------------------
# port/TRACE.yaml, port/declared-helpers.yaml and port/conventions/anchors.yaml are read through the
# shared strict loader the Python tools use (_chisel_lib.text_loader): a quoted value is its value, a
# `source_commit:` under another key is not meta's, an alias is the value it names, a scalar is text
# (a ref `0042` stays `0042`), and a repeated key or a file that is not the expected shape is
# UNRELIABLE, never read as one of its copies or as an empty default.
cp "$WB/port/TRACE.yaml" "$TMP/trace.saved"
cp "$WB/port/declared-helpers.yaml" "$TMP/helpers.saved"
pin="$(git -C "$WB" rev-parse HEAD)"
git -C "$WB" tag 0042 "$pin"
trace() { printf "$@" >"$WB/port/TRACE.yaml"; }
trace 'meta:\n  source_root: "source/"\n  source_commit: "%s"   # the local import commit\n' "$pin"
expect "a quoted, commented meta.source_commit is the pin" 0 '^SUMMARY \[default\]: 7 verified' green
trace 'notes:\n  source_commit: deadbeef\nmeta:\n  source_root: source/\n  source_commit: %s\n' "$pin"
expect "a source_commit under another key is not meta.source_commit" 0 '^SUMMARY \[default\]: 7 verified' green
trace 'pins:\n  current: &p %s\nmeta:\n  source_root: source/\n  source_commit: *p\n' "$pin"
expect "an alias reads as the value it names" 0 '^SUMMARY \[default\]: 7 verified' green
trace 'meta:\n  source_root: source/\n  source_commit: 0042\n'
expect "a ref of digits is read as text, not as a number" 0 '^SUMMARY \[default\]: 7 verified' green
trace 'meta:\n  source_root: source/\n  source_commit: deadbeef\n  source_commit: %s\n' "$pin"
expect "a TRACE repeating a meta key is UNRELIABLE, never read as one copy" 2 \
	'UNRELIABLE - port/TRACE\.yaml cannot be read: .*duplicate key' green
trace 'meta:\n  - source_commit: %s\n' "$pin"
expect "a TRACE whose meta is not a mapping is UNRELIABLE" 2 'UNRELIABLE - port/TRACE\.yaml: meta is not a mapping' green
trace 'meta:\n  source_root: source/\n  source_commit: [%s]\n' "$pin"
expect "a meta.source_commit that is not a scalar is UNRELIABLE" 2 \
	'UNRELIABLE - port/TRACE\.yaml: meta\.source_commit is not a single-line scalar' green
trace 'meta: [unclosed\n'
expect "a TRACE that is not YAML is UNRELIABLE" 2 'UNRELIABLE - port/TRACE\.yaml cannot be read' green
cp "$TMP/trace.saved" "$WB/port/TRACE.yaml"
helpers() { printf "$@" >"$WB/port/declared-helpers.yaml"; }
file yhelper src/f_runtime.h <<'EOF'
static const int f_runtime_unit = 6; /* runtime-helper: T19 - list-directed output unit */
EOF
helpers 'helpers:\n  - "f_runtime.h"   # quoted\n'
expect "a quoted declared helper is declared" 0 '^RESULT: GREEN' yhelper
helpers -- '- f_runtime.h   # a bare list, the form ports hold\n'
expect "a bare list of declared helpers is read" 0 '^RESULT: GREEN' yhelper
helpers 'helpers:\n  - f_runtime.h\nhelpers:\n  - other.h\n'
expect "a declared-helpers file repeating a key is UNRELIABLE" 2 \
	'UNRELIABLE - port/declared-helpers\.yaml cannot be read: .*duplicate key' yhelper
helpers -- '- f_runtime.h\n- name: other.h\n'
expect "a bare list holding a mapping is UNRELIABLE" 2 'UNRELIABLE - port/declared-helpers\.yaml is malformed' yhelper
helpers 'helpers:\n  - "old f_runtime.h"\n'
expect "a helper name holding a space is one name, not two" 1 \
	'^RED src/f_runtime\.h:1: invalid-anchor - a runtime-helper anchor is valid only in a file listed' yhelper
cp "$TMP/helpers.saved" "$WB/port/declared-helpers.yaml"
printf 'regimes:\n  default: {}\nregimes:\n  dp: {}\n' >"$WB/port/conventions/anchors.yaml"
expect "an anchors.yaml repeating a key is UNRELIABLE" 2 \
	'UNRELIABLE - port/conventions/anchors\.yaml cannot be read: .*duplicate key' green
rm "$WB/port/conventions/anchors.yaml"
# port/product.yaml: a placeholder checkout, and a file the strict reader refuses, each named.
printf 'repo: x\ncheckout: <the product checkout>\n' >"$WB/port/product.yaml"
expect "a product.yaml whose checkout is a placeholder is UNRELIABLE" 2 \
	'port/product\.yaml present but its checkout is unset/placeholder' -
printf 'repo: x\ncheckout: ../p\ncheckout: ../q\n' >"$WB/port/product.yaml"
expect "a product.yaml the strict reader refuses is UNRELIABLE, and says so" 2 \
	'port/product\.yaml cannot be read \(the reason is above\)' -
rm "$WB/port/product.yaml"

# ---- no TARGET code yet ----------------------------------------------------------------------------------
# No product wired (no port/product.yaml) and no target/ tree: nothing to verify. A wired product whose
# checkout is missing is UNRELIABLE.
expect "no TARGET code yet is a clean skip" 0 'no TARGET source tree at .* yet - nothing to verify \(skipping\)' -
expect "a product root that does not exist is UNRELIABLE" 2 'is not present beside the workbench' none

# ---- runtime-helper anchors ------------------------------------------------------------------------------
file helper src/f_runtime.h <<'EOF'
static const int f_runtime_unit = 6; /* runtime-helper: T19 - list-directed output unit */
static const int f_runtime_width =
	80; /* runtime-helper: T19 - list-directed record width */
EOF
expect "a declared helper file whose constants carry runtime-helper anchors is GREEN" 0 '^RESULT: GREEN' helper
file helpergap src/f_runtime.h <<'EOF'
static const int f_runtime_unit = 6; /* runtime-helper: T19 - list-directed output unit */
static const int f_runtime_width = 80;
EOF
expect "  ... but a constant of it without one is RED (coverage): one anchor never covers the file" 1 \
	'^RED src/f_runtime\.h:2 f_runtime_width \[default\]: coverage - no anchor binds to f_runtime_width' helpergap
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
