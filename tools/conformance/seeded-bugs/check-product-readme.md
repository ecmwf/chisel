# SEEDED-BUG DEMONSTRATION - conformance/check-product-readme

- Date: 2026-06-15 (new detector, WS-A: the product README is about the product)
- Detector: tools/conformance/check-product-readme.sh
- Failure class targeted: porting-process ("chisel-meta") vocabulary leaking into the
  product README. A consumer reading the ported codebase must see an ordinary project
  README - what it does, where it came from, how to build and run it - never the
  scaffolding that produced it (charter, TRACE, reference runs, gates, anchors, sprints).
- Exit-code contract: 0 GREEN (no methodology vocabulary, or no README to check), 1 RED
  (at least one leaked term), 2 UNRELIABLE (could not run).

The detector scans the product README (default `target/README.md`, override with
`--readme` / `PRODUCT_README`) against a denylist of methodology phrases, matched
case-insensitively. Phrases are preferred over bare words so ordinary product prose is
not flagged (e.g. "port to a new platform" passes; "port charter" does not).

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
  `reference run`. `25 term(s); 8 leak(s). RESULT: RED`.

## Green proof (defect removed)

- A product-focused README (`A C implementation of the original solver
  (https://example.org/original)`, a `cmake` build block, a run command): GREEN, exit 0 -
  `25 term(s); 0 leak(s). RESULT: GREEN`.
- The in-repo `target/README.md` (the instantiated product-README placeholder): GREEN,
  exit 0 - it is the canonical example of a clean product README.

## Scope / non-defect signals confirmed

- A missing product README skips with exit 0 (vacuous-clean, not "could not run"):
  before the product exists there is nothing to leak.
- Ordinary product wording survives: "port", "build", "run", "license", and a link to
  the original project are not methodology vocabulary.

## Comparison-logic version

The comparison logic is the `DENY` array (25 extended-regex phrases) matched with
`grep -nEi`. Re-run this demonstration after any change to that denylist (standing
seeded-bug rule): a widened list must still flag a genuine leak, and any newly added
term must move a README containing it from GREEN (before) to RED (after).
