#!/usr/bin/env bash
# tools/build-checks/check-sanitized.py on small programs built here with AddressSanitizer and
# UndefinedBehaviorSanitizer: a clean program passes, a heap overflow (L4/T30) and a signed overflow
# (T13) are RED, a translation unit built without the sanitizers is RED before any test runs, and a
# missing test command is UNRELIABLE. The sanitizer runtimes ship with gcc and clang; without them
# the test fails, it never skips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/build-checks/check-sanitized.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CC="$(command -v cc || command -v gcc || command -v clang)"

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; printf '%s\n' "${2:-}" | tail -20 | sed 's/^/    /'; failures=$((failures + 1)); }
expect() { # expect EXIT NEEDLE LABEL ARGS...
	local want="$1" needle="$2" label="$3" out rc
	shift 3
	out="$(python3 "$CHECK" "$@" 2>&1)" && rc=0 || rc=$?
	if [ "$rc" != "$want" ]; then
		not_ok "$label (expected exit $want, got $rc)" "$out"
	elif ! grep -qF -- "$needle" <<<"$out"; then
		not_ok "$label (output lacks '$needle')" "$out"
	else
		ok "$label"
	fi
}

P="$TMP/proj"
mkdir -p "$P"
cat >"$P/clean.c" <<'EOF'
int main(void) { int a[4] = {0, 1, 2, 3}; return a[1] - 1; }
EOF
cat >"$P/heap.c" <<'EOF'
#include <stdlib.h>
int main(void) { int *p = malloc(4 * sizeof *p); p[4] = 1; int r = p[0]; free(p); return r; }
EOF
cat >"$P/signed.c" <<'EOF'
#include <limits.h>
int main(int argc, char **argv) { (void)argv; int x = INT_MAX; x += argc; return x == 0; }
EOF

# build NAME FLAGS: the program and a one-entry compilation database for it.
build() {
	local name="$1" flags="$2"
	( cd "$P" && $CC -std=c17 -g $flags -o "$name" "$name.c" )
	python3 - "$P" "$name" "$CC" "$flags" >"$TMP/$name.json" <<'PY'
import json, shlex, sys
proj, name, cc, flags = sys.argv[1:]
print(json.dumps([{"directory": proj, "file": name + ".c",
                   "arguments": [cc, "-std=c17", "-g"] + shlex.split(flags) + ["-c", name + ".c", "-o", name + ".o"]}]))
PY
}

SAN="-fsanitize=address,undefined"
build clean "$SAN"
expect 0 "RESULT: GREEN" "a clean program on a sanitizer build is GREEN" --compile-commands "$TMP/clean.json" --cwd "$P" -- ./clean
build heap "$SAN"
expect 1 "AddressSanitizer" "a heap buffer overflow is RED" --compile-commands "$TMP/heap.json" --cwd "$P" -- ./heap
build signed "$SAN"
expect 1 "runtime error" "a signed-integer overflow is RED" --compile-commands "$TMP/signed.json" --cwd "$P" -- ./signed

cp "$P/clean.c" "$P/plain.c"
build plain ""
expect 1 "not built with -fsanitize=address,undefined" "a translation unit without the sanitizers is RED, tests not run" --compile-commands "$TMP/plain.json" --cwd "$P" -- ./plain
cp "$P/clean.c" "$P/half.c"
build half "$SAN -fno-sanitize=undefined"
expect 1 "not built with -fsanitize=undefined" "a sanitizer taken back with -fno-sanitize= is RED" --compile-commands "$TMP/half.json" --cwd "$P" -- ./half

expect 2 "is not found" "a test command that does not exist is UNRELIABLE" --compile-commands "$TMP/clean.json" --cwd "$P" -- ./no-such-test
expect 2 "usage" "no test command at all is UNRELIABLE" --compile-commands "$TMP/clean.json"
expect 2 "cannot read the compilation database" "a missing database is UNRELIABLE" --compile-commands "$TMP/absent.json" --cwd "$P" -- ./clean

if [ "$failures" -ne 0 ]; then
	echo "# test-build-sanitized: $failures failure(s)" >&2
	exit 1
fi
echo "# test-build-sanitized: all assertions passed"
