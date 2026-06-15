# SEEDED-BUG DEMONSTRATION - conformance/check-product-readme

- Date: 2026-06-15 (new detector, WS-A: the product README is about the product)
- Detector: tools/conformance/check-product-readme.sh
- Failure class targeted: porting-process ("chisel-meta") vocabulary leaking into the
  product README. A consumer reading the ported codebase must see an ordinary project
  README - what it does, where it came from, how to build and run it - never the
  scaffolding that produced it (charter, TRACE, reference runs, gates, anchors, sprints).
- Exit-code contract: 0 GREEN (no methodology vocabulary, or no default README to check),
  1 RED (at least one leaked term), 2 UNRELIABLE (could not run, or an explicitly
  requested README is missing/unreadable).

The detector scans the product README (default resolved via `lib/product-root.sh`: the
product checkout in `port/product.yaml` plus `/README.md`, else `target/README.md`; override
with `--readme` / `PRODUCT_README`) against a denylist of methodology
phrases, matched case-insensitively. Phrases are preferred over bare words so ordinary
product prose is not flagged (e.g. "port to a new platform", "stack traces are logged",
and "gated behind a feature flag" all pass; "port charter" does not). A missing DEFAULT
README skips (exit 0 - the product is not set up yet), but an EXPLICITLY requested
README that is missing/unreadable is "cannot run" (exit 2).

## Seeded defect (representative of the class)

A product README that documents the porting process instead of the product, e.g.:

```
Run the sprint with /port-sprint-start, then consult the port charter and
target/CONVENTIONS.md. Status is mirrored in port/TRACE.yaml; every module passes the
validation ladder before it is gated. See docs/evidence for the gate evidence.
Compare against the canonical reference run.
```

## Red proof

- The fixture above: RED, exit 1, 8 leaks reported with file:line and the matched term -
  `port charter`, `/port-[a-z]` (the `/port-sprint-start` command), `TRACE.yaml`,
  `CONVENTIONS.md`, `validation ladder`, `docs/evidence`, `gate evidence`, and
  `reference run`. `29 term(s); 8 leak(s). RESULT: RED`.
- A second fixture exercising the phrase terms - `See TRACE for status. Independent
  review and human sign-off happen before gated modules; the evidence pack lives with
  the port handoff.`: RED, exit 1, 4 leaks - `independent review`, `human sign-off`,
  `evidence pack`, `port handoff`. (The bare words `TRACE` and `gated` are deliberately
  NOT in the denylist - see scope signals - so the leak is caught by the phrases.)

## Green proof (defect removed)

- A product-focused README (`A C implementation of the original solver
  (https://example.org/original)`, a `cmake` build block, a run command): GREEN, exit 0 -
  `29 term(s); 0 leak(s). RESULT: GREEN`.
- The clean product README that `tools/new-product.sh` seeds into a new product repo
  (a product-focused placeholder): GREEN, exit 0 - the canonical clean baseline.

## Scope / non-defect signals confirmed

- A missing DEFAULT product README skips with exit 0 (vacuous-clean, not "could not
  run"): before the product exists there is nothing to leak.
- An EXPLICITLY requested README (`--readme <path>` / `PRODUCT_README`) that is
  missing/unreadable returns exit 2, and `--readme` with no value returns exit 2 - both
  are "cannot run", kept distinct from RED.
- The product README path is resolved against the repo root (from `port/product.yaml`, else
  `target/`), so the check gives the same verdict whether invoked from the root or a subdirectory.
- Ordinary product wording survives (GREEN): "port", "build", "run", "license", a link
  to the original project, "stack traces are logged", and "gated behind a feature flag"
  are not methodology vocabulary. Bare `TRACE`/`gated`/`R0`-`R5` are intentionally
  excluded from the denylist because they collide with ordinary product prose (stack
  traces, feature-gating, hardware registers); the methodology-specific phrases
  (`TRACE.yaml`, `validation ladder`, `independent review`, ...) carry the signal.

## Comparison-logic version

The comparison logic is the shared denylist `tools/conformance/chisel-vocabulary.txt`
(29 extended-regex phrases, one per line; the same file check-product-invisibility.sh
reads) matched with `grep -nEi`. Re-run this demonstration - and the
check-product-invisibility demonstration - after any change to that file (standing
seeded-bug rule): a widened list must still flag a genuine leak, and any newly added
term must move a README containing it from GREEN (before) to RED (after).
