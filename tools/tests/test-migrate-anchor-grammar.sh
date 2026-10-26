#!/usr/bin/env bash
# tools/migrate-anchor-grammar.py over a throwaway workbench (SOURCE imported in a commit recorded
# as port/TRACE.yaml meta.source_commit) and product: a quoted literal that is a SOURCE token without
# its kind suffix or exponent is rewritten to the whole token; an anchor that already holds is left
# alone; an anchor it cannot rewrite unambiguously is reported and left alone. A dry run changes
# nothing. The rewritten product then passes the anchor verifier, which failed it before.
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

WB="$TMP/wb"
mkdir -p "$WB/tools/conformance" "$WB/source/src" "$WB/port" "$WB/.opencode/skill/target-conventions/references/pairs"
cp "$ROOT/tools/migrate-anchor-grammar.py" "$WB/tools/"
cp "$ROOT/tools/conformance/verify-anchors.sh" "$WB/tools/conformance/"
cp -R "$ROOT/tools/conformance/lib" "$WB/tools/conformance/"
mkdir -p "$WB/tools/coordination"
cp "$ROOT/tools/coordination/yaml_get.py" "$ROOT/tools/coordination/_chisel_lib.py" "$WB/tools/coordination/"
printf '| T1 | a synthetic trap row |\n' >"$WB/.opencode/skill/target-conventions/references/pairs/fortran-to-c.md"
cat >"$WB/source/src/mod_a.F90" <<'EOF'
MODULE MOD_A
  IMPLICIT NONE
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(13, 300)
  REAL(WP), PARAMETER :: A = 0.1_WP
  REAL(WP), PARAMETER :: B = 1.E3_WP
  REAL(WP), PARAMETER :: C = 2._WP
  REAL(8), PARAMETER :: D = 1.0D0
  REAL(WP), PARAMETER :: E = 0.5_WP
  REAL(WP), PARAMETER :: F = 2.0_WP * 0.5_WP
  INTEGER, PARAMETER :: N = 10
  REAL(WP), PARAMETER :: P = 0.1_WP + 0.1_8
END MODULE MOD_A
EOF
git -C "$WB" init -q -b main
git -C "$WB" -c user.name=tester -c user.email=tester@example.invalid add source
git -C "$WB" -c user.name=tester -c user.email=tester@example.invalid commit -q -m "import synthetic source"
printf 'meta:\n  source_root: source\n  source_commit: %s\n' "$(git -C "$WB" rev-parse HEAD)" >"$WB/port/TRACE.yaml"
# A later working-tree edit of the SOURCE: the script reads the pinned commit, never this.
sed -i 's/0.1_WP/0.1_XX/' "$WB/source/src/mod_a.F90"

# The rewritable product: every anchor quotes a literal of its line, some without their tail.
P="$TMP/product"
mkdir -p "$P/src" "$P/tests"
cat >"$P/src/mod_a.c" <<'EOF'
/* src: src/mod_a.F90:1 */
static const double mod_a_a = 0.1; /* src: src/mod_a.F90:4 = 0.1 */
static const double mod_a_b = 1.e3; /* src: src/mod_a.F90:5 = 1.E3 */
static const double mod_a_c = 2.0; /* src: src/mod_a.F90:6 = 2. */
static const double mod_a_d = 1.0; /* src: src/mod_a.F90:7 = 1.0 */
static const double mod_a_e = 0.5; /* src: src/mod_a.F90:8 = 0.5_WP */
static const double mod_a_f = 2.0 * 0.5; /* src: src/mod_a.F90:9 = 2.0_WP * 0.5_WP */
EOF
printf 'static const double t_a = 0.1; /* src: src/mod_a.F90:4 = 0.1 */\n' >"$P/tests/t.c"
# A hidden directory is part of the file set, as the verifier reads it.
mkdir -p "$P/.hidden"
printf 'static const double mod_a_a = 0.1; /* src: src/mod_a.F90:4 = 0.1 */\n' >"$P/.hidden/h.c"
# Anchor text in a string literal is no anchor: never rewritten.
printf 'static const char *const mod_a_doc = "/* src: src/mod_a.F90:4 = 0.1 */";\n' >"$P/src/doc.c"
cp -R "$P" "$TMP/product.orig"

run() { # run OUT ARGS... - the script from the workbench; its exit code in $rc
	rc=0
	(cd "$WB" && python3 tools/migrate-anchor-grammar.py "${@:2}") >"$1" 2>&1 || rc=$?
}

# Before: the verifier rejects the anchors that cut a token.
rc=0
(cd "$WB" && bash tools/conformance/verify-anchors.sh --target-dir "$P") >"$TMP/before.log" 2>&1 || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'cuts a token of src/mod_a.F90:4' "$TMP/before.log"; then
	ok "before the migration the verifier is RED on a quote without its kind suffix"
else
	not_ok "before the migration the verifier is RED on a quote without its kind suffix (exit $rc)" "$TMP/before.log"
fi

run "$TMP/dry.log" "$P"
if [ "$rc" -eq 0 ] && diff -r "$P" "$TMP/product.orig" >/dev/null \
	&& grep -qF 'src/mod_a.c:2: /* src: src/mod_a.F90:4 = 0.1 */ -> /* src: src/mod_a.F90:4 = 0.1_WP */' "$TMP/dry.log" \
	&& grep -q '5 anchor(s) to rewrite (dry run' "$TMP/dry.log"; then
	ok "a dry run lists the five rewrites, a hidden directory's included, and changes nothing"
else
	not_ok "a dry run lists the five rewrites, a hidden directory's included, and changes nothing (exit $rc)" "$TMP/dry.log"
fi

run "$TMP/apply.log" --apply "$P"
cat >"$TMP/want.c" <<'EOF'
/* src: src/mod_a.F90:1 */
static const double mod_a_a = 0.1; /* src: src/mod_a.F90:4 = 0.1_WP */
static const double mod_a_b = 1.e3; /* src: src/mod_a.F90:5 = 1.E3_WP */
static const double mod_a_c = 2.0; /* src: src/mod_a.F90:6 = 2._WP */
static const double mod_a_d = 1.0; /* src: src/mod_a.F90:7 = 1.0D0 */
static const double mod_a_e = 0.5; /* src: src/mod_a.F90:8 = 0.5_WP */
static const double mod_a_f = 2.0 * 0.5; /* src: src/mod_a.F90:9 = 2.0_WP * 0.5_WP */
EOF
if [ "$rc" -eq 0 ] && diff "$TMP/want.c" "$P/src/mod_a.c" >"$TMP/diff.log" 2>&1 \
	&& diff "$P/tests/t.c" "$TMP/product.orig/tests/t.c" >/dev/null; then
	ok "--apply quotes each literal whole and leaves valid anchors and tests/ alone"
else
	not_ok "--apply quotes each literal whole and leaves valid anchors and tests/ alone (exit $rc)" "$TMP/diff.log"
fi
if diff "$P/src/doc.c" "$TMP/product.orig/src/doc.c" >/dev/null; then
	ok "anchor text in a string literal is not rewritten"
else
	not_ok "anchor text in a string literal is not rewritten" "$P/src/doc.c"
fi

run "$TMP/again.log" "$P"
if [ "$rc" -eq 0 ] && grep -q '0 anchor(s) to rewrite' "$TMP/again.log"; then
	ok "a second run finds nothing to rewrite"
else
	not_ok "a second run finds nothing to rewrite (exit $rc)" "$TMP/again.log"
fi

rc=0
(cd "$WB" && bash tools/conformance/verify-anchors.sh --target-dir "$P") >"$TMP/after.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
	ok "after the migration the verifier is GREEN"
else
	not_ok "after the migration the verifier is GREEN (exit $rc)" "$TMP/after.log"
fi

# What it cannot rewrite unambiguously it reports and leaves alone.
Q="$TMP/ambiguous"
mkdir -p "$Q"
cat >"$Q/mod_a.c" <<'EOF'
static const double mod_a_p = 0.2; /* src: src/mod_a.F90:11 = 0.1 */
static const int mod_a_n = 10; /* src: src/mod_a.F90:10 = 1 */
static const double mod_a_x = 9.0; /* src: src/mod_a.F90:4 = 9.0 */
static const double mod_a_y = 9.0; /* src: src/mod_a.F90:40 = 9.0 */
EOF
cp "$Q/mod_a.c" "$TMP/ambiguous.orig.c"
run "$TMP/amb.log" --apply "$Q"
if [ "$rc" -eq 1 ] && diff "$Q/mod_a.c" "$TMP/ambiguous.orig.c" >/dev/null \
	&& grep -qF "mod_a.c:1: cannot rewrite /* src: src/mod_a.F90:11 = 0.1 */: src/mod_a.F90:11 holds more than one token completing '0.1': 0.1_8, 0.1_WP" "$TMP/amb.log" \
	&& grep -qF "mod_a.c:2: cannot rewrite /* src: src/mod_a.F90:10 = 1 */: no literal of src/mod_a.F90:10 is '1' with a kind suffix or exponent" "$TMP/amb.log" \
	&& grep -qF "mod_a.c:3: cannot rewrite /* src: src/mod_a.F90:4 = 9.0 */: no literal of src/mod_a.F90:4" "$TMP/amb.log" \
	&& grep -qF "mod_a.c:4: cannot rewrite /* src: src/mod_a.F90:40 = 9.0 */: cites src/mod_a.F90:40, which the pinned SOURCE does not have" "$TMP/amb.log"; then
	ok "two candidate tokens, a cut token, a quote not on the line and a missing line are reported (exit 1), not rewritten"
else
	not_ok "two candidate tokens, a cut token, a quote not on the line and a missing line are reported (exit 1), not rewritten (exit $rc)" "$TMP/amb.log"
fi

run "$TMP/nopin.log" --ref no-such-ref "$P"
if [ "$rc" -eq 2 ] && grep -q "does not resolve" "$TMP/nopin.log"; then
	ok "a SOURCE pin that does not resolve stops the script (exit 2)"
else
	not_ok "a SOURCE pin that does not resolve stops the script (exit 2) (exit $rc)" "$TMP/nopin.log"
fi

if [ "$failures" -ne 0 ]; then
	printf '# test-migrate-anchor-grammar: %d assertion(s) failed\n' "$failures" >&2
	exit 1
fi
printf '# test-migrate-anchor-grammar: all assertions passed\n'
