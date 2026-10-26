#!/usr/bin/env python3
"""check-build-flags.py - the C build contract, checked on the flags the compiler really received.

The flags that decide a port's numbers are the ones each translation unit (TU) was compiled with,
not the ones a CMakeLists, a cache variable or a configure summary claims (references/langs/c.md).
This reads them from the build's own compilation database (compile_commands.json, from
CMAKE_EXPORT_COMPILE_COMMANDS or `bear`) and checks every C TU:

- the C standard is pinned and the same in every TU (`-std=c11` or `-std=c17` by default);
- the warning floor is on and fatal (`-Wall -Wextra -Wconversion -Wshadow -Wdouble-promotion
  -Werror` by default), and nothing takes a warning back: `-w` and `-Wno-error` are forbidden, and a
  `-Wno-<warning>` is allowed only where the contract lists it with its reason;
- floating-point contraction is off (the last `-ffp-contract=` is `off`), no value-changing math mode
  is on (`-ffast-math`, `-Ofast`, `-funsafe-math-optimizations`, `-fassociative-math`,
  `-freciprocal-math`, `-ffinite-math-only`, `-fno-signed-zeros`), and the build does not depend on
  the machine it runs on (`-march=native`, `-mtune=native`).

With --objects it also disassembles each TU's object file and refuses fused multiply-add
instructions: a compiler may contract `a*b + c` into one rounding without being asked (gcc and clang
both do at -O2 for a target with FMA), and only the object shows whether it did.

A port that pins other flags records them in a contract file and passes it with --contract (YAML:
`std: [c17]`, `required: [...]`, `forbidden: [...]` - a trailing `*` matches a prefix - and
`allowed: {-Wno-<warning>: <why this warning is wrong for this code>}`); a key the file omits keeps
its default, and the defaults are the floor of references/langs/c.md.

Usage: check-build-flags.py --compile-commands FILE [--contract FILE] [--objects]
Exit:  0 GREEN, 1 RED (a TU breaks the contract), 2 UNRELIABLE (no or empty database, a TU or object
       that cannot be read, an unknown architecture, objdump or PyYAML missing).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from compile_db import Unreliable, load as load_database  # noqa: E402

DEFAULT = {
    'std': ['c11', 'c17'],
    'required': ['-Wall', '-Wextra', '-Wconversion', '-Wshadow', '-Wdouble-promotion', '-Werror'],
    'forbidden': ['-w', '-Wno-error', '-Wno-error=*', '-ffast-math', '-Ofast', '-funsafe-math-optimizations',
                  '-fassociative-math', '-freciprocal-math', '-ffinite-math-only', '-fno-signed-zeros',
                  '-march=native', '-mtune=native'],
    'allowed': {},
}
# Fused multiply-add mnemonics: x86 FMA3/FMA4/AVX-512 (vfmadd*, vfmsub*, vfnmadd*, vfnmsub*,
# vfmaddsub*, vfmsubadd*) and AArch64 (fmadd, fmsub, fnmadd, fnmsub, fmla, fmls).
FMA = {
    'x86': re.compile(r'\bvf(?:n?m(?:add|sub)|maddsub|msubadd)\w*'),
    'aarch64': re.compile(r'\b(?:f(?:n)?m(?:add|sub)|fml[as])\b'),
}


def load_contract(path):
    contract = {k: (dict(v) if isinstance(v, dict) else list(v)) for k, v in DEFAULT.items()}
    if not path:
        return contract
    try:
        import yaml
    except ImportError:
        raise Unreliable('PyYAML is needed to read the contract file')
    try:
        data = yaml.safe_load(open(path, encoding='utf-8'))
    except (OSError, yaml.YAMLError) as e:
        raise Unreliable(f'cannot read the contract {path}: {e}')
    if not isinstance(data, dict) or not set(data) <= set(DEFAULT):
        raise Unreliable(f'the contract {path} must be a mapping of {", ".join(DEFAULT)}')
    for k, v in data.items():
        if k == 'allowed':
            if not isinstance(v, dict) or not all(isinstance(f, str) and f.startswith('-Wno-') and
                                                   isinstance(r, str) and r.strip() for f, r in v.items()):
                raise Unreliable(f'the contract {path}: allowed must map each -Wno-<warning> to its reason')
        elif not isinstance(v, list) or not all(isinstance(x, str) and x for x in v):
            raise Unreliable(f'the contract {path}: {k} must be a list of strings')
        contract[k] = v
    return contract


def matches(flag, pattern):
    return flag.startswith(pattern[:-1]) if pattern.endswith('*') else flag == pattern


def check_flags(tus, contract):
    """[(file, problem)] for every TU that breaks the contract."""
    out = []
    stds = {}
    for f, _, args, _ in tus:
        flags = args[1:]
        std = [a.split('=', 1)[1] for a in flags if a.startswith('-std=')]
        if not std:
            out.append((f, 'no -std= flag: the C standard is not pinned'))
        else:
            stds.setdefault(std[-1], []).append(f)
            if std[-1] not in contract['std']:
                out.append((f, f'-std={std[-1]} is not the pinned standard ({" or ".join(contract["std"])})'))
        for req in contract['required']:
            if req not in flags:
                out.append((f, f'{req} is missing'))
        for a in flags:
            if any(matches(a, p) for p in contract['forbidden']):
                out.append((f, f'{a} is forbidden'))
            elif a.startswith('-Wno-') and a not in contract['allowed']:
                out.append((f, f'{a} takes a warning back (allowed only when the contract lists it with its reason)'))
        contract_ff = [a.split('=', 1)[1] for a in flags if a.startswith('-ffp-contract=')]
        if not contract_ff or contract_ff[-1] != 'off':
            out.append((f, '-ffp-contract=off is missing' if not contract_ff
                        else f'-ffp-contract={contract_ff[-1]}: contraction must be off'))
    if len(stds) > 1:
        out.append(('(all)', 'the TUs use different standards: ' + ', '.join(f'-std={s} ({len(v)})' for s, v in sorted(stds.items()))))
    return out


def object_of(directory, args, output):
    if output:
        return os.path.normpath(output if os.path.isabs(output) else os.path.join(directory, output))
    for i, a in enumerate(args):
        if a == '-o' and i + 1 < len(args):
            o = args[i + 1]
            return os.path.normpath(o if os.path.isabs(o) else os.path.join(directory, o))
        if a.startswith('-o') and len(a) > 2:
            return os.path.normpath(os.path.join(directory, a[2:]))
    raise Unreliable(f'the entry compiled in {directory} names no object file (-o)')


def check_objects(tus):
    """[(file, problem)] for every object that holds a fused multiply-add."""
    if shutil.which('objdump') is None:
        raise Unreliable('objdump is needed to read the objects (binutils)')
    out = []
    for f, directory, args, output in tus:
        obj = object_of(directory, args, output)
        if not os.path.isfile(obj):
            raise Unreliable(f'the object {obj} of {f} does not exist: build before checking')
        head = subprocess.run(['objdump', '-f', obj], capture_output=True, text=True)
        if head.returncode != 0:
            raise Unreliable(f'objdump cannot read {obj}: {head.stderr.strip()}')
        arch = 'x86' if re.search(r'architecture: i386:x86-64|architecture: i386\b', head.stdout) else \
            'aarch64' if 'aarch64' in head.stdout else None
        if arch is None:
            raise Unreliable(f'{obj}: an architecture this check does not know ({head.stdout.strip().splitlines()[-1]})')
        dis = subprocess.run(['objdump', '-d', '--no-show-raw-insn', obj], capture_output=True, text=True)
        if dis.returncode != 0:
            raise Unreliable(f'objdump cannot disassemble {obj}: {dis.stderr.strip()}')
        func, hits = '?', []
        for ln in dis.stdout.splitlines():
            m = re.match(r'^[0-9a-f]+ <(.+)>:$', ln)
            if m:
                func = m.group(1)
            elif FMA[arch].search(ln):
                hits.append((func, ln.split('\t')[-1].strip()))
        if hits:
            where = ', '.join(sorted({h[0] for h in hits}))
            out.append((f, f'{len(hits)} fused multiply-add instruction(s) in {where} (first: {hits[0][1]})'))
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--compile-commands', required=True)
    ap.add_argument('--contract')
    ap.add_argument('--objects', action='store_true')
    a = ap.parse_args(argv)
    try:
        contract = load_contract(a.contract)
        tus = load_database(a.compile_commands)
        problems = check_flags(tus, contract)
        if a.objects:
            problems += check_objects(tus)
    except Unreliable as e:
        print(f'check-build-flags: {e} (UNRELIABLE)', file=sys.stderr)
        return 2
    for f, p in problems:
        print(f'[FAIL] {f}: {p}')
    verdict = 'RED' if problems else 'GREEN'
    print(f'check-build-flags: {len(tus)} C translation unit(s){" and their objects" if a.objects else ""}; '
          f'{len(problems)} problem(s). RESULT: {verdict}')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
