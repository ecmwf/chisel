#!/usr/bin/env bash
# Regression tests for tools/conformance/check-index-helpers.sh.
#
# Drives a byte copy of the shipped check (and its lib/) inside a throwaway directory, so no
# project-layer waiver or helper-name file is picked up, over synthetic TARGET files passed
# explicitly. Every case states the verdict and, for a RED, the subscript that must be reported.
# The listed-helper cases need python3 with libclang (clang.cindex), as the check itself does.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset TARGET_DIR PRODUCT_ROOT INDEX_HELPER_WAIVERS INDEX_HELPER_NAMES _PR_LOAD_CWD

# A listed helper name is verified against a libclang parse of the central helper files; without
# libclang every such case would be UNRELIABLE, so the test cannot pass vacuously - it stops here.
if ! python3 -c 'import clang.cindex as ci; ci.Index.create()' >/dev/null 2>&1; then
	printf 'not ok - python3 clang.cindex with the native libclang is required to run the check\n' >&2
	exit 1
fi

mkdir -p "$TMP/tools/conformance"
cp "$ROOT/tools/conformance/check-index-helpers.sh" "$TMP/tools/conformance/"
cp -R "$ROOT/tools/conformance/lib" "$TMP/tools/conformance/"
CHECK="$TMP/tools/conformance/check-index-helpers.sh"
F="$TMP/fixtures"
mkdir -p "$F"

failures=0
# Extra NAME=VALUE environment, and extra files to pass, for the next expect calls (empty: none).
RUN_ENV=()
EXTRA_FILES=()
# expect EXIT LABEL FIXTURE [REPORTED-TEXT] - run the check on one fixture file (plus EXTRA_FILES;
# an empty FIXTURE runs the scan mode instead);
# the report must also contain REPORTED-TEXT (so a verdict for the wrong reason does not pass).
expect() {
	local expected="$1" label="$2" fixture="$3" want="${4:-}" output rc
	set +e
	output="$(cd "$TMP" && env ${RUN_ENV[@]+"${RUN_ENV[@]}"} bash "$CHECK" ${fixture:+"$fixture"} \
		${EXTRA_FILES[@]+"${EXTRA_FILES[@]}"} 2>&1)"
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

cat >"$F/typedef_product.c" <<'EOF'
void f(double *pz, double zq_t, double zfac, int i, int j, int nx)
{
    double ztend = zfac +
                   zq_t * pz[i + j * nx];
}
EOF
expect 1 "a _t name times a subscript on a continuation line is a product, not a declaration" \
	"$F/typedef_product.c" ':4:'

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

# 3. The helper set is the port's convention. A call whose arguments carry a stride multiply is
#    accepted only when it names a helper: by default idx0..idx4 / idx1_stride / idxlb; a port
#    lists its own set in the project layer, and that list REPLACES the default. Only exact names
#    count, a malformed or empty list is UNRELIABLE, and every listed name must be defined in the
#    central helper header/source (idx.h / idx.c) among the checked files.
cat >"$F/helpers.c" <<'EOF'
void f(double *a, double *b, int n1, int n2, int n3, int n4, int i, int j, int k, int l, int m)
{
    a[idx5(n1, n2, n3, n4, i, j, k, l, 2 * m)] = 0.0;
    b[idx2(n1, i, 2 * j)] = 1.0;
}
EOF
cat >"$F/other_names.c" <<'EOF'
void f(double *a, int n, int i, int j)
{
    a[at2(n, i, 2 * j)] = 0.0;
    a[at2x(n, i, 2 * j)] = 1.0;
}
EOF
# Central helper headers/sources. Genuine definition forms: a function with a body, a prototype,
# a declarator wrapped onto its own line, and a #define.
mkdir -p "$F/full" "$F/at2" "$F/at2proto" "$F/at2wrapped" "$F/at2macro" \
	"$F/call_declared_elsewhere" "$F/call_undeclared" "$F/comment" "$F/inactive" "$F/broken"
cat >"$F/full/idx.h" <<'EOF'
#include <stddef.h>
static inline long idx0(long i) { return i; }
static inline long idx1(long i) { return i - 1; }
static inline long idx2(long n1, long i, long j) { return idx1(i) + idx1(j) * n1; }
static inline long idx3(long n1, long n2, long i, long j, long k)
{
    return idx2(n1, i, j) + idx1(k) * n1 * n2;
}
static inline long
idx4(long n1, long n2, long n3, long i, long j, long k, long l)
{
    return idx3(n1, n2, i, j, k) + idx1(l) * n1 * n2 * n3;
}
long idx5(long n1, long n2, long n3, long n4, long i, long j, long k, long l, long m);
static inline long idx1_stride(long i, long s) { return idx1(i) * s; }
#define idxlb(i, lb) ((i) - (lb))
EOF
printf '%s\n' 'static inline long at2(long n, long i, long j) { return (i - 1) + (j - 1) * n; }' >"$F/at2/idx.h"
printf '%s\n' 'long at2(long n, long i, long j);' >"$F/at2proto/idx.h"
printf '%s\n' 'static inline long' 'at2(long n, long i, long j)' '{' '    return (i - 1) + (j - 1) * n;' '}' \
	>"$F/at2wrapped/idx.h"
printf '%s\n' '#define at2(n, i, j) (((i) - 1) + ((j) - 1) * (n))' >"$F/at2macro/idx.h"
# Counter-examples that mention the name without defining it in the central file.
printf '%s\n' 'long at2(long n, long i, long j);' >"$F/call_declared_elsewhere/other.h"
cat >"$F/call_declared_elsewhere/idx.c" <<'EOF'
#include "other.h"
void use(long n, long i, long j)
{
    at2(n, i, j);
}
EOF
cat >"$F/call_undeclared/idx.c" <<'EOF'
void use(long n, long i, long j)
{
    at2(n, i, j);
}
EOF
cat >"$F/comment/idx.h" <<'EOF'
/*
long at2(long n, long i, long j);
#define at2(n, i, j) 0
 */
// long at2(long n, long i, long j);
static inline long at3(long n, long i, long j, long k) { return (i - 1) + (j - 1) * n + k; }
EOF
cat >"$F/inactive/idx.h" <<'EOF'
#if 0
long at2(long n, long i, long j);
#define at2(n, i, j) 0
#endif
#ifdef A_FLAG_NOBODY_SETS
static inline long at2(long n, long i, long j) { return i + j * n; }
#endif
static inline long at3(long n, long i, long j, long k) { return (i - 1) + (j - 1) * n + k; }
EOF
printf '%s\n' 'static inline long at2(long n, long i, long j) { return (i - 1) + (j - 1) * n' >"$F/broken/idx.h"
expect 1 "a helper outside the default set is not whitelisted" "$F/helpers.c" \
	":3: ad-hoc subscript '[idx5(n1, n2, n3, n4, i, j, k, l, 2 * m)]'"

PROJECT_NAMES="$TMP/tools/conformance/project/index-helper-names.txt"
mkdir -p "$(dirname "$PROJECT_NAMES")"
printf '%s\n' '# the port helper set' 'idx0' 'idx1' 'idx2' 'idx3' 'idx4' 'idx5  # five dimensions' \
	'idx1_stride' 'idxlb' >"$PROJECT_NAMES"
EXTRA_FILES=("$F/full/idx.h")
expect 0 "the project helper-name list is read from the project layer" "$F/helpers.c" \
	"helper names from '$PROJECT_NAMES'"
EXTRA_FILES=()
expect 2 "a listed helper needs its central definition among the checked files" "$F/helpers.c" \
	"no definition in the central helper header/source (idx.h / idx.c) among the checked files: idx0 idx1"
rm -f "$PROJECT_NAMES"

LIST="$TMP/names.txt"
printf '%s\n' 'at2' >"$LIST"
RUN_ENV=(INDEX_HELPER_NAMES="$LIST")
EXTRA_FILES=("$F/at2/idx.h")
expect 1 "the list replaces the default set" "$F/helpers.c" ":4: ad-hoc subscript '[idx2(n1, i, 2 * j)]'"
expect 1 "only the exact listed name is a helper" "$F/other_names.c" ":4: ad-hoc subscript '[at2x(n, i, 2 * j)]'"
# The listed helper's calls carry a stride multiply, so only a real definition makes this GREEN.
printf '%s\n' 'void f(double *a, int n, int i, int j)' '{' '    a[at2(n, i, 2 * j)] = 0.0;' '}' >"$F/at2_only.c"
for form in at2 at2proto at2wrapped at2macro; do
	EXTRA_FILES=("$F/$form/idx.h")
	expect 0 "a genuine definition form is GREEN: $form" "$F/at2_only.c" "0 violation(s)"
done
EXTRA_FILES=("$F/call_declared_elsewhere/idx.c")
expect 2 "a bare call in the central file is not a definition" "$F/at2_only.c" "checked files: at2 -"
EXTRA_FILES=("$F/call_undeclared/idx.c")
expect 2 "a bare call to an undeclared helper makes the central file UNRELIABLE" "$F/at2_only.c" \
	"does not parse cleanly"
EXTRA_FILES=("$F/comment/idx.h")
expect 2 "a code-shaped comment is not a definition" "$F/at2_only.c" "checked files: at2 -"
EXTRA_FILES=("$F/inactive/idx.h")
expect 2 "a declaration in an inactive #if branch is not a definition" "$F/at2_only.c" "checked files: at2 -"
EXTRA_FILES=("$F/broken/idx.h")
expect 2 "a central file that does not parse is UNRELIABLE" "$F/at2_only.c" "does not parse cleanly"
EXTRA_FILES=("$F/full/idx.h")
expect 2 "a listed name the helper header does not define is UNRELIABLE" "$F/other_names.c" "checked files: at2 -"
# Without libclang the definitions cannot be read: UNRELIABLE, never GREEN.
mkdir -p "$TMP/no-libclang/clang"
printf '%s\n' 'raise ImportError("libclang withheld by the test")' >"$TMP/no-libclang/clang/__init__.py"
EXTRA_FILES=("$F/at2/idx.h")
RUN_ENV=(INDEX_HELPER_NAMES="$LIST" PYTHONPATH="$TMP/no-libclang")
expect 2 "without libclang the listed names are UNRELIABLE" "$F/at2_only.c" "libclang (clang.cindex) is not usable"
RUN_ENV=(INDEX_HELPER_NAMES="$LIST")
cat >"$F/local_helper.c" <<'EOF'
static inline long at2(long n, long i, long j) { return (i - 1) + (j - 1) * n; }
void f(double *a, int n, int i, int j)
{
    a[at2(n, i, 2 * j)] = 0.0;
}
EOF
EXTRA_FILES=()
expect 2 "a definition outside the central helper header does not count" "$F/local_helper.c" "checked files: at2 -"
printf '%s\n' 'at2' 'idx[0-9]+' >"$LIST"
expect 2 "a pattern in the helper-name list is UNRELIABLE" "$F/other_names.c" "is not a C identifier"
printf '%s\n' '# nothing listed' '' >"$LIST"
expect 2 "an empty helper-name list is UNRELIABLE" "$F/other_names.c" "names no helper"
RUN_ENV=(INDEX_HELPER_NAMES="$TMP/absent.txt")
expect 2 "a named helper-name list that is missing is UNRELIABLE" "$F/other_names.c" "missing or unreadable"
RUN_ENV=()

# 4. The same in scan mode: the helper header is found in the scanned product tree.
mkdir -p "$TMP/product/src"
cp "$F/other_names.c" "$TMP/product/src/use.c"
printf '%s\n' 'at2' 'at2x' >"$LIST"
RUN_ENV=(INDEX_HELPER_NAMES="$LIST" TARGET_DIR="$TMP/product")
expect 2 "scan mode: listed helpers missing from the product's helper header are UNRELIABLE" \
	"" "checked files: at2 at2x -"
printf '%s\n' '#define at2x(n, i, j) at2(n, i, j)' | cat "$F/at2/idx.h" - >"$TMP/product/src/idx.h"
expect 0 "scan mode: listed helpers defined in the product's helper header are accepted" "" \
	"0 violation(s)"
# The header and the source in different directories, the source including the header by name.
mkdir -p "$TMP/split/include" "$TMP/split/src"
cp "$F/at2_only.c" "$TMP/split/src/use.c"
printf '%s\n' 'long at2(long n, long i, long j);' >"$TMP/split/include/idx.h"
printf '%s\n' '#include "idx.h"' 'long at2(long n, long i, long j) { return (i - 1) + (j - 1) * n; }' \
	>"$TMP/split/src/idx.c"
printf '%s\n' 'at2' >"$LIST"
RUN_ENV=(INDEX_HELPER_NAMES="$LIST" TARGET_DIR="$TMP/split")
expect 0 "scan mode: include/idx.h and src/idx.c that includes it are read together" "" "0 violation(s)"
RUN_ENV=()

if [ "$failures" -gt 0 ]; then
	printf '%s index-helper case(s) failed\n' "$failures" >&2
	exit 1
fi
