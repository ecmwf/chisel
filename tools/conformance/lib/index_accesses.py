#!/usr/bin/env python3
"""index_accesses.py - find open-coded multi-dimensional flattens in the product's C code.

Used by check-index-helpers.sh. The C files are parsed with libclang (lib/product_tu.py), and the
rule is judged on the parse, after macro expansion, never on the text:

  - An ACCESS is an array subscript (`a[e]`) or pointer arithmetic: `p + e` / `p - e` with one
    pointer operand and one integer operand, or `p += e` / `p -= e` on a pointer. A dereference
    `*(p + e)` is the pointer arithmetic inside it. The array sizes in a declaration are not
    accesses, and comments are not code.
  - An access is a FLATTEN when its index (the subscript, or the integer operand) contains a
    multiplication outside a helper: a call to a helper function, or the expansion of a helper
    macro, with everything inside it, belongs to the helper. A nested access is judged on its own.
  - An access that lies wholly inside a helper macro's expansion is the helper's, not counted.
  - Accesses in the central helper header/source (idx.h / idx.c) are not judged: they define the
    helpers.

A flatten is reported at the line of the access as the product's file has it, including when a
macro produces it: then the report names the macro and quotes its use. libclang records only the
outermost macro expansion at a use site, so a helper macro used inside another macro is not seen as
a helper; call the helper at the use site, or list the outer macro as a helper.

Waivers: a line `<path-substring><TAB><content>` of the waiver file waives a flatten whose file
path contains the substring and whose content is exactly the quoted text (the subscript inside the
brackets, the pointer expression, or the macro use), comments dropped and whitespace runs read as
one space.

Usage:
  index_accesses.py --helpers 'NAME...' [--waivers FILE] [--root DIR] -- FILE...

Output (stdout, tab-separated):
  FAIL\t<file>\t<line>\t<description>
  WAIVE\t<file>\t<line>\t<description>
  TOTAL\t<accesses checked>              always last

Exit codes:
  0  ran to completion (the records above)
  2  UNRELIABLE: a file does not parse cleanly, libclang is unavailable, or a file cannot be read
"""
import ctypes
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import product_tu  # noqa: E402

CENTRAL = ('idx.h', 'idx.c')
_BO = []


def _binop(ci):
    """The spelling of a binary operator cursor's operator ('*', '+', '+=', ...)."""
    if not _BO:
        lib = ci.conf.lib
        try:
            kind = lib.clang_getCursorBinaryOperatorKind
            spell = lib.clang_getBinaryOperatorKindSpelling
        except AttributeError as exc:
            raise product_tu.Unreliable(f'this libclang cannot name binary operators (needs 17 or later): {exc}')
        kind.argtypes, kind.restype = [ci.Cursor], ctypes.c_int
        spell.argtypes, spell.restype = [ctypes.c_int], ci._CXString
        cache = {}

        def op(cursor):
            k = kind(cursor)
            if k not in cache:
                cache[k] = ci._CXString.from_result(spell(k))
            return cache[k]

        _BO.append(op)
    return _BO[0]


def read_waivers(path):
    out = []
    if not path:
        return out
    try:
        with open(path, encoding='utf-8') as fh:
            lines = fh.read().splitlines()
    except OSError as exc:
        raise product_tu.Unreliable(f"cannot read the waiver file '{path}': {exc}")
    for ln in lines:
        if not ln.strip() or ln.lstrip().startswith('#') or '\t' not in ln:
            continue
        where, content = ln.split('\t', 1)
        out.append((where, ' '.join(content.split())))
    return out


class Judge:
    """The rule, applied to one parsed unit (in a worker process)."""

    def __init__(self, unit, helpers, given):
        ci = product_tu.cindex()
        self.ci = ci
        self.unit = unit
        self.helpers = set(helpers)
        self.given = given
        self.op = _binop(ci)
        K = ci.TypeKind
        self.pointer_kinds = {K.POINTER, K.CONSTANTARRAY, K.INCOMPLETEARRAY, K.VARIABLEARRAY,
                              K.DEPENDENTSIZEDARRAY}
        self.seen = set()
        self.records = []

    # ---- where a cursor is ----------------------------------------------------------------
    def _file(self, cursor):
        f = cursor.location.file
        return self.unit.real(f.name) if f is not None else None

    def _span(self, cursor):
        e = cursor.extent
        return e.start.offset, e.end.offset

    def _macro_around(self, macros, s, e, helper):
        """The macro expansion (start, end, name) that holds [s, e), helper or not, or None."""
        for ms, me, name in macros:
            if ms <= s and e <= me and (name in self.helpers) == helper:
                return ms, me, name
        return None

    # ---- the rule ---------------------------------------------------------------------------
    def _pointer(self, cursor):
        return cursor.type.get_canonical().kind in self.pointer_kinds

    def access_index(self, cursor):
        """For an access, ('subscript' | 'pointer offset', index cursor); otherwise None."""
        CK = self.ci.CursorKind
        k = cursor.kind
        if k == CK.ARRAY_SUBSCRIPT_EXPR:
            kids = list(cursor.get_children())
            if len(kids) != 2:
                raise product_tu.Unreliable(f'a subscript at line {cursor.location.line} does not have two operands')
            # C allows i[a]: the index is the operand that is not the pointer.
            return 'subscript', (kids[0] if self._pointer(kids[1]) and not self._pointer(kids[0]) else kids[1])
        if k in (CK.BINARY_OPERATOR, CK.COMPOUND_ASSIGNMENT_OPERATOR):
            op = self.op(cursor)
            kids = list(cursor.get_children())
            if len(kids) != 2:
                return None
            a, b = kids
            if op in ('+=', '-=') and self._pointer(a) and not self._pointer(b):
                return 'pointer offset', b
            if op in ('+', '-') and self._pointer(a) != self._pointer(b):
                return 'pointer offset', (b if self._pointer(a) else a)
        return None

    def stride(self, index, macros):
        """The first multiplication in `index` outside a helper, or None. Nested accesses are
        judged on their own and not entered."""
        CK = self.ci.CursorKind
        stack = [index]
        while stack:
            n = stack.pop()
            if n is not index and self.access_index(n) is not None:
                continue
            if n.kind == CK.CALL_EXPR and n.spelling in self.helpers:
                continue
            s, e = self._span(n)
            if self._macro_around(macros, s, e, helper=True):
                continue
            if n.kind == CK.BINARY_OPERATOR and self.op(n) == '*':
                return n
            stack.extend(reversed(list(n.get_children())))
        return None

    def text(self, cursor, s, e):
        """The source text of [s, e) in the cursor's file, comments dropped, whitespace runs as
        one space."""
        ci, tu = self.ci, self.unit.tu
        f = cursor.extent.start.file
        rng = ci.SourceRange.from_locations(ci.SourceLocation.from_offset(tu, f, s),
                                            ci.SourceLocation.from_offset(tu, f, e))
        out, prev = '', None
        for t in tu.get_tokens(extent=rng):
            ts, te = t.extent.start.offset, t.extent.end.offset
            if ts >= e or t.kind == ci.TokenKind.COMMENT:
                prev = te if prev is not None else None
                continue
            if prev is not None and ts > prev:
                out += ' '
            out += t.spelling
            prev = te
        return out

    def judge(self, cursor, path, macros):
        found = self.access_index(cursor)
        if found is None:
            return
        kind, index = found
        s, e = self._span(cursor)
        if self._macro_around(macros, s, e, helper=True):
            return  # the helper's own access
        key = (path, s, e, kind, self._span(index))
        if key in self.seen:
            return
        self.seen.add(key)
        mul = self.stride(index, macros)
        if mul is None:
            return
        quoted = index if kind == 'subscript' else cursor
        qs, qe = self._span(quoted)
        outer = self._macro_around(macros, qs, qe, helper=False)
        if outer:
            ms, me, name = outer
            content = self.text(cursor, ms, me)
            desc = f"ad-hoc {kind} in the expansion of macro '{name}': '{content}'"
        else:
            content = self.text(cursor, qs, qe)
            desc = f"ad-hoc subscript '[{content}]'" if kind == 'subscript' else f"ad-hoc pointer offset '{content}'"
            inner = self._macro_around(macros, *self._span(mul), helper=False)
            if inner:
                desc += f" (the multiply comes from macro '{inner[2]}')"
        self.records.append((key, cursor.location.line, desc, content))

    def run(self):
        CK = self.ci.CursorKind
        macros, tops = {}, []
        for c in self.unit.tu.cursor.get_children():
            path = self._file(c)
            if path is None or path not in self.given or os.path.basename(path) in CENTRAL:
                continue
            if c.kind == CK.MACRO_INSTANTIATION:
                macros.setdefault(path, []).append((c.extent.start.offset, c.extent.end.offset, c.spelling))
            elif not c.kind.is_preprocessing():
                tops.append((path, c))
        for path, top in tops:
            for n in top.walk_preorder():
                if self._file(n) == path:
                    self.judge(n, path, macros.get(path, []))
        return sorted(self.seen), self.records


def judge_unit(unit, plan, payload):
    """Worker: (access keys, flatten records) of one parsed unit."""
    return Judge(unit, payload['helpers'], payload['given']).run()


def scan(files, helpers, waivers, root):
    """[(tag, shown file, line, description)], number of accesses checked."""
    given = {}
    for f in files:
        given.setdefault(os.path.realpath(f), f)
    plan = product_tu.make_plan(files, root)
    with product_tu.Pool() as pool:
        results = pool.run(plan, judge_unit, {'helpers': list(helpers), 'given': set(given)})
    keys, records, seen = set(), [], set()
    for _path, (unit_keys, unit_records) in results:
        keys.update(unit_keys)
        for key, line, desc, content in unit_records:
            if key in seen:
                continue
            seen.add(key)
            shown = given[key[0]]
            waived = any(where in shown and content == want for where, want in waivers)
            records.append(('WAIVE' if waived else 'FAIL', shown, line, desc))
    return records, len(keys)


def main(argv):
    helpers, waivers, root = None, None, None
    while argv and argv[0] != '--':
        if argv[0] in ('--helpers', '--waivers', '--root') and len(argv) > 1:
            if argv[0] == '--helpers':
                helpers = argv[1].split()
            elif argv[0] == '--waivers':
                waivers = argv[1] or None
            else:
                root = argv[1] or None
            argv = argv[2:]
            continue
        sys.stderr.write(f'index_accesses: unknown argument {argv[0]!r}\n')
        return 2
    files = argv[1:]
    if helpers is None or not files:
        sys.stderr.write("usage: index_accesses.py --helpers 'NAME...' [--waivers FILE] [--root DIR] -- FILE...\n")
        return 2
    try:
        product_tu.cindex()
        records, total = scan(files, helpers, read_waivers(waivers), root)
    except product_tu.Unreliable as exc:
        sys.stderr.write(f'index_accesses: {exc}\n')
        return 2
    for tag, path, line, desc in sorted(records, key=lambda r: (r[1], r[2])):
        print(f'{tag}\t{path}\t{line}\t{desc}')
    print(f'TOTAL\t{total}')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
