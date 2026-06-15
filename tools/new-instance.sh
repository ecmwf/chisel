#!/usr/bin/env bash
# Create a new port instance from the base repo, in one command.
# We do NOT fork (GitHub allows one fork per account per repo); instead each port
# is its own independent repo cloned from the base, so you can run any number.
#
# Run from a FRESH clone of the base. This flips the clone into an instance:
# the base becomes the `upstream` remote, the new repo becomes `origin`, the
# layer merge driver is activated, and main is pushed.
#
# Usage:
#   tools/new-instance.sh <new-repo>
#     <new-repo> = a gh target like "me/port-foo" (needs the gh CLI), OR a full
#                  git URL of a repo you already created.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

NEW="${1:-}"
if [ -z "$NEW" ]; then
  echo "usage: tools/new-instance.sh <new-repo>   (gh name 'me/port-x' or a git URL)" >&2
  exit 2
fi

# Idempotency guard: a clone that already has an `upstream` remote has already been flipped
# into an instance. Re-flipping renames the current origin (the instance) onto `upstream`,
# pointing it at the WRONG repo and corrupting the layer model - so refuse, and tell the
# operator to start from a fresh base clone instead.
if git remote get-url upstream >/dev/null 2>&1; then
  echo "This clone already has an 'upstream' remote - it is already an instance." >&2
  echo "Refusing to re-flip (that would point 'upstream' at the wrong repo). Start from a fresh base clone." >&2
  exit 2
fi

# The base is where this clone came from; fall back to the recorded pointer.
BASE="$(git remote get-url origin 2>/dev/null || true)"
if [ -z "$BASE" ] && [ -f tools/base-repo.txt ]; then
  BASE="$(grep -vE '^\s*#|^\s*$' tools/base-repo.txt | head -1)"
fi
[ -z "$BASE" ] && { echo "cannot determine the base repo URL" >&2; exit 2; }

# Point upstream at the base, freeing origin for the instance.
git remote remove upstream 2>/dev/null || true
git remote rename origin upstream 2>/dev/null || git remote add upstream "$BASE"

case "$NEW" in
  *://*|git@*)
    git remote remove origin 2>/dev/null || true
    git remote add origin "$NEW"
    git push -u origin main
    ;;
  *)
    command -v gh >/dev/null || { echo "gh CLI not found: create the repo yourself and re-run with its git URL" >&2; exit 2; }
    gh repo create "$NEW" --private --source=. --remote=origin --push
    ;;
esac

# Layer merge drivers: ours keeps the instance side (project layer), theirs takes
# the base side (methodology layer). Reversing these would lose real work.
git config merge.ours.driver true
git config merge.theirs.driver 'cp -f %B %A'

echo "Instance ready."
echo "  upstream (base): $BASE"
echo "  origin (this port): $(git remote get-url origin)"
echo "Next: start a sprint here - run /port-sprint-start."
