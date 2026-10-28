#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# check-no-home-paths.sh - refuse a home-directory path in the commits of a range.
#
# A path inside a user's home directory - /home/<user>, /Users/<user>, or a profile folder under
# C:\Users on Windows - names a person's machine. Once committed it stays in the history even when a later commit removes it, so this reads
# every commit of the range - the lines it adds and its message - not only the final tree. CI runs it
# on the base for the commits a change brings; run it before pushing to catch one while it can still
# be amended.
#
# Usage: check-no-home-paths.sh [RANGE]    (default: origin/main..HEAD)
# Exit:  0 none found; 1 found (each printed under its commit); 2 the range does not resolve.
set -euo pipefail

range="${1:-origin/main..HEAD}"
pattern='(/home|/Users)/[A-Za-z0-9._-]+/|[A-Za-z]:\\Users\\'
commits="$(git rev-list --no-merges "$range" 2>/dev/null)" ||
	{ echo "check-no-home-paths: '$range' is not a commit range (UNRELIABLE)" >&2; exit 2; }

found=0
for c in $commits; do
	hits="$({
		git log -1 --format=%B "$c"
		git show --format= --no-renames --unified=0 "$c" | grep -E '^\+' | grep -v -E '^\+\+\+ ' || true
	} | grep -E -- "$pattern" || true)"
	if [ -n "$hits" ]; then
		found=1
		git log -1 --format='%h %s' "$c"
		printf '%s\n' "$hits" | sed 's/^/    /'
	fi
done

if [ "$found" = 1 ]; then
	echo "check-no-home-paths: a home-directory path is in the commits above; rewrite them without it" \
		"(amend, or rebase and edit), since a later commit that removes it leaves it in the history"
	exit 1
fi
echo "check-no-home-paths: no home-directory path in $range"
