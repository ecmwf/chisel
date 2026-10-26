#!/usr/bin/env python3
"""migrate-anchor-grammar.py - rewrite constant anchors to quote a SOURCE literal whole.

A constant anchor `/* src: <path>:<line> = <literal-as-read> */` quotes one literal of the cited
SOURCE line whole - with its exponent and kind suffix - or the whole right-hand side of its
statement (tools/conformance/seeded-bugs/verify-anchors/README.md, "Anchor grammar and binding").
An anchor written to the earlier rule, which only asked that the cited line contain the quoted
text, may quote a literal without its tail: `= 0.1` where the line has `0.1_WP`. This script finds
such anchors in a product tree and rewrites the quoted literal to the whole token of the line:

- a quoted literal that is a token of the line minus its kind suffix or exponent (`0.1` of
  `0.1_WP`, `1.E3` of `1.E3_WP`, `2.` of `2._WP`, `1.0` of `1.0D0`) becomes that token, when the
  line holds exactly one such token text;
- an anchor that already holds (one literal whole, or the whole right-hand side) is left alone;
- every other constant anchor that breaks the rule is reported, never guessed: two candidate
  tokens, a quote that cuts a token elsewhere (`1` of `10`), a quote that is not on the line.

The SOURCE is read at the pinned import commit (port/TRACE.yaml meta source_commit and
source_root, or --ref / SOURCE_PIN_REF), never the working tree. The file set is the verifier's:
*.c and *.h under the product root, `tests/` subtrees and hidden directories left out.

Usage: migrate-anchor-grammar.py [--apply] [--ref <git-ref>] [--workbench <dir>] <product-root>

Dry run by default: prints each rewrite and each anchor it cannot rewrite. --apply writes the
rewrites, which are changes to the product's TARGET files and land like any other. Exit: 0 every
constant anchor holds after the rewrites; 1 some anchor is reported for a human to fix; 2 the
script cannot run (no pin, unreadable file, bad arguments).
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, 'conformance', 'lib'))
import anchor_binding as ab  # noqa: E402

TAIL = re.compile(r'(?:_[A-Za-z0-9_]+|[EeDd][+-]?[0-9]+(?:_[A-Za-z0-9_]+)?)')
USAGE = 'Usage: migrate-anchor-grammar.py [--apply] [--ref <git-ref>] [--workbench <dir>] <product-root>'


class Stop(RuntimeError):
    """The script cannot run."""


def pin(wb, ref):
    """(commit, SOURCE root) of the pinned SOURCE."""
    meta = {}
    trace = os.path.join(wb, 'port', 'TRACE.yaml')
    if os.path.exists(trace):
        import yaml
        with open(trace, encoding='utf-8') as fh:
            data = yaml.safe_load(fh)
        meta = data.get('meta') if isinstance(data, dict) and isinstance(data.get('meta'), dict) else {}
    ref = ref or os.environ.get('SOURCE_PIN_REF') or str(meta.get('source_commit') or '')
    root = (os.environ.get('SOURCE_SUBDIR') or str(meta.get('source_root') or 'source')).strip().rstrip('/')
    if not ref:
        raise Stop('no SOURCE pin: set port/TRACE.yaml meta source_commit, SOURCE_PIN_REF or --ref')
    p = subprocess.run(['git', '-C', wb, 'rev-parse', '--verify', '--quiet', f'{ref}^{{commit}}'],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode != 0:
        raise Stop(f"the SOURCE pin '{ref}' does not resolve in {wb}")
    return p.stdout.strip(), root


class Source:
    """The pinned SOURCE files' lines, read with git show."""

    def __init__(self, wb, sha, root):
        self.wb, self.sha, self.root, self.cache = wb, sha, root, {}

    def lines(self, path):
        norm = os.path.normpath(path)
        if os.path.isabs(norm) or norm.startswith('..'):
            return None
        if norm not in self.cache:
            p = subprocess.run(['git', '-C', self.wb, 'show', f'{self.sha}:{self.root}/{norm}'],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            lines = p.stdout.decode('utf-8', errors='replace').split('\n') if p.returncode == 0 else None
            if lines and lines[-1] == '':
                lines.pop()
            self.cache[norm] = lines
        return self.cache[norm]


def target_files(root):
    out = []
    for d, subdirs, files in os.walk(root):
        subdirs[:] = sorted(s for s in subdirs if not s.startswith('.') and s != 'tests')
        out += [os.path.join(d, f) for f in sorted(files) if f.endswith(('.c', '.h'))]
    return out


def whole_token(lit, line):
    """The literal tokens of the SOURCE line that are `lit` with its kind suffix or exponent:
    the set of their texts."""
    code = line.split('!')[0]
    return {t for t in (m.group(0) for m in ab.F_TOKEN.finditer(code))
            if ab.F_LITERAL.fullmatch(t) and t.startswith(lit) and TAIL.fullmatch(t[len(lit):])}


def migrate_line(text, lineno, show, src):
    """(new text, [(old anchor, new anchor)], [(anchor, why)]) for one TARGET line."""
    rewrites, reports, edits = [], [], []
    for m in ab.ANCHOR.finditer(text):
        rest = m.group('rest')
        if not rest.strip().startswith('= ') or not rest.strip()[2:].strip():
            continue  # not a constant anchor
        lit = rest.strip()[2:]
        path, n = m.group('path'), int(m.group('line'))
        slines = src.lines(path)
        if slines is None or not 1 <= n <= len(slines):
            reports.append((m.group(0), f'cites {path}:{n}, which the pinned SOURCE does not have'))
            continue
        if not ab.bound_problems([(lineno, m)], [], path, slines, n, '', show):
            continue  # already one literal whole, or the whole right-hand side
        found = whole_token(lit, slines[n - 1])
        if len(found) != 1:
            why = (f'{path}:{n} holds more than one token completing {lit!r}: {", ".join(sorted(found))}' if found
                   else f'no literal of {path}:{n} is {lit!r} with a kind suffix or exponent')
            reports.append((m.group(0), why))
            continue
        new = found.pop()
        start = m.start('rest') + rest.index('= ') + 2
        start += len(text[start:m.end('rest')]) - len(text[start:m.end('rest')].lstrip())
        edits.append((start, m.end('rest'), new))
        rewrites.append((m.group(0), m.group(0)[:start - m.start()] + new + m.group(0)[m.end('rest') - m.start():]))
    for a, b, new in sorted(edits, reverse=True):
        text = text[:a] + new + text[b:]
    return text, rewrites, reports


def main(argv):
    apply, ref, wb, roots = False, '', os.path.dirname(HERE), []
    it = iter(argv)
    for a in it:
        if a == '--apply':
            apply = True
        elif a in ('--ref', '--workbench'):
            v = next(it, None)
            if v is None:
                print(f'migrate-anchor-grammar: {a} needs a value', file=sys.stderr)
                return 2
            ref, wb = (v, wb) if a == '--ref' else (ref, v)
        elif a.startswith('-'):
            print(USAGE, file=sys.stderr)
            return 2
        else:
            roots.append(a)
    if len(roots) != 1 or not os.path.isdir(roots[0]):
        print(USAGE, file=sys.stderr)
        return 2
    try:
        sha, root = pin(os.path.abspath(wb), ref)
    except Stop as e:
        print(f'migrate-anchor-grammar: {e}', file=sys.stderr)
        return 2
    src = Source(os.path.abspath(wb), sha, root)
    product = os.path.abspath(roots[0])
    nrew, nrep = 0, 0
    for f in target_files(product):
        show = os.path.relpath(f, product)
        try:
            with open(f, encoding='utf-8', newline='') as fh:
                lines = fh.read().split('\n')
        except (OSError, UnicodeDecodeError) as e:
            print(f'migrate-anchor-grammar: {show} cannot be read: {e}', file=sys.stderr)
            return 2
        changed = False
        for k, text in enumerate(lines):
            new, rewrites, reports = migrate_line(text, k + 1, show, src)
            for old, rep in rewrites:
                print(f'{show}:{k + 1}: {old} -> {rep}')
            for anchor, why in reports:
                print(f'{show}:{k + 1}: cannot rewrite {anchor}: {why}')
            nrew, nrep = nrew + len(rewrites), nrep + len(reports)
            if new != text:
                lines[k], changed = new, True
        if changed and apply:
            with open(f, 'w', encoding='utf-8', newline='') as fh:
                fh.write('\n'.join(lines))
    verb = 'rewritten' if apply else 'to rewrite (dry run; --apply writes them)'
    print(f'migrate-anchor-grammar: {nrew} anchor(s) {verb}; {nrep} anchor(s) for a human to fix')
    return 1 if nrep else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
