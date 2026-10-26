#!/usr/bin/env bash
# The anchor value verifier (tools/conformance/lib/anchor_values.py) against its acceptance corpus,
# tools/conformance/seeded-bugs/verify-anchors/: every case, in every regime it lists, must get its
# expected verdict - expect, the mismatch kind, and `at` - exactly.
#
# The verifier compares VALUES: gfortran evaluates the SOURCE constant and clang the TARGET one, and
# the two are compared by type, kind and bits; the structure comes from fparser (SOURCE) and libclang
# (TARGET). A missing compiler or parser fails this test; it never skips. Two fail-closed paths are
# checked too: a TARGET that does not compile and a missing fparser are UNRELIABLE, never a pass.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/tools/conformance/lib"
CORPUS="$ROOT/tools/conformance/seeded-bugs/verify-anchors"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The verifier's scratch directories go to TMPDIR: an empty one of this test's, checked empty at the end.
export TMPDIR="$TMP/tmpdir"
mkdir "$TMPDIR"

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n%s\n' "$1" "${2:-}" | sed '2,$s/^/    /'; failures=$((failures + 1)); }

for tool in gfortran clang; do
	command -v "$tool" >/dev/null 2>&1 || { not_ok "$tool is installed" "the verifier compiles probes with it"; }
done
python3 -c 'import yaml, fparser, clang.cindex' 2>/dev/null \
	|| not_ok "python3 can import yaml, fparser and clang.cindex" "pip install -r tools/requirements-ast.txt (and libclang)"
[ "$failures" -eq 0 ] || { echo "# test-anchor-values: $failures failure(s)" >&2; exit 1; }

# ---- the corpus ---------------------------------------------------------------------------------
cat >"$TMP/run.py" <<'PY'
import collections
import glob
import os
import sys
from concurrent.futures import ProcessPoolExecutor

LIB, CORPUS = sys.argv[1], sys.argv[2]
sys.path.insert(0, LIB)
import anchor_values as av  # noqa: E402
import yaml  # noqa: E402


def judge(job):
    case, regime, want = job
    try:
        v = av.judge_case(case, regime)
        return case, regime, want, (v.verdict, v.mismatch, v.at), v.reason
    except av.Unreliable as e:
        return case, regime, want, ('UNRELIABLE', '', ''), str(e)


if __name__ == '__main__':
    jobs = []
    for path in sorted(glob.glob(os.path.join(CORPUS, '*', '*', 'case.yaml'))):
        meta = yaml.safe_load(open(path, encoding='utf-8'))
        want = (meta['expect'], meta.get('mismatch', ''), str(meta.get('at', '')))
        jobs += [(os.path.dirname(path), r, want) for r in meta['regimes']]
    with ProcessPoolExecutor(max_workers=os.cpu_count() or 1) as pool:
        results = list(pool.map(judge, jobs))
    bad = [r for r in results if r[2] != r[3]]
    for case, regime, want, got, why in bad:
        name = os.path.relpath(case, CORPUS)
        print(f'not ok - {name} [{regime}]: expected {" ".join(x for x in want if x)}, got {" ".join(x for x in got if x)}')
        if why:
            print(f'    {why}')
    verdicts = collections.Counter(w[0] for _, _, w, _, _ in results)
    if not bad:
        cases = len({c for c, _, _, _, _ in results})
        print(f'ok - the verifier gives all {cases} corpus cases their expected verdict in every listed regime '
              f'({len(results)} judgments: ' + ', '.join(f'{n} {k}' for k, n in sorted(verdicts.items())) + ')')
    sys.exit(1 if bad else 0)
PY
if out="$(python3 "$TMP/run.py" "$LIB" "$CORPUS" 2>&1)"; then
	printf '%s\n' "$out"
else
	printf '%s\n' "$out"
	failures=$((failures + 1))
fi

# ---- fail closed ----------------------------------------------------------------------------------
# A TARGET that does not compile: UNRELIABLE, never a verdict.
pass_case="$(ls -d "$CORPUS"/literals-kinds/01-* | head -1)"
cp -R "$pass_case" "$TMP/broken"
sed -i 's/;\( *\/\*\)/\1/' "$TMP/broken/target.c"   # drop the declaration's semicolon
out="$(python3 "$LIB/anchor_values.py" "$TMP/broken" --regime dp 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 2 ] && grep -q 'UNRELIABLE' <<<"$out" && ! grep -q ' pass' <<<"$out"; then
	ok "a TARGET that does not compile is UNRELIABLE (exit 2), never a pass"
else
	not_ok "a TARGET that does not compile is UNRELIABLE (exit 2), never a pass" "exit $rc: $out"
fi

# Without fparser the SOURCE cannot be read: UNRELIABLE.
mkdir -p "$TMP/nofparser/fparser"
printf 'raise ImportError("fparser withheld by the test")\n' >"$TMP/nofparser/fparser/__init__.py"
out="$(PYTHONPATH="$TMP/nofparser" python3 "$LIB/anchor_values.py" "$pass_case" --regime dp 2>&1)" && rc=0 || rc=$?
if [ "$rc" -eq 2 ] && grep -q 'UNRELIABLE.*fparser' <<<"$out"; then
	ok "without fparser the verifier is UNRELIABLE (exit 2)"
else
	not_ok "without fparser the verifier is UNRELIABLE (exit 2)" "exit $rc: $out"
fi

# Each side alone makes a pair not-comparable. In the corpus a run-time SOURCE always meets a run-time
# TARGET, so these two cases give each rule a pair where the other side is a constant.
mkcase() { # mkcase DIR SLINE SNAME TLINE TNAME (source.F90 and target.c written by the caller)
	printf 'description: a case\nsituation: rendering\nsource: {file: source.F90, line: %s, name: %s}\n' "$2" "$3" >"$1/case.yaml"
	printf 'target: {file: target.c, line: %s, name: %s}\nregimes: [dp]\nexpect: not-comparable\nwhy: test\n' "$4" "$5" >>"$1/case.yaml"
}
mkdir -p "$TMP/src-runtime" "$TMP/tgt-runtime"
printf '%s\n' 'MODULE MOD_A' '  IMPLICIT NONE' '  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(13, 300)' '  REAL(WP) :: XS' \
	'CONTAINS' '  SUBROUTINE INIT_A' '    XS = 2._WP' '  END SUBROUTINE INIT_A' 'END MODULE MOD_A' >"$TMP/src-runtime/source.F90"
printf '%s\n' 'static const double xs = 2.0; /* src: source.F90:7 = 2._WP */' >"$TMP/src-runtime/target.c"
mkcase "$TMP/src-runtime" 7 XS 1 xs
printf '%s\n' 'MODULE MOD_A' '  IMPLICIT NONE' '  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(13, 300)' \
	'  REAL(WP), PARAMETER :: Q = 0.5_WP' 'END MODULE MOD_A' >"$TMP/tgt-runtime/source.F90"
printf '%s\n' 'double f(double x)' '{' '	const double q = x; /* src: source.F90:4 = 0.5_WP */' '	return q;' '}' >"$TMP/tgt-runtime/target.c"
mkcase "$TMP/tgt-runtime" 4 Q 3 q
for c in src-runtime:"a SOURCE variable set only at run time, against a constant TARGET" \
	tgt-runtime:"a TARGET initialized from a run-time value, against a constant SOURCE"; do
	dir="${c%%:*}" label="${c#*:}"
	out="$(python3 "$LIB/anchor_values.py" "$TMP/$dir" --regime dp 2>&1)" && rc=0 || rc=$?
	if [ "$rc" -eq 0 ] && grep -q ' not-comparable' <<<"$out"; then
		ok "$label is not-comparable"
	else
		not_ok "$label is not-comparable" "exit $rc: $out"
	fi
done

# ---- many pairs in one regime (judge_many) ------------------------------------------------------------
# A SOURCE of two modules over a kinds module (compiled first, as the regime's fsources), a TARGET of
# several entities, two of them brace-list macros (each gets its own holder in the one probe). One
# entity the SOURCE probe cannot compile (named like a variable of the probe's own) and one it
# cannot print (CHARACTER) are UNRELIABLE on their own; every other pair gets its verdict, the same
# as judged alone - a PRIVATE parameter included.
B="$TMP/batch"
mkdir -p "$B"
printf '%s\n' 'MODULE MOD_KINDS' '  IMPLICIT NONE' '  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(13, 300)' \
	'  TYPE PT' '    REAL(WP) :: X = 1.5_WP' '    INTEGER :: N = 2' '  END TYPE PT' 'END MODULE MOD_KINDS' >"$B/kinds.F90"
printf '%s\n' 'MODULE MOD_A' '  USE MOD_KINDS' '  IMPLICIT NONE' '  REAL(WP), PARAMETER :: A = 0.1_WP' \
	'  INTEGER, PARAMETER :: N = 7' '  REAL(WP), PARAMETER :: TAB(3) = (/ 1.0_WP, 2.0_WP, 3.0_WP /)' \
	'  TYPE(PT), PARAMETER :: P0 = PT(2.5_WP, 3)' '  TYPE(PT), PARAMETER :: P1 = PT(2.5_WP, 4)' \
	'  REAL(WP), PARAMETER, PRIVATE :: HIDDEN = 1.0_WP' "  CHARACTER(4), PARAMETER :: S = 'abcd'" '  REAL(WP) :: R' \
	'  REAL(WP), PARAMETER :: CHISEL_I = 1.0_WP' 'END MODULE MOD_A' >"$B/a.F90"
printf '%s\n' 'MODULE MOD_B' '  USE MOD_KINDS' '  IMPLICIT NONE' '  REAL(WP), PARAMETER :: A = 0.2_WP' 'END MODULE MOD_B' >"$B/b.F90"
cat >"$B/target.c" <<'EOF'
typedef struct { double x; int n; } pt;
static const double mod_a_a = 0.1;
enum { mod_a_n = 7 };
static const double mod_a_tab[3] = {1.0, 2.0, 3.0};
#define MOD_A_P0 {2.5, 3}
#define MOD_A_P1 {2.5, 3}
static const double mod_b_a = 0.2f;
static const double mod_a_hidden = 1.0;
static const char mod_a_s[5] = "abcd";
static const double mod_a_chisel_i = 1.0;
EOF
cat >"$TMP/batch.py" <<'PY'
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import anchor_values as av
B = sys.argv[2]
a, b, t = (os.path.join(B, f) for f in ('a.F90', 'b.F90', 'target.c'))
regime = av.Regime('test', fsources=(os.path.join(B, 'kinds.F90'),))
cases = [
    (av.Pair(a, 'A', t, 'mod_a_a', 2), 'pass'),
    (av.Pair(a, 'N', t, 'mod_a_n', 3), 'pass'),
    (av.Pair(a, 'TAB', t, 'mod_a_tab', 4), 'pass'),
    (av.Pair(a, 'P0', t, 'MOD_A_P0', 5), 'pass'),
    (av.Pair(a, 'P1', t, 'MOD_A_P1', 6), 'mismatch value at .n'),
    (av.Pair(b, 'A', t, 'mod_b_a', 7), 'mismatch kind'),
    (av.Pair(b, 'A', t, 'mod_a_a', 2), 'mismatch value'),
    (av.Pair(a, 'R', t, 'mod_a_a', 2), 'not-comparable'),
    (av.Pair(a, 'HIDDEN', t, 'mod_a_hidden', 8), 'pass'),
    (av.Pair(a, 'CHISEL_I', t, 'mod_a_chisel_i', 10), 'UNRELIABLE'),
    (av.Pair(a, 'S', t, 'mod_a_s', 9), 'UNRELIABLE'),
]
def show(r):
    return 'UNRELIABLE' if isinstance(r, av.Unreliable) else r.line().split(' - ')[0]
bad = 0
with tempfile.TemporaryDirectory(prefix='batch-') as work:
    many = [show(r) for r in av.judge_many([p for p, _ in cases], regime, work)]
    for (p, want), got in zip(cases, many):
        try:
            alone = show(av.judge(p.src, p.tpath, p.sname, p.tname, p.tline, regime, work))
        except av.Unreliable:
            alone = 'UNRELIABLE'
        label = f'{os.path.basename(p.src)}:{p.sname} against {p.tname}'
        if got == want == alone:
            print(f'ok - judge_many: {label} is {want}, as judged alone')
        else:
            bad += 1
            print(f'not ok - judge_many: {label}: expected {want}, got {got} (alone: {alone})')
# Batched means one probe per file: on the pairs every probe can build, one gfortran probe per SOURCE
# file and one clang probe per TARGET file, plus at most one per literal move (raise, lower).
clean = [p for p, want in cases if want != 'UNRELIABLE']
with tempfile.TemporaryDirectory(prefix='batch-count-') as work:
    av.judge_many(clean, regime, work)
    probes = sorted(d.split('-')[0] for d in os.listdir(work) if d.startswith(('fprobe-', 'cprobe-')))
nf, nc = probes.count('fprobe'), probes.count('cprobe')
if nf == 2 and 1 <= nc <= 3:
    print(f'ok - judge_many builds one SOURCE probe per SOURCE file and one TARGET probe per TARGET file '
          f'and literal move ({nf} gfortran, {nc} clang probes for {len(clean)} pairs)')
else:
    bad += 1
    print(f'not ok - judge_many is not batched: {nf} gfortran and {nc} clang probes for {len(clean)} pairs '
          f'over 2 SOURCE files and 1 TARGET file')
sys.exit(1 if bad else 0)
PY
if out="$(python3 "$TMP/batch.py" "$LIB" "$B" 2>&1)"; then
	printf '%s\n' "$out"
else
	printf '%s\n' "$out"
	failures=$((failures + 1))
fi

# A brace-list macro for a struct declared as an untagged typedef (`typedef struct { ... } pt;`) is
# filled through the typedef: the struct has no tag `pt` to name.
U="$TMP/untagged"
mkdir -p "$U"
printf '%s\n' 'MODULE MOD_A' '  IMPLICIT NONE' '  INTEGER, PARAMETER :: WP = SELECTED_REAL_KIND(13, 300)' \
	'  TYPE PT' '    REAL(WP) :: X = 1.5_WP' '    INTEGER :: N = 2' '  END TYPE PT' \
	'  TYPE(PT), PARAMETER :: P0 = PT(2.5_WP, 3)' 'END MODULE MOD_A' >"$U/source.F90"
printf '%s\n' 'typedef struct { double x; int n; } pt;' '#define MOD_A_P0 {2.5, 3}' >"$U/target.c"
out="$(python3 - "$LIB" "$U" <<'PY' 2>&1
import os, sys, tempfile
sys.path.insert(0, sys.argv[1])
import anchor_values as av
u = sys.argv[2]
with tempfile.TemporaryDirectory() as work:
    print(av.judge(os.path.join(u, 'source.F90'), os.path.join(u, 'target.c'), 'P0', 'MOD_A_P0', 2, 'dp', work).line())
PY
)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$out" = "pass" ]; then
	ok "a brace list for an untagged typedef struct is filled through the typedef"
else
	not_ok "a brace list for an untagged typedef struct is filled through the typedef" "exit $rc: $out"
fi

leftover="$(ls -A "$TMPDIR")"
if [ -z "$leftover" ]; then
	ok "the verifier and this test leave no scratch directory behind"
else
	not_ok "the verifier and this test leave no scratch directory behind" "$leftover"
fi

if [ "$failures" -ne 0 ]; then
	echo "# test-anchor-values: $failures failure(s)" >&2
	exit 1
fi
echo "# test-anchor-values: all assertions passed"
