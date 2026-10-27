#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# sync_merge.sh keeps the instance's project layer whatever the base did to it. A base repo with the
# real .gitattributes and an instance cloned from it, with the layer drivers set as chisel-init sets
# them. The base edits a project file the instance left alone, adds one and deletes one, and changes a
# methodology file: after the sync the project layer matches the instance and the methodology file
# matches the base. A conflict outside the project layer is reported (exit 1), with the project layer
# restored all the same.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYNC="$ROOT/tools/coordination/sync_merge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
failures=0
check() { # check <name> <command...>: the command must succeed
	local name="$1"; shift
	if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name" >&2; failures=$((failures + 1)); fi
}
has() { [ "$(cat "$1" 2>/dev/null)" = "$2" ]; }
gone() { [ ! -e "$2/$1" ] && [ -z "$(git -C "$2" ls-files -- "$1")" ]; }
commit() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }

B="$TMP/base"
git init -q -b main "$B"
cp "$ROOT/.gitattributes" "$B/.gitattributes"
mkdir -p "$B/port" "$B/tools"
for f in a old keep; do echo "$f-0" >"$B/port/$f.md"; done
echo x-0 >"$B/tools/x.sh"
echo n-0 >"$B/notes.txt"
commit "$B" base

I="$TMP/inst"
git clone -q "$B" "$I"
git -C "$I" remote rename origin upstream
git -C "$I" config merge.ours.driver true
git -C "$I" config merge.theirs.driver 'cp -f %B %A'
echo a-inst >"$I/port/a.md" && commit "$I" "instance work"

echo a-base >"$B/port/a.md"
echo old-base >"$B/port/old.md"
echo new-base >"$B/port/new.md"
git -C "$B" rm -q port/keep.md
echo x-1 >"$B/tools/x.sh"
commit "$B" "base changes"

# 1. Project-layer changes only: merged, and the project layer is the instance's.
git -C "$I" fetch -q upstream
git -C "$I" worktree add -q "$TMP/s1" -b sync/1 main
rc=0; out="$(bash "$SYNC" upstream/main --worktree "$TMP/s1" 2>&1)" || rc=$?
check "a sync with no conflict outside the project layer exits 0" [ "$rc" -eq 0 ]
check "a project file both sides changed keeps the instance side" has "$TMP/s1/port/a.md" a-inst
check "a base edit to a project file the instance left alone is undone" has "$TMP/s1/port/old.md" old-0
check "a project file the base added is removed" gone port/new.md "$TMP/s1"
check "a project file the base deleted is kept" has "$TMP/s1/port/keep.md" keep-0
check "a methodology file takes the base side" has "$TMP/s1/tools/x.sh" x-1
check "the staged project layer equals the pre-merge HEAD" git -C "$TMP/s1" diff --cached --quiet HEAD -- port
check "the restored files are listed" grep -q 'port/old.md' <<<"$out"
[ "$failures" -eq 0 ] || printf '%s\n' "$out" >&2
git -C "$TMP/s1" merge --abort

# 2. And a conflict outside the project layer: reported, the project layer restored anyway.
echo n-base >"$B/notes.txt" && commit "$B" "base notes"
echo n-inst >"$I/notes.txt" && commit "$I" "instance notes"
git -C "$I" fetch -q upstream
git -C "$I" worktree add -q "$TMP/s2" -b sync/2 main
rc=0; out="$(bash "$SYNC" upstream/main --worktree "$TMP/s2" 2>&1)" || rc=$?
check "a conflict outside the project layer exits 1" [ "$rc" -eq 1 ]
check "the conflicting path is named" grep -q '^  notes.txt$' <<<"$out"
check "the project layer is restored despite the conflict" has "$TMP/s2/port/old.md" old-0
check "a project file the base added is removed despite the conflict" gone port/new.md "$TMP/s2"

[ "$failures" -eq 0 ] || { echo "# test-sync-merge: $failures failure(s)" >&2; exit 1; }
echo "# test-sync-merge: all assertions passed"
