#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# migrate-opencode-dirs.py rewrites .opencode/command/ and .opencode/skill/ paths in a port's living
# documents, and nothing else: LESSONS, retrospectives, evidence and source/ stay as written, paths
# already on the new names are left alone, a dry run changes nothing, and a second run is a no-op.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATE="$ROOT/tools/migrate-opencode-dirs.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
failures=0
check() {
	local name="$1"; shift
	if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name" >&2; failures=$((failures + 1)); fi
}
has() { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }

R="$TMP/port-repo"
mkdir -p "$R/port/plan" "$R/port/retrospectives" "$R/docs/evidence" "$R/source"
OLD='See `.opencode/command/port-prove.md` and .opencode/skill/code-port/SKILL.md.'
printf '%s\nAlready new: .opencode/commands/port-land.md\n' "$OLD" >"$R/port/plan/00-charter.md"
for f in port/LESSONS.md port/retrospectives/phase-0.md docs/evidence/pack.md source/notes.md; do
	printf '%s\n' "$OLD" >"$R/$f"
done
printf 'untracked: .opencode/skill/x\n' >"$R/port/plan/untracked.md"
git init -q "$R"
git -C "$R" add port/plan/00-charter.md port/LESSONS.md port/retrospectives docs source
git -C "$R" commit -q -m init

out="$(cd "$R" && python3 "$MIGRATE")"
check "a dry run lists the file" grep -q '^port/plan/00-charter.md: 2 path(s)$' <<<"$out"
check "a dry run changes nothing" has "$R/port/plan/00-charter.md" '.opencode/command/port-prove.md'

(cd "$R" && python3 "$MIGRATE" --apply >/dev/null)
C="$R/port/plan/00-charter.md"
check "a command path moves to commands/" has "$C" '`.opencode/commands/port-prove.md`'
check "a skill path moves to skills/" has "$C" '.opencode/skills/code-port/SKILL.md'
check "a path already on the new name is left alone" has "$C" '.opencode/commands/port-land.md'
check "no old path is left" hasnt "$C" '.opencode/command/'
for f in port/LESSONS.md port/retrospectives/phase-0.md docs/evidence/pack.md source/notes.md; do
	check "$f stays as written" has "$R/$f" "$OLD"
done
check "an untracked file is not touched" has "$R/port/plan/untracked.md" '.opencode/skill/x'
out="$(cd "$R" && python3 "$MIGRATE" --apply)"
check "a second run changes nothing" grep -q 'nothing to change' <<<"$out"

[ "$failures" -eq 0 ] || { echo "# test-migrate-opencode-dirs: $failures failure(s)" >&2; exit 1; }
echo "# test-migrate-opencode-dirs: all assertions passed"
