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
# applies). It SAVES the provenance to port/provenance/<name>.yaml (durable - the commit
# is unqueryable once .git is gone); the caller pins charter section 2 + port/TRACE.yaml
# meta.source_commit FROM that file, then runs `git add` (one writer per worktree; git
# operations are the human's).
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

# SAFETY: `rm -rf "$dir/.git"` below is destructive. Refuse anything that is not a SOURCE
# clone strictly under source/, so 'tools/import-source.sh .' (or any path outside source/)
# can never delete the workbench's own .git, or another repo's. Three guards:
#   (a) $dir must be its OWN clone - its toplevel resolves to itself, not a parent worktree;
#   (b) $dir must not be the outer repository root;
#   (c) $dir must live strictly under <repo>/source/.
dir_abs="$(cd "$dir" && pwd -P)" || fail "cannot resolve '$dir'"
dir_top="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$dir_top" ] && dir_top="$(cd "$dir_top" && pwd -P)"
[ "$dir_top" = "$dir_abs" ] || fail "'$dir' is not its own clone (its .git belongs to a parent repo); SOURCE must be a standalone clone under source/"
outer_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$outer_top" ]; then
	outer_top="$(cd "$outer_top" && pwd -P)"
	[ "$dir_abs" != "$outer_top" ] || fail "'$dir' is the repository root, not a SOURCE clone"
	case "$dir_abs/" in
		"$outer_top"/source/*) : ;;
		*) fail "'$dir' is not under '$outer_top/source/' - SOURCE is imported only into source/" ;;
	esac
fi

# Provenance MUST be captured before .git is removed (afterwards it is unqueryable).
captured="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
commit="$(git -C "$dir" rev-parse HEAD)" || fail "cannot read HEAD"
branch="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
describe="$(git -C "$dir" describe --tags --always 2>/dev/null || echo '(no tag)')"
remote_url="$(git -C "$dir" remote get-url origin 2>/dev/null || git -C "$dir" remote -v | awk 'NR==1{print $2}')"
tracked="$(git -C "$dir" ls-files | wc -l | tr -d ' ')"
remotes="$(git -C "$dir" remote -v)" || fail "cannot read remotes"
# Run by chisel-init, which reports the import in one line, the full record stays in the file below.
if [ -z "${CHISEL_INIT:-}" ]; then
	echo "=== PROVENANCE for $dir (saved to port/provenance/; also for charter section 2 + TRACE meta) ==="
	echo "captured: $captured"
	echo "remote(s):"
	sed 's/^/  /' <<<"$remotes"
	echo "commit:   $commit"
	echo "branch:   $branch"
	echo "describe: $describe"
	[ -f "$dir/VERSION" ] && echo "VERSION:  $(cat "$dir/VERSION")"
	echo "tracked:  $tracked files in the upstream index at $commit"
	echo "================================================================="
fi

# Refuse on conditions that would make the recorded commit misrepresent the bytes.
[ -f "$dir/.gitmodules" ] && fail "'$dir' has submodules (.gitmodules); import them explicitly first"
[ -z "$(git -C "$dir" status --porcelain)" ] || fail "'$dir' is dirty; imported bytes would not match $commit"

# Persist provenance durably. The printed block above is ephemeral; a fresh /port-sprint-start
# session must pin charter section 2 + TRACE meta.source_commit WITHOUT re-asking for a URL/commit
# the import already had (and which is unqueryable once .git is gone). One file per imported source.
name="$(basename "$dir_abs")"
if [ -n "$outer_top" ]; then
	prov_dir="$outer_top/port/provenance"
	prov_rel="port/provenance/$name.yaml"
	path_rel="${dir_abs#"$outer_top"/}"
else
	prov_dir="$dir_abs/../provenance"
	prov_rel="$prov_dir/$name.yaml"
	path_rel="$dir_abs"
fi
mkdir -p "$prov_dir"
{
	echo "# Provenance of the imported SOURCE tree $path_rel, captured by tools/import-source.sh BEFORE"
	echo "# the nested .git was stripped (afterwards it is unqueryable). Durable record so Phase 0 pins"
	echo "# charter section 2 + TRACE meta.source_commit from here - never by asking. One per source."
	echo "name: $name"
	echo "path: $path_rel"
	echo "remote: $remote_url"
	echo "commit: $commit"
	echo "branch: $branch"
	echo "describe: \"$describe\""
	echo "tracked_files: $tracked"
	echo "imported_at: \"$captured\""
} >"$prov_dir/$name.yaml"
[ -n "${CHISEL_INIT:-}" ] || echo "provenance saved: $prov_rel"

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
		[ -n "${CHISEL_INIT:-}" ] || echo "completeness OK: all $tracked upstream-tracked files are stageable."
	fi
else
	echo "NOTE: not inside a git work tree; verify completeness manually ($tracked files expected)."
fi

[ -n "${CHISEL_INIT:-}" ] || echo "OK: '$dir' imported at $commit (nested .git removed)."
# Run by chisel-init, the next step is its own (the first sprint commits the setup).
[ -n "${CHISEL_INIT:-}" ] || echo "Next: pin charter section 2 + TRACE meta.source_commit from $prov_rel (saved), then '$stage_hint'."
