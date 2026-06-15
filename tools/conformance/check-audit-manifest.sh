#!/usr/bin/env bash
#
# check-audit-manifest.sh - audit manifests bind a product commit to verified evidence.
#
# Two-repo model (references/two-repo-architecture.md, C4): each integrated deliverable
# has a manifest (port/manifests/<id>.yaml) in the WORKBENCH binding the squashed PRODUCT
# commit to its gate/review evidence. This check recomputes that binding and fails if the
# evidence was produced against a different tree (the stale-evidence gap) or does not
# resolve - the machine-checkable attestation the workbench owes the product.
#
# A thin wrapper over the verifier (tools/coordination/check_manifest.py). Before any
# manifests exist (pre-split, single-operator) there is nothing to check, so it skips.
#
# Exit-code contract:
#   0  GREEN       every manifest verifies (or there are none yet)
#   1  RED         a manifest's evidence binding does not verify
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / product checkout / not a git repo)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-audit-manifest: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-audit-manifest: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-audit-manifest: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/check_manifest.py" "$@"
