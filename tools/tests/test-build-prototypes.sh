#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# tools/build-checks/check-prototypes.py on two-file builds: a call through the callee's header
# passes; a caller-local prototype is RED even when it matches (trap T33), and so is one with another
# arity, another pointer level, or no prototype at all, and an extern variable declared with another
# type; a typedef naming the same type and two static functions of one name in different files are
# not conflicts; a file libclang cannot parse is UNRELIABLE. A missing libclang fails the test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/build-checks/check-prototypes.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/    /'; failures=$((failures + 1)); }

python3 -c 'import clang.cindex' 2>/dev/null || { not_ok "python3 can import clang.cindex"; exit 1; }

# case LABEL EXIT NEEDLE A.C B.C [A-FLAGS]: a database of the two files (compiled with -std=c17
# -Iinclude, a.c also with A-FLAGS).
n=0
case_() {
	local label="$1" want="$2" needle="$3" out rc d
	n=$((n + 1))
	d="$TMP/c$n"
	mkdir -p "$d/include"
	printf 'double scale(double x, int n);\n' >"$d/include/scale.h"
	printf 'inline double twice(double x) { return 2.0 * x; }\n' >"$d/include/twice.h"
	printf '%s\n' "$4" >"$d/a.c"
	printf '%s\n' "$5" >"$d/b.c"
	python3 - "$d" "${6:-}" >"$d/compile_commands.json" <<'PY'
import json, shlex, sys
d, extra = sys.argv[1:]
print(json.dumps([{"directory": d, "file": "a.c", "arguments": ["cc", "-std=c17", "-Iinclude"] + shlex.split(extra) + ["-c", "a.c", "-o", "a.o"]},
                  {"directory": d, "file": "b.c", "command": "cc -std=c17 -Iinclude -c b.c -o b.o"}]))
PY
	out="$(python3 "$CHECK" --compile-commands "$d/compile_commands.json" 2>&1)" && rc=0 || rc=$?
	if [ "$rc" != "$want" ]; then
		not_ok "$label (expected exit $want, got $rc)" "$out"
	elif ! grep -qF -- "$needle" <<<"$out"; then
		not_ok "$label (output lacks '$needle')" "$out"
	else
		ok "$label"
	fi
}

DEF='double scale(double x, int n) { return x * n; }'
case_ "a call through the callee's header is GREEN" 0 "RESULT: GREEN" "#include \"scale.h\"
$DEF" '#include "scale.h"
double use(void) { return scale(1.0, 2); }'
case_ "a caller-local prototype is RED even when it matches" 1 "scale is declared here, a caller-local prototype" "$DEF" \
	'double scale(double x, int n); double use(void) { return scale(1.0, 2); }'
case_ "a prototype with another arity is RED" 1 "scale is declared with 2 types" "$DEF" \
	'double scale(double x); double use(void) { return scale(1.0); }'
case_ "a prototype with another pointer level is RED" 1 "scale is declared with 2 types" "$DEF" \
	'double scale(double *x, int n); double use(void) { double v = 1.0; return scale(&v, 2); }'
case_ "an unprototyped declaration is RED" 1 "scale is declared with 2 types" "$DEF" \
	'double scale(); double use(void) { return scale(1.0, 2); }'
case_ "a typedef naming the same type is not a conflict" 0 "RESULT: GREEN" \
	'typedef double real_t; real_t scale(real_t x, int n) { return x * n; }' '#include "scale.h"
double use(void) { return scale(1.0, 2); }'
case_ "static functions of one name in two files are not a conflict" 0 "RESULT: GREEN" \
	'static int helper(int x) { return x; } int fa(void) { return helper(1); }' \
	'static double helper(double x) { return x; } double fb(void) { return helper(1.0); }'
case_ "an extern variable declared with another type is RED" 1 "count is declared with 2 types" \
	'int count = 0;' 'extern long count; long get(void) { return count; }'
case_ "main in two executables of one build is not a conflict" 0 "RESULT: GREEN" \
	'int main(void) { return 0; }' 'int main(int argc, char **argv) { (void)argv; return argc - 1; }'
case_ "an array declared without its size matches the sized definition" 0 "RESULT: GREEN" \
	'const double tab[3] = {1.0, 2.0, 3.0};' 'extern const double tab[]; double first(void) { return tab[0]; }'
case_ "an array declared with another size is RED" 1 "tab is declared with 2 types" \
	'const double tab[3] = {1.0, 2.0, 3.0};' 'extern const double tab[4]; double first(void) { return tab[0]; }'
case_ "a system header read under different macros is not compared" 0 "RESULT: GREEN" \
	'#include <string.h>
char *msg(int e, char *b, size_t n) { (void)strerror_r(e, b, n); return b; }' \
	'#define _POSIX_C_SOURCE 200112L
#include <string.h>
int msg2(int e, char *b, size_t n) { return strerror_r(e, b, n) != 0; }' "-D_GNU_SOURCE"
case_ "a forward declaration of a function its own file defines is not a caller-local prototype" 0 "RESULT: GREEN" \
	'double later(double x); double first(double x) { return later(x); } double later(double x) { return x; }' \
	'int other(void) { return 0; }'
case_ "C99 extern inline of a header's inline definition is not a caller-local prototype" 0 "RESULT: GREEN" \
	'#include "twice.h"
extern inline double twice(double x);' '#include "twice.h"
double use(void) { return twice(2.0); }'
case_ "gcc-only warning and analyzer flags do not stop the parse" 0 "RESULT: GREEN" "$DEF" \
	'int other(void) { return 0; }' "-Werror -Wlogical-op -Wduplicated-cond -fanalyzer"
case_ "a file libclang cannot parse is UNRELIABLE" 2 "cannot parse" "$DEF" 'double use(void) { return scale(1.0, 2) }'
# The flags that change predefined macros reach the parse (a file may select code by them), and a
# kept gcc-only flag clang does not know makes the parse UNRELIABLE, naming the flag.
MACROS='#if !defined(_OPENMP) || !defined(__CHAR_UNSIGNED__) || !defined(__OPTIMIZE__) || !defined(__FAST_MATH__)
#error a flag that sets a predefined macro did not reach the parse
#endif
#if !defined(_REENTRANT) || !defined(__AVX2__) || __SIZEOF_LONG__ != 4
#error a flag that sets a predefined macro did not reach the parse
#endif'
case_ "-fopenmp, -funsigned-char, -O2, -ffast-math, -pthread, -mavx2 and -m32 reach the parse" 0 "RESULT: GREEN" \
	"$MACROS
$DEF" 'int other(void) { return 0; }' "-fopenmp -funsigned-char -O2 -ffast-math -pthread -mavx2 -m32"
case_ "-ansi after -std=c17 reaches the parse (C89 has no __STDC_VERSION__)" 0 "RESULT: GREEN" '#ifdef __STDC_VERSION__
#error -ansi did not reach the parse
#endif
int f(void) { return 0; }' 'int other(void) { return 0; }' "-ansi"
case_ "--target= reaches the parse" 0 "RESULT: GREEN" '#ifndef __aarch64__
#error --target did not reach the parse
#endif
int f(void) { return 0; }' 'int other(void) { return 0; }' "--target=aarch64-linux-gnu"
case_ "a kept gcc-only flag clang does not know is UNRELIABLE, named" 2 "-mpreferred-stack-boundary=4" "$DEF" \
	'int other(void) { return 0; }' "-mpreferred-stack-boundary=4"

d="$TMP/missing"
mkdir -p "$d"
printf '[{"directory": "%s", "file": "gone.c", "arguments": ["cc", "-c", "gone.c"]}]\n' "$d" >"$d/compile_commands.json"
out="$(python3 "$CHECK" --compile-commands "$d/compile_commands.json" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 2 ] && grep -q "does not exist" <<<"$out"; then
	ok "a unit whose file does not exist is UNRELIABLE"
else
	not_ok "a unit whose file does not exist is UNRELIABLE" "exit $rc: $out"
fi

if [ "$failures" -ne 0 ]; then
	echo "# test-build-prototypes: $failures failure(s)" >&2
	exit 1
fi
echo "# test-build-prototypes: all assertions passed"
