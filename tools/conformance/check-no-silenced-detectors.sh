#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

#
# check-no-silenced-detectors.sh - prohibit warning/sanitizer/lint suppression.
#
# AGENTS.md hard rule "Never silence a detector": "No suppression annotations, pragmas, or
# casts to quiet a warning, lint, sanitizer finding, or probe; fix the root cause, or record
# a charter exception. Suppression is allowed only when it is itself the correct semantic
# choice, stated in a comment at the site." This mechanizes that rule for TARGET code.
#
# The detection targets a C TARGET and checks *.c/*.h; instantiate it per TARGET language, the
# way the index-helper and naming-map checks are instantiated per TARGET. On a TARGET with no
# matching files the check skips (vacuous green), so it is harmless to ship enabled.
#
# The C is read as the compiler reads it, never searched as text: every file is parsed with
# libclang (lib/product_tu.py: the product's compile_commands.json when it has one, otherwise
# -std=c17 with -I for every directory of the product tree), and lib/silenced_detectors.py reports:
#   - suppressing pragmas - #pragma GCC/clang diagnostic ignored|ignored_attributes|warning
#     (warning turns an error back into a warning; a push or pop alone silences nothing), GCC/clang
#     system_header, warning(disable|suppress), warning(push, 0), diag_suppress / nv_diag_suppress,
#     a clang attribute pragma applying a suppressing
#     attribute - from each file's raw tokens (every #if branch, and _Pragma("...") also inside a
#     macro definition) and from the preprocessed token stream (clang -E with the file's compile
#     arguments), so a pragma a macro produces is reported where the macro is used;
#   - suppression attributes (no_sanitize and its variants, clang::suppress) in the raw tokens -
#     every #if branch and macro definition, so a guarded `#define NO_ASAN __attribute__((...))`
#     counts - and in the preprocessed tokens, at the line that carries them after macro expansion;
#   - clang-tidy suppressions (NOLINT, NOLINTNEXTLINE, NOLINTBEGIN, NOLINTEND) wherever clang-tidy
#     finds them, in the raw text of a line: a comment, a string literal, an identifier.
# Compiler flags are not judged here: tools/build-checks/check-build-flags.py owns the flag rules
# (-w and -Wno-* forbidden unless its contract allows a -Wno- with a reason), on the flags each
# unit really received. Flags that silence a detector without a -W spelling - a sanitizer ignore
# list (-fsanitize-ignorelist=, -fsanitize-blacklist=) and -isystem naming a product directory
# (its headers' warnings are then dropped) - belong to that check too; it does not judge them yet.
# Every file of the product tree a unit includes is read too, also one the scan does not list (a
# .inc). A pragma's words in a comment or a string are not a pragma. A file that does not parse cleanly,
# or a missing python3/libclang/clang driver, is UNRELIABLE.
# The files are parsed in parallel, one translation unit per process at a time (CHISEL_PARSE_JOBS
# sets the number of processes; default the CPU count).
#
# ALLOWED SUPPRESSIONS. AGENTS.md: "Suppression is allowed only when it is itself the correct
# semantic choice, stated in a comment at the site." Such a suppression is a charter named exception
# (port/plan/00-charter.md, section 4, with an ID such as X-01), registered in the project layer at
# port/conventions/allowed-suppressions.yaml (override the path with ALLOWED_SUPPRESSIONS; template:
# .opencode/skills/target-conventions/assets/allowed-suppressions.template.yaml):
#   suppressions:
#     - {file: <product-relative path>, suppression: <its text as the report quotes it>,
#        count: <how many in that file>, exception: <charter ID>}
# A suppression is GREEN ([ALLOW]) only when an entry has its file and exact text, the number found
# in that file equals `count` (more or fewer is RED: a copy cannot ride on one registration), the
# `exception` ID is in the charter's section 4 table (no charter, or no such ID, is RED), and a
# comment on its line or the line directly above says something besides the directive itself (its
# content is the human's to judge). An entry that matches nothing is RED (stale). A malformed or
# unreadable registry, or an unreadable charter, is UNRELIABLE. With no registry, every suppression
# is RED. The product itself never names the workbench: the comment is plain prose.
#
# Exit-code contract:
#   0  GREEN       no suppression annotation found, or every one allowed as a registered named exception
#   1  RED         a suppression annotation not allowed, or a stale registry entry
#   2  UNRELIABLE  detector could not run (missing files / tooling, a file that does not parse)
#
# A detector is trusted only after it is seen to fail (the seeded-bug rule).
# Seeded-bug record: tools/conformance/seeded-bugs/check-no-silenced-detectors.md

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/product-root.sh"

# Precedence: --target-dir > TARGET_DIR env > the suite-wide PRODUCT_ROOT env (resolved once and
# exported by tools/run-conformance.sh, or set by a worker for its own product worktree) >
# port/product.yaml.
TARGET_DIR="${TARGET_DIR:-${PRODUCT_ROOT:-}}"

usage() {
    cat <<'USAGE'
Usage: check-no-silenced-detectors.sh [--target-dir <dir>] [files...]

  --target-dir <dir>   Root to scan for TARGET *.c/*.h. Default: $TARGET_DIR, else $PRODUCT_ROOT,
                       else the product checkout (port/product.yaml), else target/.
  files...             Explicit files to check (overrides the scan).

Exit: 0 GREEN, 1 RED (suppression annotation found), 2 UNRELIABLE.
USAGE
}

EXPLICIT_FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-dir) TARGET_DIR="${2:?--target-dir needs a value}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        --)           shift; while [[ $# -gt 0 ]]; do EXPLICIT_FILES+=("$1"); shift; done ;;
        -*)           echo "check-no-silenced-detectors: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *)            EXPLICIT_FILES+=("$1"); shift ;;
    esac
done

FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
    FILES=("${EXPLICIT_FILES[@]}")
else
    # product_root_for_scan validates whichever root is selected - an explicit TARGET_DIR /
    # PRODUCT_ROOT or the port/product.yaml default - against this invocation's own sibling product
    # worktree: an explicit root takes precedence but is not exempt from that validation.
    TARGET_DIR="$(product_root_for_scan "$TARGET_DIR")"; _prc=$?
    case "$_prc" in
        2) echo "check-no-silenced-detectors: $(pr_checkout_problem) (UNRELIABLE)." >&2; exit 2 ;;
        3) exit 2 ;; # product_root_for_scan already printed the wrong-tree diagnosis (names both trees)
    esac
    if [[ "$_prc" -eq 0 && ! -d "$TARGET_DIR" ]]; then
        echo "check-no-silenced-detectors: product is wired but its checkout '${TARGET_DIR}' is not present - clone it; refusing to skip (UNRELIABLE)." >&2
        exit 2
    fi
    if [[ "$_prc" -eq 0 ]]; then
        _unread="$(_pr_unreadable_msg "$TARGET_DIR")"
        [[ -n "$_unread" ]] && { echo "check-no-silenced-detectors: ${_unread} (UNRELIABLE)." >&2; exit 2; }
    fi
    # pr_confirm_find fails closed when the walk does not complete cleanly (e.g. an unreadable
    # subdirectory) instead of reporting the partial file list as the whole tree.
    if [[ -d "$TARGET_DIR" ]]; then
        RAW_FILES=()
        if ! pr_confirm_find "$TARGET_DIR" RAW_FILES SCAN_ERR -- -type f \( -name '*.c' -o -name '*.h' \); then
            echo "check-no-silenced-detectors: ${SCAN_ERR} (UNRELIABLE)." >&2
            exit 2
        fi
        # A readable but unsearchable directory lists its entries and fails every read through it.
        if ! pr_confirm_searchable "$TARGET_DIR" SEARCH_ERR; then
            echo "check-no-silenced-detectors: ${SEARCH_ERR} (UNRELIABLE)." >&2
            exit 2
        fi
        # Guard the empty case: printf '%s\n' with no arguments still prints one empty line.
        if [[ ${#RAW_FILES[@]} -gt 0 ]]; then
            while IFS= read -r f; do FILES+=("$f"); done < <(printf '%s\n' "${RAW_FILES[@]}" | sort)
        fi
    fi
    # A TARGET_DIR that does not exist here is the not-wired target/ fallback (exit code 10 above):
    # FILES stays empty and the clean skip below applies.
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "check-no-silenced-detectors: no TARGET *.c/*.h files under '${TARGET_DIR:-<scanned>}' - nothing to check (skipping)."
    exit 0
fi

# What silences a detector is read from the compiler's own view of the code (lib/silenced_detectors.py,
# over the parse of lib/product_tu.py): pragmas from each file's raw tokens and from the
# preprocessed token stream, suppression attributes from the preprocessed tokens, lint suppressions from comment
# and string tokens. See the header for the list.
fails=0
allowed=0
stale=0
total_lines=0
SCAN_FILES=()

for file in "${FILES[@]}"; do
    # A file that is not there, or a directory, was never examined: that is no verdict at all.
    if [[ ! -f "$file" && -d "$file" ]]; then
        echo "check-no-silenced-detectors: '${file}' is a directory, not a file - name it with --target-dir to scan it (UNRELIABLE)." >&2
        exit 2
    fi
    [[ -f "$file" ]] || { echo "check-no-silenced-detectors: '${file}' does not exist - its contents were never examined (UNRELIABLE)." >&2; exit 2; }
    [[ -r "$file" ]] || { echo "check-no-silenced-detectors: cannot read '${file}' - its contents were never examined (UNRELIABLE)." >&2; exit 2; }
    file_lines=$(wc -l < "$file" 2>/dev/null || echo 0)
    total_lines=$((total_lines + file_lines))
    SCAN_FILES+=("$file")
done

if [[ ${#SCAN_FILES[@]} -gt 0 ]]; then
    command -v python3 >/dev/null 2>&1 || { echo "check-no-silenced-detectors: python3 not found - required (with libclang) to read the TARGET C (UNRELIABLE)." >&2; exit 2; }
    SCAN_ARGS=()
    # The product root gives the parse its compile_commands.json and include directories; explicit
    # files are read from their own directories unless a root is named.
    [[ -n "${TARGET_DIR:-}" && -d "$TARGET_DIR" ]] && SCAN_ARGS+=(--root "$TARGET_DIR")
    # The allowed suppressions and the named exceptions they cite are workbench state.
    WB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    REGISTRY="${ALLOWED_SUPPRESSIONS:-$WB_ROOT/port/conventions/allowed-suppressions.yaml}"
    if [[ -n "${ALLOWED_SUPPRESSIONS:-}" || -e "$REGISTRY" || -L "$REGISTRY" ]]; then
        [[ -f "$REGISTRY" && -r "$REGISTRY" ]] || { echo "check-no-silenced-detectors: the suppression registry '${REGISTRY}' is missing or unreadable (UNRELIABLE)." >&2; exit 2; }
        SCAN_ARGS+=(--registry "$REGISTRY")
    fi
    SCAN_ARGS+=(--charter "$WB_ROOT/port/plan/00-charter.md")
    SCAN_ERR="$(mktemp)" || { echo "check-no-silenced-detectors: mktemp failed - cannot read the TARGET C (UNRELIABLE)." >&2; exit 2; }
    FINDINGS="$(python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/silenced_detectors.py" \
        ${SCAN_ARGS[@]+"${SCAN_ARGS[@]}"} -- "${SCAN_FILES[@]}" 2>"$SCAN_ERR")"
    _src=$?
    if [[ "$_src" -ne 0 ]]; then
        echo "check-no-silenced-detectors: could not read the TARGET C, so its contents were never examined (UNRELIABLE):" >&2
        sed 's/^/  /' "$SCAN_ERR" >&2
        rm -f "$SCAN_ERR"
        exit 2
    fi
    rm -f "$SCAN_ERR"
    while IFS=$'\t' read -r tag where desc; do
        case "$tag" in
            FAIL) echo "[FAIL] ${where}: ${desc}"; fails=$((fails+1)) ;;
            ALLOW) echo "[ALLOW] ${where}: ${desc}"; allowed=$((allowed+1)) ;;
            REGISTRY) echo "[FAIL] ${where}: ${desc}"; stale=$((stale+1)) ;;
        esac
    done <<< "$FINDINGS"
fi

echo "check-no-silenced-detectors: ${total_lines} line(s) scanned in ${#FILES[@]} file(s); ${fails} suppression(s) found; ${allowed} allowed as named exceptions; ${stale} stale registry entr(y/ies)."
if [[ $((fails + stale)) -gt 0 ]]; then
    echo "RESULT: RED (exit 1) - suppression annotation(s) found."
    exit 1
fi
if [[ "$allowed" -gt 0 ]]; then
    echo "RESULT: GREEN (exit 0) - every suppression annotation is an allowed named exception."
else
    echo "RESULT: GREEN (exit 0) - no suppression annotations found."
fi
exit 0
