#!/usr/bin/env bash
#
# check-status-fragments.sh - validate the per-work-item status fragments.
#
# In a many-contributor port, each work item's status lives in its own branch as
# port/status/<trace-id>.yaml (shard-and-generate; see references/team-coordination.md),
# and the canonical TRACE is generated from these. This check validates a fragment
# BEFORE it feeds the generator, fail-closed, so a malformed or independence-violating
# fragment never silently corrupts canonical status or defeats independent review.
#
# It checks, per fragment:
#   - the YAML is a known, well-formed subset: no duplicate keys, no unknown keys
#     (fail-closed; lists use block "- item" form);
#   - enums: status {unmapped,in-progress,proven,excluded}; ownership.kind {owned,leaf};
#     claim.state {created,active,stale}; integration.state {proven,integrated};
#   - status-dependent required fields (an excluded row needs only a reason; an
#     in-progress row needs target/claim; a proven row needs target/claim/author_id - a
#     dispatched worker cannot see its own session id, so author_id stays null until the
#     orchestrator records it from the worker's Task result);
#   - claim.ref, when set, names this unit's own claim: port/claims/<id>.yaml or refs/claims/<id>;
#   - proven => a real, INDEPENDENT review: reviewer_id set and != author_id;
#     reviewer_session set and NOT in author_sessions; author_sessions non-empty; a
#     tier-R1+ proof with evidence and a review report. (The syntactic check; the independence
#     control is the reviewer agent dispatched on a different model - there is no identity registry.)
#   - integrated => status proven, product.main_commit set.
#
# Exit-code contract:
#   0  GREEN       every fragment is well-formed (or there are none)
#   1  RED         at least one fragment violates the schema
#   2  UNRELIABLE  detector could not run (missing tooling / not a git repo)

set -uo pipefail

command -v awk >/dev/null 2>&1 || { echo "check-status-fragments: awk not found" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "check-status-fragments: git not found" >&2; exit 2; }

EXPLICIT_FILES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) echo "Usage: check-status-fragments.sh [fragment.yaml ...]"; exit 0 ;;
        --) shift; while [[ $# -gt 0 ]]; do EXPLICIT_FILES+=("$1"); shift; done ;;
        -*) echo "check-status-fragments: unknown option: $1" >&2; exit 2 ;;
        *) EXPLICIT_FILES+=("$1"); shift ;;
    esac
done

ORIG_PWD="$PWD"
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-status-fragments: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || { echo "check-status-fragments: cannot enter repo root '${ROOT}'" >&2; exit 2; }

FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
    for f in "${EXPLICIT_FILES[@]}"; do
        case "$f" in /*) FILES+=("$f") ;; *) FILES+=("$ORIG_PWD/$f") ;; esac
    done
else
    while IFS= read -r f; do FILES+=("$f"); done \
        < <(find port/status -type f -name '*.yaml' ! -name '_meta.yaml' 2>/dev/null | sort)
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "check-status-fragments: no fragments under port/status/ - nothing to check (skipping)."
    exit 0
fi

# Parse a fragment into section-qualified, trimmed, dequoted lines: "key=val",
# "section.key=val", and block-list items "section[]=item". Two nesting levels only.
parse() {
    awk '
    function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
    function dequote(s) {
        if (s ~ /^".*"$/)       return substr(s, 2, length(s) - 2)
        if (s ~ /^\047.*\047$/) return substr(s, 2, length(s) - 2)
        return s
    }
    {
        line = $0
        sub(/[[:space:]]*#.*$/, "", line)
        if (line ~ /^[a-z_]+:/) {
            key = line; sub(/:.*/, "", key)
            val = dequote(trim(substr(line, length(key) + 2)))
            section = key
            if (val != "") print key "=" val
        } else if (line ~ /^  - /) {
            item = dequote(trim(substr(line, 5)))
            if (item != "") print section "[]=" item
        } else if (line ~ /^  [a-z_]+:/) {
            sub(/^  /, "", line)
            key = line; sub(/:.*/, "", key)
            val = dequote(trim(substr(line, length(key) + 2)))
            print section "." key "=" val
        }
    }' "$1"
}

KNOWN_SCALAR=" id source target status provides_contract ownership.kind ownership.workstream\
 ownership.owned_surface author_id author_team reviewer_id reviewer_team reviewer_session\
 claim.ref claim.claimant claim.state product.branch_commit product.main_commit proof.tier\
 proof.validation proof.commit proof.evidence review.evidence review.targets integration.state integration.epoch_certificate\
 workbench_manifest notes "
# notes accepts BOTH a scalar string (legacy) and a block list (preferred): it is in KNOWN_SCALAR
# above AND KNOWN_LIST here, so a synced instance's existing string notes never breaks.
KNOWN_LIST=" author_sessions depends_on consumes_contracts notes "

is_set()  { local v="${1:-}"; [[ -n "$v" && "$v" != "null" && "$v" != "[]" && "$v" != *"<"* ]]; }
in_set()  { local v="$1"; shift; local x; for x in "$@"; do [[ "$v" == "$x" ]] && return 0; done; return 1; }

fails=0
for f in "${FILES[@]}"; do
    [[ -r "$f" ]] || { echo "[FAIL] ${f}: not found/readable"; fails=$((fails+1)); continue; }

    declare -A F=() SEEN=()
    AUTHOR_SESSIONS=()
    NOTES_ITEMS=()
    ff=0   # per-file fail flag for messages

    while IFS='=' read -r k v; do
        [[ -n "$k" ]] || continue
        if [[ "$k" == *'[]' ]]; then
            base="${k%'[]'}"
            [[ "$KNOWN_LIST" == *" $base "* ]] || { echo "[FAIL] ${f}: unknown list key '${base}'"; fails=$((fails+1)); ff=1; continue; }
            [[ "$base" == "author_sessions" ]] && AUTHOR_SESSIONS+=("$v")
            [[ "$base" == "notes" ]] && NOTES_ITEMS+=("$v")
            continue
        fi
        # A port that has not migrated still writes the gate block (legacy-vocab): it is the proof block,
        # so mapping it here also makes a fragment holding both blocks a duplicate key below.
        [[ "$k" == gate.* ]] && k="proof.${k#gate.}"   # legacy-vocab
        if [[ -n "${SEEN[$k]:-}" ]]; then
            echo "[FAIL] ${f}: duplicate key '${k}'"; fails=$((fails+1)); ff=1
        fi
        SEEN[$k]=1
        [[ "$KNOWN_SCALAR" == *" $k "* || "$KNOWN_LIST" == *" $k "* ]] || { echo "[FAIL] ${f}: unknown key '${k}'"; fails=$((fails+1)); ff=1; }
        F[$k]="$v"
    done < <(parse "$f")

    [[ "${F[status]:-}" == "gated" ]] && F[status]="proven"                          # legacy-vocab
    [[ "${F[integration.state]:-}" == "gated" ]] && F[integration.state]="proven"    # legacy-vocab
    st="${F[status]:-}"

    # Base required fields.
    for req in id source status ownership.kind; do
        is_set "${F[$req]:-}" || { echo "[FAIL] ${f}: missing/placeholder required field '${req}'"; fails=$((fails+1)); ff=1; }
    done

    # Enums (validated when set).
    is_set "$st" && ! in_set "$st" unmapped in-progress proven excluded && { echo "[FAIL] ${f}: invalid status '${st}'"; fails=$((fails+1)); ff=1; }
    is_set "${F[ownership.kind]:-}" && ! in_set "${F[ownership.kind]}" owned leaf && { echo "[FAIL] ${f}: invalid ownership.kind '${F[ownership.kind]}'"; fails=$((fails+1)); ff=1; }
    is_set "${F[claim.state]:-}" && ! in_set "${F[claim.state]}" created active stale && { echo "[FAIL] ${f}: invalid claim.state '${F[claim.state]}'"; fails=$((fails+1)); ff=1; }
    is_set "${F[integration.state]:-}" && ! in_set "${F[integration.state]}" proven integrated && { echo "[FAIL] ${f}: invalid integration.state '${F[integration.state]}'"; fails=$((fails+1)); ff=1; }
    is_set "${F[proof.validation]:-}" && ! in_set "${F[proof.validation]}" transitive && { echo "[FAIL] ${f}: proof.validation must be 'transitive' or null (declaration-only marker)"; fails=$((fails+1)); ff=1; }

    # Owned items name an owner.
    [[ "${F[ownership.kind]:-}" == "owned" ]] && ! is_set "${F[ownership.workstream]:-}" && { echo "[FAIL] ${f}: ownership.kind=owned but ownership.workstream is unset"; fails=$((fails+1)); ff=1; }
    [[ "${F[ownership.kind]:-}" == "owned" ]] && ! is_set "${F[ownership.owned_surface]:-}" && { echo "[FAIL] ${f}: ownership.kind=owned but ownership.owned_surface is unset"; fails=$((fails+1)); ff=1; }

    # Status-dependent requirements.
    case "$st" in
        excluded)
            # A reason is required: a scalar `notes:` string (legacy) OR at least one block-list item.
            { is_set "${F[notes]:-}" || [[ ${#NOTES_ITEMS[@]} -gt 0 ]]; } \
                || { echo "[FAIL] ${f}: excluded row needs a reason in notes"; fails=$((fails+1)); ff=1; } ;;
        in-progress)
            # author_id may still be null: the orchestrator records it from the worker's Task result.
            for req in target claim.ref claim.claimant claim.state; do
                is_set "${F[$req]:-}" || { echo "[FAIL] ${f}: status '${st}' requires '${req}'"; fails=$((fails+1)); ff=1; }
            done ;;
        proven)
            for req in target claim.ref claim.claimant claim.state author_id; do
                is_set "${F[$req]:-}" || { echo "[FAIL] ${f}: status '${st}' requires '${req}'"; fails=$((fails+1)); ff=1; }
            done ;;
    esac

    # The cited claim is this unit's own: the local port/claims/<id>.yaml or the pushed ref
    # refs/claims/<id>. Another unit's claim (a fragment copied from a sibling) binds this unit to a
    # reservation that does not cover it.
    uid="${F[id]:-}"
    if is_set "${F[claim.ref]:-}" && is_set "$uid" \
        && [[ "${F[claim.ref]}" != "port/claims/${uid}.yaml" && "${F[claim.ref]}" != "refs/claims/${uid}" ]]; then
        echo "[FAIL] ${f}: claim.ref '${F[claim.ref]}' is not this unit's claim (expected port/claims/${uid}.yaml or refs/claims/${uid})"; fails=$((fails+1)); ff=1
    fi

    # target, when set, must be a YAML list (the TRACE generator requires it); reject a bare scalar.
    is_set "${F[target]:-}" && [[ ! "${F[target]}" =~ ^\[.*\]$ ]] && { echo "[FAIL] ${f}: target must be a list like [path.c], not a bare scalar (the TRACE generator requires a list)"; fails=$((fails+1)); ff=1; }

    # proven => a real, independent review and a tier-R1+ proof.
    if [[ "$st" == "proven" ]]; then
        if is_set "${F[reviewer_id]:-}"; then
            [[ "${F[reviewer_id]}" == "${F[author_id]:-}" ]] && { echo "[FAIL] ${f}: reviewer_id == author_id ('${F[author_id]:-}') - independence violated"; fails=$((fails+1)); ff=1; }
        else
            echo "[FAIL] ${f}: proven requires reviewer_id (independent reviewer)"; fails=$((fails+1)); ff=1
        fi
        if is_set "${F[reviewer_session]:-}"; then
            for s in "${AUTHOR_SESSIONS[@]}"; do
                [[ "$s" == "${F[reviewer_session]}" ]] && { echo "[FAIL] ${f}: reviewer_session '${s}' appears in author_sessions - independence violated"; fails=$((fails+1)); ff=1; }
            done
        else
            echo "[FAIL] ${f}: proven requires reviewer_session"; fails=$((fails+1)); ff=1
        fi
        [[ ${#AUTHOR_SESSIONS[@]} -gt 0 ]] || { echo "[FAIL] ${f}: proven requires a non-empty author_sessions (block list)"; fails=$((fails+1)); ff=1; }
        if is_set "${F[proof.tier]:-}"; then
            [[ "${F[proof.tier]}" =~ ^R[1-9][0-9]*$ ]] || { echo "[FAIL] ${f}: proof.tier '${F[proof.tier]}' must be R1 or higher (R0 cannot prove)"; fails=$((fails+1)); ff=1; }
        else
            echo "[FAIL] ${f}: proven requires proof.tier (R1+)"; fails=$((fails+1)); ff=1
        fi
        is_set "${F[proof.commit]:-}"     || { echo "[FAIL] ${f}: proven requires proof.commit (the product commit the proof ran against)"; fails=$((fails+1)); ff=1; }
        is_set "${F[proof.evidence]:-}"   || { echo "[FAIL] ${f}: proven requires proof.evidence"; fails=$((fails+1)); ff=1; }
        is_set "${F[review.evidence]:-}" || { echo "[FAIL] ${f}: proven requires review.evidence"; fails=$((fails+1)); ff=1; }
    fi

    # Any non-null integration state requires the piece be proven first.
    is_set "${F[integration.state]:-}" && [[ "$st" != "proven" ]] && { echo "[FAIL] ${f}: integration.state '${F[integration.state]}' set but status is not proven"; fails=$((fails+1)); ff=1; }

    # integrated => proven, on the canonical line (product.main_commit records where it landed).
    if [[ "${F[integration.state]:-}" == "integrated" ]]; then
        [[ "$st" == "proven" ]] || { echo "[FAIL] ${f}: integration.state=integrated requires status: proven"; fails=$((fails+1)); ff=1; }
        is_set "${F[product.main_commit]:-}" || { echo "[FAIL] ${f}: integrated requires product.main_commit"; fails=$((fails+1)); ff=1; }
    fi

    [[ "$ff" -eq 0 ]] && echo "  ok: ${f}"
    unset F SEEN
done

echo "check-status-fragments: checked ${#FILES[@]} fragment(s); ${fails} violation(s)."
if [[ "$fails" -gt 0 ]]; then
    echo "RESULT: RED (exit 1) - a status fragment is malformed or violates independence."
    exit 1
fi
echo "RESULT: GREEN (exit 0) - all status fragments are well-formed."
exit 0
