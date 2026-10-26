#!/usr/bin/env bash
# The product-level anchor verifier (lib/anchor_driver.py) over the case corpus,
# tools/conformance/seeded-bugs/verify-anchors/: every case becomes part of a throwaway product, its
# target file under a directory of its own, citing its source.F90 imported into a workbench in a
# commit recorded as meta.source_commit. The cases run in batches, one driver run per set of regimes
# (anchors.yaml regimes), with each case's pairing - TARGET name -> SOURCE name, from case.yaml -
# in anchors.yaml names, so the naming rule is not what is tested. In every listed regime the named
# target's finding must be the case's verdict:
#   pass            the target verified
#   mismatch        RED, `mismatch <kind>` and `at <path>` as the case gives them
#   not-comparable  UNVERIFIED
#   invalid-anchor  RED invalid-anchor, or RED coverage: no anchor binds to the target
# The other anchors of a case are context (the corpus README) and are not judged.
#
# A missing compiler or parser fails this test; it never skips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
SCRATCH="$(mktemp -d)"  # the driver's TMPDIR, beside TMP: paths no longer than the caller's
trap 'rm -rf "$TMP" "$SCRATCH"' EXIT
export TMPDIR="$SCRATCH"
unset SOURCE_PIN_REF SOURCE_SUBDIR

for tool in gfortran clang ar objcopy git; do
	command -v "$tool" >/dev/null 2>&1 || { echo "not ok - $tool is installed (the verifier needs it)"; exit 1; }
done
python3 -c 'import yaml, fparser, clang.cindex as ci; ci.Index.create()' 2>/dev/null \
	|| { echo "not ok - python3 imports yaml, fparser and clang.cindex with its native library"; exit 1; }

python3 - "$ROOT" "$TMP/cases" <<'PY'
import collections
import glob
import os
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

import yaml

ROOT, OUT = sys.argv[1], sys.argv[2]
DRIVER = os.path.join(ROOT, 'tools', 'conformance', 'lib', 'anchor_driver.py')
CORPUS = os.path.join(ROOT, 'tools', 'conformance', 'seeded-bugs', 'verify-anchors')
IDENT = re.compile(r'[A-Za-z_]\w*')
FLAGS = {'dp': '{source_flags: [-DFIXTURE_DP], target_flags: [-DFIXTURE_DP]}', 'sp': '{}'}
FINDING = re.compile(r'(PASS|RED|UNRELIABLE|UNVERIFIED) (\S+?)(?::(\d+))?(?: (\S+))? \[([^\]]*)\]: (.*)')


def git(wb, *args):
    subprocess.run(['git', '-C', wb, '-c', 'user.name=tester', '-c', 'user.email=tester@example.invalid'] + list(args),
                   check=True, capture_output=True)


def ident(case):
    return os.path.relpath(case, CORPUS).replace(os.sep, '_')


def run(batch, regimes, cases):
    """The driver's output over the cases of one batch, set up as one workbench and one product."""
    wb, prod = os.path.join(OUT, batch, 'wb'), os.path.join(OUT, batch, 'product')
    os.makedirs(os.path.join(wb, 'port', 'conventions'))
    files, names = [], {}
    for case, meta in cases:
        os.makedirs(os.path.join(wb, 'source', ident(case)))
        os.makedirs(os.path.join(prod, ident(case)))
        shutil.copy(os.path.join(case, 'source.F90'), os.path.join(wb, 'source', ident(case)))
        tfile = os.path.join(prod, ident(case), meta['target']['file'])
        with open(os.path.join(case, meta['target']['file']), encoding='utf-8') as fh:
            text = fh.read()
        with open(tfile, 'w', encoding='utf-8') as fh:
            fh.write(re.sub(r'(/\*\s*src:\s*)source\.F90:', rf'\g<1>{ident(case)}/source.F90:', text))
        files.append(tfile)
        tname, sname = meta['target']['name'], meta['source']['name']
        if IDENT.fullmatch(tname) and IDENT.fullmatch(sname):
            names[tname] = sname
    git(wb, 'init', '-q')
    git(wb, 'add', 'source')
    git(wb, 'commit', '-q', '-m', 'import the cases SOURCE')
    sha = subprocess.run(['git', '-C', wb, 'rev-parse', 'HEAD'], capture_output=True, text=True, check=True).stdout.strip()
    with open(os.path.join(wb, 'port', 'TRACE.yaml'), 'w') as fh:
        fh.write(f'meta:\n  source_root: source\n  source_commit: {sha}\n')
    with open(os.path.join(wb, 'port', 'conventions', 'anchors.yaml'), 'w') as fh:
        fh.write('regimes:\n' + ''.join(f'  {r}: {FLAGS[r]}\n' for r in regimes) + 'include: [.]\nnames:\n'
                 + ''.join(f'  {t}: {n}\n' for t, n in sorted(names.items())))
    p = subprocess.run([sys.executable, DRIVER, '--workbench', wb, '--product-root', prod, '--verbose', '--'] + files,
                       capture_output=True, text=True)
    shutil.rmtree(os.path.join(OUT, batch))
    return p.stdout + p.stderr


def expected(meta, tag, text):
    want = meta['expect']
    if want == 'pass':
        return tag == 'PASS'
    if want == 'mismatch':
        kind = f"mismatch {meta['mismatch']}" + (f" at {meta['at']}" if meta.get('at') else '')
        return tag == 'RED' and text.startswith(kind + ' - ')
    if want == 'not-comparable':
        return tag == 'UNVERIFIED'
    return tag == 'RED' and text.startswith(('invalid-anchor - ', 'coverage - '))


def judge(case, meta, out):
    """The regimes where the named target's finding is not the case's verdict, with what it got."""
    name, line = meta['target']['name'], meta['target']['line']
    statement = not IDENT.fullmatch(name)  # an assignment: its anchor's own line, no entity name
    found = []
    for ln in out.splitlines():
        m = FINDING.fullmatch(ln)
        if not m or os.path.dirname(m.group(2)) != ident(case):
            continue
        if (not statement and m.group(4) == name) or (statement and not m.group(4) and m.group(3) == str(line)):
            found.append((m.group(1), int(m.group(3) or 0), m.group(5).split(', '), m.group(6)))
    if len({f[1] for f in found}) > 1:  # one name declared twice: the declaration on the case's line
        found = [f for f in found if f[1] == line]
    bad = []
    for r in meta['regimes']:
        got = [f for f in found if r in f[2]]
        if len(got) != 1 or not expected(meta, got[0][0], got[0][3]):
            bad.append((r, ' | '.join(f'{f[0]} {f[3]}' for f in got) or 'no finding'))
    return bad


batches = collections.defaultdict(list)
for path in sorted(glob.glob(os.path.join(CORPUS, '*', '*', 'case.yaml'))):
    meta = yaml.safe_load(open(path, encoding='utf-8'))
    batches[tuple(meta['regimes'])].append((os.path.dirname(path), meta))
os.makedirs(OUT)
with ThreadPoolExecutor(max_workers=len(batches)) as pool:
    outs = dict(zip(batches, pool.map(lambda kv: run('-'.join(kv[0]), kv[0], kv[1]), batches.items())))
results = [(case, meta, outs[regimes]) for regimes, cases in batches.items() for case, meta in cases]
cases = [case for case, _, _ in results]
failed, verdicts, judgments = 0, collections.Counter(), 0
for case, meta, out in results:
    verdicts[meta['expect']] += 1
    judgments += len(meta['regimes'])
    for regime, got in judge(case, meta, out):
        failed += 1
        want = ' '.join(str(x) for x in (meta['expect'], meta.get('mismatch', ''), meta.get('at', '')) if x)
        print(f'not ok - {os.path.relpath(case, CORPUS)} [{regime}]: expected {want} for {meta["target"]["name"]}, got {got}')
if failed:
    print(f'# test-verify-anchors-corpus: {failed} of {judgments} judgments differ')
    sys.exit(1)
print(f'ok - the product-level verifier gives all {len(cases)} corpus cases their verdict in every listed regime '
      f'({judgments} judgments; cases: ' + ', '.join(f'{n} {k}' for k, n in sorted(verdicts.items())) + ')')
PY
leftover="$(ls -A "$TMPDIR")"
if [ -n "$leftover" ]; then
	printf 'not ok - the verifier leaves no scratch directory behind\n%s\n' "$leftover"
	exit 1
fi
echo "# test-verify-anchors-corpus: all assertions passed"
