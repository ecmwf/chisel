#!/usr/bin/env bash
#
# check-depmap.sh - the committed dependency map must match what SOURCE generates.
#
# references/team-coordination.md: the ready-set and the owned/leaf partition are computed from the
# SOURCE dependency map, and the file inventory it carries is check-completeness's independent SOURCE
# accounting, so the map must never silently go stale. The map is GENERATED from SOURCE by
# tools/coordination/extract_dependencies.py (the inventory + the PROVEN in-tree use/call edges +
# the structural owned/shared surfaces); this check regenerates from SOURCE and
# fails if the committed map (tools/scoping/dependency-map.yaml, project layer) disagrees - the
# same generate-and-drift-check guard the canonical TRACE uses. Before a map is committed
# (single-operator pilot, or Phase 0 scoping not yet done) there is nothing to check, so it
# skips. Fixtures/tests pass --map FILE [--source-root DIR] to point at a fixture map.
#
# Exit-code contract:
#   0  GREEN       the committed map matches SOURCE (or there is none yet)
#   1  RED         the committed map drifts from SOURCE (regenerate it)
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / git / source root missing)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-depmap: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-depmap: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-depmap: not inside a git repository" >&2; exit 2; }

# Pin the SOURCE root to the repo's own source/ tree; a committed map that names a different
# source_root is a drift (the map was generated against the wrong tree). Fixtures/tests pass a
# trailing --source-root, which wins (argparse takes the last).
exec python3 "$ROOT/tools/coordination/extract_dependencies.py" --check --source-root "$ROOT/source" "$@"
