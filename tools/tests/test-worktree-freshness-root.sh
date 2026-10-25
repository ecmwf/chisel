#!/usr/bin/env bash
# Test where check-worktree-freshness.sh looks for claims and worktrees.
#
# The live claims (port/claims/, gitignored) and the per-piece worktrees (.worktrees/<id>) belong to
# the MAIN workbench checkout. Run from inside a linked worktree - a worker or reviewer running the
# suite where it works - the check used to anchor on that worktree's own top level, find no claims
# there and report "nothing to check": a silent pass while a stale worktree waited to be dispatched.
# It must resolve the main checkout from a linked worktree exactly as from the main checkout itself.
# On a git too old for `rev-parse --path-format` (it echoes the unknown option back and exits 0), it
# must fall back to the top level instead of turning that output into a root path. Revert the
# resolution and the linked-worktree case goes RED; drop the directory test on the git output and the
# old-git cases go RED (exit 2, cannot enter the root).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/conformance/check-worktree-freshness.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
	GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# KEEP_GOING=1 reports every failing case instead of stopping at the first (for a red demonstration).
failed=0
pass() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; [ -n "${KEEP_GOING:-}" ] || exit 1; failed=$((failed + 1)); }
expect() { # expect <exit-code> <label> <dir> [env assignments...]; EXPECT_OUT, if set, must appear
	local want="$1" label="$2" dir="$3" out rc
	shift 3
	set +e; out="$(cd "$dir" && env "$@" bash "$CHECK" 2>&1)"; rc=$?; set -e
	if [ "$rc" != "$want" ]; then
		bad "$label (expected exit $want, got $rc)"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	elif [ -n "${EXPECT_OUT:-}" ] && ! grep -qF -- "$EXPECT_OUT" <<<"$out"; then
		bad "$label (exit $rc as expected, but the output lacks '$EXPECT_OUT')"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	else
		pass "$label"
	fi
}

# A workbench with one live claim whose worktree falls one commit behind the mainline.
W="$TMP/wb"
git init -q -b main "$W"
printf '.worktrees/\nport/claims/\n' >"$W/.gitignore"
git -C "$W" add .gitignore
git -C "$W" commit -q -m "seed workbench"
mkdir -p "$W/port/claims"
printf 'id: alpha\nclaimant: operator\ncreated: 2026-01-01T00:00:00Z\nstate: active\n' >"$W/port/claims/alpha.yaml"
git -C "$W" worktree add -q -b work/alpha "$W/.worktrees/alpha"
mkdir -p "$W/.worktrees/alpha/sub"
git -C "$W" commit -q --allow-empty -m "advance mainline"

STALE="stale worktree - alpha: 1 commit(s) behind"
EXPECT_OUT="$STALE" expect 0 "from the main checkout the stale worktree is reported" "$W"
EXPECT_OUT="$STALE" expect 0 "from inside a linked worktree the same claims are examined" "$W/.worktrees/alpha"
EXPECT_OUT="$STALE" expect 0 "from a subdirectory of a linked worktree the same claims are examined" "$W/.worktrees/alpha/sub"

# A git older than 2.31: rev-parse does not know --path-format and prints it back as an argument.
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/oldgit"
cat >"$TMP/oldgit/git" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
	if [ "\$a" = --path-format=absolute ]; then printf '%s\n' "\$a"; else args+=("\$a"); fi
done
exec "$REAL_GIT" "\${args[@]}"
EOF
chmod +x "$TMP/oldgit/git"
OLD_PATH="PATH=$TMP/oldgit:$PATH"
EXPECT_OUT="$STALE" expect 0 "old git: from the main checkout the stale worktree is still reported" "$W" "$OLD_PATH"
EXPECT_OUT="nothing to check" expect 0 "old git: a linked worktree falls back to its own top level, not a garbage root" "$W/.worktrees/alpha" "$OLD_PATH"

[ "$failed" -eq 0 ] || { printf '# test-worktree-freshness-root: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-worktree-freshness-root: all assertions passed\n'
