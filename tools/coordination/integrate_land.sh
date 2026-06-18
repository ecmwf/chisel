#!/usr/bin/env bash
# integrate_land.sh - the sanctioned INTEGRATION auto-land (the `integrate` analogue of finalize.sh).
#
# auto-mode's `integrate` action needs the one act the orchestrator must NOT run: the merge of a
# gated, independently-reviewed piece onto the canonical line. Ptah never merges; Seshat PREPARES but
# does not perform; so without a sanctioned path the merge falls to a manual `git merge` keystroke.
# This is that path: it performs the fast-forward merge for a CHARTER-AUTHORIZED performer (the bot at
# L2/L3, or a human running this script), so integration is hands-off git - WITHOUT collapsing the
# separation of powers. The keystroke is not the trust gate; the RECORDED state + the separation are,
# and both are re-verified HERE, fail-closed (AGENTS.md: "the human's keystroke is not the gate").
#
# SCOPE: the WORKBENCH integration - Phase-1 Layer-0/Layer-1 tooling merged onto the workbench line
# (`git merge --ff-only work/<id>`). The Phase-2 PRODUCT land (separate product repo + audit manifest
# + integration epoch) is Seshat's documented procedure, NOT this script.
#
# FAIL-CLOSED (refuse, exit 2, merge/push NOTHING) unless ALL hold:
#  - <id> is a valid trace-id and a `work/<id>` branch exists.
#  - the deterministic Phase-1 planner (phase1_drive.py) RECOMMENDS `integrate <id>` at HEAD. The
#    planner self-validates the F3 evidence + the INDEPENDENT clean review + deps-integrated, so a
#    forged `accepted`/`integrated` flag is sent to triage, not passed - this is the readiness gate.
#  - the FULL conformance suite is green at HEAD (the trust floor: independence, gated evidence,
#    bindings, completeness).
#  - work/<id> fast-forwards onto the current branch (HEAD is an ancestor of work/<id>; no divergence
#    or stale base - matching Seshat's stale-base rejection).
#  - the performer (--as <id>) is a contributor REGISTERED in port/contributors.yaml and DISTINCT from
#    the piece's author_id and reviewer_id (the merger is neither the author nor the reviewer).
#
#   integrate_land.sh <trace-id> --as <performer-id> [--remote origin] [--no-push] [--dry-run]
# Exit: 0 landed (ff-merged onto the line + pushed); 2 refused.
set -euo pipefail

fail() { echo "integrate-land: $*" >&2; exit 2; }
say()  { echo "integrate-land: $*"; }
run()  { echo "  + $*"; [ "$DRY" = 1 ] || "$@"; }

ID=""; AS=""; REMOTE="origin"; PUSH=1; DRY=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--as)      [ "$#" -ge 2 ] || fail "--as needs a performer contributor id"; AS="$2"; shift 2 ;;
		--remote)  [ "$#" -ge 2 ] || fail "--remote needs a remote name"; REMOTE="$2"; shift 2 ;;
		--no-push) PUSH=0; shift ;;
		--dry-run) DRY=1; shift ;;
		--*)       fail "unknown option: $1" ;;
		*)         [ -z "$ID" ] || fail "only one <trace-id> allowed (got '$ID' and '$1')"; ID="$1"; shift ;;
	esac
done

[ -n "$ID" ] || fail "usage: integrate_land.sh <trace-id> --as <performer-id> [--remote origin] [--no-push] [--dry-run]"
case "$ID" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "id '$ID' must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes)" ;; esac
[ -n "$AS" ] || fail "--as <performer-id> is required: the merge must name a registered performer distinct from the author/reviewer (a charter-bot at L2/L3, or you)"
case "$AS" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "performer id '$AS' must match [A-Za-z0-9][A-Za-z0-9._-]*" ;; esac
case "$REMOTE" in ""|-*|*:*|*/*|*" "*) fail "remote '$REMOTE' must be a configured remote name" ;; esac

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git repository"
cd "$top"
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" != "HEAD" ] || fail "detached HEAD - run from the canonical line you are landing onto"
case "$branch" in work/*) fail "current branch is '$branch' - integrate onto the canonical line (e.g. main), not a work branch" ;; esac
head="$(git rev-parse HEAD)"

# Gate 1 (READINESS, via the self-validating planner): phase1_drive must RECOMMEND `integrate <id>`.
plan="port/phase1-plan.yaml"
[ -f "$plan" ] || fail "no $plan - this is the Phase-1 workbench integration land; a Phase-2 product land is Seshat's procedure, not this script"
planout="$(python3 "$here/phase1_drive.py" 2>/dev/null)" || fail "phase1_drive.py did not exit cleanly (HALT/UNRELIABLE) - the plan is not in an integratable state"
printf '%s\n' "$planout" | awk -v id="$ID" '$1=="integrate" && $2==id {f=1} END{exit !f}' \
	|| fail "the Phase-1 planner does NOT recommend 'integrate $ID' at HEAD - it is not gated+clean-reviewed+deps-integrated (or it is guarded/blocked). Nothing landed"

# Gate 2 (TRUST FLOOR): the full conformance suite must be green at HEAD.
fails=0
for s in tools/conformance/*.sh; do bash "$s" >/dev/null 2>&1 || fails=$((fails+1)); done
[ "$fails" -eq 0 ] || fail "$fails conformance check(s) RED at HEAD - never integrate over a red gate; fix them first"

# Gate 3 (CLEAN FAST-FORWARD): work/<id> must exist and fast-forward onto the current line.
wb="work/$ID"
git rev-parse -q --verify "refs/heads/$wb" >/dev/null 2>&1 || fail "branch '$wb' not found"
wbtip="$(git rev-parse "$wb")"
[ "$wbtip" != "$head" ] || fail "'$wb' is already at HEAD - nothing to integrate"
git merge-base --is-ancestor "$head" "$wb" \
	|| fail "'$wb' does not fast-forward onto '$branch' (it diverged / the base moved) - rebase '$wb' onto '$branch', re-gate, AND get a fresh INDEPENDENT re-review (gate and review are commit-bound) before retrying; nothing landed (Seshat's stale-base rule)"

# Gate 4 (INDEPENDENT, REGISTERED MERGER): port/contributors.yaml is REQUIRED (an absent registry is
# never a pass); the performer must be a registered contributor whose HUMAN is neither the author's nor
# the reviewer's - resolved through the registry's canonical id->human map (reusing check_contributors'
# NFC/trim/casefold key), so an alias id or a case/space variant cannot sneak the merger past the
# separation. Exit: 0 ok | 2 performer is the author/reviewer human | 3 performer unregistered | 1 other.
[ -f port/contributors.yaml ] || fail "port/contributors.yaml is required - the merger must be a REGISTERED contributor distinct from the author/reviewer; an absent registry is never a pass"
set +e
PYTHONPATH="$here" python3 - "$plan" "$ID" "$AS" <<'PY'
import sys
plan, uid, performer = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    import yaml
    from dashboard import _strict_loader
    from check_contributors import _key
    L = _strict_loader(yaml)
    plan_d = yaml.load(open(plan, encoding="utf-8"), Loader=L) or {}
    reg = yaml.load(open("port/contributors.yaml", encoding="utf-8"), Loader=L) or {}
except Exception:
    sys.exit(1)
if not isinstance(plan_d, dict) or not isinstance(reg, dict):
    sys.exit(1)
id2human = {}
for c in (reg.get("contributors") or []):
    if isinstance(c, dict) and isinstance(c.get("id"), str) and isinstance(c.get("human"), str) \
            and c["id"].strip() and c["human"].strip():
        id2human[_key(c["id"])] = _key(c["human"])
pk = _key(performer)
if pk not in id2human:
    sys.exit(3)                                  # performer is not a registered contributor
unit = next((u for u in (plan_d.get("units") or [])
             if isinstance(u, dict) and str(u.get("id")) == uid), None)
if unit is None:
    sys.exit(1)
perf_human = id2human[pk]
for role_id in (unit.get("author_id"), unit.get("reviewer_id")):
    if not (isinstance(role_id, str) and role_id.strip()):
        sys.exit(4)                              # an integrate-ready unit must name an author AND reviewer
    rk = _key(role_id)
    if rk not in id2human:
        sys.exit(4)                              # author/reviewer UNREGISTERED -> independence is UNPROVABLE -> refuse
    if perf_human == id2human[rk]:
        sys.exit(2)                              # performer resolves to the author's or reviewer's human
sys.exit(0)
PY
rc=$?
set -e
case "$rc" in
	0) : ;;
	2) fail "performer '$AS' resolves to the same human as the author or reviewer of '$ID' - the merger must be a DISTINCT person (separation of powers)" ;;
	3) fail "performer '$AS' is not a registered contributor in port/contributors.yaml" ;;
	4) fail "the author or reviewer of '$ID' is missing or NOT registered in port/contributors.yaml - cannot prove the merger is a distinct human; register all three first" ;;
	*) fail "cannot resolve '$ID' against the registry (missing unit, or malformed plan/registry)" ;;
esac

# Working tree must be clean, so what we land is exactly the gated bytes.
[ -z "$(git status --porcelain)" ] || fail "working tree is dirty - commit or stash before landing"
if [ "$PUSH" = 1 ]; then
	git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "remote '$REMOTE' is not configured"
fi

say "landing '$wb' onto '$branch' as '$AS' (planner-ready, conformance green, clean FF)$([ "$DRY" = 1 ] && echo ' [dry-run]')"
run git merge --ff-only "$wb"                  # the one gated act, inside this sanctioned script
[ "$PUSH" = 1 ] && run git push "$REMOTE" "$branch"
say "done - '$ID' integrated onto '$branch'$([ "$PUSH" = 1 ] && echo " (pushed to $REMOTE)")$([ "$DRY" = 1 ] && echo ' [dry-run]'). Record integration.state and tear down the worktree as usual."
