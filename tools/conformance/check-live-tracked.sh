#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

#
# check-live-tracked.sh - every file the dependency map / TRACE calls LIVE is git-TRACKED.
#
# A recorded failure: `helper.F90` was a real, declared in the build's source list LIVE routine that
# was never committed - `tools/import-source.sh` strips the nested `.git` on import, which demotes
# every imported file to untracked, at which point the imported `.gitignore` (harmless upstream,
# since tracked files are immune to it) starts excluding real source; `git add -A` then silently
# skips it. The main working tree still held the untracked file (so checks passed there); a fresh
# worktree checked out from git at the same commit did not have it at all.
#
# check-source-import.sh already proves the AGGREGATE half: tracked-file COUNT under each imported
# SOURCE path equals its provenance `tracked_files`. That is real and durable, but it is a whole-
# tree SUM over a much larger set (the entire imported repo: tests, docs, cmake, ...) than the
# dependency map/TRACE ever name, so it can hold even while the SPECIFIC file the map calls live is
# the one missing. This is the missing PER-FILE half: every dependency-map node, and every TRACE
# row whose status is not `excluded`, must resolve to a file that both EXISTS on disk and is
# git-tracked - not merely present in a working tree that happens to still hold an untracked copy.
# A thin wrapper over tools/coordination/check_live_tracked.py.
#
# Exit-code contract:
#   0  GREEN       every map node and every live TRACE row is on disk and tracked (or nothing yet)
#   1  RED         a map/TRACE-named file is missing from disk, or present but untracked
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / git / malformed input)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-live-tracked: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-live-tracked: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-live-tracked: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/check_live_tracked.py" "$@"
