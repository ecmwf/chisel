#!/usr/bin/env python3
"""check-sanitized.py - run the product's tests on a sanitizer build, and stop at the first error.

AddressSanitizer catches an out-of-bounds read or write at first touch (a wrong stride or extent,
failure mode L4; a wrong index base, T10/T30) and UndefinedBehaviorSanitizer catches what C leaves
undefined where Fortran did not (signed-integer overflow, T13; a float-to-integer conversion out of
range; a bad shift) - references/langs/c.md, "Runtime sanitizers". A sanitizer build is a diagnostic
build: acceptance comparisons still run on the deterministic build.

The check reads the sanitizer build's compilation database and requires every C translation unit to
carry the sanitizers (address and undefined by default; `-fno-sanitize=` taking one back counts as
off). It then runs the test command with the runtimes set to stop at the first error
(ASAN_OPTIONS halt_on_error=1:abort_on_error=1:detect_leaks=1, UBSAN_OPTIONS
halt_on_error=1:print_stacktrace=1). A test command that fails, or output that holds a sanitizer
report, is RED. Use a test command that fails when it runs no tests (e.g. `ctest --no-tests=error`).

Usage: check-sanitized.py --compile-commands FILE [--sanitizers address,undefined] [--cwd DIR] -- CMD...
Exit:  0 GREEN, 1 RED, 2 UNRELIABLE (no or empty database, no test command, a command not found).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from compile_db import Unreliable, load  # noqa: E402

REPORT = re.compile(r'^(?:==\d+==ERROR: (?:Address|Leak|Memory|Thread)Sanitizer|.*: runtime error: )', re.M)


def sanitizers_of(args):
    on = set()
    for a in args:
        if a.startswith('-fsanitize='):
            on |= set(a.split('=', 1)[1].split(','))
        elif a.startswith('-fno-sanitize='):
            on -= set(a.split('=', 1)[1].split(','))
    return on


def main(argv):
    if '--' not in argv:
        print('usage: check-sanitized.py --compile-commands FILE [--sanitizers LIST] [--cwd DIR] -- CMD...', file=sys.stderr)
        return 2
    i = argv.index('--')
    ap = argparse.ArgumentParser()
    ap.add_argument('--compile-commands', required=True)
    ap.add_argument('--sanitizers', default='address,undefined')
    ap.add_argument('--cwd', default='.')
    a = ap.parse_args(argv[:i])
    cmd = argv[i + 1:]
    want = set(s for s in a.sanitizers.split(',') if s)
    try:
        if not cmd:
            raise Unreliable('no test command after --')
        if shutil.which(cmd[0], path=os.environ.get('PATH')) is None and not os.path.isfile(os.path.join(a.cwd, cmd[0])):
            raise Unreliable(f'the test command {cmd[0]} is not found')
        tus = load(a.compile_commands)
    except Unreliable as e:
        print(f'check-sanitized: {e} (UNRELIABLE)', file=sys.stderr)
        return 2
    problems = []
    for f, _, args, _ in tus:
        missing = want - sanitizers_of(args)
        if missing:
            problems.append(f'{f}: not built with -fsanitize={",".join(sorted(missing))}')
    if problems:
        for p in problems:
            print(f'[FAIL] {p}')
        print(f'check-sanitized: {len(problems)} translation unit(s) without the sanitizers; tests not run. RESULT: RED')
        return 1
    env = dict(os.environ)
    env['ASAN_OPTIONS'] = ':'.join(x for x in (env.get('ASAN_OPTIONS', ''), 'halt_on_error=1:abort_on_error=1:detect_leaks=1') if x)
    env['UBSAN_OPTIONS'] = ':'.join(x for x in (env.get('UBSAN_OPTIONS', ''), 'halt_on_error=1:print_stacktrace=1') if x)
    try:
        p = subprocess.run(cmd, cwd=a.cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace')
    except OSError as e:
        print(f'check-sanitized: cannot run the test command: {e} (UNRELIABLE)', file=sys.stderr)
        return 2
    reports = [m.group(0).strip() for m in REPORT.finditer(p.stdout)]
    if p.returncode != 0 or reports:
        print(p.stdout[-4000:])
        why = reports[0] if reports else f'the test command exited {p.returncode}'
        print(f'[FAIL] {why}')
        print(f'check-sanitized: {len(tus)} translation unit(s) sanitized; the tests did not pass cleanly. RESULT: RED')
        return 1
    print(f'check-sanitized: {len(tus)} translation unit(s) built with -fsanitize={",".join(sorted(want))}; '
          f'the tests passed with no sanitizer report. RESULT: GREEN')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
