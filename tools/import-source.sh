#!/usr/bin/env bash
# Import a cloned SOURCE tree into the repository (Phase 0 source-import helper).
#
# A git clone committed as-is becomes a broken gitlink, not a directory of files
# (the nested-.git trap). This script turns a clone placed under source/ into
# plain imported bytes: it records the upstream provenance, refuses to proceed if
# the clone is dirty or carries submodules (either would make the recorded commit
# misrepresent the imported bytes), then removes the nested .git and verifies that
# none remains within the subtree.
#
# It never stages or commits and makes no MUTATING git call on the outer repo; it
# only runs a read-only completeness check (git add -n / git check-ignore) so the
# caller can see whether a .gitignore would silently drop upstream-tracked files
# (the source's own .gitignore becomes a plain file once imported and still
# applies). The caller transcribes the printed provenance into
# port/plan/00-charter.md and port/TRACE.yaml, then runs `git add` (one writer per
# worktree; git operations are the human's).
#
# Note on the post-removal check: it scopes to the subtree (find ... -name .git),
# never `git rev-parse` inside the dir, because the imported tree lives inside the
# repository's own worktree and git would walk upward and find the OUTER .git,
# reporting a false failure.
#
# Usage:   tools/import-source.sh <path-to-cloned-source-dir>
# Example: tools/import-source.sh source/<program>
#
# Exit-code contract: 0 = imported (no nested .git remains in the subtree),
#                     2 = refused or error (nothing removed, or the check failed).
set -euo pipefail

fail() {
	echo "ERROR: $*" >&2
	exit 2
}

[ "$#" -eq 1 ] || fail "usage: tools/import-source.sh <path-to-cloned-source-dir>"
dir="${1%/}"
[ -d "$dir" ] || fail "not a directory: $dir"
[ -d "$dir/.git" ] || fail "no nested .git in '$dir': not a clone (already imported?)"

# Provenance MUST be captured before .git is removed (afterwards it is unqueryable).
echo "=== PROVENANCE for $dir (record in charter section 2 + TRACE meta) ==="
echo "captured: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "remote(s):"
git -C "$dir" remote -v | sed 's/^/  /' || fail "cannot read remotes"
commit="$(git -C "$dir" rev-parse HEAD)" || fail "cannot read HEAD"
echo "commit:   $commit"
echo "branch:   $(git -C "$dir" rev-parse --abbrev-ref HEAD)"
echo "describe: $(git -C "$dir" describe --tags --always 2>/dev/null || echo '(no tag)')"
[ -f "$dir/VERSION" ] && echo "VERSION:  $(cat "$dir/VERSION")"
tracked="$(git -C "$dir" ls-files | wc -l | tr -d ' ')"
echo "tracked:  $tracked files in the upstream index at $commit"
echo "================================================================="

# Refuse on conditions that would make the recorded commit misrepresent the bytes.
[ -f "$dir/.gitmodules" ] && fail "'$dir' has submodules (.gitmodules); import them explicitly first"
[ -z "$(git -C "$dir" status --porcelain)" ] || fail "'$dir' is dirty; imported bytes would not match $commit"

# Remove the nested .git so the tree commits as files, then verify (subtree-scoped).
rm -rf "$dir/.git"
remaining="$(find "$dir" -name .git -print)"
[ -z "$remaining" ] || fail "nested .git still present after removal: $remaining"

# Completeness: a .gitignore (the source's own, now a plain file, or the host's)
# can shadow upstream-tracked files when they are re-added, silently dropping
# SOURCE. Compare the upstream tracked count against what the host would stage.
stage_hint="git add $dir"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	addable="$(git add -n -- "$dir" 2>/dev/null | wc -l | tr -d ' ')"
	if [ "$addable" != "$tracked" ]; then
		echo "WARNING: $tracked files tracked upstream, but 'git add' would stage $addable."
		echo "         A .gitignore is shadowing these upstream-tracked files:"
		find "$dir" \( -type f -o -type l \) | git check-ignore --stdin -v 2>/dev/null | sed 's/^/           /'
		echo "         Stage the SOURCE faithfully with the force flag instead."
		stage_hint="git add -f $dir"
	else
		echo "completeness OK: all $tracked upstream-tracked files are stageable."
	fi
else
	echo "NOTE: not inside a git work tree; verify completeness manually ($tracked files expected)."
fi

echo "OK: '$dir' imported at $commit (nested .git removed)."
echo "Next: record provenance above in charter section 2 + TRACE meta, then '$stage_hint'."
