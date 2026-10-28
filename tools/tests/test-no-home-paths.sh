#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# tools/check-no-home-paths.sh reads every commit of a range, its added lines and its message. A
# home-directory path in an added line, in a message, in a Windows form, or added and then removed
# within the range is refused; a range that only removes an older one, or holds none, passes; a range
# that does not resolve is UNRELIABLE. The sample paths are put together at run time, so this file
# itself holds none for the check to find.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/check-no-home-paths.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
failures=0
expect() { # expect EXIT NEEDLE LABEL RANGE
	local out rc=0
	out="$(cd "$R" && bash "$CHECK" "$4" 2>&1)" || rc=$?
	if [ "$rc" = "$1" ] && grep -qF -- "$2" <<<"$out"; then
		printf 'ok - %s\n' "$3"
	else
		printf 'not ok - %s (exit %s)\n%s\n' "$3" "$rc" "$out" >&2
		failures=$((failures + 1))
	fi
}

home="/ho""me/alice/work"
mac="/Use""rs/alice/work"
win='C:''\Users\alice\work'
R="$TMP/repo"
git init -q -b main "$R"
commit() { printf '%s\n' "$1" >"$R/f.txt"; git -C "$R" add f.txt; git -C "$R" commit -q -m "$2"; git -C "$R" rev-parse HEAD; }
base="$(commit "clean" "start")"

c="$(commit "see $home/notes" "add notes")"
expect 1 "add notes" "a path in an added line is refused" "$base..$c"
c="$(commit "clean again" "drop notes")"
expect 1 "add notes" "a path added and removed within the range is refused" "$base..$c"
expect 0 "no home-directory path" "a range that only removes an older one passes" "$c~1..$c"

c="$(commit "fine" "built in $mac/build")"
expect 1 "built in" "a path in a commit message is refused" "$c~1..$c"
c="$(commit "see $win\\notes" "windows notes")"
expect 1 "windows notes" "a Windows home path is refused" "$c~1..$c"
c="$(commit "a relative path: ~/work and /tmp/x" "clean change")"
expect 0 "no home-directory path" "a range with none passes" "$c~1..$c"
expect 2 "is not a commit range" "a range that does not resolve is UNRELIABLE" "nope..$c"

[ "$failures" -eq 0 ] || { echo "# test-no-home-paths: $failures failure(s)" >&2; exit 1; }
echo "# test-no-home-paths: all assertions passed"
