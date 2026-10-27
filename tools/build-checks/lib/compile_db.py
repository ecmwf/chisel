# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""compile_db - read a build's compilation database (compile_commands.json) for the build checks.

A compilation database records, for every translation unit, the exact command the build ran:
CMake writes one with CMAKE_EXPORT_COMPILE_COMMANDS=ON, and `bear -- <build command>` records one for
any other build system. The build checks read flags from it, never from build files or caches, and
ask the compiler itself what a command means (`normalized`) rather than reading flag spellings.
"""
import json
import os
import shlex
import subprocess


class Unreliable(Exception):
    """The check cannot decide: reported as UNRELIABLE (exit 2), never as a pass."""


def _is_c(f, args):
    """A C translation unit: a .c file, or any file the command compiles with `-x c`."""
    if f.endswith('.c'):
        return True
    for i, a in enumerate(args):
        if (a == '-x' and i + 1 < len(args) and args[i + 1] == 'c') or a == '-xc':
            return True
    return False


def expand(args, directory, depth=0):
    """`args` with every response file (`@file`, relative to the directory) replaced by its content."""
    out = []
    for a in args:
        if a.startswith('@') and len(a) > 1:
            path = a[1:] if os.path.isabs(a[1:]) else os.path.join(directory, a[1:])
            if depth > 8:
                raise Unreliable(f'response files nested too deep at {a}')
            try:
                text = open(path, encoding='utf-8').read()
                inner = shlex.split(text)
            except (OSError, ValueError) as e:
                raise Unreliable(f'cannot read the response file {path}: {e}')
            out += expand(inner, directory, depth + 1)
        else:
            out.append(a)
    return out


def load(path):
    """[(file, directory, arguments, output)] for every C translation unit of the database, with the
    response files of each command expanded. A malformed entry is Unreliable, never skipped."""
    try:
        db = json.load(open(path, encoding='utf-8'))
    except (OSError, ValueError) as e:
        raise Unreliable(f'cannot read the compilation database {path}: {e}')
    if not isinstance(db, list):
        raise Unreliable(f'{path} is not a compilation database (a JSON list)')
    tus = []
    for e in db:
        if not isinstance(e, dict) or not isinstance(e.get('file'), str) or not isinstance(e.get('directory'), str):
            raise Unreliable(f'{path}: an entry without a "file" and a "directory" string: {str(e)[:120]}')
        if not os.path.isabs(e['directory']):
            raise Unreliable(f'{path}: the entry for {e["file"]} has a relative "directory"')
        args = e.get('arguments')
        if args is None:
            if not isinstance(e.get('command'), str):
                raise Unreliable(f'{path}: the entry for {e["file"]} has neither "arguments" nor "command"')
            try:
                args = shlex.split(e['command'])
            except ValueError as err:
                raise Unreliable(f'{path}: the command of {e["file"]} cannot be split: {err}')
        if not isinstance(args, list) or not args or not all(isinstance(a, str) for a in args):
            raise Unreliable(f'{path}: the entry for {e["file"]} has no command, or "arguments" is not a list of strings')
        out = e.get('output')
        if out is not None and not isinstance(out, str):
            raise Unreliable(f'{path}: the "output" of {e["file"]} is not a string')
        f = os.path.normpath(e['file'] if os.path.isabs(e['file']) else os.path.join(e['directory'], e['file']))
        args = expand(args, e['directory'])
        if _is_c(f, args):
            tus.append((f, e['directory'], args, out))
    if not tus:
        raise Unreliable(f'{path} lists no C translation unit')
    return tus


def normalized(directory, args):
    """The compiler's own command for the unit, as its driver hands it on (`<cc> ... -###`): response
    files expanded, long options mapped to short ones, and in clang an option such as
    `-ffp-model=fast` expanded into the flags it sets. Unreliable when the driver refuses the command
    or prints no compiler job."""
    try:
        p = subprocess.run(list(args) + ['-###'], cwd=directory, capture_output=True, text=True)
    except OSError as e:
        raise Unreliable(f'cannot run the compiler {args[0]}: {e}')
    if p.returncode != 0:
        first = next((ln for ln in p.stderr.splitlines() if 'error' in ln.lower()), p.stderr.strip()[:200])
        raise Unreliable(f'the compiler refuses the command ({args[0]} -###): {first.strip()}')
    for ln in p.stderr.splitlines():
        try:
            toks = shlex.split(ln)
        except ValueError:
            continue
        if toks and (os.path.basename(toks[0]) == 'cc1' or (len(toks) > 1 and toks[1] == '-cc1')):
            return toks[1:]
    raise Unreliable(f'{args[0]} -### shows no compiler job: only gcc and clang drivers are read')


# The flags that shape how a file parses: macros, include paths, forced includes, the standard, and
# the flags that change predefined macros or the language (the target and its -m options, -O, the
# OpenMP, fast-math, char-signedness, threading, freestanding and -ansi modes). Everything else
# (warnings, code generation) is left out, so a gcc-only warning or code-generation flag cannot stop
# libclang. A kept flag clang does not know (a gcc-only -m option such as
# -mpreferred-stack-boundary=) makes the parse fail with clang naming it: UNRELIABLE, since the
# macros it sets cannot be known.
_KEEP_JOINED = ('-D', '-U', '-I', '-std=', '--std=', '-iquote', '-isystem', '-idirafter', '-include', '-imacros',
                '--sysroot=', '-isysroot', '--target=')
_KEEP_SEPARATE = ('-D', '-U', '-I', '-iquote', '-isystem', '-idirafter', '-include', '-imacros', '--sysroot',
                  '-isysroot', '-x', '-target', '--target')
_KEEP_EXACT = ('-ansi', '-pthread', '-ffast-math', '-fno-fast-math', '-funsigned-char', '-fsigned-char',
               '-fno-unsigned-char', '-fno-signed-char', '-fno-openmp', '-ffreestanding')
_KEEP_PREFIX = ('-m', '-O', '-fopenmp')
_DROP_SEPARATE = ('-mllvm',)  # a clang code-generation option and its value
_PATH_FLAGS = ('-I', '-iquote', '-isystem', '-idirafter', '-include', '-imacros')


def parse_args(directory, args, source):
    """The arguments that shape parsing (macros, include paths, forced includes, the standard, the
    flags that change predefined macros), for libclang, with relative paths made absolute."""
    out = []
    i = 1
    while i < len(args):
        a = args[i]
        if a in _DROP_SEPARATE:
            i += 2
            continue
        if a in _KEEP_EXACT or a == '-O' or (a.startswith(_KEEP_PREFIX) and len(a) > 2):
            out.append(a)
            i += 1
            continue
        if a in _KEEP_SEPARATE and i + 1 < len(args):
            val = args[i + 1]
            if a in _PATH_FLAGS and not os.path.isabs(val):
                val = os.path.normpath(os.path.join(directory, val))
            out += [a, val]
            i += 2
            continue
        joined = next((k for k in _KEEP_JOINED if a.startswith(k) and len(a) > len(k)), None)
        if joined:
            val = a[len(joined):]
            if joined in _PATH_FLAGS and not os.path.isabs(val):
                val = os.path.normpath(os.path.join(directory, val))
            out.append(joined + val if joined != '--std=' else '-std=' + val)
        i += 1
    return out


_RES = []


def resource_dir_arg():
    """libclang does not add clang's resource directory (stddef.h, stdbool.h) as the driver does."""
    if not _RES:
        p = subprocess.run(['clang', '-print-resource-dir'], capture_output=True, text=True)
        if p.returncode != 0 or not p.stdout.strip():
            raise Unreliable('clang -print-resource-dir failed: the clang driver is needed')
        _RES.append('-resource-dir=' + p.stdout.strip())
    return _RES[0]
