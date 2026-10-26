#!/usr/bin/env bash
# Regression tests for tools/conformance/check-no-silenced-detectors.sh.
#
# Drives a byte copy of the shipped check (and its lib/) inside a throwaway directory, over
# synthetic TARGET files passed explicitly or a synthetic product tree. Every case states the
# verdict and, for a RED, the finding that must be reported. The check reads the C through libclang
# (python3 with clang.cindex, and the clang driver for the preprocessed stream), so every fixture is
# C that compiles; a fixture that does not is a case of its own (UNRELIABLE).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset TARGET_DIR PRODUCT_ROOT _PR_LOAD_CWD

if ! python3 -c 'import clang.cindex as ci; ci.Index.create()' >/dev/null 2>&1; then
	printf 'not ok - python3 clang.cindex with the native libclang is required to run the check\n' >&2
	exit 1
fi

mkdir -p "$TMP/tools/conformance"
cp "$ROOT/tools/conformance/check-no-silenced-detectors.sh" "$TMP/tools/conformance/"
cp -R "$ROOT/tools/conformance/lib" "$TMP/tools/conformance/"
# The checks parse the product through the build checks' compilation-database reader.
mkdir -p "$TMP/tools/build-checks"
cp -R "$ROOT/tools/build-checks/lib" "$TMP/tools/build-checks/"
CHECK="$TMP/tools/conformance/check-no-silenced-detectors.sh"
F="$TMP/fixtures"
mkdir -p "$F"

failures=0
RUN_ENV=()
# expect EXIT LABEL FIXTURE [REPORTED-TEXT] - run the check on one fixture file (an empty FIXTURE
# runs the scan mode instead); the report must also contain REPORTED-TEXT.
expect() {
	local expected="$1" label="$2" fixture="$3" want="${4:-}" output rc
	set +e
	output="$(cd "$TMP" && env ${RUN_ENV[@]+"${RUN_ENV[@]}"} bash "$CHECK" ${fixture:+"$fixture"} 2>&1)"
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

# 1. Pragmas, as written: every spelling and every #if branch, push included.
cat >"$F/seeded.c" <<'EOF'
int g(void) { return 0; }
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wconversion"
int f(const char *p) { (void)p; return 0; }
#pragma GCC diagnostic pop
EOF
expect 1 "an ignore between a push and its pop is RED" "$F/seeded.c" \
	"seeded.c:3: pragma '#pragma GCC diagnostic ignored \"-Wconversion\"'"
expect 1 "the push and pop around it are not reported themselves" "$F/seeded.c" "1 suppression(s) found"
cat >"$F/push_error.c" <<'EOF'
int g(void) { return 0; }
#pragma GCC diagnostic push
#pragma GCC diagnostic error "-Wconversion"
int f(int x) { return x; }
#pragma GCC diagnostic pop
#pragma warning(push)
#pragma warning(pop)
EOF
expect 0 "a push that only makes a warning an error silences nothing" "$F/push_error.c" "0 suppression(s) found"
cat >"$F/other_compilers.c" <<'EOF'
int g(void) { return 0; }
#pragma warning(push, 0)
#pragma diag_suppress 177
#pragma nv_diag_suppress 177
#pragma warning(pop)
EOF
expect 1 "warning(push, 0) turns every warning off" "$F/other_compilers.c" "other_compilers.c:2: pragma '#pragma warning ( push , 0 )'"
expect 1 "diag_suppress is RED" "$F/other_compilers.c" "other_compilers.c:3: pragma '#pragma diag_suppress 177'"
expect 1 "nv_diag_suppress is RED" "$F/other_compilers.c" "other_compilers.c:4: pragma '#pragma nv_diag_suppress 177'"
cat >"$F/spacing.c" <<'EOF'
int g(void) { return 0; }
#pragma  clang   diagnostic   ignored "-Wconversion"
#if 0
#pragma GCC diagnostic ignored "-Wshadow"
#endif
EOF
expect 1 "extra whitespace does not hide a pragma" "$F/spacing.c" \
	"spacing.c:2: pragma '#pragma clang diagnostic ignored \"-Wconversion\"'"
expect 1 "a pragma in an inactive #if branch is still reported" "$F/spacing.c" \
	"spacing.c:4: pragma '#pragma GCC diagnostic ignored \"-Wshadow\"'"
printf '%s\n' 'int g(void) { return 0; }' '#pragma GCC diagnostic warning "-Wconversion"' >"$F/downgrade.c"
expect 1 "turning an error back into a warning is RED" "$F/downgrade.c" "downgrade.c:2: pragma"
printf '%s\n' '#pragma GCC system_header' 'int g(void);' >"$F/system_header.h"
expect 1 "marking a file a system header is RED" "$F/system_header.h" "system_header.h:1: pragma"
printf '%s\n' 'int g(void) { return 0; }' '#pragma GCC diagnostic pop' >"$F/pop.c"
expect 0 "a pop alone silences nothing" "$F/pop.c" "0 suppression(s) found"

# 2. A pragma a macro produces is reported where the macro is used, and its _Pragma where the
#    macro is defined; the macro may live in a header that is not itself checked.
mkdir -p "$F/macro"
cat >"$F/macro/quiet.h" <<'EOF'
#define QUIET_UNUSED _Pragma("GCC diagnostic ignored \"-Wunused-variable\"")
#define DO_PRAGMA(x) _Pragma(#x)
EOF
cat >"$F/macro/use.c" <<'EOF'
#include "quiet.h"
int f(void)
{
    QUIET_UNUSED
    int x = 0;
    DO_PRAGMA(GCC diagnostic ignored "-Wshadow")
    return 0;
}
EOF
expect 1 "a _Pragma from a macro is reported where the macro is used" "$F/macro/use.c" \
	"use.c:4: pragma '#pragma GCC diagnostic ignored \"-Wunused-variable\"' (produced by a macro)"
expect 1 "a pragma a macro builds with # is reported where it is used" "$F/macro/use.c" \
	"use.c:6: pragma '#pragma GCC diagnostic ignored \"-Wshadow\"' (produced by a macro)"
expect 1 "a _Pragma in a macro definition is reported where it is defined" "$F/macro/quiet.h" \
	"quiet.h:1: pragma '_Pragma(\"GCC diagnostic ignored \\\"-Wunused-variable\\\"\")'"

# 3. Words that only look like a pragma: in a comment, or in a string, they silence nothing.
cat >"$F/words.c" <<'EOF'
/* never write #pragma GCC diagnostic ignored here */
// #pragma clang diagnostic push
const char *advice = "#pragma GCC diagnostic ignored is not allowed";
EOF
expect 0 "pragma words in a comment or a string are not a pragma" "$F/words.c" "0 suppression(s) found"

# 4. Suppression attributes, from the parse (also through a macro).
cat >"$F/attrs.c" <<'EOF'
#define NO_ASAN __attribute__((no_sanitize("address")))
NO_ASAN double first(const double *a) { return a[0]; }
__attribute__((no_sanitize_undefined)) int add(int a, int b) { return a + b; }
int plain(int a) { return a; }
EOF
expect 1 "a no_sanitize attribute from a macro is RED where it is used" "$F/attrs.c" \
	"attrs.c:2: attribute 'no_sanitize(\"address\")'"
expect 1 "a no_sanitize_undefined attribute is RED" "$F/attrs.c" "attrs.c:3: attribute 'no_sanitize_undefined'"

# 4b. Suppression attributes in every preprocessor branch and in macro definitions, as written.
cat >"$F/guarded_attrs.c" <<'EOF'
#if defined(__SANITIZE_ADDRESS__)
#define NO_ASAN __attribute__((no_sanitize_address))
#elif defined(__has_feature)
#if __has_feature(address_sanitizer)
#define NO_ASAN __attribute__((__no_sanitize__("address")))
#endif
#endif
#ifndef NO_ASAN
#define NO_ASAN
#endif
NO_ASAN int g(const int *p) { return p[1]; }
#if defined(__GNUC__) && !defined(__clang__)
__attribute__((no_sanitize_undefined))
#endif
int add(int a, int b) { return a + b; }
EOF
expect 1 "a guarded no_sanitize_address macro is RED where it is defined" "$F/guarded_attrs.c" \
	"guarded_attrs.c:2: attribute 'no_sanitize_address'"
expect 1 "a __no_sanitize__ spelling in an inactive branch is RED" "$F/guarded_attrs.c" \
	"guarded_attrs.c:5: attribute '__no_sanitize__(\"address\")'"
expect 1 "a GCC-only attribute in a branch clang skips is RED" "$F/guarded_attrs.c" \
	"guarded_attrs.c:13: attribute 'no_sanitize_undefined'"

# 5. clang-tidy suppressions, as clang-tidy reads them: in any comment, anywhere in it.
cat >"$F/nolint.c" <<'EOF'
int f(const char *p) { (void)p; return 0; }   /* NOLINT */
int h(void) { return 0; }   // NOLINTNEXTLINE
int k(void) { return 1; }   // kept as in the source NOLINT(readability-magic-numbers)
int m(void) { return 2; }   // NOLINTED is not a directive
EOF
expect 1 "a block-comment NOLINT is RED" "$F/nolint.c" "nolint.c:1: lint suppression 'NOLINT'"
expect 1 "a NOLINTNEXTLINE is RED" "$F/nolint.c" "nolint.c:2: lint suppression 'NOLINTNEXTLINE'"
expect 1 "a word that only begins with NOLINT is not a directive" "$F/nolint.c" "3 suppression(s) found"
printf '%s\n' 'int k(void) { return 1; }   // kept as in the source NOLINT(readability-magic-numbers)' \
	>"$F/nolint_mid.c"
expect 1 "a NOLINT inside a comment's text is RED" "$F/nolint_mid.c" "nolint_mid.c:1: lint suppression 'NOLINT'"

# 6. A clean file, and a file that does not parse.
printf '%s\n' 'int g(void) { return 0; }' 'int f(const char *p) { (void)p; return 0; }' >"$F/good.c"
expect 0 "a file with no suppression is GREEN" "$F/good.c" "0 suppression(s) found"
printf '%s\n' 'int g(void) { return 0 }' >"$F/broken.c"
expect 2 "a file that does not parse is UNRELIABLE" "$F/broken.c" "broken.c' does not parse cleanly"
mkdir -p "$TMP/no-libclang/clang"
printf '%s\n' 'raise ImportError("libclang withheld by the test")' >"$TMP/no-libclang/clang/__init__.py"
RUN_ENV=(PYTHONPATH="$TMP/no-libclang")
expect 2 "without libclang the files are UNRELIABLE" "$F/good.c" "libclang (clang.cindex) is not usable"
RUN_ENV=()

# 7. The product's compile_commands.json: its files are parsed with their entries. Its flags are
#    not judged here: tools/build-checks/check-build-flags.py owns -w and -Wno-*.
P="$TMP/product"
mkdir -p "$P/src" "$P/build"
cat >"$P/src/model.c" <<'EOF'
#ifndef MODEL_BUILD
#error MODEL_BUILD is set by the build
#endif
int model_step(int unused_argument) { return 0; }
EOF
cat >"$P/compile_commands.json" <<EOF
[{"directory": "$P/build", "file": "../src/model.c",
  "arguments": ["cc", "-std=c17", "-DMODEL_BUILD", "-Wall", "-Werror", "-c", "../src/model.c", "-o", "model.o"]}]
EOF
RUN_ENV=(TARGET_DIR="$P")
expect 0 "a file is parsed with its compile_commands.json entry" "" "0 suppression(s) found"
cat >"$P/compile_commands.json" <<EOF
[{"directory": "$P/build", "file": "../src/model.c",
  "arguments": ["cc", "-std=c17", "-DMODEL_BUILD", "-Wall", "-Wno-unused-parameter", "-w", "-c", "../src/model.c"]}]
EOF
expect 0 "-Wno-* and -w in the compile command are the build-flags check's, not this one's" "" \
	"0 suppression(s) found"
rm -f "$P/compile_commands.json"
expect 2 "without compile_commands.json the same file does not parse" "" "MODEL_BUILD is set by the build"
RUN_ENV=()

# 9. Every file of the product tree a unit includes is read, also one the scan does not list.
P="$TMP/inc-product"
mkdir -p "$P/src"
printf '%s\n' '#pragma GCC diagnostic ignored "-Wconversion"' >"$P/src/quiet.inc"
printf '%s\n' '#include "quiet.inc"' 'int g(void) { return 0; }' >"$P/src/c.c"
RUN_ENV=(TARGET_DIR="$P")
expect 1 "a pragma in an included .inc is RED" "" "src/quiet.inc:1: pragma '#pragma GCC diagnostic ignored \"-Wconversion\"'"
RUN_ENV=()

# 10. Text that is not UTF-8 (a Latin-1 comment or string) is read as bytes, never a crash.
printf 'int g(void) { return 0; } /* commentaire \351t\351 */\nconst char *s = "caf\351";\n#pragma GCC diagnostic ignored "-Wshadow"\n' \
	>"$F/latin1.c"
printf 'int g(void) { return 0; } /* \351 */\n' >"$F/latin1_clean.c"
expect 1 "a pragma next to Latin-1 text is reported, not a crash" "$F/latin1.c" "latin1.c:3: pragma"
expect 0 "a Latin-1 comment alone is GREEN" "$F/latin1_clean.c" "0 suppression(s) found"

# 8. The files are parsed in a pool of processes; the verdict and the report are the same as in one.
P="$TMP/pooled"
mkdir -p "$P/src"
for n in 1 2 3 4 5 6; do
	printf '#define QUIET%s _Pragma("GCC diagnostic ignored \\"-Wshadow\\"")\nint f%s(void) { QUIET%s return %s; } // NOLINT\n' \
		"$n" "$n" "$n" "$n" >"$P/src/m$n.c"
done
serial="$(cd "$TMP" && env TARGET_DIR="$P" CHISEL_PARSE_JOBS=1 bash "$CHECK" 2>&1)" || true
pooled="$(cd "$TMP" && env TARGET_DIR="$P" CHISEL_PARSE_JOBS=4 bash "$CHECK" 2>&1)" || true
if [ "$serial" = "$pooled" ] && grep -qF "18 suppression(s) found" <<<"$pooled"; then
	printf 'ok - a pool of parsers reports what one parser does\n'
else
	printf 'not ok - a pool of parsers reports what one parser does\n--- serial\n%s\n--- pooled\n%s\n' "$serial" "$pooled" >&2
	failures=$((failures + 1))
fi

if [ "$failures" -gt 0 ]; then
	printf '%s silenced-detector case(s) failed\n' "$failures" >&2
	exit 1
fi
