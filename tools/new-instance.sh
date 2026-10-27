#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# Create (or resume) a port instance from the base repo, in one command.
# We do NOT fork (GitHub allows one fork per account per repo); instead each port
# is its own independent repo cloned from the base, so you can run any number.
#
# Run from a clone of the base. This flips the clone into an instance: the base
# becomes the `upstream` remote, the new repo becomes `origin`, the layer merge
# drivers are activated, and main is pushed.
#
# IDEMPOTENT / RESUMABLE: if this clone is already the instance you ask for, it just
# re-asserts the drivers + pushes main and exits 0 (so re-running after a later step
# failed is safe). If a previous run already CREATED the remote repo, it is reused,
# not recreated. It refuses only when the clone is an instance of a DIFFERENT repo
# than requested (which would corrupt the layer model) - pass --force to repoint then.
#
# Usage:
#   tools/new-instance.sh [--force] <new-repo>
#     <new-repo> = a gh target like "me/port-foo" (needs the gh CLI), OR a full
#                  git URL of a repo you already created.
#     --force    = repoint a clone that is already an instance at <new-repo>.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

FORCE=0
NEW=""
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) if [ -z "$NEW" ]; then NEW="$a"; else echo "too many arguments" >&2; exit 2; fi ;;
  esac
done
[ -n "$NEW" ] || { echo "usage: tools/new-instance.sh [--force] <new-repo>   (gh name 'me/port-x' or a git URL)" >&2; exit 2; }
# A git URL (file:// for a local repo) or a strict GitHub owner/name - the same rule as
# chisel-init and new-product.sh. A bare local path is neither: refuse it before changing anything.
case "$NEW" in
  *://*|git@*:*) ;;
  *) printf '%s' "$NEW" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$' \
       || { echo "new-instance: '$NEW' is neither a git URL nor a GitHub owner/name. For a local repo, pass a file:// URL." >&2; exit 2; } ;;
esac

# owner/name for a gh name OR a git URL alike, so we can tell "same repo" from "different repo".
slug() { sed -E 's#\.git/?$##; s#/+$##' <<<"$1" | awk -F'[/:]' 'NF>=2{print tolower($(NF-1)"/"$NF); next}{print tolower($0)}'; }

cur_origin="$(git remote get-url origin 2>/dev/null || true)"
cur_upstream="$(git remote get-url upstream 2>/dev/null || true)"

drivers() {
  # Layer merge drivers: ours keeps the instance side (project layer), theirs takes the base side
  # (methodology layer). Reversing them would lose real work. Setting them is idempotent.
  git config merge.ours.driver true
  git config merge.theirs.driver 'cp -f %B %A'
}

# Point origin at <new-repo>, CREATING the gh repo only if it does not already exist (a prior failed
# run may have created it), then push the checked-out methodology to the instance's main.
set_origin_to_new() {
  case "$NEW" in
    *://*|git@*:*)
      git remote remove origin 2>/dev/null || true
      git remote add origin "$NEW"
      git push -u origin HEAD:main
      ;;
    *)
      command -v gh >/dev/null || { echo "gh CLI not found: create the repo yourself and re-run with its git URL" >&2; exit 2; }
      git remote remove origin 2>/dev/null || true
      if gh repo view "$NEW" >/dev/null 2>&1; then
        local proto url
        proto="$(gh config get git_protocol 2>/dev/null || echo ssh)"
        if [ "$proto" = https ]; then url="$(gh repo view "$NEW" --json url -q .url)"; else url="$(gh repo view "$NEW" --json sshUrl -q .sshUrl)"; fi
        echo "repo $NEW already exists - using it (not recreating)."
        git remote add origin "$url"
        git push -u origin HEAD:main
      else
        gh repo create "$NEW" --private --source=. --remote=origin --push
      fi
      ;;
  esac
}

# ---- already an instance? resume the same one, repoint a different one, or refuse ----
if [ -n "$cur_upstream" ]; then
  BASE="$cur_upstream"
  if [ "$(slug "$cur_origin")" = "$(slug "$NEW")" ]; then
    echo "Already an instance for $NEW (upstream=$BASE) - re-asserting drivers + main (idempotent)."
    drivers
    git push -u origin HEAD:main 2>/dev/null || echo "  note: main not pushed (up-to-date, diverged, or offline) - push later if needed."
    echo "Instance ready (resumed)."
    exit 0
  fi
  if [ "$FORCE" != 1 ]; then
    echo "This clone is already an instance whose origin is '$cur_origin', not '$NEW'." >&2
    echo "Refusing to repoint (that could corrupt the layer model). Re-run with --force to repoint at" >&2
    echo "'$NEW', or start a different port from a fresh base clone." >&2
    exit 2
  fi
  echo "--force: repointing this instance to $NEW (upstream stays the base $BASE)."
  git remote set-url upstream "$BASE" 2>/dev/null || git remote add upstream "$BASE"
  set_origin_to_new
  drivers
  echo "Instance repointed."
  echo "  upstream (base): $BASE"
  echo "  origin (this port): $(git remote get-url origin)"
  exit 0
fi

# ---- fresh flip (no upstream yet) ----
# The base is where this clone came from; fall back to the recorded pointer.
BASE="$cur_origin"
if [ -z "$BASE" ] && [ -f tools/base-repo.txt ]; then
  BASE="$(grep -vE '^\s*#|^\s*$' tools/base-repo.txt | head -1)"
fi
[ -z "$BASE" ] && { echo "cannot determine the base repo URL" >&2; exit 2; }

# Point upstream at the base, freeing origin. Capture the old origin for rollback.
ORIG_ORIGIN="$cur_origin"
git remote remove upstream 2>/dev/null || true
git remote rename origin upstream 2>/dev/null || git remote add upstream "$BASE"

# If repo creation or the push fails, restore the original remotes so a failure never leaves a
# half-flipped clone (origin renamed away with no working remote to push to).
rollback() {
  echo "new-instance: failed - restoring the original remotes (no half-flipped clone)." >&2
  git remote remove origin 2>/dev/null || true
  git remote remove upstream 2>/dev/null || true
  [ -n "$ORIG_ORIGIN" ] && git remote add origin "$ORIG_ORIGIN" 2>/dev/null || true
}
_FLIP_OK=0
trap '[ "$_FLIP_OK" = 1 ] || rollback' EXIT

set_origin_to_new
_FLIP_OK=1
drivers

# Run by hand, the flip is only the first step of setting up a port: chisel-init does the rest (it
# sees the clone is already an instance and continues). Run by chisel-init, which reports the
# result itself, it says nothing more.
if [ -z "${CHISEL_INIT:-}" ]; then
  echo "Instance ready."
  echo "  upstream (base): $BASE"
  echo "  origin (this port): $(git remote get-url origin)"
  echo "Next: run uv run tools/chisel-init.py here - it imports the original code into source/, creates the"
  echo "      product repo beside this folder and chooses the agents' models (the flip is done; it continues)."
fi
