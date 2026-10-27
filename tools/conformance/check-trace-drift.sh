#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

#
# check-trace-drift.sh - canonical TRACE must match what the fragments generate.
#
# Shard-and-generate (references/team-coordination.md): canonical port/TRACE.yaml is
# GENERATED from the per-work-item fragments (port/status/*.yaml), never hand-merged.
# This check regenerates from the fragments and fails if the committed TRACE disagrees -
# the guard that lets many contributors write fragments in their own branches while one
# canonical TRACE stays correct. It is the cutover check: until this check is live and
# seeded, the central-write commands stay serial.
#
# A thin wrapper over the deterministic generator (tools/coordination/generate_trace.py
# --check); compares parsed DATA MODELS (robust to formatting/comments), normalizing row
# order by id. Before any fragments exist (single-operator pilot) there is nothing to
# generate, so it skips.
#
# Exit-code contract:
#   0  GREEN       committed TRACE matches the fragments (or there are no fragments yet)
#   1  RED         the committed TRACE drifts from the fragments
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / meta / not a git repo)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-trace-drift: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-trace-drift: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-trace-drift: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/generate_trace.py" --check "$@"
