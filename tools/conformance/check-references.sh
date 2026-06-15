#!/usr/bin/env bash
#
# check-references.sh - every cited reference file-path and trap-ID resolves.
#
# After the language rulebook was split into per-pair files
# (references/pairs/<source>-to-<target>.md) and per-language files
# (references/langs/<lang>.md), a citation can dangle: a skill, command, template, or
# lesson pointing at a reference path that has moved, or at a trap ID (T1...) that no
# pair table defines. A dangling citation is worse than no split, so this check fails
# loud on either.
#
# It checks two things across the methodology text (skills, commands, agents, the
# code-port templates, tools/README, AGENTS.md, README.md, and port/ lessons):
#   1. every `references/.../<name>.md` path citation exists under a skill's
#      references/ tree;
#   2. every `T<number>` trap-ID citation is defined by a row in some pair table
#      (references/pairs/*.md).
#
# Convention this enforces: cite real files by path; use <angle-bracket> placeholders
# for illustrative/example paths that do not exist yet. Seeded-bug records are excluded
# from the default scan because they intentionally discuss bogus citations.
#
# Exit-code contract:
#   0  GREEN       every cited reference path and trap ID resolves (or nothing to check)
#   1  RED         at least one dangling citation
#   2  UNRELIABLE  detector could not run (no tooling, no pair tables, bad arguments)

set -uo pipefail

usage() {
    cat <<'USAGE'
Usage: check-references.sh [files...]

  files...   Explicit files to scan (for the seeded-bug demonstration). With no
             files, scans the tracked methodology text by default.

Exit: 0 GREEN, 1 RED (dangling citation), 2 UNRELIABLE.
USAGE
}

EXPLICIT_FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do EXPLICIT_FILES+=("$1"); shift; done ;;
        -*) echo "check-references: unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) EXPLICIT_FILES+=("$1"); shift ;;
    esac
done

command -v grep >/dev/null 2>&1 || { echo "check-references: grep not found" >&2; exit 2; }
command -v git  >/dev/null 2>&1 || { echo "check-references: git not found"  >&2; exit 2; }

ORIG_PWD="$PWD"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-references: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || { echo "check-references: cannot enter repo root '${ROOT}'" >&2; exit 2; }

TC_PREFIX=".claude/skills/target-conventions/"
CP_PREFIX=".claude/skills/code-port/"
PAIRS_DIR="${TC_PREFIX}references/pairs"

# Defined trap IDs: the first cell of every pair-table row, e.g. "| T1 | ...".
declare -A IS_DEFINED
defined_count=0
while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    IS_DEFINED["$id"]=1
    defined_count=$((defined_count+1))
done < <(grep -rhoE '^\|[[:space:]]*T[0-9]+[[:space:]]*\|' "$PAIRS_DIR" 2>/dev/null \
            | grep -oE 'T[0-9]+' | sort -u)

if [[ "$defined_count" -eq 0 ]]; then
    echo "check-references: no trap-table definitions found under '${PAIRS_DIR}' - cannot run." >&2
    exit 2
fi

# Scan set.
SCAN=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
    for f in "${EXPLICIT_FILES[@]}"; do
        case "$f" in
            /*) SCAN+=("$f") ;;
            *)  SCAN+=("$ORIG_PWD/$f") ;;
        esac
    done
    for f in "${SCAN[@]}"; do
        [[ -r "$f" ]] || { echo "check-references: file '$f' is missing or unreadable." >&2; exit 2; }
    done
else
    while IFS= read -r f; do SCAN+=("$f"); done < <(
        git ls-files \
            | grep -E '\.md$' \
            | grep -E '^(\.claude/|tools/|port/|AGENTS\.md$|README\.md$)' \
            | grep -vE '^tools/conformance/seeded-bugs/'
    )
fi

if [[ ${#SCAN[@]} -eq 0 ]]; then
    echo "check-references: no files to scan (skipping)."
    exit 0
fi

fails=0

# (1) Reference file-path citations resolve under a skill references/ tree.
while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    [[ -f "${TC_PREFIX}${p}" || -f "${CP_PREFIX}${p}" ]] && continue
    echo "[FAIL] dangling reference path: ${p}"
    grep -rnF -- "$p" "${SCAN[@]}" 2>/dev/null | sed 's/^/    /'
    fails=$((fails+1))
done < <(grep -rhoE 'references/[A-Za-z0-9_./-]+\.md' "${SCAN[@]}" 2>/dev/null | sort -u)

# (2) Trap-ID citations are defined by a pair table.
while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ -n "${IS_DEFINED[$id]:-}" ]] && continue
    echo "[FAIL] dangling trap-ID citation: ${id} (no pair table defines it)"
    grep -rnE -- "\b${id}\b" "${SCAN[@]}" 2>/dev/null | sed 's/^/    /'
    fails=$((fails+1))
done < <(grep -rhoE '\bT[0-9]+\b' "${SCAN[@]}" 2>/dev/null | sort -u)

echo "check-references: scanned ${#SCAN[@]} file(s); ${defined_count} trap ID(s) defined; ${fails} dangling citation(s)."
if [[ "$fails" -gt 0 ]]; then
    echo "RESULT: RED (exit 1) - a citation points at a reference path or trap ID that does not resolve."
    exit 1
fi
echo "RESULT: GREEN (exit 0) - every reference path and trap-ID citation resolves."
exit 0
