#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""index_accesses.py - find open-coded multi-dimensional flattens in the product's C code.

Used by check-index-helpers.sh. The C files are parsed with libclang (lib/product_tu.py), and the
rule is judged on the parse, after macro expansion, never on the text:

  - An ACCESS is an array subscript (`a[e]`) or pointer arithmetic: `p + e` / `p - e` with one
    pointer operand and one integer operand, or `p += e` / `p -= e` on a pointer. A dereference
    `*(p + e)` is the pointer arithmetic inside it. The array sizes in a declaration are not
    accesses, and comments are not code. Pointer arithmetic whose value is only compared (`p < a +
    n*m`, an end pointer) addresses no element and is not an access; a pointer it forms and keeps
    - a row or column pointer `rows[j] = data + j*n`, `double *col = a + j*n`, or an end pointer
    stored in a variable - is one, since it fixes the storage order the helpers own.
  - An access is a FLATTEN when its index (the subscript, or the integer operand) contains a
    multiplication outside a helper: an INTEGER multiplication that is not a constant (clang's
    evaluator cannot fold it), or a left shift that is one in disguise (`j << 4`, a stride of 16). A floating-point product converted to an index (`tab[(int)(x *
    inv_dx)]`) and a constant (`a[3 * 4]`, `a[NX * 2]`) are not strides. A constant times an index
    (`z[2 * k]`, `buf[i * sizeof(x)]`) is: it is the flatten of interleaved data (a complex pair, a
    byte offset), and a port that keeps such an access lists it as a waiver. A HELPER is a function or macro of a helper name that is
    declared or defined in the central helper header/source (idx.h / idx.c): a function or macro
    of that name declared anywhere else (a local static, a #define in the file) is ordinary code
    and is judged. A call to a helper, or the expansion of a helper macro, with everything inside
    it, belongs to the helper - except the index argument (the first) of a ONE-INDEX helper (idx0,
    idx1, idxlb, idx1_stride, or a listed helper with one parameter): its argument is the whole
    address, so a multiply there is a flatten. A nested access is judged on its own. In a helper
    macro's use, clang_getFileLocation tells what the macro's body produces (the helper's) from what
    the caller wrote in its arguments (the caller's, judged as in a helper function's arguments).
  - An access that lies wholly inside a helper macro's expansion is the helper's, not counted.
  - Every file of the product tree a unit includes is judged, not only the files listed for the
    check (a `.inc` included into a function, a header the scan does not list), except a product
    `tests/` directory. Accesses in the central helper header/source (idx.h / idx.c) are not
    judged: they define the helpers.
  - A function or macro of a helper name declared outside the central files is itself reported:
    a local `static long idx2(...)` that open-codes the flatten in its body would otherwise pass at
    every call.
  - A preprocessor branch the parse skips (`#if 0`, an `#ifdef` the build does not set) has no
    parse, so it is judged on its tokens (clang_getAllSkippedRanges, then libclang's lexer): a
    subscript `x[...]`, or a dereference `*(...)` holding a `+` or `-`, whose brackets hold a
    binary `*` is a flatten, reported "in an inactive preprocessor branch". A `[` after a type in
    a declaration is a size, and a `*` after a cast's parentheses is a dereference. Pointer
    arithmetic outside a dereference is not seen there. A branch whose brackets do not close
    inside it cannot be judged: UNRELIABLE. A branch one unit skips and another compiles is
    judged by that unit's parse.

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
ONE_INDEX = {'idx0', 'idx1', 'idxlb', 'idx1_stride'}
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


_TYPE_WORDS = {'void', 'char', 'short', 'int', 'long', 'float', 'double', 'signed', 'unsigned', '_Bool',
               '_Complex', 'const', 'volatile', 'restrict', 'static', 'extern', 'register', 'auto', 'inline',
               '_Thread_local', '_Atomic', 'struct', 'union', 'enum', 'typedef', '__restrict', '__inline',
               '__restrict__', '__inline__', '__const'}
_BOUNDARY = {';', '{', '}', '(', ',', None}


class Tok:
    __slots__ = ('sp', 'kind', 'start', 'end', 'line')

    def __init__(self, sp, kind, start, end, line):
        self.sp, self.kind, self.start, self.end, self.line = sp, kind, start, end, line


class InactiveBranch:
    """The token judgement of a skipped preprocessor branch (no parse exists for it)."""

    def __init__(self, toks, typedefs):
        self.t = toks
        self.typedefs = typedefs

    def _ends_expr(self, k):
        t = self.t[k]
        return t.sp in (')', ']') or (t.kind in ('IDENTIFIER', 'LITERAL') and t.sp not in _TYPE_WORDS)

    def _typeish(self, t):
        return t.sp in _TYPE_WORDS or t.sp == '*' or t.sp in self.typedefs or t.sp.endswith('_t')

    def _match(self, i, open_, close):
        depth = 0
        for j in range(i, len(self.t)):
            if self.t[j].sp == open_:
                depth += 1
            elif self.t[j].sp == close:
                depth -= 1
                if depth == 0:
                    return j
        return None

    def _match_back(self, j, open_, close):
        depth = 0
        for k in range(j, -1, -1):
            if self.t[k].sp == close:
                depth += 1
            elif self.t[k].sp == open_:
                depth -= 1
                if depth == 0:
                    return k
        return None

    def _declaration(self, i):
        """Whether the `[` at i follows a declared name (its brackets give a size)."""
        k = i - 1
        while k >= 0 and self.t[k].sp == ']':
            m = self._match_back(k, '[', ']')
            if m is None:
                return False
            k = m - 1
        if k < 0 or self.t[k].kind != 'IDENTIFIER':
            return False
        k -= 1
        typed = False
        while k >= 0 and self.t[k].sp not in _BOUNDARY:
            t = self.t[k]
            prev = self.t[k - 1].sp if k > 0 else None
            if self._typeish(t) or (t.kind == 'IDENTIFIER' and prev in ('struct', 'union', 'enum')):
                typed = typed or t.sp != '*'
                k -= 1
                continue
            return False
        return typed

    def _cast_before(self, k):
        """Whether the `)` at k closes a cast (parentheses around a type name)."""
        m = self._match_back(k, '(', ')')
        if m is None or m + 1 > k - 1:
            return False
        if m > 0 and self.t[m - 1].sp in ('sizeof', '_Alignof', 'alignof'):
            return False
        inner = self.t[m + 1:k]
        return all(self._typeish(t) or (t.kind == 'IDENTIFIER' and i > 0 and inner[i - 1].sp in
                                         ('struct', 'union', 'enum')) for i, t in enumerate(inner))

    @staticmethod
    def _number(t):
        return t.kind == 'LITERAL' and (t.sp[:1].isdigit() or t.sp[:1] == '.')

    @staticmethod
    def _floating(t):
        sp = t.sp.lower()
        return t.kind == 'LITERAL' and not sp.startswith('0x') and ('.' in sp or 'e' in sp) and sp[:1] in '.0123456789'

    def _multiply(self, lo, hi):
        """The first binary `*` or `<<` among tokens lo..hi-1 that can be a stride (not one of two
        number literals, not a product with a floating literal), or None."""
        for k in range(lo + 1, hi):
            shift = self.t[k].sp == '<<' and self._ends_expr(k - 1)
            if shift or (self.t[k].sp == '*' and self._ends_expr(k - 1)
                         and not (self.t[k - 1].sp == ')' and self._cast_before(k - 1))):
                left, right = self.t[k - 1], self.t[k + 1] if k + 1 < hi else None
                if right is not None and self._number(left) and self._number(right):
                    continue
                if self._floating(left) or (right is not None and self._floating(right)):
                    continue
                return k
        return None

    def flattens(self):
        """[(token index of the access start, '(' or '[' index, closing index, kind, flatten)] for
        every subscript and dereferenced sum; raises Unreliable for brackets that do not close
        inside the branch."""
        out = []
        t = self.t
        for i, tok in enumerate(t):
            if tok.sp == '[' and i > 0 and self._ends_expr(i - 1):
                j = self._match(i, '[', ']')
                if j is None:
                    raise product_tu.Unreliable(f'line {tok.line}: a subscript in an inactive preprocessor branch '
                                                f'does not close inside it, so it cannot be judged')
                if not self._declaration(i):
                    out.append((i - 1, i, j, 'subscript', self._multiply(i + 1, j) is not None))
            elif tok.sp == '*' and (i == 0 or not self._ends_expr(i - 1)) and i + 1 < len(t) and t[i + 1].sp == '(':
                j = self._match(i + 1, '(', ')')
                if j is None:
                    raise product_tu.Unreliable(f'line {tok.line}: a dereference in an inactive preprocessor branch '
                                                f'does not close inside it, so it cannot be judged')
                if any(x.sp in ('+', '-') for x in t[i + 2:j]):
                    out.append((i, i + 1, j, 'pointer offset', self._multiply(i + 2, j) is not None))
        return out


class Judge:
    """The rule, applied to one parsed unit (in a worker process)."""

    def __init__(self, unit, helpers, given, plan):
        ci = product_tu.cindex()
        self.ci = ci
        args = [ci.SourceLocation, ctypes.POINTER(ctypes.c_void_p)] + [ctypes.POINTER(ctypes.c_uint)] * 3
        self._fileloc = ci.conf.lib.clang_getFileLocation
        self._exploc = ci.conf.lib.clang_getExpansionLocation
        for fn in (self._fileloc, self._exploc):
            fn.argtypes, fn.restype = args, None
        lib = ci.conf.lib
        self._evaluate, self._eval_kind, self._eval_dispose = (
            lib.clang_Cursor_Evaluate, lib.clang_EvalResult_getKind, lib.clang_EvalResult_dispose)
        self._evaluate.argtypes, self._evaluate.restype = [ci.Cursor], ctypes.c_void_p
        self._eval_kind.argtypes, self._eval_kind.restype = [ctypes.c_void_p], ctypes.c_int
        self._eval_dispose.argtypes, self._eval_dispose.restype = [ctypes.c_void_p], None
        self.unit = unit
        self.helpers = set(helpers)
        self.given = given
        self.plan = plan
        self._wanted = {}
        self.op = _binop(ci)
        K = ci.TypeKind
        self.pointer_kinds = {K.POINTER, K.CONSTANTARRAY, K.INCOMPLETEARRAY, K.VARIABLEARRAY,
                              K.DEPENDENTSIZEDARRAY}
        self.integer_kinds = {getattr(K, n) for n in (
            'BOOL', 'CHAR_U', 'UCHAR', 'CHAR16', 'CHAR32', 'USHORT', 'UINT', 'ULONG', 'ULONGLONG', 'UINT128',
            'CHAR_S', 'SCHAR', 'WCHAR', 'SHORT', 'INT', 'LONG', 'LONGLONG', 'INT128', 'ENUM') if hasattr(K, n)}
        self.seen = set()
        self.records = []
        self._data = {}
        CK = ci.CursorKind
        self.candidates = {CK.ARRAY_SUBSCRIPT_EXPR, CK.BINARY_OPERATOR, CK.COMPOUND_ASSIGNMENT_OPERATOR}

    # ---- where a cursor is ----------------------------------------------------------------
    def wanted(self, real):
        """Whether accesses in a file are judged: a file checked, or any file of the product tree a
        unit includes (a .inc, a header the scan does not list), but not the central helper files
        and not a product tests/ directory."""
        w = self._wanted.get(real)
        if w is None:
            if os.path.basename(real) in CENTRAL:
                w = False
            elif real in self.given:
                w = True
            else:
                dirs = [d for d in self.plan.dirs if real.startswith(d + os.sep)]
                w = bool(dirs) and 'tests' not in os.path.relpath(real, dirs[0]).split(os.sep)[:-1]
            self._wanted[real] = w
        return w

    def _file(self, cursor):
        f = cursor.location.file
        return self.unit.real(f.name) if f is not None else None

    def _span(self, cursor):
        """[start, end) of the cursor as the file is written: an expression written in a macro's
        arguments has its own place; one the macro's body produces spans the whole macro use."""
        e = cursor.extent
        return self._floc(e.start), self._floc(e.end)

    def _floc(self, loc):
        """clang_getFileLocation's offset: where a macro argument was written, or where a macro was
        expanded; the expansion offset when that lies in another file."""
        f, line, col, off = ctypes.c_void_p(), ctypes.c_uint(), ctypes.c_uint(), ctypes.c_uint()
        self._fileloc(loc, ctypes.byref(f), ctypes.byref(line), ctypes.byref(col), ctypes.byref(off))
        g, goff = ctypes.c_void_p(), ctypes.c_uint()
        self._exploc(loc, ctypes.byref(g), ctypes.byref(line), ctypes.byref(col), ctypes.byref(goff))
        return off.value if f.value == g.value else goff.value

    def _written_arg(self, cursor, macro, operator):
        """The index of the argument of the helper macro use `macro` that `cursor` is written in
        (its text there holds its own `operator`), or None when the macro's body produces it."""
        ms, me, _name, _kind, args = macro
        fb, fe = self._span(cursor)
        if not (ms < fb and fe <= me):
            return None
        ci, tu = self.ci, self.unit.tu
        f = cursor.extent.start.file
        rng = ci.SourceRange.from_locations(ci.SourceLocation.from_offset(tu, f, fb),
                                            ci.SourceLocation.from_offset(tu, f, fe))
        if operator not in [self._tsp(t) for t in tu.get_tokens(extent=rng) if t.extent.start.offset < fe]:
            return None
        return next((k for k, (a, b) in enumerate(args) if a <= fb < b), None)

    def _arguments(self, cursor):
        """[(start, end)] of each argument of a function-like macro use, as written."""
        ci, tu = self.ci, self.unit.tu
        toks = [t for t in tu.get_tokens(extent=cursor.extent) if t.kind != ci.TokenKind.COMMENT]
        out, depth, start, last = [], 0, None, None
        for t in toks[1:]:
            sp = self._tsp(t)
            if sp == '(':
                depth += 1
                if depth == 1:
                    continue
            elif sp == ')':
                depth -= 1
                if depth == 0:
                    if start is not None:
                        out.append((start, last))
                    break
            if depth == 1 and sp == ',':
                out.append((start if start is not None else t.extent.start.offset, last or t.extent.start.offset))
                start, last = None, None
                continue
            if depth >= 1:
                start = t.extent.start.offset if start is None else start
                last = t.extent.end.offset
        return out

    def _macro_around(self, macros, s, e, helper):
        """The macro use (start, end, name, kind, argument spans) that holds [s, e), a helper's or
        not, or None. kind is 'one' or 'multi' for a helper macro, None for any other macro."""
        for m in macros:
            if m[0] <= s and e <= m[1] and (m[3] is not None) == helper:
                return m
        return None

    @staticmethod
    def _central(decl):
        """Whether a declaration or definition (or the first declaration of its entity) is in the
        central helper header/source."""
        for c in (decl, getattr(decl, 'canonical', None)):
            if c is not None and c.location.file is not None and os.path.basename(c.location.file.name) in CENTRAL:
                return True
        return False

    def helper_call(self, call):
        """'one' or 'multi' for a call to a central helper function, otherwise None."""
        if call.spelling not in self.helpers:
            return None
        ref = call.referenced
        if ref is None or ref.kind != self.ci.CursorKind.FUNCTION_DECL or not self._central(ref):
            return None
        return 'one' if call.spelling in ONE_INDEX or len(list(ref.get_arguments())) == 1 else 'multi'

    def helper_macro(self, inst):
        """'one' or 'multi' for an expansion of a central helper macro, otherwise None."""
        if inst.spelling not in self.helpers:
            return None
        ref = inst.referenced
        if ref is None or ref.kind != self.ci.CursorKind.MACRO_DEFINITION or not self._central(ref):
            return None
        toks = list(ref.get_tokens())
        params = 0
        if len(toks) > 1 and self._tsp(toks[1]) == '(' and toks[1].extent.start.offset == toks[0].extent.end.offset:
            for t in toks[2:]:
                sp = self._tsp(t)
                if sp == ')':
                    break
                params += sp != ','
        return 'one' if inst.spelling in ONE_INDEX or params == 1 else 'multi'

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
        """(the first multiplication in `index` outside a helper, the one-index helper whose index
        argument holds it or None), or (None, None). Nested accesses are judged on their own and
        not entered."""
        CK = self.ci.CursorKind
        # Only a helper macro used within this index belongs to it: an access written in a helper's
        # argument is the caller's, and the helper around it does not cover its index.
        lo, hi = self._span(index)
        macros = [m for m in macros if lo <= m[0] and m[1] <= hi]
        stack = [(index, None)]
        while stack:
            n, within = stack.pop()
            if n is not index and self.access_index(n) is not None:
                continue
            if n.kind == CK.CALL_EXPR:
                kind = self.helper_call(n)
                if kind == 'one':
                    args = list(n.get_arguments())
                    if args:
                        stack.append((args[0], n.spelling))
                    continue
                if kind == 'multi':
                    continue
            if n.kind == CK.BINARY_OPERATOR and self.op(n) in ('*', '<<') and self._stride_shaped(n):
                m = self._macro_around(macros, *self._span(n), helper=True)
                if m is None:
                    return n, within
                k = self._written_arg(n, m, self.op(n))
                if k == 0 and m[3] == 'one':
                    return n, m[2]  # written in a one-index helper macro's index argument
                # otherwise the helper macro's body, or one of its other arguments: the helper's
            stack.extend((c, within) for c in reversed(list(n.get_children())))
        return None, None

    def _stride_shaped(self, mul):
        """An integer multiplication or left shift clang's evaluator cannot fold to a constant."""
        if mul.type.get_canonical().kind not in self.integer_kinds:
            return False
        r = self._evaluate(mul)
        if r:
            try:
                return self._eval_kind(r) != 1  # CXEval_Int: a constant
            finally:
                self._eval_dispose(r)
        return True

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
            out += self._tsp(t)
            prev = te
        return out

    def judge(self, cursor, path, macros, up):
        found = self.access_index(cursor)
        if found is None:
            return
        kind, index = found
        if kind == 'pointer offset' and up is not None and up.kind == self.ci.CursorKind.BINARY_OPERATOR \
                and self.op(up) in ('<', '<=', '>', '>=', '==', '!='):
            return  # a bound (an end pointer compared against), not an address
        s, e = self._span(cursor)
        m = self._macro_around(macros, s, e, helper=True)
        if m is not None and self._written_arg(cursor, m, '[' if kind == 'subscript' else self.op(cursor)) is None:
            return  # the helper macro's own access
        key = (path, s, e, kind, self._span(index))
        if key in self.seen:
            return
        self.seen.add(key)
        mul, within = self.stride(index, macros)
        if mul is None:
            return
        quoted = index if kind == 'subscript' else cursor
        qs, qe = self._span(quoted)
        outer = self._macro_around(macros, qs, qe, helper=False)
        if outer and qs > outer[0]:
            outer = None  # written in the macro's arguments: quoted as written
        if outer:
            ms, me, name = outer[:3]
            content = self.text(cursor, ms, me)
            desc = f"ad-hoc {kind} in the expansion of macro '{name}': '{content}'"
        else:
            content = self.text(cursor, qs, qe)
            desc = f"ad-hoc subscript '[{content}]'" if kind == 'subscript' else f"ad-hoc pointer offset '{content}'"
            ms_, _me = self._span(mul)
            inner = self._macro_around(macros, ms_, _me, helper=False)
            if inner and ms_ == inner[0]:  # produced by the macro's body, not written in its arguments
                desc += f" (the multiply comes from macro '{inner[2]}')"
        if within:
            desc += f" (in the index argument of one-index helper '{within}')"
        self.records.append((key, cursor.location.line, desc, content))

    def run(self):
        CK = self.ci.CursorKind
        macros, tops = {}, []
        for c in self.unit.tu.cursor.get_children():
            path = self._file(c)
            if path is None or not self.wanted(path):
                continue
            if c.kind in (CK.FUNCTION_DECL, CK.MACRO_DEFINITION) and c.spelling in self.helpers:
                self.misplaced(c, path)
            if c.kind == CK.MACRO_INSTANTIATION:
                hk = self.helper_macro(c)
                macros.setdefault(path, []).append((c.extent.start.offset, c.extent.end.offset, c.spelling,
                                                    hk, self._arguments(c) if hk else []))
            elif not c.kind.is_preprocessing():
                tops.append((path, c))
        transparent = {CK.PAREN_EXPR, CK.UNEXPOSED_EXPR, CK.CSTYLE_CAST_EXPR}
        for path, top in tops:
            stack = [(top, None)]
            while stack:
                n, up = stack.pop()  # up: the nearest enclosing cursor that is not parentheses or a cast
                if n.kind in self.candidates:
                    f = self._file(n)  # a function body may #include a file of its own
                    if f is not None and self.wanted(f):
                        self.judge(n, f, macros.get(f, []), up)
                child_up = up if n.kind in transparent else n
                stack.extend((c, child_up) for c in reversed(list(n.get_children())))
        skipped = self.unit.skipped()
        seen = {r for r in self.unit.includes() | {os.path.realpath(self.unit.path)}
                if self.wanted(r)}
        if any(skipped.get(r) for r in seen):
            typedefs = {c.spelling for c in self.unit.tu.cursor.get_children() if c.kind == CK.TYPEDEF_DECL}
            for r in sorted(seen):
                for lo, hi in skipped.get(r, []):
                    self.inactive(r, lo, hi, typedefs)
        coverage = {r: skipped.get(r, []) for r in seen}
        return sorted(self.seen), self.records, coverage

    def misplaced(self, decl, path):
        """A function or macro of a helper name declared outside the central files: its calls are
        ordinary code (the body that open-codes a flatten is not seen at a call), so the name
        itself is reported."""
        off = decl.extent.start.offset
        key = (path, off, off, 'helper name', decl.spelling)
        if any(r[0] == key for r in self.records):
            return
        what = 'macro' if decl.kind == self.ci.CursorKind.MACRO_DEFINITION else 'function'
        self.records.append((key, decl.location.line,
                             f"{what} '{decl.spelling}' has an index helper's name but is declared here, outside "
                             f"the central idx.h / idx.c - calls to it are not helper calls", decl.spelling))

    def inactive(self, real, lo, hi, typedefs):
        """Judge the tokens of one skipped branch [lo, hi) of a file."""
        ci, tu = self.ci, self.unit.tu
        f = tu.get_file(real)
        data = self._bytes(real)
        rng = ci.SourceRange.from_locations(ci.SourceLocation.from_offset(tu, f, lo),
                                            ci.SourceLocation.from_offset(tu, f, hi))
        toks, directive = [], None
        for t in tu.get_tokens(extent=rng):
            a, b = t.extent.start.offset, t.extent.end.offset
            if a >= hi or t.kind == ci.TokenKind.COMMENT:
                continue
            line = t.location.line
            sp = data[a:b].decode('utf-8', 'surrogateescape')
            if sp == '#' and (not toks or toks[-1].line != line) and directive != line:
                directive = line
            if line == directive:
                continue  # a conditional directive line (#if, #else, #endif) of the branch
            toks.append(Tok(sp, t.kind.name, a, b, line))
        branch = InactiveBranch(toks, typedefs)
        try:
            found = branch.flattens()
        except product_tu.Unreliable as exc:
            raise product_tu.Unreliable(f'{real}: {exc}')
        for start, open_at, close_at, kind, flatten in found:
            key = (real, toks[open_at].start, toks[close_at].end, kind, 'inactive')
            if key in self.seen:
                continue
            self.seen.add(key)
            if not flatten:
                continue
            inner = toks[open_at + 1:close_at]
            text, prev = '', None
            for x in inner:
                text += (' ' if prev is not None and x.start > prev else '') + x.sp
                prev = x.end
            if kind == 'subscript':
                desc = f"ad-hoc subscript '[{text}]' in an inactive preprocessor branch"
            else:
                desc = f"ad-hoc pointer offset '{text}' in an inactive preprocessor branch"
            self.records.append((key, toks[start].line, desc, text))

    def _tsp(self, tok):
        """A token's text, read from the file's bytes (libclang's own spelling must be UTF-8)."""
        f = tok.location.file
        if f is None:
            return tok.spelling
        data = self._bytes(self.unit.real(f.name))
        return data[tok.extent.start.offset:tok.extent.end.offset].decode('utf-8', 'surrogateescape')

    def _bytes(self, real):
        if real not in self._data:
            with open(real, 'rb') as fh:
                self._data[real] = fh.read()
        return self._data[real]


def judge_unit(unit, plan, payload):
    """Worker: (access keys, flatten records) of one parsed unit."""
    return Judge(unit, payload['helpers'], payload['given'], plan).run()


def scan(files, helpers, waivers, root):
    """[(tag, shown file, line, description)], number of accesses checked."""
    given = {}
    for f in files:
        given.setdefault(os.path.realpath(f), f)
    plan = product_tu.make_plan(files, root)
    with product_tu.Pool() as pool:
        results = pool.run(plan, judge_unit, {'helpers': list(helpers), 'given': set(given)})
    coverage = {}
    for _path, (_k, _r, cov) in results:
        for real, ranges in cov.items():
            coverage.setdefault(real, []).append(ranges)

    def active_elsewhere(key):
        """An inactive-branch finding whose place another unit compiles is that unit's parse's."""
        real, off = key[0], key[1]
        return any(not any(lo <= off < hi for lo, hi in ranges) for ranges in coverage.get(real, []))

    keys, records, seen = set(), [], set()
    for _path, (unit_keys, unit_records, _cov) in results:
        keys.update(k for k in unit_keys if k[-1] != 'inactive' or not active_elsewhere(k))
        for key, line, desc, content in unit_records:
            if key in seen or (key[-1] == 'inactive' and active_elsewhere(key)):
                continue
            seen.add(key)
            shown = given.get(key[0], key[0])
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
    sys.stdout.reconfigure(errors='backslashreplace')
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
