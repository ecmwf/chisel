#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""select_tests.py - the tool tests a change can affect, from tools/tests/covers.json.

Usage: select_tests.py [--base REF] [--github-output]
Prints the selected tests (one per line), or every registered test when the change cannot be
narrowed. With --github-output it also writes `tests` (space-separated), `count` and `toolchain`
(true when a selected test needs the analysis toolchain) to $GITHUB_OUTPUT.

A test is selected when a changed file is one it reads (covers.json, measured by trace-covers.py),
when the test itself changed, or when covers.json does not know it yet (a new test). Everything
runs when there is no base or no map to compare with, or when the Python environment changes
(pyproject.toml, uv.lock, .python-version: they change what every test runs on). A file no test reads selects nothing: no test
exercises it.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
EVERYTHING = {"pyproject.toml", "uv.lock", ".python-version"}


def registered():
    # the entries of run.sh's TESTS array: one test path per line, indented
    return re.findall(r'^\s+(tools/tests/[\w.-]+\.sh)\s*$', open(os.path.join(ROOT, "tools", "tests", "run.sh")).read(), re.M)


def changed(base):
    """The files changed between base and HEAD, or None when that cannot be said."""
    if not base:
        return None
    p = subprocess.run(["git", "-C", ROOT, "diff", "-z", "--name-only", f"{base}...HEAD"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    return [f for f in p.stdout.split("\0") if f]


def select(files, covers, tests):
    if files is None or any(f in EVERYTHING for f in files):
        return list(tests)
    out = []
    for t in tests:
        entry = covers.get(t)
        if entry is None or t in files or any(f == c or (c.endswith("/") and f.startswith(c)) or c == ""
                                              for f in files for c in entry["covers"]):
            out.append(t)
    return out


def main(argv):
    base = argv[argv.index("--base") + 1] if "--base" in argv else None
    tests = registered()
    try:
        covers = json.load(open(os.path.join(ROOT, "tools", "tests", "covers.json"), encoding="utf-8"))
    except (OSError, ValueError):
        covers, base = {}, None          # no map: run everything
    picked = select(changed(base), covers, tests)
    toolchain = any(covers.get(t, {"toolchain": True})["toolchain"] for t in picked)
    for t in picked:
        print(t)
    print(f"select: {len(picked)} of {len(tests)} tool test(s); toolchain {'needed' if toolchain else 'not needed'}",
          file=sys.stderr)
    if "--github-output" in argv and os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as fh:
            fh.write(f"tests={' '.join(picked)}\ncount={len(picked)}\ntoolchain={'true' if toolchain else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
