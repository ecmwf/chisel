#!/usr/bin/env python3
"""anchor_values - compare an anchored TARGET constant with its SOURCE constant by value.

The verdicts, their precedence and the comparison rules are those of the case corpus README
(tools/conformance/seeded-bugs/verify-anchors/README.md). Every fact comes from a compiler or a
real parser, never from reading the text:

- SOURCE structure (which entity, its components, which carry a default, which are pointers or
  allocatable, whether it has a compile-time value) from fparser's parse of the preprocessed SOURCE
  (`gfortran -cpp -E`); SOURCE values from a probe program compiled by gfortran - the SOURCE's own
  compiler - that prints each leaf's type, kind and bits (CLASS(*), SELECT TYPE, TRANSFER).
- TARGET structure (the entity, its type, which leaves its initializer gives, duplicated or excess
  initializers) from libclang; TARGET values from a probe compiled by clang that prints each leaf
  through memcpy, or for a block-scope constant from clang's own constant evaluator, in its scope.
- `kind` versus `value` for a same-size real difference: the TARGET is rebuilt with only its literal
  precision moved (every f suffix dropped, or every unsuffixed floating literal given one) in the
  macro-expanded TARGET, through clang's tokens; equal afterwards means `kind`.

Verdicts: pass | mismatch (shape, type, kind, value; with `at`) | not-comparable | invalid-anchor.
A situation the verifier cannot judge raises Unreliable - never a pass.

A regime (anchor_binding.Regime) is one build of the pair: the flags each compiler receives and the
SOURCE modules compiled before the cited file. `judge_many` judges many pairs in one regime with one
parse per file and one probe per SOURCE file and per TARGET file; `judge` and `judge_case` judge one.

Usage: anchor_values.py <case-dir>... [--regime dp|sp]   (corpus cases; prints one verdict per line)
"""
import ctypes
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from dataclasses import dataclass, field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from anchor_binding import Regime, regime_of  # noqa: E402,F401  (Regime: for callers)

FFLAGS = ['-cpp', '-O0', '-ffp-contract=off']
CFLAGS = ['-std=c17', '-O0', '-ffp-contract=off']
# Every function and object in its own section, linked with --gc-sections: a procedure the probe
# never reaches is dropped with its calls to routines defined elsewhere, so the probe links without
# them (GNU ld, gold and lld alike).
SECTIONS = ['-ffunction-sections', '-fdata-sections']
GC_SECTIONS = ['-Wl,--gc-sections']


class Unreliable(RuntimeError):
    """The verifier cannot judge this pair; reported as UNRELIABLE, never as a pass."""


@dataclass
class Verdict:
    verdict: str                 # pass | mismatch | not-comparable | invalid-anchor
    mismatch: str = ''           # shape | type | kind | value
    at: str = ''                 # [k], .f, .in.b, .k[2]
    reason: str = ''

    def line(self):
        out = self.verdict + (f' {self.mismatch}' if self.mismatch else '') + (f' at {self.at}' if self.at else '')
        return out + (f' - {self.reason}' if self.reason else '')


def _run(cmd, cwd=None, what='a command'):
    p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        first = next((ln for ln in p.stdout.splitlines() if 'error' in ln.lower()), p.stdout.strip()[:300])
        raise Unreliable(f'{what} failed: {first.strip()}')
    return p.stdout


# ==== SOURCE: structure through fparser, values through a gfortran probe ===========================

@dataclass
class SLeaf:
    path: str             # '' (scalar), '.n', '.in.b'; array elements get '[k]' appended
    expr: str             # the Fortran expression the probe prints
    array: bool = False   # one leaf per element, in storage order
    pointer: bool = False # compared by association
    explicit: bool = True # the SOURCE spells out a value here
    null_default: bool = False


@dataclass
class SEntity:
    kind: str                       # value | type | module | runtime
    module: str = ''                # the module the probe USEs
    reason: str = ''                # why a runtime entity has no compile-time value
    struct: str = ''                # the C struct a brace-list initializer of it fills, if any
    decls: list = field(default_factory=list)
    leaves: list = field(default_factory=list)


def _fparser():
    try:
        from fparser.common.readfortran import FortranStringReader
        from fparser.two.parser import ParserFactory
        from fparser.two import Fortran2003 as F, utils
    except ImportError as e:
        raise Unreliable(f'fparser is not importable ({e}); install it: pip install fparser')
    return FortranStringReader, ParserFactory, F, utils


def preprocess_fortran(path, regime):
    return _run(['gfortran'] + FFLAGS[:1] + list(regime_of(regime).fflags) + ['-E', '-P', path],
                what='gfortran -E (the SOURCE preprocessor)')


def _up(x):
    return str(x).strip().upper()


def _attrs(attr_list):
    return [] if attr_list is None else [_up(a) for a in attr_list.children]


def _in_procedure(node, F):
    p = node.parent
    while p is not None:
        if isinstance(p, (F.Function_Subprogram, F.Subroutine_Subprogram)):
            return True
        p = p.parent
    return False


def _is_array(decl, attrs):
    return decl.children[1] is not None or any(a.startswith('DIMENSION') for a in attrs)


_FPARSER_LOCK = threading.Lock()


def parse_fortran(text):
    """fparser's parse tree of preprocessed SOURCE text."""
    FortranStringReader, ParserFactory, F, utils = _fparser()
    from fparser.two.symbol_table import SYMBOL_TABLES
    with _FPARSER_LOCK:  # fparser keeps global parser state
        SYMBOL_TABLES.clear()
        try:
            return ParserFactory().create(std='f2008')(FortranStringReader(text, ignore_comments=True))
        except Exception as e:  # fparser raises its own error types
            raise Unreliable(f'fparser cannot parse the SOURCE: {e}')


def analyse_source(text, name, others=()):
    """The SOURCE entity `name`: what it is and the leaves the probe prints. `others` are the parse
    trees of the modules it USEs."""
    tree = parse_fortran(text)
    _, _, F, utils = _fparser()
    return _analyse_tree(tree, name, F, utils, others)


def _analyse_tree(tree, name, F, utils, others=()):
    """The entity `name` of `tree`; `others` are the trees of the modules it USEs, where a derived
    type of one of its components may be defined."""
    NAME = name.upper()
    walk = utils.walk

    types = {}
    for t in list(others) + [tree]:
        for td in walk(t, F.Derived_Type_Def):
            types[_up(td.children[0].children[1])] = td

    def module_of(node):
        p = node
        while p is not None and not isinstance(p, F.Module):
            p = p.parent
        return _up(p.children[0].children[1]) if p is not None else ''

    def type_leaves(tname, prefix, expr, all_explicit):
        """Leaves of a variable of derived type tname: every component with its default (or, when
        all_explicit, every component - a constructor or initializer gives them all)."""
        td = types.get(tname)
        if td is None:
            raise Unreliable(f'derived type {tname} is not defined in the SOURCE')
        out = []
        for comp in walk(td, F.Data_Component_Def_Stmt):
            tspec, attr_list, decl_list = comp.children
            attrs = _attrs(attr_list)
            for d in decl_list.children:
                cname = _up(d.children[0])
                init = d.children[3]
                path, cexpr = f'{prefix}.{cname.lower()}', f'{expr}%{cname}'
                pointer = 'POINTER' in attrs
                if isinstance(tspec, F.Declaration_Type_Spec) and not pointer:
                    inner = _up(tspec.children[1])
                    out += type_leaves(inner, path, cexpr, all_explicit or init is not None)
                    continue
                null = init is not None and 'NULL' in _up(init)
                explicit = all_explicit or init is not None
                out.append(SLeaf(path, cexpr, array=_is_array(d, attrs) and not pointer, pointer=pointer,
                                 explicit=explicit and not (pointer and init is None and not all_explicit),
                                 null_default=null))
        return out

    # a MODULE: its context, the module variables
    for mod in walk(tree, F.Module):
        if _up(mod.children[0].children[1]) == NAME:
            # naming: SOURCE names preserved; a module's state is the context struct <module>_ctx (T7)
            ent = SEntity('module', module=NAME, struct=NAME.lower() + '_ctx')
            data_init = _data_initialized(mod, F, walk)
            spec = next((c for c in mod.children if isinstance(c, F.Specification_Part)), None)
            for st in ([] if spec is None else walk(spec, F.Type_Declaration_Stmt)):
                if _in_procedure(st, F) or st.parent is None:
                    continue
                tspec, attr_list, decl_list = st.children
                attrs = _attrs(attr_list)
                if 'PARAMETER' in attrs:
                    continue
                for d in decl_list.children:
                    vname = _up(d.children[0])
                    init = d.children[3]
                    pointer = 'POINTER' in attrs
                    if isinstance(tspec, F.Declaration_Type_Spec) and not pointer:
                        ent.leaves += type_leaves(_up(tspec.children[1]), f'.{vname.lower()}', vname,
                                                  init is not None or vname in data_init)
                        continue
                    has = init is not None or vname in data_init
                    ent.leaves.append(SLeaf(f'.{vname.lower()}', vname, array=_is_array(d, attrs) and not pointer,
                                            pointer=pointer, explicit=has,
                                            null_default=init is not None and 'NULL' in _up(init)))
            return ent

    # a TYPE: its default initialization
    if NAME in types:
        ent = SEntity('type', module=module_of(types[NAME]), struct=NAME.lower(),
                      decls=[f'TYPE({NAME}) :: CHISEL_V'])
        ent.leaves = type_leaves(NAME, '', 'CHISEL_V', False)
        return ent

    # a function result is a run-time value
    for fs in walk(tree, F.Function_Stmt):
        if _up(fs.children[1]) == NAME:
            return SEntity('runtime', reason=f'{NAME} is a function result, a run-time value')

    # a declared entity
    for st in walk(tree, F.Type_Declaration_Stmt):
        tspec, attr_list, decl_list = st.children
        attrs = _attrs(attr_list)
        for d in decl_list.children:
            if _up(d.children[0]) != NAME:
                continue
            init = d.children[3]
            local = _in_procedure(st, F)
            mod = module_of(st)
            if 'ALLOCATABLE' in attrs:
                return SEntity('runtime', reason=f'{NAME} is allocatable: its value exists only at run time')
            if 'PARAMETER' not in attrs and init is None and NAME not in _data_initialized(st.parent, F, walk):
                return SEntity('runtime', reason=f'{NAME} has no initial value: it is set at run time')
            if local and 'PARAMETER' not in attrs:
                return SEntity('runtime', reason=f'{NAME} is a procedure-local variable')
            if local:
                raise Unreliable(f'{NAME} is a procedure-local constant; the probe cannot reach it')
            pointer = 'POINTER' in attrs
            ent = SEntity('value', module=mod)
            if isinstance(tspec, F.Declaration_Type_Spec) and not pointer:
                ent.struct = _up(tspec.children[1]).lower()
                ent.leaves = type_leaves(_up(tspec.children[1]), '', NAME, True)
            else:
                ent.leaves = [SLeaf('', NAME, array=_is_array(d, attrs) and not pointer, pointer=pointer,
                                    null_default=init is not None and 'NULL' in _up(init))]
            return ent
    raise Unreliable(f'the SOURCE declares no {NAME}')


def _data_initialized(scope, F, walk):
    names = set()
    for ds in walk(scope, F.Data_Stmt):
        for st in walk(ds, F.Data_Stmt_Set):
            for n in walk(st.children[0], F.Name):
                names.add(_up(n))
    return names


SHOW_F90 = '''MODULE CHISEL_SHOW
  IMPLICIT NONE
CONTAINS
  SUBROUTINE CHISEL_LEAF(PATH, X)
    CHARACTER(*), INTENT(IN) :: PATH
    CLASS(*), INTENT(IN) :: X
    SELECT TYPE (X)
    TYPE IS (INTEGER(1))
      WRITE(*,'(A,A,I0)') PATH, ' integer 1 ', X
    TYPE IS (INTEGER(2))
      WRITE(*,'(A,A,I0)') PATH, ' integer 2 ', X
    TYPE IS (INTEGER(4))
      WRITE(*,'(A,A,I0)') PATH, ' integer 4 ', X
    TYPE IS (INTEGER(8))
      WRITE(*,'(A,A,I0)') PATH, ' integer 8 ', X
    TYPE IS (REAL(4))
      WRITE(*,'(A,A,Z8.8)') PATH, ' real 4 ', TRANSFER(X, 0_4)
    TYPE IS (REAL(8))
      WRITE(*,'(A,A,Z16.16)') PATH, ' real 8 ', TRANSFER(X, 0_8)
    TYPE IS (COMPLEX(4))
      WRITE(*,'(A,A,Z8.8,1X,Z8.8)') PATH, ' complex 4 ', TRANSFER(REAL(X), 0_4), TRANSFER(AIMAG(X), 0_4)
    TYPE IS (COMPLEX(8))
      WRITE(*,'(A,A,Z16.16,1X,Z16.16)') PATH, ' complex 8 ', TRANSFER(REAL(X), 0_8), TRANSFER(AIMAG(X), 0_8)
    TYPE IS (LOGICAL(1))
      WRITE(*,'(A,A,I0)') PATH, ' logical 1 ', MERGE(1, 0, X)
    TYPE IS (LOGICAL(2))
      WRITE(*,'(A,A,I0)') PATH, ' logical 2 ', MERGE(1, 0, X)
    TYPE IS (LOGICAL(4))
      WRITE(*,'(A,A,I0)') PATH, ' logical 4 ', MERGE(1, 0, X)
    TYPE IS (LOGICAL(8))
      WRITE(*,'(A,A,I0)') PATH, ' logical 8 ', MERGE(1, 0, X)
    CLASS DEFAULT
      WRITE(*,'(A,A)') PATH, ' unsupported 0 0'
    END SELECT
  END SUBROUTINE CHISEL_LEAF
  SUBROUTINE CHISEL_ELEM(PATH, K, X)
    CHARACTER(*), INTENT(IN) :: PATH
    INTEGER, INTENT(IN) :: K
    CLASS(*), INTENT(IN) :: X
    CHARACTER(32) :: IDX
    WRITE(IDX,'(I0)') K
    CALL CHISEL_LEAF(PATH // '[' // TRIM(IDX) // ']', X)
  END SUBROUTINE CHISEL_ELEM
END MODULE CHISEL_SHOW
'''


def _source_body(ent):
    """The probe statements printing every leaf of a SOURCE entity."""
    body = []
    for i, leaf in enumerate(ent.leaves):
        if not (leaf.explicit or leaf.null_default):
            continue  # no SOURCE value here (and an unset pointer has no association to ask)
        p = leaf.path or '-'
        if leaf.pointer:
            body.append(f"  WRITE(*,'(A,A,I0)') '{p}', ' ptr 0 ', MERGE(1, 0, ASSOCIATED({leaf.expr}))")
        elif leaf.array:
            body += [f'  ASSOCIATE (CHISEL_P{i} => PACK({leaf.expr}, .TRUE.))',
                     f"    WRITE(*,'(A,A,I0)') '{p}', ' count 0 ', SIZE(CHISEL_P{i})",
                     f'    DO CHISEL_I = 1, SIZE(CHISEL_P{i})',
                     f"      CALL CHISEL_ELEM('{p}', CHISEL_I - 1, CHISEL_P{i}(CHISEL_I))",
                     '    END DO', '  END ASSOCIATE']
        else:
            body.append(f"  CALL CHISEL_LEAF('{p}', {leaf.expr})")
    return body


def source_probe(src_path, ents, regime, work):
    """{i: (values, counts) or Unreliable} for the SOURCE entities [(i, SEntity)] of one file, from one
    probe: each entity in its own internal subroutine with its own USE, so names of different
    modules cannot clash, and its output after a `@ <i>` line. A probe that does not build or run
    raises Unreliable for all of them."""
    regime = regime_of(regime)
    calls, subs = [], []
    for i, ent in ents:
        calls.append(f'  CALL CHISEL_E{i}')
        subs += ([f'SUBROUTINE CHISEL_E{i}', '  USE CHISEL_SHOW', f'  USE {ent.module}', '  IMPLICIT NONE',
                  '  INTEGER :: CHISEL_I'] + [f'  {d}' for d in ent.decls]
                 + [f"  WRITE(*,'(A,I0)') '@ ', {i}"] + _source_body(ent) + [f'END SUBROUTINE CHISEL_E{i}'])
    prog = '\n'.join(['PROGRAM CHISEL_PROBE', '  IMPLICIT NONE'] + calls + ['CONTAINS'] + subs
                     + ['END PROGRAM CHISEL_PROBE', ''])
    d = tempfile.mkdtemp(prefix='fprobe-', dir=work)
    with open(os.path.join(d, 'show.f90'), 'w') as fh:
        fh.write(SHOW_F90)
    with open(os.path.join(d, 'probe.f90'), 'w') as fh:
        fh.write(prog)
    src = os.path.abspath(src_path)
    deps = [os.path.abspath(f) for f in regime.fsources if os.path.abspath(f) != src]
    _run(['gfortran'] + FFLAGS + SECTIONS + list(regime.fflags) + ['-o', 'probe'] + deps
         + [src, 'show.f90', 'probe.f90'] + list(regime.ldflags) + GC_SECTIONS,
         cwd=d, what='compiling the SOURCE probe with gfortran')
    sections = _sections(_run([os.path.join(d, 'probe')], cwd=d, what='running the SOURCE probe'))
    return {i: _guard(lambda i=i: _parse_probe(_section(sections, i, 'SOURCE'))) for i, _ in ents}


def source_values(src_path, ent, regime, work):
    """{path: (class, size, value)} for every SOURCE leaf, plus {path: count} for arrays."""
    r = source_probe(src_path, [(0, ent)], regime, work)[0]
    if isinstance(r, Unreliable):
        raise r
    return r


def _sections(out):
    """A batched probe's output split at its `@ <i>` lines: {i: [lines]}."""
    secs, cur = {}, None
    for ln in out.splitlines():
        m = re.fullmatch(r'\s*@ ([0-9]+)\s*', ln)
        if m:
            cur = int(m.group(1))
            secs[cur] = []
        elif cur is not None:
            secs[cur].append(ln)
    return secs


def _section(sections, i, side):
    if i not in sections:
        raise Unreliable(f'the {side} probe printed nothing for this entity')
    return '\n'.join(sections[i])


def _guard(fn):
    """fn(), or the Unreliable it raised."""
    try:
        return fn()
    except Unreliable as e:
        return e


def _parse_probe(out):
    """Probe lines are `<path> <class> <size> <value...>`; the path `-` (with any [k]) is the entity."""
    vals, counts = {}, {}
    for ln in out.splitlines():
        parts = ln.split()
        if len(parts) < 4:
            continue
        path = parts[0][1:] if parts[0].startswith('-') else parts[0]
        cls, size, val = parts[1], int(parts[2]), ' '.join(parts[3:]).lower()
        if cls == 'count':
            counts[path] = int(val)
        elif cls == 'unsupported':
            raise Unreliable(f'a SOURCE leaf {path or "(the constant)"} has a type the probe does not print')
        else:
            vals[path] = (cls, size, val)
    return vals, counts


# ==== TARGET: structure through libclang, values through a clang probe ============================

_RES = []


def _clang_args(regime):
    if not _RES:
        p = subprocess.run(['clang', '-print-resource-dir'], capture_output=True, text=True)
        if p.returncode != 0 or not p.stdout.strip():
            raise Unreliable('clang -print-resource-dir failed: the clang driver is needed')
        _RES.append('-resource-dir=' + p.stdout.strip())
    return ['-x', 'c', '-std=c17'] + _RES + list(regime_of(regime).cflags)


def _ci():
    try:
        import clang.cindex as ci
    except ImportError as e:
        raise Unreliable(f'clang.cindex (libclang) is not importable: {e}')
    return ci


def _parse_c(path, regime):
    ci = _ci()
    tu = ci.Index.create().parse(path, args=_clang_args(regime),
                                 options=ci.TranslationUnit.PARSE_DETAILED_PROCESSING_RECORD)
    return tu


def _in_file(c, path):
    f = c.location.file
    return f is not None and os.path.realpath(f.name) == os.path.realpath(path)


def find_target(tu, path, name, line):
    ci = _ci()
    kinds = (ci.CursorKind.VAR_DECL, ci.CursorKind.ENUM_CONSTANT_DECL, ci.CursorKind.MACRO_DEFINITION)
    hits = [c for c in tu.cursor.walk_preorder()
            if c.kind in kinds and c.spelling == name and _in_file(c, path)
            and (c.location.line == line or c.extent.start.line <= line <= c.extent.end.line)]
    if not hits:
        hits = [c for c in tu.cursor.walk_preorder() if c.kind in kinds and c.spelling == name and _in_file(c, path)]
    if len(hits) != 1:
        raise Unreliable(f'{"no" if not hits else len(hits)} TARGET declaration(s) of {name} near line {line}')
    return hits[0]


def _cls(t):
    ci = _ci()
    k = t.get_canonical().kind
    K = ci.TypeKind
    if k == K.BOOL:
        return 'logical'
    if k in (K.CHAR_S, K.SCHAR, K.UCHAR, K.SHORT, K.USHORT, K.INT, K.UINT, K.LONG, K.ULONG, K.LONGLONG,
             K.ULONGLONG, K.ENUM, K.CHAR_U):
        return 'integer'
    if k in (K.FLOAT, K.DOUBLE, K.LONGDOUBLE):
        return 'real'
    if k == K.COMPLEX:
        return 'complex'
    if k == K.POINTER:
        return 'ptr'
    if k == K.RECORD:
        return 'record'
    if k in (K.CONSTANTARRAY, K.INCOMPLETEARRAY):
        return 'array'
    raise Unreliable(f'a TARGET leaf has a type the verifier does not compare: {t.spelling}')


def _base_count(t):
    """The number of non-array elements in a (possibly nested) array type; 1 for anything else."""
    ct = t.get_canonical()
    return ct.element_count * _base_count(ct.element_type) if _cls(t) == 'array' else 1


def _flat(i, sub_n, inner):
    """The path of leaf `inner` of element i, with nested array positions flattened to storage order."""
    m = re.match(r'\[(\d+)\](.*)$', inner) if inner else None
    if sub_n > 1 and m:
        return f'[{i * sub_n + int(m.group(1))}]{m.group(2)}'
    return f'[{i}]{inner}'


def c_leaves(t, expr, path, out):
    """Every leaf of an object of type t, in storage order: (path, class, expr). Array positions are
    flat storage positions: [k] counts elements of the innermost dimension in memory order."""
    cls = _cls(t)
    ct = t.get_canonical()
    if cls == 'record':
        for f in ct.get_fields():
            c_leaves(f.type, f'{expr}.{f.spelling}', f'{path}.{f.spelling}', out)
    elif cls == 'array':
        n, et = ct.element_count, ct.element_type
        sub_n = _base_count(et)
        for i in range(n):
            for p2, c2, e2 in c_leaves(et, f'{expr}[{i}]', '', []):
                out.append((path + _flat(i, sub_n, p2), c2, e2))
    else:
        out.append((path, cls, expr))
    return out


PROBE_C_HEAD = '''#include <stdio.h>
#include <string.h>
#include <stdint.h>
static void chisel_bits(const char *path, const char *cls, size_t n, const void *p)
{
	unsigned char b[32];
	memcpy(b, p, n);
	printf("%s %s %zu ", path[0] ? path : "-", cls, n);
	for (size_t i = n; i-- > 0;)
		printf("%02x", b[i]);
	printf("\\n");
}
'''


def _leaf_stmt(path, cls, expr):
    p = path or '-'
    if cls == 'integer':
        return f'\tprintf("%s integer %zu %lld\\n", "{p}", sizeof({expr}), (long long)({expr}));'
    if cls == 'logical':
        return f'\tprintf("%s logical %zu %d\\n", "{p}", sizeof({expr}), ({expr}) ? 1 : 0);'
    if cls == 'ptr':
        return f'\tprintf("%s ptr 0 %d\\n", "{p}", ({expr}) != 0);'
    if cls == 'real':
        return f'\tchisel_bits("{path}", "real", sizeof({expr}), &({expr}));'
    if cls == 'complex':
        return (f'\t{{ __typeof__({expr}) chisel_z = {expr}; __typeof__(__real__ chisel_z) chisel_re = __real__ chisel_z, '
                f'chisel_im = __imag__ chisel_z; printf("%s complex %zu ", "{p}", sizeof chisel_re); '
                f'chisel_hex(sizeof chisel_re, &chisel_re); printf(" "); chisel_hex(sizeof chisel_im, &chisel_im); printf("\\n"); }}')
    raise Unreliable(f'cannot print a TARGET leaf of class {cls}')


HEX_C = '''static void chisel_hex(size_t n, const void *p)
{
	unsigned char b[32];
	memcpy(b, p, n);
	for (size_t i = n; i-- > 0;)
		printf("%02x", b[i]);
}
'''


def _parse_c_probe(out):
    vals = {}
    for ln in out.splitlines():
        parts = ln.split()
        if len(parts) < 4:
            continue
        path = '' if parts[0] == '-' else parts[0]
        vals[path] = (parts[1], int(parts[2]), ' '.join(parts[3:]).lower())
    return vals


def c_probe(include, groups, regime, work, move=None):
    """{i: values or Unreliable} for the groups [(i, decls, stmts)] of one TARGET file, from one probe
    that includes the TARGET once: each group's statements in their own block, after a `@ <i>` line.
    With `move` ('raise' / 'lower') the whole probe is macro-expanded first and its literal precision
    moved. A probe that does not build or run raises Unreliable for all of them."""
    regime = regime_of(regime)
    d = tempfile.mkdtemp(prefix='cprobe-', dir=work)
    stmts = []
    for i, _, ss in groups:
        stmts += [f'\tprintf("@ %d\\n", {i});', '\t{'] + list(ss) + ['\t}']
    # A TARGET file may define main(): the probe's own main() is the one that runs.
    src = (PROBE_C_HEAD + HEX_C + f'#define main chisel_target_main\n#include "{os.path.abspath(include)}"\n#undef main\n'
           + '\n'.join(dl for _, ds, _ in groups for dl in ds)
           + '\nint main(void)\n{\n' + '\n'.join(stmts) + '\n\treturn 0;\n}\n')
    probe = os.path.join(d, 'probe.c')
    with open(probe, 'w') as fh:
        fh.write(src)
    cflags = list(regime.cflags)
    if move:
        moved = move_literals(_preprocess_c(probe, regime), regime, move, d)
        with open(probe, 'w') as fh:
            fh.write(moved)
        cflags = []
    _run(['clang'] + CFLAGS + cflags + SECTIONS + ['-w', '-o', 'probe', 'probe.c', '-lm'] + list(regime.ldflags)
         + GC_SECTIONS, cwd=d, what='compiling the TARGET probe with clang')
    sections = _sections(_run([os.path.join(d, 'probe')], cwd=d, what='running the TARGET probe'))
    return {i: _guard(lambda i=i: _parse_c_probe(_section(sections, i, 'TARGET'))) for i, _, _ in groups}


def run_c_probe(include, decls, stmts, regime, work, move=None):
    """One group's values (c_probe of a single group)."""
    r = c_probe(include, [(0, decls, stmts)], regime, work, move)[0]
    if isinstance(r, Unreliable):
        raise r
    return r


def _evaluate(cursor):
    """clang's constant evaluator on a declaration, in its own scope: (class, value) or None."""
    ci = _ci()
    lib = ci.conf.lib
    for fn, res, args in (('clang_Cursor_Evaluate', ctypes.c_void_p, [ci.Cursor]),
                          ('clang_EvalResult_getKind', ctypes.c_int, [ctypes.c_void_p]),
                          ('clang_EvalResult_getAsLongLong', ctypes.c_longlong, [ctypes.c_void_p]),
                          ('clang_EvalResult_getAsDouble', ctypes.c_double, [ctypes.c_void_p]),
                          ('clang_EvalResult_dispose', None, [ctypes.c_void_p])):
        f = getattr(lib, fn)
        f.restype, f.argtypes = res, args
    r = lib.clang_Cursor_Evaluate(cursor)
    if not r:
        return None
    try:
        kind = lib.clang_EvalResult_getKind(r)
        if kind == 1:
            return ('int', lib.clang_EvalResult_getAsLongLong(r))
        if kind == 2:
            return ('float', lib.clang_EvalResult_getAsDouble(r))
        return None
    finally:
        lib.clang_EvalResult_dispose(r)


def _scalar_from_eval(cursor):
    import struct
    ev = _evaluate(cursor)
    if ev is None:
        return None
    cls = _cls(cursor.type)
    size = cursor.type.get_canonical().get_size()
    if cls in ('integer',):
        return (cls, size, str(ev[1]))
    if cls == 'logical':
        return (cls, size, '1' if ev[1] else '0')
    if cls == 'real':
        v = float(ev[1])
        raw = struct.pack('<f', v) if size == 4 else struct.pack('<d', v)
        return (cls, size, raw[::-1].hex())
    return None


# ---- the TARGET initializer's structure: which leaves it gives ----------------------------------

@dataclass
class Given:
    leaves: list = field(default_factory=list)   # paths the initializer gives, in order
    dupes: list = field(default_factory=list)    # paths given twice
    excess: list = field(default_factory=list)   # paths past the end


def _strip(c):
    ci = _ci()
    while c.kind == ci.CursorKind.UNEXPOSED_EXPR and not any(x.kind == ci.CursorKind.MEMBER_REF for x in c.get_children()):
        kids = list(c.get_children())
        if len(kids) != 1:
            break
        c = kids[0]
    return c


def _is_zero_literal(c):
    """The integer literal 0 (its value from clang's evaluator: a macro-expanded literal has no
    tokens of its own at the use site)."""
    ci = _ci()
    c = _strip(c)
    return c.kind == ci.CursorKind.INTEGER_LITERAL and _evaluate(c) == ('int', 0)


def given_leaves(init, t, path, g):
    """Walk an initializer list against type t (C's rules, field designators included)."""
    ci = _ci()
    init = _strip(init)
    cls = _cls(t)
    ct = t.get_canonical()
    if init.kind != ci.CursorKind.INIT_LIST_EXPR or cls not in ('record', 'array'):
        # a whole object given by one expression: all its leaves
        g.leaves += [p for p, _, _ in c_leaves(t, 'x', path, [])]
        return
    kids = list(init.get_children())
    if len(kids) == 1 and _is_zero_literal(kids[0]):
        return  # {0}: the universal zero initializer gives no field
    if cls == 'record':
        fields = list(ct.get_fields())
        pos = 0
        for k in kids:
            refs = [x for x in k.get_children() if x.kind == ci.CursorKind.MEMBER_REF] if k.kind == ci.CursorKind.UNEXPOSED_EXPR else []
            if refs:
                names = [r.spelling for r in refs]
                idx = next((i for i, f in enumerate(fields) if f.spelling == names[0]), None)
                if idx is None:
                    raise Unreliable(f'designator .{names[0]} names no field')
                value = [x for x in k.get_children() if x.kind != ci.CursorKind.MEMBER_REF][-1]
                fpath = f'{path}.{".".join(names)}'
                ftype = fields[idx].type
                for nm in names[1:]:
                    ftype = next(f.type for f in ftype.get_canonical().get_fields() if f.spelling == nm)
                _give(value, ftype, fpath, g)
                pos = idx + 1
            else:
                if pos >= len(fields):
                    g.excess.append(f'{path}.<excess>')
                    continue
                _give(k, fields[pos].type, f'{path}.{fields[pos].spelling}', g)
                pos += 1
    else:
        n, et = ct.element_count, ct.element_type
        sub_n = _base_count(et)
        aggregate_elem = _cls(et) in ('record', 'array')
        if aggregate_elem and kids and all(_strip(k).kind != ci.CursorKind.INIT_LIST_EXPR for k in kids):
            # brace elision: a flat list fills the base elements in storage order
            total = n * sub_n
            for j in range(len(kids)):
                (g.excess if j >= total else g.leaves).append(f'{path}[{j}]')
            return
        for i, k in enumerate(kids):
            if i >= n:
                g.excess.append(f'{path}[{i * sub_n}]')
                continue
            sub = Given()
            given_leaves(k, et, '', sub)
            g.leaves += [path + _flat(i, sub_n, p2) for p2 in sub.leaves]
            g.dupes += [path + _flat(i, sub_n, p2) for p2 in sub.dupes]
            g.excess += [path + _flat(i, sub_n, p2) for p2 in sub.excess]


def _give(value, t, fpath, g):
    sub = Given()
    given_leaves(value, t, fpath, sub)
    for p in sub.leaves:
        if p in g.leaves:
            g.dupes.append(p)
        else:
            g.leaves.append(p)
    g.dupes += sub.dupes
    g.excess += sub.excess


# ---- literal precision, moved through clang's tokens --------------------------------------------

def move_literals(text, regime, how, work):
    """`text` (macro-expanded C) with every floating literal's precision moved, through clang's
    tokens: 'raise' drops every f suffix, 'lower' gives every unsuffixed floating literal one."""
    ci = _ci()
    name = os.path.join(work, f'moved-{how}.c')
    tu = ci.Index.create().parse(name, args=_clang_args(regime), unsaved_files=[(name, text)])
    data = text.encode()
    edits = []
    for tok in tu.get_tokens(extent=tu.cursor.extent):
        if tok.kind != ci.TokenKind.LITERAL:
            continue
        sp = tok.spelling
        if not re.fullmatch(r'(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+(?=[eE]))(?:[eE][+-]?[0-9]+)?[fFlL]?', sp):
            continue
        a, b = tok.extent.start.offset, tok.extent.end.offset
        if how == 'raise' and sp[-1] in 'fF':
            edits.append((a, b, sp[:-1]))
        elif how == 'lower' and sp[-1] not in 'fFlL':
            edits.append((a, b, sp + 'f'))
    for a, b, sp in sorted(edits, reverse=True):
        data = data[:a] + sp.encode() + data[b:]
    return data.decode()


def _preprocess_c(src, regime):
    return _run(['clang', '-E', '-P'] + CFLAGS[:1] + list(regime_of(regime).cflags) + ['-x', 'c', src],
                what='clang -E (the TARGET preprocessor)')


# ==== the TARGET entity, evaluated ===============================================================

@dataclass
class TEntity:
    runtime: str = ''
    leaves: list = field(default_factory=list)    # [(path, class, expr)] in storage order
    given: Given = None
    values: dict = field(default_factory=dict)
    scalar_cursor: object = None
    decls: list = field(default_factory=list)
    stmts: list = field(default_factory=list)


def _macro_body_tokens(cursor):
    """The macro's replacement tokens, comments dropped and backslash-newline splices removed
    (libclang spells a punctuator raw, splice included)."""
    ci = _ci()
    toks = [t for t in cursor.get_tokens() if t.kind != ci.TokenKind.COMMENT]
    return [re.sub(r'\\[ \t]*(?:\r\n|\r|\n)', '', t.spelling) for t in toks[1:]]


def _split_top(tokens):
    """The comma-separated items of a brace list (its outer braces removed), nested braces flattened."""
    items, depth, cur = [], 0, []
    for t in tokens:
        if t in '([{':
            depth += 1
        elif t in ')]}':
            depth -= 1
        if t == ',' and depth == 0:
            items.append(cur)
            cur = []
        else:
            cur.append(t)
    if cur:
        items.append(cur)
    flat = []
    for it in items:
        if it and it[0] == '{' and it[-1] == '}':
            flat += _split_top(it[1:-1])
        else:
            flat.append(it)
    return flat


def parse_target(tpath, regime):
    """libclang's translation unit of a TARGET file; one clang cannot compile is Unreliable."""
    ci = _ci()
    tu = _parse_c(tpath, regime)
    errs = [str(d) for d in tu.diagnostics if d.severity >= ci.Diagnostic.Error]
    if errs:
        raise Unreliable('clang cannot compile the TARGET: ' + errs[0])
    return tu


def analyse_target(tpath, tname, tline, sent, regime, work, tu=None, tag=''):
    """The TARGET entity `tname` declared at `tline`: its leaves, what its initializer gives, and the
    probe statements printing it. `tu` is the file's parse when the caller has one; `tag` makes the
    probe's own declarations unique when several entities share one probe."""
    ci = _ci()
    if not re.fullmatch(r'[A-Za-z_]\w*', tname):
        return TEntity(runtime=f'{tname} is not a declared object: its value is set by a statement at run time')
    if tu is None:
        tu = parse_target(tpath, regime)
    cur = find_target(tu, tpath, tname, tline)
    te = TEntity()
    if cur.kind == ci.CursorKind.ENUM_CONSTANT_DECL:
        te.leaves = [('', 'integer', tname)]
        te.values = {'': ('integer', cur.type.get_canonical().get_size() if cur.type.get_canonical().kind != ci.TypeKind.INVALID else 4, str(cur.enum_value))}
        te.given = Given([''])
        return te
    if cur.kind == ci.CursorKind.VAR_DECL:
        block = cur.semantic_parent is not None and cur.semantic_parent.kind == ci.CursorKind.FUNCTION_DECL
        exprs = [c for c in cur.get_children() if c.kind.is_expression()]
        init = exprs[-1] if exprs else None  # an array's size expression comes first
        if init is None:
            return TEntity(runtime=f'{tname} has no initializer')
        if block:
            v = _scalar_from_eval(cur)
            if v is None:
                return TEntity(runtime=f'{tname} is initialized by a run-time value')
            te.leaves, te.values, te.given, te.scalar_cursor = [('', v[0], tname)], {'': v}, Given(['']), cur
            return te
        te.leaves = c_leaves(cur.type, tname, '', [])
        te.given = Given()
        given_leaves(init, cur.type, '', te.given)
        te.stmts = [_leaf_stmt(p, c, e) for p, c, e in te.leaves]
        return te
    # a macro
    body = _macro_body_tokens(cur)
    if body and body[0] == '{':
        if sent.struct:
            tdecl = _find_struct(tu, tpath, sent.struct)
            hname = f'chisel_holder{tag}'
            holder = f'static const {tdecl} {hname} = {tname};'
            te.decls = [holder]
            htu = _holder_tu(tpath, holder, regime, work)
            hv = next(c for c in htu.cursor.walk_preorder() if c.kind == ci.CursorKind.VAR_DECL and c.spelling == hname)
            te.leaves = c_leaves(hv.type, hname, '', [])
            te.given = Given()
            given_leaves(next(c for c in hv.get_children() if c.kind.is_expression()), hv.type, '', te.given)
            te.stmts = [_leaf_stmt(p, c, e) for p, c, e in te.leaves]
            return te
        # an array brace list: each element in its own natural type
        items = _split_top(body[1:-1] if body[-1] == '}' else body[1:])
        for k, ex in enumerate(' '.join(it) for it in items):
            te.stmts.append(f'\t{{ __auto_type chisel_e{k} = ({ex}); {{ {_leaf_body(k)} }} }}')
        te.given = Given([f'[{k}]' for k in range(len(items))])
        te.leaves = [(f'[{k}]', None, None) for k in range(len(items))]
        return te
    te.stmts = [f'\t{{ __auto_type chisel_v = ({tname}); {_leaf_body(None)} }}']
    te.leaves = [('', None, None)]
    te.given = Given([''])
    return te


def _leaf_body(k):
    v = 'chisel_v' if k is None else f'chisel_e{k}'
    p = '-' if k is None else f'[{k}]'
    return (f'_Generic(({v}), _Bool: printf("%s logical %zu %d\\n", "{p}", sizeof {v}, {v} ? 1 : 0), '
            f'float: chisel_bits("{p if k is not None else ""}", "real", sizeof {v}, &{v}), '
            f'double: chisel_bits("{p if k is not None else ""}", "real", sizeof {v}, &{v}), '
            f'long double: chisel_bits("{p if k is not None else ""}", "real", sizeof {v}, &{v}), '
            f'default: printf("%s integer %zu %lld\\n", "{p}", sizeof {v}, (long long)({v})));')


def _find_struct(tu, tpath, name):
    """The C type a brace list of the struct `name` fills: the typedef `name` when there is one (an
    untagged `typedef struct {...} name;` gives its struct the spelling `name` too, but no tag), else
    the tagged `struct name`."""
    ci = _ci()
    found = {c.kind for c in tu.cursor.walk_preorder() if c.spelling == name and _in_file(c, tpath)
             and c.kind in (ci.CursorKind.TYPEDEF_DECL, ci.CursorKind.STRUCT_DECL)}
    if ci.CursorKind.TYPEDEF_DECL in found:
        return name
    if ci.CursorKind.STRUCT_DECL in found:
        return f'struct {name}'
    raise Unreliable(f'the TARGET defines no struct or typedef {name} for the initializer to fill')


def _holder_tu(tpath, holder, regime, work):
    ci = _ci()
    name = os.path.join(work, 'holder.c')
    text = f'#include "{os.path.abspath(tpath)}"\n{holder}\n'
    tu = ci.Index.create().parse(name, args=_clang_args(regime), unsaved_files=[(name, text)])
    errs = [str(d) for d in tu.diagnostics if d.severity >= ci.Diagnostic.Error]
    if errs:
        raise Unreliable('the initializer does not compile into its struct: ' + errs[0])
    return tu


def target_values_many(tpath, tes, regime, work, move=None):
    """{i: values or Unreliable} for the TARGET entities {i: TEntity} of one file: a block-scope
    constant from clang's evaluator (on the moved file, with `move`), an enumerator from its
    declaration, everything else from one probe."""
    out, groups, moved_tu = {}, [], []
    for i, te in tes.items():
        if te.scalar_cursor is not None:
            if move is None:
                out[i] = te.values
                continue
            if not moved_tu:
                moved_tu.append(_guard(lambda: _moved_tu(tpath, regime, move, work)))
            out[i] = moved_tu[0] if isinstance(moved_tu[0], Unreliable) else \
                _guard(lambda te=te: _block_value(moved_tu[0], te.scalar_cursor.spelling))
        elif te.values and not te.stmts:
            out[i] = te.values
        else:
            groups.append((i, te.decls, te.stmts))
    if groups:
        out.update(c_probe(tpath, groups, regime, work, move))
    return out


def _moved_tu(tpath, regime, move, work):
    text = move_literals(_preprocess_c(os.path.abspath(tpath), regime), regime, move, work)
    name = os.path.join(work, f'block-{move}.c')
    return _ci().Index.create().parse(name, args=_clang_args(regime), unsaved_files=[(name, text)])


def _block_value(tu, spelling):
    ci = _ci()
    for c in tu.cursor.walk_preorder():
        if c.kind == ci.CursorKind.VAR_DECL and c.spelling == spelling and \
                c.semantic_parent is not None and c.semantic_parent.kind == ci.CursorKind.FUNCTION_DECL:
            v = _scalar_from_eval(c)
            if v:
                return {'': v}
    raise Unreliable('the block-scope constant cannot be re-evaluated')


def target_values(tpath, te, regime, work, move=None):
    r = target_values_many(tpath, {0: te}, regime, work, move)[0]
    if isinstance(r, Unreliable):
        raise r
    return r


# ==== the verdict ================================================================================

ORDER = ('shape', 'type', 'kind', 'value')


def compare(sent, svals, scounts, te, tvals, moved):
    """(mismatch, at) or ('', '') for a pass. `moved` evaluates the TARGET with literal precision
    moved ('raise' / 'lower') and returns its values."""
    # SOURCE leaves, expanded to elements
    sleaves = {}
    for leaf in sent.leaves:
        if leaf.array and (leaf.explicit or leaf.null_default):
            n = scounts.get(leaf.path)
            if n is None:
                raise Unreliable(f'the SOURCE probe gave no element count for {leaf.path or "the array"}')
            for k in range(n):
                sleaves[f'{leaf.path}[{k}]'] = leaf
        else:
            sleaves[leaf.path] = leaf
    tpaths = [p for p, _, _ in te.leaves]
    # `at` names the first difference in the SOURCE's storage order; TARGET-only leaves come after
    order = {p: i for i, p in enumerate(sleaves)}
    for p in tpaths:
        order.setdefault(p, len(order))
    tset = set(tpaths)
    given = set(te.given.leaves)
    problems = []

    def add(kind, path):
        problems.append((ORDER.index(kind), order.get(path, len(order) + len(problems)), path, kind))

    # shape: the initializer gives exactly what the SOURCE spells out
    for p in te.given.dupes:
        add('shape', p)
    for p in te.given.excess:
        add('shape', re.sub(r'\.<excess>$', '', p) or p)
    for p, leaf in sleaves.items():
        if p not in tset:
            add('shape', p)
        elif leaf.explicit and not leaf.null_default and p not in given:
            add('shape', p)
    for p in given:
        if p not in sleaves or not (sleaves[p].explicit or sleaves[p].null_default):
            add('shape', p)
    if not problems:
        for p, leaf in sleaves.items():
            if not (leaf.explicit or leaf.null_default):
                continue
            s = svals.get(p)
            t = tvals.get(p)
            if s is None or t is None:
                raise Unreliable(f'no value for {p or "the constant"} on the {"SOURCE" if s is None else "TARGET"} side')
            scls, ssize, sval = s
            tcls, tsize, tval = t
            if scls != tcls:
                add('type', p)
            elif scls in ('logical', 'ptr'):
                if sval != tval:
                    add('value', p)
            elif ssize != tsize:
                add('kind', p)
            elif sval != tval:
                if scls in ('real', 'complex') and any(moved(how).get(p, (None, None, None))[2] == sval for how in ('raise', 'lower')):
                    add('kind', p)
                else:
                    add('value', p)
    if not problems:
        return '', ''
    problems.sort()
    _, _, path, kind = problems[0]
    return kind, path


@dataclass(frozen=True)
class Pair:
    """One anchored pair: the SOURCE entity `sname` of the file `src` and the TARGET entity `tname`
    declared at line `tline` of the file `tpath`."""
    src: str
    sname: str
    tpath: str
    tname: str
    tline: int


def _cached(cache, key, fn):
    """fn() once per key; an Unreliable is cached and raised again for every later caller."""
    if key not in cache:
        cache[key] = _guard(fn)
    if isinstance(cache[key], Unreliable):
        raise cache[key]
    return cache[key]


def _probe_each(keys, batch):
    """{key: result or Unreliable}: one batched probe over all keys; if it does not build or run, the
    keys split in halves and each half probed again, down to the single entity the probe cannot
    handle - which alone is Unreliable, without taking the others with it."""
    try:
        return batch(keys)
    except Unreliable as e:
        if len(keys) == 1:
            return {keys[0]: e}
    half = len(keys) // 2
    return {**_probe_each(keys[:half], batch), **_probe_each(keys[half:], batch)}


def judge_many(pairs, regime, work):
    """The verdict of every pair in one regime (the anchor rules aside), in order: a Verdict, or the
    Unreliable that stopped that pair. Each file is preprocessed and parsed once; values come from
    one gfortran probe per SOURCE file and one clang probe per TARGET file (and per literal move)."""
    regime = regime_of(regime)
    _, _, F, utils = _fparser()
    out = [None] * len(pairs)
    trees, tus, sents, tes = {}, {}, {}, {}
    others = []

    def other_trees():
        return _cached(trees, ('fsources',), lambda: [parse_fortran(preprocess_fortran(f, regime))
                                                        for f in regime.fsources])

    for i, p in enumerate(pairs):
        try:
            tree = _cached(trees, p.src, lambda p=p: parse_fortran(preprocess_fortran(p.src, regime)))
            others = other_trees()
            sent = _analyse_tree(tree, p.sname, F, utils, others)
            if sent.kind == 'runtime':
                out[i] = Verdict('not-comparable', reason=sent.reason)
                continue
            tu = _cached(tus, p.tpath, lambda p=p: parse_target(p.tpath, regime))
            te = analyse_target(p.tpath, p.tname, p.tline, sent, regime, work, tu=tu, tag=str(i))
            if te.runtime:
                out[i] = Verdict('not-comparable', reason=te.runtime)
                continue
            sents[i], tes[i] = sent, te
        except Unreliable as e:
            out[i] = e

    def by(attr):
        groups = {}
        for i in sents:
            groups.setdefault(getattr(pairs[i], attr), []).append(i)
        return groups

    svalues, tvalues = {}, {}
    for src, idx in by('src').items():
        svalues.update(_probe_each(idx, lambda ks, src=src: source_probe(src, [(k, sents[k]) for k in ks], regime, work)))
    for tpath, idx in by('tpath').items():
        tvalues.update(_probe_each(idx, lambda ks, tpath=tpath: target_values_many(tpath, {k: tes[k] for k in ks}, regime, work)))
    moved_cache = {}

    def moved_for(i, how):
        key = (pairs[i].tpath, how)
        if key not in moved_cache:
            idx = by('tpath')[pairs[i].tpath]
            moved_cache[key] = _probe_each(idx, lambda ks: target_values_many(pairs[i].tpath, {k: tes[k] for k in ks},
                                                                             regime, work, move=how))
        r = moved_cache[key][i]
        if isinstance(r, Unreliable):
            raise r
        return r

    for i in sents:
        try:
            for r in (svalues[i], tvalues[i]):
                if isinstance(r, Unreliable):
                    raise r
            svals, scounts = svalues[i]
            tvals = tvalues[i]
            te = tes[i]
            if te.leaves and te.leaves[0][1] is None:   # macro leaves: classes come from the probe
                te.leaves = [(q, tvals.get(q, (None,))[0], None) for q, _, _ in te.leaves]
            kind, at = compare(sents[i], svals, scounts, te, tvals, lambda how, i=i: moved_for(i, how))
            out[i] = Verdict('mismatch', kind, at) if kind else Verdict('pass')
        except Unreliable as e:
            out[i] = e
    return out


def judge(src_path, tpath, sname, tname, tline, regime, work):
    """The verdict for one anchored pair in one regime (the anchor rules aside)."""
    r = judge_many([Pair(src_path, sname, tpath, tname, tline)], regime, work)[0]
    if isinstance(r, Unreliable):
        raise r
    return r


def judge_case(case_dir, regime):
    """A corpus case: the anchor rules first (invalid-anchor), then the values."""
    import yaml
    import anchor_binding as ab
    meta = yaml.safe_load(open(os.path.join(case_dir, 'case.yaml'), encoding='utf-8'))
    src = os.path.join(case_dir, meta['source']['file'])
    tfile = meta['target']['file']
    tpath = os.path.join(case_dir, tfile)
    try:
        problems = ab.anchor_problems(meta, case_dir, ab.read_lines(src), ab.read_lines(tpath), tfile, regime)
    except RuntimeError as e:
        raise Unreliable(str(e))
    if problems:
        return Verdict('invalid-anchor', reason=problems[0])
    work = tempfile.mkdtemp(prefix='avv-')
    try:
        return judge(src, tpath, meta['source']['name'], meta['target']['name'], meta['target']['line'], regime, work)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main(argv):
    regimes = None
    cases = []
    it = iter(argv)
    for a in it:
        if a == '--regime':
            regimes = [next(it)]
        else:
            cases.append(a)
    if not cases:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    import yaml
    rc = 0
    for c in cases:
        meta = yaml.safe_load(open(os.path.join(c, 'case.yaml'), encoding='utf-8'))
        for r in regimes or meta['regimes']:
            try:
                v = judge_case(c, r)
                print(f'{c} {r} {v.line()}')
            except Unreliable as e:
                print(f'{c} {r} UNRELIABLE - {e}')
                rc = 2
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
