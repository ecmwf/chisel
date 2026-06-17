#!/usr/bin/env bash
# contribute.sh - the sanctioned auto-PR path for /port-contribute-to-base.
#
# /port-contribute-to-base builds a methodology-only contribution branch off the base's main and
# drafts a genericized PR body; this performs the one privileged step an agent otherwise cannot
# (git push is denied) and opens the PR, so the human gets a PR link to review instead of a pair of
# commands to paste. It is the contribute analogue of finalize.sh's auto-land: a shape-verified,
# sanctioned push - it NEVER merges. Landing the proposal onto the shared base stays the human's act
# (review + merge on the PR is the curation checkpoint; that is where genericization is judged).
#
# The push runs INSIDE this script, so it bypasses the per-command `git push` deny exactly as
# finalize.sh does - and it is shape-verified first so it cannot push arbitrary or project-layer work
# to the shared base: the branch must be a contribute/<id> built on <remote>/main whose every changed
# file is METHODOLOGY-layer (no merge=ours project file leaks upstream).
#
#   contribute.sh --branch <contribute/id> --title <t> --body-file <path> [--remote upstream]
#                 [--base main] [--no-pr] [--dry-run]
#
# Exit: 0 pushed (+ PR opened/updated); 2 refused (a guard tripped) - on refusal nothing is pushed.
set -euo pipefail

fail() { echo "contribute: $*" >&2; exit 2; }
say()  { echo "contribute: $*"; }
run()  { echo "  + $*"; [ "$DRY" = 1 ] || "$@"; }

BRANCH=""; TITLE=""; BODY=""; REMOTE="upstream"; BASE="main"; PR=1; DRY=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--branch)    BRANCH="${2:-}"; shift 2 ;;
		--title)     TITLE="${2:-}"; shift 2 ;;
		--body-file) BODY="${2:-}"; shift 2 ;;
		--remote)    REMOTE="${2:-}"; shift 2 ;;
		--base)      BASE="${2:-}"; shift 2 ;;
		--no-pr)     PR=0; shift ;;
		--dry-run)   DRY=1; shift ;;
		*)           fail "unknown argument: $1" ;;
	esac
done

[ -n "$BRANCH" ] || fail "usage: contribute.sh --branch <contribute/id> --title <t> --body-file <path> [--no-pr]"
case "$BRANCH" in contribute/*) : ;; *) fail "branch '$BRANCH' must be a contribute/<id> branch (the sanctioned contribution namespace)" ;; esac
case "$BRANCH" in *" "*) fail "branch '$BRANCH' contains whitespace" ;; esac
# REMOTE/BASE are configured names, never a URL/path/dash (no pushing to an arbitrary remote).
case "$REMOTE" in ""|-*|*:*|*/*|*" "*) fail "remote '$REMOTE' must be a configured remote name" ;; esac
case "$BASE"   in ""|-*|*" "*) fail "base '$BASE' must be a simple branch name" ;; esac
if [ "$PR" = 1 ]; then
	[ -n "$TITLE" ] || fail "--title is required to open the PR (or pass --no-pr to push only)"
	[ -n "$BODY" ]  || fail "--body-file is required to open the PR (or pass --no-pr to push only)"
	[ -f "$BODY" ]  || fail "--body-file '$BODY' does not exist"
fi

top="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git repository"
cd "$top"

git rev-parse -q --verify "refs/heads/$BRANCH" >/dev/null 2>&1 || fail "branch '$BRANCH' not found locally"
git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "remote '$REMOTE' is not configured - add it (it points at the base repo)"
BASEREF="refs/remotes/$REMOTE/$BASE"
git rev-parse -q --verify "$BASEREF" >/dev/null 2>&1 || fail "$REMOTE/$BASE is unknown - run 'git fetch $REMOTE' first"

# The branch must be built ON the current base tip (so the PR is a clean set of contribution commits,
# not a stale or unrelated branch).
git merge-base --is-ancestor "$BASEREF" "$BRANCH" \
	|| fail "'$BRANCH' is not built on $REMOTE/$BASE - rebase it onto $REMOTE/$BASE (the contribute command builds off upstream/main)"
if git diff --quiet "$BASEREF..$BRANCH"; then fail "'$BRANCH' has no commits over $REMOTE/$BASE - nothing to contribute"; fi

# SHAPE GATE: a contribution carries METHODOLOGY-layer changes only. Every changed file must NOT be a
# project-owned (merge=ours) path, so no instance/project content leaks into the shared base. This is
# the mechanical half of "genericize ruthlessly"; the prose is judged by the human on the PR.
while IFS= read -r f; do
	[ -n "$f" ] || continue
	[ "$(git check-attr merge -- "$f" | sed -E 's/.*: //')" != "ours" ] \
		|| fail "'$BRANCH' changes project-layer file '$f' - the base accepts methodology-layer changes only (genericize it, or leave it in the instance)"
done < <(git diff --name-only "$BASEREF..$BRANCH")

# Derive the base repo slug (owner/name) from the remote URL, for `gh --repo`.
slug=""
if [ "$PR" = 1 ]; then
	url="$(git remote get-url "$REMOTE")"; url="${url%.git}"
	case "$url" in
		*github.com:*) slug="${url##*github.com:}" ;;
		*github.com/*) slug="${url##*github.com/}" ;;
	esac
	[ -n "$slug" ] || fail "cannot derive a github owner/name from $REMOTE url '$url' - open the PR by hand, or pass --no-pr"
fi

say "contributing '$BRANCH' -> $REMOTE/$BASE${slug:+ (PR to $slug)}$([ "$DRY" = 1 ] && echo ' [dry-run]')"
run git push -u "$REMOTE" "$BRANCH"

if [ "$PR" = 1 ]; then
	# Re-runnable: if a PR for this head already exists, the push above updated it - just report it.
	existing=""
	[ "$DRY" = 1 ] || existing="$(gh pr list --repo "$slug" --head "$BRANCH" --state open --json url --jq '.[0].url' 2>/dev/null || true)"
	if [ -n "$existing" ]; then
		say "PR already open (updated by the push): $existing"
	else
		run gh pr create --repo "$slug" --base "$BASE" --head "$BRANCH" --title "$TITLE" --body-file "$BODY"
	fi
fi

done_msg="done - pushed"
if [ "$PR" = 1 ]; then done_msg="$done_msg, PR ready"; fi
done_msg="$done_msg. Review and MERGE it on the base yourself (the merge stays human); then /port-sync-with-base to receive the canonical form."
if [ "$DRY" = 1 ]; then done_msg="$done_msg [dry-run]"; fi
say "$done_msg"
