#!/usr/bin/env bash
# Validates the anchor-verifier test-case corpus, tools/conformance/seeded-bugs/verify-anchors/
# (format, binding rules and verdict vocabulary: its README.md). Every case directory
# <category>/<NN>-<slug>/ must hold exactly case.yaml, source.F90 and target.c (or target.h), and:
#   - case.yaml parses, uses only the documented keys (`situation` among the required ones), and
#     every enumerated value is valid;
#     `mismatch` is present exactly when `expect` is `mismatch`; `at` only with it, written as
#     zero-based storage positions `[k]` and field names `.f`;
#   - the cited lines exist and contain the named symbol (SOURCE: whole word, any case; TARGET:
#     whole word, exact case; a path such as `T%A` or `ctx.a` matches on any of its identifiers);
#   - the anchors bound to the TARGET entity (README "Anchor grammar and binding") obey the anchor
#     rules - a constant anchor quotes one literal of the cited line or the whole right-hand side of
#     its statement - and `expect` is `invalid-anchor` exactly when one of them is broken;
#   - the TARGET passes `clang -std=c17 -fsyntax-only` and the SOURCE `gfortran -cpp
#     -fsyntax-only`, in each listed regime (`dp` defines FIXTURE_DP, `sp` does not);
#   - every situation holding a `pass` or `mismatch` case holds a `pass` case and a case of another
#     verdict (a situation of `not-comparable` and `invalid-anchor` cases only is exempt), and
#     every category holds at least one `pass` case and at least one other.
# Declaration extents come from clang's AST, so binding follows the compiler, not the layout. A
# missing compiler fails the test; it never skips. The validator does not measure values.
#
# The validator is then run on a known-good corpus built here and on seeded malformed copies of
# it; the good corpus must be accepted and each copy rejected for its own reason.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORPUS="$ROOT/tools/conformance/seeded-bugs/verify-anchors"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
failt() { printf 'not ok - %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }

cat >"$TMP/validate.py" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor

root = sys.argv[1]
for tool in ('clang', 'gfortran'):
    if shutil.which(tool) is None:
        print(f'not ok - {tool} not found: the corpus cannot be compiled, so it is not validated')
        sys.exit(1)
try:
    import yaml
except ImportError:
    print('not ok - python3 yaml (PyYAML) not importable: case.yaml cannot be read')
    sys.exit(1)

KEYS = {'description', 'situation', 'source', 'target', 'regimes', 'expect', 'mismatch', 'at', 'why'}
REQUIRED = {'description', 'situation', 'source', 'target', 'regimes', 'expect', 'why'}
EXPECT = ('pass', 'mismatch', 'not-comparable', 'invalid-anchor')
MISMATCH = ('value', 'kind', 'type', 'shape')
REGIMES = ('dp', 'sp')
SLUG = re.compile(r'^[a-z0-9]+(-[a-z0-9]+)*$')
CASE = re.compile(r'^[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$')
IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
AT = re.compile(r'^(\[[0-9]+\]|\.[A-Za-z_][A-Za-z0-9_]*)+$')
ANCHOR = re.compile(r'/\*\s*src:\s*(?P<path>[^:\s]+):(?P<line>[0-9]+)(?P<rest>.*?)\s*\*/')
TYPE_HDR = re.compile(r'\s*TYPE\s*(?:,[^:]*)?(?:::)?\s*([A-Za-z_]\w*)\s*$', re.I)
TYPE_END = re.compile(r'\s*END\s*TYPE\b', re.I)
TYPE_COMP = re.compile(r'\s*TYPE\s*\(\s*([A-Za-z_]\w*)\s*\)', re.I)
MODULE_HDR = re.compile(r'\s*MODULE\s+([A-Za-z_]\w*)\s*$', re.I)
MODULE_END = re.compile(r'\s*END\s*MODULE\b', re.I)
F_TOKEN = re.compile(r'(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[EeDd][+-]?[0-9]+)?(?:_[A-Za-z0-9_]+)?'
                     r'|\.(?:TRUE|FALSE)\.(?:_[A-Za-z0-9_]+)?|\.[A-Za-z]+\.|[A-Za-z][A-Za-z0-9_]*'
                     r'|\'[^\']*\'|"[^"]*"|\*\*|//|=>|==|/=|<=|>=|\S', re.I)

errors = []
jobs = []
ncases = 0


def word_in(ident, line, fold):
    return re.search(r'(?<![A-Za-z0-9_])' + re.escape(ident) + r'(?![A-Za-z0-9_])', line,
                     re.I if fold else 0) is not None


def read_lines(path):
    lines = open(path, encoding='utf-8').read().split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    return lines


def side(where, meta, key, files, path):
    """Validate meta[key] ({file, line, name}); return (lines, line) or None."""
    ref = meta.get(key)
    if not isinstance(ref, dict) or set(ref) != {'file', 'line', 'name'}:
        errors.append(f'{where}: {key} must be a mapping of exactly file, line and name')
        return None
    f, line, name = ref['file'], ref['line'], ref['name']
    allowed = ('source.F90',) if key == 'source' else ('target.c', 'target.h')
    if f not in allowed:
        errors.append(f'{where}: {key}.file is {f!r}, not one of {", ".join(allowed)}')
        return None
    if f not in files:
        errors.append(f'{where}: {key}.file {f} does not exist')
        return None
    if not isinstance(line, int) or isinstance(line, bool) or line < 1:
        errors.append(f'{where}: {key}.line must be a positive integer')
        return None
    if not isinstance(name, str) or not IDENT.search(name):
        errors.append(f'{where}: {key}.name must name an identifier')
        return None
    lines = read_lines(os.path.join(path, f))
    if line > len(lines):
        errors.append(f'{where}: {key}.line {line} is past the end of {f} ({len(lines)} lines)')
        return None
    text = lines[line - 1]
    if not any(word_in(i, text, key == 'source') for i in IDENT.findall(name)):
        errors.append(f'{where}: {f}:{line} does not contain {key}.name {name!r}: {text.strip()!r}')
        return None
    return lines, line


# ---- SOURCE scope: the lines an anchor of this case may cite ------------------------------------
def f_statements(lines):
    """[(first, last, text)]: free-form statements, '&' continuations joined, '!' comments dropped."""
    out, i = [], 0
    while i < len(lines):
        first, buf = i + 1, ''
        while True:
            ln = re.sub(r'!.*$', '', lines[i]).rstrip()
            if buf and ln.lstrip().startswith('&'):
                ln = ln.lstrip()[1:]
            if ln.endswith('&') and i + 1 < len(lines):
                buf += ln[:-1] + ' '
                i += 1
                continue
            buf += ln
            break
        out.append((first, i + 1, buf))
        i += 1
    return out


def block(stmts, k, end_re):
    for first, last, text in stmts[k + 1:]:
        if end_re.match(text):
            return last
    return stmts[-1][1]


def source_scope(lines, sline):
    """(scope lines, module name or None): the statement holding sline and its continuation
    lines; for a TYPE statement its definition and those of the types of its components; for a
    MODULE statement the whole module."""
    stmts = f_statements(lines)
    for k, (first, last, text) in enumerate(stmts):
        if first <= sline <= last:
            break
    else:
        return set(), None
    m = MODULE_HDR.match(text)
    if m and m.group(1).upper() != 'PROCEDURE':
        return set(range(first, block(stmts, k, MODULE_END) + 1)), m.group(1).upper()
    if TYPE_HDR.match(text):
        types = {}
        for j, (f2, l2, t2) in enumerate(stmts):
            h = TYPE_HDR.match(t2)
            if h:
                types[h.group(1).upper()] = j
        scope, todo, done = set(), [TYPE_HDR.match(text).group(1).upper()], set()
        while todo:
            name = todo.pop()
            if name in done or name not in types:
                continue
            done.add(name)
            j = types[name]
            end = block(stmts, j, TYPE_END)
            scope |= set(range(stmts[j][0], end + 1))
            todo += [c.group(1).upper() for f2, l2, t2 in stmts if stmts[j][0] < f2 <= end
                     for c in [TYPE_COMP.match(t2)] if c]
        return scope, None
    return set(range(first, last + 1)), None


# ---- TARGET declarations and anchor binding -------------------------------------------------------
def target_decls(path, text, regime):
    """[(name, first line, name line, last line)]: objects, enumerators and functions of the file
    (extents from clang's AST) and its #defines (with their continued lines)."""
    define = ['-DFIXTURE_DP'] if regime == 'dp' else []
    p = subprocess.run(['clang', '-std=c17', '-fsyntax-only', '-x', 'c'] + define +
                       ['-Xclang', '-ast-dump=json', path], stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise RuntimeError('clang cannot read the declarations')
    starts = [0]
    for ln in text.split('\n'):
        starts.append(starts[-1] + len(ln) + 1)

    def line_at(off):
        lo, hi = 0, len(starts) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if starts[mid] <= off:
                lo = mid
            else:
                hi = mid - 1
        return lo + 1

    def where(loc):
        if not loc:
            return None
        loc = loc.get('expansionLoc', loc)
        if 'includedFrom' in loc or 'offset' not in loc:
            return None
        return loc['offset']

    decls = []

    def walk(n):
        if n.get('kind') in ('VarDecl', 'EnumConstantDecl', 'FunctionDecl') and n.get('name'):
            o = (where(n.get('loc')), where(n.get('range', {}).get('begin')), where(n.get('range', {}).get('end')))
            if None not in o:
                decls.append((n['name'], line_at(o[1]), line_at(o[0]), line_at(o[2])))
        for c in n.get('inner') or []:
            walk(c)

    walk(json.loads(p.stdout))
    lines = text.split('\n')
    i = 0
    while i < len(lines):
        m = re.match(r'\s*#\s*define\s+(\w+)', lines[i])
        if m:
            j = i
            while j + 1 < len(lines) and lines[j].rstrip().endswith('\\'):
                j += 1
            decls.append((m.group(1), i + 1, i + 1, j + 1))
            i = j
        i += 1
    return decls


F_LITERAL = re.compile(r'(?:(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[EeDd][+-]?[0-9]+)?(?:_[A-Za-z0-9_]+)?'
                       r'|\.(?:TRUE|FALSE)\.(?:_[A-Za-z0-9_]+)?)', re.I)


def squeeze(text):
    return re.sub(r'\s+', '', text)


def literal_token(payload, line):
    """True when payload is one numeric or logical literal - kind suffix and exponent included -
    and is a whole token of the SOURCE line."""
    code = line.split('!')[0]
    return (F_LITERAL.fullmatch(payload) is not None
            and any(m.group(0) == payload for m in F_TOKEN.finditer(code)))


def top_level(text, sep):
    """Split text at the separators outside parentheses and brackets."""
    parts, depth, cur = [], 0, ''
    for ch in text:
        depth += {'(': 1, '[': 1, ')': -1, ']': -1}.get(ch, 0)
        if ch == sep and depth == 0:
            parts.append(cur)
            cur = ''
        else:
            cur += ch
    return parts + [cur]


def statement_rhs(stmt):
    """The right-hand sides a SOURCE statement gives: the value of each initialized entity of a
    declaration (after ::, a pointer default after =>), the value of an assignment, or the value
    list of a DATA statement."""
    m = re.match(r'\s*DATA\b[^/]*/(.*)/\s*$', stmt, re.I)
    if m:
        return [m.group(1)]
    parts = top_level(stmt.split('::', 1)[1], ',') if '::' in stmt else [stmt]
    out = []
    for part in parts:
        depth = 0
        for i, ch in enumerate(part):
            depth += {'(': 1, '[': 1, ')': -1, ']': -1}.get(ch, 0)
            if ch == '=' and depth == 0 and part[i - 1:i] not in ('=', '/', '<', '>') \
                    and part[i + 1:i + 2] != '=':
                out.append(part[i + 2:] if part[i + 1:i + 2] == '>' else part[i + 1:])
                break
    return out


def whole_tokens(payload, line):
    """True when payload occurs in the SOURCE line as a run of whole Fortran tokens: it starts at a
    token's first character and ends at a token's last, so it cannot stop inside a literal (before
    its kind suffix, exponent or last digits), a name, or an operator."""
    code = line.split('!')[0]
    spans = [(m.start(), m.end()) for m in F_TOKEN.finditer(code)]
    starts, ends = {a for a, b in spans}, {b for a, b in spans}
    i = code.find(payload)
    while i != -1:
        if i in starts and i + len(payload) in ends:
            return True
        i = code.find(payload, i + 1)
    return False


def code_of(line):
    c = re.sub(r'/\*.*?\*/', ' ', line)
    c = re.sub(r'/\*.*$', ' ', c).strip().rstrip('\\').strip()
    return '' if re.fullmatch(r'[\s};,)\]]*', c) else c


def bind(decls, lines, aline):
    """The declaration an anchor on aline binds to, or None (README binding rules)."""
    inside = [d for d in decls if d[1] <= aline <= d[3]]
    if inside:
        named = [d for d in inside if d[2] == aline]
        return named[0] if named else max(inside, key=lambda d: d[1])
    if code_of(lines[aline - 1]) == '' and not any(d[1] == aline + 1 for d in decls):
        above = [d for d in decls if d[3] == aline - 1]
        if above:
            return max(above, key=lambda d: d[2])
    return None


def anchor_problems(meta, path, slines, tlines, tfile, regime):
    """The anchor rules a case breaks (an empty list when every rule holds)."""
    sline, tline, tname = meta['source']['line'], meta['target']['line'], meta['target']['name']
    scope, module = source_scope(slines, sline)
    stmts = f_statements(slines)
    base = IDENT.match(tname.strip()).group(0) if IDENT.match(tname.strip()) else tname
    text = '\n'.join(tlines)
    decls = target_decls(os.path.join(path, tfile), text, regime)
    entity = [d for d in decls if d[0] == base and (d[2] == tline or d[1] <= tline <= d[3])]
    found, opened = [], []
    for i, ln in enumerate(tlines, 1):
        for m in ANCHOR.finditer(ln):
            found.append((i, m))
        if re.search(r'/\*\s*src:', ANCHOR.sub('', ln)):
            opened.append(i)
    if entity:
        is_bound = lambda i: bind(decls, tlines, i) == entity[0]
    else:  # an assignment statement, not a declaration: its anchor is on its own line
        is_bound = lambda i: i == tline
    bound = [(i, m) for i, m in found if is_bound(i)]
    problems = [f'{tfile}:{i}: an anchor opens without closing on its line' for i in opened if is_bound(i)]
    context = base.upper().endswith('_CTX_INIT')
    seen, constants = set(), 0
    for i, m in bound:
        full, rest = m.group(0), m.group('rest').strip()
        if (i, full) in seen:
            problems.append(f'{tfile}:{i}: {full} is written twice')
        seen.add((i, full))
        if m.group('path') != 'source.F90':
            problems.append(f'{tfile}:{i}: {full} cites {m.group("path")}, not source.F90')
            continue
        n = int(m.group('line'))
        if n > len(slines):
            problems.append(f'{tfile}:{i}: {full} cites a line past the end of source.F90')
            continue
        mod = re.fullmatch(r'\(module\s+([A-Za-z_]\w*)\)', rest, re.I)
        if rest.startswith('= ') and rest[2:].strip():
            constants += 1
            lit, line = rest[2:], slines[n - 1]
            stmt = next((t for f2, l2, t in stmts if f2 <= n <= l2), '')
            if n not in scope:
                problems.append(f'{tfile}:{i}: {full} cites line {n}, outside the SOURCE statement, type or module of the case')
            elif squeeze(lit) not in squeeze(line.split('!')[0]):
                problems.append(f'{tfile}:{i}: {full}: the literal-as-read is not on source.F90:{n}')
            elif literal_token(lit, line) or squeeze(lit) in {squeeze(r) for r in statement_rhs(stmt)}:
                pass
            elif not whole_tokens(lit, line):
                problems.append(f'{tfile}:{i}: {full}: the literal-as-read cuts a token of source.F90:{n} - quote a literal whole, with its exponent and kind suffix')
            else:
                problems.append(f'{tfile}:{i}: {full}: the literal-as-read is neither one literal of source.F90:{n} nor the whole right-hand side of its statement')
        elif mod:
            if not (context and module and n == sline and mod.group(1).upper() == module
                    and base.upper() == module + '_CTX_INIT'):
                problems.append(f'{tfile}:{i}: {full}: a module header anchor is only for <MODULE>_CTX_INIT, citing that MODULE statement')
        else:
            problems.append(f'{tfile}:{i}: {full} is not the constant grammar')
    if not bound and not problems:
        problems.append(f'no anchor binds to {base}')
    elif constants == 0 and not context and not problems:
        problems.append(f'no constant anchor binds to {base}')
    return problems


if not os.path.isdir(root):
    print(f'not ok - corpus root {root} does not exist')
    sys.exit(1)

coverage = {}
situations = {}
for cat in sorted(os.listdir(root)):
    cpath = os.path.join(root, cat)
    if not os.path.isdir(cpath):
        continue
    if not SLUG.match(cat):
        errors.append(f'{cat}: a category name is lowercase words joined by hyphens')
    coverage[cat] = {'pass': 0, 'other': 0}
    for name in sorted(os.listdir(cpath)):
        path = os.path.join(cpath, name)
        where = f'{cat}/{name}'
        if not os.path.isdir(path):
            errors.append(f'{where}: a category holds case directories only')
            continue
        ncases += 1
        if not CASE.match(name):
            errors.append(f'{where}: a case directory is <NN>-<short-slug>')
        files = set(os.listdir(path))
        if 'case.yaml' not in files:
            errors.append(f'{where}: case.yaml missing')
            continue
        try:
            meta = yaml.safe_load(open(os.path.join(path, 'case.yaml'), encoding='utf-8'))
        except yaml.YAMLError as e:
            errors.append(f'{where}: case.yaml does not parse: {str(e).splitlines()[0]}')
            continue
        if not isinstance(meta, dict):
            errors.append(f'{where}: case.yaml is not a mapping')
            continue
        bad = False
        for k in sorted(set(meta) - KEYS):
            errors.append(f'{where}: unknown key {k!r}')
            bad = True
        for k in sorted(REQUIRED - set(meta)):
            errors.append(f'{where}: missing key {k!r}')
            bad = True
        if bad:
            continue
        for k in ('description', 'why'):
            if not isinstance(meta[k], str) or not meta[k].strip() or '\n' in meta[k].strip():
                errors.append(f'{where}: {k} must be one non-empty line of text')
        if 'situation' in meta and not (isinstance(meta['situation'], str) and SLUG.match(meta['situation'])):
            errors.append(f'{where}: situation is lowercase words joined by hyphens')
        expect = meta['expect']
        if expect not in EXPECT:
            errors.append(f'{where}: expect is {expect!r}, not one of {", ".join(EXPECT)}')
        if expect == 'mismatch':
            if meta.get('mismatch') not in MISMATCH:
                errors.append(f'{where}: expect: mismatch needs mismatch: one of {", ".join(MISMATCH)}')
        else:
            for k in ('mismatch', 'at'):
                if k in meta:
                    errors.append(f'{where}: {k} is only for expect: mismatch')
        if 'at' in meta and not (isinstance(meta['at'], str) and AT.match(meta['at'])):
            errors.append(f'{where}: at is zero-based storage positions [k] and field names .f, as in "[2]" or ".b.c" or ".k[1]"')
        regimes = meta['regimes']
        if (not isinstance(regimes, list) or not regimes or len(set(regimes)) != len(regimes)
                or any(r not in REGIMES for r in regimes)):
            errors.append(f'{where}: regimes must be a non-empty list of distinct values from {", ".join(REGIMES)}')
            regimes = []
        if expect in EXPECT:
            coverage[cat]['pass' if expect == 'pass' else 'other'] += 1
            situations.setdefault((cat, str(meta['situation'])), set()).add(expect)
        tfile = meta['target'].get('file') if isinstance(meta['target'], dict) else None
        want = {'case.yaml', 'source.F90'} | ({tfile} if tfile in ('target.c', 'target.h') else set())
        for f in sorted(files - want):
            errors.append(f'{where}: unexpected file {f}')
        src = side(where, meta, 'source', files, path)
        tgt = side(where, meta, 'target', files, path)
        if src and tgt and regimes and expect in EXPECT:
            jobs.append(('anchors', where, regimes[0], (meta, path, src[0], tgt[0], tfile, expect)))
        if 'source.F90' in files:
            for r in regimes:
                jobs.append(('gfortran', where, r, os.path.join(path, 'source.F90')))
        if tfile in files and tfile in ('target.c', 'target.h'):
            for r in regimes:
                jobs.append(('clang', where, r, os.path.join(path, tfile)))

for cat, c in coverage.items():
    if c['pass'] == 0:
        errors.append(f'{cat}: no pass case (every category holds at least one)')
    if c['other'] == 0:
        errors.append(f'{cat}: no case other than pass (every category holds at least one)')
# A situation with a comparable value pairs a faithful rendering with a wrong one. A situation
# holding only not-comparable and invalid-anchor cases is exempt: no rendering of a run-time value
# can pass, and the counterpart of a wrong anchor is every correctly anchored case.
for (cat, sit), verdicts in sorted(situations.items()):
    if not verdicts & {'pass', 'mismatch'}:
        continue
    if 'pass' not in verdicts:
        errors.append(f'{cat}: situation {sit!r} has no pass case')
    if verdicts == {'pass'}:
        errors.append(f'{cat}: situation {sit!r} has no case other than pass')


def run_job(job):
    tool, where, regime, arg = job
    if tool == 'anchors':
        meta, path, slines, tlines, tfile, expect = arg
        try:
            problems = anchor_problems(meta, path, slines, tlines, tfile, regime)
        except RuntimeError:
            return None  # the compile job reports the error
        if expect == 'invalid-anchor' and not problems:
            return f'{where}: expect is invalid-anchor, but every anchor rule holds'
        if expect != 'invalid-anchor' and problems:
            return f'{where}: an anchor rule is broken, so expect must be invalid-anchor: {problems[0]}'
        return None
    define = ['-DFIXTURE_DP'] if regime == 'dp' else []
    with tempfile.TemporaryDirectory(prefix='avc-') as tmp:
        if tool == 'clang':
            cmd = ['clang', '-std=c17', '-fsyntax-only', '-x', 'c'] + define + [arg]
        else:
            cmd = ['gfortran', '-cpp', '-fsyntax-only', '-J', tmp] + define + [arg]
        p = subprocess.run(cmd, cwd=tmp, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        first = next((l for l in p.stdout.splitlines() if 'error' in l.lower()), p.stdout.strip()[:200])
        return f'{where}: {os.path.basename(arg)} does not compile with {tool} in regime {regime}: {first.strip()}'
    return None


with ThreadPoolExecutor(max_workers=min(4, os.cpu_count() or 1)) as pool:
    errors += [e for e in pool.map(run_job, jobs) if e]

for e in errors:
    print(f'not ok - {e}')
if errors:
    sys.exit(1)
ncomp = sum(1 for j in jobs if j[0] != 'anchors')
nexempt = sum(1 for v in situations.values() if not v & {'pass', 'mismatch'})
print(f'ok - {ncases} case(s) in {len(coverage)} categor{"y" if len(coverage) == 1 else "ies"} valid; '
      f'{len(situations)} situation(s), {len(situations) - nexempt} with a pass case and another, '
      f'{nexempt} of run-time values or wrong anchors only; '
      f'{ncomp} compilation(s) clean, anchors bound as the cases expect')
PY

validate() { python3 "$TMP/validate.py" "$1"; }

# ---- the corpus ---------------------------------------------------------------------------------
if out="$(validate "$CORPUS" 2>&1)"; then
	pass "corpus: ${out#ok - }"
else
	failt "the anchor-verifier case corpus is invalid" "$out"
fi

# ---- the validator rejects malformed cases --------------------------------------------------------
# good/cat/: a scalar pass and mismatch case (line 8 of source.F90 declares A; line 9 of target.c
# renders it), a designated initializer anchored field by field, a {0} context initializer with
# its module header anchor, and an anchor alone on the line below its declaration.
F_WP='#ifdef FIXTURE_DP
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(13, 300)
#else
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(6, 37)
#endif'
C_WP='#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif'
yaml_case() { # yaml_case FILE SLINE SNAME TFILE TLINE TNAME EXPECT-LINES... (situation: $SITUATION)
	local f="$1" sl="$2" sn="$3" tf="$4" tl="$5" tn="$6"
	shift 6
	{
		printf 'description: a case\n'
		printf 'situation: %s\n' "${SITUATION:-rendering}"
		printf 'source: {file: source.F90, line: %s, name: %s}\n' "$sl" "$sn"
		printf 'target: {file: %s, line: %s, name: %s}\n' "$tf" "$tl" "$tn"
		printf 'regimes: [dp, sp]\n'
		printf '%s\n' "$@"
		printf 'why: the value of %s\n' "$sn"
	} >"$f"
}
good_case() { # good_case DIR VALUE EXPECT-LINES...
	local d="$1" value="$2"
	shift 2
	mkdir -p "$d"
	printf 'MODULE MOD_A\n  IMPLICIT NONE\n%s\n  REAL(WP), PARAMETER :: A = 0.5_WP\nEND MODULE MOD_A\n' "$F_WP" >"$d/source.F90"
	printf '%s\n\nstatic const real_t a = CONST(%s); /* src: source.F90:8 = 0.5_WP */\n' "$C_WP" "$value" >"$d/target.c"
	yaml_case "$d/case.yaml" 8 A target.c 9 a "$@"
}
good_case "$TMP/good/cat/01-pass" 0.5 'expect: pass'
good_case "$TMP/good/cat/02-mismatch" 0.25 'expect: mismatch' 'mismatch: value'
d="$TMP/good/cat/03-designated"
mkdir -p "$d"
printf 'MODULE MOD_A\n  IMPLICIT NONE\n%s\n  TYPE :: T_A\n    INTEGER :: N = 6\n    REAL(WP) :: X = 1.5_WP\n  END TYPE T_A\nEND MODULE MOD_A\n' "$F_WP" >"$d/source.F90"
cat >"$d/target.h" <<EOF
$C_WP

typedef struct t_a {
	int n;
	real_t x;
} t_a;

#define T_A_INIT \\
	{ \\
		.n = 6, /* src: source.F90:9 = 6 */ \\
		.x = CONST(1.5) /* src: source.F90:10 = 1.5_WP */ \\
	}
EOF
yaml_case "$d/case.yaml" 8 T_A target.h 14 T_A_INIT 'expect: pass'
d="$TMP/good/cat/04-context"
mkdir -p "$d"
printf 'MODULE MOD_A\n  IMPLICIT NONE\n%s\n  REAL(WP), POINTER :: P => NULL()\nEND MODULE MOD_A\n' "$F_WP" >"$d/source.F90"
printf '%s\n\ntypedef struct mod_a_ctx {\n\treal_t *p;\n} mod_a_ctx;\n\n#define MOD_A_CTX_INIT {0} /* src: source.F90:1 (module MOD_A) */\n' "$C_WP" >"$d/target.h"
yaml_case "$d/case.yaml" 1 MOD_A target.h 13 MOD_A_CTX_INIT 'expect: pass'
d="$TMP/good/cat/05-below"
good_case "$d" 0.5 'expect: pass'
sed -i 's/A = 0.5_WP/A = 0.25_WP + 0.25_WP/' "$d/source.F90"
printf '%s\n\nstatic const real_t a = CONST(0.25) + CONST(0.25);\n/* src: source.F90:8 = 0.25_WP+0.25_WP */\n' "$C_WP" >"$d/target.c"
d="$TMP/good/cat/06-invalid"
SITUATION=anchor-form good_case "$d" 0.5 'expect: invalid-anchor'
sed -i 's/= 0.5_WP/= 0.25_WP/' "$d/target.c"
if out="$(validate "$TMP/good" 2>&1)"; then
	pass "a well-formed corpus is accepted"
else
	failt "the known-good corpus is rejected" "$out"
fi

# seeded LABEL REASON EDIT - copy the good corpus, apply EDIT (a shell snippet run inside the copy),
# and require the validator to reject it with REASON in its output.
n=0
seeded() {
	local label="$1" reason="$2" edit="$3" d out rc
	n=$((n + 1))
	d="$TMP/seeded-$n"
	cp -R "$TMP/good" "$d"
	(cd "$d/cat" && eval "$edit")
	set +e
	out="$(validate "$d" 2>&1)"
	rc=$?
	set -e
	if [[ "$rc" -eq 0 ]]; then
		failt "seeded: $label is accepted" "$out"
	elif ! grep -qF -- "$reason" <<<"$out"; then
		failt "seeded: $label is rejected, but not for '$reason'" "$out"
	fi
	pass "seeded: $label is rejected"
}
seeded "an unknown expect value" "expect is 'passes'" "sed -i 's/^expect: pass$/expect: passes/' 01-pass/case.yaml"
seeded "a mismatch kind on a pass case" "mismatch is only for expect: mismatch" "printf 'mismatch: value\n' >>01-pass/case.yaml"
seeded "a mismatch case without its kind" "expect: mismatch needs mismatch" "sed -i '/^mismatch:/d' 02-mismatch/case.yaml"
seeded "an unknown mismatch kind" "expect: mismatch needs mismatch" "sed -i 's/^mismatch: value$/mismatch: digits/' 02-mismatch/case.yaml"
seeded "a one-based or unbracketed at" "at is zero-based storage positions" "printf 'at: \"(1)\"\n' >>02-mismatch/case.yaml"
seeded "an unknown regime" "regimes must be" "sed -i 's/^regimes: .*/regimes: [dp, qp]/' 01-pass/case.yaml"
seeded "an unknown key" "unknown key 'notes'" "printf 'notes: x\n' >>01-pass/case.yaml"
seeded "a missing key" "missing key 'why'" "sed -i '/^why:/d' 01-pass/case.yaml"
seeded "a case.yaml that does not parse" "case.yaml does not parse" "printf 'why: [unclosed\n' >>01-pass/case.yaml"
seeded "a SOURCE line that does not name the constant" "source.F90:7 does not contain source.name 'A'" \
	"sed -i 's/line: 8, name: A/line: 7, name: A/' 01-pass/case.yaml"
seeded "a TARGET line that does not name the constant" "target.c:1 does not contain target.name 'a'" \
	"sed -i 's/line: 9, name: a/line: 1, name: a/' 01-pass/case.yaml"
seeded "a TARGET name in the wrong case" "does not contain target.name 'A'" \
	"sed -i 's/line: 9, name: a/line: 9, name: A/' 01-pass/case.yaml"
seeded "a line past the end of the file" "source.line 99 is past the end of source.F90" \
	"sed -i 's/line: 8, name: A/line: 99, name: A/' 01-pass/case.yaml"
seeded "a TARGET without its anchor" "no anchor binds to a" \
	"sed -i 's| /\\* src: .*\\*/||' 01-pass/target.c"
seeded "an anchor citing another line" "cites line 7, outside the SOURCE statement" \
	"sed -i 's/source.F90:8 =/source.F90:7 =/' 01-pass/target.c"
seeded "an anchor in another grammar" "is not the constant grammar" \
	"sed -i 's/source.F90:8 = /source.F90:8: /' 01-pass/target.c"
seeded "an anchor misquoting its literal" "the literal-as-read is not on source.F90:8" \
	"sed -i 's/= 0.5_WP/= 0.25_WP/' 01-pass/target.c"
seeded "an anchor quoting a literal without its kind suffix" "the literal-as-read cuts a token of source.F90:8" \
	"sed -i 's|= 0.5_WP \\*/|= 0.5 */|' 01-pass/target.c"
seeded "an anchor quoting a literal cut before its last digits" "the literal-as-read cuts a token of source.F90:8" \
	"sed -i 's/A = 0.5_WP/A = 0.55/' 01-pass/source.F90; sed -i 's|= 0.5_WP \\*/|= 0.5 */|' 01-pass/target.c"
seeded "an anchor quoting the tail of a longer literal" "the literal-as-read cuts a token of source.F90:8" \
	"sed -i 's/A = 0.5_WP/A = 10.5_WP/' 01-pass/source.F90"
seeded "an anchor quoting only an operator of the right-hand side" "is neither one literal of source.F90:8 nor the whole right-hand side" \
	"sed -i 's/A = 0.5_WP/A = 0.25_WP + 0.25_WP/' 01-pass/source.F90; sed -i 's|= 0.5_WP \\*/|= + */|' 01-pass/target.c"
seeded "an anchor quoting the leading part of the right-hand side" "is neither one literal of source.F90:8 nor the whole right-hand side" \
	"sed -i 's/A = 0.5_WP/A = 0.25_WP + 0.25_WP/' 01-pass/source.F90; sed -i 's|= 0.5_WP \\*/|= 0.25_WP + */|' 01-pass/target.c"
seeded "an anchor quoting a middle part of the right-hand side" "is neither one literal of source.F90:8 nor the whole right-hand side" \
	"sed -i 's/A = 0.5_WP/A = (0.25_WP + 0.25_WP)*2._WP/' 01-pass/source.F90; sed -i 's|= 0.5_WP \\*/|= 0.25_WP + 0.25_WP */|' 01-pass/target.c"
seeded "an anchor written twice" "is written twice" \
	"sed -i 's|\\(/\\* src: .*\\*/\\)|\\1 \\1|' 01-pass/target.c"
seeded "an anchor that opens without closing" "an anchor opens without closing on its line" \
	"sed -i 's|0.5_WP \\*/|0.5_WP\\n */|' 01-pass/target.c"
seeded "an anchor above its declaration" "no anchor binds to a" \
	"sed -i 's| \\(/\\* src: .*\\*/\\)||; s|^static const real_t a|/* src: source.F90:8 = 0.5_WP */\\nstatic const real_t a|' 01-pass/target.c; sed -i 's/line: 9, name: a/line: 10, name: a/' 01-pass/case.yaml"
seeded "an anchor below its declaration with another declaration after it" "no anchor binds to a" \
	"printf 'static const real_t b = CONST(0.5);\n' >>05-below/target.c"
seeded "a field anchor citing a line outside its type" "cites line 2, outside the SOURCE statement, type or module" \
	"sed -i 's/source.F90:10 = 1.5_WP/source.F90:2 = IMPLICIT/' 03-designated/target.h"
seeded "a module header anchor naming another module" "a module header anchor is only for <MODULE>_CTX_INIT" \
	"sed -i 's/(module MOD_A)/(module MOD_B)/' 04-context/target.h"
seeded "a module header anchor on a constant" "a module header anchor is only for <MODULE>_CTX_INIT" \
	"sed -i 's/source.F90:8 = 0.5_WP/source.F90:1 (module MOD_A)/' 01-pass/target.c"
seeded "an invalid-anchor case whose anchors obey every rule" "every anchor rule holds" \
	"sed -i 's/^expect: pass$/expect: invalid-anchor/' 01-pass/case.yaml"
seeded "a TARGET that does not compile" "target.c does not compile with clang in regime dp" \
	"sed -i 's/CONST(0.5);/CONST(0.5)/' 01-pass/target.c"
seeded "a TARGET that compiles in one regime only" "target.c does not compile with clang in regime sp" \
	"sed -i 's/^typedef float real_t;/typedef flaot real_t;/' 01-pass/target.c"
seeded "a SOURCE that does not compile" "source.F90 does not compile with gfortran in regime dp" \
	"sed -i 's/PARAMETER :: A/PARAMETR :: A/' 01-pass/source.F90"
seeded "a missing SOURCE file" "source.file source.F90 does not exist" "rm 01-pass/source.F90"
seeded "a stray file in a case" "unexpected file notes.txt" "touch 01-pass/notes.txt"
seeded "a case directory not numbered" "a case directory is <NN>-<short-slug>" "mv 01-pass pass"
seeded "a case without a situation" "missing key 'situation'" "sed -i '/^situation:/d' 01-pass/case.yaml"
seeded "a malformed situation" "situation is lowercase words joined by hyphens" \
	"sed -i 's/^situation: .*/situation: Lone Literal/' 01-pass/case.yaml"
seeded "a situation with a mismatch but no pass case" "situation 'lonely' has no pass case" \
	"sed -i 's/^situation: .*/situation: lonely/' 02-mismatch/case.yaml"
seeded "a situation whose cases all pass" "situation 'rendering' has no case other than pass" \
	"sed -i 's/^situation: .*/situation: lonely/' 02-mismatch/case.yaml"
seeded "a category without a pass case" "cat: no pass case" "rm -r 01-pass 03-designated 04-context 05-below"
seeded "a category with only pass cases" "cat: no case other than pass" "rm -r 02-mismatch 06-invalid"

# A missing compiler fails the validation; it never skips it.
mkdir -p "$TMP/bin"
ln -s "$(command -v python3)" "$TMP/bin/python3"
for tool in clang gfortran; do
	set +e
	out="$(PATH="$TMP/bin" python3 "$TMP/validate.py" "$TMP/good" 2>&1)"
	rc=$?
	set -e
	if [[ "$rc" -eq 0 ]] || ! grep -qF -- "$tool not found" <<<"$out"; then
		failt "a missing $tool does not fail the validation" "$out"
	fi
	pass "a missing $tool fails the validation"
	ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
