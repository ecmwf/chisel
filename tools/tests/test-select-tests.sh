#!/usr/bin/env bash
# tools/tests/select_tests.py picks the tool tests a change can affect from covers.json. Its rules,
# on a synthetic map: with no base, or when the Python requirements changed, everything runs; a
# changed file selects the tests that read it; a directory entry selects for any file under
# it, a new one too; a test reading the whole repository runs on every change; a changed or an
# unmapped test always runs; a file no test reads selects nothing; an unmapped test is assumed to
# need the analysis toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT/tools/tests" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import select_tests as s

covers = {
    "tools/tests/test-a.sh": {"covers": ["tools/a.py", "tools/tests/test-a.sh"], "toolchain": False},
    "tools/tests/test-b.sh": {"covers": ["tools/lib/", "tools/tests/test-b.sh"], "toolchain": True},
    "tools/tests/test-all.sh": {"covers": [""], "toolchain": False},
}
tests = ["tools/tests/test-a.sh", "tools/tests/test-b.sh", "tools/tests/test-all.sh", "tools/tests/test-new.sh"]
cases = [
    ("no base to compare with: everything", None, tests),
    ("the Python requirements changed: everything", ["tools/requirements-ast.txt"], tests),
    ("the CI workflow changed: only what reads it (it runs itself)", [".github/workflows/ci.yml"],
     ["tools/tests/test-all.sh", "tools/tests/test-new.sh"]),
    ("a file one test reads: that test (and the whole-repo one, and the unmapped one)",
     ["tools/a.py"], ["tools/tests/test-a.sh", "tools/tests/test-all.sh", "tools/tests/test-new.sh"]),
    ("a new file under a directory a test reads whole: that test",
     ["tools/lib/new_module.py"], ["tools/tests/test-b.sh", "tools/tests/test-all.sh", "tools/tests/test-new.sh"]),
    ("a changed test: that test", ["tools/tests/test-a.sh"],
     ["tools/tests/test-a.sh", "tools/tests/test-all.sh", "tools/tests/test-new.sh"]),
    ("a file no test reads: only the whole-repo and the unmapped test", ["port/TRACE.yaml"],
     ["tools/tests/test-all.sh", "tools/tests/test-new.sh"]),
]
bad = 0
for label, files, want in cases:
    got = s.select(files, covers, tests)
    if got == want:
        print(f"ok - {label}")
    else:
        bad += 1
        print(f"not ok - {label}: got {got}")
tc = any(covers.get(t, {"toolchain": True})["toolchain"] for t in ["tools/tests/test-new.sh"])
if tc:
    print("ok - an unmapped test is assumed to need the analysis toolchain")
else:
    bad += 1
    print("not ok - an unmapped test is assumed to need the analysis toolchain")
sys.exit(1 if bad else 0)
PY
echo "# test-select-tests: all assertions passed"
