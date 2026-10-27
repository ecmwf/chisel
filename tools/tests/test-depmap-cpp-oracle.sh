#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# The dependency extractor decides which SOURCE lines are live under the pinned macro state with its
# own #if evaluator (tools/coordination/extract_dependencies.py, _line_liveness): it must answer
# UNKNOWN for a macro the port never pinned, which a real preprocessor cannot. Where every macro IS
# pinned, its answer must be the preprocessor's. This test generates nested #if/#ifdef/#ifndef/
# #elif/#else files with defined(), !, && and || at random (fixed seed), runs each through
# gfortran's own preprocessor with the same macro state (ON = -DNAME=1, OFF = undefined: pinned
# macros are plain flags, the extractor's documented reading), and requires the two to agree on
# every line. A missing gfortran or libclang fails the test; it never skips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
command -v gfortran >/dev/null || { echo "not ok - gfortran is installed"; exit 1; }

python3 - "$ROOT/tools/coordination" "$TMP" <<'PY'
import os, random, subprocess, sys
sys.path.insert(0, sys.argv[1])
import extract_dependencies as ed
tmp = sys.argv[2]
rng = random.Random(20261027)
MACROS = ["M1", "M2", "M3", "M4", "M5"]
counter = [0]

def expr(depth):
    if depth <= 0 or rng.random() < 0.35:
        m = rng.choice(MACROS)
        return rng.choice([m, f"defined({m})", f"defined {m}", rng.choice(["0", "1"])])
    kind = rng.choice(["not", "and", "or", "paren"])
    if kind == "not":
        return f"!{expr(depth - 1)}" if rng.random() < 0.5 else f"!({expr(depth - 1)})"
    if kind == "paren":
        return f"({expr(depth - 1)})"
    return f"{expr(depth - 1)} {'&&' if kind == 'and' else '||'} {expr(depth - 1)}"

def body():
    counter[0] += 1
    return [f"      X{counter[0]} = {counter[0]}"]

def block(depth):
    out = []
    for _ in range(rng.randint(1, 3)):
        if depth > 0 and rng.random() < 0.5:
            head = rng.choice(["ifdef", "ifndef", "if"])
            out.append(f"#{head} {rng.choice(MACROS) if head != 'if' else expr(2)}")
            out += block(depth - 1)
            for _ in range(rng.randint(0, 2)):
                out.append(f"#elif {expr(2)}")
                out += block(depth - 1)
            if rng.random() < 0.5:
                out.append("#else")
                out += block(depth - 1)
            out.append("#endif")
        else:
            out += body()
    return out

files = cases = 0
for n in range(300):
    counter[0] = 0
    lines = block(3)
    state = {m: rng.random() < 0.5 for m in MACROS}
    path = os.path.join(tmp, f"case{n}.F90")
    with open(path, "w") as fh:
        fh.write("\n".join(lines) + "\n")
    live = ed._line_liveness(path, {m: (v, "test") for m, v in state.items()})
    flags = [f"-D{m}=1" for m, v in state.items() if v]
    p = subprocess.run(["gfortran", "-cpp", "-E", "-P"] + flags + [path], capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"not ok - gfortran -E failed on {path}: {p.stderr.strip()[:300]}")
    kept = set(ln.split("=")[0].strip() for ln in p.stdout.splitlines() if "=" in ln)
    files += 1
    for i, ln in enumerate(lines, 1):
        if ln.startswith("#"):
            continue
        cases += 1
        name = ln.split("=")[0].strip()
        want = name in kept
        got = live[i][0]
        if got is not want:
            print(f"not ok - line {i} ({name}) of a generated file: the preprocessor keeps it: {want}, "
                  f"the extractor says {got} ({live[i][1]})")
            print("    macro state: " + ", ".join(f"{m}={'ON' if v else 'OFF'}" for m, v in state.items()))
            print("\n".join("    " + l for l in lines))
            sys.exit(1)
print(f"ok - the extractor's line liveness agrees with gfortran's preprocessor on {cases} lines of {files} generated files")
PY
echo "# test-depmap-cpp-oracle: all assertions passed"
