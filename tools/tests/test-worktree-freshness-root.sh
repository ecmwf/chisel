#!/usr/bin/env bash
# Test where check-worktree-freshness.sh looks for claims and worktrees.
#
# The live claims (port/claims/, gitignored) and the per-piece worktrees (.worktrees/<id>) belong to
# the MAIN workbench checkout. Run from inside a linked worktree - a worker or reviewer running the
# suite where it works - the check used to anchor on that worktree's own top level, find no claims
# there and report "nothing to check": a silent pass while a stale worktree waited to be dispatched.
#
# The check now reads them where provision_worker.sh writes them: the parent of the common git dir
# (_pr_main_root in lib/product-root.sh, which provision_worker.sh's _pr_repo_root also uses), the
# same from the main checkout, a subdirectory, and any linked worktree. A common git dir that does
# not resolve is UNRELIABLE (exit 2), never a skip. The helper resolves plain --git-common-dir itself:
# --path-format needs git 2.31, and an older git echoes it back as output - which also broke the
# writer's root, so the old-git cases cover both sides.
#
# Revert the resolution and the linked-worktree cases go RED (a silent "nothing to check").
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
# A linked worktree outside <root>/.worktrees/ (an editor's or a tool's own) names the same common git
# dir, so it reads the main checkout's claims too.
git -C "$W" worktree add -q -b elsewhere "$TMP/elsewhere"
EXPECT_OUT="$(stale alpha)" expect 0 "from a linked worktree outside .worktrees/ the same claims are examined" "$TMP/elsewhere"

# ---- old git: the writer resolves the same root ---------------------------------------------------------
LIB="$ROOT/tools/conformance/lib/product-root.sh"
got="$(cd "$W/.worktrees/alpha" && env "$OLD" FAKE_GIT=old bash -c 'source "$1" && _pr_repo_root' _ "$LIB")"
if [ "$got" = "$(cd "$W" && pwd -P)" ]; then
	pass "old git: provision_worker.sh's root (_pr_repo_root) is the main checkout"
else
	bad "old git: provision_worker.sh's root (_pr_repo_root) is '$got', not the main checkout"
fi

# ---- reader = writer: --separate-git-dir ----------------------------------------------------------------
# provision_worker.sh puts the claims and worktrees under _pr_repo_root. Under --separate-git-dir that is
# the directory holding the git dir, not the checkout - unusual, but the check must read where the
# claims are written, from the checkout and from the linked worktree alike.
S="$TMP/sep"
mkdir -p "$TMP/meta"
git init -q -b main --separate-git-dir "$TMP/meta/.git" "$S"
git -C "$S" commit -q --allow-empty -m "seed workbench"
WRITER="$(cd "$S" && bash -c 'source "$1" && _pr_repo_root' _ "$LIB")"
if [ "$WRITER" = "$(cd "$TMP/meta" && pwd -P)" ]; then
	pass "separate git dir: the writer's root is the directory holding the git dir"
else
	bad "separate git dir: the writer's root is '$WRITER'"
fi
mkdir -p "$WRITER/port/claims"
printf 'id: beta\nclaimant: operator\ncreated: 2026-01-01T00:00:00Z\nstate: active\n' >"$WRITER/port/claims/beta.yaml"
git -C "$S" worktree add -q -b work/beta "$WRITER/.worktrees/beta"
git -C "$S" commit -q --allow-empty -m "advance mainline"
EXPECT_OUT="$(stale beta)" expect 0 "separate git dir: from the checkout the claims the writer placed are examined" "$S"
EXPECT_OUT="$(stale beta)" expect 0 "separate git dir: from the linked worktree the same claims are examined" "$WRITER/.worktrees/beta"

[ "$failed" -eq 0 ] || { printf '# test-worktree-freshness-root: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-worktree-freshness-root: all assertions passed\n'
