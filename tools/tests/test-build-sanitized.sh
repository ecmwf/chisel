#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# tools/build-checks/check-sanitized.py on small programs built here with AddressSanitizer and
# UndefinedBehaviorSanitizer: a clean program passes, a heap overflow (N4/T30), a signed overflow
# (T13), a float-to-integer conversion out of range (T17) and an allocation never freed (T36) are RED, a translation unit built without
# the sanitizers - or without float-cast-overflow, which GCC leaves out of undefined - is RED before
# any test runs, and a
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
cat >"$P/leak.c" <<'EOF'
#include <stdlib.h>
int main(int argc, char **argv) { (void)argv; double *a = malloc(8 * sizeof *a); a[0] = argc; return a[0] == 0; }
EOF
cat >"$P/cast.c" <<'EOF'
int main(int argc, char **argv) { (void)argv; volatile double d = 1e300 * argc; int i = (int)d; return i == 7; }
EOF

# build NAME FLAGS [COMPILER]: the program and a one-entry compilation database for it.
build() {
	local name="$1" flags="$2" cc="${3:-$CC}"
	( cd "$P" && $cc -std=c17 -g $flags -o "$name" "$name.c" )
	python3 - "$P" "$name" "$cc" "$flags" >"$TMP/$name.json" <<'PY'
import json, shlex, sys
proj, name, cc, flags = sys.argv[1:]
print(json.dumps([{"directory": proj, "file": name + ".c",
                   "arguments": [cc, "-std=c17", "-g"] + shlex.split(flags) + ["-c", name + ".c", "-o", name + ".o"]}]))
PY
}

SAN="-fsanitize=address,undefined,float-cast-overflow"
build clean "$SAN"
expect 0 "RESULT: GREEN" "a clean program on a sanitizer build is GREEN" --compile-commands "$TMP/clean.json" --cwd "$P" -- ./clean
build heap "$SAN"
expect 1 "AddressSanitizer" "a heap buffer overflow is RED" --compile-commands "$TMP/heap.json" --cwd "$P" -- ./heap
build signed "$SAN"
expect 1 "runtime error" "a signed-integer overflow is RED" --compile-commands "$TMP/signed.json" --cwd "$P" -- ./signed
build leak "$SAN"
expect 1 "LeakSanitizer" "an allocation never freed is RED" --compile-commands "$TMP/leak.json" --cwd "$P" -- ./leak
build cast "$SAN"
expect 1 "is outside the range of representable values" "a float-to-integer conversion out of range is RED" --compile-commands "$TMP/cast.json" --cwd "$P" -- ./cast
cp "$P/cast.c" "$P/nocast.c"
build nocast "-fsanitize=address,undefined"
expect 1 "not built with -fsanitize=float-cast-overflow" "a unit without float-cast-overflow is RED, tests not run" --compile-commands "$TMP/nocast.json" --cwd "$P" -- ./nocast

cp "$P/clean.c" "$P/plain.c"
build plain ""
expect 1 "not built with -fsanitize=address,float-cast-overflow,undefined" "a translation unit without the sanitizers is RED, tests not run" --compile-commands "$TMP/plain.json" --cwd "$P" -- ./plain
cp "$P/clean.c" "$P/half.c"
build half "$SAN -fno-sanitize=undefined"
expect 1 "-fno-sanitize=undefined takes a sanitizer back" "a sanitizer taken back with -fno-sanitize= is RED" --compile-commands "$TMP/half.json" --cwd "$P" -- ./half

cp "$P/signed.c" "$P/partial.c"
build partial "$SAN -fno-sanitize=signed-integer-overflow"
expect 1 "-fno-sanitize=signed-integer-overflow takes a sanitizer back" "taking back part of undefined is RED" --compile-commands "$TMP/partial.json" --cwd "$P" -- ./partial
cp "$P/clean.c" "$P/none.c"
build none "$SAN -fno-sanitize=all"
expect 1 "-fno-sanitize=all takes a sanitizer back" "-fno-sanitize=all is RED" --compile-commands "$TMP/none.json" --cwd "$P" -- ./none
# The caller's environment cannot divert the reports, and a runner that hides the exit status and
# prefixes the output does not hide the report.
printf '#!/bin/sh
./heap 2>&1 | sed "s/^/1: /"
exit 0
' >"$P/runner.sh"
chmod +x "$P/runner.sh"
out="$(ASAN_OPTIONS="log_path=$TMP/asan-log" python3 "$CHECK" --compile-commands "$TMP/heap.json" --cwd "$P" -- ./runner.sh 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 1 ] && grep -qF "AddressSanitizer" <<<"$out"; then
	ok "a report under a prefixing runner that exits 0, with ASAN_OPTIONS=log_path set, is RED"
else
	not_ok "a report under a prefixing runner that exits 0, with ASAN_OPTIONS=log_path set, is RED" "exit $rc: $out"
fi
# Flags or an environment that exempt code from the sanitizers (the tests are not run, so these
# entries need no binary).
dbonly() { # dbonly NAME FLAGS: a one-entry database, nothing built
	python3 - "$P" "$1" "$CC" "$2" >"$TMP/$1.json" <<'PY'
import json, shlex, sys
proj, name, cc, flags = sys.argv[1:]
print(json.dumps([{"directory": proj, "file": name + ".c",
                   "arguments": [cc, "-std=c17"] + shlex.split(flags) + ["-c", name + ".c", "-o", name + ".o"]}]))
PY
}
dbonly ignored "$SAN -fsanitize-ignorelist=ignore.txt"
expect 1 "-fsanitize-ignorelist=ignore.txt exempts code from the sanitizers" "a sanitizer ignore-list is RED" --compile-commands "$TMP/ignored.json" --cwd "$P" -- ./clean
dbonly blacklisted "$SAN -fsanitize-blacklist=ignore.txt"
expect 1 "-fsanitize-blacklist=ignore.txt exempts code from the sanitizers" "the old ignore-list spelling is RED" --compile-commands "$TMP/blacklisted.json" --cwd "$P" -- ./clean
out="$(UBSAN_OPTIONS="print_stacktrace=1:suppressions=$TMP/ub.supp" python3 "$CHECK" --compile-commands "$TMP/clean.json" --cwd "$P" -- ./clean 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 1 ] && grep -qF "UBSAN_OPTIONS sets suppressions=$TMP/ub.supp" <<<"$out"; then
	ok "a suppressions file in the environment is RED"
else
	not_ok "a suppressions file in the environment is RED" "exit $rc: $out"
fi
out="$(ASAN_OPTIONS="suppressions=" python3 "$CHECK" --compile-commands "$TMP/clean.json" --cwd "$P" -- ./clean 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 0 ]; then
	ok "an empty suppressions= option names no file and is GREEN"
else
	not_ok "an empty suppressions= option names no file and is GREEN" "exit $rc: $out"
fi
# MemorySanitizer (clang only, a build of its own): an uninitialized read (T8). It reports a WARNING,
# not an ERROR, so the report must be found even when the runner hides the exit status.
CLANG="$(command -v clang || true)"
[ -n "$CLANG" ] || { not_ok "clang is installed (MemorySanitizer cases)"; exit 1; }
cat >"$P/uninit.c" <<'EOF'
#include <stdio.h>
int main(int argc, char **argv) { (void)argv; int x; if (argc > 5) x = 1; if (x) puts("set"); return 0; }
EOF
MSAN="-fsanitize=memory -fsanitize-memory-track-origins"
build uninit "$MSAN" "$CLANG"
expect 1 "MemorySanitizer: use-of-uninitialized-value" "an uninitialized read on a MemorySanitizer build is RED" --compile-commands "$TMP/uninit.json" --sanitizers memory --cwd "$P" -- ./uninit
printf '#!/bin/sh\n./uninit 2>&1 | sed "s/^/1: /"\nexit 0\n' >"$P/msan-runner.sh"
chmod +x "$P/msan-runner.sh"
expect 1 "MemorySanitizer" "a MemorySanitizer WARNING under a runner that exits 0 is RED" --compile-commands "$TMP/uninit.json" --sanitizers memory --cwd "$P" -- ./msan-runner.sh
cp "$P/clean.c" "$P/mclean.c"
build mclean "$MSAN" "$CLANG"
expect 0 "RESULT: GREEN" "a clean program on a MemorySanitizer build is GREEN" --compile-commands "$TMP/mclean.json" --sanitizers memory --cwd "$P" -- ./mclean
expect 1 "not built with -fsanitize=memory" "a unit without MemorySanitizer is RED under --sanitizers memory" --compile-commands "$TMP/clean.json" --sanitizers memory --cwd "$P" -- ./clean
expect 2 "names no sanitizer" "--sanitizers naming none is UNRELIABLE" --compile-commands "$TMP/clean.json" --sanitizers "" --cwd "$P" -- ./clean
expect 2 "is not found" "a test command that does not exist is UNRELIABLE" --compile-commands "$TMP/clean.json" --cwd "$P" -- ./no-such-test
expect 2 "usage" "no test command at all is UNRELIABLE" --compile-commands "$TMP/clean.json"
expect 2 "cannot read the compilation database" "a missing database is UNRELIABLE" --compile-commands "$TMP/absent.json" --cwd "$P" -- ./clean

if [ "$failures" -ne 0 ]; then
	echo "# test-build-sanitized: $failures failure(s)" >&2
	exit 1
fi
echo "# test-build-sanitized: all assertions passed"
