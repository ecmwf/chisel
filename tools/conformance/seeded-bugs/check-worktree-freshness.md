# SEEDED-BUG DEMONSTRATION - conformance/check-worktree-freshness

- Date: 2026-08-25 (new detector, parallel-port coordination: worktree currency)
- Detector: tools/conformance/check-worktree-freshness.sh
- Failure class targeted: a worktree is provisioned ONCE, at the mainline tip of that moment, and
  the mainline then keeps moving. Isolation is necessary but not sufficient - a piece can be
  perfectly isolated and still be built on a base that no longer exists, so it reasons from dead
  commits, re-introduces already-fixed defects, and runs checkers that have since been corrected.
  Nothing about this is visible in the piece's own diff, and "remember to rebase before dispatch"
  is an orchestrator intention rather than a control (see the meta-lesson in
  references/failure-modes.md). `assert_isolated.sh` REFUSES a stale worktree at the moment of
  use; this detector surfaces the same condition at PREFLIGHT, so the drift is fixed before a
  round is dispatched rather than discovered mid-round.
- Exit-code contract: 0 GREEN (every live claim's worktrees are current, or there are no live
  claims), 1 RED (reserved - staleness itself is reported as NOTICE, see below), 2 UNRELIABLE
  (a malformed claim, a missing or detached worktree, or any freshness question that cannot be
  answered).

Staleness is deliberately reported as `NOTICE:` and does NOT fail the suite: it is operational
drift, not a code defect, and failing the suite for it would train operators to ignore a red gate.
An UNDETERMINABLE freshness question is different and DOES block (exit 2) - "cannot tell" must
never read as "fine".

In the two-repo layout a piece has TWO linked worktrees: the workbench worktree `.worktrees/<id>`
and the product worktree `.worktrees/product-<id>`, whose staleness is measured against the
PRODUCT repo's own mainline, not the workbench's. An earlier revision of this detector examined
only the workbench worktree and therefore reported GREEN for a piece whose product worktree was
stale or entirely missing - a piece `assert_isolated.sh` would refuse the instant it was
dispatched, which is exactly what a preflight exists to prevent.

## Seeded demonstration

Fixture: a workbench repo with `port/product.yaml` (two-repo layout) and one live claim `alpha`,
plus a separate product repo. Both worktrees are provisioned at their respective tips; the PRODUCT
mainline is then advanced by one commit.

### RED - product worktree stale (was GREEN before the product pass existed)

```
$ bash tools/conformance/check-worktree-freshness.sh
NOTICE: check-worktree-freshness: stale worktree - product-alpha: 1 commit(s) behind product
  'refs/heads/main' (merge-base 45dbb30 behind tip f61d738)
  - fix: git -C ".../.worktrees/product-alpha" rebase "refs/heads/main"
check-worktree-freshness: 1 stale worktree(s) ...; 1 live claim(s) discovered, 2 examined fresh/stale.
```

The `2 examined` against `1 live claim` is the load-bearing detail: both the workbench and the
product worktree were examined. The notice names the exact remedy, so the operator does not have
to derive it.

### GREEN - after running the named remedy

```
$ git -C .worktrees/product-alpha rebase main
$ bash tools/conformance/check-worktree-freshness.sh
(no product-alpha line; suite GREEN)
```

### UNRELIABLE - product worktree missing (must never read as GREEN)

```
$ git -C <product-repo> worktree remove --force .worktrees/product-alpha
$ bash tools/conformance/check-worktree-freshness.sh; echo $?
check-worktree-freshness: freshness UNDETERMINABLE for 1 item(s) (UNRELIABLE):
  - alpha: two-repo layout but no product worktree at '.../.worktrees/product-alpha'
    - freshness UNDETERMINABLE (assert_isolated will refuse this piece)
2
```

## Non-vacuity

The detector is not trivially green: removing the product pass turns the RED case above into a
silent GREEN while the piece remains undispatchable, and removing the fail-closed handling turns
the missing-worktree case from exit 2 into exit 0. Both were observed before the fix and are the
reason this record exists.
