#!/usr/bin/env python3
"""check-prototypes.py - cross-file calls go through the callee's header, with one type everywhere.

Trap T33 (references/pairs/fortran-to-c.md): a call from one SOURCE unit into another, rendered with
a prototype the caller writes for itself, compiles and links even when the prototype disagrees with
the definition (another arity, a pointer level, a qualifier) - undefined behaviour that no per-unit
proof sees, and that a test mocking the callee hides. The compiler sees one file at a time; this
check sees them all. It parses every C translation unit of the build's compilation database with
libclang, with that unit's own flags, and requires:

- every declaration of each externally visible function and variable to have the same type
  (canonical types, so a typedef is not a difference; an unprototyped `f()` differs from `f(int)`);
- no caller-local prototype: a function is declared in a header (the callee's own, T33's rendering)
  or defined, never re-declared inside a .c file - a matching local prototype can drift later.

Usage: check-prototypes.py --compile-commands FILE
Exit:  0 GREEN, 1 RED (a name declared with two types, or a caller-local prototype), 2 UNRELIABLE (no or empty database, a unit
       libclang cannot parse, libclang missing).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from compile_db import Unreliable, load, parse_args, resource_dir_arg  # noqa: E402


def declarations(tus):
    """({name: {canonical type: {(file, line)}}} for every external function and variable,
    {(name, file, line)} of the functions declared without a body inside a .c file)."""
    try:
        import clang.cindex as ci
    except ImportError as e:
        raise Unreliable(f'clang.cindex (libclang) is not importable: {e}')
    index = ci.Index.create()
    kinds = (ci.CursorKind.FUNCTION_DECL, ci.CursorKind.VAR_DECL)
    out, local = {}, set()
    for f, directory, args, _ in tus:
        tu = index.parse(f, args=['-x', 'c'] + parse_args(directory, args, f) + [resource_dir_arg()])
        errors = [d for d in tu.diagnostics if d.severity >= ci.Diagnostic.Error]
        if errors:
            raise Unreliable(f'libclang cannot parse {f}: {errors[0]}')
        for c in tu.cursor.walk_preorder():
            if c.kind not in kinds or c.linkage != ci.LinkageKind.EXTERNAL or c.location.file is None:
                continue
            if c.kind == ci.CursorKind.VAR_DECL and c.semantic_parent.kind != ci.CursorKind.TRANSLATION_UNIT \
                    and c.storage_class != ci.StorageClass.EXTERN:
                continue
            where = (os.path.normpath(c.location.file.name), c.location.line)
            out.setdefault(c.spelling, {}).setdefault(c.type.get_canonical().spelling, set()).add(where)
            if c.kind == ci.CursorKind.FUNCTION_DECL and not c.is_definition() and where[0].endswith('.c'):
                local.add((c.spelling,) + where)
    return out, local


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument('--compile-commands', required=True)
    a = ap.parse_args(argv)
    try:
        tus = load(a.compile_commands)
        decls, local = declarations(tus)
    except Unreliable as e:
        print(f'check-prototypes: {e} (UNRELIABLE)', file=sys.stderr)
        return 2
    bad = {n: t for n, t in decls.items() if len(t) > 1}
    for name in sorted(bad):
        print(f'[FAIL] {name} is declared with {len(bad[name])} types:')
        for typ, where in sorted(bad[name].items()):
            print(f'         {typ}  at ' + ', '.join(f'{f}:{ln}' for f, ln in sorted(where)))
    for name, f, ln in sorted(local):
        print(f'[FAIL] {f}:{ln}: {name} is declared here, a caller-local prototype - include its header (T33)')
    red = bool(bad or local)
    print(f'check-prototypes: {len(tus)} translation unit(s), {len(decls)} external name(s); '
          f'{len(bad)} with conflicting types, {len(local)} caller-local prototype(s). RESULT: {"RED" if red else "GREEN"}')
    return 1 if red else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
