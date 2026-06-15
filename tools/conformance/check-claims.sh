#!/usr/bin/env bash
#
# check-claims.sh - work-item claims are well-formed, unique, and honored by their branches.
#
# Claims (references/team-coordination.md, "Claims: a pushed ref, atomic"): a claim reserves
# a work item via a pushed ref refs/claims/<trace-id> pointing at a blob whose content is the
# claim (assets/claim.template.yaml). push-to-create is the atomic collision detector; this
# check verifies what git's ref machinery cannot:
#   SCHEMA     each claim is valid YAML with the required fields, its id matches the ref name,
#              state is created|active|stale, and source/target are non-empty block lists;
#   DUPLICATE  no two LIVE claims (created|active) cover overlapping source/target, and no two
#              share an id (the same SOURCE reserved twice under different ids);
#   BRANCH-DIFF (on demand, per branch) a branch touches only its claim's write surface, and
#              does not reach into an owned surface its claim was not granted.
#
# A thin wrapper over the verifier (tools/coordination/check_claims.py). With NO arguments it
# runs schema + duplicate over refs/claims/*; before any claims exist there is nothing to
# check, so it skips. Branch-diff is an on-demand mode (--claim ID --files-from FILE, or
# --branch REF), invoked by the dashboard/integrator per branch - not by the no-arg CI pass.
# Fixtures/tests pass --claims-dir DIR to read <trace-id>.yaml files instead of refs.
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
