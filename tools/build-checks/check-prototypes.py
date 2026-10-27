#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""check-prototypes.py - cross-file calls go through the callee's header, with one type everywhere.

Trap T33 (references/pairs/fortran-to-c.md): a call from one SOURCE unit into another, rendered with
a prototype the caller writes for itself, compiles and links even when the prototype disagrees with
the definition (another arity, a pointer level, a qualifier) - undefined behaviour that no per-unit
proof sees, and that a test mocking the callee hides. The compiler sees one file at a time; this
check sees them all. It parses every C translation unit of the build's compilation database with
libclang, with the flags of that unit that shape parsing (macros, include paths, the standard, and
the flags that change predefined macros: the target and its -m options, -O, -fopenmp, -ffast-math,
-funsigned-char, -pthread, -ansi; lib/compile_db.py `parse_args`), and requires:

- every declaration of each externally visible function and variable to have the same type
  (canonical types, so a typedef is not a difference; an unprototyped `f()` differs from `f(int)`;
  an array declared without its size, `extern const double t[];`, matches the sized definition);
- no caller-local prototype: an external function is declared in a header (the callee's own, T33's
  rendering) or defined, never declared without its body inside a .c file that does not define it -
  a matching local prototype can drift later.

`main` is not compared (each executable of a build has its own), nor is anything declared in a
system header.

Usage: check-prototypes.py --compile-commands FILE
Exit:  0 GREEN, 1 RED (a name declared with two types, or a caller-local prototype), 2 UNRELIABLE (no or
       empty database, a malformed entry, a unit libclang cannot parse - including a kept gcc-only flag
       clang does not know, such as -mpreferred-stack-boundary=, which clang names - libclang missing).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'lib'))
from compile_db import Unreliable, load, parse_args, resource_dir_arg  # noqa: E402


def _type_key(ci, t):
    """(canonical spelling, 'unsized' | 'sized' | '' , canonical element spelling of an array)."""
    ct = t.get_canonical()
    if ct.kind == ci.TypeKind.INCOMPLETEARRAY:
        return (ct.spelling, 'unsized', ct.element_type.get_canonical().spelling)
    if ct.kind == ci.TypeKind.CONSTANTARRAY:
        return (ct.spelling, 'sized', ct.element_type.get_canonical().spelling)
    return (ct.spelling, '', '')


def _conflicting(typed):
    """{type spelling: {(file, line)}} of one name, an array declared without its size dropped when a
    sized array of the same element type is declared too: more than one entry is a conflict."""
    sized_elems = {elem for (_, form, elem) in typed if form == 'sized'}
    return {spelling: where for (spelling, form, elem), where in typed.items()
            if not (form == 'unsized' and elem in sized_elems)}


def declarations(tus):
    """({name: {type key: {(file, line)}}} for every external function and variable,
    {(name, file, line)} of the functions declared without a body inside a .c file that does not
    define them)."""
    try:
        import clang.cindex as ci
    except ImportError as e:
        raise Unreliable(f'clang.cindex (libclang) is not importable: {e}')
    index = ci.Index.create()
    kinds = (ci.CursorKind.FUNCTION_DECL, ci.CursorKind.VAR_DECL)
    out, local = {}, set()
    for f, directory, args, _ in tus:
        if not os.path.isfile(f):
            raise Unreliable(f'the unit {f} does not exist')
        try:
            tu = index.parse(f, args=['-x', 'c'] + parse_args(directory, args, f) + [resource_dir_arg()])
        except ci.TranslationUnitLoadError as e:
            raise Unreliable(f'libclang cannot load {f}: {e}')
        errors = [d for d in tu.diagnostics if d.severity >= ci.Diagnostic.Error]
        if errors:
            raise Unreliable(f'libclang cannot parse {f}: {errors[0]}')
        for c in tu.cursor.walk_preorder():
            if c.kind not in kinds or c.linkage != ci.LinkageKind.EXTERNAL or c.location.file is None:
                continue
            if c.spelling == 'main' or c.location.is_in_system_header:
                continue
            if c.kind == ci.CursorKind.VAR_DECL and c.semantic_parent.kind != ci.CursorKind.TRANSLATION_UNIT \
                    and c.storage_class != ci.StorageClass.EXTERN:
                continue
            where = (os.path.normpath(c.location.file.name), c.location.line)
            out.setdefault(c.spelling, {}).setdefault(_type_key(ci, c.type), set()).add(where)
            if c.kind == ci.CursorKind.FUNCTION_DECL and not c.is_definition() and where[0].endswith('.c') \
                    and c.get_definition() is None:
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
    bad = {}
    for name, typed in decls.items():
        types = _conflicting(typed)
        if len(types) > 1:
            bad[name] = types
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
