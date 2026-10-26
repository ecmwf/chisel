#!/usr/bin/env bash
# integrate_bringup.sh - push a piece onto the product's BRING-UP PREVIEW branch, so the target repo
# visibly fills up and is buildable DURING bring-up, before pieces are R1-proven onto the mainline.
#
# The product MAINLINE is the certified, shipped line: only R1-proven, independently-reviewed pieces
# land there (integrate_product.sh). Early in a port that means the mainline is empty for a while
# ("0% proven, all work on branches") and you cannot see or build the target taking shape. This lands a
# piece's product work branch onto a separate `bring-up` branch instead - a PREVIEW, explicitly NOT the
# proven mainline - so you can clone the product, check out `bring-up`, build it, and watch progress. A
# piece graduates to the mainline later, unchanged, when it is R1-proven (integrate_product.sh).
#
# The bar is RELAXED on purpose - NO R1, NO proven status, NO planner-readiness - but it is NOT zero: the
# FULL conformance suite must be green at HEAD AND on the merge RESULT (so the preview at least BUILDS
# and passes the structural checks - naming, anchors, index helpers, product invisibility), rolled back
# on red. So `bring-up` is real, buildable code-in-progress, just not certified faithful.
#
# It pushes from INSIDE this script, bypassing the per-agent `git push` deny exactly as
# integrate_product.sh does - and only ever a conformance-green preview to the `bring-up` branch, NEVER
# the mainline.
#
# FAIL-CLOSED (refuse, exit 2, merge/push NOTHING) unless ALL hold:
#  - a two-repo product is wired (port/product.yaml + a present checkout).
#  - a product `work/<id>` branch exists.
#  - the FULL conformance suite is green at HEAD (both roots), and AGAIN at the bring-up merge RESULT.
#
#   integrate_bringup.sh <trace-id> [--branch bring-up] [--message <msg>] [--remote origin] [--no-push] [--dry-run]
# Exit: 0 landed (squash-merged onto the bring-up preview branch + pushed); 2 refused.
set -euo pipefail

fail() { echo "integrate-bringup: $*" >&2; exit 2; }
say()  { echo "integrate-bringup: $*"; }
run()  { echo "  + $*"; [ "$DRY" = 1 ] || "$@"; }

# Crash-safe rollback: from the moment we mutate the bring-up branch until the merge RESULT is verified
# green, ARM a rollback so ANY exit (failed git command, signal/kill) resets the bring-up branch to its
# pre-land commit. The MAINLINE is never touched by this script.
ROLLBACK_ARMED=0; PC=""; PRE_LAND=""; BR_PREV=""
rollback_bringup() {
	[ "$ROLLBACK_ARMED" = 1 ] || return 0
	echo "integrate-bringup: land did not complete verified - rolling bring-up back to $PRE_LAND" >&2
	git -C "$PC" reset --hard "$PRE_LAND" >/dev/null 2>&1 \
		|| echo "integrate-bringup: WARNING - rollback FAILED; reset it by hand: git -C '$PC' reset --hard $PRE_LAND" >&2
}
trap rollback_bringup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ID=""; BUB="bring-up"; REMOTE="origin"; PUSH=1; DRY=0; MSG=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--branch)  [ "$#" -ge 2 ] || fail "--branch needs a name"; BUB="$2"; shift 2 ;;
		--message) [ "$#" -ge 2 ] || fail "--message needs a commit message"; MSG="$2"; shift 2 ;;
		--remote)  [ "$#" -ge 2 ] || fail "--remote needs a remote name"; REMOTE="$2"; shift 2 ;;
		--no-push) PUSH=0; shift ;;
		--dry-run) DRY=1; shift ;;
		--*)       fail "unknown option: $1" ;;
		*)         [ -z "$ID" ] || fail "only one <trace-id> allowed (got '$ID' and '$1')"; ID="$1"; shift ;;
	esac
done

[ -n "$ID" ] || fail "usage: integrate_bringup.sh <trace-id> [--branch bring-up] [--message <msg>] [--remote origin] [--no-push] [--dry-run]"
case "$ID" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "id '$ID' must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes)" ;; esac
case "$BUB" in *[!A-Za-z0-9._/-]*|""|/*|*/|-*|*..*) fail "branch '$BUB' must be a plain branch name" ;; esac
case "$REMOTE" in ""|-*|*:*|*/*|*" "*) fail "remote '$REMOTE' must be a configured remote name" ;; esac

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../conformance/lib/product-root.sh"
wb="$(_pr_repo_root)" || fail "not inside a git repository"
cd "$wb"

# Check 0 (TWO-REPO WIRED): resolve the product checkout, fail-closed on single-repo / placeholder / absent.
set +e; PC="$(default_product_root)"; PRC=$?; set -e
case "$PRC" in
	0)  : ;;
	10) fail "single-repo (no port/product.yaml) - there is no separate product to preview" ;;
	2)  fail "$(pr_checkout_problem) - fix port/product.yaml first (UNRELIABLE)" ;;
	*)  fail "cannot resolve the product checkout" ;;
esac
[ -d "$PC" ] || fail "product checkout '$PC' is absent - clone it first (tools/checkout-product.sh)"
git -C "$PC" rev-parse --show-toplevel >/dev/null 2>&1 || fail "product checkout '$PC' is not a git repo"

DB="$(_pr_default_branch "$wb")" || fail "cannot read default_branch from port/product.yaml (see above) - refusing to guess the mainline (UNRELIABLE)"
[ "$BUB" != "$DB" ] || fail "--branch must NOT be the proven mainline '$DB' - this is the PREVIEW line; proven pieces land on '$DB' via integrate_product.sh"

[ -z "$(git -C "$PC" status --porcelain)" ] || fail "product working tree is dirty - commit/clean it first"

# Check 1 (WORK BRANCH EXISTS): the piece's product work branch.
br="work/$ID"
git -C "$PC" rev-parse -q --verify "refs/heads/$br" >/dev/null 2>&1 || fail "branch '$br' not found in the product repo ('$PC')"

if [ "$PUSH" = 1 ]; then
	git -C "$PC" remote get-url "$REMOTE" >/dev/null 2>&1 || fail "product remote '$REMOTE' is not configured (in '$PC')"
fi

# Put the product checkout on the bring-up preview branch (create it from the mainline if absent). The
# preview workflow tracks `bring-up`; proven mainline lands re-check-out '$DB'.
BR_PREV="$(git -C "$PC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
if git -C "$PC" rev-parse -q --verify "refs/heads/$BUB" >/dev/null 2>&1; then
	run git -C "$PC" checkout "$BUB"
else
	say "bring-up branch '$BUB' does not exist - creating it from '$DB'"
	run git -C "$PC" checkout -b "$BUB" "$DB"
fi
[ "$DRY" = 1 ] || PRE_LAND="$(git -C "$PC" rev-parse "$BUB")"

# Check 2 (TRUST FLOOR, both roots): full conformance green at HEAD (the preview state) before mutating.
bash tools/run-conformance.sh >/dev/null 2>&1 \
	|| fail "conformance check(s) RED at HEAD - never land over a red check; fix them first (see: bash tools/run-conformance.sh)"

[ -n "$MSG" ] || MSG="bring-up($ID): preview $ID (NOT proven - R0/in-progress)"
say "landing '$br' onto the PREVIEW branch '$BUB' (conformance-checked; NOT the mainline '$DB')$([ "$DRY" = 1 ] && echo ' [dry-run]')"
[ "$DRY" = 1 ] || ROLLBACK_ARMED=1
run git -C "$PC" merge --squash "$br"
run git -C "$PC" commit -m "$MSG"

# Check 3 (PREVIEW BUILDS, two-root merge RESULT): re-run the FULL suite against the bring-up merge result;
# a preview that does not even build/pass the structural checks is rolled back and refused (push NOTHING).
if [ "$DRY" != 1 ]; then
	if ! bash tools/run-conformance.sh >/dev/null 2>&1; then
		fail "conformance check(s) RED at the bring-up merge result - rolling '$BUB' back to $PRE_LAND, nothing pushed (see: bash tools/run-conformance.sh)."
	fi
fi
ROLLBACK_ARMED=0

[ "$PUSH" = 1 ] && run git -C "$PC" push "$REMOTE" "$BUB"

newtip="$(git -C "$PC" rev-parse "$BUB" 2>/dev/null || echo "$PRE_LAND")"
say "done - '$ID' on PREVIEW branch '$BUB'=$newtip$([ "$PUSH" = 1 ] && echo " (pushed to $REMOTE)")$([ "$DRY" = 1 ] && echo ' [dry-run]')."
say "Build the target so far: clone the product, 'git checkout $BUB'. This is a PREVIEW, not the proven mainline '$DB' - the piece graduates there when it is R1-proven (integrate_product.sh)."
