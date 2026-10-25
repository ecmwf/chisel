#!/usr/bin/env bash
# sync_merge.sh - the sanctioned resolution merge for /port-sync-with-base (step 2).
#
# A base->instance sync resolves automatically via the layer drivers (merge.ours/theirs over
# .gitattributes): project files keep the instance side, methodology files take the base side. But the
# agent's blanket `git merge` deny - meant to keep an agent from moving a SHARED line ad-hoc - also
# blocks this legitimate, ephemeral resolution merge into a throwaway sync/<id> branch, so the sync
# stalls and asks the human to run it by hand. Like finalize.sh's push, the merge runs INSIDE this
# sanctioned script (bypassing the per-command deny), and it is shape-checked so it can ONLY merge into
# a sync/<id> branch in a worktree - never `main`, never a real line.
#
#   sync_merge.sh <base-ref> [--worktree <path>]      run from the sync worktree (default --worktree .)
#
# It merges with --no-ff --no-commit (a verifiable merge commit, left STAGED so the command can restore
# the project layer + run conformance before sealing). Exit: 0 merged-clean or already-up-to-date
# (read the message); 1 real conflict (a path matched no layer rule - resolve per step 3); 2 refused.
set -uo pipefail
fail() { echo "sync_merge: $*" >&2; exit 2; }

BASE=""; WT="."
while [ "$#" -gt 0 ]; do
	case "$1" in
		--worktree) [ "$#" -ge 2 ] || fail "--worktree needs a path"; WT="$2"; shift 2 ;;
		-*) fail "unknown flag: $1" ;;
		*) [ -z "$BASE" ] || fail "unexpected extra argument: $1"; BASE="$1"; shift ;;
	esac
done
[ -n "$BASE" ] || fail "usage: sync_merge.sh <base-ref> [--worktree <path>]   (e.g. upstream/main, from the sync worktree)"
[ -n "$WT" ] || fail "--worktree needs a path"
[ -d "$WT" ] || fail "worktree '$WT' not found"
git -C "$WT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail "'$WT' is not a git worktree"

# SHAPE GUARD: only ever merge into an ephemeral sync/<id> branch - never main or any real line.
branch="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)" || fail "cannot read the worktree's branch"
case "$branch" in sync/*) : ;; *) fail "refuse: worktree is on '$branch', not a sync/<id> branch - this merges ONLY into an ephemeral sync line, never main" ;; esac

git -C "$WT" rev-parse -q --verify "$BASE" >/dev/null 2>&1 || fail "base ref '$BASE' not found - run 'git fetch upstream' first"
# BASE must BE the base tip: this merges ONLY upstream/main, never an arbitrary ref slipped in as if it were the base.
git -C "$WT" rev-parse -q --verify refs/remotes/upstream/main >/dev/null 2>&1 || fail "no upstream/main ref - run 'git fetch upstream' first"
[ "$(git -C "$WT" rev-parse "$BASE")" = "$(git -C "$WT" rev-parse refs/remotes/upstream/main)" ] || fail "refuse: base ref '$BASE' is not the upstream/main tip - sync_merge merges only the base"
# A half-finished prior merge (MERGE_HEAD set) or any dirty state must be sorted out first - never stack onto one.
! git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 || fail "a merge is already in progress in '$WT' - resolve or 'git -C $WT merge --abort' first"
[ -z "$(git -C "$WT" status --porcelain 2>/dev/null)" ] || fail "worktree '$WT' is not clean (a prior merge in progress?) - resolve or 'git -C $WT merge --abort' first"

echo "sync_merge: merging $BASE into $branch (drivers auto-resolve: project=ours, methodology=theirs)..."
git -C "$WT" merge --no-ff --no-commit "$BASE"
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "sync_merge: merge stopped with conflicts (exit $rc) - the layer drivers could not auto-resolve a path (no layer rule in .gitattributes, or a rename/delete/binary/driver edge); resolve it per /port-sync-with-base step 3, then commit." >&2
	exit "$rc"
fi
if git -C "$WT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
	echo "sync_merge: MERGED - auto-resolved and STAGED, uncommitted. Proceed (restore the project layer, run conformance, then commit)."
else
	echo "sync_merge: ALREADY UP TO DATE - nothing to sync; tear the worktree down (step 9)."
fi
exit 0
