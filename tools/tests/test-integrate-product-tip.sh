#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# integrate_product.sh lands the commit that was proven, never a later one: the product branch's tip
# must be the unit's fragment proof.commit. A workbench copy of tools/ with the planner and the
# conformance suite stubbed (both are checked elsewhere) and a local product repo: the proven tip
# lands; a branch that gained a commit after its proof is refused, and so is a fragment with no
# proof.commit; a refused land leaves the product mainline where it was.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n%s\n' "$1" "${2:-}" >&2; failures=$((failures + 1)); }

# The workbench: the real tools, with the planner recommending u1 and the suite green.
W="$TMP/work/wb"
mkdir -p "$W/port/status"
cp -r "$ROOT/tools" "$W/tools"
printf 'print("integrate u1")\n' >"$W/tools/coordination/autodrive.py"
printf '#!/usr/bin/env bash\nexit 0\n' >"$W/tools/run-conformance.sh"
printf 'repo: "file://%s/prod.git"\ncheckout: "../prod"\ndefault_branch: main\nattested_commit: none\n' "$TMP" \
	>"$W/port/product.yaml"
git -C "$W" init -q -b main && git -C "$W" add -A && git -C "$W" commit -q -m wb

# The product: main, and work/u1 one commit ahead of it.
P="$TMP/work/prod"
git init -q -b main "$P"
printf 'int a;\n' >"$P/a.c" && git -C "$P" add -A && git -C "$P" commit -q -m base
git -C "$P" checkout -q -b work/u1
printf 'int b;\n' >"$P/b.c" && git -C "$P" add -A && git -C "$P" commit -q -m "port u1"
PROVEN="$(git -C "$P" rev-parse HEAD)"
git -C "$P" checkout -q main
BASE="$(git -C "$P" rev-parse main)"

land() { (cd "$W" && bash tools/coordination/integrate_product.sh u1 --no-push 2>&1); }
fragment() { printf 'id: u1\nstatus: proven\nproof:\n  tier: R1\n%s\n' "$1" >"$W/port/status/u1.yaml"; }

# A commit after the proof: refused, mainline untouched.
git -C "$P" checkout -q work/u1
printf 'int c;\n' >>"$P/b.c" && git -C "$P" commit -q -am "after the proof"
git -C "$P" checkout -q main
fragment "  commit: $PROVEN"
rc=0; out="$(land)" || rc=$?
if [ "$rc" -eq 2 ] && grep -q "moved after its proof" <<<"$out" && [ "$(git -C "$P" rev-parse main)" = "$BASE" ]; then
	ok "a branch that moved after its proof is refused, and nothing lands"
else
	not_ok "a branch that moved after its proof is refused, and nothing lands" "exit $rc: $out"
fi

# No proof.commit: refused.
fragment "  path: docs/evidence/u1/proof.md"
rc=0; out="$(land)" || rc=$?
if [ "$rc" -eq 2 ] && grep -q "no proof.commit" <<<"$out" && [ "$(git -C "$P" rev-parse main)" = "$BASE" ]; then
	ok "a fragment with no proof.commit is refused"
else
	not_ok "a fragment with no proof.commit is refused" "exit $rc: $out"
fi

# The proven tip: lands.
git -C "$P" branch -q -f work/u1 "$PROVEN"
fragment "  commit: $PROVEN"
rc=0; out="$(land)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(git -C "$P" rev-parse main)" != "$BASE" ] && [ -f "$P/b.c" ]; then
	ok "the proven tip lands as one squashed commit"
else
	not_ok "the proven tip lands as one squashed commit" "exit $rc: $out"
fi

[ "$failures" -eq 0 ] || { echo "# test-integrate-product-tip: $failures failure(s)" >&2; exit 1; }
echo "# test-integrate-product-tip: all assertions passed"
