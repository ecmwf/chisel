#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# The dependency extractor draws an edge only from a line the pinned configuration compiles. The
# fixture tools/coordination/fixtures/depmap-guarded/ has one consumer whose ONLY references to its
# producer - a USE and a CALL - sit inside `#ifdef DEMO_FEATURE`, so the three outcomes of the
# macro-state contract are observable through the shipped CLI:
#   - DEMO_FEATURE pinned OFF  -> neither edge is drawn (the guarded lines are dead);
#   - DEMO_FEATURE pinned ON   -> both edges are drawn;
#   - DEMO_FEATURE not pinned  -> UNRELIABLE (exit 2) naming the macro - never a guess either way.
# The extractor reads the guarded regions through clang's raw lexer, so this runs the installed clang.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EXTRACT="$ROOT/tools/coordination/extract_dependencies.py"
FIX="$ROOT/tools/coordination/fixtures/depmap-guarded"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
failt() { printf 'not ok - %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }

# extract [--macro-state FILE]: run the extractor on the fixture tree; sets $out (the map, stdout),
# $err (stderr) and $rc.
extract() {
	set +e
	out="$(cd "$ROOT" && python3 "$EXTRACT" --source-root "$FIX/source" --generator-edges /dev/null "$@" 2>"$TMP/err")"
	rc=$?
	set -e
	err="$(cat "$TMP/err")"
}

# edges: the emitted map's edges, one "from -> to (kind)" per line, sorted. Fails unless the output
# is a map holding exactly the fixture's two nodes, so a garbled or empty map never reads as "no edge".
edges() {
	printf '%s\n' "$out" | python3 -c '
import sys, yaml
m = yaml.safe_load(sys.stdin)
if not isinstance(m, dict) or sorted(n.get("id") for n in m.get("nodes") or []) != ["consumer", "producer"]:
    sys.exit("not a map of the two fixture nodes: %r" % (m,))
for e in sorted((e["from"], e["to"], e["kind"]) for e in m.get("edges") or []):
    print("%s -> %s (%s)" % e)'
}

extract --macro-state "$FIX/macro-off.yaml"
[ "$rc" = 0 ] || failt "pinned OFF: the extractor runs (expected exit 0, got $rc)" "$err"
got="$(edges)" || failt "pinned OFF: the extractor emits the fixture's map" "$out"
[ -z "$got" ] || failt "pinned OFF: no edge is drawn from the guarded lines" "$got"
pass "pinned OFF: no edge is drawn from the guarded lines"

extract --macro-state "$FIX/macro-on.yaml"
[ "$rc" = 0 ] || failt "pinned ON: the extractor runs (expected exit 0, got $rc)" "$err"
got="$(edges)" || failt "pinned ON: the extractor emits the fixture's map" "$out"
want="consumer -> producer (call)
consumer -> producer (use)"
[ "$got" = "$want" ] || failt "pinned ON: the guarded USE and CALL edges are drawn" "$got"
pass "pinned ON: the guarded USE and CALL edges are drawn"

extract
[ "$rc" = 2 ] || failt "not pinned: UNRELIABLE (expected exit 2, got $rc)" "$out$err"
case "$err" in *"consumer.f90:8:"*DEMO_FEATURE*) ;; *) failt "not pinned: the refusal names the line and the macro" "$err" ;; esac
pass "not pinned: UNRELIABLE, naming the line and the macro"
