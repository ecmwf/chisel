#!/usr/bin/env bash
#
# check-status-fragments.sh - validate the per-work-item status fragments.
#
# In a many-contributor port, each work item's status lives in its own branch as
# port/status/<trace-id>.yaml (shard-and-generate; see references/team-coordination.md),
# and the canonical TRACE is generated from these fragments. This check validates a
# fragment's schema BEFORE it feeds the generator, so a malformed or
# independence-violating fragment never silently corrupts canonical status.
#
# It checks, per fragment:
#   - required fields present and not left as <placeholders>: id, source, status,
#     ownership.kind, claim.ref;
#   - enums valid: status in {unmapped,in-progress,gated,excluded};
#     ownership.kind in {owned,leaf}; claim.state in {created,active,stale};
#     integration.state in {gated,integrated};
#   - owned items name an owner: ownership.kind=owned requires ownership.workstream;
#   - INDEPENDENCE (the fidelity invariant): when both are set, reviewer_id != author_id
#     - the team-scale form of the existing "reviewer session not in author_sessions".
#
# Exit-code contract:
#   0  GREEN       every fragment is well-formed (or there are none)
#   1  RED         at least one fragment violates the schema
#   2  UNRELIABLE  detector could not run (missing tooling)

set -uo pipefail

command -v awk >/dev/null 2>&1 || { echo "check-status-fragments: awk not found" >&2; exit 2; }

EXPLICIT_FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) echo "Usage: check-status-fragments.sh [fragment.yaml ...]"; exit 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do EXPLICIT_FILES+=("$1"); shift; done ;;
        -*) echo "check-status-fragments: unknown option: $1" >&2; exit 2 ;;
        *) EXPLICIT_FILES+=("$1"); shift ;;
    esac
done

FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
    FILES=("${EXPLICIT_FILES[@]}")
else
    while IFS= read -r f; do FILES+=("$f"); done \
        < <(find port/status -type f -name '*.yaml' 2>/dev/null | sort)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "check-status-fragments: no fragments under port/status/ - nothing to check (skipping)."
    exit 0
fi

# Emit section-qualified scalars (key=value / section.key=value) for one fragment, so
# nested keys that repeat under different parents (claim.state vs integration.state) are
# disambiguated by their parent section.
parse() {
    awk '
    {
        line = $0
        sub(/[[:space:]]*#.*$/, "", line)          # strip inline comments
        if (line ~ /^[a-z_]+:/) {                    # top-level key
            key = line; sub(/:.*/, "", key)
            val = line; sub(/^[a-z_]+:[[:space:]]*/, "", val)
            section = key
            if (val != "") print key "=" val
        } else if (line ~ /^  [a-z_]+:/) {           # nested key (2-space indent)
            key = line; sub(/^  /, "", key); sub(/:.*/, "", key)
            val = line; sub(/^  [a-z_]+:[[:space:]]*/, "", val)
            print section "." key "=" val
        }
    }' "$1"
}

# Is a value set (non-empty, not null, not a <placeholder>)?
is_set() { [[ -n "$1" && "$1" != "null" && ! "$1" =~ ^\<.*\>$ ]]; }

in_set() { local v="$1"; shift; local x; for x in "$@"; do [[ "$v" == "$x" ]] && return 0; done; return 1; }

fails=0
for f in "${FILES[@]}"; do
    [[ -f "$f" ]] || { echo "[FAIL] ${f}: not found"; fails=$((fails+1)); continue; }

    declare -A F=()
    while IFS='=' read -r k v; do
        [[ -n "$k" ]] || continue
        v="${v%\"}"; v="${v#\"}"                     # strip surrounding quotes
        F["$k"]="$v"
    done < <(parse "$f")

    # Required fields.
    for req in id source status ownership.kind claim.ref; do
        is_set "${F[$req]:-}" || { echo "[FAIL] ${f}: missing/placeholder required field '${req}'"; fails=$((fails+1)); }
    done

    # Enums.
    if is_set "${F[status]:-}" && ! in_set "${F[status]}" unmapped in-progress gated excluded; then
        echo "[FAIL] ${f}: invalid status '${F[status]}'"; fails=$((fails+1))
    fi
    if is_set "${F[ownership.kind]:-}" && ! in_set "${F[ownership.kind]}" owned leaf; then
        echo "[FAIL] ${f}: invalid ownership.kind '${F[ownership.kind]}'"; fails=$((fails+1))
    fi
    if is_set "${F[claim.state]:-}" && ! in_set "${F[claim.state]}" created active stale; then
        echo "[FAIL] ${f}: invalid claim.state '${F[claim.state]}'"; fails=$((fails+1))
    fi
    if is_set "${F[integration.state]:-}" && ! in_set "${F[integration.state]}" gated integrated; then
        echo "[FAIL] ${f}: invalid integration.state '${F[integration.state]}'"; fails=$((fails+1))
    fi

    # Owned items must name an owner.
    if [[ "${F[ownership.kind]:-}" == "owned" ]] && ! is_set "${F[ownership.workstream]:-}"; then
        echo "[FAIL] ${f}: ownership.kind=owned but ownership.workstream is unset"; fails=$((fails+1))
    fi

    # INDEPENDENCE: reviewer must differ from author (when both are set).
    if is_set "${F[author_id]:-}" && is_set "${F[reviewer_id]:-}" && [[ "${F[author_id]}" == "${F[reviewer_id]}" ]]; then
        echo "[FAIL] ${f}: reviewer_id == author_id ('${F[author_id]}') - independence violated"; fails=$((fails+1))
    fi

    unset F
done

echo "check-status-fragments: checked ${#FILES[@]} fragment(s); ${fails} violation(s)."
if [[ "$fails" -gt 0 ]]; then
    echo "RESULT: RED (exit 1) - a status fragment is malformed or violates independence."
    exit 1
fi
echo "RESULT: GREEN (exit 0) - all status fragments are well-formed."
exit 0
