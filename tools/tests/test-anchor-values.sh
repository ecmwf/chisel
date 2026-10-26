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

if [ "$failures" -ne 0 ]; then
	echo "# test-anchor-values: $failures failure(s)" >&2
	exit 1
fi
echo "# test-anchor-values: all assertions passed"
