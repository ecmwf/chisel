"""anchor_binding - the anchor grammar and binding rules of a TARGET file against its SOURCE.

Shared by the anchor-verifier case corpus validator (tools/tests/test-verify-anchors-cases.sh) and the
value-comparing anchor verifier. The rules are those of the corpus README
(tools/conformance/seeded-bugs/verify-anchors/README.md, "Anchor grammar and binding"):

- `Regime` is one build of the pair: what each compiler is given (the corpus has two, `dp` and `sp`);
- `target_decls` lists the TARGET's declarations and #defines with their extents;
- `bind` decides which declaration an anchor on a line binds to;
- `anchor_problems` returns the anchor rules a SOURCE/TARGET pair breaks (empty when all hold);
- the remaining helpers read the SOURCE's free-form statements, scopes, literals and right-hand sides.
"""
import os
import re
import subprocess
from dataclasses import dataclass

IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
ANCHOR = re.compile(r'/\*\s*src:\s*(?P<path>[^:\s]+):(?P<line>[0-9]+)(?P<rest>.*?)\s*\*/')
TYPE_HDR = re.compile(r'\s*TYPE\s*(?:,[^:]*)?(?:::)?\s*([A-Za-z_]\w*)\s*$', re.I)
TYPE_END = re.compile(r'\s*END\s*TYPE\b', re.I)
TYPE_COMP = re.compile(r'\s*TYPE\s*\(\s*([A-Za-z_]\w*)\s*\)', re.I)
MODULE_HDR = re.compile(r'\s*MODULE\s+([A-Za-z_]\w*)\s*$', re.I)
MODULE_END = re.compile(r'\s*END\s*MODULE\b', re.I)
F_TOKEN = re.compile(r'(?:[0-9]+\.[0-9]*|\.[0-9]+|[0-9]+)(?:[EeDd][+-]?[0-9]+)?(?:_[A-Za-z0-9_]+)?'
                     r'|\.(?:TRUE|FALSE)\.(?:_[A-Za-z0-9_]+)?|\.[A-Za-z]+\.|[A-Za-z][A-Za-z0-9_]*'
                     r'|\'[^\']*\'|"[^"]*"|\*\*|//|=>|==|/=|<=|>=|\S', re.I)


@dataclass(frozen=True)
class Regime:
    """One build of a SOURCE/TARGET pair, as each compiler receives it on top of the verifier's fixed
    flags: `fflags` for gfortran (defines, -I of module directories, a promote-real flag), `cflags`
    for clang (defines, include directories), `fsources` the SOURCE files compiled before the cited
    one - the modules it USEs, in dependency order - and `ldflags` for linking the probes."""
    name: str
    fflags: tuple = ()
    cflags: tuple = ()
    fsources: tuple = ()
    ldflags: tuple = ()


# The corpus's two regimes (seeded-bugs/verify-anchors/README.md, "Regimes").
CORPUS_REGIMES = {'dp': Regime('dp', fflags=('-DFIXTURE_DP',), cflags=('-DFIXTURE_DP',)), 'sp': Regime('sp')}


def regime_of(regime):
    """A Regime, given one or the name of a corpus regime."""
    if isinstance(regime, Regime):
        return regime
    if regime in CORPUS_REGIMES:
        return CORPUS_REGIMES[regime]
    raise RuntimeError(f'unknown regime {regime!r}')


def word_in(ident, line, fold):
    return re.search(r'(?<![A-Za-z0-9_])' + re.escape(ident) + r'(?![A-Za-z0-9_])', line,
                     re.I if fold else 0) is not None


def read_lines(path):
    lines = open(path, encoding='utf-8').read().split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    return lines



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
_RESOURCE = []


def _resource_args():
    """libclang does not add clang's resource directory (stddef.h, stdbool.h) as the driver does."""
    if not _RESOURCE:
        p = subprocess.run(['clang', '-print-resource-dir'], capture_output=True, text=True)
        if p.returncode != 0 or not p.stdout.strip():
            raise RuntimeError('clang -print-resource-dir failed: the clang driver is needed')
        _RESOURCE.append('-resource-dir=' + p.stdout.strip())
    return _RESOURCE


def target_decls(path, text, regime):
    """[(name, first line, name line, last line)]: the objects, enumerators, functions and macro
    definitions of the file, with their extents, as clang reads it in this regime (libclang's
    cursors; a #define in an inactive #if branch is not one). `text` is unused and kept for callers."""
    import clang.cindex as ci
    tu = ci.Index.create().parse(path, args=['-x', 'c', '-std=c17'] + _resource_args() + list(regime_of(regime).cflags),
                                 options=ci.TranslationUnit.PARSE_DETAILED_PROCESSING_RECORD)
    errors = [str(d) for d in tu.diagnostics if d.severity >= ci.Diagnostic.Error]
    if errors:
        raise RuntimeError('clang cannot read the declarations: ' + errors[0])
    real = os.path.realpath(path)
    kinds = {ci.CursorKind.VAR_DECL, ci.CursorKind.ENUM_CONSTANT_DECL, ci.CursorKind.FUNCTION_DECL,
             ci.CursorKind.MACRO_DEFINITION}
    decls = []
    for c in tu.cursor.walk_preorder():
        if c.kind not in kinds or not c.spelling:
            continue
        f = c.location.file
        if f is None or os.path.realpath(f.name) != real:
            continue
        decls.append((c.spelling, c.extent.start.line, c.location.line, c.extent.end.line))
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


F_LABEL = re.compile(r'\s*[0-9]{1,5}\s+')


def top_level_marks(text):
    """The positions of the characters of text outside character context and outside parentheses
    and brackets, up to a '!' comment."""
    out, quote, depth = [], None, 0
    for i, ch in enumerate(text):
        if quote:
            quote = None if ch == quote else quote
        elif ch in '\'"':
            quote = ch
        elif ch == '!':
            break
        elif ch in '([':
            depth += 1
        elif ch in ')]':
            depth -= 1
        elif depth == 0:
            out.append(i)
    return out


def data_statement(stmt):
    """(text, slashes) when stmt is a DATA statement - the statement without its label and the
    positions of its '/' outside quotes and parentheses - else None. After an optional statement
    label, DATA is the keyword when a name or a parenthesized implied DO follows it and no '='
    outside quotes and parentheses comes before the first such '/'; otherwise DATA names a variable
    (`DATA = 1`, `DATA(I) = 2`, `DATA = A / B`)."""
    m = F_LABEL.match(stmt)
    body = stmt[m.end():] if m else stmt.lstrip()
    if not re.match(r'DATA(?:\s+[A-Za-z_]|\s*\()', body, re.I):
        return None
    marks = [i for i in top_level_marks(body) if body[i] in '=/']
    if marks and body[marks[0]] == '=':
        return None
    return body, [i for i in marks if body[i] == '/']


def statement_rhs(stmt):
    """The right-hand sides a SOURCE statement gives: the value of each initialized entity of a
    declaration (after ::, a pointer default after =>), the value of an assignment, or the value
    list of each /.../ set of a DATA statement."""
    data = data_statement(stmt)
    if data:
        body, slashes = data
        return [body[a + 1:b] for a, b in zip(slashes[::2], slashes[1::2])]
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


def outside_strings(line):
    """The characters of a SOURCE line outside character context, up to a '!' comment."""
    out, quote = '', None
    for ch in line:
        if quote:
            quote = None if ch == quote else quote
        elif ch in '\'"':
            quote = ch
        elif ch == '!':
            break
        else:
            out += ch
    return out


def citation_format(slines, cited):
    """Format errors of the cited SOURCE lines: a cited line holds exactly one statement (no ';'
    separator; a statement continued with '&' is one statement over its lines), and a cited DATA
    statement (as data_statement recognizes it) holds exactly one /.../ value list."""
    stmts, out = f_statements(slines), []
    for n in sorted(cited):
        for first, last, text in stmts:
            if first <= n <= last:
                if any(';' in outside_strings(slines[k - 1]) for k in range(first, last + 1)):
                    out.append(f'source.F90:{n} holds more than one statement (a ";" separator); '
                               f'a cited line holds exactly one statement')
                data = data_statement(text)
                if data and len(data[1]) != 2:
                    out.append(f'source.F90:{n} is a DATA statement with more than one /.../ set; '
                               f'a cited DATA statement holds exactly one set')
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
