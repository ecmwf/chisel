#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

bash "$ROOT/tools/tests/test-chisel-init.sh"
bash "$ROOT/tools/tests/test-flow-diagram.sh"
bash "$ROOT/tools/tests/test-product-invisibility.sh"
bash "$ROOT/tools/tests/test-proof-vocabulary.sh"
bash "$ROOT/tools/tests/test-provision-worker.sh"
bash "$ROOT/tools/tests/test-shape-guards.sh"
bash "$ROOT/tools/tests/test-status-fragment-identity.sh"
bash "$ROOT/tools/tests/test-sync-land-guard.sh"
bash "$ROOT/tools/tests/test-verify-anchors.sh"
bash "$ROOT/tools/tests/test-teardown-evidence-guard.sh"
bash "$ROOT/tools/tests/test-worktree-freshness-root.sh"
