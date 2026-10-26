#!/usr/bin/env python3
"""anchor_driver - the anchor verifier of a product: every provenance anchor of the TARGET tree
checked against the pinned SOURCE, every comparable TARGET constant required to carry one, and
every anchored constant compared by value with its SOURCE constant in every precision build.

tools/conformance/verify-anchors.sh resolves the product root and the TARGET file set and runs this.
The anchor grammar, binding rules 1-3 and verdicts are those of the anchor-verifier corpus
(tools/conformance/seeded-bugs/verify-anchors/README.md), applied through lib/anchor_binding.py;
values are compared by lib/anchor_values.py.

1. Configuration (workbench): port/conventions/anchors.yaml - the precision regimes, the TARGET
   include directories and naming exceptions; port/declared-helpers.yaml - the runtime-helper
   files; the trap rows a runtime-helper anchor may cite (the pair table and the project
   conventions); the SOURCE pin (port/TRACE.yaml meta source_commit and source_root).
2. SOURCE: the pinned subtree extracted from the import commit (git archive), never the working
   tree. Per regime, each cited file and the files defining the modules it USEs are preprocessed
   and parsed with fparser, in parallel; their USE closure is compiled once (gfortran -c -J) and
   reaches the probes as a module directory and an archive.
3. TARGET: per regime and file, libclang's declarations (a product file a TARGET file includes
   that is not one itself - a `.inc` fragment - read inside each TARGET file that includes it);
   anchors read only in comments; each anchor bound by rules 1-3; each
   anchored entity paired with the SOURCE entity of its cited statement by the naming rule (SOURCE
   names kept, module-scoped names prefixed `<module>_`, case-insensitive; anchors.yaml `names`
   overrides it); the anchor rules checked; the pair judged by value (judge_many).
4. Coverage: every comparable TARGET constant carries a constant anchor (a context initializer may
   carry the module header anchor instead; a constant of a declared helper file, its own
   runtime-helper anchor).

Exit: 0 GREEN, 1 RED (a mismatch, a broken anchor rule, a missing anchor), 2 UNRELIABLE (something
could not be judged). A run-time value is reported UNVERIFIED: never RED, never a pass.

Usage: anchor_driver.py --workbench <dir> --product-root <dir> [--ref <git-ref>] [--verbose] (--scan | [--] <file>...)
(--scan: the TARGET files of the product root; --verbose lists every verified pair too.)
"""
import collections
import contextlib
import ctypes
import os
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import traceback
from concurrent.futures import ProcessPoolExecutor
from dataclasses import dataclass

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# the shared strict YAML reader of the tools (tools/coordination/_chisel_lib.py)
sys.path.insert(1, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'coordination'))
import anchor_binding as ab  # noqa: E402
import anchor_values as av  # noqa: E402

ANCHORS_YAML = 'port/conventions/anchors.yaml'
HELPERS_YAML = 'port/declared-helpers.yaml'
TRACE_YAML = 'port/TRACE.yaml'
PAIR_TABLE = '.opencode/skill/target-conventions/references/pairs/fortran-to-c.md'
PROJECT_CONVENTIONS = 'port/conventions/fortran-to-c.md'

# Modules the compiler supplies: a USE of one needs no SOURCE file.
INTRINSIC_MODULES = {'ISO_C_BINDING', 'ISO_FORTRAN_ENV', 'IEEE_ARITHMETIC', 'IEEE_EXCEPTIONS',
                     'IEEE_FEATURES', 'OMP_LIB', 'OMP_LIB_KINDS', 'OPENACC'}
FORTRAN_SUFFIXES = {'.f', '.for', '.ftn', '.f77', '.f90', '.f95', '.f03', '.f08'}
MODULE_LINE = re.compile(r'^[ \t]*module[ \t]+([a-z_]\w*)[ \t]*(?:!.*)?$', re.I | re.M)
HELPER_ANCHOR = re.compile(r'/\*\s*runtime-helper:\s*(?P<payload>.*?)\s*\*/')
REGIME_NAME = re.compile(r'[A-Za-z0-9_.-]+')

RED, UNRELIABLE, UNVERIFIED, PASS = 'RED', 'UNRELIABLE', 'UNVERIFIED', 'PASS'


class Fatal(RuntimeError):
    """The whole run cannot be judged: UNRELIABLE."""


# ==== configuration ===============================================================================

@dataclass
class Config:
    regimes: dict                  # name -> (source flags, target flags)
    include: list                  # TARGET include directories, absolute
    names: dict                    # lowercased TARGET name -> uppercased SOURCE name
    helpers: set                   # lowercased basenames of the declared helper files
    traps: object                  # trap row IDs a runtime-helper anchor may cite (None: no pair table)
    ref: str = ''
    sha: str = ''
    source_root: str = 'source'


def _yaml():
    try:
        import yaml
    except ImportError as e:
        raise Fatal(f'PyYAML is not importable ({e})')
    return yaml


def _chisel_lib():
    try:
        import _chisel_lib
    except ImportError as e:
        raise Fatal(f'the shared YAML reader tools/coordination/_chisel_lib.py is not importable ({e})')
    return _chisel_lib


def _load_yaml(path, what):
    """A workbench YAML file read as data through the strict loader the tools share
    (_chisel_lib.text_loader): a repeated key is an error, an alias reads as the value it names, and
    every scalar is text - a ref `0042` stays `0042`."""
    yaml = _yaml()
    loader = _chisel_lib().text_loader(yaml)
    try:
        with open(path, encoding='utf-8') as fh:
            return yaml.load(fh, Loader=loader)
    except (OSError, UnicodeDecodeError, yaml.YAMLError) as e:
        raise Fatal(f'{what} cannot be read: {str(e).splitlines()[0] if str(e) else type(e).__name__}')


def _meta_scalar(meta, key):
    """meta.<key> of port/TRACE.yaml as one line of text ('' when absent or null), as yaml_get reads
    a scalar: a mapping, a list, a value over several lines or a control character is refused."""
    v = meta.get(key)
    if v is None:
        return ''
    if not isinstance(v, str) or '\n' in v or '\r' in v or _chisel_lib().control_char(v) is not None:
        raise Fatal(f'{TRACE_YAML}: meta.{key} is not a single-line scalar')
    return v


def _strings(value, what):
    if not isinstance(value, list) or not all(isinstance(x, str) and x for x in value):
        raise Fatal(f'{ANCHORS_YAML} is malformed: {what} is not a list of strings')
    return list(value)


def load_anchors_yaml(wb, product_root):
    """(regimes, include directories, names) from port/conventions/anchors.yaml, or the defaults:
    one regime `default` with no extra flags, every product directory, no names."""
    path = os.path.join(wb, ANCHORS_YAML)
    data = _load_yaml(path, ANCHORS_YAML) if os.path.exists(path) else {}
    if not isinstance(data, dict):
        raise Fatal(f'{ANCHORS_YAML} is malformed: its top level is not a mapping')
    unknown = set(data) - {'regimes', 'include', 'names'}
    if unknown:
        raise Fatal(f'{ANCHORS_YAML} is malformed: unknown key(s) {", ".join(sorted(map(str, unknown)))}')
    regimes = {'default': ((), ())}
    if 'regimes' in data:
        raw = data['regimes']
        if not isinstance(raw, dict) or not raw:
            raise Fatal(f'{ANCHORS_YAML} is malformed: regimes is not a non-empty mapping')
        regimes = {}
        for name, spec in raw.items():
            if not isinstance(name, str) or not REGIME_NAME.fullmatch(name):
                raise Fatal(f'{ANCHORS_YAML} is malformed: regime name {name!r} is not [A-Za-z0-9_.-]+')
            spec = {} if spec is None else spec
            if not isinstance(spec, dict) or set(spec) - {'source_flags', 'target_flags'}:
                raise Fatal(f'{ANCHORS_YAML} is malformed: regime {name} holds keys other than source_flags and target_flags')
            regimes[name] = (tuple(_strings(spec.get('source_flags', []), f'regimes.{name}.source_flags')),
                             tuple(_strings(spec.get('target_flags', []), f'regimes.{name}.target_flags')))
    if 'include' in data:
        include = []
        for d in _strings(data['include'], 'include'):
            full = os.path.normpath(os.path.join(product_root, d))
            if os.path.isabs(d) or not (full + os.sep).startswith(os.path.normpath(product_root) + os.sep):
                raise Fatal(f'{ANCHORS_YAML} is malformed: include {d!r} is not a directory of the product')
            if not os.path.isdir(full):
                raise Fatal(f'{ANCHORS_YAML}: include directory {d} does not exist under the product root')
            include.append(full)
    else:
        include = product_dirs(product_root)
    names = {}
    if 'names' in data:
        raw = data['names']
        if not isinstance(raw, dict) or not all(isinstance(k, str) and isinstance(v, str) and ab.IDENT.fullmatch(k)
                                                and ab.IDENT.fullmatch(v) for k, v in raw.items()):
            raise Fatal(f'{ANCHORS_YAML} is malformed: names is not a mapping of TARGET names to SOURCE names')
        names = {k.lower(): v.upper() for k, v in raw.items()}
    return regimes, include, names


def product_dirs(root):
    """Every directory of the product tree (hidden directories and `tests/` subtrees left out)."""
    out = []
    if not os.path.isdir(root):
        return out
    for d, subdirs, _ in os.walk(root):
        subdirs[:] = sorted(s for s in subdirs if not s.startswith('.') and s != 'tests')
        out.append(os.path.abspath(d))
    return out


def load_helpers(wb):
    """The declared helper files: port/declared-helpers.yaml, a YAML list of basenames (also accepted
    under a `helpers:` key)."""
    path = os.path.join(wb, HELPERS_YAML)
    if not os.path.exists(path):
        return set()
    data = _load_yaml(path, HELPERS_YAML)
    if isinstance(data, dict) and set(data) == {'helpers'}:
        data = data['helpers']
    if data is None:
        return set()
    if not isinstance(data, list) or not all(isinstance(x, str) and x and '/' not in x for x in data):
        raise Fatal(f'{HELPERS_YAML} is malformed: it is not a list of file basenames')
    return {x.lower() for x in data}


def load_traps(wb):
    """The trap rows a runtime-helper anchor may cite: the pair table's T rows, the project
    conventions' T and P rows. None when the pair table is missing."""
    table = os.path.join(wb, PAIR_TABLE)
    if not os.path.exists(table):
        return None
    traps = set()
    for path, pat in ((table, r'\|\s*(T[0-9]+)\s*\|'), (os.path.join(wb, PROJECT_CONVENTIONS), r'\|\s*([TP][0-9]+)\s*\|')):
        if os.path.exists(path):
            with open(path, encoding='utf-8', errors='replace') as fh:
                traps |= set(re.findall(pat, fh.read()))
    return traps


INCLUDE_OPTIONS = ('-isystem', '-iquote', '-idirafter', '-I')


def include_flags(flags, base, refused, regime):
    """Regime flags with their include directories made absolute: a relative one is relative to
    `base` - the pinned SOURCE root (extracted) for source_flags, the product root for target_flags -
    since every compiler run has its own working directory. An absolute SOURCE include directory in
    the workbench's working SOURCE tree (`refused`) would read files other than the pinned ones."""
    out, it = [], iter(flags)
    for f in it:
        opt = next((o for o in INCLUDE_OPTIONS if f.startswith(o)), None)
        if opt is None:
            out.append(f)
            continue
        d = f[len(opt):] or next(it, '')
        if not os.path.isabs(d):
            d = os.path.normpath(os.path.join(base, d))
        elif refused and (os.path.realpath(d) + os.sep).startswith(refused + os.sep):
            raise Fatal(f'{ANCHORS_YAML}: regime {regime} includes {d}, in the working SOURCE tree, not the pinned '
                        f'SOURCE: give it relative to the SOURCE root ({os.path.relpath(d, refused)})')
        out.append(opt + d)
    return tuple(out)


def git(wb, *args):
    return subprocess.run(['git', '-C', wb] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def load_pin(wb, ref):
    """(ref, commit, SOURCE root): the in-repo import commit holding the pinned SOURCE, from
    port/TRACE.yaml meta source_commit and source_root (overridden by --ref or SOURCE_PIN_REF, and
    SOURCE_SUBDIR)."""
    meta = {}
    trace = os.path.join(wb, TRACE_YAML)
    if os.path.exists(trace):
        data = _load_yaml(trace, TRACE_YAML)
        if data is not None and not isinstance(data, dict):
            raise Fatal(f'{TRACE_YAML}: its top level is not a mapping')
        meta = (data or {}).get('meta')
        if meta is None:
            meta = {}
        elif not isinstance(meta, dict):
            raise Fatal(f'{TRACE_YAML}: meta is not a mapping')
    ref = ref or os.environ.get('SOURCE_PIN_REF') or _meta_scalar(meta, 'source_commit')
    root = (os.environ.get('SOURCE_SUBDIR') or _meta_scalar(meta, 'source_root') or 'source').strip().rstrip('/') or '.'
    if not ref:
        raise Fatal('no SOURCE pin: set port/TRACE.yaml meta source_commit (or SOURCE_PIN_REF / --ref) to the '
                    'local import commit of the SOURCE')
    p = git(wb, 'rev-parse', '--verify', f'{ref}^{{commit}}')
    if p.returncode != 0:
        said = ' '.join(p.stderr.decode(errors='replace').split())
        raise Fatal(f"SOURCE pin ref '{ref}' does not resolve in this repo (git: {said}). Set port/TRACE.yaml meta source_commit "
                    f'(or SOURCE_PIN_REF / --ref) to the LOCAL import commit that introduced the SOURCE (normally '
                    f'the oldest commit touching it: git log --reverse --format=%H -- {root} | head -1); the '
                    f'upstream commit is provenance only and is not an object here')
    return ref, p.stdout.decode().strip(), root


def extract_source(wb, sha, root, dest):
    """The SOURCE subtree at the pinned commit, extracted under dest; returns its directory."""
    tar = os.path.join(dest, 'source.tar')
    p = git(wb, 'archive', '--format=tar', '-o', tar, sha, '--', root)
    if p.returncode != 0:
        raise Fatal(f'git archive of {root} at {sha[:12]} failed: {p.stderr.decode(errors="replace").strip()}')
    out = os.path.join(dest, 'pin')
    os.makedirs(out)
    try:
        with tarfile.open(tar) as tf:
            tf.extractall(out, filter='data')
    except (tarfile.TarError, OSError) as e:
        raise Fatal(f'the SOURCE at the pin {sha[:12]} cannot be extracted: {e} - a link out of the SOURCE tree, or a '
                    f'path the extraction refuses, is never followed')
    top = os.path.join(out, root)
    if not os.path.isdir(top):
        raise Fatal(f'the SOURCE root {root} does not exist at the pin {sha[:12]}')
    return top


# ==== SOURCE: one file in one regime, through fparser ============================================

def _up(x):
    return str(x).strip().upper()


def _base_names(node, F, utils):
    """The names of the objects a DATA object or an assignment's left-hand side designates."""
    if isinstance(node, F.Name):
        return [_up(node)]
    if isinstance(node, F.Data_Implied_Do):
        return [n for o in node.children[0].children for n in _base_names(o, F, utils)]
    for n in utils.walk(node, F.Name):
        return [_up(n)]
    return []


def _context(node, F):
    """(module, derived type, inside a procedure or main program) of a statement."""
    module, typ, proc = '', '', False
    p = node.parent
    while p is not None:
        if isinstance(p, F.Module) and not module:
            module = _up(p.children[0].children[1])
        elif isinstance(p, F.Derived_Type_Def) and not typ:
            typ = _up(p.children[0].children[1])
        elif isinstance(p, (F.Function_Subprogram, F.Subroutine_Subprogram, F.Main_Program)):
            proc = True
        p = p.parent
    return module, typ, proc


def _stmt_info(node, first, last, F, utils):
    kind, names = 'other', []
    if isinstance(node, F.Type_Declaration_Stmt):
        kind, names = 'decl', [_up(d.children[0]) for d in node.children[2].children]
    elif isinstance(node, F.Data_Component_Def_Stmt):
        kind, names = 'component', [_up(d.children[0]) for d in node.children[2].children]
    elif isinstance(node, F.Data_Stmt):
        kind = 'data'
        names = [n for s in utils.walk(node, F.Data_Stmt_Set) for o in s.children[0].children
                 for n in _base_names(o, F, utils)]
    elif isinstance(node, F.Parameter_Stmt):
        kind, names = 'param', [_up(d.children[0]) for d in utils.walk(node, F.Named_Constant_Def)]
    elif isinstance(node, (F.Assignment_Stmt, F.Pointer_Assignment_Stmt)):
        kind, names = 'assign', _base_names(node.children[0], F, utils)
    elif isinstance(node, F.Allocate_Stmt):
        kind, names = 'assign', [n for a in utils.walk(node, F.Allocation) for n in _base_names(a.children[0], F, utils)]
    elif isinstance(node, F.Derived_Type_Stmt):
        kind, names = 'type', [_up(node.items[1])]
    elif isinstance(node, F.Module_Stmt):
        kind, names = 'module', [_up(node.children[1])]
    module, typ, proc = _context(node, F)
    # a value the SOURCE gives at compile time: a constant, an initializer, DATA, a component default
    value = kind in ('param', 'data') or (kind in ('decl', 'component') and (
        any(str(a).strip().upper() == 'PARAMETER' for a in (node.children[1].children if node.children[1] else ()))
        or any(d.children[3] is not None for d in node.children[2].children)))
    return {'first': first, 'last': last, 'kind': kind, 'names': list(dict.fromkeys(names)),
            'module': module, 'type': typ, 'proc': proc, 'value': value}


def index_source(path, flags, lines):
    """What the verifier needs of one SOURCE file in one regime: the modules it defines (with the
    line of their MODULE statement), the modules it USEs, its derived types, and the statement(s)
    holding each of `lines`. A file that cannot be preprocessed or parsed gives {'error': ...}."""
    try:
        text, origin = av.preprocess_mapped(path, flags)
        tree = av.parse_fortran(text)
        _, _, F, utils = av._fparser()
    except av.Unreliable as e:
        return {'error': str(e)}
    except Exception as e:  # noqa: BLE001 - anything else is just as unjudgeable
        return {'error': f'{type(e).__name__}: {e}'}
    try:
        stmts = []
        for node in utils.walk(tree):
            if not isinstance(node, utils.StmtBase) or getattr(node, 'item', None) is None:
                continue
            p = node.parent
            while p is not None and not isinstance(p, utils.StmtBase):
                p = p.parent
            if p is not None:
                continue  # the action statement of an IF statement belongs to it
            span = av.statement_lines(node, origin, path)
            if span:
                stmts.append((span[0], span[1], node))
        modules, types, uses, decls = {}, {}, set(), []
        for first, last, node in stmts:
            if isinstance(node, F.Module_Stmt):
                modules[_up(node.children[1])] = first
            elif isinstance(node, F.Derived_Type_Stmt):
                types[_up(node.items[1])] = (_context(node, F)[0], first)
            if isinstance(node, (F.Type_Declaration_Stmt, F.Parameter_Stmt, F.Derived_Type_Stmt, F.Module_Stmt)):
                si = _stmt_info(node, first, last, F, utils)
                kind = {'decl': 'entity', 'param': 'entity'}.get(si['kind'], si['kind'])
                decls += [{'kind': kind, 'name': x, 'module': si['module'], 'line': first} for x in si['names']]
        for node in utils.walk(tree, F.Use_Stmt):
            if node.items[0] is not None and _up(node.items[0]) == 'INTRINSIC':
                continue
            uses.add(_up(node.items[2]))
        at = {}
        for n in lines:
            at[n] = [_stmt_info(node, a, b, F, utils) for a, b, node in stmts if a <= n <= b]
        from fparser.two import Fortran2008
        units = sum(1 for _ in utils.walk(tree, (F.Module, F.Main_Program, F.Subroutine_Subprogram,
                                                 F.Function_Subprogram, F.Block_Data, Fortran2008.Submodule)))
        return {'error': '', 'modules': modules, 'types': types, 'uses': sorted(uses), 'at': at, 'decls': decls,
                'units': units}
    except Exception as e:  # noqa: BLE001
        return {'error': f'reading the parse tree failed: {type(e).__name__}: {e}'}


def module_candidates(top):
    """{MODULE: [files]}: the SOURCE files whose text has a `MODULE <name>` line (fparser confirms)."""
    out = collections.defaultdict(list)
    for d, subdirs, files in os.walk(top):
        subdirs.sort()
        for f in sorted(files):
            if os.path.splitext(f)[1].lower() not in FORTRAN_SUFFIXES:
                continue
            path = os.path.join(d, f)
            with open(path, encoding='utf-8', errors='replace') as fh:
                text = fh.read()
            if ab.fixed_form(path):
                text = '\n'.join(ab.fixed_code(ln) for ln in text.split('\n'))
            for m in MODULE_LINE.finditer(text):
                if path not in out[m.group(1).upper()]:
                    out[m.group(1).upper()].append(path)
    return out


def compile_closure(flags, files, deps, show, work):
    """The modules of `files` (in dependency order) compiled once: {'moddir', 'archive', 'failed':
    {file: (the file that does not compile, why)}}. A file whose dependency failed is not compiled;
    it carries its dependency's cause."""
    moddir, objdir = os.path.join(work, 'mod'), os.path.join(work, 'obj')
    os.makedirs(moddir)
    os.makedirs(objdir)
    failed, objs = {}, []
    for k, f in enumerate(files):
        bad = [g for g in deps[f] if g in failed]
        if bad:
            failed[f] = failed[bad[0]]
            continue
        try:
            objs.append(av.compile_source(f, flags, os.path.join(objdir, f'{k}.o'), objdir, moddir))
        except av.Unreliable as e:
            failed[f] = (f, str(e))
    archive = None
    if objs:
        archive = os.path.join(work, 'libsource.a')
        p = subprocess.run(['ar', 'rcs', archive] + objs, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if p.returncode != 0:
            reason = 'ar failed: ' + p.stdout.decode(errors='replace').strip()
            return {'moddir': moddir, 'archive': None, 'failed': {f: (objs[0], reason) for f in files}}
    return {'moddir': moddir, 'archive': archive, 'failed': failed}


# ==== TARGET: one file in one regime, through libclang ===========================================

@dataclass
class TFile:
    path: str
    show: str
    lines: list
    helper: bool
    comments: list = None  # the lines with everything outside a comment blanked: where anchors are
    unit: dict = None  # for a fragment read inside a file including it: {regime: that file}
    within: str = ''  # that file, as shown

    @property
    def key(self):
        return (self.path, self.within)


@dataclass
class Outcome:
    """One verdict of one regime: an anchored entity, a statement anchor or an anchor rule; `within`,
    the file a fragment was read inside."""
    tag: str
    show: str
    line: int
    name: str
    text: str
    within: str = ''


@dataclass
class Job:
    """An anchored pair handed to judge_many, with what its verdict is reported against."""
    pair: object
    show: str
    line: int
    name: str
    sshow: str
    within: str = ''


def _reserved(name):
    return re.match(r'_[A-Z_]', name) is not None


def _numeric_literal(tok, ci):
    s = tok.spelling
    return tok.kind == ci.TokenKind.LITERAL and (s[:1].isdigit() or (s[:1] == '.' and s[1:2].isdigit()))


def _const(t):
    while t.get_canonical().kind in (t.kind.CONSTANTARRAY, t.kind.INCOMPLETEARRAY):
        t = t.get_canonical().element_type
    return t.is_const_qualified()


def _leaf_kinds(t, ci, out):
    """The kinds of the leaves of a TARGET type: 'number' (an arithmetic type or bool, plain char
    aside), 'pointer', or 'other'."""
    K = ci.TypeKind
    ct = t.get_canonical()
    if ct.kind in (K.CONSTANTARRAY, K.INCOMPLETEARRAY):
        return _leaf_kinds(ct.element_type, ci, out)
    if ct.kind == K.RECORD:
        for f in ct.get_fields():
            _leaf_kinds(f.type, ci, out)
        return out
    if ct.kind == K.POINTER:
        out.add('pointer')
    elif ct.kind in (K.BOOL, K.SCHAR, K.UCHAR, K.SHORT, K.USHORT, K.INT, K.UINT, K.LONG, K.ULONG, K.LONGLONG,
                     K.ULONGLONG, K.ENUM, K.FLOAT, K.DOUBLE, K.LONGDOUBLE, K.COMPLEX):
        out.add('number')
    else:
        out.add('other')
    return out


def numeric_object(t, ci):
    """Whether an object of type t holds numbers to compare: every leaf a number or bool - a pointer
    only as a member of an aggregate - and at least one number. A pointer object, a string or a
    table of function pointers is not one."""
    kinds = _leaf_kinds(t, ci, set())
    return t.get_canonical().kind != ci.TypeKind.POINTER and 'number' in kinds and kinds <= {'number', 'pointer'}


def comparable(c, ci):
    """Whether a TARGET declaration is a constant the coverage rule requires an anchor for."""
    K = ci.CursorKind
    if c.kind == K.VAR_DECL:
        init = av.initializer(c)
        if init is None or not numeric_object(c.type, ci):
            return False
        parent = c.semantic_parent
        if parent is None or parent.kind == K.TRANSLATION_UNIT:
            return True
        return ((_const(c.type) or c.storage_class == ci.StorageClass.STATIC)
                and any(_numeric_literal(t, ci) for t in init.get_tokens()))
    if c.kind == K.ENUM_CONSTANT_DECL:
        return any(ch.kind.is_expression() for ch in c.get_children())
    if c.kind == K.MACRO_DEFINITION:
        body = macro_body(c, ci)
        return bool(body) and (body[0].spelling == '{' or any(_numeric_literal(t, ci) for t in body))
    return False


def macro_body(c, ci):
    """The replacement tokens of an object-like macro of the product, or None (a function-like
    macro, or a reserved name such as a feature-test macro)."""
    f = ci.conf.lib.clang_Cursor_isMacroFunctionLike
    f.restype, f.argtypes = ctypes.c_uint, [ci.Cursor]
    if _reserved(c.spelling) or f(c):
        return None
    return [t for t in c.get_tokens() if t.kind != ci.TokenKind.COMMENT][1:]


BOOL_WORDS = ('true', 'false')


def product_valued(tu, product, ci):
    """A test of whether an object-like macro of the product takes its value from the product: its body
    names a bool (`true`, `false` - like the literals 1 and 0), an enumerator or object a product
    file declares, or another product macro that does. One whose body names only C-library macros,
    keywords or sizeof (EXIT_SUCCESS, DBL_EPSILON, CHAR_BIT, sizeof(double)) aliases the library,
    not a SOURCE constant."""
    K = ci.CursorKind
    root = os.path.realpath(product) + os.sep
    macros, declared = {}, set()
    for c in tu.cursor.walk_preorder():
        f = c.location.file
        if f is None or not os.path.realpath(f.name).startswith(root):
            continue
        if c.kind == K.MACRO_DEFINITION:
            macros[c.spelling] = c
        elif c.kind in (K.VAR_DECL, K.ENUM_CONSTANT_DECL):
            declared.add(c.spelling)
    memo = {}

    def valued(name, stack=()):
        if name in memo:
            return memo[name]
        c = macros.get(name)
        body = macro_body(c, ci) if c is not None and name not in stack else None
        hit = bool(body) and any(t.kind == ci.TokenKind.IDENTIFIER and (
            t.spelling in BOOL_WORDS or t.spelling in declared or valued(t.spelling, stack + (name,))) for t in body)
        memo[name] = hit
        return hit
    return valued


def evaluated_macros(path, macros, cflags, ci):
    """The object-like macros of `macros` clang evaluates to a constant number or bool though no
    literal is in their body (`#define LDEBUG false`, `#define NC (NB + NLEV)`): each initializes a
    file-scope constant of a holder that includes the file; one whose line has no error and whose
    type is a number or bool is such a constant."""
    if not macros:
        return set()
    name = path + '.chisel-macros.c'
    text = f'#include "{path}"\n' + ''.join(f'static const __auto_type chisel_macro_{k} = ({m.spelling});\n'
                                             for k, m in enumerate(macros))
    tu = ci.Index.create().parse(name, args=['-x', 'c', '-std=c17'] + ab._resource_args() + list(cflags),
                                 unsaved_files=[(name, text)])
    bad = {d.location.line for d in tu.diagnostics if d.severity >= ci.Diagnostic.Error and d.location.file
           and d.location.file.name == name}
    held = {c.spelling: c for c in tu.cursor.get_children() if c.kind == ci.CursorKind.VAR_DECL
            and c.spelling.startswith('chisel_macro_')}
    out = set()
    for k, m in enumerate(macros):
        c = held.get(f'chisel_macro_{k}')
        if c is not None and k + 2 not in bad and _leaf_kinds(c.type, ci, set()) == {'number'}:
            out.add(ab.decl_extent(m))
    return out


class Sources:
    """The pinned SOURCE files' lines, read once."""

    def __init__(self, top):
        self.top, self.cache = top, {}

    def resolve(self, path):
        """The extracted file an anchor path names, or (None, reason)."""
        norm = os.path.normpath(path)
        if os.path.isabs(norm) or norm == '..' or norm.startswith('..' + os.sep):
            return None, 'outside the SOURCE root'
        full = os.path.join(self.top, norm)
        return (full, '') if os.path.isfile(full) else (None, 'absent from the pinned SOURCE')

    def lines(self, full):
        if full not in self.cache:
            with open(full, encoding='utf-8', errors='replace') as fh:
                lines = fh.read().split('\n')
            if lines and lines[-1] == '':
                lines.pop()
            self.cache[full] = lines
        return self.cache[full]


def _rest(m):
    return m.group('rest').strip()


def anchor_form(m):
    rest = _rest(m)
    if rest.startswith('= ') and rest[2:].strip():
        return 'constant'
    if re.fullmatch(r'\(module\s+([A-Za-z_]\w*)\)', rest, re.I):
        return 'module'
    return 'routine' if not rest else 'other'


def standalone_problems(i, m, src, show, sha):
    """The rules an anchor bound to no constant breaks: it cites an existing line; a module header
    anchor cites that MODULE statement; a constant anchor (on a statement) quotes the cited line;
    nothing else is an anchor form."""
    full = m.group(0)
    path, n, form = m.group('path'), int(m.group('line')), anchor_form(m)
    if form == 'other':
        return [f'{show}:{i}: {full} matches none of the anchor forms (constant, module header, routine)']
    spath, why = src.resolve(path)
    if spath is None:
        return [f'{show}:{i}: {full} cites {path}, {why} ({sha[:12]})']
    slines = src.lines(spath)
    if not 1 <= n <= len(slines):
        return [f'{show}:{i}: {full} cites line {n}, past the end of {path} ({len(slines)} lines)']
    if form == 'module':
        name = re.fullmatch(r'\(module\s+([A-Za-z_]\w*)\)', _rest(m), re.I).group(1).upper()
        if ab.source_scope(slines, n, ab.fixed_form(path))[1] != name:
            return [f'{show}:{i}: {full} does not cite the MODULE statement of {name}']
    if form == 'constant':
        return ab.bound_problems([(i, m)], [], path, slines, n, '', show)
    return []


def no_unit(path):
    return (f'{path} holds no program unit (an INCLUDE file?): its statements are read only through the '
            f'file that INCLUDEs them, which the verifier does not follow - a constant it declares cannot be '
            f'judged')


def statement_anchor(i, m, sindex, src, show, regime):
    """A constant anchor on a statement: a run-time value (UNVERIFIED) when it cites what the SOURCE
    sets at run time; when it cites a value the SOURCE gives at compile time, a SOURCE constant
    rendered as a literal in a statement - not as the declared TARGET constant the naming rule asks
    for, and so never compared: RED."""
    path, n = m.group('path'), int(m.group('line'))
    idx = sindex.get(src.resolve(path)[0])
    if idx is None or idx['error']:
        return Outcome(UNRELIABLE, show, i, '', f'SOURCE {path} cannot be read in regime {regime}: '
                       f'{idx["error"] if idx else "not indexed"}')
    if not idx['units']:
        return Outcome(UNRELIABLE, show, i, '', no_unit(path))
    infos = idx['at'].get(n, [])
    if len(infos) == 1 and infos[0]['value']:
        return Outcome(RED, show, i, '', f'invalid-anchor - {show}:{i}: {m.group(0)} is on a statement but cites '
                       f'{", ".join(infos[0]["names"])}, a value the SOURCE gives at compile time: render a SOURCE '
                       f'constant as a declared TARGET constant, whose value is compared')
    return Outcome(UNVERIFIED, show, i, '', 'not-comparable - the anchor is on a statement, not on a declared '
                   'constant: a run-time value')


def own_problems(anchors, unclosed, src, name, show, sha):
    """The anchor rules the anchors of an entity break whatever SOURCE entity it renders: each cites
    an existing file and line, is a constant (or module header) anchor quoting its own cited line,
    is written once and closes on its line."""
    out = [f'{show}:{i}: an anchor opens without closing on its line' for i in unclosed]
    seen = set()
    for i, m in anchors:
        full = m.group(0)
        if (i, full) in seen:
            out.append(f'{show}:{i}: {full} is written twice')
        seen.add((i, full))
        spath, why = src.resolve(m.group('path'))
        if spath is None:
            out.append(f'{show}:{i}: {full} cites {m.group("path")}, {why} ({sha[:12]})')
        elif anchor_form(m) in ('routine', 'other'):
            out.append(f'{show}:{i}: {full} is not the constant grammar')
        else:
            out += ab.bound_problems([(i, m)], [], m.group('path'), src.lines(spath), int(m.group('line')), name, show)
    return out


def accepted(kind, sname, module):
    """The TARGET names the naming rule gives a SOURCE entity, lowercased: its name, or
    `<module>_<name>`; a type's default initialization `<TYPE>_INIT`; a module's context
    initializer `<MODULE>_CTX_INIT`, or the module's name for a struct object of its variables."""
    s, m = sname.lower(), module.lower()
    if kind == 'module':
        return {s + '_ctx_init', s}
    if kind == 'type':
        return {s + '_init'} | ({f'{m}_{s}_init'} if m else set())
    return {s} | ({f'{m}_{s}'} if m else set())


VERB = {'decl': 'declares', 'param': 'declares', 'component': 'declares', 'type': 'declares',
        'module': 'declares', 'data': 'initializes', 'assign': 'sets'}


def declared_elsewhere(name, want, anchors, sindex, src, show):
    """When the TARGET name maps - by `names` (`want`) or by the naming rule - to an entity a cited
    file declares, but not in the statement its anchor cites: why the anchor is invalid."""
    for i, m in anchors:
        if anchor_form(m) != 'constant':
            continue
        path, n = m.group('path'), int(m.group('line'))
        idx = sindex.get(src.resolve(path)[0])
        if not idx or idx['error']:
            continue
        hits = [e for e in idx['decls'] if (e['name'] == want if want else name.lower() in accepted(e['kind'], e['name'], e['module']))]
        if not hits:
            continue
        infos = idx['at'].get(n, [])
        stmt = ('holds no statement' if not infos else
                f'{VERB.get(infos[0]["kind"], "declares")} {", ".join(infos[0]["names"]) or "nothing the verifier pairs"}')
        lines = sorted({e['line'] for e in hits})
        what = ', '.join(sorted({e['name'] for e in hits}))
        return (f'invalid-anchor - {show}:{i}: {m.group(0)} cites line {n}, which {stmt}; {what} is declared at '
                f'line{"s" if len(lines) > 1 else ""} {", ".join(map(str, lines))}')
    return ''


def pair_entity(name, anchors, sindex, src, names, regime, show):
    """The SOURCE entity a TARGET entity renders, from the statements its anchors cite: (candidate,
    '', '') - a dict of kind (entity, type, module), the path as cited, the extracted file, the
    SOURCE name and module, the line of its statement, and whether that statement is an assignment
    - or (None, RED or UNRELIABLE, why). The name mapping to an entity of a cited file declared by
    another statement is RED; to none at all, UNRELIABLE. A fourth value is True for that last case,
    where the entity may be a temporary of a constant that does pair."""
    cands, empty = {}, []

    def add(kind, path, full, sname, module, line, assign=False):
        key = (kind, full, sname, module)
        if key not in cands:
            cands[key] = {'kind': kind, 'path': path, 'full': full, 'sname': sname, 'module': module,
                          'line': line, 'accepted': accepted(kind, sname, module), 'assign': assign}
        else:
            cands[key]['assign'] = cands[key]['assign'] and assign

    for i, m in anchors:
        path, n, form = m.group('path'), int(m.group('line')), anchor_form(m)
        full, _ = src.resolve(path)
        idx = sindex.get(full)
        if idx is None:
            continue
        if idx['error']:
            return None, UNRELIABLE, f'SOURCE {path} cannot be read in regime {regime}: {idx["error"]}', False
        if not idx['units']:
            return None, UNRELIABLE, no_unit(path), False
        infos = idx['at'].get(n, [])
        if len(infos) > 1:
            return None, UNRELIABLE, f'{path}:{n} holds more than one statement: the anchor cannot bind to one', False
        if not infos:
            empty.append(f'{path}:{n}')
        for si in infos:
            mod, kind = si['module'], si['kind']
            if form == 'module':
                if kind == 'module':
                    add('module', path, full, si['names'][0], si['names'][0], si['first'])
            elif kind in ('decl', 'data', 'param', 'assign'):
                for x in si['names']:
                    add('entity', path, full, x, mod, si['first'], kind == 'assign')
                if kind in ('decl', 'data') and mod and not si['proc']:
                    add('module', path, full, mod, mod, idx['modules'].get(mod, 0))
            elif kind == 'component':
                add('type', path, full, si['type'], mod, idx['types'].get(si['type'], ('', 0))[1])
            elif kind == 'type':
                add('type', path, full, si['names'][0], mod, si['first'])
            elif kind == 'module':
                add('module', path, full, si['names'][0], si['names'][0], si['first'])
    found = list(cands.values())
    declared = ', '.join(sorted({c['sname'] for c in found})) or 'nothing the verifier pairs'
    if empty and not found:
        declared += f'; {", ".join(empty)} holds no statement in regime {regime}'
    want = names.get(name.lower(), '')
    hits = [c for c in found if (c['sname'] == want if want else name.lower() in c['accepted'])]
    if not hits:
        elsewhere = declared_elsewhere(name, want, anchors, sindex, src, show)
        if elsewhere:
            return None, RED, elsewhere, False
        if want:
            return None, UNRELIABLE, (f'{ANCHORS_YAML} pairs {name} with {want}, which no cited SOURCE file '
                                      f'declares (the cited statement(s) declare {declared})'), False
        return None, UNRELIABLE, (f'no SOURCE entity of the cited statement(s) is named {name} by the naming '
                                  f'rule (they declare {declared}); pair it in {ANCHORS_YAML} names'), True
    if len(hits) > 1:
        return None, UNRELIABLE, (f'{name} pairs with more than one SOURCE entity: '
                                  + ', '.join(f'{c["kind"]} {c["sname"]}' for c in hits)), False
    return hits[0], '', '', False


def bind_file(tf, regime, cflags, names, top, sindex, sha, product='', scanned=None, judged=frozenset()):
    """The anchors of one TARGET file in one regime: (outcomes, jobs, constant anchors bound to
    nothing - {line: None, or the branch this build skips it in, 'never' or 'unbuilt'} -, whether clang could read the file, temporaries). `sindex` is the index of every SOURCE
    file the file cites, in this regime. A temporary is (its line, its name, the line and name of
    the constant it is a temporary of), whose verdict it takes."""
    try:
        return _bind_file(tf, regime, cflags, names, top, sindex, sha, product, scanned, judged)
    except Exception as e:  # noqa: BLE001 - fail closed on anything unforeseen
        return ([Outcome(UNRELIABLE, tf.show, 0, '', f'the verifier failed on this file: {type(e).__name__}: {e}')],
                [], {}, False, [])


def _bind_file(tf, regime, cflags, names, top, sindex, sha, product, scanned, judged):
    import clang.cindex as ci
    src = Sources(top)
    out, jobs = [], []
    # a fragment is read inside the TARGET file that includes it; in a regime where none does, it
    # is not built
    unit = tf.path if tf.unit is None else tf.unit.get(regime)
    if unit is None:
        return [], [], {}, False, []
    try:
        tu = ab.parse_declarations(unit, ab.Regime(regime, cflags=tuple(cflags)))
    except RuntimeError as e:
        inside = '' if unit == tf.path else f' (read inside {os.path.basename(unit)}, which includes it)'
        return [Outcome(UNRELIABLE, tf.show, 0, '', f'{e}{inside} - its anchors and coverage cannot be judged')], \
            [], {}, False, []
    if unit == tf.path:
        out += unread_includes(tu, tf, product, scanned, judged)
    cursors = ab.decl_cursors(tu, tf.path)
    decls = [ab.decl_extent(c) for c in cursors]
    kind = {ab.decl_extent(c): c.kind for c in cursors}
    needs = {ab.decl_extent(c) for c in cursors if comparable(c, ci)}
    valued = product_valued(tu, product or os.path.dirname(tf.path), ci)
    needs |= evaluated_macros(unit, [c for c in cursors if c.kind == ci.CursorKind.MACRO_DEFINITION
                                     and ab.decl_extent(c) not in needs and valued(c.spelling)], cflags, ci)
    # in a declared helper file, a runtime-helper anchor covers the declaration it binds to
    helped = {ab.bind(decls, tf.lines, i, h.start() + 1) for i, ln in enumerate(tf.comments, 1) for h in HELPER_ANCHOR.finditer(ln)} \
        if tf.helper else set()
    found, opened = ab.anchors_in(tf.comments)
    bound, unclosed, orphans = collections.defaultdict(list), collections.defaultdict(list), {}
    skipped = skipped_lines(tu, tf.path, ci, tf.lines)
    paired, unnamed = {}, []
    for i, m in found:
        d = ab.bind(decls, tf.lines, i, m.start() + 1,
                    lambda d, i=i, m=m: pair_entity(d[0], [(i, m)], sindex, src, names, regime, tf.show)[0] is not None)
        if d is not None and kind[d] != ci.CursorKind.FUNCTION_DECL:
            bound[d].append((i, m))
        elif d is None and anchor_form(m) == 'constant':
            orphans[i] = skipped.get(i)  # RED unless it binds in another regime
        else:
            problems = standalone_problems(i, m, src, tf.show, sha)
            if problems:
                out.append(Outcome(RED, tf.show, i, '', 'invalid-anchor - ' + problems[0]))
            elif anchor_form(m) == 'constant':
                out.append(statement_anchor(i, m, sindex, src, tf.show, regime))
    for i in opened:
        d = ab.bind(decls, tf.lines, i)
        if d is not None and kind[d] != ci.CursorKind.FUNCTION_DECL:
            unclosed[d].append(i)
        else:
            out.append(Outcome(RED, tf.show, i, '', f'invalid-anchor - {tf.show}:{i}: an anchor opens without '
                               f'closing on its line'))
    for d in sorted(set(bound) | set(unclosed) | needs, key=lambda d: (d[2], d[0])):
        name, line = d[0], d[2]
        anchors = bound.get(d, [])
        if not anchors and not unclosed.get(d):
            if d not in helped:
                out.append(Outcome(RED, tf.show, line, name, f'coverage - no anchor binds to {name}: every comparable '
                                   f'TARGET constant carries a constant anchor'
                                   + (' or, in a declared helper file, a runtime-helper anchor' if tf.helper else '')))
            continue
        if d not in needs and not unclosed.get(d) and all(anchor_form(m) in ('routine', 'module') for _, m in anchors):
            for i, m in anchors:  # a routine or module anchor on a declaration that is not a constant
                problems = standalone_problems(i, m, src, tf.show, sha)
                if problems:
                    out.append(Outcome(RED, tf.show, i, name, 'invalid-anchor - ' + problems[0]))
            continue
        problems = own_problems(anchors, unclosed.get(d, []), src, name, tf.show, sha)
        if not problems and not anchors:
            problems = [f'no anchor binds to {name}']
        if problems:
            out.append(Outcome(RED, tf.show, line, name, 'invalid-anchor - ' + problems[0]))
            continue
        cand, tag, why, maybe_temporary = pair_entity(name, anchors, sindex, src, names, regime, tf.show)
        if maybe_temporary:
            unnamed.append((d, anchors, why))
            continue
        if cand is None:
            out.append(Outcome(tag, tf.show, line, name, why))
            continue
        if cand['kind'] == 'entity':
            paired[d] = (cand['full'], cand['line'])
        problems = ab.bound_problems(anchors, [], cand['path'], src.lines(cand['full']), cand['line'], name, tf.show)
        if problems:
            out.append(Outcome(RED, tf.show, line, name, 'invalid-anchor - ' + problems[0]))
            continue
        sshow = f'{cand["path"]}:{cand["line"]} {cand["sname"]}'
        if cand['assign']:
            out.append(Outcome(UNVERIFIED, tf.show, line, name, f'not-comparable - {sshow} is set by an executable '
                               f'statement (an assignment or allocation), at run time'))
            continue
        jobs.append(Job(av.Pair(cand['full'], cand['sname'], tf.path, name, line, cand['module'], cand['line'],
                                '' if unit == tf.path else unit),
                        tf.show, line, name, sshow, tf.within))
    temps = []
    refs = {ab.decl_extent(c): _refs(c, ci, tf.path) for c in cursors
            if c.kind in (ci.CursorKind.VAR_DECL, ci.CursorKind.ENUM_CONSTANT_DECL)}
    by_extent = {ab.decl_extent(c): c for c in cursors}
    for d, anchors, why in unnamed:
        keys = cited_statements(anchors, sindex, src)
        owners = [p for p in sorted(paired, key=lambda p: p[2]) if paired[p] in keys and d in _reach(p, refs)]
        owner = next((p for p in owners if moves(by_extent[d], p, tf, unit, regime, cflags, ci)), None)
        if owner is not None:
            temps.append((d[2], d[0], owner[2], owner[0]))
        elif owners:
            out.append(Outcome(UNRELIABLE, tf.show, d[2], d[0], f'{owners[0][0]} refers to {d[0]}, but its value does '
                               f'not change when {d[0]}\'s does: {d[0]} is not verified through it'))
        else:
            out.append(Outcome(UNRELIABLE, tf.show, d[2], d[0], why))
    return out, jobs, orphans, True, temps


class _RangeList(ctypes.Structure):
    _fields_ = [('count', ctypes.c_uint), ('ranges', ctypes.c_void_p)]


NEVER_BUILT = re.compile(r'\s*#\s*(?:el)?if\s*\(?\s*0+\s*\)?\s*(?://.*|/\*.*)?$')


def skipped_lines(tu, path, ci, lines):
    """{line: 'never' or 'unbuilt'}: the lines of the file the preprocessor skips in this build (an
    inactive #if branch) - 'never' in a branch opened by `#if 0` or `#elif 0`, which no build
    compiles. A skipped range starts at the directive opening its branch."""
    lib = ci.conf.lib
    get, dispose = lib.clang_getSkippedRanges, lib.clang_disposeSourceRangeList
    get.restype, get.argtypes = ctypes.POINTER(_RangeList), [ctypes.c_void_p, ctypes.c_void_p]
    dispose.restype, dispose.argtypes = None, [ctypes.POINTER(_RangeList)]
    f = tu.get_file(path)
    lst = get(tu.obj, f.obj)
    out = {}
    if not lst:
        return out
    try:
        ranges = ctypes.cast(lst.contents.ranges, ctypes.POINTER(ci.SourceRange))
        for k in range(lst.contents.count):
            a, b = ranges[k].start.line, ranges[k].end.line
            how = 'never' if 0 < a <= len(lines) and NEVER_BUILT.match(lines[a - 1]) else 'unbuilt'
            out.update({n: how for n in range(a, b + 1)})
    finally:
        dispose(lst)
    return out


def unread(real, product, scanned, targets):
    """Whether an included file is a product file the verifier does not read as a TARGET file: not a
    .c or .h file, or (from a scan) outside the scanned set."""
    root = os.path.realpath(product) + os.sep
    return real.startswith(root) and real not in targets and (
        os.path.splitext(real)[1].lower() not in ab.TARGET_SUFFIXES or (scanned is not None and real not in scanned))


def includes_of(path, cflags):
    """{regime: [real path of every file the TARGET file includes in that regime]} (none when clang
    cannot read it: binding reports that)."""
    out = {}
    for r, flags in cflags.items():
        try:
            tu = ab.parse_unit(path, ab.Regime(r, cflags=tuple(flags)))
            out[r] = sorted({os.path.realpath(inc.include.name) for inc in tu.get_includes()})
        except Exception:  # noqa: BLE001 - the file's binding reports why clang cannot read it
            out[r] = []
    return out


def fragments(pool, tfiles, cflags, product, scanned, cfg):
    """The product files the TARGET files include that the verifier does not read as TARGET files -
    a `.inc` fragment, a header under tests/ - as TARGET files read inside each TARGET file that
    includes them, one instance per including file, in each regime it includes them in: a fragment
    stamped into two units (`#define REAL double` in one, `float` in the other) is two renderings,
    each judged. ([fragment instances], [outcomes])."""
    targets = {os.path.realpath(tf.path) for tf in tfiles}
    units = {}
    futs = [(tf, pool.submit(includes_of, tf.path, cflags)) for tf in tfiles]
    for tf, fut in futs:
        for r, incs in fut.result().items():
            for real in incs:
                if unread(real, product, scanned, targets):
                    units.setdefault(real, {}).setdefault((tf.path, tf.show), {})[r] = tf.path
    out, glob = [], []
    for real, by in sorted(units.items()):
        show = os.path.relpath(real, os.path.realpath(product))
        try:
            with open(real, encoding='utf-8') as fh:
                lines = fh.read().split('\n')
        except (OSError, UnicodeDecodeError) as e:
            glob.append(Outcome(UNRELIABLE, show, 0, '', f'cannot be read ({e}): its anchors and coverage cannot be judged'))
            continue
        if lines and lines[-1] == '':
            lines.pop()
        for (_, within), unit in sorted(by.items()):
            out.append(TFile(real, show, lines, os.path.basename(real).lower() in cfg.helpers, unit=unit, within=within))
    return out, glob


def unread_includes(tu, tf, product, scanned, judged):
    """A product file the TARGET file includes that the verifier neither reads as a TARGET file nor
    as a fragment included by one has constants no one judges: UNRELIABLE."""
    out = []
    for inc in tu.get_includes():
        real = os.path.realpath(inc.include.name)
        if real not in judged and unread(real, product, scanned, judged):
            shown = os.path.relpath(real, os.path.realpath(product))
            out.append(Outcome(UNRELIABLE, tf.show, inc.location.line, '', f'{shown}, which it includes, is not read '
                               f'by the verifier: its constants are not judged'))
    return out


def _refs(c, ci, path):
    """The objects and enumerators of the file `path` a declaration's initializer refers to."""
    K = ci.CursorKind
    expr = av.initializer(c) if c.kind == K.VAR_DECL else next((x for x in c.get_children() if x.kind.is_expression()), None)
    out = set()
    for x in ([] if expr is None else expr.walk_preorder()):
        r = x.referenced if x.kind == K.DECL_REF_EXPR else None
        if r is not None and r.kind in (K.VAR_DECL, K.ENUM_CONSTANT_DECL) and r.location.file is not None \
                and os.path.realpath(r.location.file.name) == os.path.realpath(path):
            out.add(ab.decl_extent(r))
    return out


def _evaluated(c, ci):
    """The values clang's constant evaluator gives a declaration's initializer, leaf by leaf (None for
    a leaf it does not evaluate)."""
    if c.kind == ci.CursorKind.ENUM_CONSTANT_DECL:
        return [c.enum_value]
    out = []

    def leaves(e):
        if e.kind == ci.CursorKind.INIT_LIST_EXPR:
            for x in e.get_children():
                leaves(x)
        else:
            out.append(av._evaluate(e))
    init = av.initializer(c)
    if init is not None:
        leaves(init)
    return out


def moves(temp, owner, tf, unit, regime, cflags, ci):
    """Whether the value of the constant `owner` (a declaration extent) depends on the value of the
    temporary `temp` (a cursor): its initializer is changed - to 2*(E)+1, then to 2*(E)+3, so one of
    the two changes any value - and the owner evaluated again. A reference the owner's value does not
    depend on - an arm a constant condition never takes, the operand of sizeof - does not count."""
    K = ci.CursorKind
    expr = av.initializer(temp) if temp.kind == K.VAR_DECL else \
        next((x for x in temp.get_children() if x.kind.is_expression()), None)
    if expr is None or expr.extent.start.file is None \
            or os.path.realpath(expr.extent.start.file.name) != os.path.realpath(tf.path):
        return False
    a, b = expr.extent.start.offset, expr.extent.end.offset
    with open(tf.path, 'rb') as fh:
        data = fh.read()

    def owner_values(tu):
        hits = [c for c in ab.decl_cursors(tu, tf.path) if ab.decl_extent(c)[:3] == owner[:3]]
        return _evaluated(hits[0], ci) if len(hits) == 1 else None

    before = owner_values(ab.parse_unit(unit, ab.Regime(regime, cflags=tuple(cflags))))
    if not before or all(v is None for v in before):
        return False
    for k in (1, 3):
        text = (data[:a] + b'(2 * (' + data[a:b] + b') + ' + str(k).encode() + b')' + data[b:]).decode('utf-8')
        after = owner_values(ab.parse_unit(unit, ab.Regime(regime, cflags=tuple(cflags)),
                                           [(os.path.abspath(tf.path), text)]))
        if after is not None and after != before:
            return True
    return False


def _reach(d, refs):
    """Every declaration the initializer of `d` reaches through references, transitively."""
    seen, todo = set(), list(refs.get(d, ()))
    while todo:
        x = todo.pop()
        if x not in seen:
            seen.add(x)
            todo += refs.get(x, ())
    return seen


def cited_statements(anchors, sindex, src):
    """{(SOURCE file, first line)} of the statements the constant anchors cite."""
    out = set()
    for i, m in anchors:
        idx = sindex.get(src.resolve(m.group('path'))[0])
        infos = idx['at'].get(int(m.group('line')), []) if idx and not idx['error'] else []
        if anchor_form(m) == 'constant' and len(infos) == 1:
            out.add((src.resolve(m.group('path'))[0], infos[0]['first']))
    return out


def judge_group(jobs, regime, work, unavailable):
    """The verdicts of the pairs of one SOURCE file in one regime, as outcomes."""
    out = _judge_group(jobs, regime, work, unavailable)
    for o, j in zip(out, jobs):
        o.within = j.within
    return out


def _judge_group(jobs, regime, work, unavailable):
    if unavailable:
        return [Outcome(UNRELIABLE, j.show, j.line, j.name, f'{j.sshow}: {unavailable}') for j in jobs]
    try:
        verdicts = av.judge_many([j.pair for j in jobs], regime, tempfile.mkdtemp(prefix='judge-', dir=work))
    except Exception as e:  # noqa: BLE001
        verdicts = [av.Unreliable(f'the value comparison failed: {type(e).__name__}: {e}')] * len(jobs)
    out = []
    for j, v in zip(jobs, verdicts):
        if isinstance(v, BaseException):
            out.append(Outcome(UNRELIABLE, j.show, j.line, j.name, f'{j.sshow}: {v}'))
        elif v.verdict == 'pass':
            out.append(Outcome(PASS, j.show, j.line, j.name, j.sshow))
        elif v.verdict == 'not-comparable':
            out.append(Outcome(UNVERIFIED, j.show, j.line, j.name, f'not-comparable - {j.sshow}: {v.reason}'))
        else:
            out.append(Outcome(RED, j.show, j.line, j.name, f'{v.line()} - SOURCE {j.sshow}'))
    return out


# ==== the run =====================================================================================

def lex_comments(pool, tfiles):
    """(the TARGET files with their comment lines, an UNRELIABLE outcome for each file libclang
    cannot lex): anchors are read only in comments."""
    futs = [(tf, pool.submit(ab.comment_lines, tf.path)) for tf in tfiles]
    kept, out = [], []
    for tf, fut in futs:
        try:
            tf.comments = fut.result()
        except Exception as e:  # noqa: BLE001 - a file whose comments are unknown has unknown anchors
            out.append(Outcome(UNRELIABLE, tf.show, 0, '', f'its comments cannot be read ({e}): its anchors and '
                               f'coverage cannot be judged', tf.within))
            continue
        if len(tf.comments) != len(tf.lines):
            out.append(Outcome(UNRELIABLE, tf.show, 0, '', 'libclang reads its lines differently from the verifier: '
                               'its anchors and coverage cannot be judged', tf.within))
            continue
        kept.append(tf)
    return kept, out


def helper_outcomes(tf, cfg):
    """The runtime-helper anchors of a file: valid only in a declared helper file, citing a trap row."""
    out = []
    for i, ln in enumerate(tf.comments, 1):
        for m in HELPER_ANCHOR.finditer(ln):
            trap = re.sub(r'[^A-Za-z0-9]', '', re.split(r'[-:]', (m.group('payload').split() or [''])[0])[0])
            if not tf.helper:
                out.append(Outcome(RED, tf.show, i, '', f'invalid-anchor - a runtime-helper anchor is valid only in '
                                   f'a file listed in {HELPERS_YAML}; {os.path.basename(tf.path)} is not'))
            elif cfg.traps is None:
                out.append(Outcome(UNRELIABLE, tf.show, i, '', f'the pair table {PAIR_TABLE} is missing: the trap '
                                   f'row of a runtime-helper anchor cannot be checked'))
            elif trap not in cfg.traps:
                out.append(Outcome(RED, tf.show, i, '', f'invalid-anchor - the runtime-helper anchor cites trap '
                                   f'{trap or "(none)"}, which no trap row of {PAIR_TABLE} or '
                                   f'{PROJECT_CONVENTIONS} defines'))
        if re.search(r'/\*\s*runtime-helper:', HELPER_ANCHOR.sub('', ln)):
            out.append(Outcome(RED, tf.show, i, '', 'invalid-anchor - a runtime-helper anchor opens without closing '
                               'on its line'))
    return out


def index_sources(pool, cfg, cited, top):
    """({(regime, file): index}, {MODULE: [files with a `MODULE <name>` line]}): every cited file and,
    transitively, every file that may define a module one of them USEs - each preprocessed and
    parsed in its own process."""
    definers = module_candidates(top)
    index, todo = {}, {(r, f): sorted(lines) for r in cfg.regimes for f, lines in cited.items()}
    while todo:
        futs = {k: pool.submit(index_source, k[1], av.FFLAGS[:1] + list(cfg.regimes[k[0]][0]), v)
                for k, v in todo.items()}
        nxt = {}
        for (r, f), fut in futs.items():
            res = index[(r, f)] = fut.result()
            for mname in ([] if res['error'] else res['uses']):
                for g in definers.get(mname, []):
                    if (r, g) not in index and (r, g) not in futs:
                        nxt[(r, g)] = []
        todo = nxt
    return index, definers


def closures(index, regime, cited, show, definers):
    """(files to compile in dependency order, their dependencies, {cited file: (its closure, or None
    and the reason it has none)}) in one regime. A module is defined by the files fparser finds it
    in; a file with a `MODULE <name>` line that cannot be read may define it too, so a USE of that
    module cannot be resolved."""
    defined = collections.defaultdict(list)
    for (r, f), res in sorted(index.items()):
        if r == regime and not res['error']:
            for mname in res['modules']:
                defined[mname].append(f)
    order, deps, state, reason = [], {}, {}, {}

    def visit(f, chain):
        if state.get(f) == 'done':
            return reason[f]
        if state.get(f) == 'open':
            return 'a cycle of module USEs: ' + ' -> '.join(show[x] for x in chain + [f])
        res = index[(regime, f)]
        if res['error']:
            return f'{show[f]} cannot be read: {res["error"]}'
        state[f], deps[f], why = 'open', [], None
        for mname in res['uses']:
            files = [] if mname in res['modules'] else defined.get(mname, [])
            unread = [g for g in definers.get(mname, []) if (regime, g) in index and index[(regime, g)]['error']]
            if mname not in res['modules'] and unread:
                why = why or (f'{show[unread[0]]} has a MODULE {mname} line but cannot be read in regime {regime}: '
                              f'{index[(regime, unread[0])]["error"]}')
                continue
            if mname in res['modules'] or (not files and mname in INTRINSIC_MODULES):
                continue
            if not files:
                why = why or f'module {mname}, USEd by {show[f]}, is defined by no SOURCE file'
            elif len(files) > 1:
                why = why or f'module {mname} is defined by more than one SOURCE file: {", ".join(show[g] for g in files)}'
            else:
                why = why or visit(files[0], chain + [f])
                deps[f].append(files[0])
        state[f], reason[f] = 'done', why
        if res['modules']:
            order.append(f)
        return why

    per = {}
    for f in sorted(cited):
        why = visit(f, [])
        if why:
            per[f] = (None, why)
            continue
        seen, stack = [], [f]
        while stack:
            g = stack.pop()
            if g not in seen:
                seen.append(g)
                stack += deps.get(g, [])
        per[f] = (seen, '')
    # A probe compiles its cited file itself: the closure holds only what some cited file USEs.
    used = {g for closure, _ in per.values() for g in (closure or [])[1:]}
    return [f for f in order if f in used and not reason.get(f)], deps, per


@contextlib.contextmanager
def worker_pool():
    """The process pool of a run. Each worker leads a process group of its own, with the compilers it
    runs, so leaving the pool early - a stop by a signal, an error - ends the running tasks at once
    (each group killed) and cancels the work not yet started; the scratch directory is then removed
    with nothing left writing to it."""
    pool = ProcessPoolExecutor(max_workers=cpus(), initializer=os.setpgrp)
    try:
        yield pool
    except BaseException:
        # the pool's worker processes (a private attribute, stable since Python 3.2: were it gone, the
        # stop would wait for the running tasks, no worse)
        for pid in list(getattr(pool, '_processes', None) or {}):
            for kill in (os.killpg, os.kill):
                try:
                    kill(pid, signal.SIGKILL)
                    break
                except OSError:
                    continue
        pool.shutdown(wait=True, cancel_futures=True)
        raise
    pool.shutdown(wait=True)


def cpus():
    """The CPUs this process may run on (taskset and CI limits included)."""
    if hasattr(os, 'process_cpu_count'):
        return os.process_cpu_count() or 1
    return len(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else os.cpu_count() or 1


def _show(path, root):
    rel = os.path.relpath(path, root)
    return path if rel == '..' or rel.startswith('..' + os.sep) else rel


def run(argv):
    opts = {'workbench': None, 'product_root': None, 'ref': '', 'verbose': False, 'scan': False}
    files, it = [], iter(argv)
    for a in it:
        if a in ('--workbench', '--product-root', '--ref'):
            opts[a[2:].replace('-', '_')] = next(it, '')
        elif a in ('--verbose', '--scan'):
            opts[a[2:]] = True
        elif a == '--':
            files += list(it)
        else:
            files.append(a)
    if not opts['workbench'] or not opts['product_root']:
        raise Fatal(__doc__.strip().splitlines()[-2])
    wb, product = os.path.abspath(opts['workbench']), os.path.abspath(opts['product_root'])
    scanned = None
    if opts['scan']:
        files, problems = ab.target_files(product)
        if problems:
            raise Fatal(f'scanning {product} for TARGET files did not complete: {problems[0]} - the file set may '
                        f'be incomplete')
        if not files:
            print(f"verify-anchors: no TARGET *.c/*.h files under '{product}' yet - nothing to verify (skipping).")
            return 0
        scanned = {os.path.realpath(f) for f in files}
    regimes, include, names = load_anchors_yaml(wb, product)
    include = include or sorted({os.path.dirname(os.path.abspath(f)) for f in files})
    cfg = Config(regimes, include, names, load_helpers(wb), load_traps(wb))
    cfg.ref, cfg.sha, cfg.source_root = load_pin(wb, opts['ref'])
    for tool in ('gfortran', 'clang', 'ar', 'objcopy'):
        if shutil.which(tool) is None:
            raise Fatal(f'{tool} is not installed: the verifier compiles the SOURCE and TARGET probes with it')
    try:
        import clang.cindex as ci
        ci.Index.create()
        av._fparser()
    except Exception as e:  # noqa: BLE001 - an import or native-library failure alike
        raise Fatal(f'a parser is not available: {e}')
    scratch = tempfile.mkdtemp(prefix='verify-anchors-')
    try:
        return verify(cfg, wb, product, files, scratch, opts['verbose'], scanned)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def verify(cfg, wb, product, files, scratch, verbose=False, scanned=None):
    top = extract_source(wb, cfg.sha, cfg.source_root, scratch)
    work_tree = os.path.realpath(os.path.join(wb, cfg.source_root))
    cfg.regimes = {r: (include_flags(sf, top, work_tree, r), include_flags(tf, product, None, r))
                   for r, (sf, tf) in cfg.regimes.items()}
    src = Sources(top)
    tfiles, glob = [], []
    for f in files:
        full = os.path.abspath(f)
        show = _show(full, product)
        try:
            with open(full, encoding='utf-8') as fh:
                lines = fh.read().split('\n')
        except (OSError, UnicodeDecodeError) as e:
            glob.append(Outcome(UNRELIABLE, show, 0, '', f'cannot be read ({e}): its anchors and coverage cannot be judged'))
            continue
        if lines and lines[-1] == '':
            lines.pop()
        tfiles.append(TFile(full, show, lines, os.path.basename(full).lower() in cfg.helpers))
    sshow = {}
    regimes = list(cfg.regimes)
    print(f'verify-anchors: SOURCE pin {cfg.ref} ({cfg.sha[:12]}), root {cfg.source_root}; '
          f'{len(files)} TARGET file(s); regime(s): {", ".join(regimes)}')
    per_regime = {r: [] for r in regimes}
    cflags = {r: list(cfg.regimes[r][1]) + [x for d in cfg.include for x in ('-I', d)] for r in regimes}
    with worker_pool() as pool:
        frags, unread_frags = fragments(pool, tfiles, cflags, product, scanned, cfg)
        glob += unread_frags
        tfiles, unlexed = lex_comments(pool, tfiles + frags)
        glob += unlexed
        judged = frozenset(os.path.realpath(tf.path) for tf in tfiles)
        cited, cites, seen = collections.defaultdict(set), collections.defaultdict(set), set()
        for tf in tfiles:
            if tf.path in seen:
                continue  # another instance of a fragment: its text is read once
            seen.add(tf.path)
            glob += helper_outcomes(tf, cfg)
            for i, m in ab.anchors_in(tf.comments)[0]:
                full = src.resolve(m.group('path'))[0]
                if full and anchor_form(m) in ('constant', 'module'):
                    cited[full].add(int(m.group('line')))
                    cites[tf.path].add(full)
        index, definers = index_sources(pool, cfg, cited, top)
        for _, f in index:
            sshow[f] = os.path.relpath(f, top)
        plans, comp = {}, {}
        for r in regimes:
            plans[r] = closures(index, r, cited, sshow, definers)
            work = os.path.join(scratch, f'regime-{r}')
            os.makedirs(work)
            comp[r] = pool.submit(compile_closure, list(cfg.regimes[r][0]), plans[r][0], plans[r][1], sshow, work)
        bound = {(r, tf.key): (tf, pool.submit(bind_file, tf, r, cflags[r], cfg.names, top,
                                                {f: index[(r, f)] for f in cites[tf.path]}, cfg.sha, product,
                                                scanned, judged))
                 for r in regimes for tf in tfiles}
        orphans = collections.defaultdict(list)
        jobs = collections.defaultdict(list)
        temps = {r: [] for r in regimes}
        for (r, key), (tf, fut) in bound.items():
            out, js, orph, parsed, tmp = fut.result()
            for o in out:
                o.within = tf.within
            per_regime[r] += out
            temps[r] += [(tf.show, tf.within) + t for t in tmp]
            if parsed:
                orphans[key].append(orph)
            for j in js:
                jobs[(r, j.pair.src)].append(j)
        judged, causes = [], {}
        for (r, s), js in sorted(jobs.items()):
            c = comp[r].result()
            closure, why = plans[r][2].get(s, (None, 'it was not indexed'))
            if not why:
                broken = [g for g in closure if g in c['failed']]
                if broken:
                    root, cause = c['failed'][broken[0]]
                    shown = sshow.get(root, os.path.basename(root))
                    causes[(r, shown)] = cause
                    why = f'{shown}, in its USE closure, does not compile (the SOURCE {shown} finding says why)'
            regime = ab.Regime(r, fflags=tuple(cfg.regimes[r][0]) + ('-I', c['moddir']), cflags=tuple(cflags[r]),
                               ldflags=(c['archive'],) if c['archive'] else (),
                               fmodules=tuple(g for g in (closure or []) if g != s and index[(r, g)]['types']))
            judged.append((r, pool.submit(judge_group, js, regime, scratch, why)))
        for r, fut in judged:
            per_regime[r] += fut.result()
    for r in regimes:
        per_regime[r] += temporary_outcomes(temps[r], per_regime[r])
    for (r, shown), cause in causes.items():
        per_regime[r].append(Outcome(UNRELIABLE, f'SOURCE {shown}', 0, '', f'does not compile: {cause}'))
    for tf in tfiles:
        maps = orphans.get(tf.key)
        for i in sorted(set.intersection(*[set(m) for m in maps]) if maps else ()):
            if all(m[i] == 'never' for m in maps):
                glob.append(Outcome(UNRELIABLE, tf.show, i, '', 'this branch is never built (#if 0): the declaration '
                                    'its anchor would bind to is never compiled, so never judged - remove the dead '
                                    'code or its anchor', tf.within))
            elif all(m[i] for m in maps):
                glob.append(Outcome(UNRELIABLE, tf.show, i, '', f'no regime builds this branch: the declaration '
                                    f'its anchor would bind to is never compiled, so never judged - add the regime '
                                    f'that builds it to {ANCHORS_YAML}', tf.within))
            else:
                glob.append(Outcome(RED, tf.show, i, '', f'invalid-anchor - {tf.show}:{i}: the constant anchor binds '
                                    f'to no declaration (binding rules 1-3)', tf.within))
    return report(per_regime, glob, regimes, verbose)


def temporary_outcomes(temps, outcomes):
    """A temporary of a TARGET constant - an anchored constant its initializer reaches, citing its
    statement - is verified through that constant: it takes the constant's verdict."""
    by = {(o.show, o.within, o.line, o.name): o for o in outcomes}
    out = []
    for show, within, line, name, oline, oname in temps:
        o = by.get((show, within, oline, oname))
        if o is None:
            out.append(Outcome(UNRELIABLE, show, line, name, f'temporary of {oname} (line {oline}), which has no '
                               f'verdict', within))
        elif o.tag == PASS:
            out.append(Outcome(PASS, show, line, name, f'temporary of {oname} (line {oline}), verified through it', within))
        else:
            out.append(Outcome(o.tag, show, line, name, f'temporary of {oname} (line {oline}): {o.text}', within))
    return out


def report(per_regime, glob, regimes, verbose=False):
    findings = collections.OrderedDict()
    for r in regimes:
        for o in per_regime[r]:
            findings.setdefault((o.tag, o.show, o.line, o.name, o.text, o.within), []).append(r)
    for o in glob:
        findings.setdefault((o.tag, o.show, o.line, o.name, o.text, o.within), [])
    order = {RED: 0, UNRELIABLE: 1, UNVERIFIED: 2}
    for (tag, show, line, name, text, within), rs in sorted(
            findings.items(), key=lambda kv: (kv[0][1], kv[0][2], kv[0][5], order.get(kv[0][0], 3), kv[0][4])):
        if tag == PASS and not verbose:
            continue
        loc = (f'{show}:{line}' if line else show) + (f' (in {within})' if within else '')
        print(f'{tag} {loc}{" " + name if name else ""}{" [" + ", ".join(rs) + "]" if rs else ""}: {text}')
    print('-' * 72)
    for r in regimes:
        c = collections.Counter(o.tag for o in per_regime[r])
        print(f'SUMMARY [{r}]: {c[PASS]} verified, {c[UNVERIFIED]} unverified, {c[RED]} red, {c[UNRELIABLE]} unreliable')
    g = collections.Counter(o.tag for o in glob)
    if glob:
        print(f'SUMMARY [every regime]: {g[RED]} red, {g[UNRELIABLE]} unreliable (runtime-helper and unbound anchors, '
              f'unreadable files)')
    tags = {o.tag for r in regimes for o in per_regime[r]} | set(g)
    if RED in tags:
        print('RESULT: RED (exit 1) - a value mismatch, a broken anchor rule or a constant without an anchor.')
        return 1
    if UNRELIABLE in tags:
        print('RESULT: UNRELIABLE (exit 2) - something could not be judged; never counted as a pass.')
        return 2
    print('RESULT: GREEN (exit 0) - every anchor holds and every anchored constant equals its SOURCE value'
          + (' (run-time values reported UNVERIFIED).' if UNVERIFIED in tags else '.'))
    return 0


def _stopped(signum, frame):
    raise Fatal(f'stopped by signal {signum} before the verdict')


def main(argv):
    signal.signal(signal.SIGTERM, _stopped)  # a stop unwinds through the scratch directory's removal
    try:
        return run(argv)
    except Fatal as e:
        print(f'verify-anchors: UNRELIABLE - {e}')
    except Exception:  # noqa: BLE001 - a crash is not a verdict
        print('verify-anchors: UNRELIABLE - the verifier failed:')
        traceback.print_exc(file=sys.stdout)
    print('RESULT: UNRELIABLE (exit 2)')
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
