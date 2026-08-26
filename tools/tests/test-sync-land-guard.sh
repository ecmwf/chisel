#!/usr/bin/env bash
# Test the finalize.sh --land-only layer guard.
#
# A base sync is a --no-ff merge of upstream/main onto HEAD, resolved by the layer drivers (project
# kept at HEAD, methodology taken from base). The land guard must then verify that resolution WITHOUT
# rejecting the instance's own local methodology - methodology it has modified or added but not yet
# contributed (a deferred contribution, or a local-only tool). The merge KEEPS such files; before the
# base-changed test this guard rejected them, because it required every methodology file to equal
# upstream/main, so a sync could not land while the instance carried any uncontributed methodology
# (revert the mergebase/base-changed logic in finalize.sh and case 1 below goes RED - the swap-and-fail).
#
# This drives the REAL finalize.sh guard via `--land-only --no-push --dry-run`: the guard runs before
# the remote preflight and the (dry-run) land, so no remote and no teardown are needed. Cases 2-4 prove
# the guard is still non-vacuous - it rejects a dropped base change, a tampered base change, and an
# altered project file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FINALIZE="$ROOT/tools/coordination/finalize.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
failt() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

inst="$TMP/inst"
mkdir -p "$inst"
cd "$inst"
git init -q -b main
git config user.name tester
git config user.email tester@example.invalid
git config merge.ours.driver true
git config merge.theirs.driver 'cp -f %B %A'

# Two-layer attributes: proj/** is project (merge=ours); everything else is methodology.
printf 'proj/** merge=ours\n' >.gitattributes

# B - the merge base (the previous synced base point): a base-owned methodology file, an untouched
# methodology file, and a project file.
mkdir -p proj
printf 'v0\n' >meth_base.txt
printf 'v0\n' >meth_untouched.txt
printf 'v0\n' >proj/p.txt
git add -A
git commit -q -m "B: merge base"

# U - the base advances (upstream/main): change meth_base, add meth_new; leave meth_untouched alone.
git switch -q -c base-adv
printf 'v1\n' >meth_base.txt
printf 'new\n' >meth_new.txt
git add -A
git commit -q -m "U: base advances"
U="$(git rev-parse HEAD)"
git switch -q main
git update-ref refs/remotes/upstream/main "$U" # simulate the fetched base tip

# H - the instance advances: add a LOCAL-ONLY methodology tool + change a project file. HEAD does NOT
# touch anything the base changed.
printf 'local-only tool\n' >meth_local.txt
printf 'inst\n' >proj/p.txt
git add -A
git commit -q -m "H: instance local methodology + project change"
H="$(git rev-parse HEAD)"

# Build a sync/<id> branch: merge upstream/main onto H with the drivers (no commit), restore the
# project layer to HEAD (the sync procedure's step 4), apply an optional mutation, then commit.
build_sync() {
	local id="$1"
	shift
	git switch -q -C "sync/$id" "$H"
	git merge --no-ff --no-commit upstream/main >/dev/null 2>&1 || true
	git checkout "$H" -- proj/ 2>/dev/null || true
	"$@" # optional mutation callback (stages its change)
	git commit -q --no-edit
	git switch -q main
}

guard_ok() { # returns finalize's exit status for sync/<id>
	( cd "$inst" && bash "$FINALIZE" --land-only --sync "sync/$1" --no-push --dry-run ) >/dev/null 2>&1
}

noop() { :; }
drop_base() {
	printf 'v0\n' >meth_base.txt
	git add meth_base.txt
} # revert the base's change
tamper_base() {
	printf 'evil\n' >meth_base.txt
	git add meth_base.txt
} # a value that is neither HEAD nor upstream
alter_proj() {
	printf 'sneaked\n' >proj/p.txt
	git add proj/p.txt
} # project file not at HEAD

# 1) LEGIT: base change landed verbatim, local methodology preserved -> guard PASSES (the fix).
build_sync legit noop
guard_ok legit && pass "legit sync with local methodology passes" \
	|| failt "legit sync REJECTED - local methodology must be preserved, not reset to upstream"

# 2) DROPPED base change -> guard FAILS (safety: a silently dropped base change is caught).
build_sync dropped drop_base
guard_ok dropped && failt "dropped base change PASSED - guard must reject it" \
	|| pass "dropped base change is rejected"

# 3) TAMPERED base change -> guard FAILS (safety: methodology not matching upstream is caught).
build_sync tampered tamper_base
guard_ok tampered && failt "tampered base change PASSED - guard must reject it" \
	|| pass "tampered base change is rejected"

# 4) ALTERED project file -> guard FAILS (safety: project layer must equal HEAD).
build_sync altproj alter_proj
guard_ok altproj && failt "altered project file PASSED - project layer must equal HEAD" \
	|| pass "altered project file is rejected"

printf '# test-sync-land-guard: all assertions passed\n'
