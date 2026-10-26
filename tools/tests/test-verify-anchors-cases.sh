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
#   - every SOURCE line the case cites holds exactly one statement (no `;` separator outside
#     character context; an `&` continuation is part of its statement), and a cited DATA
#     statement - after an optional label, `DATA` followed by a name or an implied-DO `(`, and no
#     `=` before its first `/` - holds exactly one /.../ set, its slashes counted outside quotes
#     and parentheses;
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

from anchor_binding import *  # noqa: F401,F403 - the anchor rules shared with the verifier

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

errors = []
jobs = []
ncases = 0


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
        if src and tgt:
            cited = {src[1]} | {int(m.group('line')) for ln in tgt[0] for m in ANCHOR.finditer(ln)
                                if m.group('path') == 'source.F90' and 1 <= int(m.group('line')) <= len(src[0])}
            errors += [f'{where}: {e}' for e in citation_format(src[0], cited)]
        if src and tgt and regimes and expect in EXPECT:
            # Each listed regime: a dual-precision TARGET binds a different branch in each build.
            for r in regimes:
                jobs.append(('anchors', where, r, (meta, path, src[0], tgt[0], tfile, expect)))
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
            return f'{where}: expect is invalid-anchor, but every anchor rule holds in regime {regime}'
        if expect != 'invalid-anchor' and problems:
            return f'{where}: an anchor rule is broken in regime {regime}, so expect must be invalid-anchor: {problems[0]}'
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

validate() { PYTHONPATH="$ROOT/tools/conformance/lib${PYTHONPATH:+:$PYTHONPATH}" python3 "$TMP/validate.py" "$1"; }

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
d="$TMP/good/cat/07-data"
mkdir -p "$d"
printf 'MODULE MOD_A\n  IMPLICIT NONE\n%s\n  REAL(WP) :: A(3)\n  DATA A / 3*0.5_WP /\nEND MODULE MOD_A\n' "$F_WP" >"$d/source.F90"
printf '%s\n\nstatic real_t a[3] = {CONST(0.5), CONST(0.5), CONST(0.5)}; /* src: source.F90:9 = 3*0.5_WP */\n' "$C_WP" >"$d/target.c"
yaml_case "$d/case.yaml" 9 A target.c 9 a 'expect: pass'
d="$TMP/good/cat/08-labelled-data"
mkdir -p "$d"
printf 'MODULE MOD_A\n  IMPLICIT NONE\n%s\n  REAL(WP) :: A(3)\n  100 DATA A / 3*0.5_WP /\nEND MODULE MOD_A\n' "$F_WP" >"$d/source.F90"
printf '%s\n\nstatic real_t a[3] = {CONST(0.5), CONST(0.5), CONST(0.5)}; /* src: source.F90:9 = 3*0.5_WP */\n' "$C_WP" >"$d/target.c"
yaml_case "$d/case.yaml" 9 A target.c 9 a 'expect: pass'
d="$TMP/good/cat/09-data-variable"
mkdir -p "$d"
printf 'MODULE MOD_A\n  IMPLICIT NONE\n%s\n  REAL(WP) :: DATA\nCONTAINS\n  SUBROUTINE S_A\n    DATA = 0.5_WP\n  END SUBROUTINE S_A\nEND MODULE MOD_A\n' "$F_WP" >"$d/source.F90"
printf '%s\n\nstruct mod_a_ctx {\n\treal_t data;\n};\n\nvoid mod_a_s_a(struct mod_a_ctx *ctx)\n{\n\tctx->data = CONST(0.5); /* src: source.F90:11 = 0.5_WP */\n}\n' "$C_WP" >"$d/target.c"
SITUATION=assigned-variable yaml_case "$d/case.yaml" 11 DATA target.c 15 'ctx->data' 'expect: not-comparable'
d="$TMP/good/cat/10-data-implied-do"
mkdir -p "$d"
printf 'MODULE MOD_A\n  IMPLICIT NONE\n%s\n  INTEGER :: I\n  REAL(WP) :: A(3)\n  DATA (A(I), I = 1, 6/2) / 3*0.5_WP /\nEND MODULE MOD_A\n' "$F_WP" >"$d/source.F90"
printf '%s\n\nstatic real_t a[3] = {CONST(0.5), CONST(0.5), CONST(0.5)}; /* src: source.F90:10 = 3*0.5_WP */\n' "$C_WP" >"$d/target.c"
yaml_case "$d/case.yaml" 10 A target.c 9 a 'expect: pass'
d="$TMP/good/cat/11-data-element"
mkdir -p "$d"
printf 'MODULE MOD_A\n  IMPLICIT NONE\n%s\n  REAL(WP) :: DATA(2)\nCONTAINS\n  SUBROUTINE S_A\n    DATA(2) = 1.0_WP / 2.0_WP\n  END SUBROUTINE S_A\nEND MODULE MOD_A\n' "$F_WP" >"$d/source.F90"
printf '%s\n\nstruct mod_a_ctx {\n\treal_t data[2];\n};\n\nvoid mod_a_s_a(struct mod_a_ctx *ctx)\n{\n\tctx->data[1] = CONST(1.0) / CONST(2.0); /* src: source.F90:11 = 1.0_WP / 2.0_WP */\n}\n' "$C_WP" >"$d/target.c"
SITUATION=assigned-variable yaml_case "$d/case.yaml" 11 DATA target.c 15 'ctx->data' 'expect: not-comparable'
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
seeded "an anchor borrowing the right-hand side of another statement on its line" "source.F90:8 holds more than one statement" \
	"sed -i 's/:: A = 0.5_WP/:: A = 0.5_WP; REAL(WP), PARAMETER :: B = 0.25_WP + 0.25_WP/' 01-pass/source.F90; sed -i 's|= 0.5_WP \\*/|= 0.25_WP + 0.25_WP */|' 01-pass/target.c"
seeded "an anchor quoting the tail of two statements on its line" "source.F90:11 holds more than one statement" \
	"printf 'MODULE MOD_A\\n  IMPLICIT NONE\\n%s\\n  REAL(WP) :: A, B\\nCONTAINS\\n  SUBROUTINE S_A\\n    A = 0.5_WP; B = 0.25_WP\\n  END SUBROUTINE S_A\\nEND MODULE MOD_A\\n' \"\$F_WP\" >01-pass/source.F90; sed -i 's/line: 8, name: A/line: 11, name: A/' 01-pass/case.yaml; sed -i 's|source.F90:8 = 0.5_WP \\*/|source.F90:11 = 0.5_WP; B = 0.25_WP */|' 01-pass/target.c"
seeded "a correct literal of the second statement on its line" "source.F90:8 holds more than one statement" \
	"sed -i 's/REAL(WP), PARAMETER :: A = 0.5_WP/REAL(WP), PARAMETER :: B = 0.25_WP; REAL(WP), PARAMETER :: A = 0.5_WP/' 01-pass/source.F90"
seeded "a DATA value list spanning two sets" "source.F90:9 is a DATA statement with more than one /.../ set" \
	"sed -i 's/REAL(WP) :: A(3)/REAL(WP) :: A(3), B/; s|DATA A / 3\\*0.5_WP /|DATA A / 3*0.5_WP /, B / 0.25_WP /|' 07-data/source.F90; sed -i 's|= 3\\*0.5_WP \\*/|= 3*0.5_WP /, B / 0.25_WP */|' 07-data/target.c"
seeded "a correct value list of one DATA set among two" "source.F90:9 is a DATA statement with more than one /.../ set" \
	"sed -i 's/REAL(WP) :: A(3)/REAL(WP) :: A(3), B/; s|DATA A / 3\\*0.5_WP /|DATA B / 0.25_WP /, A / 3*0.5_WP /|' 07-data/source.F90"
seeded "a labelled DATA statement with two sets" "source.F90:9 is a DATA statement with more than one /.../ set" \
	"sed -i 's/REAL(WP) :: A(3)/REAL(WP) :: A(3), B/; s|100 DATA A / 3\\*0.5_WP /|100 DATA A / 3*0.5_WP /, B / 0.25_WP /|' 08-labelled-data/source.F90; sed -i 's|= 3\\*0.5_WP \\*/|= 0.25_WP */|' 08-labelled-data/target.c"
seeded "a DATA statement with an implied DO and two sets" "source.F90:10 is a DATA statement with more than one /.../ set" \
	"sed -i 's/REAL(WP) :: A(3)/REAL(WP) :: A(3), B/; s|/ 3\\*0.5_WP /|/ 3*0.5_WP /, B / 0.25_WP /|' 10-data-implied-do/source.F90; sed -i 's|= 3\\*0.5_WP \\*/|= 0.25_WP */|' 10-data-implied-do/target.c"
seeded "a DATA statement with a name, an implied DO and two sets" "source.F90:10 is a DATA statement with more than one /.../ set" \
	"sed -i 's/REAL(WP) :: A(3)/REAL(WP) :: A(3), B, C/; s|DATA (A(I), I = 1, 6/2) / 3\\*0.5_WP /|DATA C, (A(I), I = 1, 6/2) / 4*0.5_WP /, B / 0.25_WP /|' 10-data-implied-do/source.F90; sed -i 's|= 3\\*0.5_WP \\*/|= 0.25_WP */|' 10-data-implied-do/target.c"
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
# The single-precision branch carries an anchor citing a line that does not hold the constant (line
# 3 is the #ifdef of the WP selection): every anchor rule holds in the dp build, not in the sp one.
seeded "an anchor wrong only in the single-precision build" "an anchor rule is broken in regime sp" \
	"printf '%s\\n\\nstatic const real_t a =\\n#ifdef FIXTURE_DP\\n    CONST(0.5); /* src: source.F90:8 = 0.5_WP */\\n#else\\n    CONST(0.5); /* src: source.F90:3 = 0.5_WP */\\n#endif\\n' \"\$C_WP\" >01-pass/target.c"
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
seeded "a category without a pass case" "cat: no pass case" "rm -r 01-pass 03-designated 04-context 05-below 07-data 08-labelled-data 10-data-implied-do"
seeded "a category with only pass cases" "cat: no case other than pass" "rm -r 02-mismatch 06-invalid 09-data-variable 11-data-element"

# A missing compiler fails the validation; it never skips it.
mkdir -p "$TMP/bin"
ln -s "$(command -v python3)" "$TMP/bin/python3"
for tool in clang gfortran; do
	set +e
	out="$(PATH="$TMP/bin" PYTHONPATH="$ROOT/tools/conformance/lib" python3 "$TMP/validate.py" "$TMP/good" 2>&1)"
	rc=$?
	set -e
	if [[ "$rc" -eq 0 ]] || ! grep -qF -- "$tool not found" <<<"$out"; then
		failt "a missing $tool does not fail the validation" "$out"
	fi
	pass "a missing $tool fails the validation"
	ln -s "$(command -v "$tool")" "$TMP/bin/$tool"
done
