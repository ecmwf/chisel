#!/usr/bin/env python3
"""silenced_detectors.py - find what silences a detector in the product's C code.

Used by check-no-silenced-detectors.sh. Every file is parsed with libclang first
(lib/product_tu.py), so a file that does not parse cleanly is UNRELIABLE. Every file of the
product tree a unit includes is read too, also one the scan does not list (a `.inc`). Then four readings, each
from the compiler's own view of the code, never from a text search:

  1. Pragmas in each file's raw tokens (clang's lexer through lib/scan_guarded_macros.py):
     every `#pragma` directive, in every #if branch, and every `_Pragma("...")` with a literal
     argument, also inside a macro definition. Comments and string literals are not pragmas.
  2. Pragmas in the preprocessed token stream (`clang -E` with each file's compile arguments; the
     lines that belong to the checked files are tokenized by libclang): a pragma a macro produces
     is reported at the line that uses the macro.
  3. Attributes in the same preprocessed tokens: no_sanitize and its variants, and clang's
     suppress, in `__attribute__((...))` or `[[...]]`, reported at the line that carries them
     after macro expansion (also a GCC spelling clang does not implement, no_sanitize_undefined).
  4. Lint suppressions in comment and string tokens: NOLINT, NOLINTNEXTLINE, NOLINTBEGIN,
     NOLINTEND, as clang-tidy reads them (anywhere in the text, followed by no other letter).

Compiler flags (-w, -Wno-*) are not judged here: tools/build-checks/check-build-flags.py owns them.

A pragma suppresses when it is `GCC|clang diagnostic ignored|ignored_attributes|warning|push`
(`push` frames an ignore region; `warning` turns an error back into a warning),
`GCC|clang system_header`, `warning(disable|suppress ...)`, or a `clang attribute` pragma that
applies a suppressing attribute.

Usage:
  silenced_detectors.py [--root DIR] -- FILE...

Output (stdout, tab-separated, one line per finding):
  FAIL\t<file>:<line>\t<description>

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
NOLINT_RE = re.compile(r'NOLINT(?:NEXTLINE|BEGIN|END)?(?![A-Za-z])')
WORD_RE = re.compile(r'"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|\S')


def _attr_name(word):
    return word[2:-2] if word.startswith('__') and word.endswith('__') and len(word) > 4 else word


def pragma_suppresses(words):
    """Whether a pragma with these tokens (after `pragma`) silences a detector."""
    w = list(words)
    if len(w) >= 3 and w[0] in ('GCC', 'clang') and w[1] == 'diagnostic' \
            and w[2] in ('ignored', 'ignored_attributes', 'warning', 'push'):
        return True
    if len(w) >= 2 and w[0] in ('GCC', 'clang') and w[1] == 'system_header':
        return True
    if len(w) >= 3 and w[0] == 'warning' and w[1] == '(' and w[2] in ('disable', 'suppress'):
        return True
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
    """Worker: findings [(real, line, kind, key, description)] in one file's raw tokens."""
    shown = payload['given'].get(real, real)
    try:
        toks = sgm._parse_raw_tokens(real)
    except RuntimeError as exc:
        raise product_tu.Unreliable(str(exc))
    found = []
    for t in toks:
        if t['type'] == 'unknown':
            raise product_tu.Unreliable(f"{shown}:{t['line']}: an unterminated comment")
        if t['type'] in ('comment', 'literal'):
            m = NOLINT_RE.search(t['spelling'])
            if m:
                text = ' '.join(t['spelling'].split())
                found.append((real, int(t['line']), 'lint', text,
                              f"lint suppression '{m.group(0)}' in {t['type']} '{text[:80]}'"))
    for start, end in sgm._spans(toks):
        i = sgm._first_significant(toks, start, end)
        if i is None or toks[i]['type'] != 'hash':
            continue
        k = sgm._first_significant(toks, i + 1, end)
        if k is None or toks[k]['spelling'] != 'pragma':
            continue
        words = [t['spelling'] for t in toks[k + 1:end] if t['type'] != 'comment']
        if pragma_suppresses(words):
            found.append((real, int(toks[i]['line']), 'pragma', tuple(words), f"pragma '#pragma {' '.join(words)}'"))
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
                found.append((real, int(t['line']), 'pragma', tuple(words),
                              f"pragma '_Pragma({sig[n + 2]['spelling']})'"))
    return found


_MARKER = re.compile(rb'^# (\d+) "((?:[^"\\]|\\.)*)"')


def unit_scan(unit, plan, payload):
    """Worker: (findings [(real, line, kind, key, description)] in the preprocessed token stream of
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
                found.append((real, line, 'pragma', tuple(words[2:]),
                              f"pragma '#pragma {' '.join(words[2:])}' (produced by a macro)"))
    placed = [(sp, where[ln - 1]) for sp, ln in toks if ln - 1 < len(where) and where[ln - 1]]
    for (real, line), name, text in attributes(placed):
        if name in SUPPRESSING_ATTRS:
            found.append((real, line, 'attribute', name, f"attribute '{text}'"))
    return found, extras


def scan(files, root):
    """[(where, line or None, description)]."""
    given = {}
    for f in files:
        given.setdefault(os.path.realpath(f), f)
    plan = product_tu.make_plan(files, root)
    payload = {'given': given}
    with product_tu.Pool() as pool:
        units = pool.run(plan, unit_scan, payload)
        extras = sorted({r for _p, (_f, ex) in units for r in ex})
        raw = pool.map(raw_scan, list(given) + extras, plan, payload)
    seen, findings = set(), []
    # Raw findings first: a pragma the preprocessed stream shows at a line the file itself spells
    # is reported as written, and only one no raw token spells is "produced by a macro".
    for batch in raw + [f for _p, (f, _ex) in units]:
        for real, line, kind, key, desc in batch:
            k = (real, line, kind, key)
            if k in seen:
                continue
            seen.add(k)
            findings.append((given.get(real, real), line, desc))
    return findings


def main(argv):
    root = None
    if argv[:1] == ['--root'] and len(argv) > 1:
        root, argv = argv[1] or None, argv[2:]
    if argv[:1] != ['--'] or len(argv) < 2:
        sys.stderr.write('usage: silenced_detectors.py [--root DIR] -- FILE...\n')
        return 2
    sys.stdout.reconfigure(errors='backslashreplace')
    try:
        product_tu.cindex()
        findings = scan(argv[1:], root)
    except product_tu.Unreliable as exc:
        sys.stderr.write(f'silenced_detectors: {exc}\n')
        return 2
    for where, line, desc in sorted(findings, key=lambda f: (f[0], f[1] or 0)):
        print(f"FAIL\t{where}{'' if line is None else f':{line}'}\t{desc}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
