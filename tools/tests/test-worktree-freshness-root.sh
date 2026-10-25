#!/usr/bin/env bash
# Test where check-worktree-freshness.sh looks for claims and worktrees.
#
# The live claims (port/claims/, gitignored) and the per-piece worktrees (.worktrees/<id>) belong to
# the MAIN workbench checkout. Run from inside a linked worktree - a worker or reviewer running the
# suite where it works - the check used to anchor on that worktree's own top level, find no claims
# there and report "nothing to check": a silent pass while a stale worktree waited to be dispatched.
#
# Git records no path for the main checkout: the parent of the common git dir, and `git worktree
# list` (the common git dir minus a trailing /.git), name the git dir or the directory holding it,
# which is not the checkout in a submodule or --separate-git-dir layout (including one whose git dir
# is itself named .git). So the check takes the main checkout as the top level of the main working
# tree itself, or - from a linked worktree at <root>/.worktrees/<name>, the layout
# provision_worker.sh creates and the check reads - as <root>, once git confirms <root> is a main
# working tree with the same common git dir. Every other case (a linked worktree elsewhere, a bare
# main repository, a git dir that does not resolve) is UNRELIABLE (exit 2), never a skip. The
# resolution uses only plain --git-dir/--git-common-dir/--show-toplevel, so a git without
# --path-format (before 2.31) resolves the same root.
#
# Revert the resolution and the linked-worktree cases go RED. Resolve through --path-format with a
# fall back to the worktree's own top level and the old-git linked cases go RED (a silent "nothing to
# check"). Take the parent of the common git dir - even only when that dir is named .git - and the
# external .git separate-git-dir linked case goes RED (a silent skip of the real claim), as do the linked
# worktree outside .worktrees/ and the bare main repository.
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

# workbench <dir> <id> [git-init options...]: a workbench with one live claim <id> whose linked
# worktree <dir>/.worktrees/<id> falls one commit behind the mainline.
workbench() {
	local dir="$1" id="$2"
	shift 2
	git init -q -b main "$@" "$dir"
	printf '.worktrees/\nport/claims/\n' >"$dir/.gitignore"
	git -C "$dir" add .gitignore
	git -C "$dir" commit -q -m "seed workbench"
	mkdir -p "$dir/port/claims"
	printf 'id: %s\nclaimant: operator\ncreated: 2026-01-01T00:00:00Z\nstate: active\n' "$id" >"$dir/port/claims/$id.yaml"
	git -C "$dir" worktree add -q -b "work/$id" "$dir/.worktrees/$id"
	mkdir -p "$dir/.worktrees/$id/sub"
	git -C "$dir" commit -q --allow-empty -m "advance mainline"
}
stale() { printf 'stale worktree - %s: 1 commit(s) behind' "$1"; }

# A stand-in git. FAKE_GIT=old: rev-parse knows neither --path-format (git 2.31) nor
# --absolute-git-dir (git 2.13), so it echoes them back and ignores them, as an older git does with an
# unknown option. FAKE_GIT=nocommon: --git-common-dir names a directory that does not exist.
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/fakegit"
cat >"$TMP/fakegit/git" <<EOF
#!/usr/bin/env bash
args=()
for a in "\$@"; do
	case "\${FAKE_GIT:-}:\$a" in
		old:--path-format=*|old:--absolute-git-dir) printf '%s\n' "\$a" ;;
		nocommon:--git-common-dir) printf '%s\n' "$TMP/no-such-dir/.git"; exit 0 ;;
		*) args+=("\$a") ;;
	esac
done
exec "$REAL_GIT" "\${args[@]}"
EOF
chmod +x "$TMP/fakegit/git"
OLD="PATH=$TMP/fakegit:$PATH"

# ---- the ordinary layout: <root>/.git ---------------------------------------------------------------
W="$TMP/wb"
workbench "$W" alpha
EXPECT_OUT="$(stale alpha)" expect 0 "from the main checkout the stale worktree is reported" "$W"
EXPECT_OUT="$(stale alpha)" expect 0 "from a subdirectory of the main checkout the stale worktree is reported" "$W/port"
EXPECT_OUT="$(stale alpha)" expect 0 "from inside a linked worktree the same claims are examined" "$W/.worktrees/alpha"
EXPECT_OUT="$(stale alpha)" expect 0 "from a subdirectory of a linked worktree the same claims are examined" "$W/.worktrees/alpha/sub"
EXPECT_OUT="$(stale alpha)" expect 0 "old git: from the main checkout the stale worktree is reported" "$W" "$OLD" FAKE_GIT=old
EXPECT_OUT="$(stale alpha)" expect 0 "old git: from inside a linked worktree the same claims are examined" "$W/.worktrees/alpha" "$OLD" FAKE_GIT=old
EXPECT_OUT="$(stale alpha)" expect 0 "old git: from a subdirectory of a linked worktree the same claims are examined" "$W/.worktrees/alpha/sub" "$OLD" FAKE_GIT=old
EXPECT_OUT="UNRELIABLE" expect 2 "an unresolvable common git dir is UNRELIABLE from the main checkout" "$W" "$OLD" FAKE_GIT=nocommon
EXPECT_OUT="UNRELIABLE" expect 2 "an unresolvable common git dir is UNRELIABLE from a linked worktree" "$W/.worktrees/alpha" "$OLD" FAKE_GIT=nocommon
# A linked worktree outside <root>/.worktrees/ gives no position to read the main checkout from.
git -C "$W" worktree add -q -b elsewhere "$TMP/elsewhere"
EXPECT_OUT="UNRELIABLE" expect 2 "a linked worktree outside .worktrees/ is UNRELIABLE" "$TMP/elsewhere"

# ---- --separate-git-dir whose git dir is itself named .git, outside the workbench ----------------------
# The common git dir is <meta>/.git: its parent <meta> holds no claims, and `git worktree list` names
# <meta> as the main worktree too, yet <meta> with its .git looks to git exactly like a checkout.
mkdir -p "$TMP/meta"
workbench "$TMP/sepdot" beta --separate-git-dir "$TMP/meta/.git"
EXPECT_OUT="$(stale beta)" expect 0 "separate git dir named .git: from the main checkout the stale worktree is reported" "$TMP/sepdot"
EXPECT_OUT="$(stale beta)" expect 0 "separate git dir named .git: from a linked worktree the same claims are examined" "$TMP/sepdot/.worktrees/beta"
EXPECT_OUT="$(stale beta)" expect 0 "separate git dir named .git, old git: from a linked worktree the same claims are examined" "$TMP/sepdot/.worktrees/beta/sub" "$OLD" FAKE_GIT=old

# ---- --separate-git-dir with any other name ------------------------------------------------------------
workbench "$TMP/sepother" gamma --separate-git-dir "$TMP/other-meta"
EXPECT_OUT="$(stale gamma)" expect 0 "separate git dir: from the main checkout the stale worktree is reported" "$TMP/sepother"
EXPECT_OUT="$(stale gamma)" expect 0 "separate git dir: from a linked worktree the same claims are examined" "$TMP/sepother/.worktrees/gamma"

# ---- the submodule layout: the git dir lives in a superproject's .git/modules/<name> --------------------
# The parent of the common git dir is inside the superproject's git dir, which resolves to the
# superproject: no claims there.
SUPER="$TMP/super"
git init -q -b main "$SUPER"
git -C "$SUPER" commit -q --allow-empty -m "seed superproject"
mkdir -p "$SUPER/.git/modules"
workbench "$SUPER/wb" delta --separate-git-dir "$SUPER/.git/modules/wb"
EXPECT_OUT="$(stale delta)" expect 0 "submodule layout: from the main checkout the stale worktree is reported" "$SUPER/wb"
EXPECT_OUT="$(stale delta)" expect 0 "submodule layout: from a linked worktree the same claims are examined" "$SUPER/wb/.worktrees/delta"
EXPECT_OUT="$(stale delta)" expect 0 "submodule layout, old git: from a linked worktree the same claims are examined" "$SUPER/wb/.worktrees/delta" "$OLD" FAKE_GIT=old

# ---- a bare main repository: there is no main checkout to hold the claims ------------------------------
# The bare repository sits at <dir>/.git with a linked worktree at <dir>/.worktrees/<id>, so neither
# the name of the common git dir nor the position of the worktree tells it apart from a checkout.
B="$TMP/bare"
git init -q --bare -b main "$B/.git"
tree="$(git -C "$B/.git" mktree </dev/null)"
git -C "$B/.git" update-ref refs/heads/main "$(git -C "$B/.git" commit-tree "$tree" -m "seed")"
mkdir -p "$B/port/claims"
printf 'id: eps\nclaimant: operator\ncreated: 2026-01-01T00:00:00Z\nstate: active\n' >"$B/port/claims/eps.yaml"
git -C "$B/.git" worktree add -q -b work/eps "$B/.worktrees/eps" main
git -C "$B/.git" update-ref refs/heads/main "$(git -C "$B/.git" commit-tree "$tree" -p main -m "advance")"
EXPECT_OUT="UNRELIABLE" expect 2 "a bare main repository is UNRELIABLE from its linked worktree" "$B/.worktrees/eps"

[ "$failed" -eq 0 ] || { printf '# test-worktree-freshness-root: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-worktree-freshness-root: all assertions passed\n'
