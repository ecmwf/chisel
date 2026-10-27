#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# sync_merge.sh - the sanctioned resolution merge for /port-sync-with-base (step 2).
#
# A base->instance sync resolves automatically via the layer drivers named in .gitattributes, which
# this script sets for its own merge: merge=ours keeps the instance's file, merge=theirs takes the
# base's, so project files keep the instance side and methodology files take the base side. The
# merge is shape-checked so it can ONLY merge into a sync/<id> branch in a worktree - never `main`,
# never a real line.
#
#   sync_merge.sh <base-ref> [--worktree <path>]      run from the sync worktree (default --worktree .)
#
# It merges with --no-ff --no-commit, restores the project layer (every merge=ours path) to the
# pre-merge HEAD, and leaves the merge STAGED so the command can run conformance before sealing.
# Exit: 0 merged or already up to date (read the message); 1 a conflict outside the project layer
# (resolve per step 3); 2 refused.
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

top="$(git -C "$WT" rev-parse --show-toplevel)" || fail "cannot find the top of worktree '$WT'"
echo "sync_merge: merging $BASE into $branch (drivers auto-resolve: project=ours, methodology=theirs)..."
git -C "$top" -c merge.ours.driver=true -c 'merge.theirs.driver=cp -f %B %A' merge --no-ff --no-commit "$BASE"
rc=$?
if ! git -C "$top" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
	[ "$rc" -eq 0 ] || fail "git merge stopped before merging (exit $rc) - nothing merged; see its message above"
	echo "sync_merge: ALREADY UP TO DATE - nothing to sync; tear the worktree down (step 8)."
	exit 0
fi

# Restore the project layer to the pre-merge HEAD: the instance is its truth. The merge=ours driver
# acts only on a conflict, so a base change to a project file the instance left alone merges in
# clean, and a file the base added or deleted there goes through too. Every path the merge touched
# (staged or still unmerged) whose merge attribute is `ours` is checked out from HEAD without
# overlay: a file HEAD lacks is removed, and a conflict in the project layer is settled the same way.
layer="$(mktemp)"
trap 'rm -f "$layer"' EXIT
project_paths() {
	{ git -C "$top" diff --cached --name-only -z HEAD; git -C "$top" diff --name-only -z --diff-filter=U; } \
		| sort -zu | git -C "$top" check-attr -z --stdin merge \
		| while IFS= read -r -d '' path && IFS= read -r -d '' _ && IFS= read -r -d '' value; do
			[ "$value" = ours ] && printf '%s\0' "$path"
		done
	return 0
}
project_paths >"$layer"
if [ -s "$layer" ]; then
	git -C "$top" --literal-pathspecs checkout --no-overlay HEAD --pathspec-from-file="$layer" --pathspec-file-nul \
		|| fail "could not restore the project layer from HEAD - abort with 'git -C $top merge --abort'"
	echo "sync_merge: restored these project-layer files the base had changed (the instance keeps its own):"
	tr '\0' '\n' <"$layer" | sed 's/^/  /'
fi
[ -z "$(project_paths | tr -d '\0')" ] || fail "the project layer still differs from HEAD after the restore - abort with 'git -C $top merge --abort'"

unmerged="$(git -C "$top" diff --name-only --diff-filter=U)"
if [ -n "$unmerged" ]; then
	echo "sync_merge: CONFLICT outside the project layer - resolve these per /port-sync-with-base step 3, then commit:" >&2
	printf '%s\n' "$unmerged" | sed 's/^/  /' >&2
	exit 1
fi
echo "sync_merge: MERGED - project layer restored, the rest auto-resolved and STAGED, uncommitted. Run conformance, then commit."
exit 0
