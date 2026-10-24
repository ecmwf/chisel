#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

bash "$ROOT/tools/tests/test-chisel-init.sh"
bash "$ROOT/tools/tests/test-product-invisibility.sh"
bash "$ROOT/tools/tests/test-provision-worker.sh"
bash "$ROOT/tools/tests/test-sync-land-guard.sh"
