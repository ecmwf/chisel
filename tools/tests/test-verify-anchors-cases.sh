#!/usr/bin/env bash
# Validates the anchor-verifier test-case corpus, tools/conformance/seeded-bugs/verify-anchors/
# (format and verdict vocabulary: its README.md). Every case directory <category>/<NN>-<slug>/
# must hold exactly case.yaml, source.F90 and target.c (or target.h), and:
#   - case.yaml parses, uses only the documented keys, and every enumerated value is valid;
#     `mismatch` is present exactly when `expect` is `mismatch`, `at` only with it;
#   - the cited lines exist and contain the named symbol (SOURCE: whole word, any case; TARGET:
#     whole word, exact case; a path such as `T%A` or `ctx.a` matches on any of its identifiers);
#   - unless `expect` is `invalid-anchor`, the TARGET line or the line above it carries the
#     constant anchor `/* src: source.F90:<source line> = <literal> */`;
#   - the TARGET passes `clang -std=c17 -fsyntax-only` and the SOURCE `gfortran -cpp
#     -fsyntax-only`, in each listed regime (`dp` defines FIXTURE_DP, `sp` does not);
#   - every category holds at least one `pass` case and at least one other.
# A missing compiler fails the test; it never skips. The validator does not measure verdicts.
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

KEYS = {'description', 'source', 'target', 'regimes', 'expect', 'mismatch', 'at', 'why'}
REQUIRED = {'description', 'source', 'target', 'regimes', 'expect', 'why'}
EXPECT = ('pass', 'mismatch', 'not-comparable', 'invalid-anchor')
MISMATCH = ('value', 'kind', 'type', 'shape')
REGIMES = ('dp', 'sp')
SLUG = re.compile(r'^[a-z0-9]+(-[a-z0-9]+)*$')
CASE = re.compile(r'^[0-9]{2}-[a-z0-9]+(-[a-z0-9]+)*$')
IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')

errors = []
jobs = []
ncases = 0


def word_in(ident, line, fold):
    return re.search(r'(?<![A-Za-z0-9_])' + re.escape(ident) + r'(?![A-Za-z0-9_])', line,
                     re.I if fold else 0) is not None


def side(where, meta, key, files, path):
    """Validate meta[key] ({file, line, name}); return (file, line) or None."""
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
    lines = open(os.path.join(path, f), encoding='utf-8').read().split('\n')
    if lines and lines[-1] == '':
        lines.pop()
    if line > len(lines):
        errors.append(f'{where}: {key}.line {line} is past the end of {f} ({len(lines)} lines)')
        return None
    text = lines[line - 1]
    if not any(word_in(i, text, key == 'source') for i in IDENT.findall(name)):
        errors.append(f'{where}: {f}:{line} does not contain {key}.name {name!r}: {text.strip()!r}')
        return None
    return lines, line


if not os.path.isdir(root):
    print(f'not ok - corpus root {root} does not exist')
    sys.exit(1)

coverage = {}
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
        if 'at' in meta and not (isinstance(meta['at'], (str, int)) and str(meta['at']).strip()):
            errors.append(f'{where}: at must name an element or field')
        regimes = meta['regimes']
        if (not isinstance(regimes, list) or not regimes or len(set(regimes)) != len(regimes)
                or any(r not in REGIMES for r in regimes)):
            errors.append(f'{where}: regimes must be a non-empty list of distinct values from {", ".join(REGIMES)}')
            regimes = []
        if expect in EXPECT:
            coverage[cat]['pass' if expect == 'pass' else 'other'] += 1
        tfile = meta['target'].get('file') if isinstance(meta['target'], dict) else None
        want = {'case.yaml', 'source.F90'} | ({tfile} if tfile in ('target.c', 'target.h') else set())
        for f in sorted(files - want):
            errors.append(f'{where}: unexpected file {f}')
        src = side(where, meta, 'source', files, path)
        tgt = side(where, meta, 'target', files, path)
        if src and tgt and expect != 'invalid-anchor':
            tlines, tline = tgt
            anchor = re.compile(r'/\* src: source\.F90:' + str(src[1]) + r' = \S.*?\*/')
            near = [tlines[tline - 1]] + ([tlines[tline - 2]] if tline > 1 else [])
            if not any(anchor.search(t) for t in near):
                errors.append(f'{where}: neither {tfile}:{tline} nor the line above carries '
                              f'/* src: source.F90:{src[1]} = <literal> */')
        if 'source.F90' in files:
            for r in regimes:
                jobs.append((where, r, 'gfortran', os.path.join(path, 'source.F90')))
        if tfile in files and tfile in ('target.c', 'target.h'):
            for r in regimes:
                jobs.append((where, r, 'clang', os.path.join(path, tfile)))

for cat, c in coverage.items():
    if c['pass'] == 0:
        errors.append(f'{cat}: no pass case (every category holds at least one)')
    if c['other'] == 0:
        errors.append(f'{cat}: no case other than pass (every category holds at least one)')


def compile_one(job):
    where, regime, tool, path = job
    define = ['-DFIXTURE_DP'] if regime == 'dp' else []
    with tempfile.TemporaryDirectory(prefix='avc-') as tmp:
        if tool == 'clang':
            cmd = ['clang', '-std=c17', '-fsyntax-only', '-x', 'c'] + define + [path]
        else:
            cmd = ['gfortran', '-cpp', '-fsyntax-only', '-J', tmp] + define + [path]
        p = subprocess.run(cmd, cwd=tmp, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if p.returncode != 0:
        first = next((l for l in p.stdout.splitlines() if 'error' in l.lower()), p.stdout.strip()[:200])
        return f'{where}: {os.path.basename(path)} does not compile with {tool} in regime {regime}: {first.strip()}'
    return None


with ThreadPoolExecutor(max_workers=min(4, os.cpu_count() or 1)) as pool:
    errors += [e for e in pool.map(compile_one, jobs) if e]

for e in errors:
    print(f'not ok - {e}')
if errors:
    sys.exit(1)
print(f'ok - {ncases} case(s) in {len(coverage)} categor{"y" if len(coverage) == 1 else "ies"} valid; '
      f'{len(jobs)} compilation(s) clean')
PY

validate() { python3 "$TMP/validate.py" "$1"; }

# ---- the corpus ---------------------------------------------------------------------------------
if out="$(validate "$CORPUS" 2>&1)"; then
	pass "corpus: ${out#ok - }"
else
	failt "the anchor-verifier case corpus is invalid" "$out"
fi

# ---- the validator rejects malformed cases --------------------------------------------------------
# good/cat/: one pass case and one mismatch case, valid in both regimes. Line 8 of source.F90
# declares A; line 9 of target.c renders it.
good_case() { # good_case DIR VALUE EXPECT-LINES...
	local d="$1" value="$2"
	shift 2
	mkdir -p "$d"
	cat >"$d/source.F90" <<'EOF'
MODULE MOD_A
  IMPLICIT NONE
#ifdef FIXTURE_DP
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(13, 300)
#else
  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(6, 37)
#endif
  REAL(WP), PARAMETER :: A = 0.5_WP
END MODULE MOD_A
EOF
	cat >"$d/target.c" <<EOF
#ifdef FIXTURE_DP
typedef double real_t;
#define CONST(x) x
#else
typedef float real_t;
#define CONST(x) x##f
#endif

static const real_t a = CONST($value); /* src: source.F90:8 = 0.5_WP */
EOF
	{
		printf 'description: a working-precision literal\n'
		printf 'source: {file: source.F90, line: 8, name: A}\n'
		printf 'target: {file: target.c, line: 9, name: a}\n'
		printf 'regimes: [dp, sp]\n'
		printf '%s\n' "$@"
		printf 'why: the value of A\n'
	} >"$d/case.yaml"
}
good_case "$TMP/good/cat/01-pass" 0.5 'expect: pass'
good_case "$TMP/good/cat/02-mismatch" 0.25 'expect: mismatch' 'mismatch: value'
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
seeded "a TARGET without its anchor" "carries /* src: source.F90:8 = <literal> */" \
	"sed -i 's| /\\* src: .*\\*/||' 01-pass/target.c"
seeded "an anchor citing another line" "carries /* src: source.F90:8 = <literal> */" \
	"sed -i 's/source.F90:8 =/source.F90:7 =/' 01-pass/target.c"
seeded "an anchor in another grammar" "carries /* src: source.F90:8 = <literal> */" \
	"sed -i 's/source.F90:8 = /source.F90:8: /' 01-pass/target.c"
seeded "a TARGET that does not compile" "target.c does not compile with clang in regime dp" \
	"sed -i 's/CONST(0.5);/CONST(0.5)/' 01-pass/target.c"
seeded "a TARGET that compiles in one regime only" "target.c does not compile with clang in regime sp" \
	"sed -i 's/^typedef float real_t;/typedef flaot real_t;/' 01-pass/target.c"
seeded "a SOURCE that does not compile" "source.F90 does not compile with gfortran in regime dp" \
	"sed -i 's/PARAMETER :: A/PARAMETR :: A/' 01-pass/source.F90"
seeded "a missing SOURCE file" "source.file source.F90 does not exist" "rm 01-pass/source.F90"
seeded "a stray file in a case" "unexpected file notes.txt" "touch 01-pass/notes.txt"
seeded "a case directory not numbered" "a case directory is <NN>-<short-slug>" "mv 01-pass pass"
seeded "a category without a pass case" "cat: no pass case" "rm -r 01-pass"
seeded "a category with only pass cases" "cat: no case other than pass" "rm -r 02-mismatch"

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
