#!/usr/bin/env bash
#
# check-product-invisibility.sh - the product tree carries no methodology leakage.
#
# After the two-repo split (references/two-repo-architecture.md), a consumer clones the
# PRODUCT and must see an ordinary codebase: no porting state, no governance files, and
# no chisel vocabulary in the code, comments, or commit subjects - beyond the plain
# SOURCE anchors (/* src: ... */) that the KEEP-anchors decision (C2) deliberately
# retains, which carry no chisel branding and do not match the denylist.
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

if [[ -n "$PRODUCT_ROOT_ARG" ]]; then
    case "$PRODUCT_ROOT_ARG" in
        /*) PRODUCT_ROOT="$PRODUCT_ROOT_ARG" ;;
        *)  PRODUCT_ROOT="$ORIG_PWD/$PRODUCT_ROOT_ARG" ;;
    esac
    _prc=0
else
    PRODUCT_ROOT="$(default_product_root)"; _prc=$?
    [[ "$_prc" -eq 2 ]] && { echo "check-product-invisibility: port/product.yaml present but its checkout is unset/placeholder - set it (UNRELIABLE)." >&2; exit 2; }
fi

if [[ ! -d "$PRODUCT_ROOT" ]]; then
    if [[ "$_prc" -eq 0 ]]; then
        echo "check-product-invisibility: product is wired (port/product.yaml) but its checkout '${PRODUCT_ROOT}' is not present beside the workbench - clone/checkout it; refusing to skip (UNRELIABLE)." >&2
        exit 2
    fi
    echo "check-product-invisibility: no product tree at '${PRODUCT_ROOT}' - nothing to check (skipping)."
    exit 0
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
while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    echo "[FAIL] ${path} - methodology structure must not ship with the product."
    fails=$((fails+1))
done < <(find "$PRODUCT_ROOT" -name .git -prune -o \
    \( \( -type d -name port \) -o -name .claude -o -name .opencode \
       -o -name AGENTS.md -o -name CLAUDE.md \) -print 2>/dev/null)

# (2) No chisel vocabulary in file contents, case-insensitively (-i), binary skipped.
for pat in "${DENY[@]}"; do
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        echo "[FAIL] ${hit}  (matched '${pat}')"
        fails=$((fails+1))
    done < <(grep -rInEi --binary-files=without-match --exclude=.git --exclude-dir=.git -- "$pat" "$PRODUCT_ROOT" 2>/dev/null)
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
