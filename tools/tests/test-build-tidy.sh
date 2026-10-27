#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# tools/build-checks/check-tidy.py on small builds, with the shipped allowlist template
# (.opencode/skills/target-conventions/assets/clang-tidy.template.yaml) as the config: clean code is
# GREEN; a clang-analyzer or bugprone finding, in a unit or in a product header it includes, is RED;
# code a literal translation keeps (integer division in a floating context) is not a finding; a
# config enabling a rewriting check is RED; a config enabling nothing, a unit that does not compile,
# a missing config or a missing clang-tidy is UNRELIABLE. Needs clang-tidy: it fails, never skips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/build-checks/check-tidy.py"
TEMPLATE="$ROOT/.opencode/skills/target-conventions/assets/clang-tidy.template.yaml"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/    /'; failures=$((failures + 1)); }
command -v clang-tidy >/dev/null || { not_ok "clang-tidy is installed"; exit 1; }
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

# product NAME A.C [FLAGS]: a product with a.c, a clean b.c and include/k.h, and its database.
product() {
	local d="$TMP/$1"
	mkdir -p "$d/include"
	printf '%s\n' "$2" >"$d/a.c"
	printf '#include "k.h"\nint twice(int x) { return 2 * x; }\n' >"$d/b.c"
	[ -f "$d/include/k.h" ] || printf 'int twice(int x);\n' >"$d/include/k.h"
	python3 - "$d" "${3:-}" >"$d/compile_commands.json" <<'PY'
import json, shlex, sys
d, extra = sys.argv[1:]
print(json.dumps([{"directory": d, "file": f, "arguments": ["cc", "-std=c17", "-Iinclude"] + shlex.split(extra) + ["-c", f]}
                  for f in ("a.c", "b.c")]))
PY
}

product clean '#include "k.h"
double scale(double x, int n) { return x * twice(n); }'
expect 0 "RESULT: GREEN" "clean code with the template config is GREEN" --compile-commands "$TMP/clean/compile_commands.json" --config "$TEMPLATE"

product divzero 'int ratio(void) { int z = 0; return 1 / z; }'
expect 1 "[clang-analyzer-core.DivideZero]" "a division by zero clang-analyzer proves is RED" --compile-commands "$TMP/divzero/compile_commands.json" --config "$TEMPLATE"

product semicolon 'int pick(int x) { if (x); { return 1; } return 0; }'
expect 1 "[bugprone-suspicious-semicolon]" "a bugprone finding is RED" --compile-commands "$TMP/semicolon/compile_commands.json" --config "$TEMPLATE"

mkdir -p "$TMP/inheader/include"
printf 'int twice(int x);\nstatic inline int pick(int x) { if (x); { return 1; } return 0; }\n' >"$TMP/inheader/include/k.h"
product inheader '#include "k.h"
int use(void) { return pick(1); }'
expect 1 "include/k.h:2:" "a finding in a product header a unit includes is RED, at the header" --compile-commands "$TMP/inheader/compile_commands.json" --config "$TEMPLATE"

product intdiv 'double mean_step(int n) { return 1.0 + n / 2; }'
expect 0 "RESULT: GREEN" "integer division in a floating context (faithful) is not a finding with the template" --compile-commands "$TMP/intdiv/compile_commands.json" --config "$TEMPLATE"
printf 'Checks: "-*,bugprone-integer-division"\n' >"$TMP/intdiv.yaml"
expect 1 "[bugprone-integer-division]" "the same code is RED once bugprone-integer-division is on" --compile-commands "$TMP/intdiv/compile_commands.json" --config "$TMP/intdiv.yaml"

product gccflags '#include "k.h"
int four(void) { return twice(2); }' "-fipa-pta -ftree-loop-vectorize -Wlogical-op"
expect 0 "RESULT: GREEN" "gcc-only flags in the database do not stop clang-tidy" --compile-commands "$TMP/gccflags/compile_commands.json" --config "$TEMPLATE"

# The allowlist itself.
printf 'Checks: "-*,bugprone-*,modernize-use-nullptr"\n' >"$TMP/modernize.yaml"
expect 1 "enables modernize-use-nullptr, a check that rewrites the code" "a config enabling a modernize check is RED" --compile-commands "$TMP/clean/compile_commands.json" --config "$TMP/modernize.yaml"
printf 'Checks: "-*,readability-braces-around-statements,readability-identifier-naming"\n' >"$TMP/readability.yaml"
out="$(python3 "$CHECK" --compile-commands "$TMP/clean/compile_commands.json" --config "$TMP/readability.yaml" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 1 ] && grep -qF "enables readability-braces-around-statements" <<<"$out" && ! grep -qF "enables readability-identifier-naming" <<<"$out"; then
	ok "a rewriting readability check is RED; readability-identifier-naming is allowed"
else
	not_ok "a rewriting readability check is RED; readability-identifier-naming is allowed" "exit $rc: $out"
fi

# Fail closed.
printf 'Checks: "-*"\n' >"$TMP/none.yaml"
expect 2 "enables no check" "a config enabling no check is UNRELIABLE" --compile-commands "$TMP/clean/compile_commands.json" --config "$TMP/none.yaml"
expect 2 "does not exist" "a missing config is UNRELIABLE" --compile-commands "$TMP/clean/compile_commands.json" --config "$TMP/absent.yaml"
product broken 'int f(void) { return 1 }'
expect 2 "cannot compile" "a unit clang-tidy cannot compile is UNRELIABLE" --compile-commands "$TMP/broken/compile_commands.json" --config "$TEMPLATE"
mkdir -p "$TMP/bin"
ln -s "$(command -v python3)" "$TMP/bin/python3"
out="$(PATH="$TMP/bin" "$TMP/bin/python3" "$CHECK" --compile-commands "$TMP/clean/compile_commands.json" --config "$TEMPLATE" 2>&1)" && rc=0 || rc=$?
if [ "$rc" = 2 ] && grep -qF "clang-tidy is not installed" <<<"$out"; then
	ok "a missing clang-tidy is UNRELIABLE"
else
	not_ok "a missing clang-tidy is UNRELIABLE" "exit $rc: $out"
fi

if [ "$failures" -ne 0 ]; then
	echo "# test-build-tidy: $failures failure(s)" >&2
	exit 1
fi
echo "# test-build-tidy: all assertions passed"
