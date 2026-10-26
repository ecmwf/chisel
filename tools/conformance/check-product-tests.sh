#!/usr/bin/env bash
#
# check-product-tests.sh - the port's tests are PRODUCT-OWNED: they ship inside the product
# tree and the product builds them itself, so a consumer who clones only the product can run
# `make test`. The failure this guards is the orphan pattern: tests authored into the
# WORKBENCH (e.g. a top-level tests/unit/) with the product build reaching OUT to find them
# (`TESTDIR := ../tests/unit`). That cross-boundary reference does not even resolve once the
# product is its own repo (references/two-repo-architecture.md), so the regression net never
# ships with the deliverable. Tests live under PRODUCT_ROOT/tests/ (drivers + fixtures); the
# fixture GENERATOR (it instruments the SOURCE) stays in the workbench under tools/diff/.
#
# Three arms:
#   1. PRODUCT BUILD does not escape the product for test sources. Each product build file
#      (Makefile / *.mk / CMakeLists.txt / *.cmake) is scanned for a parent-directory ("..")
#      path token that names a test; the token is resolved against the build file's directory
#      and must stay INSIDE PRODUCT_ROOT. An escape (it resolves outside the product) is the
#      `../tests` smell. Runs only when a product tree is present.
#   2. WORKBENCH has no orphaned tests/. A top-level tests/ in the workbench holding test
#      sources is the orphan location - those belong in the product. Always runs.
#   3. PRODUCT test sources are WIRED INTO THE BUILD. A `test*`-named source shipped under the
#      product's tests/ that no build file references is a shipped-but-unbuilt test - a fresh
#      clone's ctest never runs it. Skipped when the build GLOBs/wildcards tests (the glob picks
#      them up). This does NOT catch a test that was never composed at all (no source of truth for
#      "which tests should exist"); that is the integration review's + the clone-build-run check's job.
#
# Product tree = PRODUCT_ROOT, resolved automatically (lib/product-root.sh): the product
# checkout in port/product.yaml after the split, else target/. Override with PRODUCT_ROOT /
# --product-root (used by the seeded-bug demonstration to point at a fixture tree).
#
# Exit-code contract:
#   0  GREEN       tests are product-owned, no workbench orphans, every shipped test is wired into the build
#   1  RED         an escaping product build reference, a workbench tests/ orphan, or a shipped-but-unwired test
#   2  UNRELIABLE  detector could not run (no tooling), or product wired but checkout missing

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/product-root.sh"

PRODUCT_ROOT_ARG="${PRODUCT_ROOT:-}"

usage() {
    cat <<'USAGE'
Usage: check-product-tests.sh [--product-root <dir>]

  --product-root <dir>   Product tree to scan. Default: the product checkout (port/product.yaml), else target/ (or PRODUCT_ROOT).

Exit: 0 GREEN, 1 RED (escaping build ref / workbench orphan), 2 UNRELIABLE.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --product-root) [[ $# -ge 2 ]] || { echo "check-product-tests: --product-root needs a value" >&2; exit 2; }
                        PRODUCT_ROOT_ARG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "check-product-tests: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v grep     >/dev/null 2>&1 || { echo "check-product-tests: grep not found" >&2; exit 2; }
command -v git      >/dev/null 2>&1 || { echo "check-product-tests: git not found"  >&2; exit 2; }
command -v find     >/dev/null 2>&1 || { echo "check-product-tests: find not found" >&2; exit 2; }
command -v realpath >/dev/null 2>&1 || { echo "check-product-tests: realpath not found" >&2; exit 2; }

ORIG_PWD="$PWD"
# Workbench root, stable across linked worktrees (the orphan arm is a workbench invariant).
ROOT="$(_pr_repo_root)" \
    || { echo "check-product-tests: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || { echo "check-product-tests: cannot enter repo root '${ROOT}'" >&2; exit 2; }

# Resolve the product tree (mirrors check-product-invisibility's fail-closed handling).
EXPLICIT_ROOT=""
if [[ -n "$PRODUCT_ROOT_ARG" ]]; then
    case "$PRODUCT_ROOT_ARG" in
        /*) EXPLICIT_ROOT="$PRODUCT_ROOT_ARG" ;;
        *)  EXPLICIT_ROOT="$ORIG_PWD/$PRODUCT_ROOT_ARG" ;;
    esac
fi
# product_root_for_scan validates whichever root is selected - an explicit PRODUCT_ROOT (flag/env)
# or the port/product.yaml default - against this invocation's own sibling product worktree: an
# explicit root takes precedence but is not exempt from that validation.
PRODUCT_ROOT="$(product_root_for_scan "$EXPLICIT_ROOT")"; _prc=$?
case "$_prc" in
    2) echo "check-product-tests: port/product.yaml present but its checkout is unset/placeholder - set it (UNRELIABLE)." >&2; exit 2 ;;
    3) exit 2 ;; # product_root_for_scan already printed the wrong-tree diagnosis (names both trees)
esac

PRODUCT_PRESENT=0
if [[ -d "$PRODUCT_ROOT" ]]; then
    _unread="$(_pr_unreadable_msg "$PRODUCT_ROOT")"
    [[ -n "$_unread" ]] && { echo "check-product-tests: ${_unread} (UNRELIABLE)." >&2; exit 2; }
    PRODUCT_ROOT="$(realpath -m -- "$PRODUCT_ROOT")"
    PRODUCT_PRESENT=1
elif [[ "$_prc" -eq 0 ]]; then
    echo "check-product-tests: product is wired (port/product.yaml) but its checkout '${PRODUCT_ROOT}' is not present beside the workbench - clone/checkout it; refusing to skip (UNRELIABLE)." >&2
    exit 2
fi

# Arms (1) and (3) trust "no match" only if every enumerated build file could actually be read. A
# directory that is readable but not searchable lets `find` list its entries without error while
# every read through it fails - and grep's errors are discarded - so confirm every directory is
# searchable first.
if [[ "$PRODUCT_PRESENT" -eq 1 ]]; then
    SEARCH_ERR=""
    if ! pr_confirm_searchable "$PRODUCT_ROOT" SEARCH_ERR; then
        echo "check-product-tests: ${SEARCH_ERR} (UNRELIABLE)." >&2
        exit 2
    fi
fi

fails=0
BUILD_FILES=()

# (1) The product build must not reach OUTSIDE the product for its test sources. Scan product
#     build files for a ".."-escaping path token that names a test, resolve it against the
#     build file's directory, and require it to stay under PRODUCT_ROOT. pr_confirm_find fails
#     closed when the walk does not complete cleanly instead of reporting a partial list of build
#     files as all of them; arm (3) reuses the same list.
if [[ "$PRODUCT_PRESENT" -eq 1 ]]; then
    if ! pr_confirm_find "$PRODUCT_ROOT" BUILD_FILES SCAN_ERR -- -name .git -prune -o -type f \
        \( -name Makefile -o -name GNUmakefile -o -name '*.mk' -o -name CMakeLists.txt -o -name '*.cmake' \) -print; then
        echo "check-product-tests: ${SCAN_ERR} (UNRELIABLE)." >&2
        exit 2
    fi
    for bf in ${BUILD_FILES[@]+"${BUILD_FILES[@]}"}; do
        [[ -n "$bf" ]] || continue
        # Its references are read through a process substitution, where grep's exit status is lost.
        [[ -r "$bf" ]] || { echo "check-product-tests: cannot read build file '${bf}' - its references were never examined (UNRELIABLE)." >&2; exit 2; }
        bfdir="$(dirname "$bf")"
        while IFS= read -r tok; do
            [[ -n "$tok" ]] || continue
            printf '%s' "$tok" | grep -qiE 'test' || continue   # only test-source escapes concern us
            abs="$(realpath -m -- "$bfdir/$tok" 2>/dev/null)" || continue
            case "$abs/" in
                "$PRODUCT_ROOT"/*) : ;;   # stays inside the product - fine
                *) echo "[FAIL] ${bf#"$ROOT"/}: build references test sources outside the product ('${tok}' -> ${abs}). Move them under ${PRODUCT_ROOT#"$ROOT"/}/tests/ and reference them relatively."
                   fails=$((fails+1)) ;;
            esac
        done < <(grep -oE '\.\./[^[:space:]:=)(]*' "$bf" 2>/dev/null)
    done
else
    echo "check-product-tests: no product tree at '${PRODUCT_ROOT}' - skipping the build-reference arm (no product wired yet)."
fi

# (3) Every test SOURCE shipped under the product's tests/ must be BUILT - referenced by some product
#     build file - else a fresh clone's `ctest` never runs it (a shipped-but-unwired test, the milder
#     cousin of dropping a test entirely). This does NOT (and cannot statically) verify a test that was
#     never composed at all; that is the integration review's + the clone-build-run check's job. Skipped
#     when the product uses build-time GLOB/wildcard for tests, since the glob enumerates them at
#     configure time and a shipped test cannot then be silently unregistered.
if [[ "$PRODUCT_PRESENT" -eq 1 && -d "$PRODUCT_ROOT/tests" ]]; then
    bfiles=()
    [[ ${#BUILD_FILES[@]} -gt 0 ]] && bfiles=("${BUILD_FILES[@]}")
    if [[ "${#bfiles[@]}" -eq 0 ]]; then
        echo "check-product-tests: product has a tests/ but no build files - skipping the test-registration arm."
    else
      # Comment-stripped build text (computed once bfiles is known non-empty), used for BOTH the glob
      # check and the per-file match - so neither a "# no GLOB here" comment can falsely DISABLE the
      # arm, nor a "# TODO wire test_x" mis-credit an unwired test.
      buildtext="$(sed 's/#.*$//' "${bfiles[@]}" 2>/dev/null)"
      if printf '%s\n' "$buildtext" | grep -qiE 'glob|wildcard'; then
        echo "check-product-tests: product build uses GLOB/wildcard - test sources are enumerated at build time; skipping the per-file test-registration arm."
      else
        # Only `test`-PREFIXED source files (the convention), so e.g. `latest.c` is not a test driver.
        # pr_confirm_find fails closed rather than under-reporting shipped tests from a partial walk.
        TEST_SRCS=()
        if ! pr_confirm_find "$PRODUCT_ROOT/tests" TEST_SRCS SCAN_ERR -- -type f \
            \( -iname 'test*.c' -o -iname 'test*.cc' -o -iname 'test*.cpp' -o -iname 'test*.cxx' \
               -o -iname 'test*.f90' -o -iname 'test*.rs' \); then
            echo "check-product-tests: ${SCAN_ERR} (UNRELIABLE)." >&2
            exit 2
        fi
        for tf in ${TEST_SRCS[@]+"${TEST_SRCS[@]}"}; do
            [[ -n "$tf" ]] || continue
            base="$(basename "$tf")"   # match the SOURCE FILENAME (with ext): a test must be NAMED to be compiled
            if ! printf '%s\n' "$buildtext" | grep -qF -- "$base"; then
                echo "[FAIL] product test source '${tf#"$PRODUCT_ROOT"/}' is referenced by NO product build file - a shipped test that never builds/runs (a fresh clone's ctest skips it). Wire it into the product's test target."
                fails=$((fails+1))
            fi
        done
      fi
    fi
fi

# (2) The workbench must not hold an orphaned top-level tests/ of product test sources (the
#     orphan location). Tests are product-owned; a workbench tests/ means they never ship. Always runs.
if [[ -d "$ROOT/tests" ]]; then
    orphans="$(find "$ROOT/tests" -type f \
        \( -iname '*test*' -o -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' \
           -o -name '*.h' -o -name '*.hpp' -o -name '*.f90' -o -name '*.F90' -o -name '*.rs' \) 2>/dev/null)"
    if [[ -n "$orphans" ]]; then
        n="$(printf '%s\n' "$orphans" | grep -c .)"
        echo "[FAIL] workbench has a top-level tests/ holding ${n} product test source(s) - tests are product-owned (PRODUCT_ROOT/tests/), not workbench orphans:"
        printf '%s\n' "$orphans" | sed -E "s#^${ROOT}/#         #"
        fails=$((fails+1))
    fi
fi

if [[ "$fails" -gt 0 ]]; then
    echo "RESULT: RED (exit 1) - tests are not fully product-owned (${fails} finding(s))."
    exit 1
fi
echo "check-product-tests: GREEN - tests are product-owned (product '${PRODUCT_ROOT#"$ROOT"/}', no workbench orphans)."
exit 0
