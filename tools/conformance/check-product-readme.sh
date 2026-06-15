#!/usr/bin/env bash
#
# check-product-readme.sh - keep the product README about the product.
#
# The product README describes the ported codebase to a consumer: what it does, a
# link to the original project, and how to build and run it. It must NOT describe the
# porting process. This check fails if methodology vocabulary leaks into it (charter,
# TRACE, reference runs, gates, anchors, sprints, ...), so a consumer reading the
# product never sees the scaffolding that produced it.
#
# (WS-A scope: the README only. The same denylist later extends to the whole product
# tree once the product is its own repo.)
#
# Exit-code contract:
#   0  GREEN       no methodology vocabulary in the product README (or none to check)
#   1  RED         at least one leaked term found
#   2  UNRELIABLE  detector could not run (missing tooling)

set -uo pipefail

REQUESTED=""
[[ -n "${PRODUCT_README:-}" ]] && REQUESTED="$PRODUCT_README"

usage() {
    cat <<'USAGE'
Usage: check-product-readme.sh [--readme <path>]

  --readme <path>   Product README to scan. Default: target/README.md at the repo
                    root (or the PRODUCT_README env var).

Exit: 0 GREEN, 1 RED (methodology term leaked), 2 UNRELIABLE.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --readme)
            [[ $# -ge 2 ]] || { echo "check-product-readme: --readme needs a value" >&2; exit 2; }
            REQUESTED="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "check-product-readme: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v grep >/dev/null 2>&1 || { echo "check-product-readme: grep not found" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || { echo "check-product-readme: git not found"  >&2; exit 2; }

ORIG_PWD="$PWD"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-product-readme: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || { echo "check-product-readme: cannot enter repo root '${ROOT}'" >&2; exit 2; }

if [[ -n "$REQUESTED" ]]; then
    case "$REQUESTED" in
        /*) PRODUCT_README="$REQUESTED" ;;
        *)  PRODUCT_README="$ORIG_PWD/$REQUESTED" ;;
    esac
    if [[ ! -r "$PRODUCT_README" ]]; then
        echo "check-product-readme: requested README '${PRODUCT_README}' is missing or unreadable." >&2
        exit 2
    fi
else
    PRODUCT_README="target/README.md"
    if [[ ! -f "$PRODUCT_README" ]]; then
        echo "check-product-readme: no product README at '${PRODUCT_README}' - nothing to check (skipping)."
        exit 0
    fi
fi

# Methodology vocabulary (one ERE per line) is shared with check-product-invisibility.sh
# in a single source of truth, so the two product-facing checks cannot drift.
VOCAB_FILE="${VOCAB_FILE:-tools/conformance/chisel-vocabulary.txt}"
if [[ ! -r "$VOCAB_FILE" ]]; then
    echo "check-product-readme: vocabulary file '${VOCAB_FILE}' is missing or unreadable." >&2
    exit 2
fi
DENY=()
while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    DENY+=("$line")
done < "$VOCAB_FILE"
if [[ ${#DENY[@]} -eq 0 ]]; then
    echo "check-product-readme: no vocabulary terms loaded from '${VOCAB_FILE}'." >&2
    exit 2
fi
for pat in "${DENY[@]}"; do
    printf '' | grep -E -- "$pat" >/dev/null 2>&1
    [[ $? -ge 2 ]] && { echo "check-product-readme: invalid regex in vocabulary: '${pat}'" >&2; exit 2; }
done

fails=0
for pat in "${DENY[@]}"; do
    while IFS= read -r hit; do
        [[ -n "$hit" ]] || continue
        echo "[FAIL] ${PRODUCT_README}:${hit}  (matched '${pat}')"
        fails=$((fails+1))
    done < <(grep -nEi -- "$pat" "$PRODUCT_README" 2>/dev/null)
done

echo "check-product-readme: scanned '${PRODUCT_README}' against ${#DENY[@]} term(s); ${fails} leak(s)."
if [[ "$fails" -gt 0 ]]; then
    echo "RESULT: RED (exit 1) - porting-process vocabulary leaked into the product README."
    exit 1
fi
echo "RESULT: GREEN (exit 0) - the product README is about the product."
exit 0
