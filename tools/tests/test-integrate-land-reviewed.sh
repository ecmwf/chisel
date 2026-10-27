#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# integrate_land.sh lands a Phase-1 tool only as it was reviewed: the unit's reviewed_commit must be
# on work/<id>, and every change after it may touch only the unit's own records. A workbench with the
# real tools, the planner and the conformance suite stubbed (both are checked elsewhere), and a
# work/u1 branch whose tool commit was reviewed and whose records came after it. A code change after
# the review is refused, and so is a unit with no reviewed_commit or one from another history; each
# refusal leaves main where it was. The records-only tip lands.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n%s\n' "$1" "${2:-}" >&2; failures=$((failures + 1)); }

W="$TMP/wb"
mkdir -p "$W/port"
cp -r "$ROOT/tools" "$W/tools"
printf 'print("integrate u1")\n' >"$W/tools/coordination/phase1_drive.py"
printf '#!/usr/bin/env bash\nexit 0\n' >"$W/tools/run-conformance.sh"
plan() { printf 'schema_version: 1\nunits:\n  - id: u1\n    layer: 0\n    kind: harness\n    accepted: %s\n%s' "$1" "$2" >"$W/port/phase1-plan.yaml"; }
plan false ""
git -C "$W" init -q -b main && git -C "$W" add -A && git -C "$W" commit -q -m wb
BASE="$(git -C "$W" rev-parse main)"

# work/u1: the tool, which the review covered; then the unit's records.
git -C "$W" checkout -q -b work/u1
mkdir -p "$W/tools/proofs" && printf 'echo u1\n' >"$W/tools/proofs/u1.sh"
git -C "$W" add -A && git -C "$W" commit -q -m "build u1"
REVIEWED="$(git -C "$W" rev-parse HEAD)"
mkdir -p "$W/docs/evidence/phase1/u1" && printf 'verdict: clean\n' >"$W/docs/evidence/phase1/u1/review.md"
plan true "    reviewed_commit: $REVIEWED
"
git -C "$W" add -A && git -C "$W" commit -q -m "u1 records"
RECORDS="$(git -C "$W" rev-parse HEAD)"
git -C "$W" checkout -q main

land() { (cd "$W" && bash tools/coordination/integrate_land.sh u1 --no-push 2>&1); }
on_work() { git -C "$W" checkout -q work/u1 && "$@" && git -C "$W" add -A && git -C "$W" commit -q -m change && git -C "$W" checkout -q main; }
refused() { # refused <name> <expected message>
	local rc=0 out
	out="$(land)" || rc=$?
	if [ "$rc" -eq 2 ] && grep -q -- "$2" <<<"$out" && [ "$(git -C "$W" rev-parse main)" = "$BASE" ]; then
		ok "$1"
	else
		not_ok "$1" "exit $rc: $out"
	fi
	git -C "$W" branch -q -f work/u1 "$RECORDS"
}

on_work sh -c "printf 'echo changed\n' >'$W/tools/proofs/u1.sh'"
refused "a code change after the review is refused, and nothing lands" "changed after its review"

on_work plan true ""
refused "a unit with no reviewed_commit is refused" "records no reviewed_commit"

git -C "$W" checkout -q -b side "$BASE" && printf 'x\n' >"$W/side.txt" && git -C "$W" add -A \
	&& git -C "$W" commit -q -m side && git -C "$W" checkout -q main
SIDE="$(git -C "$W" rev-parse side)"
on_work plan true "    reviewed_commit: $SIDE
"
refused "a reviewed_commit from another history is refused" "is not on 'work/u1'"

rc=0; out="$(land)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(git -C "$W" rev-parse main)" = "$RECORDS" ]; then
	ok "records added after the review land with the reviewed tool"
else
	not_ok "records added after the review land with the reviewed tool" "exit $rc: $out"
fi

[ "$failures" -eq 0 ] || { echo "# test-integrate-land-reviewed: $failures failure(s)" >&2; exit 1; }
echo "# test-integrate-land-reviewed: all assertions passed"
