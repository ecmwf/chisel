#!/usr/bin/env python3
"""silenced_detectors.py - find what silences a detector in the product's C code.

Used by check-no-silenced-detectors.sh. Every file is parsed with libclang first
(lib/product_tu.py), so a file that does not parse cleanly is UNRELIABLE. Then four readings, each
from the compiler's own view of the code, never from a text search:

  1. Pragmas in each file's raw tokens (clang's lexer through lib/scan_guarded_macros.py):
     every `#pragma` directive, in every #if branch, and every `_Pragma("...")` with a literal
     argument, also inside a macro definition. Comments and string literals are not pragmas.
  2. Pragmas in the preprocessed token stream (`clang -E` with each file's compile arguments, read
     back through libclang): a pragma a macro produces is reported at the line that uses the macro.
  3. Attributes in the preprocessed parse: no_sanitize and its variants, and clang's suppress,
     reported at the line of the declaration that carries them. A suppressing attribute clang does
     not implement (GCC's no_sanitize_undefined) is read from clang's unknown-attribute warning.
  4. Lint suppressions in comment and string tokens: NOLINT, NOLINTNEXTLINE, NOLINTBEGIN,
     NOLINTEND, as clang-tidy reads them (anywhere in the text, followed by no other letter).

And, when the product root has a compile_commands.json, the compile command of every file checked
is audited for flags that turn warnings off: -w and -Wno-* (including -Wno-error).

A pragma suppresses when it is `GCC|clang diagnostic ignored|ignored_attributes|warning|push`
(`push` frames an ignore region; `warning` turns an error back into a warning),
`GCC|clang system_header`, `warning(disable|suppress ...)`, or a `clang attribute` pragma that
applies a suppressing attribute.

Usage:
  silenced_detectors.py [--root DIR] -- FILE...

Output (stdout, tab-separated, one line per finding):
  FAIL\t<file>:<line> or <compile_commands.json>\t<description>

Exit codes:
  0  ran to completion (the findings above, possibly none)
  2  UNRELIABLE: a file does not parse cleanly, cannot be read or preprocessed, or libclang / the
     clang driver is unavailable
"""
import bisect
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


class Scan:
    def __init__(self, files, root):
        self.ci = product_tu.cindex()
        self.root = root
        self.given = {}
        for f in files:
            self.given.setdefault(os.path.realpath(f), f)
        self.units, self.owner = product_tu.parse(files, root)
        self.seen = set()
        self.findings = []

    def add(self, real, line, kind, key, desc):
        k = (real, line, kind, key)
        if k in self.seen:
            return False
        self.seen.add(k)
        self.findings.append((self.given[real], line, desc))
        return True

    # ---- 1 and 4: raw tokens ----------------------------------------------------------------
    def raw(self, real):
        try:
            toks = sgm._parse_raw_tokens(real)
        except RuntimeError as exc:
            raise product_tu.Unreliable(str(exc))
        for t in toks:
            if t['type'] == 'unknown':
                raise product_tu.Unreliable(f"{self.given[real]}:{t['line']}: an unterminated comment")
            if t['type'] in ('comment', 'literal'):
                m = NOLINT_RE.search(t['spelling'])
                if m:
                    text = ' '.join(t['spelling'].split())
                    self.add(real, int(t['line']), 'lint', text,
                             f"lint suppression '{m.group(0)}' in {t['type']} '{text[:80]}'")
        for start, end in sgm._spans(toks):
            i = sgm._first_significant(toks, start, end)
            if i is None or toks[i]['type'] != 'hash':
                continue
            k = sgm._first_significant(toks, i + 1, end)
            if k is None or toks[k]['spelling'] != 'pragma':
                continue
            words = [t['spelling'] for t in toks[k + 1:end] if t['type'] != 'comment']
            if pragma_suppresses(words):
                self.add(real, int(toks[i]['line']), 'pragma', tuple(words),
                         f"pragma '#pragma {' '.join(words)}'")
        sig = [t for t in toks if t['type'] != 'comment']
        for n, t in enumerate(sig):
            if t['spelling'] != '_Pragma' or n + 3 >= len(sig):
                continue
            # _Pragma("..."): a literal argument can be judged here; one the preprocessor builds
            # (_Pragma(#x)) is judged where it is used, in the preprocessed stream.
            if sig[n + 1]['spelling'] == '(' and sig[n + 2]['type'] == 'literal' \
                    and sig[n + 3]['spelling'] == ')':
                text = destringize(sig[n + 2]['spelling'])
                if text is None:
                    continue
                words = WORD_RE.findall(text)
                if pragma_suppresses(words):
                    self.add(real, int(t['line']), 'pragma', tuple(words),
                             f"pragma '_Pragma({sig[n + 2]['spelling']})'")

    # ---- 2 and 3: the preprocessed stream ---------------------------------------------------
    @staticmethod
    def _pp_args(args):
        out, skip = [], False
        for a in args:
            if skip:
                skip = False
                continue
            if a in ('-x', '-include', '-imacros', '-isystem', '-iquote', '-idirafter', '-I', '-D', '-U'):
                skip = True
                continue
            if a.startswith(('-x', '-D', '-U', '-I', '-working-directory', '-include', '-imacros',
                             '-isystem', '-iquote', '-idirafter')):
                continue
            out.append(a)
        return ['-x', 'cpp-output'] + out

    def preprocessed(self, unit):
        ci = self.ci
        try:
            p = subprocess.run(['clang', '-E'] + unit.args + [unit.path], cwd=unit.directory,
                               capture_output=True)
        except OSError as exc:
            raise product_tu.Unreliable(f"cannot run the clang driver to preprocess '{unit.path}': {exc}")
        if p.returncode != 0:
            err = p.stderr.decode('utf-8', 'replace')
            first = next((ln for ln in err.splitlines() if 'error' in ln), err.strip()[:300])
            raise product_tu.Unreliable(f"clang -E could not preprocess '{unit.path}': {first}")
        text = p.stdout
        name = unit.path + '.chisel-preprocessed.i'
        try:
            tu = ci.Index.create().parse(name, args=self._pp_args(unit.args), unsaved_files=[(name, text)])
        except Exception as exc:
            raise product_tu.Unreliable(f"libclang could not read the preprocessed '{unit.path}': {exc}")
        for d in tu.diagnostics:
            if d.severity >= ci.Diagnostic.Error:
                raise product_tu.Unreliable(
                    f"the preprocessed '{unit.path}' does not parse cleanly: line {d.location.line}: {d.spelling}")
        f = tu.get_file(name)
        size = len(text)
        rng = ci.SourceRange.from_locations(ci.SourceLocation.from_offset(tu, f, 0),
                                            ci.SourceLocation.from_offset(tu, f, size))
        # Token text is read from the preprocessed bytes, so a string or comment that is not UTF-8
        # does not stop the reading.
        def sp(t):
            return text[t.extent.start.offset:t.extent.end.offset].decode('utf-8', 'surrogateescape')

        lines = {}
        for t in tu.get_tokens(extent=rng):
            lines.setdefault(t.location.line, []).append((t, sp(t)))
        # Line markers: `# N "file" flags` makes the next line line N of file.
        marks, where = [], []
        for ln in sorted(lines):
            toks = [s for _, s in lines[ln]]
            if len(toks) >= 3 and toks[0] == '#' and toks[1].isdigit() and toks[2].startswith('"'):
                marks.append(ln)
                where.append((int(toks[1]), unit.real(_unescape_marker(toks[2][1:-1]))))

        def source_of(buf_line):
            k = bisect.bisect_left(marks, buf_line) - 1
            if k < 0:
                return None, None
            n, real = where[k]
            return real, n + (buf_line - marks[k] - 1)

        for ln in sorted(lines):
            toks = [s for _, s in lines[ln]]
            if len(toks) >= 2 and toks[0] == '#' and toks[1] == 'pragma':
                real, line = source_of(ln)
                if real not in self.given:
                    continue
                words = toks[2:]
                if pragma_suppresses(words):
                    self.add(real, line, 'pragma', tuple(words),
                             f"pragma '#pragma {' '.join(words)}' (produced by a macro)")
            for n in range(len(toks) - 2):
                if toks[n:n + 3] == ['clang', '::', 'suppress']:
                    real, line = source_of(ln)
                    if real in self.given:
                        self.add(real, line, 'attribute', 'clang::suppress', "attribute 'clang::suppress'")
        for top in tu.cursor.get_children():
            real, _ = source_of(top.extent.start.line)
            if real not in self.given:
                continue
            for c in top.walk_preorder():
                if not c.kind.is_attribute():
                    continue
                words = [sp(t) for t in c.get_tokens()]
                if len(words) >= 3 and words[1] == '::':
                    words = words[2:]
                if not words or _attr_name(words[0]) not in SUPPRESSING_ATTRS:
                    continue
                areal, line = source_of(c.extent.start.line)
                if areal in self.given:
                    self.add(areal, line, 'attribute', _attr_name(words[0]), f"attribute '{''.join(words)}'")

    def unknown_attributes(self, unit):
        """A suppressing attribute clang does not implement (GCC's no_sanitize_undefined, say)
        still silences the build of a compiler that does; clang's own warning names it."""
        for d in unit.tu.diagnostics:
            if d.option != '-Wunknown-attributes' or d.location.file is None:
                continue
            m = re.search(r"attribute '([^']+)'", d.spelling)
            real = unit.real(d.location.file.name)
            if m and _attr_name(m.group(1).split('::')[-1]) in SUPPRESSING_ATTRS and real in self.given:
                name = _attr_name(m.group(1).split('::')[-1])
                self.add(real, d.location.line, 'attribute', name, f"attribute '{m.group(1)}'")

    # ---- flags ------------------------------------------------------------------------------
    def flags(self):
        entries, db = product_tu.load_compile_db(self.root)
        for real in self.given:
            for _directory, argv in entries.get(real, []):
                for a in argv[1:]:
                    if a == '-w' or a.startswith('-Wno-'):
                        key = (db, real, a)
                        if key in self.seen:
                            continue
                        self.seen.add(key)
                        self.findings.append((db, None, f"compiler flag '{a}' in the compile command of "
                                                        f"'{self.given[real]}' turns warnings off"))

    def run(self):
        for real in self.given:
            self.raw(real)
        for unit in self.units:
            self.preprocessed(unit)
            self.unknown_attributes(unit)
        self.flags()
        return self.findings


def main(argv):
    root = None
    if argv[:1] == ['--root'] and len(argv) > 1:
        root, argv = argv[1] or None, argv[2:]
    if argv[:1] != ['--'] or len(argv) < 2:
        sys.stderr.write('usage: silenced_detectors.py [--root DIR] -- FILE...\n')
        return 2
    sys.stdout.reconfigure(errors='backslashreplace')
    try:
        findings = Scan(argv[1:], root).run()
    except product_tu.Unreliable as exc:
        sys.stderr.write(f'silenced_detectors: {exc}\n')
        return 2
    for where, line, desc in sorted(findings, key=lambda f: (f[0], f[1] or 0)):
        print(f"FAIL\t{where}{'' if line is None else f':{line}'}\t{desc}")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
