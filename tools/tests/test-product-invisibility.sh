#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/conformance/check-product-invisibility.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect_result() {
	local expected="$1" label="$2" fixture="$3" output rc
	set +e
	output="$(bash "$CHECK" --product-root "$fixture" 2>&1)"
	rc=$?
	set -e
	if [ "$rc" -ne "$expected" ]; then
		printf 'not ok - %s (expected exit %s, got %s)\n%s\n' "$label" "$expected" "$rc" "$output" >&2
		exit 1
	fi
	printf 'ok - %s\n' "$label"
}

mkdir -p "$TMP/clean"
printf '%s\n' '/* src: source_unit.F90:212 = 0.1 */' 'double cw = 0.1;' >"$TMP/clean/model.c"
expect_result 0 "clean SOURCE anchor stays green" "$TMP/clean"

mkdir -p "$TMP/linked"
printf '%s\n' 'gitdir: /tmp/chisel-linked-worktree' >"$TMP/linked/.git"
expect_result 0 "linked-worktree .git control file is metadata" "$TMP/linked"
cp "$TMP/linked/.git" "$TMP/linked/ordinary-control"
expect_result 1 "the same bytes in an ordinary file are content" "$TMP/linked"

mkdir -p "$TMP/port-structure/port"
printf '%s\n' ordinary >"$TMP/port-structure/file.txt"
expect_result 1 "port directory remains red" "$TMP/port-structure"

mkdir -p "$TMP/command-structure/.claude" "$TMP/skill-structure/.opencode"
expect_result 1 ".claude directory remains red" "$TMP/command-structure"
expect_result 1 ".opencode directory remains red" "$TMP/skill-structure"

mkdir -p "$TMP/governance/deep/nest"
ln -s nowhere "$TMP/governance/deep/nest/CLAUDE.md"
expect_result 1 "nested dangling governance link remains red" "$TMP/governance"

mkdir -p "$TMP/content"
printf '%s\n' '/* Validation Ladder and Port Charter */' >"$TMP/content/model.c"
expect_result 1 "denylisted file content remains red" "$TMP/content"

mkdir -p "$TMP/history"
git -C "$TMP/history" init -q -b main
git -C "$TMP/history" config user.name tester
git -C "$TMP/history" config user.email tester@example.invalid
printf '%s\n' ordinary >"$TMP/history/file.txt"
git -C "$TMP/history" add file.txt
git -C "$TMP/history" commit -q -m "record port charter workflow"
expect_result 1 "denylisted commit subject remains red" "$TMP/history"
