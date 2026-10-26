#!/usr/bin/env bash
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

# case LABEL EXIT NEEDLE A.C B.C: a database of the two files (compiled with -std=c17 -Iinclude).
n=0
case_() {
	local label="$1" want="$2" needle="$3" out rc d
	n=$((n + 1))
	d="$TMP/c$n"
	mkdir -p "$d/include"
	printf 'double scale(double x, int n);\n' >"$d/include/scale.h"
	printf '%s\n' "$4" >"$d/a.c"
	printf '%s\n' "$5" >"$d/b.c"
	printf '[{"directory": "%s", "file": "a.c", "arguments": ["cc", "-std=c17", "-Iinclude", "-c", "a.c", "-o", "a.o"]},\n {"directory": "%s", "file": "b.c", "command": "cc -std=c17 -Iinclude -c b.c -o b.o"}]\n' "$d" "$d" >"$d/compile_commands.json"
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
case_ "a file libclang cannot parse is UNRELIABLE" 2 "cannot parse" "$DEF" 'double use(void) { return scale(1.0, 2) }'

if [ "$failures" -ne 0 ]; then
	echo "# test-build-prototypes: $failures failure(s)" >&2
	exit 1
fi
echo "# test-build-prototypes: all assertions passed"
