#!/usr/bin/env python3
"""product_tu.py - libclang translation units for the product's C files.

The product checks that judge C code read it through this one module, so they all parse it the
same way, as a compiler would, never as text.

Compile arguments for a file:

  - from the product's compile_commands.json (at the product root) when it has an entry for the
    file, read by the build checks' reader (tools/build-checks/lib/compile_db.py): the entry is
    validated (an absolute directory, a list of string arguments), its response files (`@file`)
    are expanded, and only the flags that shape parsing are kept (`compile_db.parse_args`: macros,
    include paths with relative ones made absolute, forced includes, the standard, and the flags
    that change predefined macros - the target and its -m options, -O, -fopenmp, -ffast-math,
    -funsigned-char, -pthread, -ansi). Warnings and code generation are left out, so a gcc-only
    warning flag cannot stop the parse; a kept gcc-only flag clang does not know makes it
    UNRELIABLE, with clang naming the flag.
  - otherwise `-std=c17` with `-I` for every directory of the product tree (or, with no product
    root, the directory of every file given). With a compile_commands.json, only a header that no
    listed source includes is parsed this way: a source (*.c) the database does not list is
    UNRELIABLE, never parsed with guessed arguments, and so is a compile_commands.json that is a
    link to nothing.
  - always clang's resource directory (`clang -print-resource-dir`), so compiler headers such as
    <stddef.h> resolve, and `-Werror=implicit-function-declaration`, so a call to an undeclared
    function is an error with every clang version.

A source file (*.c) is parsed on its own. A header is read inside the first parsed source that
includes it, or is parsed on its own when no source does. A file that does not parse cleanly -
any error, including a missing header, an unknown compiler flag or a call to an undeclared
function - raises Unreliable with the first error; it is never skipped.

Usage (prints how each file was read):
  product_tu.py [--root DIR] -- FILE...

Exit codes:
  0  every FILE parses cleanly
  2  one does not, or libclang / the clang driver is unavailable
"""
import os
import sys
from dataclasses import dataclass

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'build-checks', 'lib'))
import compile_db  # noqa: E402

DB_NAME = 'compile_commands.json'
DEFAULT_ARGS = ['-x', 'c', '-std=c17']
EXTRA_ARGS = ['-Werror=implicit-function-declaration']

# The product's C cannot be read as the compiler reads it; a check reports UNRELIABLE.
Unreliable = compile_db.Unreliable


@dataclass
class Unit:
    path: str            # absolute path of the file parsed
    tu: object           # the clang.cindex TranslationUnit
    args: list           # the arguments the parse used
    directory: str       # the directory relative paths in the parse resolve against
    origin: str          # how the arguments were chosen, for reports
    command: list = None  # the compile_commands.json entry's arguments, as written, or None
    db: str = None       # the compile_commands.json the entry came from, or None

    def real(self, name):
        """The real path of a file name as the parse reports it."""
        return os.path.realpath(os.path.join(self.directory, name))


_CI = []


def cindex():
    """clang.cindex, with its native library loaded."""
    if not _CI:
        try:
            import clang.cindex as ci
            ci.Index.create()
        except Exception as exc:
            raise Unreliable(f'libclang (clang.cindex) is not usable: {exc}')
        _CI.append(ci)
    return _CI[0]


def resource_dir():
    """[`-resource-dir=<dir>`] from the clang driver; Unreliable without the driver."""
    return [compile_db.resource_dir_arg()]


def _is_header(path):
    return path.endswith('.h')


def load_compile_db(root):
    """({real path of a source: [(directory, arguments), ...]}, path of the database) from
    <root>/compile_commands.json through compile_db.load (validated, response files expanded),
    entries in file order; ({}, None) when the product has none."""
    if not root:
        return {}, None
    db = os.path.join(root, DB_NAME)
    if os.path.lexists(db) and not os.path.exists(db):
        raise Unreliable(f"'{db}' is a link to a file that does not exist (a build directory removed?) - "
                         f"the product's build configuration is unknown")
    if not os.path.exists(db):
        return {}, None
    out = {}
    for f, directory, args, _output in compile_db.load(db):
        out.setdefault(os.path.realpath(f), []).append((directory, args))
    return out, db


def parse_arguments(argv, directory, source):
    """The compile command `argv` (compiler first) as arguments for the parse."""
    return ['-x', 'c'] + compile_db.parse_args(directory, argv, source) + EXTRA_ARGS + resource_dir()


def product_dirs(root):
    """Every directory of the product tree, the root first; hidden directories (.git) left out."""
    dirs = []

    def fail(err):
        raise Unreliable(f"cannot walk the product tree '{root}': {err}")

    for d, subdirs, _ in os.walk(root, onerror=fail):
        subdirs[:] = sorted(s for s in subdirs if not s.startswith('.'))
        dirs.append(d)
    return dirs


def _first_error(ci, tu, unit_path, origin):
    for d in tu.diagnostics:
        if d.severity >= ci.Diagnostic.Error:
            where = unit_path
            if d.location.file is not None:
                where = f'{d.location.file.name}:{d.location.line}'
            return f'{where}: {d.spelling} (parsed with {origin})'
    return None


def _parse(ci, index, path, args, directory, origin, command=None, db=None):
    try:
        tu = index.parse(path, args=args, options=ci.TranslationUnit.PARSE_DETAILED_PROCESSING_RECORD)
    except Exception as exc:
        raise Unreliable(f"libclang could not parse '{path}' (with {origin}): {exc}")
    err = _first_error(ci, tu, path, origin)
    if err:
        raise Unreliable(f"'{path}' does not parse cleanly: {err}")
    return Unit(path, tu, args, directory, origin, command, db)


def parse(files, root=None):
    """Parse the product's C `files`. Returns (units, owner): one Unit per parse, and for every
    file given (by real path) the Unit whose translation unit holds it. Raises Unreliable."""
    ci = cindex()
    index = ci.Index.create()
    root = os.path.abspath(root) if root else None
    db_entries, db = load_compile_db(root)
    paths = [os.path.abspath(f) for f in files]
    for p in paths:
        if not os.path.isfile(p) or not os.access(p, os.R_OK):
            raise Unreliable(f"cannot read '{p}'")
    if root:
        include = product_dirs(root)
    else:
        include = list(dict.fromkeys(os.path.dirname(p) for p in paths))
    default = DEFAULT_ARGS + EXTRA_ARGS + resource_dir() + [f'-I{d}' for d in include]

    units, owner = [], {}
    sources = [p for p in paths if not _is_header(p)]
    headers = [p for p in paths if _is_header(p)]
    for p in sources + headers:
        real = os.path.realpath(p)
        if real in owner:
            continue
        entry = db_entries.get(real)
        if db and not entry and not _is_header(p):
            raise Unreliable(f"'{p}' is a C source that '{db}' does not list - how the build compiles it "
                             f"is unknown, so it is not parsed with guessed arguments; rebuild the "
                             f"database, or remove the file")
        if entry:
            directory, argv = entry[0]
            unit = _parse(ci, index, p, parse_arguments(argv, directory, real), directory,
                          f"its entry in '{db}'", argv, db)
        else:
            origin = 'the default arguments' + (f" (a header: '{db}' lists sources only)" if db else '')
            unit = _parse(ci, index, p, default, os.path.dirname(p), origin)
        units.append(unit)
        owner[real] = unit
        for inc in unit.tu.get_includes():
            owner.setdefault(unit.real(inc.include.name), unit)
    return units, owner


def main(argv):
    root = None
    if argv[:1] == ['--root']:
        if len(argv) < 2:
            sys.stderr.write('usage: product_tu.py [--root DIR] -- FILE...\n')
            return 2
        root, argv = argv[1], argv[2:]
    if argv[:1] != ['--'] or len(argv) < 2:
        sys.stderr.write('usage: product_tu.py [--root DIR] -- FILE...\n')
        return 2
    files = argv[1:]
    try:
        units, owner = parse(files, root)
    except Unreliable as exc:
        sys.stderr.write(f'product_tu: {exc}\n')
        return 2
    for f in files:
        u = owner[os.path.realpath(f)]
        how = 'parsed' if os.path.realpath(u.path) == os.path.realpath(f) else f"read inside '{u.path}'"
        print(f'{f}: {how}, with {u.origin}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
