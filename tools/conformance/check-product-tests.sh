#!/usr/bin/env bash
#
# check-product-tests.sh - the port's tests are PRODUCT-OWNED: they ship inside the product
# tree and the product builds them itself, so a consumer who clones only the product can run
# `make test`. The failure this guards is the v1 orphan pattern: tests authored into the
# WORKBENCH (e.g. a top-level tests/unit/) with the product build reaching OUT to find them
# (`TESTDIR := ../tests/unit`). That cross-boundary reference does not even resolve once the
# product is its own repo (references/two-repo-architecture.md), so the regression net never
# ships with the deliverable. Tests live under PRODUCT_ROOT/tests/ (drivers + fixtures); the
# fixture GENERATOR (it instruments the SOURCE) stays in the workbench under tools/diff/.
#
# Two arms:
#   1. PRODUCT BUILD does not escape the product for test sources. Each product build file
#      (Makefile / *.mk / CMakeLists.txt / *.cmake) is scanned for a parent-directory ("..")
#      path token that names a test; the token is resolved against the build file's directory
#      and must stay INSIDE PRODUCT_ROOT. An escape (it resolves outside the product) is the
#      `../tests` smell. Runs only when a product tree is present.
#   2. WORKBENCH has no orphaned tests/. A top-level tests/ in the workbench holding test
#      sources is the v1 orphan location - those belong in the product. Always runs.
#
# Product tree = PRODUCT_ROOT, resolved automatically (lib/product-root.sh): the product
# checkout in port/product.yaml after the split, else target/. Override with PRODUCT_ROOT /
# --product-root (used by the seeded-bug demonstration to point at a fixture tree).
#
# Exit-code contract:
#   0  GREEN       tests are product-owned (and no workbench orphans)
#   1  RED         an escaping product build reference, or a workbench tests/ orphan
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
if [[ -n "$PRODUCT_ROOT_ARG" ]]; then
    case "$PRODUCT_ROOT_ARG" in
        /*) PRODUCT_ROOT="$PRODUCT_ROOT_ARG" ;;
        *)  PRODUCT_ROOT="$ORIG_PWD/$PRODUCT_ROOT_ARG" ;;
    esac
    _prc=0
else
    PRODUCT_ROOT="$(default_product_root)"; _prc=$?
    [[ "$_prc" -eq 2 ]] && { echo "check-product-tests: port/product.yaml present but its checkout is unset/placeholder - set it (UNRELIABLE)." >&2; exit 2; }
fi

PRODUCT_PRESENT=0
if [[ -d "$PRODUCT_ROOT" ]]; then
    PRODUCT_ROOT="$(realpath -m -- "$PRODUCT_ROOT")"
    PRODUCT_PRESENT=1
elif [[ "$_prc" -eq 0 ]]; then
    echo "check-product-tests: product is wired (port/product.yaml) but its checkout '${PRODUCT_ROOT}' is not present beside the workbench - clone/checkout it; refusing to skip (UNRELIABLE)." >&2
    exit 2
fi

fails=0

# (1) The product build must not reach OUTSIDE the product for its test sources. Scan product
#     build files for a ".."-escaping path token that names a test, resolve it against the
#     build file's directory, and require it to stay under PRODUCT_ROOT.
if [[ "$PRODUCT_PRESENT" -eq 1 ]]; then
    while IFS= read -r bf; do
        [[ -n "$bf" ]] || continue
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
    done < <(find "$PRODUCT_ROOT" -name .git -prune -o -type f \
        \( -name Makefile -o -name GNUmakefile -o -name '*.mk' -o -name CMakeLists.txt -o -name '*.cmake' \) -print 2>/dev/null)
else
    echo "check-product-tests: no product tree at '${PRODUCT_ROOT}' - skipping the build-reference arm (no product wired yet)."
fi

# (2) The workbench must not hold an orphaned top-level tests/ of product test sources (the v1
#     location). Tests are product-owned; a workbench tests/ means they never ship. Always runs.
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
