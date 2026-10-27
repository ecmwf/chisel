#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# Who writes a shared COMMON block decides what may be ported in parallel. compiler_graph.py finds the
# writers in gfortran's GIMPLE, and extract_dependencies.py guards only them. The fixture:
#   /state/  written by setup (an assignment), read by user1 and user2 (one through sin());
#   /cfg/    given initial values by the BLOCK DATA init, read by user1;
#   /io/     written by reads (a READ into it) and by pass (handed to a procedure), read by user3.
# Expected: setup owns /state/ and init owns /cfg/, their readers wait on them through data edges and
# are not guarded; /io/ has two writers, which stay guarded, and its reader user3 is free. Without the
# compiler graph, every file sharing a block is guarded, as before.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GRAPH="$ROOT/tools/coordination/compiler_graph.py"
EXTRACT="$ROOT/tools/coordination/extract_dependencies.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
failures=0
check() {
	local name="$1"; shift
	if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name" >&2; failures=$((failures + 1)); fi
}

W="$TMP/wb"
S="$W/source/src"
mkdir -p "$S" "$W/build"
git init -q "$W"
unit() { printf '%s\n' "$2" >"$S/$1.f90"; }
unit setup  $'subroutine setup()\n  real :: s1\n  common /state/ s1\n  s1 = 2.0\nend subroutine'
unit user1  $'subroutine user1(y)\n  real :: y, s1, k\n  common /state/ s1\n  common /cfg/ k\n  y = s1 + k\nend subroutine'
unit user2  $'subroutine user2(y)\n  real :: y, s1\n  common /state/ s1\n  y = sin(s1)\nend subroutine'
unit init   $'block data init\n  real :: k\n  common /cfg/ k\n  data k /1.0/\nend block data'
unit reads  $'subroutine reads()\n  real :: v\n  common /io/ v\n  read(*,*) v\nend subroutine'
unit pass   $'subroutine pass()\n  real :: v\n  common /io/ v\n  call consume(v)\nend subroutine'
unit user3  $'subroutine user3(y)\n  real :: y, v\n  common /io/ v\n  y = v\nend subroutine'
git -C "$W" add -A && git -C "$W" commit -q -m source

python3 - "$W" <<'PY'
import json, subprocess, sys
w = sys.argv[1]; entries = []
for u in ("setup", "user1", "user2", "init", "reads", "pass", "user3"):
    args = ["gfortran", "-O0", "-c", "%s/source/src/%s.f90" % (w, u), "-o", "%s/build/%s.o" % (w, u)]
    subprocess.run(args, check=True, cwd=w + "/build")
    entries.append({"directory": w + "/build", "file": "%s/source/src/%s.f90" % (w, u), "arguments": args})
json.dump(entries, open(w + "/build/compile_commands.json", "w"))
PY
(cd "$W" && python3 "$GRAPH" --compile-commands build/compile_commands.json --source-root source --out "$TMP/graph.yaml") >/dev/null
writers() { python3 -c 'import sys,yaml; print(" ".join("%s=%s" % (c["name"], ",".join(w.split("/")[-1][:-4] for w in c["writers"])) for c in yaml.safe_load(open(sys.argv[1]))["commons"]))' "$TMP/graph.yaml"; }
check "the writers are found: an assignment, a BLOCK DATA, a READ, a procedure argument" \
	[ "$(writers)" = "cfg=init io=pass,reads state=setup" ]

printf 'macro_state: {}\n' >"$TMP/macros.yaml"
map() { (cd "$W" && python3 "$EXTRACT" --source-root source --generator-edges /dev/null --macro-state "$TMP/macros.yaml" "$@") >"$TMP/map.yaml"; }
q() { python3 -c "import sys,yaml; m=yaml.safe_load(open(sys.argv[1])); n={x['id']: x for x in m['nodes']}; e={(x['from'], x['to'], x['kind']) for x in m['edges']}; s={x['name']: x for x in m['owned_surfaces']}; sys.exit(0 if ($1) else 1)" "$TMP/map.yaml"; }
map --compiler-graph "$TMP/graph.yaml"
check "the single writer owns the block" q "s['common:/state/']['owner'] == 'setup' and s['common:/cfg/']['owner'] == 'init'"
check "readers wait for the writer through a data edge" q "{('user1','setup','data'), ('user2','setup','data'), ('user1','init','data')} <= e"
check "readers of a block with one writer are not guarded" q "n['user1']['self_serve_eligible'] and n['user2']['self_serve_eligible']"
check "two writers of a block stay guarded" q "n['reads']['guarded_reasons'] == ['shared-surface:common:/io/'] and n['pass']['guarded_reasons'] == ['shared-surface:common:/io/']"
check "the reader of a block with two writers is free and waits for both" q "n['user3']['self_serve_eligible'] and {('user3','pass','data'), ('user3','reads','data')} <= e"
map
check "without the graph, every file sharing a block is guarded" q "not n['user1']['self_serve_eligible'] and not n['user3']['self_serve_eligible']"

[ "$failures" -eq 0 ] || { echo "# test-common-writers: $failures failure(s)" >&2; exit 1; }
echo "# test-common-writers: all assertions passed"
