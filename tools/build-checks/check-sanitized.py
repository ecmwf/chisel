#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""check-sanitized.py - run the product's tests on a sanitizer build, and stop at the first error.

AddressSanitizer catches an out-of-bounds read or write at first touch (a wrong stride or extent,
failure mode N4; a wrong index base, T10/T30) and UndefinedBehaviorSanitizer catches what C leaves
undefined where Fortran did not (signed-integer overflow, T13; a float-to-integer conversion out of
range; a bad shift) - references/langs/c.md, "Runtime sanitizers". MemorySanitizer (clang only, and
in a build of its own: it does not combine with AddressSanitizer) catches a read of an uninitialized
value, which a SOURCE build that zero-initializes hid (T8); check that build with
`--sanitizers memory`. ThreadSanitizer, a build of its own too, catches a data race once the
execution model adds threads: `--sanitizers thread`. A sanitizer build is a diagnostic build: acceptance comparisons still run on
the deterministic build.

The check reads the sanitizer build's compilation database and requires every C translation unit to
carry the sanitizers - by default address, undefined and float-cast-overflow: GCC leaves the
float-to-integer check out of `undefined` (clang puts it in), so it is named on its own, and a
Fortran INT or NINT of a value out of range is undefined in C (T17) - and to take none of them back: any
`-fno-sanitize=` is RED, since `-fno-sanitize=signed-integer-overflow` silently removes part of
`undefined` and `-fno-sanitize=all` all of it, and so is an ignore-list
(`-fsanitize-ignorelist=`, `-fsanitize-blacklist=`) or a runtime suppressions file in the
environment (`suppressions=` in ASAN_OPTIONS, UBSAN_OPTIONS, LSAN_OPTIONS, ...). It then runs the test command with the runtimes set
to stop at the first error and to report on standard error whatever the caller's environment says
(ASAN_OPTIONS ...:halt_on_error=1:abort_on_error=1:detect_leaks=1:log_path=stderr, UBSAN_OPTIONS
...:halt_on_error=1:print_stacktrace=1:log_path=stderr, MSAN_OPTIONS ...:halt_on_error=1:log_path=stderr).
A test command that fails, or output that holds a sanitizer report anywhere on a line (an ERROR or
WARNING from Address-, Leak-, Memory- or ThreadSanitizer, or a UBSan `runtime error`), is RED. Use a test command that fails when it runs no
tests (e.g. `ctest --no-tests=error`), and that runs the binaries this database built.

Usage: check-sanitized.py --compile-commands FILE [--sanitizers address,undefined,float-cast-overflow] [--cwd DIR] -- CMD...
Exit:  0 GREEN, 1 RED, 2 UNRELIABLE (no or empty database, a malformed entry, no sanitizer named, no test
       command, a command not found).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from compile_db import Unreliable, load  # noqa: E402

# AddressSanitizer and LeakSanitizer report an ERROR, MemorySanitizer and ThreadSanitizer a WARNING;
# UndefinedBehaviorSanitizer a `runtime error`.
REPORT = re.compile(r'==\d+==(?:ERROR|WARNING): (?:Address|Leak|Memory|Thread)Sanitizer.*|\S*: runtime error: .*')


IGNORELISTS = ('-fsanitize-ignorelist=', '-fsanitize-blacklist=')
SUPPRESSION_ENV = ('ASAN_OPTIONS', 'UBSAN_OPTIONS', 'LSAN_OPTIONS', 'MSAN_OPTIONS', 'TSAN_OPTIONS')


def sanitizers_of(args):
    """(the sanitizers turned on, the flags that take some back: any -fno-sanitize=, and an
    ignore-list exempting code from them)."""
    on, back = set(), []
    for a in args:
        if a.startswith('-fsanitize='):
            on |= set(a.split('=', 1)[1].split(','))
        elif a.startswith('-fno-sanitize=') or a.startswith(IGNORELISTS):
            back.append(a)
    return on, back


def suppressed_by_environment(env):
    """The runtime options in the environment that point the sanitizers at a suppressions file."""
    return [f'{k} sets {opt}' for k in SUPPRESSION_ENV for opt in env.get(k, '').split(':')
            if opt.split('=', 1)[0].strip() == 'suppressions' and opt.split('=', 1)[-1].strip()]


def main(argv):
    if '--' not in argv:
        print('usage: check-sanitized.py --compile-commands FILE [--sanitizers LIST] [--cwd DIR] -- CMD...', file=sys.stderr)
        return 2
    i = argv.index('--')
    ap = argparse.ArgumentParser()
    ap.add_argument('--compile-commands', required=True)
    ap.add_argument('--sanitizers', default='address,undefined,float-cast-overflow')
    ap.add_argument('--cwd', default='.')
    a = ap.parse_args(argv[:i])
    cmd = argv[i + 1:]
    want = set(s for s in a.sanitizers.split(',') if s)
    try:
        if not want:
            raise Unreliable('--sanitizers names no sanitizer')
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
        on, back = sanitizers_of(args)
        missing = want - on
        if missing:
            problems.append(f'{f}: not built with -fsanitize={",".join(sorted(missing))}')
        for b in back:
            problems.append(f'{f}: {b} takes a sanitizer back' if b.startswith('-fno-sanitize=')
                            else f'{f}: {b} exempts code from the sanitizers')
    problems += [f'the environment {s}: a suppressions file hides sanitizer reports'
                 for s in suppressed_by_environment(os.environ)]
    if problems:
        for p in problems:
            print(f'[FAIL] {p}')
        print(f'check-sanitized: {len(problems)} problem(s) in the sanitizer flags of {len(tus)} translation unit(s); tests not run. RESULT: RED')
        return 1
    env = dict(os.environ)
    env['ASAN_OPTIONS'] = ':'.join(x for x in (env.get('ASAN_OPTIONS', ''),
                                               'halt_on_error=1:abort_on_error=1:detect_leaks=1:log_path=stderr') if x)
    env['UBSAN_OPTIONS'] = ':'.join(x for x in (env.get('UBSAN_OPTIONS', ''),
                                                'halt_on_error=1:print_stacktrace=1:log_path=stderr') if x)
    env['MSAN_OPTIONS'] = ':'.join(x for x in (env.get('MSAN_OPTIONS', ''), 'halt_on_error=1:log_path=stderr') if x)
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
