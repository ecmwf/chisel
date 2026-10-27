#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# push_claim.sh publishes a local claim as refs/claims/<id> and never replaces another operator's.
# Two workbenches share one bare remote. The first pushes its claim (and keeps the local ref that
# release_claim.sh looks for); pushing it again changes nothing; the second operator's claim on the
# same unit is refused and the remote keeps the first. A missing claim, or a claim file for another
# id, is refused.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PUSH="$ROOT/tools/coordination/push_claim.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
failures=0
check() {
	local name="$1"; shift
	if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name" >&2; failures=$((failures + 1)); fi
}

git init -q --bare "$TMP/remote.git"
git init -q -b main "$TMP/seed" && git -C "$TMP/seed" commit -q --allow-empty -m init \
	&& git -C "$TMP/seed" push -q "$TMP/remote.git" main
for who in a b; do
	git clone -q "$TMP/remote.git" "$TMP/$who"
	mkdir -p "$TMP/$who/port/claims"
	printf 'id: u1\nclaimant: %s\n' "$who" >"$TMP/$who/port/claims/u1.yaml"
done
claim() { local rc=0; (cd "$TMP/$1" && bash "$PUSH" "${@:2}") >"$TMP/out" 2>&1 || rc=$?; echo "$rc"; }
remote_claim() { git -C "$TMP/remote.git" cat-file -p refs/claims/u1 2>/dev/null; }
local_ref() { git -C "$TMP/a" rev-parse -q --verify refs/claims/u1 >/dev/null; }

check "the first claim is pushed" [ "$(claim a u1)" = 0 ]
check "the remote holds it" grep -q 'claimant: a' <<<"$(remote_claim)"
check "the local ref release_claim.sh looks for is set" local_ref
check "pushing the same claim again changes nothing" [ "$(claim a u1)" = 0 ]
check "another operator's claim on the same unit is refused" [ "$(claim b u1)" = 1 ]
check "the refusal says who holds it" grep -q 'another operator holds' "$TMP/out"
check "the remote keeps the first claim" grep -q 'claimant: a' <<<"$(remote_claim)"
check "a unit with no local claim is refused" [ "$(claim a u2)" = 2 ]
printf 'id: u9\n' >"$TMP/a/port/claims/u3.yaml"
check "a claim file for another id is refused" [ "$(claim a u3)" = 2 ]

[ "$failures" -eq 0 ] || { echo "# test-push-claim: $failures failure(s)" >&2; exit 1; }
echo "# test-push-claim: all assertions passed"
