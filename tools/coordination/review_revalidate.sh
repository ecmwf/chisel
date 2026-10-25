#!/usr/bin/env bash
# review_revalidate.sh - decide, FAIL-CLOSED, whether a piece's independent review survives a rebase.
#
# A rebase changes a branch's commit SHAs but may leave the piece's OWN target files byte-identical.
# The independent FIDELITY review reads the piece's TARGET source against the SOURCE; its validity
# tracks the piece's CODE (its target-file bytes), not the commit SHA. So when a rebase leaves the
# piece's target files byte-identical to the commit the review was bound to (proof.commit, the reviewed
# commit), the existing review still describes the shipped bytes and STANDS - a fresh independent
# re-review is owed ONLY when the rebase changed the piece's own target files. This is the same
# principle as failure modes B8/B10 (code UNCHANGED => nothing re-reviewed), applied to a clean rebase.
#
# It does NOT skip the re-prove. A re-prove is ALWAYS owed after a rebase: a moved foundation can change
# the piece's numerical behaviour, and only re-running the proof (the numeric twin) catches that - that
# is the proof's job, never the review's. On a GREEN result here: re-prove, then advance proof.commit to
# the new tip and REUSE the existing review (no fresh independent pass).
#
# The decision is byte-identity of the piece's REVIEWED files between the reviewed commit (the
# fragment's proof.commit) and the rebased tip, via `git diff --quiet` - no stored tree-hash, no manifest.
# The reviewed coverage is read from `review.targets` (the snapshot of `target` taken when the review
# proven the piece, immutable to a later list edit), NOT from the current mutable `target:` list: a rebase
# that ALSO narrowed `target:` could otherwise hide a changed-but-delisted file. So this fails closed when
# `review.targets` is absent, and reports STALE when the current `target:` set differs from `review.targets`
# (the piece's claimed coverage changed since the review - that owes a fresh review).
#
#   review_revalidate.sh <id> [--tip <ref>] [--root <repo-dir>]
#
# <id>          the piece's trace-id; reads port/status/<id>.yaml for proof.commit + target + review.targets.
# --tip <ref>   the rebased tip to check (default: HEAD of the --root repo).
# --root <dir>  the repo where the target bytes live (default: cwd; pass the product checkout for a
#               Phase-2 product piece, whose target paths are product-root-relative).
#
# Exit:
#   0  REVIEW VALID   - target files byte-identical to proof.commit; re-prove, then REUSE the review.
#   1  REVIEW STALE   - target files changed since proof.commit; a fresh INDEPENDENT re-review is owed.
#   2  UNRELIABLE     - cannot decide (missing fragment/field, unresolved commit, not a git repo);
#                       fail closed - treat as needing a fresh re-review.
set -uo pipefail

fail() { echo "review-revalidate: $*" >&2; exit 2; }

ID=""; TIP=""; ROOT="."
while [ "$#" -gt 0 ]; do
	case "$1" in
		--tip)  [ "$#" -ge 2 ] || fail "--tip needs a ref"; TIP="$2"; shift 2 ;;
		--root) [ "$#" -ge 2 ] || fail "--root needs a directory"; ROOT="$2"; shift 2 ;;
		--*)    fail "unknown option: $1" ;;
		*)      [ -z "$ID" ] || fail "only one <id> allowed (got '$ID' and '$1')"; ID="$1"; shift ;;
	esac
done
[ -n "$ID" ] || fail "usage: review_revalidate.sh <id> [--tip <ref>] [--root <repo-dir>]"
case "$ID" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "id '$ID' must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes)" ;; esac

command -v python3 >/dev/null 2>&1 || fail "python3 not found"
command -v git     >/dev/null 2>&1 || fail "git not found"

FRAG="port/status/$ID.yaml"
[ -f "$FRAG" ] || fail "fragment '$FRAG' not found - cannot read proof.commit/target for '$ID'; re-review"

# Parse: line 1 = proof.commit; line 2 = coverage STATUS (OK | MISMATCH | MISSING); remaining lines =
# the REVIEWED target paths to byte-compare. Fail closed on any parse error.
OUT="$(python3 - "$FRAG" <<'PY'
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except Exception:
    sys.exit(3)
def as_list(x):
    # FAIL CLOSED (exit 4) on a malformed list: a non-string member (e.g. a YAML int/null/map) must
    # NOT be silently dropped - dropping it would let a changed file with that name escape the diff.
    if x is None or x == []:
        return []
    if isinstance(x, str):
        return [x.strip()] if x.strip() else []
    if not isinstance(x, list):
        sys.exit(4)
    out = []
    for p in x:
        if not isinstance(p, str):
            sys.exit(4)
        s = p.strip()
        if s:
            out.append(s)
    return out
commit = ((d.get("proof") or {}).get("commit")) or ""
cur = as_list(d.get("target"))
rev = as_list((d.get("review") or {}).get("targets"))
print(commit)
if not rev:
    print("MISSING")
elif set(cur) != set(rev):
    print("MISMATCH")
else:
    print("OK")
for p in rev:
    print(p)
PY
)" || fail "could not parse '$FRAG' (invalid YAML, or a malformed target/review.targets list with a non-string member) - cannot decide; re-review"

mapfile -t LINES <<< "$OUT"
GCOMMIT="${LINES[0]:-}"
STATUS="${LINES[1]:-}"
PATHS=("${LINES[@]:2}")
[ -n "$GCOMMIT" ] || fail "'$ID' fragment has no proof.commit (the reviewed commit) - cannot bind the review to bytes; re-review"
case "$STATUS" in
	MISSING)  fail "'$ID' fragment has no review.targets (the coverage the review saw) - cannot prove the review covered the current bytes; re-review (proving records review.targets)" ;;
	MISMATCH) echo "review-revalidate: REVIEW STALE - '$ID' current target set differs from review.targets (the piece's claimed coverage changed since the review); a fresh INDEPENDENT re-review is owed."; exit 1 ;;
	OK)       : ;;
	*)        fail "internal: unexpected coverage status '$STATUS'" ;;
esac

PATHSPEC=()
for p in "${PATHS[@]}"; do [ -n "$p" ] && PATHSPEC+=(":(literal)$p"); done
[ "${#PATHSPEC[@]}" -gt 0 ] || fail "'$ID' has empty review.targets after parse - nothing to byte-compare; re-review"

git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "'$ROOT' is not a git repository"
[ -n "$TIP" ] || TIP="HEAD"
GFULL="$(git -C "$ROOT" rev-parse -q --verify "${GCOMMIT}^{commit}" 2>/dev/null)" \
	|| fail "proof.commit '$GCOMMIT' does not resolve in '$ROOT' (wrong --root repo?) - cannot compare; re-review"
TFULL="$(git -C "$ROOT" rev-parse -q --verify "${TIP}^{commit}" 2>/dev/null)" \
	|| fail "tip '$TIP' does not resolve in '$ROOT' - cannot compare; re-review"

git -C "$ROOT" diff --quiet "$GFULL" "$TFULL" -- "${PATHSPEC[@]}"; rc=$?
case "$rc" in
	0) echo "review-revalidate: REVIEW VALID - '$ID' target file(s) are byte-identical between the reviewed commit ($GFULL) and tip ($TFULL). Re-prove, then advance proof.commit to the new tip and REUSE the existing review; no fresh independent re-review is owed."
	   exit 0 ;;
	1) echo "review-revalidate: REVIEW STALE - '$ID' target file(s) CHANGED between the reviewed commit ($GFULL) and tip ($TFULL); a fresh INDEPENDENT re-review is owed (in addition to the re-prove)."
	   exit 1 ;;
	*) fail "git diff failed (rc=$rc) comparing '$GFULL'..'$TFULL' - cannot decide; re-review" ;;
esac
