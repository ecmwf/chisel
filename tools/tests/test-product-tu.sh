#!/usr/bin/env bash
# Regression tests for tools/conformance/lib/product_tu.py, the one place the product checks get
# libclang translation units for the product's C files from.
#
# Each case runs the helper's command line over a synthetic product tree and states the exit code
# and a text the report must contain: which arguments a file was parsed with (its
# compile_commands.json entry, or the defaults with -I for every directory of the tree), and, for
# a file that does not parse cleanly, the first error. A missing libclang fails the test; it never
# skips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$ROOT/tools/conformance/lib/product_tu.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! python3 -c 'import clang.cindex as ci; ci.Index.create()' >/dev/null 2>&1; then
	printf 'not ok - python3 clang.cindex with the native libclang is required\n' >&2
	exit 1
fi

failures=0
RUN_ENV=()
# expect EXIT LABEL WANT ARGS... - run the helper with ARGS; its output must contain WANT.
expect() {
	local expected="$1" label="$2" want="$3" output rc
	shift 3
	set +e
	output="$(cd "$TMP" && env ${RUN_ENV[@]+"${RUN_ENV[@]}"} python3 "$TOOL" "$@" 2>&1)"
	rc=$?
	set -e
	if [ "$rc" -ne "$expected" ]; then
		printf 'not ok - %s (expected exit %s, got %s)\n%s\n' "$label" "$expected" "$rc" "$output" >&2
		failures=$((failures + 1))
		return 0
	fi
	if [ -n "$want" ] && ! grep -qF -- "$want" <<<"$output"; then
		printf 'not ok - %s (output lacks %s)\n%s\n' "$label" "$want" "$output" >&2
		failures=$((failures + 1))
		return 0
	fi
	printf 'ok - %s\n' "$label"
}

# 1. Default arguments: -std=c17 and -I for every directory of the product tree, so a source
#    finds a header kept in another directory; compiler headers resolve through clang's resource
#    directory.
P="$TMP/product"
mkdir -p "$P/include" "$P/src"
cat >"$P/include/grid.h" <<'EOF'
#include <stddef.h>
typedef struct { size_t nx, ny; } grid;
EOF
cat >"$P/src/step.c" <<'EOF'
#include "grid.h"
size_t cells(const grid *g) { return g->nx * g->ny; }
EOF
expect 0 "a source finds a header in another directory of the product tree" \
	"src/step.c: parsed, with the default arguments" --root "$P" -- "$P/src/step.c"
expect 2 "without the product root the other directory is not searched" \
	"'grid.h' file not found" -- "$P/src/step.c"
expect 0 "a header a parsed source includes is read inside that source" \
	"include/grid.h: read inside '$P/src/step.c'" --root "$P" -- "$P/src/step.c" "$P/include/grid.h"
expect 0 "a header no source includes is parsed on its own" \
	"include/grid.h: parsed, with the default arguments" --root "$P" -- "$P/include/grid.h"

# 2. A file that does not parse cleanly is UNRELIABLE, with its first error; never skipped.
printf '%s\n' 'int f(int i)' '{' '    return i +;' '}' >"$P/src/broken.c"
expect 2 "a syntax error is UNRELIABLE, with the first error" \
	"broken.c' does not parse cleanly: $P/src/broken.c:3: expected expression" --root "$P" -- "$P/src/broken.c"
printf '%s\n' 'int f(int i) { return undeclared_helper(i); }' >"$P/src/undeclared.c"
expect 2 "a call to an undeclared function is UNRELIABLE" "undeclared.c:1: call to undeclared function" \
	--root "$P" -- "$P/src/step.c" "$P/src/undeclared.c"
printf '%s\n' 'size_t area(const grid *g);' >"$P/include/needs_grid.h"
expect 2 "a header that is not self-contained and no source includes is UNRELIABLE" \
	"needs_grid.h' does not parse cleanly" --root "$P" -- "$P/include/needs_grid.h"
rm -f "$P/src/broken.c" "$P/src/undeclared.c" "$P/include/needs_grid.h"

# 3. compile_commands.json at the product root, read through tools/build-checks/lib/compile_db.py:
#    its entry's arguments, response files expanded, relative paths resolved against the entry's
#    directory, and only the flags that shape the parse kept (a warning does not change the code,
#    and -Werror would make it fatal; a gcc-only code-generation flag cannot stop libclang).
B="$TMP/cc"
mkdir -p "$B/inc" "$B/src" "$B/build"
printf '%s\n' '#define NCOL 4' >"$B/inc/config.h"
cat >"$B/src/model.c" <<'EOF'
#include "config.h"
#ifndef MODEL_PRECISION
#error MODEL_PRECISION is set by the build
#endif
double model_sum(const double *v)
{
    int unused_local;
    double s = 0.0;
    for (int k = 0; k < NCOL; k++) s += v[k];
    return s;
}
EOF
cat >"$B/compile_commands.json" <<EOF
[
  {"directory": "$B/build", "file": "../src/model.c",
   "arguments": ["cc", "-std=c11", "-I../inc", "-DMODEL_PRECISION=8", "-Wall", "-Werror",
                 "-c", "../src/model.c", "-o", "model.o"]}
]
EOF
expect 0 "a file is parsed with its compile_commands.json entry" \
	"src/model.c: parsed, with its entry in '$B/compile_commands.json'" --root "$B" -- "$B/src/model.c"
cat >"$B/compile_commands.json" <<EOF
[{"directory": "$B/build", "file": "../src/model.c",
  "command": "ccache cc -I../inc -DMODEL_PRECISION=8 -c ../src/model.c -o model.o"}]
EOF
expect 0 "an entry's command string is split as the shell would, wrapper included" \
	"its entry in '$B/compile_commands.json'" --root "$B" -- "$B/src/model.c"
mv "$B/compile_commands.json" "$B/compile_commands.off"
expect 2 "without compile_commands.json the same file does not parse" \
	"MODEL_PRECISION is set by the build (parsed with the default arguments)" --root "$B" -- "$B/src/model.c"
mv "$B/compile_commands.off" "$B/compile_commands.json"
printf '%s\n' 'double other(void) { return 0.0; }' >"$B/src/other.c"
expect 2 "a source compile_commands.json does not list is UNRELIABLE, never parsed with guesses" \
	"src/other.c' is a C source that '$B/compile_commands.json' does not list" \
	--root "$B" -- "$B/src/model.c" "$B/src/other.c"
rm -f "$B/src/other.c"
printf '%s\n' 'double area(double w, double h);' >"$B/inc/area.h"
expect 0 "a header no listed source includes is parsed with the default arguments" \
	"inc/area.h: parsed, with the default arguments (a header:" --root "$B" -- "$B/src/model.c" "$B/inc/area.h"
mv "$B/compile_commands.json" "$B/compile_commands.real"
ln -s "$B/build-gone/compile_commands.json" "$B/compile_commands.json"
expect 2 "a compile_commands.json that links to nothing is UNRELIABLE" "is a link to a file that does not exist" \
	--root "$B" -- "$B/src/model.c"
rm -f "$B/compile_commands.json"
mv "$B/compile_commands.real" "$B/compile_commands.json"
printf '%s\n' '-DMODEL_PRECISION=8' >"$B/build/defs.rsp"
cat >"$B/compile_commands.json" <<EOF
[{"directory": "$B/build", "file": "../src/model.c",
  "arguments": ["cc", "@defs.rsp", "-I../inc", "-c", "../src/model.c"]}]
EOF
expect 0 "a response file in the entry is expanded" "its entry in '$B/compile_commands.json'" \
	--root "$B" -- "$B/src/model.c"
cat >"$B/compile_commands.json" <<EOF
[{"directory": "$B/build", "file": "../src/model.c",
  "arguments": ["gcc", "-I../inc", "-DMODEL_PRECISION=8", "-fno-such-option-anywhere", "-Wlogical-op",
                "-c", "../src/model.c"]}]
EOF
expect 0 "a gcc-only flag that does not shape the parse is left out" "its entry in '$B/compile_commands.json'" \
	--root "$B" -- "$B/src/model.c"
cat >"$B/compile_commands.json" <<EOF
[{"directory": "$B/build", "file": "../src/model.c",
  "arguments": ["gcc", "-I../inc", "-DMODEL_PRECISION=8", "-mpreferred-stack-boundary=4", "-c", "../src/model.c"]}]
EOF
expect 2 "a kept gcc-only flag clang does not know is UNRELIABLE, named" \
	"unknown argument: '-mpreferred-stack-boundary=4'" --root "$B" -- "$B/src/model.c"
printf '%s\n' '[{"directory": "/x", "file": "a.c", "arguments": ["cc", "-c", "a.c"]' >"$B/compile_commands.json"
expect 2 "a compile_commands.json that is not JSON is UNRELIABLE" "cannot read the compilation database" \
	--root "$B" -- "$B/src/model.c"
printf '%s\n' '[{"file": "a.c", "arguments": ["cc", "-c", "a.c"]}]' >"$B/compile_commands.json"
expect 2 "an entry with no directory is UNRELIABLE" 'an entry without a "file" and a "directory" string' \
	--root "$B" -- "$B/src/model.c"
printf '%s\n' '[{"directory": "build", "file": "../src/model.c", "arguments": ["cc", "-c", "../src/model.c"]}]' \
	>"$B/compile_commands.json"
expect 2 "an entry with a relative directory is UNRELIABLE" 'has a relative "directory"' \
	--root "$B" -- "$B/src/model.c"

# 4. In a pool of parsers, the first file (in the order given) that does not parse is the one
#    reported, whichever finishes first.
Q="$TMP/pool"
mkdir -p "$Q"
for n in 1 2 3 4 5 6; do printf 'int f%s(void) { return %s; }\n' "$n" "$n" >"$Q/m$n.c"; done
printf '%s\n' 'int f2(void) { return 2 }' >"$Q/m2.c"
printf '%s\n' 'int f5(void) { return }' >"$Q/m5.c"
RUN_ENV=(CHISEL_PARSE_JOBS=4)
expect 2 "a pool reports the first file that does not parse" "m2.c' does not parse cleanly" \
	--root "$Q" -- "$Q/m1.c" "$Q/m2.c" "$Q/m3.c" "$Q/m4.c" "$Q/m5.c" "$Q/m6.c"
RUN_ENV=()

# 5. Without libclang nothing can be parsed: UNRELIABLE, never a clean result.
mkdir -p "$TMP/no-libclang/clang"
printf '%s\n' 'raise ImportError("libclang withheld by the test")' >"$TMP/no-libclang/clang/__init__.py"
RUN_ENV=(PYTHONPATH="$TMP/no-libclang")
expect 2 "without libclang the files are UNRELIABLE" "libclang (clang.cindex) is not usable" \
	--root "$P" -- "$P/src/step.c"
RUN_ENV=()

if [ "$failures" -gt 0 ]; then
	printf '%s product_tu case(s) failed\n' "$failures" >&2
	exit 1
fi
