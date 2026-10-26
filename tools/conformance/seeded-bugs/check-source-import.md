# Seeded-bug record - `check-source-import.sh`

A detector is trusted only once it has been SEEN to fail. This is the red-then-green
demonstration for `tools/conformance/check-source-import.sh`, using a defect representative of the
class it targets - not a syntax error.

## The failure class

Importing a SOURCE tree strips its nested `.git`. Every imported file thereby becomes UNTRACKED,
and the SOURCE's own `.gitignore` - inert upstream, because tracked files are immune to it - starts
excluding real source. A subsequent `git add -A` exits 0 and silently omits those files.

The bug is doubly quiet:
- the main working tree still HOLDS the untracked file, so checks pass there;
- every fresh clone and every worker WORKTREE lacks it and fails.

Green in the main tree, red in every worktree, is the signature.

## The seed

In a scratch worktree of a project whose provenance records `tracked_files: 449`, un-track one
live source file that the SOURCE's own `.gitignore` matches - reproducing exactly what the
original `git add -A` did:

```
git rm --cached -q <source-root>/<a-live-file-matching-an-ignore-pattern>
```

The file remains on disk (as it does in the real defect); only its tracked status is removed.

## RED (defect present)

```
  FAIL <source-root>: 448 tracked, but 449 were tracked upstream (1 MISSING).
       These present-but-untracked files are being excluded:
         <source-root>/.gitignore:9:build*	<source-root>/<...>/build<something>.F90
       The SOURCE is the specification; stage them faithfully with the force flag:
         git add -f <the paths above>
       (Once tracked, .gitignore no longer applies - the repair is permanent.)
RESULT: RED (exit 1) - an imported SOURCE is not fully tracked; the specification is incomplete.
```

Exit 1. Note the check does not merely report a count mismatch: it names the offending path AND
the exact `.gitignore` line responsible, so the repair needs no investigation.

## GREEN (defect removed)

```
git add -f <the path>
```

```
  OK  <source-root>: 449 tracked = 449 upstream
check-source-import: 1 imported SOURCE(s) fully tracked. RESULT: GREEN
```

Exit 0.

## Non-vacuity

Two further states were exercised so a pass cannot be vacuous:

- **No provenance directory** (a fresh instance that has imported nothing): prints
  `RESULT: GREEN (skip)`, exit 0 - it does not invent a failure where there is nothing to check.
- **Provenance present and complete**: prints the per-source `OK <path>: N tracked = N upstream`
  line, so a green states the count it actually verified rather than asserting success silently.

A malformed provenance (missing `path`/`tracked_files`, a non-numeric count, or a path that does
not exist) exits 2 UNRELIABLE rather than 0, so an unreadable input can never read as a pass.

## Reading the provenance as YAML

The provenance used to be read with a line scan (`sed`), which read text, not data: it kept an
inline comment as part of the value (`path: src   # the tree` became `src#thetree`, a path that
does not exist - a false UNRELIABLE), and of a repeated key it took the first copy, so
`tracked_files: 2` followed by `tracked_files: 3` passed while every PyYAML reader refuses the file
(a false GREEN). It now reads through the shared strict reader `tools/coordination/yaml_get.py`:
the comment is not part of the value (GREEN), a repeated key is UNRELIABLE (exit 2), and so is a
missing python3 or PyYAML - never a pass. Automated in `tools/tests/test-yaml-callers.sh`, where
both cases fail against the line scan and pass against the reader; a real shortfall is still RED.

## Why this check exists when the importer already warns

`tools/import-source.sh` detects the same condition at import time and prints a warning plus a
`git add -f` hint. That guard is correct but EPHEMERAL - one line of output to ONE session. The
session that stages and commits the import is frequently a later one, and every session after
that inspects a repo whose shortfall has become invisible. The provenance, by contrast, records
`tracked_files` permanently. The detection evidence is therefore committed and durable while the
warning is not; this check supplies the missing durable half, re-deriving the comparison on every
conformance run for the life of the project.
