# SEEDED-BUG DEMONSTRATION - conformance/check-claims

- Date: 2026-06-16 (new detector, WS-H: claim integrity)
- Detector: tools/conformance/check-claims.sh (wraps tools/coordination/check_claims.py)
- Failure class targeted: a parallel port coordinates on CLAIMS - reserving a work item before
  porting it. By default the claim is the local file port/claims/<trace-id>.yaml (the provisioned
  worktree is the write lock); the advanced multi-operator path is a pushed ref refs/claims/<trace-id>
  (--from-refs) whose push-to-create is atomic. Neither the file system nor git can tell whether a
  claim is well-formed, whether two DIFFERENT ids quietly reserve the SAME source (the same module
  ported twice), or whether a branch wandered outside what it claimed and into someone else's owned
  surface. Unchecked, these are silent: duplicated effort found at merge, a leaf branch quietly
  editing a foundation, or a claim aliased so a checker waves it through.
- Exit-code contract: 0 GREEN (every claim verifies, or there are none yet), 1 RED (a claim
  is malformed, duplicates/overlaps another, or its branch left its surface), 2 UNRELIABLE
  (no python3 / PyYAML / git, an unreadable or missing input, or a bad invocation).

Claims are read from port/claims/*.yaml by default; `--from-refs` reads refs/claims/* (`git cat-file`
the blob each ref points to), and fixtures/tests pass `--claims-dir DIR` to read `<trace-id>.yaml`. The
shipped GOOD fixtures live in `tools/coordination/fixtures/claims/`. Three modes: SCHEMA and
DUPLICATE over all claims (the no-arg CI pass), and BRANCH-DIFF per branch on demand
(`--claim ID --files-from FILE`, or `--claim ID --branch REF --base BASE`). Paths are
canonicalized (`posixpath.normpath`; absolute or root-escaping `..` rejected) and glob
matching is directory-aware (`*`/`?` do not cross `/`).

## Seeded defects and red proofs

Each defect is a one-field mutation of a good fixture, run from a scratch copy; the
non-defective siblings in the same run stay unflagged (the detector discriminates).

### SCHEMA (the no-arg pass)

A directory of five claims, each with one defect, run with `--claims-dir` -> RED, exit 1:
- `[FAIL] m100-dotdot: source[0] 'io/../io/read_input.f90' must not contain a '..' segment`
- `[FAIL] m101-empty: source[0] must be a non-empty path string`  (empty list item)
- `[FAIL] m102-nonscalar: target[0] must be a non-empty path string`  (a mapping, not a path)
- `[FAIL] m103-glob: source[0] 'io/*.f90' must be a concrete path, not a glob`
- `[FAIL] m104@bad: ref/file name 'm104@bad' is not a valid trace-id (^[A-Za-z0-9][A-Za-z0-9_.-]*$)`
- `[FAIL] m104@bad: id 'm104@bad' is not a valid trace-id (^[A-Za-z0-9][A-Za-z0-9_.-]*$)`

The same section also fires on: an `id` that does not match the ref/file name; a `state` off
the `created|active|stale` enum; a missing/non-scalar required field; a duplicate YAML key
(strict loader); and a claim ref that points to a commit or annotated tag instead of a blob
(`<ref> points to a commit, not a blob`).

### DUPLICATE (the no-arg pass)

- **Same SOURCE reserved twice (both live):** add `m009-dup` (`active`) whose `source` is also
  `io/read_input.f90` -> RED, exit 1:
  `[FAIL] live claims 'm001-io-read' and 'm009-dup' overlap on source: 'io/read_input.f90' vs 'io/read_input.f90'`
  Overlap is directory-aware and alias-proof: it also fires for `io/` vs `io/read_input.f90`,
  and `io/../io/read_input.f90` canonicalizes so it can no longer dodge the comparison.
- **Reserving over a stale claim (the offline-branch duplication):** a `stale` `m020` and a new
  `active` `m021` on the same SOURCE -> RED, exit 1:
  `[FAIL] claims 'm020-stale' and 'm021-active' overlap on source ('grid/init.f90'); 'm020-stale' is stale and must be triaged before reclaiming (stale is never auto-freed)`
  (stale is "needs triage", never auto-freed - so a stale overlap is RED, not silently free.)
- A duplicate work-item `id` across two claims is reported as `duplicate work-item id '...'`.

### BRANCH-DIFF (on demand, per branch)

For `m003-solver-step` (explicit `paths`: `solver/step.c`, `solver/step_helpers.c`, its status
fragment):
- **A file outside the surface:** `--files-from` a list of `solver/step.c` + `Makefile` -> RED:
  `[FAIL] branch touched 'Makefile' outside claim 'm003-solver-step' write surface`
  `solver/step.c` is NOT flagged (it is in the surface); only `Makefile` is.
- **A `..` escape:** `--files-from` a list containing `solver/../Makefile` -> RED:
  `[FAIL] branch touched 'Makefile' outside claim 'm003-solver-step' write surface`
  (canonicalized before the surface test, so the escape cannot smuggle a file in.)
- **Reaching an owned surface:** a leaf `m010-broad` whose `paths` are `io/` changes
  `io/formats/netcdf.c`, with `--owned-surfaces` listing `io/formats/` -> RED:
  `[FAIL] branch 'm010-broad' reaches owned surface 'io/formats' via 'io/formats/netcdf.c' (not granted in claim paths)`
  The sibling `io/read_input.c` is NOT flagged (in surface, not an owned sub-surface). A merely
  broader ancestor path (`io/`) does NOT grant the owned `io/formats/`; only an explicit grant does.

### Invocation guards (UNRELIABLE, exit 2 - kept distinct from RED)

- `--files-from` and `--branch` together -> `--files-from and --branch are mutually exclusive`.
- `--branch` without `--base` -> `--branch requires an explicit --base` (so a feature-branch
  diff against HEAD cannot silently produce an empty diff and pass).
- an explicit `--claims-dir` that does not exist -> `--claims-dir '...' is not a directory`
  (a typo'd path is operator error, not a clean "nothing to check").
- an unreadable claim FILE (OSError) is exit 2; a malformed-YAML claim is RED.

A malformed claim selected for branch-diff stays RED (its schema failure is real), never
downgraded to UNRELIABLE: `[FAIL] claim 'm001-io-read' is malformed; branch-diff skipped until it is fixed`.

## Green proof (defect removed)

- The shipped good fixtures, schema + duplicate: GREEN, exit 0 - `checked 3 claim(s); 0 violation(s)`.
- Branch-diff with the good change-list (all within `m003`'s surface) + the owned-surface list:
  GREEN, exit 0 - the solver files hit no owned surface.
- The base repo with no `port/claims/` (gitignored, absent in a fresh CI checkout): GREEN, exit 0 -
  `no claims ... nothing to check (skipping)`; a pilot that has not provisioned any worker is never blocked.

## Causal proof (the check is what catches it)

A claim passes only when its id is a valid trace-id matching its ref, its fields and state are
well-formed, its source/target are concrete clean paths, no other non-released claim shares its
source/target, and (for a diffed branch) every canonicalized changed path lies within the
claim's surface and grabs no ungranted owned surface. Mutate any one - alias a path with `..`,
invent a state, reserve a taken or stale source, touch a file outside the surface - and the
verdict moves GREEN -> RED on exactly that claim, naming the offending value. "Passed" means
the claim is structurally valid and non-conflicting, never "someone eyeballed the refs."

## Scope / non-defect signals confirmed

- Path comparison is canonical: `io/../io/x` == `io/x`, `solver/../Makefile` == `Makefile`;
  absolute paths and root escapes (`../x`) are rejected, so neither overlap nor surface checks
  can be dodged by spelling a path differently.
- Globs are directory-aware (`*`/`?` do not cross `/`, `**` spans), so `paths: ['io/*.c']`
  covers `io/a.c` but not `io/sub/a.c`; `source`/`target` reject globs outright (they name
  concrete files); character classes (`[...]`) are rejected as unsupported.
- The derived default surface (when `paths` is omitted) is the target paths + the item's
  `port/status/<id>.yaml` ONLY - evidence is NOT blanket-granted, so a leaf cannot touch an
  arbitrary evidence pack, a SIGNOFF, or another item's review via the default; a branch that
  legitimately writes evidence lists that path in `paths`.
- Only NON-RELEASED claims (created|active|stale) participate in overlap; there is no auto-free
  of stale, matching team-coordination.md.
- BRANCH-DIFF is on demand (the dashboard/integrator runs it per branch); the no-arg CI pass
  enforces SCHEMA + DUPLICATE and skips branch-diff (no branch to diff).

## Comparison-logic version

The logic is: enumerate claims (port/claims/*.yaml by default, refs/claims/* blobs with `--from-refs`,
or `--claims-dir <id>.yaml`); per claim
`verify_schema(expected_id, claim)` (trace-id regex, field/enum/path-list validation);
across schema-valid claims `find_duplicates` (id collisions + canonical source/target overlap
among created|active|stale, stale-overlap flagged); and, when a branch is supplied,
`verify_branch_diff(id, claim, changed, owned)` against the claim `paths` (or the derived
default) with canonical, directory-aware matching. Empty violation list -> GREEN, any
violation -> RED, a bad environment/invocation -> UNRELIABLE. Re-run this demonstration after
any change to the schema rules, the canonicalization, the overlap rule, or the surface/glob
logic (standing seeded-bug rule): every listed defect must go RED, the guards exit 2, and the
good fixtures stay GREEN.
