#!/usr/bin/env python3
"""check-tidy.py - the port's clang-tidy allowlist, run over every C unit of the build.

clang-tidy turns trap-table entries into standing checks (references/langs/c.md, "Format and lint"):
`bugprone-*` and `clang-analyzer-*` find real defects, and `readability-identifier-naming` enforces
the naming map. The config is an ALLOWLIST the port commits (template:
.opencode/skill/target-conventions/assets/clang-tidy.template.yaml): a check that proposes
rewriting the code (`modernize-*`, the readability checks other than identifier naming) is failure
mode B1 automated, so a config enabling one is RED.

The check reads the build's compilation database, gives clang-tidy each C unit with only the flags
that shape parsing (macros, include paths, the standard - so a gcc-only flag cannot stop clang), and
reports every finding, in the unit or in a product header it includes.

Usage: check-tidy.py --compile-commands FILE --config FILE
Exit:  0 GREEN, 1 RED (a finding, or the config enables a rewriting check), 2 UNRELIABLE (no or
       empty database, a malformed entry, clang-tidy missing, a config that enables no check or that
       clang-tidy cannot read, a unit clang-tidy cannot compile).
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from compile_db import Unreliable, load, parse_args  # noqa: E402

REWRITING = re.compile(r'modernize-.*|readability-(?!identifier-naming$).*')
FINDING = re.compile(r'^(?P<where>.+?:\d+:\d+): (?P<sev>warning|error): (?P<msg>.*) \[(?P<checks>[^\]]+)\]$')


def enabled_checks(config):
    p = subprocess.run(['clang-tidy', '--list-checks', f'--config-file={config}'], capture_output=True, text=True)
    if 'No checks enabled' in p.stdout + p.stderr:
        raise Unreliable(f'the config {config} enables no check')
    if p.returncode != 0:
        raise Unreliable(f'clang-tidy cannot read the config {config}: {(p.stderr or p.stdout).strip()[:200]}')
    checks = [ln.strip() for ln in p.stdout.splitlines()[1:] if ln.strip()]
    if not checks:
        raise Unreliable(f'the config {config} enables no check')
    return checks


def tidy(unit, build_dir, config):
    """(findings [(where, message, check)], or raises Unreliable) for one unit."""
    p = subprocess.run(['clang-tidy', '-p', build_dir, f'--config-file={config}', '--quiet', unit],
                       capture_output=True, text=True, errors='replace')
    out, broken = [], []
    for ln in (p.stdout + '\n' + p.stderr).splitlines():
        m = FINDING.match(ln)
        if not m:
            continue
        checks = [c for c in m.group('checks').split(',') if c and not c.startswith('-')]
        if any(c.startswith('clang-diagnostic-') for c in checks) and m.group('sev') == 'error':
            broken.append(ln)
        else:
            out.append((m.group('where'), m.group('msg'), ','.join(checks)))
    if broken:
        raise Unreliable(f'clang-tidy cannot compile {unit}: {broken[0]}')
    if p.returncode != 0 and not out:
        raise Unreliable(f'clang-tidy failed on {unit}: {(p.stderr or p.stdout).strip()[:200]}')
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--compile-commands', required=True)
    ap.add_argument('--config', required=True)
    a = ap.parse_args(argv)
    try:
        if shutil.which('clang-tidy') is None:
            raise Unreliable('clang-tidy is not installed')
        if not os.path.isfile(a.config):
            raise Unreliable(f'the config {a.config} does not exist')
        config = os.path.abspath(a.config)
        checks = enabled_checks(config)
        tus = load(a.compile_commands)
        rewriting = [c for c in checks if REWRITING.fullmatch(c)]
        with tempfile.TemporaryDirectory(prefix='check-tidy-') as build_dir:
            entries = [{'directory': d, 'file': f, 'arguments': ['clang', '-x', 'c'] + parse_args(d, args, f) + ['-c', f]}
                       for f, d, args, _ in tus]
            with open(os.path.join(build_dir, 'compile_commands.json'), 'w') as fh:
                json.dump(entries, fh)
            jobs = len(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else (os.cpu_count() or 1)
            with ThreadPoolExecutor(max_workers=jobs) as pool:
                results = list(pool.map(lambda t: tidy(t[0], build_dir, config), tus))
    except Unreliable as e:
        print(f'check-tidy: {e} (UNRELIABLE)', file=sys.stderr)
        return 2
    findings = sorted({f for r in results for f in r})
    for c in rewriting:
        print(f'[FAIL] the config enables {c}, a check that rewrites the code (an allowlist excludes it)')
    for where, msg, check in findings:
        print(f'[FAIL] {where}: {msg} [{check}]')
    red = bool(findings or rewriting)
    print(f'check-tidy: {len(tus)} C translation unit(s), {len(checks)} check(s) enabled; {len(findings)} finding(s), '
          f'{len(rewriting)} rewriting check(s) enabled. RESULT: {"RED" if red else "GREEN"}')
    return 1 if red else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
