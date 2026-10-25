#!/usr/bin/env bash
# Regression tests for tools/conformance/verify-anchors.sh.
#
# Drives the REAL verifier: a byte copy of the shipped script and its lib/ is placed in a
# throwaway workbench, so the inputs it resolves relative to its own location (the declared-helper
# list, the trap table) are synthetic, and it runs over synthetic SOURCE and TARGET fixtures.
#
# Per-file state: the driver keys several maps by physical LINE NUMBER (per-declaration helper
# exemptions, aggregate element counts, per-line anchor tallies) and must empty them for every
# file. A map that survives into the next file lets one file's bookkeeping decide another file's
# coverage at the same line - a false GREEN when it hides a gap. Every multi-file case is paired
# with single-file controls, so a verdict that differs from the controls can only come from state
# carried across files. Each per-file reset is load-bearing for at least one case: delete any one
# of the `HELPER_SEEN_AT=()`, `ANCHOR_COUNT_AT=()` or `DECL_ELEM_COUNT_AT=()` lines from the
# verifier and this test goes red.
#
# Trailing-point real literals: a Fortran real may end in its decimal point and still carry a
# kind (`2._WP`). The structural comparison strips the kind before parsing the literal as C; if
# it does not, the faithful rendering and a wrong one are both UNRELIABLE, so the check cannot
# tell them apart. Restore the digit-only lookbehind in lib/verify_anchors_ast.py's
# `_KIND_SUFFIX_RE` and the trailing-point cases below go red.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# The verifier reads these from the environment; keep the caller's settings out of the fixtures.
unset TRACE_FILE SOURCE_PIN_REF SOURCE_SUBDIR TARGET_DIR PRODUCT_ROOT VERIFY_ANCHORS_KINDS_FILE \
	VERIFY_ANCHORS_DOUBLE_KINDS VERIFY_ANCHORS_SINGLE_KINDS VERIFY_ANCHORS_RCONST_KINDS \
	VERIFY_ANCHORS_DEFAULT_REAL VERIFY_ANCHORS_RCONST_MACRO VERIFY_ANCHORS_RCONST_DP_DEFINE

failures=0
pass() { printf 'ok - %s\n' "$1"; }
fail() {
	printf 'not ok - %s\n' "$1" >&2
	failures=$((failures + 1))
}

# The verifier's structural and coverage checks need libclang; without it every case would be
# UNRELIABLE, so the test cannot pass vacuously - it stops here instead.
if ! python3 -c 'import clang.cindex as ci; ci.Index.create()' >/dev/null 2>&1; then
	printf 'not ok - python3 clang.cindex with the native libclang is required to run the verifier\n' >&2
	exit 1
fi

WB="$TMP/wb"
T="$WB/target"
mkdir -p "$WB/tools/conformance" "$WB/port" "$WB/source/src" "$T" \
	"$WB/.opencode/skill/target-conventions/references/pairs"
cp "$ROOT/tools/conformance/verify-anchors.sh" "$WB/tools/conformance/"
cp -R "$ROOT/tools/conformance/lib" "$WB/tools/conformance/"
printf '| T1 | synthetic trap row |\n' >"$WB/.opencode/skill/target-conventions/references/pairs/fortran-to-c.md"
printf 'helpers:\n  - a_helper.h\n' >"$WB/port/declared-helpers.yaml"

cat >"$WB/source/src/ints.F90" <<'EOF'
INTEGER, PARAMETER :: N1 = 1
INTEGER, PARAMETER :: N2 = 2
INTEGER, PARAMETER :: N3 = 3
INTEGER, PARAMETER :: N5 = 5
EOF
cat >"$WB/source/src/reals.F90" <<'EOF'
REAL(KIND=WP), PARAMETER :: TWO = 2._WP
REAL(KIND=WP), PARAMETER :: SIX = 2._WP*3._WP
REAL(KIND=WP), PARAMETER :: HUNDRED = 100._WP
REAL(KIND=WP) :: ROOT
ROOT = 2._WP*SQRT(X)
EOF
git -C "$WB" init -q -b main
git -C "$WB" config user.name tester
git -C "$WB" config user.email tester@example.invalid
git -C "$WB" add source
git -C "$WB" commit -q -m "import synthetic source"

# TRACE declares the b/c/d/e stems translated; a_helper.h is declared a helper above. Each row keeps
# `source:` on its own line, the form the verifier's translated-stem reader matches.
{
	printf 'meta:\n  source_root: source/\n  source_commit: %s\nfiles:\n' "$(git -C "$WB" rev-parse HEAD)"
	for stem in b_unit c_unit d_unit e_unit; do
		printf '  - status: in-progress\n    source: src/%s.F90\n' "$stem"
	done
} >"$WB/port/TRACE.yaml"

# expect LABEL WANT_EXIT WANT_TEXT FILE... - run the verifier over FILE... (in that order) and
# require its exit code, plus WANT_TEXT in its output unless WANT_TEXT is "-".
expect() {
	local label="$1" want="$2" text="$3" got=0
	shift 3
	(cd "$WB" && bash tools/conformance/verify-anchors.sh "$@") >"$TMP/out.log" 2>&1 || got=$?
	if [[ "$got" -ne "$want" ]]; then
		fail "$label: expected exit $want, got $got"
		sed 's/^/    /' "$TMP/out.log" >&2
	elif [[ "$text" != "-" ]] && ! grep -qF -- "$text" "$TMP/out.log"; then
		fail "$label: exit $got but the output lacks '$text'"
		sed 's/^/    /' "$TMP/out.log" >&2
	else
		pass "$label (exit $got)"
	fi
}

fixture() { # fixture DIR NAME - write stdin to $T/DIR/NAME
	mkdir -p "$T/$1"
	cat >"$T/$1/$2"
}

# 1) A declared helper's per-declaration exemption at line 1 must not exempt an unanchored
#    constant at line 1 of a later file.
fixture helper a_helper.h <<'EOF'
static const int a_helper_limit = 64; /* runtime-helper: T1 - synthetic language-contract constant */
EOF
fixture helper b_unit.h <<'EOF'
static const int b_unit_count = 7;
EOF
expect "helper file alone is GREEN" 0 - "$T/helper/a_helper.h"
expect "unanchored constant alone is RED" 1 "lacks a provenance anchor" "$T/helper/b_unit.h"
expect "helper exemption does not leak into a later file" 1 "lacks a provenance anchor" \
	"$T/helper/a_helper.h" "$T/helper/b_unit.h"

# 2) An anchor counted at line 1 of one file must not complete a later file's under-anchored
#    aggregate at line 1 (two elements, one anchor).
fixture count c_unit.h <<'EOF'
static const int c_unit_three = 3; /* src: src/ints.F90:3 = 3 */
EOF
fixture count d_unit.h <<'EOF'
static const int d_unit_tab[2] = {1, 2}; /* src: src/ints.F90:1 = 1 */
EOF
expect "anchored scalar alone is GREEN" 0 - "$T/count/c_unit.h"
expect "under-anchored aggregate alone is RED" 1 "has only 1 anchor(s)" "$T/count/d_unit.h"
expect "anchor tally does not leak into a later file" 1 "has only 1 anchor(s)" \
	"$T/count/c_unit.h" "$T/count/d_unit.h"

# 3) An aggregate's element count at line 1 of one file must not turn a later file's correctly
#    anchored scalar at line 1 into an under-anchored "aggregate".
fixture elems c_unit.h <<'EOF'
static const int c_unit_tab[2] = {1, 2}; /* src: src/ints.F90:1 = 1 */ /* src: src/ints.F90:2 = 2 */
EOF
fixture elems d_unit.h <<'EOF'
static const int d_unit_five = 5; /* src: src/ints.F90:4 = 5 */
EOF
expect "fully anchored aggregate alone is GREEN" 0 - "$T/elems/c_unit.h"
expect "anchored scalar alone is GREEN" 0 - "$T/elems/d_unit.h"
expect "element count does not leak into a later file" 0 - \
	"$T/elems/c_unit.h" "$T/elems/d_unit.h"

# 4) Both aggregate maps at once: a fully anchored aggregate at line 1 must not hide an
#    unanchored scalar at line 1 of a later file.
fixture both d_unit.h <<'EOF'
static const int d_unit_count = 7;
EOF
expect "unanchored scalar alone is RED" 1 "lacks a provenance anchor" "$T/both/d_unit.h"
expect "aggregate bookkeeping does not hide a later file's gap" 1 "lacks a provenance anchor" \
	"$T/elems/c_unit.h" "$T/both/d_unit.h"

# 5) Trailing-point real literals with a kind. WP is registered as a double kind for these runs,
#    so the faithful rendering is a plain double: GREEN when faithful, RED when wrong.
dot() { VERIFY_ANCHORS_DOUBLE_KINDS=wp expect "$@"; }
fixture dot_ok e_unit.h <<'EOF'
static const double e_unit_two = 2.0; /* src: src/reals.F90:1 = 2._WP */
EOF
fixture dot_value e_unit.h <<'EOF'
static const double e_unit_two = 3.0; /* src: src/reals.F90:1 = 2._WP */
EOF
fixture dot_float e_unit.h <<'EOF'
static const double e_unit_two = 2.0f; /* src: src/reals.F90:1 = 2._WP */
EOF
fixture dot_digits e_unit.h <<'EOF'
static const double e_unit_hundred = 100.0; /* src: src/reals.F90:3 = 100._WP */
EOF
fixture cmp_ok e_unit.h <<'EOF'
static const double e_unit_six = 2.0 * 3.0; /* src: src/reals.F90:2 = 2._WP*3._WP */
EOF
fixture cmp_operator e_unit.h <<'EOF'
static const double e_unit_six = 2.0 / 3.0; /* src: src/reals.F90:2 = 2._WP*3._WP */
EOF
fixture cmp_value e_unit.h <<'EOF'
static const double e_unit_six = 2.0 * 4.0; /* src: src/reals.F90:2 = 2._WP*3._WP */
EOF
fixture cmp_call e_unit.h <<'EOF'
double sqrt(double);
double e_unit_root(double x)
{
	const double root = 2.0 * sqrt(x); /* src: src/reals.F90:5 = 2._WP*SQRT(X) */
	return root;
}
EOF
dot "2._WP rendered 2.0 is GREEN" 0 - "$T/dot_ok/e_unit.h"
dot "2._WP rendered 3.0 is RED" 1 "rendered as '3.0' - values differ" "$T/dot_value/e_unit.h"
dot "2._WP rendered 2.0f is RED" 1 "rendered f-suffixed ('2.0f')" "$T/dot_float/e_unit.h"
dot "100._WP rendered 100.0 is GREEN" 0 - "$T/dot_digits/e_unit.h"
dot "2._WP*3._WP rendered 2.0 * 3.0 is GREEN" 0 - "$T/cmp_ok/e_unit.h"
dot "2._WP*3._WP rendered 2.0 / 3.0 is RED" 1 "structure differs" "$T/cmp_operator/e_unit.h"
dot "2._WP*3._WP rendered 2.0 * 4.0 is RED" 1 "rendered as '4.0' - values differ" "$T/cmp_value/e_unit.h"
# A call is outside the structural subset: still UNRELIABLE once the kind is stripped, never GREEN.
dot "2._WP*SQRT(X) is stripped, then UNRELIABLE" 2 "(stripped: '2.*SQRT(X)')" "$T/cmp_call/e_unit.h"

if [[ "$failures" -ne 0 ]]; then
	printf '# test-verify-anchors: %d assertion(s) failed\n' "$failures" >&2
	exit 1
fi
printf '# test-verify-anchors: all assertions passed\n'
