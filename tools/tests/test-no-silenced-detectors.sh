#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

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
# The suppression registry is read with the coordination tools' strict YAML loader.
mkdir -p "$TMP/tools/coordination"
cp "$ROOT/tools/coordination/_chisel_lib.py" "$TMP/tools/coordination/"
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
expect 1 "a NOLINT inside a comment's text is RED" "$F/nolint_mid.c" \
	"nolint_mid.c:1: lint suppression 'NOLINT(readability-magic-numbers)'"
printf '%s\n' 'const char *s = "keep NOLINT here";' >"$F/nolint_string.c"
expect 1 "a NOLINT in a string literal is RED (clang-tidy reads the raw text)" "$F/nolint_string.c" \
	"nolint_string.c:1: lint suppression 'NOLINT' in literal"
printf '%s\n' '#define NOLINT_MARK' 'int g(void) { return 0; } NOLINT_MARK' >"$F/nolint_ident.c"
expect 1 "a NOLINT in an identifier is RED" "$F/nolint_ident.c" "nolint_ident.c:2: lint suppression 'NOLINT' in identifier 'NOLINT_MARK'"

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

# 6b. A file that is not there, or a directory, was never examined: UNRELIABLE, not RED.
expect 2 "a missing explicit file is UNRELIABLE" "$F/no_such_file.c" "does not exist"
expect 2 "a directory given as a file is UNRELIABLE" "$F" "is a directory, not a file"

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

# 11. Allowed suppressions: a suppression is GREEN only as a charter named exception, registered in
#     port/conventions/allowed-suppressions.yaml with its file, exact text and count, and explained in
#     a comment at the site. The registry and the charter are read from the workbench the check
#     runs in ($TMP here).
P="$TMP/allowed"
mkdir -p "$P/src" "$TMP/port/plan" "$TMP/port/conventions"
REG="$TMP/port/conventions/allowed-suppressions.yaml"
CHARTER="$TMP/port/plan/00-charter.md"
cat >"$CHARTER" <<'EOF'
# Charter
## 4. Named exceptions to literal translation (human-authorized only)
| ID | Exception | Rationale | Authorized by | Date |
|---|---|---|---|---|
| X-01 | Exact float comparison kept | The SOURCE compares exactly | the domain expert | 2026-10-26 |
| (e.g., X-02) | (example row) | | | |

## 5. Permitted mechanical transformations
| ID | Transformation |
|---|---|
| X-07 | not a named exception |
EOF
cat >"$P/src/a.c" <<'EOF'
int g(void) { return 0; }
/* The SOURCE compares these values exactly; the comparison is the specification. */
#pragma GCC diagnostic ignored "-Wfloat-equal"
int f(double x) { return x == 1.0; }
EOF
SUPP='#pragma GCC diagnostic ignored "-Wfloat-equal"'
registry() { # registry FILE SUPPRESSION COUNT EXCEPTION
	printf 'suppressions:\n  - file: %s\n    suppression: %s\n    count: %s\n    exception: %s\n' \
		"$1" "'$2'" "$3" "$4" >"$REG"
}
RUN_ENV=(TARGET_DIR="$P")
cp "$ROOT/.opencode/skills/target-conventions/assets/allowed-suppressions.template.yaml" "$REG"
expect 1 "the registry template is an empty registry: the suppression stays RED" "" \
	"src/a.c:3: pragma '$SUPP' - not registered in '$REG'"
registry src/other.c "$SUPP" 1 X-01
expect 1 "a suppression the registry does not list is RED" "" \
	"src/a.c:3: pragma '$SUPP' - not registered in '$REG'"
registry src/a.c "$SUPP" 1 X-01
expect 0 "a registered, counted, commented named exception is GREEN" "" \
	"[ALLOW] $P/src/a.c:3: pragma '$SUPP' (named exception X-01)"
expect 0 "the summary counts it as allowed" "" "0 suppression(s) found; 1 allowed as named exceptions"
registry src/a.c "$SUPP" 2 X-01
expect 1 "fewer suppressions than registered is RED" "" "registered for 2 in this file, found 1"
registry src/a.c "$SUPP" 1 X-01
printf '%s\n' '/* The same exact comparison, a second time. */' "$SUPP" >>"$P/src/a.c"
expect 1 "a copy beyond the registered count is RED" "" "registered for 1 in this file, found 2"
registry src/a.c "$SUPP" 2 X-01
expect 0 "the count covers both when it says two" "" "2 allowed as named exceptions"
head -n 4 "$P/src/a.c" >"$P/src/a.tmp" && mv "$P/src/a.tmp" "$P/src/a.c"
registry src/a.c "$SUPP" 1 X-09
expect 1 "an exception ID the charter's section 4 does not hold is RED" "" \
	"its exception X-09 is not in the charter's section 4 table"
registry src/a.c "$SUPP" 1 X-02
expect 1 "an example row of the charter is not an ID" "" "its exception X-02 is not in the charter's section 4 table"
registry src/a.c "$SUPP" 1 X-07
expect 1 "an ID from another section of the charter is not a named exception" "" \
	"its exception X-07 is not in the charter's section 4 table"
registry src/a.c "$SUPP" 1 X-01
mv "$CHARTER" "$CHARTER.off"
expect 1 "without a charter no exception exists: RED" "" "its exception X-01: there is no charter"
mv "$CHARTER.off" "$CHARTER"
if [ "$(id -u)" -ne 0 ]; then
	chmod 000 "$CHARTER"
	expect 2 "an unreadable charter is UNRELIABLE" "" "cannot read the charter"
	chmod 644 "$CHARTER"
fi
printf '%s\n' 'int g(void) { return 0; }' '' "$SUPP" 'int f(double x) { return x == 1.0; }' >"$P/src/a.c"
expect 1 "a registered suppression with no comment at the site is RED" "" \
	"no comment at the site (on its line or the line above) gives the reason"
printf '%s\n' 'int g(void) { return 0; }' "$SUPP /* the SOURCE compares exactly */" \
	'int f(double x) { return x == 1.0; }' >"$P/src/a.c"
expect 0 "a comment on the suppression's own line gives the reason" "" "1 allowed as named exceptions"
cat >"$P/src/a.c" <<'EOF'
int g(int c, int x) { if (c) return x; else return x; } // NOLINT(bugprone-branch-clone)
int h(int c, int x) { if (c) return x; else return x; } // NOLINT(bugprone-branch-clone): both branches are the SOURCE's
EOF
printf 'suppressions:\n  - file: src/a.c\n    suppression: NOLINT(bugprone-branch-clone)\n    count: 2\n    exception: X-01\n' >"$REG"
expect 1 "a NOLINT comment that is only the directive gives no reason" "" \
	"src/a.c:1: lint suppression 'NOLINT(bugprone-branch-clone)'"
expect 1 "a NOLINT comment that says why gives the reason" "" \
	"[ALLOW] $P/src/a.c:2: lint suppression 'NOLINT(bugprone-branch-clone)'"
printf '%s\n' 'int g(void) { return 0; }' >"$P/src/a.c"
registry src/a.c "$SUPP" 1 X-01
expect 1 "a registry entry that matches nothing is RED (stale)" "" \
	"[FAIL] $REG: the entry for '$SUPP' in src/a.c (X-01) matches no suppression - remove it (stale)"
printf 'suppressions:\n  - file: src/a.c\n    file: src/b.c\n    suppression: x\n    count: 1\n    exception: X-01\n' >"$REG"
expect 2 "a registry with a repeated key is UNRELIABLE" "" "is not valid YAML"
printf 'suppressions:\n  - file: src/a.c\n    suppression: x\n    count: one\n    exception: X-01\n' >"$REG"
expect 2 "a count that is not a whole number is UNRELIABLE" "" "\`count\` must be a whole number"
printf 'suppressions:\n  - file: src/a.c\n    suppression: x\n    count: 1\n' >"$REG"
expect 2 "an entry without its exception is UNRELIABLE" "" "must be a mapping of exactly file, suppression, count, exception"
printf 'suppressions: src/a.c\n' >"$REG"
expect 2 "a registry that is not a list is UNRELIABLE" "" "holding a list"
printf 'suppressions:\n  - file: ../elsewhere.c\n    suppression: x\n    count: 1\n    exception: X-01\n' >"$REG"
expect 2 "an entry outside the product is UNRELIABLE" "" "must be a path inside the product"
rm -f "$REG"
RUN_ENV=(TARGET_DIR="$P" ALLOWED_SUPPRESSIONS="$TMP/absent.yaml")
expect 2 "a named registry that is missing is UNRELIABLE" "" "is missing or unreadable"
RUN_ENV=()
rm -rf "$TMP/port"

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
