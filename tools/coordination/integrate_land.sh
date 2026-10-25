#!/usr/bin/env bash
# integrate_land.sh - the sanctioned INTEGRATION auto-land (the `integrate` analogue of finalize.sh).
#
# auto-mode's `integrate` action needs the merge of a gated, independently-reviewed piece onto the
# canonical line. This is the sanctioned path so integration is hands-off git: the keystroke is not the
# trust gate, the RECORDED state is - the deterministic planner confirms the piece is gated, carries a
# clean review by a DISTINCT reviewer_id (dispatched on a different model by convention; the machine
# check is the distinct id + a clean verdict bound to the gated commit, via check-trace-evidence), and
# has deps-integrated; and the full conformance suite is green. All re-verified HERE, fail-closed.
#
# SCOPE: the WORKBENCH integration - Phase-1 Layer-0/Layer-1 tooling merged onto the workbench line
# (`git merge --ff-only work/<id>`). The Phase-2 PRODUCT land (squash onto the separate product repo's
# mainline) is its analogue `integrate_product.sh`, NOT this script.
#
# FAIL-CLOSED (refuse, exit 2, merge/push NOTHING) unless ALL hold:
#  - <id> is a valid trace-id and a `work/<id>` branch exists.
#  - work/<id> fast-forwards onto the current branch (HEAD is an ancestor of work/<id>; no divergence
#    or stale base - matching Seshat's stale-base rejection) and the working tree is clean.
#  - THEN the line is ff-merged to work/<id> and the LANDED RESULT is judged (never the pre-land HEAD):
#    * the deterministic Phase-1 planner (phase1_drive.py), run ON THE RESULT, RECOMMENDS `integrate <id>`
#      - it self-validates the F3 evidence + the INDEPENDENT clean review + deps-integrated, so a forged
#        `accepted`/`integrated` flag is sent to triage, not passed (the readiness gate); and
#    * the FULL conformance suite is green ON THE RESULT (the trust floor: gated evidence, completeness).
#    Judging the RESULT, not HEAD, is deliberate: a Phase-1 piece carries its gated evidence + `accepted`
#    state + independent review IN the work/<id> commit (ONE repo, ff-only -> the line is its ancestor and
#    cannot hold them yet), so a HEAD-only gate would DEADLOCK the land of the very piece that supplies the
#    state - the B13 failure mode (references/failure-modes.md). Any miss ROLLS BACK to the pre-land line
#    and refuses (pushing nothing), so nothing un-green or unready - or a commit slipped onto work/<id>
#    after its review - ever lands.
#
#   integrate_land.sh <trace-id> [--remote origin] [--no-push] [--dry-run]
# Exit: 0 landed (ff-merged onto the line + pushed); 2 refused.
set -euo pipefail

fail() { echo "integrate-land: $*" >&2; exit 2; }
say()  { echo "integrate-land: $*"; }
run()  { echo "  + $*"; [ "$DRY" = 1 ] || "$@"; }

# Crash-safe rollback: from the moment we ff-merge the line until the LANDED RESULT is verified ready +
# green (or the dry-run reset completes), ARM a rollback so ANY exit - a failed command OR a signal/kill -
# resets the line to its exact pre-land commit. Without this, an abrupt exit in that window would leave
# the canonical line advanced to unverified bytes. `branch` and `head` are set before arming.
ROLLBACK_ARMED=0; branch=""; head=""
rollback_land() {
	[ "$ROLLBACK_ARMED" = 1 ] || return 0
	echo "integrate-land: land did not complete verified - rolling '$branch' back to $head" >&2
	git reset --hard "$head" >/dev/null 2>&1 \
		|| echo "integrate-land: WARNING - rollback FAILED; '$branch' may sit at an UNVERIFIED commit (nothing was pushed). Reset it by hand: git reset --hard $head" >&2
}
trap rollback_land EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ID=""; REMOTE="origin"; PUSH=1; DRY=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--remote)  [ "$#" -ge 2 ] || fail "--remote needs a remote name"; REMOTE="$2"; shift 2 ;;
		--no-push) PUSH=0; shift ;;
		--dry-run) DRY=1; shift ;;
		--*)       fail "unknown option: $1" ;;
		*)         [ -z "$ID" ] || fail "only one <trace-id> allowed (got '$ID' and '$1')"; ID="$1"; shift ;;
	esac
done

[ -n "$ID" ] || fail "usage: integrate_land.sh <trace-id> [--remote origin] [--no-push] [--dry-run]"
case "$ID" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "id '$ID' must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes)" ;; esac
case "$REMOTE" in ""|-*|*:*|*/*|*" "*) fail "remote '$REMOTE' must be a configured remote name" ;; esac

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
top="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git repository"
cd "$top"
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" != "HEAD" ] || fail "detached HEAD - run from the canonical line you are landing onto"
case "$branch" in work/*) fail "current branch is '$branch' - integrate onto the canonical line (e.g. main), not a work branch" ;; esac
head="$(git rev-parse HEAD)"

plan="port/phase1-plan.yaml"
[ -f "$plan" ] || fail "no $plan - this is the Phase-1 workbench integration land; a Phase-2 product land uses integrate_product.sh, not this script"

# Pre-merge Gate A (CLEAN FAST-FORWARD topology): work/<id> exists, is not already landed, and the line
# fast-forwards onto it (HEAD is an ancestor of work/<id> - no divergence/stale base; Seshat's stale-base
# rule). This is a property of the CURRENT line + the branch topology, so it is checked BEFORE the merge.
wb="work/$ID"
git rev-parse -q --verify "refs/heads/$wb" >/dev/null 2>&1 || fail "branch '$wb' not found"
wbtip="$(git rev-parse "$wb")"
[ "$wbtip" != "$head" ] || fail "'$wb' is already at HEAD - nothing to integrate"
git merge-base --is-ancestor "$head" "$wb" \
	|| fail "'$wb' does not fast-forward onto '$branch' (it diverged / the base moved) - rebase '$wb' onto '$branch' and re-gate; a fresh INDEPENDENT re-review is owed only if the rebase changed the piece's own target files (check: tools/coordination/review_revalidate.sh <id>) before retrying; nothing landed (Seshat's stale-base rule)"

# Pre-merge Gate B (CLEAN STATE): a clean tree (so we land EXACTLY the gated bytes) and a configured remote.
[ -z "$(git status --porcelain)" ] || fail "working tree is dirty - commit or stash before landing"
if [ "$PUSH" = 1 ]; then
	git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "remote '$REMOTE' is not configured"
fi

# THE LAND (the one gated act, inside this sanctioned script): fast-forward the line to work/<id>. We
# then judge the LANDED RESULT - readiness + conformance are properties of the work/<id> bytes, not of
# the pre-land line (see the header: the B13 "judge the result, not the pre-land HEAD" rule).
say "landing '$wb' onto '$branch' (clean FF; readiness + conformance judged on the landed result)$([ "$DRY" = 1 ] && echo ' [dry-run]')"
echo "  + git merge --ff-only $wb"
git merge --ff-only "$wb" >/dev/null || fail "ff-merge of '$wb' failed unexpectedly (topology was clean) - nothing landed"
ROLLBACK_ARMED=1   # the line now points at the merge result; ANY exit below (error or signal) resets it

# Gate 1 (READINESS on the landed bytes, via the self-validating planner): phase1_drive, run ON THE
# RESULT, must RECOMMEND `integrate <id>`. It self-validates the F3 evidence + the INDEPENDENT clean
# review (a DISTINCT reviewer_id, a different-model session by dispatch convention, bound to the gated
# commit by check-trace-evidence) + deps-integrated, so a forged accepted/integrated flag is sent to
# triage, not passed. The result tree carries BOTH the piece's `accepted` state AND - via the ancestor
# line - the deps' integrated state, so this is exactly where readiness is true. Any miss -> fail ->
# the armed trap rolls the line back to its pre-land commit (push NOTHING).
planout="$(python3 "$here/phase1_drive.py" 2>/dev/null)" \
	|| fail "phase1_drive.py did not exit cleanly on the landed result (HALT/UNRELIABLE) - nothing pushed"
printf '%s\n' "$planout" | awk -v id="$ID" '$1=="integrate" && $2==id {f=1} END{exit !f}' \
	|| fail "the Phase-1 planner does NOT recommend 'integrate $ID' on the landed result - it is not gated+clean-reviewed+deps-integrated (or it is guarded/blocked) - nothing pushed"

# Gate 2 (TRUST FLOOR on the landed bytes): the full conformance suite must be green on the merge result
# (gated evidence, completeness, the lot) - so a commit added to work/<id> AFTER its gate/review cannot
# ride in unverified. Re-run `bash tools/run-conformance.sh` to see which check, if any, is red.
bash tools/run-conformance.sh >/dev/null 2>&1 \
	|| fail "conformance check(s) RED at the merge result (work/$ID tip) - the LANDED state is not green; nothing pushed (see: bash tools/run-conformance.sh)"

# Dry-run: we validated the real landed bytes; undo and report (change nothing, push nothing). Disarm
# only AFTER the reset succeeds, so a signal mid-reset still leaves the trap to finish the rollback.
if [ "$DRY" = 1 ]; then
	git reset --hard "$head" >/dev/null 2>&1; ROLLBACK_ARMED=0
	say "dry-run: '$ID' WOULD integrate onto '$branch' - readiness + conformance are green on the landed result; rolled back, nothing changed."
	exit 0
fi

ROLLBACK_ARMED=0   # the landed bytes are verified ready + green: DISARM and keep the commit
[ "$PUSH" = 1 ] && run git push "$REMOTE" "$branch"
say "done - '$ID' integrated onto '$branch'$([ "$PUSH" = 1 ] && echo " (pushed to $REMOTE)"). Record integration.state, commit onto '$branch' any evidence still uncommitted in the worktree, then tear it down (provision_worker.sh remove $ID; it refuses while any evidence is ungathered)."
