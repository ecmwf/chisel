#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

#
# check-product-invisibility.sh - the product tree carries no methodology leakage.
#
# After the two-repo split (references/two-repo-architecture.md), a consumer clones the
# PRODUCT and must see an ordinary codebase: no porting state, no governance files, and
# no chisel vocabulary in the code, comments, or commit subjects - beyond the plain
# SOURCE anchors (/* src: ... */) that the product deliberately keeps, which carry no
# chisel branding and do not match the denylist.
#
# Product tree = PRODUCT_ROOT. It is resolved automatically (lib/product-root.sh): the
# product checkout recorded in port/product.yaml after the two-repo split, else target/
# (a base repo or a not-yet-wired instance). Override with PRODUCT_ROOT / --product-root.
# (This is a product-only scan; do NOT point it at the whole workbench, which is methodology.)
#
# It asserts, over the product tree:
#   1. no port/ directory (porting state belongs to the workbench);
#   2. no porting governance files (AGENTS.md / CLAUDE.md);
#   3. no chisel vocabulary (tools/conformance/chisel-vocabulary.txt) in file contents;
#   4. when PRODUCT_ROOT is a separate git repo, no chisel vocabulary in recent commit
#      subjects (skipped in the single-repo phase, where the product has no own history).
#
# Exit-code contract:
#   0  GREEN       no leakage (or no product tree to check yet)
#   1  RED         methodology leakage found
#   2  UNRELIABLE  detector could not run (no tooling, no vocabulary file)

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/product-root.sh"

PRODUCT_ROOT_ARG="${PRODUCT_ROOT:-}"

usage() {
    cat <<'USAGE'
Usage: check-product-invisibility.sh [--product-root <dir>]

  --product-root <dir>   Product tree to scan. Default: the product checkout (port/product.yaml), else target/ (or PRODUCT_ROOT).

Exit: 0 GREEN, 1 RED (methodology leakage), 2 UNRELIABLE.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --product-root) [[ $# -ge 2 ]] || { echo "check-product-invisibility: --product-root needs a value" >&2; exit 2; }
                        PRODUCT_ROOT_ARG="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "check-product-invisibility: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v grep >/dev/null 2>&1 || { echo "check-product-invisibility: grep not found" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || { echo "check-product-invisibility: git not found"  >&2; exit 2; }
command -v find >/dev/null 2>&1 || { echo "check-product-invisibility: find not found" >&2; exit 2; }

ORIG_PWD="$PWD"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-product-invisibility: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || { echo "check-product-invisibility: cannot enter repo root '${ROOT}'" >&2; exit 2; }

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
    2) echo "check-product-invisibility: $(pr_checkout_problem) - fix port/product.yaml (UNRELIABLE)." >&2; exit 2 ;;
    3) exit 2 ;; # product_root_for_scan already printed the wrong-tree diagnosis (names both trees)
esac

if [[ ! -d "$PRODUCT_ROOT" ]]; then
    if [[ "$_prc" -eq 0 ]]; then
        echo "check-product-invisibility: product is wired (port/product.yaml) but its checkout '${PRODUCT_ROOT}' is not present beside the workbench - clone/checkout it; refusing to skip (UNRELIABLE)." >&2
        exit 2
    fi
    echo "check-product-invisibility: no product tree at '${PRODUCT_ROOT}' - nothing to check (skipping)."
    exit 0
fi
_unread="$(_pr_unreadable_msg "$PRODUCT_ROOT")"
[[ -n "$_unread" ]] && { echo "check-product-invisibility: ${_unread} (UNRELIABLE)." >&2; exit 2; }
# The content scan (2) below trusts "no match" only if grep could open every file. A directory that
# is readable but not searchable lets `find` list its entries without error while every read
# through it fails - and grep's errors are discarded - so confirm every directory is searchable
# first.
SEARCH_ERR=""
if ! pr_confirm_searchable "$PRODUCT_ROOT" SEARCH_ERR; then
    echo "check-product-invisibility: ${SEARCH_ERR} (UNRELIABLE)." >&2
    exit 2
fi

VOCAB_FILE="${VOCAB_FILE:-tools/conformance/chisel-vocabulary.txt}"
if [[ ! -r "$VOCAB_FILE" ]]; then
    echo "check-product-invisibility: vocabulary file '${VOCAB_FILE}' is missing or unreadable." >&2
    exit 2
fi
DENY=()
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    DENY+=("$line")
done < "$VOCAB_FILE"
[[ ${#DENY[@]} -gt 0 ]] || { echo "check-product-invisibility: no vocabulary terms loaded." >&2; exit 2; }

# Preflight every pattern: an invalid ERE makes grep exit 2 (error), which must not be
# mistaken for "no match" - that would silently drop a term and false-green.
for pat in "${DENY[@]}"; do
    printf '' | grep -E -- "$pat" >/dev/null 2>&1
    [[ $? -ge 2 ]] && { echo "check-product-invisibility: invalid regex in vocabulary: '${pat}'" >&2; exit 2; }
done

fails=0

# (1) No methodology STRUCTURE anywhere in the product tree: porting state (port/),
#     skill/command trees (.claude/.opencode), or governance files (AGENTS.md/CLAUDE.md),
#     at any depth, including symlinks (find lists a link by name even when dangling).
#     pr_confirm_find fails closed when the walk does not complete cleanly instead of reporting
#     a partial walk as the whole tree.
STRUCT_HITS=()
if ! pr_confirm_find "$PRODUCT_ROOT" STRUCT_HITS SCAN_ERR -- -name .git -prune -o \
    \( \( -type d -name port \) -o -name .claude -o -name .opencode \
       -o -name AGENTS.md -o -name CLAUDE.md \) -print; then
    echo "check-product-invisibility: ${SCAN_ERR} (UNRELIABLE)." >&2
    exit 2
fi
for path in ${STRUCT_HITS[@]+"${STRUCT_HITS[@]}"}; do
    [[ -n "$path" ]] || continue
    echo "[FAIL] ${path} - methodology structure must not ship with the product."
    fails=$((fails+1))
done

# (2) No chisel vocabulary in file contents, case-insensitively (-i), binary skipped.
for pat in "${DENY[@]}"; do
    hits="$(grep -rInEi --binary-files=without-match --exclude=.git --exclude-dir=.git -- "$pat" "$PRODUCT_ROOT" 2>/dev/null)"
    # grep exits 2 when it could not read a file: that file's contents were never examined.
    [[ $? -le 1 ]] || { echo "check-product-invisibility: grep could not read every file under '${PRODUCT_ROOT}' (UNRELIABLE)." >&2; exit 2; }
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        echo "[FAIL] ${hit}  (matched '${pat}')"
        fails=$((fails+1))
    done <<<"$hits"
done

# (3) No chisel vocabulary in the product's commit subjects (its WHOLE history must read
#     like a normal project), when PRODUCT_ROOT is a separate git repo. Skipped in the
#     single-repo phase, where the product has no own history yet.
PRODUCT_TOPLEVEL="$(git -C "$PRODUCT_ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -n "$PRODUCT_TOPLEVEL" && "$PRODUCT_TOPLEVEL" != "$ROOT" ]]; then
    for pat in "${DENY[@]}"; do
        while IFS= read -r subj; do
            [[ -n "$subj" ]] || continue
            echo "[FAIL] product commit subject leaks methodology vocabulary ('${pat}'): ${subj}"
            fails=$((fails+1))
        done < <(git -C "$PRODUCT_ROOT" log --format='%h %s' 2>/dev/null | grep -iE -- "$pat")
    done
else
    echo "check-product-invisibility: PRODUCT_ROOT is not a separate git repo; skipping commit-subject scan (single-repo phase)."
fi

echo "check-product-invisibility: scanned '${PRODUCT_ROOT}' against ${#DENY[@]} term(s); ${fails} leak(s)."
if [[ "$fails" -gt 0 ]]; then
    echo "RESULT: RED (exit 1) - methodology leakage in the product tree."
    exit 1
fi
echo "RESULT: GREEN (exit 0) - the product tree is chisel-invisible."
exit 0
