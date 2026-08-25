#!/usr/bin/env bash
# Print LIVE dispatch facts for a unit. Never cite a SHA from memory - a rebase
# rewrites them, and a brief citing a dead SHA sends a worker to a tree that
# does not match its instructions. Run this immediately before every dispatch.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
main_sha="$(git -C "$ROOT" rev-parse --short main)"
printf 'main: %s   conformance-checks: %s\n' "$main_sha" \
  "$(ls "$ROOT"/tools/conformance/*.sh "$ROOT"/tools/conformance/project/*.sh 2>/dev/null | wc -l)"
for u in "$@"; do
  wb="$ROOT/.worktrees/$u"; pr="$ROOT/.worktrees/product-$u"
  [ -d "$wb" ] || { printf '  %-24s ABSENT\n' "$u"; continue; }
  wsha="$(git -C "$wb" rev-parse --short HEAD)"
  base="$(git -C "$wb" merge-base HEAD main 2>/dev/null)"
  behind="$(git -C "$wb" rev-list --count "$base"..main 2>/dev/null)"
  dirty="$(git -C "$wb" status --porcelain | wc -l)"
  psha="n/a"; [ -d "$pr" ] && psha="$(git -C "$pr" rev-parse --short HEAD)"
  printf '  %-24s wb=%s product=%s behind-main=%s dirty=%s\n' "$u" "$wsha" "$psha" "$behind" "$dirty"
done
