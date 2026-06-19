#!/usr/bin/env bash
# integrate_product.sh - the sanctioned Phase-2 PRODUCT land (the two-repo analogue of integrate_land.sh).
#
# Phase 1 lands TOOLING onto the workbench line (integrate_land.sh). Phase 2 lands the ported CODE onto
# the separate PRODUCT repo's mainline - the step that actually fills the target repo. It lands the
# REVIEWED bytes of ONE work/<id> branch (a squash), in dependency order - the integrator authors
# nothing here and never hand-assembles N modules with unreviewed build glue (the product build is a
# generated, reviewed deliverable; see seshat-integrator.md). This is the
# sanctioned path so that land is hands-off git and fail-closed: the keystroke is never the trust gate,
# the RECORDED state is. The deterministic Phase-2 planner confirms the piece is gated, carries a clean
# review by a DISTINCT reviewer (bound to the gated commit by check-trace-evidence), and has its deps
# integrated; the FULL conformance suite is green across BOTH roots (workbench checks + the product-facing
# checks scanning the product checkout - the two-root contract C6); the piece is squash-merged onto the
# product mainline as ONE clean commit (clean product history C5); the merge RESULT is re-verified and
# ROLLED BACK on red (pushing nothing); only then is the product mainline pushed. All re-verified HERE.
#
# It pushes to the PRODUCT repo's remote from INSIDE this script, so it bypasses the per-agent `git push`
# deny exactly as integrate_land.sh / finalize.sh / contribute.sh do - and only ever for the ONE named,
# planner-ready, conformance-green, non-stale piece.
#
# FAIL-CLOSED (refuse, exit 2, merge/push NOTHING) unless ALL hold:
#  - <id> is a valid trace-id; a two-repo product is wired (port/product.yaml + a present checkout).
#  - the product checkout is on its default branch and clean (we land onto the real mainline).
#  - the Phase-2 planner (autodrive.py) RECOMMENDS `integrate <id>` (gated + INDEPENDENT clean review +
#    deps-integrated; a forged flag is sent to triage, not passed - the readiness gate).
#  - the FULL conformance suite is green at HEAD (both roots), and AGAIN at the product merge RESULT.
#  - a product `work/<id>` branch exists and INCLUDES the current product mainline (not stale-based; a
#    moved base means rebase + re-gate + re-review, never a silent merge of an ungated tree).
#
#   integrate_product.sh <trace-id> [--message <msg>] [--remote origin] [--no-push] [--dry-run]
# Exit: 0 landed (squash-merged onto the product mainline + pushed); 2 refused.
set -euo pipefail

fail() { echo "integrate-product: $*" >&2; exit 2; }
say()  { echo "integrate-product: $*"; }
run()  { echo "  + $*"; [ "$DRY" = 1 ] || "$@"; }

# Crash-safe rollback: from the moment we mutate the product (the squash + commit) until the merge
# RESULT is verified green, ARM a rollback so ANY exit - a failed git command, or a signal/kill - resets
# the product mainline to its exact pre-land commit. Without this, an abrupt exit in that window would
# leave the product mainline advanced to an unverified commit. PC and PRE_LAND are set before arming.
ROLLBACK_ARMED=0; PC=""; PRE_LAND=""
rollback_product() {
	[ "$ROLLBACK_ARMED" = 1 ] || return 0
	echo "integrate-product: land did not complete verified - rolling product back to $PRE_LAND" >&2
	git -C "$PC" reset --hard "$PRE_LAND" >/dev/null 2>&1 \
		|| echo "integrate-product: WARNING - rollback FAILED; the product mainline may sit at an UNVERIFIED commit (nothing was pushed). Reset it by hand: git -C '$PC' reset --hard $PRE_LAND" >&2
}
trap rollback_product EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ID=""; REMOTE="origin"; PUSH=1; DRY=0; MSG=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--message) [ "$#" -ge 2 ] || fail "--message needs a commit message"; MSG="$2"; shift 2 ;;
		--remote)  [ "$#" -ge 2 ] || fail "--remote needs a remote name"; REMOTE="$2"; shift 2 ;;
		--no-push) PUSH=0; shift ;;
		--dry-run) DRY=1; shift ;;
		--*)       fail "unknown option: $1" ;;
		*)         [ -z "$ID" ] || fail "only one <trace-id> allowed (got '$ID' and '$1')"; ID="$1"; shift ;;
	esac
done

[ -n "$ID" ] || fail "usage: integrate_product.sh <trace-id> [--message <msg>] [--remote origin] [--no-push] [--dry-run]"
case "$ID" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "id '$ID' must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes)" ;; esac
case "$REMOTE" in ""|-*|*:*|*/*|*" "*) fail "remote '$REMOTE' must be a configured remote name" ;; esac

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../conformance/lib/product-root.sh"
wb="$(_pr_repo_root)" || fail "not inside a git repository"
cd "$wb"

# Gate 0 (TWO-REPO WIRED): resolve the product checkout, fail-closed on single-repo / placeholder / absent.
set +e; PC="$(default_product_root)"; PRC=$?; set -e
case "$PRC" in
	0)  : ;;
	10) fail "single-repo (no port/product.yaml) - there is no separate product; Phase-1 tooling lands with integrate_land.sh" ;;
	2)  fail "product is wired but its checkout is unset/placeholder - set it in port/product.yaml first (UNRELIABLE)" ;;
	*)  fail "cannot resolve the product checkout" ;;
esac
[ -d "$PC" ] || fail "product checkout '$PC' is absent - clone it first (tools/checkout-product.sh)"
git -C "$PC" rev-parse --show-toplevel >/dev/null 2>&1 || fail "product checkout '$PC' is not a git repo"

# The product's default branch (the mainline we land onto), from port/product.yaml; default 'main'.
DB="$(sed -nE 's/^[[:space:]]*default_branch:[[:space:]]*(.*)$/\1/p' port/product.yaml | head -1 \
	| sed -E 's/[[:space:]]*#.*$//; s/^["'\'']//; s/["'\'']$//; s/[[:space:]]*$//')"
[ -n "$DB" ] || DB="main"

# Gate 1 (PRODUCT ON ITS MAINLINE, clean): land onto the real mainline, exactly the gated bytes.
pcur="$(git -C "$PC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
[ "$pcur" = "$DB" ] || fail "product checkout is on '$pcur', not '$DB' - check out the product mainline before landing"
[ -z "$(git -C "$PC" status --porcelain)" ] || fail "product working tree is dirty - commit/clean it first (we land exactly the gated bytes)"

# Gate 2 (READINESS via the Phase-2 planner): autodrive must RECOMMEND `integrate <id>` (a ready piece is
# always actionable, so the planner exits 0; a malformed artifact / stuck graph fails closed here).
planout="$(python3 "$here/autodrive.py" 2>/dev/null)" || fail "the Phase-2 planner (autodrive.py) did not exit cleanly (HALT/UNRELIABLE) - not in an integratable state"
printf '%s\n' "$planout" | awk -v id="$ID" '$1=="integrate" && $2==id {f=1} END{exit !f}' \
	|| fail "the Phase-2 planner does NOT recommend 'integrate $ID' - it is not gated+clean-reviewed+deps-integrated (or it is guarded/blocked). Nothing landed"

# Gate 3 (TRUST FLOOR, both roots): full conformance green at HEAD - workbench checks AND the product-facing
# checks (verify-anchors, invisibility, product-tests, ...) scanning the product checkout (C6).
bash tools/run-conformance.sh >/dev/null 2>&1 \
	|| fail "conformance check(s) RED at HEAD - never land over a red gate; fix them first (see: bash tools/run-conformance.sh)"

# Gate 4 (BRANCH EXISTS, NOT STALE): a product work/<id> branch that INCLUDES the current mainline, so the
# squash result tree == the gated branch tip tree (a stale base would land an ungated combined tree).
br="work/$ID"
git -C "$PC" rev-parse -q --verify "refs/heads/$br" >/dev/null 2>&1 || fail "branch '$br' not found in the product repo ('$PC')"
pmain="$(git -C "$PC" rev-parse "$DB")"
brtip="$(git -C "$PC" rev-parse "$br")"
[ "$brtip" != "$pmain" ] || fail "'$br' is already at '$DB' - nothing to integrate"
git -C "$PC" merge-base --is-ancestor "$pmain" "$br" \
	|| fail "'$br' does not include the current '$DB' (the base moved) - rebase '$br' onto '$DB', re-gate, AND get a fresh INDEPENDENT re-review (gate and review are commit-bound), then retry; nothing landed (stale-base rule)"

if [ "$PUSH" = 1 ]; then
	git -C "$PC" remote get-url "$REMOTE" >/dev/null 2>&1 || fail "product remote '$REMOTE' is not configured (in '$PC')"
fi

# Land: ONE squashed product commit onto the mainline (clean product history C5). ARM the crash-safe
# rollback first: from here until Gate 5 passes, any exit (error or signal) resets the mainline to PRE_LAND.
[ -n "$MSG" ] || MSG="feat($ID): port $ID"
PRE_LAND="$pmain"
say "landing '$br' onto product '$DB' as one squashed commit (planner-ready, conformance green, non-stale)$([ "$DRY" = 1 ] && echo ' [dry-run]')"
[ "$DRY" = 1 ] || ROLLBACK_ARMED=1
run git -C "$PC" merge --squash "$br"          # apply work/<id>'s diff onto the mainline working tree
run git -C "$PC" commit -m "$MSG"              # the one gated act, inside this sanctioned script

# Gate 5 (LANDED BYTES, two-root merge RESULT): the product checkout now holds the merge result; re-run the
# FULL suite from the workbench against it. A commit added to work/<id> after its gate/review must not ride
# in unverified - the armed rollback resets the mainline and we refuse (push NOTHING) if the LANDED state is red.
if [ "$DRY" != 1 ]; then
	if ! bash tools/run-conformance.sh >/dev/null 2>&1; then
		fail "conformance check(s) RED at the product merge result - rolling product '$DB' back to $pmain, nothing pushed. Re-gate '$br' (see: bash tools/run-conformance.sh)."
	fi
fi
# Merge RESULT verified green (or dry-run): the squashed commit is good - DISARM the rollback and KEEP it.
# A later push failure leaves the verified commit in place (retry the push), exactly like integrate_land.
ROLLBACK_ARMED=0

[ "$PUSH" = 1 ] && run git -C "$PC" push "$REMOTE" "$DB"

newmain="$(git -C "$PC" rev-parse "$DB" 2>/dev/null || echo "$pmain")"
say "done - '$ID' landed on product '$DB'$([ "$PUSH" = 1 ] && echo " (pushed to $REMOTE)")$([ "$DRY" = 1 ] && echo ' [dry-run]')."
say "product.main_commit=$newmain - record this + integration.state: integrated in port/status/$ID.yaml, regenerate TRACE, then tear down the worktree (provision_worker.sh remove $ID)."
