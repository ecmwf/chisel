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

Resolving the root from the common git dir, the same run reports what the main checkout reports:

```
$ cd .worktrees/alpha && bash tools/conformance/check-worktree-freshness.sh; echo "exit=$?"
NOTICE: check-worktree-freshness: stale worktree - alpha: 1 commit(s) behind 'refs/heads/main' ...
exit=0
```

A git older than 2.31 does not know `rev-parse --path-format`, echoes the option back and exits 0;
that output is not a directory, so the check falls back to the top level rather than taking it as a
root (without that test the run dies with exit 2, `dirname: unrecognized option`). Automated in
`tools/tests/test-worktree-freshness-root.sh` (main checkout, linked worktree, a subdirectory of
it, and the old-git fallback from both).

Fixture cleanup: the demonstration runs entirely in a scratch directory (two throwaway git repos
and their linked worktrees) which is removed afterwards; it creates nothing inside the repository
under test and leaves no fixture committed here.

## Non-vacuity

The detector is not trivially quiet:

- Remove the product pass and the seeded drift above returns to a SILENT exit 0 while the piece
  remains undispatchable - the exact regression this record exists to pin.
- Remove the fail-closed handling and the missing-worktree case falls from exit 2 to exit 0,
  turning "cannot tell" into "fine".
- A single-repo layout (no `port/product.yaml`) must be unaffected: the product pass is skipped
  entirely rather than reporting every piece undeterminable.

## Comparison-logic version

The logic is: resolve the MAIN workbench root from the common git dir (the top level when git
cannot report it as an absolute directory), so a run from a linked worktree examines the same
claims; resolve the live claim ids; resolve the workbench mainline tip (local branch first,
then `origin/HEAD`); for each live id, take the linked worktree `.worktrees/<id>`, require a linked
git-dir and an attached HEAD, and compute `merge-base(HEAD, mainline_tip)` - equal to the tip means
current (commits AHEAD are work, not staleness), behind the tip means stale by
`rev-list --count merge-base..tip`. Then, only when `port/product.yaml` marks the two-repo layout,
repeat for `.worktrees/product-<id>` against the PRODUCT repo's own mainline resolved the same way.
Staleness accumulates into `NOTICE:` lines with a per-worktree remedy and does not affect the exit
code; every unanswerable question (malformed claim, absent worktree, non-linked git-dir, detached
HEAD, unresolvable mainline, unresolvable merge-base) accumulates into the UNDETERMINABLE list and
exits 2.
