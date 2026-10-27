# Seeded-bug record - `check-live-tracked.sh`

A detector is trusted only once it has been SEEN to fail. This is the red-then-green
demonstration for `tools/conformance/check-live-tracked.sh` (wraps
`tools/coordination/check_live_tracked.py`), using a defect representative of the class it
targets - the real recorded failure, not a syntax error.

## The failure class (port/LESSONS.md)

`helper.F90` was a real, build-list-declared LIVE routine
(`source/<project>/src/CMakeLists.txt`) that was never committed. `tools/import-source.sh`
strips the nested `.git` on import, which demotes every imported file to untracked; the imported
`.gitignore` (harmless upstream - tracked files are immune to it) then starts excluding real
source (`source/<project>/.gitignore`: `build*`), and `git add -A` silently skips it. The main
working tree still held the untracked file (so checks passed there); a fresh worktree checked out
from git at the same commit did not have it at all.

`check-source-import.sh` already proves an AGGREGATE half of this: tracked-file COUNT under each
imported SOURCE `path` equals its provenance `tracked_files`. That is real and durable, but it is a
whole-tree SUM over a much larger set (the entire imported repo - tests, docs, cmake, ...) than the
dependency map/TRACE ever name; it can hold even while the SPECIFIC file the map/TRACE calls live
is the one missing. This check is the missing PER-FILE half: every dependency-map node, and every
TRACE row whose status is not `excluded`, must resolve to a file that both exists on disk and is
git-tracked.

## The seed

Reproduce exactly what the original `git add -A` did - un-track one LIVE file the SOURCE's own
`.gitignore` matches, leaving it present on disk:

```
git rm --cached -q source/<project>/src/helper.F90
```

## RED (defect present)

```
  [FAIL] map node 'helper' (source/<project>/src/helper.F90) is present on disk but
         UNTRACKED - excluded by: source/<project>/.gitignore:build*    source/<project>/src/helper.F90
  [FAIL] TRACE row 'helper' (source/<project>/src/helper.F90) is present on disk but
         UNTRACKED - excluded by: source/<project>/.gitignore:build*    source/<project>/src/helper.F90
check-live-tracked: checked 685 distinct LIVE-inventory file(s) (357 map node(s), 357 TRACE
row(s)); 2 violation(s).
RESULT: RED (exit 1) - a map/TRACE-named file is not git-tracked; git add -f it (once tracked,
.gitignore no longer applies).
```

Exit 1. Note the check names the offending path AND the exact `.gitignore` rule responsible (same
technique as `check-source-import.sh`), so the repair needs no investigation - and it fires from
BOTH the map side and the TRACE side independently (the id appears in each artifact's own scan),
so either artifact alone would have caught this.

## GREEN (defect removed)

```
git reset -q source/<project>/src/helper.F90
```

```
check-live-tracked: checked 685 distinct LIVE-inventory file(s) (357 map node(s), 357 TRACE
row(s)); 0 violation(s).
RESULT: GREEN (exit 0) - every map node and every live TRACE row is on disk and tracked.
```

Exit 0.

## Two further seeds, so the class is not just "matches an ignore rule"

- **Untracked, no ignore-rule match** (`git rm --cached -q source/<project>/src/other.F90`,
  which nothing in `.gitignore` matches): `[FAIL] map node 'abort1' (...) is present on disk but
  UNTRACKED (git ls-files does not list it)` - RED, exit 1. Proves the check does not depend on
  finding an ignore hint; the hint is a diagnostic convenience, not the detection mechanism (`git
  ls-files` membership is).
- **Missing from disk entirely** (`mv source/<project>/src/other.F90 /tmp/...`, simulating a
  truncated checkout): `[FAIL] map node 'abort1' (...) is LIVE but MISSING from disk (truncated
  checkout?)` - RED, exit 1, worded distinctly from the untracked case so the two failure shapes
  are never conflated in the output.

## Non-vacuity

- **No dependency map yet**: `RESULT: ... (skipping)`, exit 0 - a fresh instance with nothing
  imported is not a failure.
- **A map with zero nodes**: `the dependency map has no nodes - nothing to check (skipping)`, exit
  0 - an intentionally empty map (never produced by the real extractor - see
  `extract_dependencies.py`'s own zero-node guard) is not silently treated as "all live files
  verified".
- **No TRACE alongside the map**: still checks every map node (the whole SOURCE inventory), just
  skips the TRACE-row half; a real run prints `(357 map node(s), 0 TRACE row(s))` in that state, so
  a green result always states exactly what it verified, never asserting more than it checked.
- **Malformed map/TRACE** (bad YAML, non-mapping row, missing `source_root`): exit 2 UNRELIABLE,
  never a false GREEN.
- Every GREEN prints the exact counts checked (`N map node(s), M TRACE row(s)`), never a bare "OK" -
  a vacuous zero-file pass is visually distinct from a real 685-file pass.

## Scope / non-defect signals confirmed

- An `excluded` TRACE row (e.g. an UNWAM=OFF file) is deliberately NOT required to be tracked by
  the TRACE-side scan; a dead/excluded file dropping out of git is not this check's concern (it is
  still checked from the MAP side, since the map covers the whole SOURCE tree regardless of
  liveness - only the TRACE half narrows to the live subset).
- Re-tracking with `git add -f` (never a plain `git add`, since the `.gitignore` rule still applies
  until the file is force-added) is durable: once tracked, `.gitignore` no longer affects it, so
  this check stays green without repeated intervention.


## Paths read NUL-separated (added 2026-10-26)

The tracked set came from `git ls-files` in line form, which C-quotes a path holding a non-ASCII
byte, a double quote or a newline (`"source/h\303\266he.f90"`). The quoted string matched no map or
TRACE path, so a tracked file with such a name read as present but UNTRACKED (a false RED). It now
reads `git ls-files -z`. Automated in `tools/tests/test-git-paths-z.sh`: the non-ASCII and the
double-quote names fail against the line form and pass against `-z`; an untracked file is still RED.
