#!/usr/bin/env bash
#
# check-bindings.sh - the CROSS-ARTIFACT bindings hold (no single check can see them).
#
# Every other coordination check validates one artifact alone: check-status-fragments a
# fragment, check-claims a claim ref, check-audit-manifest a manifest, check-depmap the map.
# The trust claim - "claimed by who it says, gated on the evidence it cites, integrated as the
# manifest attests, and the product mainline is exactly what we attested" - lives in the JOINS
# between them, which no isolated check sees. This gate recomputes those joins:
#   FILENAME  port/status/<id>.yaml has id == <id>;
#   CLAIM     a fragment's claim block binds to the real refs/claims/<id> (ref name, existence,
#             claimant) - a fragment citing a claim while the namespace is absent is RED;
#   MANIFEST  an integrated fragment binds to port/manifests/<id>.yaml whose deliverable,
#             product/gate commits, and gate/review evidence equal the fragment's;
#   PRODUCT   each manifest's product.repo equals port/product.yaml repo;
#   ATTESTED  the product default_branch is exactly attested_commit (no unattested commit ahead),
#             which IS an integrated manifest's product.commit and caps the manifest chain.
#
# A thin wrapper over the verifier (tools/coordination/check_bindings.py). Before any
# coordination artifacts are wired there is nothing to join, so it skips. Fixtures/tests pass
# --claims-dir / --product-root / --status-dir / --manifests-dir / --product-yaml.
#
# Exit-code contract:
#   0  GREEN       every cross-artifact binding holds (or nothing is wired yet)
#   1  RED         a binding does not hold (fragment<->claim<->manifest<->product<->mainline)
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / git, product wired but absent, malformed input)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-bindings: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-bindings: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-bindings: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/check_bindings.py" "$@"
