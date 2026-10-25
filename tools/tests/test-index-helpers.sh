#!/usr/bin/env bash
# Regression tests for tools/conformance/check-index-helpers.sh.
#
# Drives a byte copy of the shipped check (and its lib/) inside a throwaway directory, so no
# project-layer waiver or helper-name file is picked up, over synthetic TARGET files passed
# explicitly. Every case states the verdict and, for a RED, the subscript that must be reported.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset TARGET_DIR PRODUCT_ROOT INDEX_HELPER_WAIVERS _PR_LOAD_CWD

mkdir -p "$TMP/tools/conformance"
cp "$ROOT/tools/conformance/check-index-helpers.sh" "$TMP/tools/conformance/"
cp -R "$ROOT/tools/conformance/lib" "$TMP/tools/conformance/"
CHECK="$TMP/tools/conformance/check-index-helpers.sh"
F="$TMP/fixtures"
mkdir -p "$F"

failures=0
# expect EXIT LABEL FIXTURE [REPORTED-TEXT] - run the check on one fixture file; on a RED, the
# report must also contain REPORTED-TEXT (so a RED for the wrong reason does not pass).
expect() {
	local expected="$1" label="$2" fixture="$3" want="${4:-}" output rc
	set +e
	output="$(cd "$TMP" && bash "$CHECK" "$fixture" 2>&1)"
	rc=$?
	set -e
	if [ "$rc" -ne "$expected" ]; then
		printf 'not ok - %s (expected exit %s, got %s)\n%s\n' "$label" "$expected" "$rc" "$output" >&2
		failures=$((failures + 1))
		return 0
	fi
	if [ -n "$want" ] && ! grep -qF -- "$want" <<<"$output"; then
		printf 'not ok - %s (report lacks %s)\n%s\n' "$label" "$want" "$output" >&2
		failures=$((failures + 1))
		return 0
	fi
	printf 'ok - %s\n' "$label"
}

# 1. Declaration lines: a declaration's array SIZE is not an access, so its subscripts before the
#    initializer are skipped. Only a whole type token may mark a declaration - an identifier that
#    merely begins with a type keyword starts an ordinary statement whose subscripts are checked.
cat >"$F/decl_ok.c" <<'EOF'
void f(int n, int m)
{
    double vv[n * m];
    static int w[2 * n];
    scalar_t ar1[n * m];
    const scalar_t *row[n * m];
}
EOF
expect 0 "array sizes in declarations are not flagged" "$F/decl_ok.c"

cat >"$F/prefix_int.c" <<'EOF'
void f(double *integral, int i, int j, int nx)
{
    integral[i + j * nx] = 0.0;
}
EOF
expect 1 "an identifier beginning with a type keyword is not a declaration" "$F/prefix_int.c" '[i + j * nx]'

cat >"$F/prefix_double.c" <<'EOF'
void f(double *doublet, int i, int j, int nx)
{
    doublet[i + j * nx] = 1.0;
}
EOF
expect 1 "doublet[...] is a statement, not a double declaration" "$F/prefix_double.c" '[i + j * nx]'

cat >"$F/prefix_typedef.c" <<'EOF'
void f(const scalar_t *a, int i, int j, int n)
{
    scalar_transform(a[i + j * n], i, j, n);
}
EOF
expect 1 "a call whose name begins with a typedef name is not a declaration" "$F/prefix_typedef.c" '[i + j * n]'

cat >"$F/typedef_array.c" <<'EOF'
void f(scalar_t *rate_t, scalar_t count_t, int i, int j, int nx)
{
    rate_t[i + j * nx] = 0.0;
    count_t = rate_t[i + j * nx];
}
EOF
expect 1 "a _t name used as a variable is not a declaration" "$F/typedef_array.c" ':3:'

# 2. Subscripts wrapped across physical lines (a formatter column limit wraps long helper calls)
#    are joined and checked as ONE unit: a wrapped helper call passes, a wrapped flatten is still
#    RED and reported at the line that opens it, and only a subscript still open at end of file
#    fails closed.
cat >"$F/wrapped_helper.c" <<'EOF'
void f(double *z, int nx, int ny, int i, int j)
{
    z[idx2(nx, ny,
           i, j)] = 0.0;
    z[idx2(nx,         /* a comment inside the wrap */
           ny, i,
           j)] = 1.0;
}
EOF
expect 0 "a wrapped helper call is verified, not refused" "$F/wrapped_helper.c"

cat >"$F/wrapped_flatten.c" <<'EOF'
void f(double *z, int nx, int i, int j)
{
    z[i +
      j * nx] = 0.0;
}
EOF
expect 1 "a wrapped flatten is still RED, reported at its opening line" "$F/wrapped_flatten.c" \
	":3: ad-hoc subscript '[i + j * nx]'"

cat >"$F/wrapped_then_flatten.c" <<'EOF'
void f(double *y, double *w, int nx, int ny, int i, int j)
{
    y[idx2(nx, ny,
           i, j)] = w[i + j * nx];
}
EOF
expect 1 "a flatten after a wrapped subscript on the continuation line is still checked" \
	"$F/wrapped_then_flatten.c" ":4: ad-hoc subscript '[i + j * nx]'"

cat >"$F/wrapped_decl.c" <<'EOF'
void f(int n, int m)
{
    scalar_t buf[n *
                 m] = {0};
}
EOF
expect 0 "a wrapped declaration size is still a declaration" "$F/wrapped_decl.c"

printf '%s\n' 'void f(double *z, int i, int j, int nx)' '{' '    z[i +' >"$F/unterminated.c"
expect 1 "a subscript never closed before end of file fails closed" "$F/unterminated.c" \
	":3: ad-hoc subscript '[subscript never closed before end of file"

{
	printf '%s\n' 'int f(char c, int x)' '{' "    if (c == '[') x = 0;"
	for _ in $(seq 1 100); do printf '%s\n' '    x = x + 1;'; done
	printf '%s\n' '    return x;' '}'
} >"$F/stray_bracket.c"
expect 1 "a stray bracket stops joining at the cap and fails closed" "$F/stray_bracket.c" \
	":3: ad-hoc subscript '[subscript not closed within 64 continuation lines"

if [ "$failures" -gt 0 ]; then
	printf '%s index-helper case(s) failed\n' "$failures" >&2
	exit 1
fi
