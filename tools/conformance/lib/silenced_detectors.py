#!/usr/bin/env python3
"""silenced_detectors.py - find what silences a detector in the product's C code.

Used by check-no-silenced-detectors.sh. Every file is parsed with libclang first
(lib/product_tu.py), so a file that does not parse cleanly is UNRELIABLE. Every file of the
product tree a unit includes is read too, also one the scan does not list (a `.inc`). Then four readings, each
from the compiler's own view of the code, never from a text search:

  1. Pragmas and attributes in each file's raw tokens (clang's lexer through
     lib/scan_guarded_macros.py): every `#pragma` directive, in every #if branch, every
     `_Pragma("...")` with a literal argument, and every suppressing attribute (below), also inside
     a macro definition. Comments and string literals are neither.
  2. Pragmas in the preprocessed token stream (`clang -E` with each file's compile arguments; the
     lines that belong to the checked files are tokenized by libclang): a pragma a macro produces
     is reported at the line that uses the macro.
  3. Attributes in the same preprocessed tokens: no_sanitize and its variants, and clang's
     suppress, in `__attribute__((...))` or `[[...]]`, reported at the line that carries them
     after macro expansion (also a GCC spelling clang does not implement, no_sanitize_undefined).
  4. Lint suppressions: NOLINT, NOLINTNEXTLINE, NOLINTBEGIN, NOLINTEND, as clang-tidy reads them -
     anywhere in the raw text of a line, followed by no other letter - so in a comment, a string
     literal or an identifier (`NOLINT_MARK`) alike.

Compiler flags (-w, -Wno-*) are not judged here: tools/build-checks/check-build-flags.py owns them.

A pragma suppresses when it is `GCC|clang diagnostic ignored|ignored_attributes|warning`
(`warning` turns an error back into a warning), whether or not a `push` frames it - a `push` or
`pop` alone silences nothing -, `GCC|clang system_header`, `warning(disable|suppress ...)`,
`warning(push, 0)`, `diag_suppress` / `nv_diag_suppress`, or a `clang attribute` pragma that
applies a suppressing attribute.

Allowed suppressions. AGENTS.md: "Suppression is allowed only when it is itself the correct semantic
choice, stated in a comment at the site." The product carries no workbench reference, so the
permission lives in the workbench: a suppression is GREEN only when the registry
(port/conventions/allowed-suppressions.yaml, `--registry`) has an entry with its file (relative to
the product root) and its exact text (as the report quotes it), the number found in that file
equals the entry's `count` (one registration cannot cover a copy), the entry's `exception` is an ID
in the charter's section 4 table (`--charter`, port/plan/00-charter.md), and a comment on the
suppression's line or the line above gives a reason (any text besides a NOLINT directive; what it
says is the human's to judge). An entry that matches nothing is RED (stale). A malformed or
unreadable registry, or an unreadable charter, is UNRELIABLE. Without a registry, every
suppression is RED.

Usage:
  silenced_detectors.py [--root DIR] [--registry FILE] [--charter FILE] -- FILE...

Output (stdout, tab-separated, one line per finding):
  FAIL\t<file>:<line>\t<description>       a suppression the registry does not allow
  ALLOW\t<file>:<line>\t<description>      a suppression the registry allows
  REGISTRY\t<registry>\t<description>      a registry entry that matches nothing

Exit codes:
  0  ran to completion (the findings above, possibly none)
  2  UNRELIABLE: a file does not parse cleanly, cannot be read or preprocessed, or libclang / the
     clang driver is unavailable
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import product_tu  # noqa: E402
import scan_guarded_macros as sgm  # noqa: E402

SUPPRESSING_ATTRS = {
    'no_sanitize', 'no_sanitize_address', 'no_address_safety_analysis', 'no_sanitize_thread',
    'no_sanitize_memory', 'no_sanitize_undefined', 'no_sanitize_coverage',
    'disable_sanitizer_instrumentation', 'suppress',
}
NOLINT_RE = re.compile(r'NOLINT(?:NEXTLINE|BEGIN|END)?(?![A-Za-z])(?:\([^)\n]*\))?')
WORD_RE = re.compile(r'"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|\S')


def _attr_name(word):
    return word[2:-2] if word.startswith('__') and word.endswith('__') and len(word) > 4 else word


def pragma_suppresses(words):
    """Whether a pragma with these tokens (after `pragma`) silences a detector."""
    w = list(words)
    if len(w) >= 3 and w[0] in ('GCC', 'clang') and w[1] == 'diagnostic' \
            and w[2] in ('ignored', 'ignored_attributes', 'warning'):
        return True
    if len(w) >= 2 and w[0] in ('GCC', 'clang') and w[1] == 'system_header':
        return True
    if len(w) >= 3 and w[0] == 'warning' and w[1] == '(' and w[2] in ('disable', 'suppress'):
        return True
    if len(w) >= 5 and w[0] == 'warning' and w[1] == '(' and w[2] == 'push' and w[3] == ',' and w[4] == '0':
        return True  # MSVC: push at warning level 0, every warning off
    if w and w[0] in ('diag_suppress', 'nv_diag_suppress'):
        return True  # EDG / NVHPC
    if len(w) >= 2 and w[0] == 'clang' and w[1] == 'attribute':
        return any(_attr_name(x) in SUPPRESSING_ATTRS for x in w[2:])
    return False


def destringize(literal):
    """The text a _Pragma string literal stands for (C17 6.10.9)."""
    s = literal[1:] if literal[:1] in 'LuU' else literal
    s = s[2:] if s.startswith('8"') else s
    if len(s) < 2 or s[0] != '"' or s[-1] != '"':
        return None
    return s[1:-1].replace('\\"', '"').replace('\\\\', '\\')


def _unescape_marker(name):
    name = re.sub(r'\\([0-7]{1,3})', lambda m: chr(int(m.group(1), 8)), name)
    return name.replace('\\"', '"').replace('\\\\', '\\')


def attributes(toks):
    """[(where, name, text)] for every attribute in `__attribute__((...))` and `[[...]]` of a token
    list [(spelling, where)]; `name` without a vendor namespace or surrounding underscores."""
    out = []
    n = len(toks)

    def items(j, close):
        """Split the tokens from j up to the bracket that closes depth 0 by top-level commas."""
        depth, cur, groups = 0, [], []
        while j < n:
            t = toks[j][0]
            if t in ('(', '[', '{'):
                depth += 1
            elif t in (')', ']', '}'):
                if depth == 0 and t == close:
                    break
                depth -= 1
            if t == ',' and depth == 0:
                groups.append(cur)
                cur = []
            else:
                cur.append(toks[j])
            j += 1
        groups.append(cur)
        return groups, j

    i = 0
    while i < n:
        sp = toks[i][0]
        groups = None
        if sp in ('__attribute__', '__attribute') and i + 2 < n and toks[i + 1][0] == '(' and toks[i + 2][0] == '(':
            groups, i = items(i + 3, ')')
        elif sp == '[' and i + 1 < n and toks[i + 1][0] == '[':
            groups, i = items(i + 2, ']')
        if groups:
            for g in groups:
                if not g:
                    continue
                k = 2 if len(g) >= 3 and g[1][0] == '::' else 0
                out.append((g[k][1], _attr_name(g[k][0]), ''.join(t[0] for t in g)))
        i += 1
    return out


def raw_scan(real, plan, payload):
    """Worker: (findings [(real, line, kind, key, text, suffix)] in one file's raw tokens, the file's
    comments [(first line, last line, text)])."""
    shown = payload['given'].get(real, real)
    try:
        toks = sgm._parse_raw_tokens(real)
    except RuntimeError as exc:
        raise product_tu.Unreliable(str(exc))
    found, comments = [], []
    for t in toks:
        if t['type'] == 'unknown':
            raise product_tu.Unreliable(f"{shown}:{t['line']}: an unterminated comment")
        if t['type'] == 'comment':
            first = int(t['line'])
            comments.append((first, first + len(re.findall(r'\r\n|\r|\n', t['spelling'])), t['spelling']))
        if t['type'] in ('comment', 'literal', 'raw_identifier'):
            m = NOLINT_RE.search(t['spelling'])
            if m:
                text = ' '.join(t['spelling'].split())
                what = 'identifier' if t['type'] == 'raw_identifier' else t['type']
                found.append((real, int(t['line']), 'lint', text, m.group(0), f" in {what} '{text[:80]}'"))
    for start, end in sgm._spans(toks):
        i = sgm._first_significant(toks, start, end)
        if i is None or toks[i]['type'] != 'hash':
            continue
        k = sgm._first_significant(toks, i + 1, end)
        if k is None or toks[k]['spelling'] != 'pragma':
            continue
        words = [t['spelling'] for t in toks[k + 1:end] if t['type'] != 'comment']
        if pragma_suppresses(words):
            found.append((real, int(toks[i]['line']), 'pragma', tuple(words), '#pragma ' + ' '.join(words), ''))
    sig = [t for t in toks if t['type'] != 'comment']
    for n, t in enumerate(sig):
        if t['spelling'] != '_Pragma' or n + 3 >= len(sig):
            continue
        # _Pragma("..."): a literal argument can be judged here; one the preprocessor builds
        # (_Pragma(#x)) is judged where it is used, in the preprocessed stream.
        if sig[n + 1]['spelling'] == '(' and sig[n + 2]['type'] == 'literal' and sig[n + 3]['spelling'] == ')':
            text = destringize(sig[n + 2]['spelling'])
            if text is None:
                continue
            words = WORD_RE.findall(text)
            if pragma_suppresses(words):
                found.append((real, int(t['line']), 'pragma', tuple(words), f"_Pragma({sig[n + 2]['spelling']})", ''))
    # Attributes as written, in every #if branch and in macro definitions (a guarded
    # `#define NO_ASAN __attribute__((no_sanitize_address))` silences the build that defines it).
    for line, name, text in attributes([(t['spelling'], int(t['line'])) for t in sig]):
        if name in SUPPRESSING_ATTRS:
            found.append((real, line, 'attribute', name, text, ''))
    return found, comments


_MARKER = re.compile(rb'^# (\d+) "((?:[^"\\]|\\.)*)"')


def unit_scan(unit, plan, payload):
    """Worker: (findings [(real, line, kind, key, text, suffix)] in the preprocessed token stream of
    one parsed unit, the files of the product tree it includes that were not given). Only the lines
    of the checked files and of those are tokenized."""
    ci = product_tu.cindex()
    given, wanted = payload['given'], {}

    def checked(real):
        """A file checked, or any file of the product tree the unit includes (a .inc, say)."""
        if real not in wanted:
            wanted[real] = real is not None and (real in given or product_tu.in_product(real, plan))
        return wanted[real]

    try:
        p = subprocess.run(['clang', '-E'] + unit.args + [unit.path], cwd=unit.directory, capture_output=True)
    except OSError as exc:
        raise product_tu.Unreliable(f"cannot run the clang driver to preprocess '{unit.path}': {exc}")
    if p.returncode != 0:
        err = p.stderr.decode('utf-8', 'replace')
        first = next((ln for ln in err.splitlines() if 'error' in ln), err.strip()[:300])
        raise product_tu.Unreliable(f"clang -E could not preprocess '{unit.path}': {first}")
    # Line markers (`# N "file" flags`: the next line is line N of file) give each line its place.
    keep, where = [b'#if 0'], [None]
    cur, nxt = None, 0
    for ln in p.stdout.split(b'\n'):
        m = _MARKER.match(ln)
        if m:
            name = _unescape_marker(m.group(2).decode('utf-8', 'surrogateescape'))
            cur, nxt = unit.real(name), int(m.group(1))
            continue
        if checked(cur) and ln.strip():
            keep.append(ln)
            where.append((cur, nxt))
        nxt += 1
    found = []
    extras = sorted(r for r in unit.includes() if r not in given and checked(r))
    if len(keep) == 1:
        return found, extras
    keep.append(b'#endif')
    text = b'\n'.join(keep) + b'\n'
    name = unit.path + '.chisel-preprocessed.i'
    # The kept lines, wrapped in `#if 0` so the parse skips them; libclang's lexer still tokenizes them.
    try:
        tu = ci.Index.create().parse(name, args=['-x', 'cpp-output'], unsaved_files=[(name, text)])
        f = tu.get_file(name)
        rng = ci.SourceRange.from_locations(ci.SourceLocation.from_offset(tu, f, 0),
                                            ci.SourceLocation.from_offset(tu, f, len(text)))
        toks = [(text[t.extent.start.offset:t.extent.end.offset].decode('utf-8', 'surrogateescape'),
                 t.location.line) for t in tu.get_tokens(extent=rng)]
    except Exception as exc:
        raise product_tu.Unreliable(f"libclang could not tokenize the preprocessed '{unit.path}': {exc}")
    lines = {}
    for sp, ln in toks:
        lines.setdefault(ln, []).append(sp)
    for ln, words in lines.items():
        if ln - 1 < len(where) and where[ln - 1] and len(words) >= 2 and words[0] == '#' and words[1] == 'pragma':
            real, line = where[ln - 1]
            if pragma_suppresses(words[2:]):
                found.append((real, line, 'pragma', tuple(words[2:]), '#pragma ' + ' '.join(words[2:]),
                              ' (produced by a macro)'))
    placed = [(sp, where[ln - 1]) for sp, ln in toks if ln - 1 < len(where) and where[ln - 1]]
    for (real, line), name, text in attributes(placed):
        if name in SUPPRESSING_ATTRS:
            found.append((real, line, 'attribute', name, text, ''))
    return found, extras


LABEL = {'pragma': 'pragma', 'attribute': 'attribute', 'lint': 'lint suppression'}


def scan(files, root):
    """(findings [(real, line, text, description)], {real: comments})."""
    given = {}
    for f in files:
        given.setdefault(os.path.realpath(f), f)
    plan = product_tu.make_plan(files, root)
    payload = {'given': given}
    with product_tu.Pool() as pool:
        units = pool.run(plan, unit_scan, payload)
        extras = sorted({r for _p, (_f, ex) in units for r in ex})
        files_read = list(given) + extras
        raw = pool.map(raw_scan, files_read, plan, payload)
    comments = {real: c for real, (_f, c) in zip(files_read, raw)}
    seen, findings = set(), []
    # Raw findings first: a pragma the preprocessed stream shows at a line the file itself spells
    # is reported as written, and only one no raw token spells is "produced by a macro".
    for batch in [f for f, _c in raw] + [f for _p, (f, _ex) in units]:
        for real, line, kind, key, text, suffix in batch:
            k = (real, line, kind, key)
            if k in seen:
                continue
            seen.add(k)
            findings.append((real, line, text, f"{LABEL[kind]} '{text}'{suffix}"))
    return given, findings, comments


# ---- the suppressions a port allows: named exceptions, registered, stated at the site -----------

def load_registry(path):
    """[(file, suppression, count, exception)] from port/conventions/allowed-suppressions.yaml, read
    with the strict loader (a repeated key is an error, every scalar is text). Anything malformed
    raises Unreliable."""
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'coordination'))
    try:
        import yaml
    except Exception:
        raise product_tu.Unreliable(f"cannot read the suppression registry '{path}': PyYAML is not available")
    try:
        from _chisel_lib import text_loader
    except Exception as exc:
        raise product_tu.Unreliable(f"cannot read the suppression registry '{path}': the strict YAML loader "
                                    f"(tools/coordination/_chisel_lib.py) is not available: {exc}")
    try:
        with open(path, encoding='utf-8') as fh:
            data = yaml.load(fh, Loader=text_loader(yaml))
    except OSError as exc:
        raise product_tu.Unreliable(f"cannot read the suppression registry '{path}': {exc.strerror or exc}")
    except Exception as exc:
        raise product_tu.Unreliable(f"the suppression registry '{path}' is not valid YAML ({' '.join(str(exc).split())})")
    if not isinstance(data, dict) or set(data) != {'suppressions'} or not isinstance(data['suppressions'], list):
        raise product_tu.Unreliable(f"the suppression registry '{path}' must be a mapping with one key, "
                                    f"`suppressions`, holding a list")
    out, keys = [], set()
    for n, e in enumerate(data['suppressions'], 1):
        where = f"the suppression registry '{path}', entry {n}"
        if not isinstance(e, dict) or set(e) != {'file', 'suppression', 'count', 'exception'}:
            raise product_tu.Unreliable(f"{where} must be a mapping of exactly file, suppression, count, exception")
        for k in ('file', 'suppression', 'exception'):
            if not isinstance(e[k], str) or not e[k].strip():
                raise product_tu.Unreliable(f"{where}: `{k}` must be a non-empty text")
        if not isinstance(e['count'], str) or not re.fullmatch(r'[1-9][0-9]*', e['count']):
            raise product_tu.Unreliable(f"{where}: `count` must be a whole number of 1 or more")
        f = os.path.normpath(e['file'])
        if os.path.isabs(f) or f == '..' or f.startswith('..' + os.sep):
            raise product_tu.Unreliable(f"{where}: `file` must be a path inside the product, relative to its root")
        key = (f, e['suppression'])
        if key in keys:
            raise product_tu.Unreliable(f"{where} registers '{e['suppression']}' in {f} a second time")
        keys.add(key)
        out.append((f, e['suppression'], int(e['count']), e['exception'].strip()))
    return out


def charter_ids(path):
    """The IDs of the named exceptions in the charter's section 4 table (its `ID` column), or None
    when there is no charter. An unreadable charter raises Unreliable."""
    if not os.path.lexists(path):
        return None
    try:
        with open(path, encoding='utf-8') as fh:
            lines = fh.read().splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise product_tu.Unreliable(f"cannot read the charter '{path}': {exc}")
    ids, in4, col = set(), False, None
    for ln in lines:
        if re.match(r'#{1,6}\s', ln):
            if in4:
                break
            in4 = re.match(r'#{1,6}\s+4[.)]?\s', ln) is not None
            continue
        if not in4 or not ln.strip().startswith('|'):
            continue
        cells = [c.strip().strip('`').strip() for c in ln.strip().strip('|').split('|')]
        if col is None:
            col = next((k for k, c in enumerate(cells) if c.upper() == 'ID'), -1)
            continue
        if col < 0 or col >= len(cells) or all(re.fullmatch(r':?-+:?', c) for c in cells if c):
            continue
        c = cells[col]
        if c and not c.startswith(('(', '<')) and c not in ('...', '-'):
            ids.add(c)
    return ids


def _reason_in(comment):
    """Whether a comment says something besides a NOLINT directive (a word: a letter or digit)."""
    text = NOLINT_RE.sub('', comment)
    text = re.sub(r'^\s*(?://|/\*)|\*/\s*$', '', text)
    return re.search(r'[A-Za-z0-9]', text) is not None


def apply_policy(given, findings, comments, registry, charter, base):
    """[(tag, where, line or None, description)]: tag FAIL, or ALLOW for a suppression registered as
    a charter named exception, counted exactly, and explained in a comment at its site."""
    shown = lambda real: given.get(real, real)  # noqa: E731
    if registry is None:
        return [('FAIL', shown(r), line, desc) for r, line, _t, desc in findings]
    entries = load_registry(registry)
    ids = charter_ids(charter)
    base = os.path.realpath(base)
    rel = lambda real: os.path.normpath(os.path.relpath(real, base))  # noqa: E731
    found = {}
    for f in findings:
        found.setdefault((rel(f[0]), f[2]), []).append(f)
    by_key = {(e[0], e[1]): e for e in entries}
    out = []
    for real, line, text, desc in findings:
        e = by_key.get((rel(real), text))
        if e is None:
            out.append(('FAIL', shown(real), line, f"{desc} - not registered in '{registry}'"))
            continue
        _f, _s, count, exception = e
        n = len(found[(e[0], e[1])])
        problems = []
        if n != count:
            problems.append(f"registered for {count} in this file, found {n}")
        if ids is None:
            problems.append(f"its exception {exception}: there is no charter '{charter}'")
        elif exception not in ids:
            problems.append(f"its exception {exception} is not in the charter's section 4 table")
        near = [c for first, last, c in comments.get(real, []) if first <= line <= last or last == line - 1]
        if not any(_reason_in(c) for c in near):
            problems.append('no comment at the site (on its line or the line above) gives the reason')
        if problems:
            out.append(('FAIL', shown(real), line, f"{desc} - {'; '.join(problems)}"))
        else:
            out.append(('ALLOW', shown(real), line, f"{desc} (named exception {exception})"))
    for f, text, _count, exception in entries:
        if (f, text) not in found:
            out.append(('REGISTRY', registry, None,
                        f"the entry for '{text}' in {f} ({exception}) matches no suppression - remove it (stale)"))
    return out


def main(argv):
    opts = {'--root': None, '--registry': None, '--charter': None}
    while argv and argv[0] in opts and len(argv) > 1:
        opts[argv[0]], argv = argv[1] or None, argv[2:]
    if argv[:1] != ['--'] or len(argv) < 2:
        sys.stderr.write('usage: silenced_detectors.py [--root DIR] [--registry FILE] [--charter FILE] -- FILE...\n')
        return 2
    sys.stdout.reconfigure(errors='backslashreplace')
    root = opts['--root']
    try:
        product_tu.cindex()
        given, findings, comments = scan(argv[1:], root)
        records = apply_policy(given, findings, comments, opts['--registry'], opts['--charter'],
                               root or os.getcwd())
    except product_tu.Unreliable as exc:
        sys.stderr.write(f'silenced_detectors: {exc}\n')
        return 2
    for tag, where, line, desc in sorted(records, key=lambda r: (r[1], r[2] or 0)):
        print(f"{tag}\t{where}{'' if line is None else f':{line}'}\t{desc}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
