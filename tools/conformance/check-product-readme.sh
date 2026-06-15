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

PRODUCT_README="${PRODUCT_README:-target/README.md}"

usage() {
    cat <<'USAGE'
Usage: check-product-readme.sh [--readme <path>]

  --readme <path>   Product README to scan. Default: target/README.md
                    (or the PRODUCT_README env var).

Exit: 0 GREEN, 1 RED (methodology term leaked), 2 UNRELIABLE.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --readme) PRODUCT_README="${2:?--readme needs a value}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "check-product-readme: unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v grep >/dev/null 2>&1 || { echo "check-product-readme: grep not found" >&2; exit 2; }

if [[ ! -f "$PRODUCT_README" ]]; then
    echo "check-product-readme: no product README at '${PRODUCT_README}' - nothing to check (skipping)."
    exit 0
fi

# Methodology vocabulary that must never appear in a product README. Each entry is an
# extended-regex, matched case-insensitively. Phrases are preferred over bare words to
# avoid flagging ordinary product prose (e.g. "port to a new platform" is fine).
DENY=(
    'chisel'
    'port charter'
    '00-charter'
    'port/plan'
    'TRACE\.yaml'
    'TRACE matrix'
    '/port-[a-z]'
    'reference run'
    'seeded[ -]bug'
    'anchor verifier'
    'provenance anchor'
    'validation ladder'
    'CONVENTIONS\.md'
    'Prime Directive'
    'live subset'
    'KNOWN-DIVERGENCES'
    'LESSONS\.md'
    'differential tooling'
    'fidelity-preserving'
    'fidelity gate'
    'porting sprint'
    'handoff'
    'docs/evidence'
    'gate evidence'
    'workbench'
)

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
