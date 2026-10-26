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

A source file (*.c) is parsed on its own. A header is read inside the source that includes it, or
is parsed on its own when no source does. A file that does not parse cleanly - any error,
including a missing header, an unknown compiler flag or a call to an undeclared function - raises
Unreliable with the first error; it is never skipped.

The files are parsed in a pool of processes (CHISEL_PARSE_JOBS, default the CPU count), one
translation unit at a time per process: a check hands `run` a function that judges one parsed unit
and returns plain data, and the unit is dropped before the next is parsed.

Usage (prints how each file was read):
  product_tu.py [--root DIR] -- FILE...

Exit codes:
  0  every FILE parses cleanly
  2  one does not, or libclang / the clang driver is unavailable
"""
import concurrent.futures
import ctypes
import multiprocessing
import os
import sys
from dataclasses import dataclass, field

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'build-checks', 'lib'))
import compile_db  # noqa: E402

DB_NAME = 'compile_commands.json'
DEFAULT_ARGS = ['-x', 'c', '-std=c17']
EXTRA_ARGS = ['-Werror=implicit-function-declaration']

# The product's C cannot be read as the compiler reads it; a check reports UNRELIABLE.
Unreliable = compile_db.Unreliable


@dataclass
class Plan:
    """Everything a worker needs to parse any of the files, as plain (picklable) data."""
    root: str            # the product root, or None
    db: str              # the compile_commands.json read, or None
    entries: dict        # real path of a listed source -> (directory, arguments)
    default: list        # the arguments of a file the database does not list
    dirs: list           # the product tree: the root, or the directories of the files given
    given: list          # the files given, absolute, in order


@dataclass
class Unit:
    path: str            # absolute path of the file parsed
    tu: object           # the clang.cindex TranslationUnit
    args: list           # the arguments the parse used
    directory: str       # the directory relative paths in the parse resolve against
    origin: str          # how the arguments were chosen, for reports
    _reals: dict = field(default_factory=dict)

    def real(self, name):
        """The real path of a file name as the parse reports it (cached: a parse names few files
        many times)."""
        r = self._reals.get(name)
        if r is None:
            r = self._reals[name] = os.path.realpath(os.path.join(self.directory, name))
        return r

    def includes(self):
        """The real path of every file the unit includes."""
        return {self.real(inc.include.name) for inc in self.tu.get_includes()}

    def skipped(self):
        """{real path: [(start offset, end offset)]} of the preprocessor branches this parse skipped
        (clang_getAllSkippedRanges; each range runs from the conditional directive that starts the
        skipped branch to the one that ends it)."""
        ci = cindex()
        lib = ci.conf.lib
        try:
            get, free = lib.clang_getAllSkippedRanges, lib.clang_disposeSourceRangeList
        except AttributeError as exc:
            raise Unreliable(f'this libclang cannot list skipped preprocessor branches: {exc}')
        rl = _range_list()
        get.argtypes, get.restype = [ci.TranslationUnit], ctypes.POINTER(rl)
        free.argtypes, free.restype = [ctypes.POINTER(rl)], None
        lst = get(self.tu)
        out = {}
        try:
            for k in range(lst.contents.count):
                r = lst.contents.ranges[k]
                if r.start.file is not None:
                    out.setdefault(self.real(r.start.file.name), []).append((r.start.offset, r.end.offset))
        finally:
            free(lst)
        return out


_RL = []


def _range_list():
    """The ctypes form of CXSourceRangeList, defined once clang.cindex is loaded."""
    if not _RL:
        ci = cindex()

        class RangeList(ctypes.Structure):
            _fields_ = [('count', ctypes.c_uint), ('ranges', ctypes.POINTER(ci.SourceRange))]
        _RL.append(RangeList)
    return _RL[0]


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


def product_dirs(root):
    """Every directory of the product tree, the root first; hidden directories (.git) left out."""
    dirs = []

    def fail(err):
        raise Unreliable(f"cannot walk the product tree '{root}': {err}")

    for d, subdirs, _ in os.walk(root, onerror=fail):
        subdirs[:] = sorted(s for s in subdirs if not s.startswith('.'))
        dirs.append(d)
    return dirs


def make_plan(files, root=None):
    """Validate the files and the product's compile_commands.json, and fix how each file is parsed."""
    root = os.path.abspath(root) if root else None
    entries, db = load_compile_db(root)
    paths = [os.path.abspath(f) for f in files]
    for p in paths:
        if not os.path.isfile(p) or not os.access(p, os.R_OK):
            raise Unreliable(f"cannot read '{p}'")
        if db and not _is_header(p) and os.path.realpath(p) not in entries:
            raise Unreliable(f"'{p}' is a C source that '{db}' does not list - how the build compiles it "
                             f"is unknown, so it is not parsed with guessed arguments; rebuild the "
                             f"database, or remove the file")
    include = product_dirs(root) if root else list(dict.fromkeys(os.path.dirname(p) for p in paths))
    resource = [compile_db.resource_dir_arg()]
    default = DEFAULT_ARGS + EXTRA_ARGS + resource + [f'-I{d}' for d in include]
    first = {real: (e[0][0], ['-x', 'c'] + compile_db.parse_args(e[0][0], e[0][1], real) + EXTRA_ARGS + resource)
             for real, e in entries.items()}
    dirs = [os.path.realpath(root)] if root else list(dict.fromkeys(os.path.realpath(os.path.dirname(p)) for p in paths))
    return Plan(root, db, first, default, dirs, paths)


def in_product(real, plan):
    """Whether a real path lies in the product tree."""
    return any(real == d or real.startswith(d + os.sep) for d in plan.dirs)


def parse_file(path, plan):
    """The Unit of one file. Raises Unreliable when it does not parse cleanly."""
    ci = cindex()
    real = os.path.realpath(path)
    if real in plan.entries:
        directory, args = plan.entries[real]
        origin = f"its entry in '{plan.db}'"
    else:
        directory, args = os.path.dirname(path), plan.default
        origin = 'the default arguments' + (f" (a header: '{plan.db}' lists sources only)" if plan.db else '')
    try:
        tu = ci.Index.create().parse(path, args=args, options=ci.TranslationUnit.PARSE_DETAILED_PROCESSING_RECORD)
    except Exception as exc:
        raise Unreliable(f"libclang could not parse '{path}' (with {origin}): {exc}")
    for d in tu.diagnostics:
        if d.severity >= ci.Diagnostic.Error:
            where = path if d.location.file is None else f'{d.location.file.name}:{d.location.line}'
            try:
                what = d.spelling
            except UnicodeDecodeError:
                what = 'an error whose message quotes text that is not UTF-8'
            raise Unreliable(f"'{path}' does not parse cleanly: {where}: {what} (parsed with {origin})")
    return Unit(path, tu, args, directory, origin)


def _task(path, plan, work, payload):
    unit = parse_file(path, plan)
    result = work(unit, plan, payload)
    includes = unit.includes()
    del unit
    return result, includes


def _call(fn, item, plan, payload):
    return fn(item, plan, payload)


def jobs_default():
    try:
        return max(1, int(os.environ.get('CHISEL_PARSE_JOBS', '') or os.cpu_count() or 1))
    except ValueError:
        return os.cpu_count() or 1


class Pool:
    """Runs per-file work in worker processes (inline for a single task). Use as a context manager."""

    def __init__(self, jobs=None):
        self.jobs = jobs or jobs_default()
        self._ex = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if self._ex is not None:
            self._ex.shutdown(wait=True, cancel_futures=True)
        return False

    def _map(self, fn, args_list):
        """[fn(*args) for args in args_list], in order; the first exception, in order, is raised."""
        if self.jobs <= 1 or len(args_list) <= 1:
            return [fn(*a) for a in args_list]
        if self._ex is None:
            methods = multiprocessing.get_all_start_methods()
            ctx = multiprocessing.get_context('forkserver' if 'forkserver' in methods else 'spawn')
            self._ex = concurrent.futures.ProcessPoolExecutor(max_workers=self.jobs, mp_context=ctx)
        futures = [self._ex.submit(fn, *a) for a in args_list]
        try:
            return [f.result() for f in futures]
        except BaseException:
            for f in futures:
                f.cancel()
            raise

    def run(self, plan, work, payload):
        """[(path, work(unit, plan, payload))] for every file of the plan that is parsed: each source,
        then each header no source includes (those are read inside their source's unit)."""
        sources = [p for p in plan.given if not _is_header(p)]
        out, covered = [], set()
        for p, (result, inc) in zip(sources, self._map(_task, [(p, plan, work, payload) for p in sources])):
            out.append((p, result))
            covered |= inc | {os.path.realpath(p)}
        headers = [p for p in dict.fromkeys(plan.given) if _is_header(p) and os.path.realpath(p) not in covered]
        for p, (result, inc) in zip(headers, self._map(_task, [(p, plan, work, payload) for p in headers])):
            out.append((p, result))
            covered |= inc
        return out

    def map(self, fn, items, plan, payload):
        """[fn(item, plan, payload)] in the pool, in order."""
        return self._map(_call, [(fn, it, plan, payload) for it in items])


def _describe(unit, plan, payload):
    return unit.origin, sorted(unit.includes())


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
        cindex()
        plan = make_plan(files, root)
        with Pool() as pool:
            parsed = pool.run(plan, _describe, None)
    except Unreliable as exc:
        sys.stderr.write(f'product_tu: {exc}\n')
        return 2
    how = {}
    for path, (origin, includes) in parsed:
        how[os.path.realpath(path)] = f'parsed, with {origin}'
        for inc in includes:
            how.setdefault(inc, f"read inside '{path}', with {origin}")
    for f in files:
        print(f'{f}: {how[os.path.realpath(f)]}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
