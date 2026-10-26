#!/usr/bin/env bash
# Regression tests for tools/conformance/check-index-helpers.sh.
#
# Drives a byte copy of the shipped check (and its lib/) inside a throwaway directory, so no
# project-layer waiver or helper-name file is picked up, over synthetic TARGET files passed
# explicitly. Every case states the verdict and, for a RED, the access that must be reported. The
# check reads the C through libclang (python3 with clang.cindex), so every fixture is C that
# compiles; a fixture that does not is a case of its own (UNRELIABLE).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset TARGET_DIR PRODUCT_ROOT INDEX_HELPER_WAIVERS INDEX_HELPER_NAMES _PR_LOAD_CWD

# The check parses every file with libclang; without it every case would be UNRELIABLE, so the
# test cannot pass vacuously - it stops here.
if ! python3 -c 'import clang.cindex as ci; ci.Index.create()' >/dev/null 2>&1; then
	printf 'not ok - python3 clang.cindex with the native libclang is required to run the check\n' >&2
	exit 1
fi

mkdir -p "$TMP/tools/conformance"
cp "$ROOT/tools/conformance/check-index-helpers.sh" "$TMP/tools/conformance/"
cp -R "$ROOT/tools/conformance/lib" "$TMP/tools/conformance/"
# The checks parse the product through the build checks' compilation-database reader.
mkdir -p "$TMP/tools/build-checks"
cp -R "$ROOT/tools/build-checks/lib" "$TMP/tools/build-checks/"
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

# 1. Declarations: a declaration's array SIZE is not an access. An identifier that merely begins
#    with a type keyword, or a _t name used as a variable, is an ordinary expression whose accesses
#    are checked.
cat >"$F/decl_ok.c" <<'EOF'
typedef double scalar_t;
void f(int n, int m)
{
    double vv[n * m];
    static int w[2 * 4];
    scalar_t ar1[n * m];
    const scalar_t *row[n * m];
    (void)vv; (void)w; (void)ar1; (void)row;
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
typedef double scalar_t;
void scalar_transform(scalar_t x, int i, int j, int n);
void f(const scalar_t *a, int i, int j, int n)
{
    scalar_transform(a[i + j * n], i, j, n);
}
EOF
expect 1 "a call whose name begins with a typedef name is not a declaration" "$F/prefix_typedef.c" '[i + j * n]'

cat >"$F/typedef_array.c" <<'EOF'
typedef double scalar_t;
void f(scalar_t *rate_t, scalar_t count_t, int i, int j, int nx)
{
    rate_t[i + j * nx] = 0.0;
    count_t = rate_t[i + j * nx];
    (void)count_t;
}
EOF
expect 1 "a _t name used as a variable is not a declaration" "$F/typedef_array.c" ':4:'

cat >"$F/typedef_product.c" <<'EOF'
void f(double *pz, double zq_t, double zfac, int i, int j, int nx)
{
    double ztend = zfac +
                   zq_t * pz[i + j * nx];
    (void)ztend;
}
EOF
expect 1 "a _t name times a subscript on a continuation line is a product, not a declaration" \
	"$F/typedef_product.c" ':4:'

# 2. Accesses wrapped across physical lines (a formatter column limit wraps long helper calls) are
#    one expression to the parser: a wrapped helper call passes, a wrapped flatten is still RED and
#    reported at the line the access starts on. A file that does not parse is UNRELIABLE, and a
#    bracket inside a character literal is not a subscript.
cat >"$F/wrapped_helper.c" <<'EOF'
long idx2(long n1, long n2, long i, long j);
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
long idx2(long n1, long n2, long i, long j);
void f(double *y, double *w, int nx, int ny, int i, int j)
{
    y[idx2(nx, ny,
           i, j)] = w[i + j * nx];
}
EOF
expect 1 "a flatten after a wrapped subscript on the continuation line is still checked" \
	"$F/wrapped_then_flatten.c" ":5: ad-hoc subscript '[i + j * nx]'"

cat >"$F/wrapped_decl.c" <<'EOF'
typedef double scalar_t;
void f(int n, int m)
{
    scalar_t buf[n *
                 m];
    (void)buf;
}
EOF
expect 0 "a wrapped declaration size is still a declaration" "$F/wrapped_decl.c"

printf '%s\n' 'void f(double *z, int i, int j, int nx)' '{' '    z[i +' >"$F/unterminated.c"
expect 2 "a file that does not parse is UNRELIABLE, never skipped" "$F/unterminated.c" \
	"unterminated.c' does not parse cleanly"
printf '%s\n' 'void f(double *z, int i) { z[undeclared_index(i)] = 0.0; }' >"$F/undeclared.c"
expect 2 "a call to an undeclared function is UNRELIABLE" "$F/undeclared.c" "call to undeclared function"

{
	printf '%s\n' 'int f(char c, int x)' '{' "    if (c == '[') x = 0;"
	for _ in $(seq 1 100); do printf '%s\n' '    x = x + 1;'; done
	printf '%s\n' '    return x;' '}'
} >"$F/stray_bracket.c"
expect 0 "a bracket in a character literal is not a subscript" "$F/stray_bracket.c" "0 violation(s)"

# 3. The helper set is the port's convention. A call whose arguments carry a stride multiply is
#    accepted only when it names a helper: by default idx0..idx4 / idx1_stride / idxlb; a port
#    lists its own set in the project layer, and that list REPLACES the default. Only exact names
#    count, a malformed or empty list is UNRELIABLE, and every listed name must be defined in the
#    central helper header/source (idx.h / idx.c) among the checked files.
cat >"$F/helpers.c" <<'EOF'
long idx2(long n1, long i, long j);
long idx5(long n1, long n2, long n3, long n4, long i, long j, long k, long l, long m);
void f(double *a, double *b, int n1, int n2, int n3, int n4, int i, int j, int k, int l, int m)
{
    a[idx5(n1, n2, n3, n4, i, j, k, l, 2 * m)] = 0.0;
    b[idx2(n1, i, 2 * j)] = 1.0;
}
EOF
cat >"$F/other_names.c" <<'EOF'
long at2(long n, long i, long j);
long at2x(long n, long i, long j);
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
	":5: ad-hoc subscript '[idx5(n1, n2, n3, n4, i, j, k, l, 2 * m)]'"

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
expect 1 "the list replaces the default set" "$F/helpers.c" ":6: ad-hoc subscript '[idx2(n1, i, 2 * j)]'"
expect 1 "only the exact listed name is a helper" "$F/other_names.c" ":6: ad-hoc subscript '[at2x(n, i, 2 * j)]'"
# The listed helper's calls carry a stride multiply, so only a real definition makes this GREEN.
printf '%s\n' 'long at2(long n, long i, long j);' 'void f(double *a, int n, int i, int j)' '{' \
	'    a[at2(n, i, 2 * j)] = 0.0;' '}' >"$F/at2_only.c"
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

# 5. What only a parse can tell. Pointer arithmetic is an access too; a typedef'd declaration's
#    size, a cast inside a subscript and a comment are not flattens; a flatten a macro produces is
#    reported where the macro is used.
cat >"$F/deref_flatten.c" <<'EOF'
void f(double *a, int i, int j, int n)
{
    *(a + i + j * n) = 0.0;
}
EOF
expect 1 "a dereferenced pointer flatten is RED" "$F/deref_flatten.c" \
	"deref_flatten.c:3: ad-hoc pointer offset 'a + i + j * n'"
cat >"$F/column_pointer.c" <<'EOF'
double first(double *a, int j, int n)
{
    double *col = a + j * n;
    return col[0];
}
EOF
expect 1 "a column pointer computed by a stride is RED" "$F/column_pointer.c" \
	"column_pointer.c:3: ad-hoc pointer offset 'a + j * n'"
cat >"$F/pointer_ok.c" <<'EOF'
double last(double *a, double *end, int i)
{
    double *p = a + i;
    p += 1;
    return *(p - 1) + (double)(end - a);
}
EOF
expect 0 "pointer arithmetic with no stride is GREEN" "$F/pointer_ok.c" "0 violation(s)"
cat >"$F/typedef_decl.c" <<'EOF'
typedef double real_wp;
void f(void)
{
    real_wp t[3 * 4];
    (void)t;
}
EOF
expect 0 "a typedef'd declaration's size is not an access" "$F/typedef_decl.c" "0 violation(s)"
cat >"$F/cast_index.c" <<'EOF'
void f(double *b, const double *p)
{
    b[(int)*p] = 1.0;
}
EOF
expect 0 "a cast and a dereference in a subscript are not a multiply" "$F/cast_index.c" "0 violation(s)"
cat >"$F/comment.c" <<'EOF'
void f(double *a, int i)
{
    // a[i*n] was the old layout
    /* b[i*n] too */
    a[i] = 0.0;
}
EOF
expect 0 "a subscript in a comment is not code" "$F/comment.c" "0 violation(s)"
mkdir -p "$F/macro"
cat >"$F/macro/layout.h" <<'EOF'
#define AT(a, i, j) (a)[(i) + (j) * n]
#define STRIDE(j) ((j) * n)
EOF
cat >"$F/macro/use.c" <<'EOF'
#include "layout.h"
void f(double *z, int i, int j, int n)
{
    z[i] = 0.0;
    AT(z, i, j) = 1.0;
    z[i + STRIDE(j)] = 2.0;
}
EOF
expect 1 "a flatten a macro produces is reported where the macro is used" "$F/macro/use.c" \
	"use.c:5: ad-hoc subscript in the expansion of macro 'AT': 'AT(z, i, j)'"
expect 1 "a stride a macro produces inside a subscript is reported at the subscript" "$F/macro/use.c" \
	"use.c:6: ad-hoc subscript '[i + STRIDE(j)]' (the multiply comes from macro 'STRIDE')"

# 6. With the product's compile_commands.json the files are parsed as they are built, so a stride
#    hidden in a macro the build defines is seen; without it, a file that needs the build's
#    definitions does not parse and is UNRELIABLE.
P="$TMP/cc-product"
mkdir -p "$P/src" "$P/build"
cat >"$P/src/step.c" <<'EOF'
void step(double *z, int i, int j, int nx)
{
    z[i + STRIDE(j)] = 0.0;
}
EOF
cat >"$P/compile_commands.json" <<EOF
[{"directory": "$P/build", "file": "../src/step.c",
  "arguments": ["cc", "-std=c17", "-DSTRIDE(j)=((j)*nx)", "-c", "../src/step.c", "-o", "step.o"]}]
EOF
RUN_ENV=(TARGET_DIR="$P")
expect 1 "a stride from the build's own definitions is RED" "" \
	"step.c:3: ad-hoc subscript '[i + STRIDE(j)]'"
mv "$P/compile_commands.json" "$P/compile_commands.off"
expect 2 "without compile_commands.json the same file does not parse" "" "does not parse cleanly"
RUN_ENV=()

# 7. Waivers: a recorded convention-exception waives exactly the access it quotes.
cat >"$F/m.c" <<'EOF'
void f(double *z, double *w, int i, int j, int a, int b, int nx, int ny)
{
    z[i + j * nx] = 0.0;
    w[a + b * ny] = 0.0;
}
EOF
printf '%s\t%s\n' 'm.c' 'i + j * nx' >"$TMP/waivers.txt"
RUN_ENV=(INDEX_HELPER_WAIVERS="$TMP/waivers.txt")
expect 1 "a waiver covers only the access it quotes" "$F/m.c" "1 violation(s); 1 waived"
expect 1 "a waived access is reported as waived" "$F/m.c" \
	"[WAIVE] $F/m.c:3: ad-hoc subscript '[i + j * nx]' (recorded convention-exception)"
RUN_ENV=()

# 8. The files are parsed in a pool of processes; the verdict and the report are the same as in one.
P="$TMP/pooled"
mkdir -p "$P/src"
for n in 1 2 3 4 5 6; do
	printf 'void f%s(double *a, int i, int j, int n) { a[i] = 0.0; a[i + j * n] = %s.0; }\n' "$n" "$n" >"$P/src/m$n.c"
done
serial="$(cd "$TMP" && env TARGET_DIR="$P" CHISEL_PARSE_JOBS=1 bash "$CHECK" 2>&1)" || true
pooled="$(cd "$TMP" && env TARGET_DIR="$P" CHISEL_PARSE_JOBS=4 bash "$CHECK" 2>&1)" || true
if [ "$serial" = "$pooled" ] && grep -qF "12 access(es) checked in 6 file(s); 6 violation(s)" <<<"$pooled"; then
	printf 'ok - a pool of parsers reports what one parser does\n'
else
	printf 'not ok - a pool of parsers reports what one parser does\n--- serial\n%s\n--- pooled\n%s\n' "$serial" "$pooled" >&2
	failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
	printf '%s index-helper case(s) failed\n' "$failures" >&2
	exit 1
fi
