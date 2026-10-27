#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

#
# check-claims.sh - work-item claims are well-formed, unique, and honored by their branches.
#
# Claims (references/team-coordination.md, "Claims: the local lock, atomic"): a claim reserves
# a work item. By DEFAULT it is the local file port/claims/<trace-id>.yaml that provision_worker.sh
# writes alongside the worker's isolated worktree (the worktree IS the lock); the pushed ref
# refs/claims/<trace-id> (--from-refs) is the advanced multi-operator path. Either way the content
# is the claim (assets/claim.template.yaml) and this check verifies what the file system / git
# ref machinery cannot:
#   SCHEMA     each claim is valid YAML with the required fields, its id matches the file/ref name,
#              state is created|active|stale, and source/target/paths (when present) are clean lists;
#   DUPLICATE  no two LIVE claims (created|active) cover overlapping source/target, and no two
#              share an id (the same SOURCE reserved twice under different ids);
#   BRANCH-DIFF (on demand, per branch) a branch touches only its claim's write surface, and
#              does not reach into an owned surface its claim was not granted.
#
# A thin wrapper over the verifier (tools/coordination/check_claims.py). With NO arguments it
# runs schema + duplicate over port/claims/* (gitignored local state, so absent in a fresh CI
# checkout -> it skips); --from-refs reads refs/claims/* instead. Branch-diff is an on-demand mode
# (--claim ID --files-from FILE, or --branch REF), invoked by the dashboard/integrator per branch -
# not by the no-arg CI pass. Fixtures/tests pass --claims-dir DIR to read <trace-id>.yaml files.
#
# Exit-code contract:
#   0  GREEN       every claim verifies (or there are none yet)
#   1  RED         a claim is malformed, duplicates another, or its branch left its surface
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / git / unreadable inputs)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-claims: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-claims: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-claims: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/check_claims.py" "$@"
