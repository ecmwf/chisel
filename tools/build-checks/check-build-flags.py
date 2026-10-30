#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""check-build-flags.py - the C build contract, checked on what the compiler really did with each unit.

The flags that decide a port's numbers are the ones each translation unit (TU) was compiled with,
not the ones a CMakeLists, a cache variable or a configure summary claims (references/langs/c.md).
This reads each TU's command from the build's own compilation database (compile_commands.json,
from CMAKE_EXPORT_COMPILE_COMMANDS or `bear`), with its response files expanded, and asks the
compiler driver what the command means (`<cc> ... -###`: long options mapped to short ones, and in
clang an option such as `-ffp-model=fast` expanded into the flags it sets). Then, per C TU:

- the C standard the compiler runs is pinned and the same in every TU (`-std=c11` or `-std=c17` by
  default; a later `-ansi` or `--std=gnu17` counts, and so does no `-std=` at all);
- the warning floor is on and fatal (`-Wall -Wextra -Wconversion -Wshadow -Wdouble-promotion
  -Werror` by default), and nothing takes a warning back: `-w` and `-Wno-error` are forbidden, and
  a `-Wno-<warning>` is allowed only where the contract lists it with its reason;
- floating-point contraction is off (the compiler's last `-ffp-contract=` is `off`), no
  value-changing math mode is on, under any spelling (`-ffast-math`, `-Ofast`, `-ffp-model=fast`,
  their parts, or what clang expands them into), no flush-to-zero for the whole process
  (`-mdaz-ftz`), and the build does not depend on the machine it
  runs on (`-march=native`, `-mtune=native`, `-mcpu=native`, read from the command as written,
  since gcc's driver replaces them with the detected CPU);
- no product header is treated as a system header: `-isystem`, `-idirafter` or `-isystem-after`
  naming a directory inside the product root, or any `--system-header-prefix=`, silences every
  warning in those headers.

With --objects it also disassembles each TU's object file and refuses fused multiply-add
instructions: a compiler may contract `a*b + c` into one rounding without being asked (gcc and clang
both do at -O2 for a target with FMA), and only the object shows whether it did. An LTO object holds
no final code, so it is UNRELIABLE here.

A port records its own contract in a file passed with --contract (YAML): `std: [c17]` replaces the
standards; `required: [...]` and `forbidden: [...]` (a trailing `*` matches a prefix) ADD to the
defaults, which a contract never removes; `allowed: {-Wno-<warning>: <why this warning is wrong for
this code>}` permits a warning to be taken back, and an allowed `-Wno-X` stands in for a required
`-WX`. The defaults are the floor of references/langs/c.md.

Usage: check-build-flags.py --compile-commands FILE [--contract FILE] [--objects] [--product-root DIR]
       (the product root defaults to the deepest directory holding every C unit of the database)
Exit:  0 GREEN, 1 RED (a TU breaks the contract), 2 UNRELIABLE (no or empty database, a malformed
       entry, a command the compiler refuses or a compiler that is not gcc or clang, an object that
       cannot be read or is LTO, an unknown architecture, objdump or PyYAML missing).
"""
import argparse
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from compile_db import Unreliable, load as load_database, normalized  # noqa: E402

DEFAULT = {
    'std': ['c11', 'c17'],
    'required': ['-Wall', '-Wextra', '-Wconversion', '-Wshadow', '-Wdouble-promotion', '-Werror'],
    'forbidden': ['-w', '-Wno-error', '-Wno-error=*', '-ffast-math', '-Ofast', '-funsafe-math-optimizations',
                  '-fassociative-math', '-freciprocal-math', '-ffinite-math-only', '-fno-signed-zeros',
                  '-fapprox-func', '-fno-honor-nans', '-fno-honor-infinities', '-ffp-model=fast',
                  '-ffp-model=aggressive', '-mdaz-ftz', '-march=native', '-mtune=native', '-mcpu=native'],
    'allowed': {},
}
# The flags clang's driver hands its compiler for a value-changing math mode, whatever spelled it.
CLANG_MATH = {'-mreassociate': 'reassociation', '-menable-no-nans': 'no NaNs', '-menable-no-infs': 'no infinities'}
# Fused multiply-add mnemonics. x86: FMA3, FMA4, AVX-512 and its FP16/complex forms. AArch64: scalar,
# Advanced SIMD, SVE/SME (fmad, fmsb, fnmla, ...), the widening and bfloat16 forms, complex fcmla.
FMA = {
    'x86': re.compile(r'vf(?:n?m(?:add|sub)|maddsub|msubadd|c?maddc)\w*'),
    'aarch64': re.compile(r'(?:fn?m(?:add|sub|ad|sb|la|ls)|fml[as]l\w*|bfml\w*|fcmla)'),
}
_PREFIX = {'lock', 'rep', 'repz', 'repnz', 'repe', 'repne', 'notrack', 'bnd', 'data16', 'addr32'}


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
            contract[k] = dict(v)
        elif not isinstance(v, list) or not v or not all(isinstance(x, str) and x for x in v):
            raise Unreliable(f'the contract {path}: {k} must be a non-empty list of strings')
        elif k == 'std':
            contract[k] = list(v)
        else:
            contract[k] += [x for x in v if x not in contract[k]]
    return contract


def matches(flag, pattern):
    return flag.startswith(pattern[:-1]) if pattern.endswith('*') else flag == pattern


def effective_std(cc1):
    """The standard the compiler runs: its last -std= (or -ansi, C90), None when it runs its default."""
    std = None
    for a in cc1:
        if a.startswith('-std='):
            std = a.split('=', 1)[1]
        elif a == '-ansi':
            std = 'c90'
    return std


def check_unit(f, written, cc1, contract):
    """The contract problems of one TU, given its command as written and as the compiler runs it."""
    out = []
    seen = written + cc1

    def add(problem):
        if problem not in out:
            out.append(problem)

    std = effective_std(cc1)
    if std is None:
        add('no -std= reaches the compiler: the C standard is not pinned (the compiler runs its default)')
    elif std not in contract['std']:
        add(f'the compiler runs -std={std}, not the pinned standard ({" or ".join(contract["std"])})')
    for req in contract['required']:
        waived = req.startswith('-W') and not req.startswith('-Wno-') and '-Wno-' + req[2:] in contract['allowed']
        if req not in seen and not waived:
            add(f'{req} is missing')
    for a in seen:
        if any(matches(a, p) for p in contract['forbidden']):
            add(f'{a} is forbidden')
        elif a.startswith('-Wno-') and a not in contract['allowed']:
            add(f'{a} takes a warning back (allowed only when the contract lists it with its reason)')
    for a in cc1:
        if a in CLANG_MATH:
            add(f'the compiler runs with {a}: a value-changing math mode ({CLANG_MATH[a]})')
    contract_ff = [a.split('=', 1)[1] for a in cc1 if a.startswith('-ffp-contract=')]
    if not contract_ff:
        add('-ffp-contract=off is missing')
    elif contract_ff[-1] != 'off':
        add(f'the compiler runs -ffp-contract={contract_ff[-1]}: contraction must be off')
    return [(f, p) for p in out], std


SYSTEM_DIR_FLAGS = ('-isystem', '-idirafter', '-isystem-after')


def system_headers(directory, written, root):
    """The flags that make headers under the product root system headers, whose warnings no
    compiler reports."""
    out = []
    i = 0
    while i < len(written):
        a = written[i]
        if a.startswith('--system-header-prefix'):
            out.append(f'{a} treats headers as system headers: their warnings are silenced')
        flag = next((k for k in SYSTEM_DIR_FLAGS if a == k or (a.startswith(k) and not a.startswith(k + '-'))), None)
        if flag:
            val = written[i + 1] if a == flag and i + 1 < len(written) else a[len(flag):]
            if a == flag:
                i += 1
            path = os.path.realpath(val if os.path.isabs(val) else os.path.join(directory, val))
            if path == root or path.startswith(root + os.sep):
                out.append(f'{flag} {val} makes product headers system headers: their warnings are silenced')
        i += 1
    return out


def product_root(tus, given):
    if given:
        return os.path.realpath(given)
    return os.path.commonpath([os.path.dirname(os.path.realpath(f)) for f, _, _, _ in tus])


def check_flags(tus, contract, root=None):
    """[(file, problem)] for every TU that breaks the contract."""
    out, stds = [], {}
    root = root or product_root(tus, None)
    for f, directory, args, _ in tus:
        problems, std = check_unit(f, list(args[1:]), normalized(directory, args), contract)
        problems += [(f, p) for p in system_headers(directory, list(args[1:]), root)]
        out += problems
        if std is not None:
            stds.setdefault(std, []).append(f)
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


def mnemonic(line):
    """The instruction mnemonic of an `objdump -d --no-show-raw-insn` line, or None."""
    m = re.match(r'^\s*[0-9a-f]+:\t(.*)$', line)
    if not m:
        return None
    for tok in m.group(1).split():
        if tok.startswith('{') or tok in _PREFIX:
            continue
        return tok
    return None


def fma_hits(arch, disassembly):
    """[(function, instruction)] of every fused multiply-add in an objdump disassembly."""
    func, hits = '?', []
    for ln in disassembly.splitlines():
        m = re.match(r'^[0-9a-f]+ <(.+)>:$', ln)
        if m:
            func = m.group(1)
            continue
        op = mnemonic(ln)
        if op and FMA[arch].fullmatch(op):
            hits.append((func, ln.split('\t', 1)[-1].strip()))
    return hits


def check_objects(tus):
    """[(file, problem)] for every object that holds a fused multiply-add."""
    if shutil.which('objdump') is None:
        raise Unreliable('objdump is needed to read the objects (binutils)')
    out = []
    for f, directory, args, output in tus:
        obj = object_of(directory, args, output)
        if not os.path.isfile(obj):
            raise Unreliable(f'the object {obj} of {f} does not exist: build before checking')
        head = subprocess.run(['objdump', '-f', '-h', obj], capture_output=True, text=True)
        if head.returncode != 0:
            raise Unreliable(f'objdump cannot read {obj} (an LLVM bitcode object from -flto?): {head.stderr.strip()}')
        if '.gnu.lto_' in head.stdout:
            raise Unreliable(f'{obj} is an LTO object: its code is generated at link time, not in the object')
        arch = 'x86' if re.search(r'architecture: i386:x86-64|architecture: i386\b', head.stdout) else \
            'aarch64' if 'aarch64' in head.stdout else None
        if arch is None:
            raise Unreliable(f'{obj}: an architecture this check does not know')
        dis = subprocess.run(['objdump', '-d', '--no-show-raw-insn', obj], capture_output=True, text=True)
        if dis.returncode != 0:
            raise Unreliable(f'objdump cannot disassemble {obj}: {dis.stderr.strip()}')
        hits = fma_hits(arch, dis.stdout)
        if hits:
            where = ', '.join(sorted({h[0] for h in hits}))
            out.append((f, f'{len(hits)} fused multiply-add instruction(s) in {where} (first: {hits[0][1]})'))
    return out


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--compile-commands', required=True)
    ap.add_argument('--contract')
    ap.add_argument('--objects', action='store_true')
    ap.add_argument('--product-root')
    a = ap.parse_args(argv)
    try:
        contract = load_contract(a.contract)
        tus = load_database(a.compile_commands)
        if a.product_root and not os.path.isdir(a.product_root):
            raise Unreliable(f'--product-root {a.product_root} is not a directory')
        problems = check_flags(tus, contract, product_root(tus, a.product_root))
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
