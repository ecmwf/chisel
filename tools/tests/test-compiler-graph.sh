#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# compiler_graph.py reads a gfortran build of the SOURCE through its compile_commands.json, and
# extract_dependencies.py adds what it finds to the map. The fixture has what a line scan misses:
# work.F90 calls helper over a continuation line and the external function twice without CALL (both
# in ext.f90), uses module base through an #include of uses.h, reads base's variable, and shares
# COMMON /blk/ with other.f90. The graph has all of it, the map gains it only with the graph, a graph
# made from another SOURCE tree is refused, and so are uncommitted SOURCE changes and a missing object.
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
cat >"$S/base.f90" <<'EOF'
module base
  implicit none
  real :: level = 1.0
end module
EOF
printf '  use base\n' >"$S/uses.h"
cat >"$S/ext.f90" <<'EOF'
subroutine helper(y)
  real :: y
  y = y + 1.0
end subroutine
real function twice(x)
  real :: x
  twice = 2.0 * x
end function
EOF
cat >"$S/work.F90" <<'EOF'
module work_m
#include "uses.h"
  implicit none
contains
  subroutine work(y)
    real :: y
    real :: c1
    common /blk/ c1
    real, external :: twice
    y = twice(y) + level + c1
    call &
      helper(y)
  end subroutine
end module
EOF
cat >"$S/other.f90" <<'EOF'
subroutine other()
  real :: c1
  common /blk/ c1
  c1 = 2.0
end subroutine
EOF
git -C "$W" add -A && git -C "$W" commit -q -m source

# The build, recorded the way Bear or CMake records it.
python3 - "$W" <<'PY'
import json, subprocess, sys
w = sys.argv[1]; entries = []
for f in ("base.f90", "ext.f90", "work.F90", "other.f90"):
    args = ["gfortran", "-O0", "-I%s/source/src" % w, "-J%s/build" % w, "-c", "%s/source/src/%s" % (w, f),
            "-o", "%s/build/%s.o" % (w, f)]
    subprocess.run(args, check=True, cwd=w + "/build")
    entries.append({"directory": w + "/build", "file": "%s/source/src/%s" % (w, f), "arguments": args})
json.dump(entries, open(w + "/build/compile_commands.json", "w"))
PY
graph() { (cd "$W" && python3 "$GRAPH" --compile-commands build/compile_commands.json --source-root source --out "$TMP/graph.yaml" "$@"); }
graph >/dev/null
G="$(python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$TMP/graph.yaml")"
has() { python3 -c "import json,sys; g=json.loads(sys.argv[1]); e={(x['from'],x['to'],x['kind']): x['via'] for x in g['edges']}; sys.exit(0 if ($1) else 1)" "$G"; }
check "the calls over a continuation line and without CALL are seen" has "e.get(('src/work.F90','src/ext.f90','call')) == ['helper_', 'twice_']"
check "the USE inside an included file is seen" has "e.get(('src/work.F90','src/base.f90','use')) == ['base']"
check "the read of a module variable is seen" has "e.get(('src/work.F90','src/base.f90','data')) == ['__base_MOD_level']"
check "the included file is seen" has "('src/work.F90','src/uses.h','include') in e"
check "the shared COMMON block and its writer are seen" has "g['commons'] == [{'name': 'blk', 'members': ['src/other.f90', 'src/work.F90'], 'writers': ['src/other.f90']}]"

printf 'macro_state: {}\n' >"$TMP/macros.yaml"
extract() { (cd "$W" && python3 "$EXTRACT" --source-root source --generator-edges /dev/null --macro-state "$TMP/macros.yaml" "$@"); }
edges() { extract "$@" | python3 -c 'import sys,yaml; print(" ".join(sorted("%s>%s:%s" % (e["from"], e["to"], e["kind"]) for e in yaml.safe_load(sys.stdin)["edges"])))'; }
with="$(edges --compiler-graph "$TMP/graph.yaml")"
without="$(edges)"
check "the map gains the compiler's call edge" grep -q 'work>ext:call' <<<"$with"
check "the map gains the compiler's use and data edges" grep -q 'work>base:data work>base:use' <<<"$with"
check "without the graph the map has no edge from work to ext" bash -c "! grep -q 'work>ext' <<<'$without'"

printf '! a later change\n' >>"$S/other.f90"
git -C "$W" commit -q -am "change the SOURCE"
rc=0; out="$(extract --compiler-graph "$TMP/graph.yaml" 2>&1)" || rc=$?
check "a graph made from another SOURCE tree is refused" bash -c "[ $rc -ne 0 ] && grep -q 'stale' <<<'$out'"

printf '! uncommitted\n' >>"$S/other.f90"
rc=0; graph >/dev/null 2>&1 || rc=$?
check "uncommitted SOURCE changes are UNRELIABLE" [ "$rc" -eq 2 ]
git -C "$W" checkout -q -- source
rm "$W/build/ext.f90.o"
rc=0; graph >/dev/null 2>&1 || rc=$?
check "a missing object is UNRELIABLE" [ "$rc" -eq 2 ]

[ "$failures" -eq 0 ] || { echo "# test-compiler-graph: $failures failure(s)" >&2; exit 1; }
echo "# test-compiler-graph: all assertions passed"
