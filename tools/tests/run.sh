#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# The tool tests. With no argument, every test registered below runs; with arguments (paths such as
# tools/tests/test-x.sh), only those. SKIP_TESTS (space-separated paths) leaves some out: CI skips the
# slow anchor-verifier tests on a pull request that does not touch what they check (.github/workflows/ci.yml).
# A new test is registered here.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

TESTS=(
	tools/tests/test-anchor-values.sh
	tools/tests/test-build-flags.sh
	tools/tests/test-build-prototypes.sh
	tools/tests/test-build-sanitized.sh
	tools/tests/test-build-tidy.sh
	tools/tests/test-check-completeness.sh
	tools/tests/test-chisel-init.sh
	tools/tests/test-chisel-init-models.sh
	tools/tests/test-chisel-init-e2e.sh
	tools/tests/test-common-writers.sh
	tools/tests/test-compiler-graph.sh
	tools/tests/test-depmap-cpp-oracle.sh
	tools/tests/test-depmap-macro-guard.sh
	tools/tests/test-flow-diagram.sh
	tools/tests/test-git-paths-z.sh
	tools/tests/test-index-helpers.sh
	tools/tests/test-integrate-land-reviewed.sh
	tools/tests/test-integrate-product-tip.sh
	tools/tests/test-migrate-anchor-grammar.sh
	tools/tests/test-migrate-opencode-dirs.sh
	tools/tests/test-new-instance.sh
	tools/tests/test-no-home-paths.sh
	tools/tests/test-no-silenced-detectors.sh
	tools/tests/test-product-invisibility.sh
	tools/tests/test-product-root-checks.sh
	tools/tests/test-product-tu.sh
	tools/tests/test-proof-vocabulary.sh
	tools/tests/test-push-claim.sh
	tools/tests/test-provision-worker.sh
	tools/tests/test-scan-guarded-macros.sh
	tools/tests/test-run-conformance.sh
	tools/tests/test-review-patch.sh
	tools/tests/test-running-agents.sh
	tools/tests/test-schedule.sh
	tools/tests/test-select-tests.sh
	tools/tests/test-shape-guards.sh
	tools/tests/test-status-fragment-data.sh
	tools/tests/test-status-fragment-identity.sh
	tools/tests/test-stamp-author-id.sh
	tools/tests/test-sync-land-guard.sh
	tools/tests/test-sync-merge.sh
	tools/tests/test-vector-math.sh
	tools/tests/test-verify-anchors.sh
	tools/tests/test-verify-anchors-cases.sh
	tools/tests/test-verify-anchors-corpus.sh
	tools/tests/test-teardown-evidence-guard.sh
	tools/tests/test-trace-evidence-data.sh
	tools/tests/test-worktree-freshness-root.sh
	tools/tests/test-yaml-callers.sh
	tools/tests/test-yaml-get.sh
)
[ "$#" -gt 0 ] && TESTS=("$@")
for t in "${TESTS[@]}"; do
	case " ${SKIP_TESTS:-} " in *" $t "*) echo "# skipped: $t"; continue ;; esac
	bash "$ROOT/$t"
done
