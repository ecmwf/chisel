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

The detector has four arms, scanned over the product tree (`PRODUCT_ROOT`, resolved via
`lib/product-root.sh`: the product checkout in `port/product.yaml`, else `target/`):
(1) STRUCTURE anywhere - a `port/` directory,
`.claude`/`.opencode`, or `AGENTS.md`/`CLAUDE.md` files (incl. dangling symlinks), at
any depth, via `find`; (2) chisel vocabulary in file CONTENTS, case-insensitively, from
the shared `tools/conformance/chisel-vocabulary.txt`; (3) chisel vocabulary in COMMIT
SUBJECTS over the product's whole history, when `PRODUCT_ROOT` is a separate git repo
(skipped in the single-repo phase). Explicit `--product-root <dir>` scans that tree
(used here). Each arm is demonstrated INDEPENDENTLY below, so a fixture that goes red
proves the arm under test, not another arm.

## Seeded defects and per-arm red proofs

Each fixture isolates ONE leak so it cannot be masked by another arm.

- **Structure - `port/` only:** a tree with just a `port/` directory and an ordinary
  file -> RED, exit 1, one structural FAIL on `.../port`.
- **Structure - `.claude/` only:** a tree with a `.claude/` directory -> RED, exit 1.
- **Structure - nested governance, dangling symlink:** `sub/CLAUDE.md` -> a symlink to a
  nonexistent target, at depth -> RED, exit 1 (`find` lists the link by name even when
  dangling; a `[[ -f ]]` test would have missed it).
- **Structure - nested `AGENTS.md`:** `deep/nest/AGENTS.md` -> RED, exit 1 (any depth,
  not just the top level).
- **Content - uppercase term:** a file containing `/* Validation Ladder and Port Charter */`
  -> RED, exit 1, two content FAILs (`validation ladder`, `port charter`) - the scan is
  case-insensitive, so title-case leakage cannot slip through.
- **Commit subject - separate product repo:** a separate git repo whose history has a
  commit subject containing a denylist term -> RED, exit 1 on that subject. (Skipped,
  with a note, when `PRODUCT_ROOT` is not its own repo.)

## Green proof (defect removed)

- A clean anchored tree (only a `.c` file with `/* src: source_unit.F90:212 = 0.1 */`
  and `double cw = 0.1;`): GREEN, exit 0 - `0 leak(s)`. The SOURCE anchor is NOT flagged.
- The clean product tree that `tools/new-product.sh` seeds (a product-focused README only):
  GREEN, exit 0 - the canonical clean product baseline.

## Scope / non-defect signals confirmed

- Plain SOURCE anchors (`/* src: <path>:<line> = <literal> */`) are allowed: they carry
  no chisel branding and match no denylist term, so a faithfully anchored port stays
  GREEN (the C2 KEEP default is compatible with invisibility).
- The denylist is the SHARED `chisel-vocabulary.txt`, so this check and
  check-product-readme.sh cannot drift; a change to that file requires re-running BOTH
  demonstrations. Both checks preflight every pattern and exit 2 (UNRELIABLE) on an
  invalid regex, so a broken term cannot silently false-green.
- A missing product tree skips with exit 0 (when no product is wired yet there is nothing to scan).
- Bare `TRACE`/`gated`/`R0`-`R5` are deliberately absent from the denylist, so ordinary
  product code (stack traces, feature-gating) is not flagged.

## Comparison-logic version

The comparison logic is: directory/file presence checks (`port/`, `AGENTS.md`,
`CLAUDE.md`) plus `grep -rInE` of each `chisel-vocabulary.txt` term over the product
tree (binary files and `.git` excluded) plus the same terms over product commit
subjects. Re-run this demonstration after any change to the vocabulary file or the
scan logic (standing seeded-bug rule): a tree with a `port/` dir, a governance file, or
a process comment must go RED, and a clean anchored tree must stay GREEN.
