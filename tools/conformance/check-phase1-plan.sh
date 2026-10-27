#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

#
# check-phase1-plan.sh - committed port/phase1-plan.yaml must match what the fragments generate.
#
# Shard-and-generate (mirrors check-trace-drift.sh / references/team-coordination.md +
# references/parallel-phase-1.md): the canonical port/phase1-plan.yaml is GENERATED from the
# per-unit fragments (port/phase1/units/<id>.yaml) + port/phase1/_meta.yaml, never hand-merged.
# This check regenerates from the fragments and fails if the committed plan disagrees - the
# guard that lets parallel sibling branches edit DISJOINT unit fragment files and never
# hand-merge the one central plan (the shared-registry collision class git resolves silently
# and wrongly).
#
# A thin wrapper over the deterministic generator:
#   tools/coordination/generate_phase1_plan.py --check
# The comparison is on parsed YAML data models (robust to comment/formatting differences).
# Before any unit fragments exist there is nothing to generate, so it skips (a small or serial
# Phase 1 may keep the monolithic scaffolded plan).
#
# Exit-code contract (mirrors check-trace-drift.sh):
#   0  GREEN       committed plan matches the fragments (or no fragments exist yet)
#   1  RED         the committed plan drifts from the fragments
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / meta / not a git repo)
#
# A detector is trusted only after it is seen to fail (STANDING RULE 7).
# Seeded-bug record: tools/conformance/seeded-bugs/check-phase1-plan.md

set -uo pipefail

command -v python3 >/dev/null 2>&1 \
    || { echo "check-phase1-plan: python3 not found" >&2; exit 2; }
command -v git >/dev/null 2>&1 \
    || { echo "check-phase1-plan: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-phase1-plan: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/generate_phase1_plan.py" --check "$@"
