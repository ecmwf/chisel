#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

#
# check-product-readme.sh - keep the product README about the product.
#
# The product README describes the ported codebase to a consumer: what it does, a
# link to the original project, and how to build and run it. It must NOT describe the
# porting process. This check fails if methodology vocabulary leaks into it (charter,
# TRACE, reference runs, proofs, anchors, sprints, ...), so a consumer reading the
# product never sees the scaffolding that produced it.
#
# (Scope: the README only. check-product-invisibility.sh applies the same denylist to the
# whole product tree.)
#
# Exit-code contract:
#   0  GREEN       no methodology vocabulary in the product README (or none to check)
#   1  RED         at least one leaked term found
#   2  UNRELIABLE  detector could not run (missing tooling)

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/product-root.sh"

REQUESTED=""
[[ -n "${PRODUCT_README:-}" ]] && REQUESTED="$PRODUCT_README"
# A product-ROOT override (--product-root, or the suite-wide PRODUCT_ROOT env resolved once and
# exported by tools/run-conformance.sh) names the product tree; this check reads its README.md.
# Precedence, finest first: --readme > PRODUCT_README env > --product-root > PRODUCT_ROOT env >
# port/product.yaml.
PRODUCT_ROOT_ARG="${PRODUCT_ROOT:-}"
REQUIRE_FILLED="${REQUIRE_FILLED:-0}"

usage() {
    cat <<'USAGE'
Usage: check-product-readme.sh [--readme <path> | --product-root <dir>] [--require-filled]

  --readme <path>       Product README to scan directly (or the PRODUCT_README env var).
  --product-root <dir>  Product tree whose README.md to scan (or the PRODUCT_ROOT env var).
                        Default when neither is given: <product checkout>/README.md
                        (port/product.yaml), else target/README.md, at the repo root.
                        Precedence: --readme > PRODUCT_README > --product-root > PRODUCT_ROOT.
  --require-filled      ALSO require the README to be actually WRITTEN, not the seeded placeholder:
                        no unfilled `<...>` template placeholders, and the consumer sections `## Build`
                        and `## Run` present. A SIGN-OFF check (the README is legitimately a stub during
                        bring-up); run it at the product-milestone / handover digest, not continuously.

Exit: 0 GREEN, 1 RED (methodology term leaked, or - with --require-filled - an unwritten README), 2 UNRELIABLE.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --readme)
            [[ $# -ge 2 ]] || { echo "check-product-readme: --readme needs a value" >&2; exit 2; }
            REQUESTED="$2"; shift 2 ;;
        --product-root)
            [[ $# -ge 2 ]] || { echo "check-product-readme: --product-root needs a value" >&2; exit 2; }
            PRODUCT_ROOT_ARG="$2"; shift 2 ;;
        --require-filled) REQUIRE_FILLED=1; shift ;;
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
elif [[ -n "$PRODUCT_ROOT_ARG" ]]; then
    case "$PRODUCT_ROOT_ARG" in
        /*) _pr_explicit="$PRODUCT_ROOT_ARG" ;;
        *)  _pr_explicit="$ORIG_PWD/$PRODUCT_ROOT_ARG" ;;
    esac
    # product_root_for_scan validates the explicit root against this invocation's own sibling
    # product worktree: an explicit root takes precedence but is not exempt from that validation.
    _pr="$(product_root_for_scan "$_pr_explicit")"; _prc=$?
    [[ "$_prc" -eq 3 ]] && exit 2 # product_root_for_scan already printed the wrong-tree diagnosis
    _unread="$(_pr_unreadable_msg "$_pr")"
    [[ -n "$_unread" ]] && { echo "check-product-readme: ${_unread} (UNRELIABLE)." >&2; exit 2; }
    PRODUCT_README="$_pr/README.md"
    # An explicitly named product must be scanned: a missing README there is UNRELIABLE, never a
    # silent fall-back to the configured product or a skip.
    if [[ ! -r "$PRODUCT_README" ]]; then
        echo "check-product-readme: explicit product root '${_pr}' has no readable README.md - refusing to skip or fall back to the configured product (UNRELIABLE)." >&2
        exit 2
    fi
else
    _pr="$(product_root_for_scan)"; _prc=$?
    case "$_prc" in
        2) echo "check-product-readme: $(pr_checkout_problem) - fix port/product.yaml (UNRELIABLE)." >&2; exit 2 ;;
        3) exit 2 ;; # product_root_for_scan already printed the wrong-tree diagnosis (names both trees)
    esac
    _unread="$(_pr_unreadable_msg "$_pr")"
    [[ -n "$_unread" ]] && { echo "check-product-readme: ${_unread} (UNRELIABLE)." >&2; exit 2; }
    PRODUCT_README="$_pr/README.md"
    if [[ ! -f "$PRODUCT_README" ]]; then
        if [[ "$_prc" -eq 0 ]]; then
            echo "check-product-readme: product is wired but its checkout '${_pr}' / README is not present beside the workbench - clone it; refusing to skip (UNRELIABLE)." >&2
            exit 2
        fi
        echo "check-product-readme: no product README at '${PRODUCT_README}' - nothing to check (skipping)."
        exit 0
    fi
    if [[ ! -r "$PRODUCT_README" ]]; then
        echo "check-product-readme: product README '${PRODUCT_README}' exists but is not readable - a scan of it cannot be trusted (UNRELIABLE)." >&2
        exit 2
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

# --require-filled: the README must be WRITTEN for a consumer, not the seeded placeholder. Detect
# UNFILLED placeholders by their LITERAL template tokens (the exact `<...>` strings from
# PRODUCT-README.template.md), so a written README is never false-flagged on legitimate angle brackets -
# HTML (`<img src="...">`), generics (`Map<String, Int>`), shell redirection (`prog < in > out`), or
# `#include <stdio.h>` are not template tokens and so never match. Plus the consumer sections must exist.
unwritten=0
if [[ "$REQUIRE_FILLED" -eq 1 ]]; then
    TEMPLATE="${PRODUCT_README_TEMPLATE:-.opencode/skill/code-port/assets/PRODUCT-README.template.md}"
    if [[ -r "$TEMPLATE" ]]; then
        # The template's own placeholder tokens; any still present in the README is an unfilled blank.
        while IFS= read -r ph; do
            [[ -n "$ph" ]] || continue
            while IFS= read -r hit; do
                [[ -n "$hit" ]] || continue
                echo "[FAIL] ${PRODUCT_README}:${hit}  (unfilled template placeholder '${ph}' - write the real content)"
                unwritten=$((unwritten+1))
            done < <(grep -nF -- "$ph" "$PRODUCT_README" 2>/dev/null)
        done < <(grep -oE '<[^>]+>' "$TEMPLATE" 2>/dev/null | sort -u)
    else
        echo "check-product-readme: --require-filled: template '${TEMPLATE}' not found - checking sections only (placeholders unchecked)."
    fi
    for sec in '^##[[:space:]]+Build' '^##[[:space:]]+Run'; do
        if ! grep -qE "$sec" "$PRODUCT_README" 2>/dev/null; then
            echo "[FAIL] ${PRODUCT_README}: missing the consumer section '${sec#^##[[:space:]]+}' - a consumer must be able to build and run it"
            unwritten=$((unwritten+1))
        fi
    done
    echo "check-product-readme: --require-filled: ${unwritten} unwritten/placeholder issue(s)."
    fails=$((fails+unwritten))
fi

if [[ "$fails" -gt 0 ]]; then
    if [[ "$unwritten" -gt 0 ]]; then
        echo "RESULT: RED (exit 1) - the product README leaked methodology vocabulary and/or is not written for a consumer (placeholders / missing Build|Run)."
    else
        echo "RESULT: RED (exit 1) - porting-process vocabulary leaked into the product README."
    fi
    echo "  See .opencode/skill/code-port/references/product-readme.md for how to write the product README."
    exit 1
fi
echo "RESULT: GREEN (exit 0) - the product README is about the product$([[ "$REQUIRE_FILLED" -eq 1 ]] && echo " and is written for a consumer")."
exit 0
