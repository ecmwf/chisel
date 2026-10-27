#!/usr/bin/env python3
"""trace-covers.py - record which repository files each tool test reads, for test selection.

Runs every test registered in tools/tests/run.sh under strace and writes tools/tests/covers.json:
for each test, the tracked files it opened or executed (an import served from a bytecode cache
counts as its source), and whether it needs the analysis toolchain (clang, clang-tidy, gfortran,
libclang, fparser) that CI installs only when a selected test needs it. A test that reads every
tracked file of a directory covers the directory, so a file added there selects it too; one that
reads the whole repository covers everything. tools/tests/select_tests.py reads the result to run only
the tests a change can affect.

The map is measured, never written by hand. Regenerate it after adding a test or changing what a
test reads: `python3 tools/tests/trace-covers.py`. `--check` exits 1 when the committed map is
stale (the nightly CI run does this); exit 2 when strace or git is missing.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
MAP = os.path.join(ROOT, "tools", "tests", "covers.json")
FD_PATH = re.compile(r'<(/[^>]+)>|execve\("([^"]+)"')
TOOLCHAIN = re.compile(r'/(?:clang(?:-tidy)?(?:-\d+)?|gfortran(?:-\d+)?)$|libclang[^/]*\.so|/fparser/')


def tests():
    # the entries of run.sh's TESTS array: one test path per line, indented
    return re.findall(r'^\s+(tools/tests/[\w.-]+\.sh)\s*$', open(os.path.join(ROOT, "tools", "tests", "run.sh")).read(), re.M)


def tracked():
    """The repository's files: tracked, and new ones not ignored (so a map made before a commit
    already knows them)."""
    out = subprocess.run(["git", "-C", ROOT, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                         capture_output=True, text=True, check=True).stdout
    return sorted(set(f for f in out.split("\0") if f))


def trace(test, scratch):
    log = os.path.join(scratch, os.path.basename(test) + ".log")
    env = dict(os.environ, TMPDIR=scratch)
    subprocess.run(["strace", "-f", "-qq", "-y", "-e", "trace=openat,execve", "-o", log, "bash", test],
                   cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    files, toolchain = set(), False
    for ln in open(log, errors="replace"):
        for m in FD_PATH.finditer(ln):
            p = m.group(1) or m.group(2)
            if TOOLCHAIN.search(p):
                toolchain = True
            p = os.path.realpath(p)
            if not p.startswith(ROOT + os.sep):
                continue
            rel = p[len(ROOT) + 1:]
            src = re.match(r'(.*)/__pycache__/([^./]+)\.[^/]*\.pyc$', rel)
            if src:  # an import served from the bytecode cache: the source it was compiled from
                rel = f"{src.group(1)}/{src.group(2)}.py"
            files.add(rel)
    return files, toolchain


def compress(read, all_files):
    """Directories every tracked file of which was read become one 'dir/' entry; reading every
    tracked file of the repository becomes ['']."""
    read = set(read) & set(all_files)
    under = {}
    for f in all_files:
        parts = f.split("/")
        for i in range(len(parts)):
            under.setdefault("/".join(parts[:i]), []).append(f)
    full = {d for d, fs in under.items() if all(f in read for f in fs)}
    if "" in full:
        return [""]
    out = set()
    for f in read:
        parts = f.split("/")
        top = next(("/".join(parts[:i]) for i in range(1, len(parts)) if "/".join(parts[:i]) in full), None)
        out.add(top + "/" if top else f)
    return sorted(out)


def build(jobs):
    if shutil.which("strace") is None:
        sys.exit("trace-covers: strace is needed to trace the tests (UNRELIABLE)")
    all_files = tracked()
    with tempfile.TemporaryDirectory(prefix="trace-covers-") as scratch:
        with ThreadPoolExecutor(max_workers=jobs) as pool:
            res = list(pool.map(lambda t: (t, *trace(t, scratch)), tests()))
    return {t: {"covers": compress(files, all_files), "toolchain": tc} for t, files, tc in sorted(res)}


def main(argv):
    jobs = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else (os.cpu_count() or 2)
    data = build(jobs)
    text = json.dumps(data, indent=1, sort_keys=True) + "\n"
    if argv[1:] == ["--check"]:
        current = open(MAP, encoding="utf-8").read() if os.path.isfile(MAP) else ""
        if current != text:
            print("trace-covers: tools/tests/covers.json is stale - regenerate it: python3 tools/tests/trace-covers.py")
            return 1
        print("trace-covers: tools/tests/covers.json is current")
        return 0
    open(MAP, "w", encoding="utf-8").write(text)
    print(f"trace-covers: wrote {os.path.relpath(MAP, ROOT)} ({len(data)} tests)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
