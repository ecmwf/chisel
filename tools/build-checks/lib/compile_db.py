"""compile_db - read a build's compilation database (compile_commands.json) for the build checks.

A compilation database records, for every translation unit, the exact command the build ran:
CMake writes one with CMAKE_EXPORT_COMPILE_COMMANDS=ON, and `bear -- <build command>` records one for
any other build system. The build checks read flags from it, never from build files or caches.
"""
import json
import os
import shlex
import subprocess


class Unreliable(Exception):
    """The check cannot decide: reported as UNRELIABLE (exit 2), never as a pass."""


def load(path, suffixes=('.c',)):
    """[(file, directory, arguments, output)] for every entry whose file has one of the suffixes."""
    try:
        db = json.load(open(path, encoding='utf-8'))
    except (OSError, ValueError) as e:
        raise Unreliable(f'cannot read the compilation database {path}: {e}')
    if not isinstance(db, list):
        raise Unreliable(f'{path} is not a compilation database (a JSON list)')
    tus = []
    for e in db:
        if not isinstance(e, dict) or 'file' not in e or 'directory' not in e:
            raise Unreliable(f'{path}: an entry without "file" and "directory"')
        args = e.get('arguments') or shlex.split(e.get('command', ''))
        if not args:
            raise Unreliable(f'{path}: the entry for {e["file"]} has no command')
        f = e['file'] if os.path.isabs(e['file']) else os.path.join(e['directory'], e['file'])
        if f.endswith(suffixes):
            tus.append((os.path.normpath(f), e['directory'], args, e.get('output')))
    if not tus:
        raise Unreliable(f'{path} lists no {"/".join(suffixes)} translation unit')
    return tus


def parse_args(directory, args, source):
    """The compiler arguments that shape parsing (macros, include paths, standard), for libclang:
    the compiler, -c, -o <file> and the source file itself removed, relative -I made absolute."""
    out, skip = [], False
    for i, a in enumerate(args[1:], 1):
        if skip:
            skip = False
            continue
        if a in ('-c', '-MD', '-MMD', '-MP'):
            continue
        if a in ('-o', '-MF', '-MT', '-MQ'):
            skip = True
            continue
        if a.startswith('-o') and len(a) > 2:
            continue
        p = a if os.path.isabs(a) else os.path.join(directory, a)
        if os.path.normpath(p) == os.path.normpath(source):
            continue
        if a.startswith('-I') and len(a) > 2 and not os.path.isabs(a[2:]):
            a = '-I' + os.path.normpath(os.path.join(directory, a[2:]))
        out.append(a)
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
