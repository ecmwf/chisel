#!/usr/bin/env bash
# Test where check-worktree-freshness.sh looks for claims and worktrees.
#
# The live claims (port/claims/, gitignored) and the per-piece worktrees (.worktrees/<id>) belong to
# the MAIN workbench checkout. Run from inside a linked worktree - a worker or reviewer running the
# suite where it works - the check used to anchor on that worktree's own top level, find no claims
# there and report "nothing to check": a silent pass while a stale worktree waited to be dispatched.
# It must resolve the main checkout from a linked worktree exactly as from the main checkout itself,
# on any git that has linked worktrees: a git older than 2.31 does not know `rev-parse --path-format`
# (it echoes the unknown option back and exits 0), so the resolution must not depend on it. When the
# common git dir cannot be resolved to a directory, the answer is UNRELIABLE (exit 2), never a skip.
# Revert the resolution and the linked-worktree cases go RED; resolve through --path-format with a
# fall back to the worktree's own top level and the old-git linked-worktree cases go RED (a silent
# "nothing to check") together with the unresolvable cases; take the parent of the common dir as
# printed, unresolved, and the unresolvable cases go RED (no UNRELIABLE verdict), as does the
# main-checkout subdirectory case (a relative root).
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
EXPECT_OUT="$STALE" expect 0 "from a subdirectory of the main checkout the stale worktree is reported" "$W/port"
EXPECT_OUT="$STALE" expect 0 "from inside a linked worktree the same claims are examined" "$W/.worktrees/alpha"
EXPECT_OUT="$STALE" expect 0 "from a subdirectory of a linked worktree the same claims are examined" "$W/.worktrees/alpha/sub"

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
FAKE_PATH="PATH=$TMP/fakegit:$PATH"
EXPECT_OUT="$STALE" expect 0 "old git: from the main checkout the stale worktree is reported" "$W" "$FAKE_PATH" FAKE_GIT=old
EXPECT_OUT="$STALE" expect 0 "old git: from inside a linked worktree the same claims are examined" "$W/.worktrees/alpha" "$FAKE_PATH" FAKE_GIT=old
EXPECT_OUT="$STALE" expect 0 "old git: from a subdirectory of a linked worktree the same claims are examined" "$W/.worktrees/alpha/sub" "$FAKE_PATH" FAKE_GIT=old
EXPECT_OUT="UNRELIABLE" expect 2 "an unresolvable common git dir is UNRELIABLE from the main checkout" "$W" "$FAKE_PATH" FAKE_GIT=nocommon
EXPECT_OUT="UNRELIABLE" expect 2 "an unresolvable common git dir is UNRELIABLE from a linked worktree" "$W/.worktrees/alpha" "$FAKE_PATH" FAKE_GIT=nocommon

# A workbench in the submodule layout: its .git is a file and its git dir lives in the superproject's
# .git/modules/<name>, so the common git dir is not <root>/.git and its parent is inside another
# repository's git dir (which resolves to that repository, with no claims). From the main working tree
# the top level is still the answer; from a linked worktree the main working tree is not the common
# dir's parent, so the check answers UNRELIABLE rather than guessing. Take the common dir's parent
# unconditionally and both cases are a silent "nothing to check".
SUPER="$TMP/super"
git init -q -b main "$SUPER"
git -C "$SUPER" commit -q --allow-empty -m "seed superproject"
S="$SUPER/wb"
mkdir -p "$SUPER/.git/modules"
git init -q -b main --separate-git-dir "$SUPER/.git/modules/wb" "$S"
printf '.worktrees/\nport/claims/\n' >"$S/.gitignore"
git -C "$S" add .gitignore
git -C "$S" commit -q -m "seed workbench"
mkdir -p "$S/port/claims"
printf 'id: beta\nclaimant: operator\ncreated: 2026-01-01T00:00:00Z\nstate: active\n' >"$S/port/claims/beta.yaml"
git -C "$S" worktree add -q -b work/beta "$S/.worktrees/beta"
git -C "$S" commit -q --allow-empty -m "advance mainline"
EXPECT_OUT="stale worktree - beta: 1 commit(s) behind" expect 0 "submodule layout: from the main checkout the stale worktree is reported" "$S"
EXPECT_OUT="UNRELIABLE" expect 2 "submodule layout: a linked worktree cannot locate the main checkout, which is UNRELIABLE" "$S/.worktrees/beta"

[ "$failed" -eq 0 ] || { printf '# test-worktree-freshness-root: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-worktree-freshness-root: all assertions passed\n'
