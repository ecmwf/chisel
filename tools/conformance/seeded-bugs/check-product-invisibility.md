# SEEDED-BUG DEMONSTRATION - conformance/check-product-invisibility

- Date: 2026-06-15 (new detector, WS-C: the product tree is chisel-invisible)
- Detector: tools/conformance/check-product-invisibility.sh
- Failure class targeted: methodology leakage into the product tree. After the two-repo
  split, a consumer cloning the product must see an ordinary codebase - no porting
  state, no governance files, no chisel vocabulary in code/comments/commit subjects -
  beyond the plain SOURCE anchors (`/* src: ... */`) the KEEP-anchors decision (C2)
  retains.
- Exit-code contract: 0 GREEN (no leakage, or no product tree yet), 1 RED (leakage),
  2 UNRELIABLE (no tooling / no vocabulary file).

The detector scans the product tree (`PRODUCT_ROOT`, default `target/` in the
single-repo phase) for: (1) a `port/` directory, (2) porting governance files
(`AGENTS.md`/`CLAUDE.md`), (3) chisel vocabulary in file contents
(`tools/conformance/chisel-vocabulary.txt`, the shared denylist), and (4) chisel
vocabulary in recent commit subjects when `PRODUCT_ROOT` is a separate git repo
(skipped in the single-repo phase). Explicit `--product-root <dir>` scans that tree
(used here).

## Seeded defect (representative of the class)

A product tree carrying all three tree-level leaks at once: a `port/` directory, an
`AGENTS.md`, and a source file whose comment cites the porting process - alongside a
legitimate, allowed SOURCE anchor:

```
prod/port/                       (directory)
prod/AGENTS.md                   "porting governance"
prod/src/solver.c:
    /* src: source_unit.F90:212 = 0.1 */              <- allowed (plain SOURCE anchor)
    double cw = 0.1;
    /* see the validation ladder and the port charter; TRACE.yaml tracks status */
```

## Red proof

- Command: `bash tools/conformance/check-product-invisibility.sh --product-root prod`.
- Result: RED, exit 1, 5 leaks - the `port/` directory, the `AGENTS.md`, and three
  content matches (`port charter`, `TRACE.yaml`, `validation ladder`).
  `29 term(s); 5 leak(s). RESULT: RED`. The `/* src: ... */` anchor on the line above is
  NOT flagged - SOURCE anchors are the provenance C2 keeps, and they match no denylist
  term.

## Green proof (defect removed)

- Same tree with `port/` and `AGENTS.md` removed and the process comment deleted,
  leaving only the anchored constant: GREEN, exit 0 - `29 term(s); 0 leak(s)`.
- The in-repo `target/` (the product placeholder): GREEN, exit 0 - it is already a clean
  product tree (a product-README placeholder and a `.gitkeep`).

## Scope / non-defect signals confirmed

- Plain SOURCE anchors (`/* src: <path>:<line> = <literal> */`) are allowed: they carry
  no chisel branding and match no denylist term, so a faithfully anchored port stays
  GREEN (the C2 KEEP default is compatible with invisibility).
- The denylist is the SHARED `chisel-vocabulary.txt`, so this check and
  check-product-readme.sh cannot drift; a change to that file requires re-running BOTH
  demonstrations.
- A missing product tree skips with exit 0 (before the split there is nothing to scan).
- The commit-subject scan activates only when `PRODUCT_ROOT` is a separate git repo;
  in the single-repo phase it is skipped with a note (the product has no own history).
- Bare `TRACE`/`gated`/`R0`-`R5` are deliberately absent from the denylist, so ordinary
  product code (stack traces, feature-gating) is not flagged.

## Comparison-logic version

The comparison logic is: directory/file presence checks (`port/`, `AGENTS.md`,
`CLAUDE.md`) plus `grep -rInE` of each `chisel-vocabulary.txt` term over the product
tree (binary files and `.git` excluded) plus the same terms over product commit
subjects. Re-run this demonstration after any change to the vocabulary file or the
scan logic (standing seeded-bug rule): a tree with a `port/` dir, a governance file, or
a process comment must go RED, and a clean anchored tree must stay GREEN.
