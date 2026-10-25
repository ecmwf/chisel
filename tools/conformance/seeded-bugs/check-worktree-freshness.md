# SEEDED-BUG DEMONSTRATION - conformance/check-worktree-freshness

- Date: 2026-08-25 (new detector, parallel-port coordination: worktree currency)
- Detector: tools/conformance/check-worktree-freshness.sh
- Failure class targeted: a worktree is provisioned ONCE, at the mainline tip of that moment, and
  the mainline then keeps moving. Isolation is necessary but not sufficient - a piece can be
  perfectly isolated and still be built on a base that no longer exists, so it reasons from dead
  commits, re-introduces already-fixed defects, and runs checkers that have since been corrected.
  None of this is visible in the piece's own diff, and "remember to rebase before dispatch" is an
  orchestrator intention rather than a control (see the meta-lesson in
  references/failure-modes.md). `assert_isolated.sh` REFUSES a stale worktree at the moment of use;
  this detector surfaces the same condition at PREFLIGHT, so drift is fixed before a round is
  dispatched rather than discovered mid-round.
- **Enforcement status: ADVISORY, not enforcing.** Staleness is reported as `NOTICE:` and the check
  **exits 0**. This is deliberate and is the one thing to understand about this record: stale
  worktrees are operational drift, not a code defect, and failing the suite for drift trains
  operators to ignore a red check. The detector therefore has no RED state at all.
- Exit-code contract: **0** = every live claim's worktrees are current (silent), OR one or more are
  stale (reported as `NOTICE:`, suite unaffected), OR there are no live claims. **2** = UNRELIABLE:
  a malformed claim, a missing or detached worktree, an unresolvable mainline, or any freshness
  question that cannot be answered. **1 is never returned.** "Cannot tell" must never read as
  "fine", so the undeterminable case is the only one that blocks.

In the two-repo layout a piece has TWO linked worktrees: the workbench worktree `.worktrees/<id>`
and the product worktree `.worktrees/product-<id>`, whose staleness is measured against the PRODUCT
repo's own mainline, not the workbench's. An earlier revision examined only the workbench worktree
and so reported a silent exit 0 for a piece whose product worktree was stale or entirely missing - a
piece `assert_isolated.sh` refuses the instant it is dispatched, which is exactly what a preflight
exists to prevent.

## Seeded demonstration

Fixture: a workbench repo with `port/product.yaml` (two-repo layout) and one live claim `alpha`,
plus a separate product repo. Both worktrees are provisioned at their respective tips; the PRODUCT
mainline is then advanced by one commit.

### Seeded drift - product worktree stale (previously a SILENT exit 0)

```
$ bash tools/conformance/check-worktree-freshness.sh; echo "exit=$?"
NOTICE: check-worktree-freshness: stale worktree - product-alpha: 1 commit(s) behind product
  'refs/heads/main' (merge-base 45dbb30 behind tip f61d738)
  - fix: git -C ".../.worktrees/product-alpha" rebase "refs/heads/main"
check-worktree-freshness: 1 stale worktree(s) ...; 1 live claim(s) discovered, 2 examined fresh/stale.
exit=0
```

`2 examined` against `1 live claim` is the load-bearing detail: both the workbench and the product
worktree were examined. The notice names the exact remedy, so the operator need not derive it. Note
the exit is 0 by design - the DEMONSTRATION is that the notice appears where previously nothing did,
not that the suite turns red.

### Cleared - after running the named remedy

```
$ git -C .worktrees/product-alpha rebase main
$ bash tools/conformance/check-worktree-freshness.sh; echo "exit=$?"
(no product-alpha notice)
exit=0
```

### UNRELIABLE - product worktree removed (must never read as fine)

```
$ git -C <product-repo> worktree remove --force .worktrees/product-alpha
$ bash tools/conformance/check-worktree-freshness.sh; echo "exit=$?"
check-worktree-freshness: freshness UNDETERMINABLE for 1 item(s) (UNRELIABLE):
  - alpha: two-repo layout but no product worktree at '.../.worktrees/product-alpha'
    - freshness UNDETERMINABLE (assert_isolated will refuse this piece)
exit=2
```

### Seeded drift - run from inside a linked worktree (previously a SILENT exit 0)

The live claims (`port/claims/`, gitignored) and the `.worktrees/<id>` they name belong to the MAIN
workbench checkout. A worker or reviewer runs the suite inside its own linked worktree, whose top
level holds neither, so a check anchored on `--show-toplevel` read "no live claims" and skipped:

```
$ cd .worktrees/alpha && bash tools/conformance/check-worktree-freshness.sh; echo "exit=$?"
check-worktree-freshness: no live claims under port/claims/ - nothing to check (skipping).
exit=0
```

Resolving the main workbench instead, the same run reports what the main checkout reports:

```
$ cd .worktrees/alpha && bash tools/conformance/check-worktree-freshness.sh; echo "exit=$?"
NOTICE: check-worktree-freshness: stale worktree - alpha: 1 commit(s) behind 'refs/heads/main' ...
exit=0
```

Git records no path for the main checkout. The parent of the common git dir is the checkout only in
the ordinary `<root>/.git` layout; `git worktree list` names the common git dir minus a trailing
`/.git`, which is the same. Under `--separate-git-dir` or a submodule both name the git dir or the
directory that holds it; it has no claims, so the run is again "nothing to check". When that git dir is itself named
`.git` (`git init --separate-git-dir <meta>/.git <workbench>`), `<meta>` looks to git exactly like a
checkout, so no test on the candidate directory can reject it. The root is therefore read from where
the invoking tree sits, and confirmed by git:

- the main working tree (its git dir IS the common git dir): its own top level;
- a linked worktree at `<root>/.worktrees/<name>` - the layout `provision_worker.sh` creates and
  this check reads: `<root>`, once git confirms `<root>` is the top level of a main working tree
  with the same common git dir;
- anything else - a linked worktree elsewhere, a bare main repository, a git dir that does not
  resolve - is UNRELIABLE (exit 2), never a skip.

Only plain `--git-dir`, `--git-common-dir` and `--show-toplevel` are used, resolved against the
current directory: a git older than 2.31 does not know `--path-format`, echoes it back and exits 0,
and resolving through it with a fallback to `--show-toplevel` would bring the silent pass above
straight back on such a git.

### Seeded drift - external git dir named .git (previously a SILENT exit 0)

The workbench is created with `git init --separate-git-dir /tmp/meta/.git /tmp/workbench`, given a
live claim `beta` with its worktree at `.worktrees/beta`, and its mainline advanced. Taking the
parent of the common git dir (`/tmp/meta`) as the root, a run from the linked worktree skips the
real claim:

```
$ cd /tmp/workbench/.worktrees/beta && bash tools/conformance/check-worktree-freshness.sh; echo "exit=$?"
check-worktree-freshness: no live claims under port/claims/ - nothing to check (skipping).
exit=0
```

Read from the worktree's position and confirmed by git, the root is `/tmp/workbench`:

```
$ cd /tmp/workbench/.worktrees/beta && bash tools/conformance/check-worktree-freshness.sh; echo "exit=$?"
NOTICE: check-worktree-freshness: stale worktree - beta: 1 commit(s) behind 'refs/heads/main' ...
exit=0
```

### UNRELIABLE - the main checkout cannot be established (must never read as fine)

```
$ cd /tmp/elsewhere && bash tools/conformance/check-worktree-freshness.sh; echo "exit=$?"   # linked, not under .worktrees/
check-worktree-freshness: linked worktree '/tmp/elsewhere' is not at <workbench>/.worktrees/<name> - the
  main workbench is unknown, freshness UNDETERMINABLE (UNRELIABLE)
exit=2
```

Automated in `tools/tests/test-worktree-freshness-root.sh`, which builds each layout:

- **Ordinary `<root>/.git`:** the main checkout, a subdirectory of it, a linked worktree and a
  subdirectory of that all report the same stale worktree. This holds on the installed git and on a
  stand-in git without `--path-format`.
- **`--separate-git-dir` named `.git` and named otherwise, and the submodule layout:** the main
  checkout and a linked worktree report the same stale worktree, including on the stand-in old git.
- **UNRELIABLE cases:** a common git dir that does not resolve, a linked worktree outside
  `.worktrees/`, and a bare main repository at `<dir>/.git` with its linked worktree at
  `<dir>/.worktrees/<id>`.

Fixture cleanup: the demonstration runs entirely in a scratch directory (throwaway git repos and
their linked worktrees) which is removed afterwards; it creates nothing inside the repository
under test and leaves no fixture committed here.

## Non-vacuity

The detector is not trivially quiet:

- Remove the product pass and the seeded drift above returns to a SILENT exit 0 while the piece
  remains undispatchable - the exact regression this record exists to pin.
- Remove the fail-closed handling and the missing-worktree case falls from exit 2 to exit 0,
  turning "cannot tell" into "fine".
- A single-repo layout (no `port/product.yaml`) must be unaffected: the product pass is skipped
  entirely rather than reporting every piece undeterminable.
- Anchor on the invoking worktree's top level - directly, or as a fallback when the git dirs cannot
  be read - and a run from a linked worktree returns to the silent "nothing to check". Take the
  parent of the common git dir instead and a `--separate-git-dir` or submodule workbench reads no
  claims; take it only when that dir is named `.git` and an external git dir named `.git` still does.

## Comparison-logic version

The logic is: resolve the MAIN workbench root - from the main working tree (git dir equal to the
common git dir) its top level; from a linked worktree at `<root>/.worktrees/<name>`, `<root>` once
git confirms it is the top level of a main working tree with the same common git dir; otherwise, or
when a git dir does not resolve, UNRELIABLE - reading only plain
`--git-dir`/`--git-common-dir`/`--show-toplevel` resolved against the current directory; resolve the
live claim ids; resolve the workbench mainline tip (local branch first, then `origin/HEAD`); for
each live id, take the linked worktree `.worktrees/<id>`, require a linked git-dir and an attached
HEAD, and compute `merge-base(HEAD, mainline_tip)` - equal to the tip means current (commits AHEAD
are work, not staleness), behind the tip means stale by `rev-list --count merge-base..tip`. Then,
only when `port/product.yaml` marks the two-repo layout, repeat for `.worktrees/product-<id>`
against the PRODUCT repo's own mainline resolved the same way. Staleness accumulates into `NOTICE:`
lines with a per-worktree remedy and does not affect the exit code; every unanswerable question
(malformed claim, absent worktree, non-linked git-dir, detached HEAD, unresolvable mainline,
unresolvable merge-base) accumulates into the UNDETERMINABLE list and exits 2.
