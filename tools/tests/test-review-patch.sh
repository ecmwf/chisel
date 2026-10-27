#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# review_patch.py accepts a reviewer's patch only when it is small and the applied commit is the
# reviewed commit plus exactly that patch. A product with src/a.c, src/b.c and tests/t.c; patches made
# with git diff in a scratch worktree, the way a reviewer makes them. An exact small patch is GREEN; a
# commit with one more change, a patch touching a test, too many lines, too many places, a new file,
# or a patch that does not apply is refused; a missing patch or commit is UNRELIABLE.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/coordination/review_patch.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
failures=0
expect() { # expect EXIT NEEDLE LABEL ARGS...
	local want="$1" needle="$2" label="$3" out rc=0
	shift 3
	out="$(python3 "$CHECK" --repo "$P" "$@" 2>&1)" || rc=$?
	if [ "$rc" = "$want" ] && grep -qF -- "$needle" <<<"$out"; then
		printf 'ok - %s\n' "$label"
	else
		printf 'not ok - %s (exit %s)\n%s\n' "$label" "$rc" "$out" >&2
		failures=$((failures + 1))
	fi
}

P="$TMP/product"
mkdir -p "$P/src" "$P/tests"
git init -q "$P"
python3 -c 'print("\n".join("int a%d = %d;" % (i, i) for i in range(40)))' >"$P/src/a.c"
printf 'int b = 1;\n' >"$P/src/b.c"
printf 'int t = 1;\n' >"$P/tests/t.c"
git -C "$P" add -A && git -C "$P" commit -q -m reviewed
R="$(git -C "$P" rev-parse HEAD)"

# patch NAME SED-SCRIPT FILE...: the reviewer's patch, made in a scratch worktree of the reviewed commit.
patch() {
	local name="$1" script="$2"; shift 2
	git -C "$P" worktree add -q --detach "$TMP/scratch" "$R"
	for f in "$@"; do sed -i "$script" "$TMP/scratch/$f"; done
	git -C "$TMP/scratch" diff >"$TMP/$name.patch"
	git -C "$P" worktree remove --force "$TMP/scratch"
}
# applied PATCH [EXTRA]: the worker's commit on top of the reviewed one: the patch, plus EXTRA if given.
applied() {
	git -C "$P" checkout -q --detach "$R"
	git -C "$P" apply "$TMP/$1.patch"
	[ -z "${2:-}" ] || printf '%s\n' "$2" >>"$P/src/b.c"
	git -C "$P" commit -q -am "fix: apply the review patch"
	git -C "$P" rev-parse HEAD
}
ALLOW=(--allow src/a.c src/b.c)

patch small 's/^int a3 = 3;/int a3 = 30;/' src/a.c
A="$(applied small)"
expect 0 "RESULT: GREEN" "an exact small patch is accepted" --reviewed "$R" --applied "$A" --patch "$TMP/small.patch" "${ALLOW[@]}"
A="$(applied small 'int extra = 2;')"
expect 1 "differs from the reviewed commit plus the patch" "a commit with one more change is refused" \
	--reviewed "$R" --applied "$A" --patch "$TMP/small.patch" "${ALLOW[@]}"

patch tests 's/1/2/' tests/t.c
expect 1 "not one of the unit's files" "a patch touching a test is refused" \
	--reviewed "$R" --applied "$R" --patch "$TMP/tests.patch" "${ALLOW[@]}"
patch big 's/^int a1[0-5] =/int x =/' src/a.c
expect 1 "more than 10 line(s)" "a patch of too many lines is refused" \
	--reviewed "$R" --applied "$R" --patch "$TMP/big.patch" "${ALLOW[@]}"
patch spread 's/^int a\(2\|12\|22\|32\) =/int y\1 =/' src/a.c
expect 1 "in 4 place(s)" "a patch spread over too many places is refused" \
	--reviewed "$R" --applied "$R" --patch "$TMP/spread.patch" "${ALLOW[@]}"
printf 'diff --git a/src/c.c b/src/c.c\nnew file mode 100644\n--- /dev/null\n+++ b/src/c.c\n@@ -0,0 +1 @@\n+int c;\n' >"$TMP/new.patch"
expect 1 "adds, deletes, renames" "a patch adding a file is refused" \
	--reviewed "$R" --applied "$R" --patch "$TMP/new.patch" --allow src/a.c src/c.c
sed 's/int a3 = 3;/int a3 = 99;/; s/int a3 = 30;/int a3 = 300;/' "$TMP/small.patch" >"$TMP/stale.patch"
expect 1 "does not apply to the reviewed commit" "a patch that does not apply is refused" \
	--reviewed "$R" --applied "$R" --patch "$TMP/stale.patch" "${ALLOW[@]}"

expect 2 "no patch at" "a missing patch is UNRELIABLE" --reviewed "$R" --applied "$R" --patch "$TMP/none.patch" "${ALLOW[@]}"
expect 2 "does not resolve" "an unknown commit is UNRELIABLE" --reviewed deadbeef --applied "$R" --patch "$TMP/small.patch" "${ALLOW[@]}"

[ "$failures" -eq 0 ] || { echo "# test-review-patch: $failures failure(s)" >&2; exit 1; }
echo "# test-review-patch: all assertions passed"
