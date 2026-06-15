# SEEDED-BUG DEMONSTRATION - conformance/check-references

- Date: 2026-06-15 (new detector, WS-B: the language rulebook split into pairs/ + langs/)
- Detector: tools/conformance/check-references.sh
- Failure class targeted: a dangling citation. After the rulebook split, a skill,
  command, template, or lesson can point at a reference file path that has moved
  (e.g. the old `references/c.md`) or at a trap ID (`T1`...) that no pair table
  defines. A dangling citation is worse than no split: a reader follows a pointer to
  nothing, or a review/conformance script cites a rule that is gone.
- Exit-code contract: 0 GREEN (every cited reference path and trap ID resolves, or
  nothing to scan), 1 RED (at least one dangling citation), 2 UNRELIABLE (no tooling,
  no pair tables, or an unreadable explicit file).

The detector scans the methodology text - skills, commands, agents, the code-port
templates, the conformance/gate/scoping scripts (`*.sh`), tools/README, AGENTS.md,
README.md, and port/ lessons (`*.md|*.sh|*.py|*.ya?ml`). It checks (1) every reference
file-path citation resolves - a `references/.../<name>.md` path under a skill's
references/ tree, or a relative `./`/`../` `.md` link (a references/-internal sibling
link) resolved against the citing file's directory - and (2) every `T<number>` trap-ID
citation is a row in some pair table under `references/pairs/`. The check itself and its
seeded-bug record are excluded by name (they document/illustrate bogus citations).
Explicit file arguments scan just those files (used here), against the trap definitions
in the real repo.

## Seeded defect (representative of the class)

A reference file that cites a moved skill-rooted path, a broken sibling link, and an
undefined trap ID (placed under a `references/` directory so the relative-link rule
applies):

```
See ../pairs/nonexistent.md and references/c.md, plus T1 and T99.
```

`references/c.md` is exactly the pre-split path this workstream removed; `T99` is a
trap ID no pair table defines; `../pairs/nonexistent.md` is a broken sibling link.

## Red proof

- Command: `bash tools/conformance/check-references.sh <fixture>` with the fixture at
  `<tmp>/references/langs/x.md` containing the line above.
- Result: RED, exit 1, 3 dangling citations, each with the offending file:line -
  `references/c.md` (skill-rooted path), `../pairs/nonexistent.md` (relative sibling
  link), and trap-ID `T99`. `27 trap ID(s) defined; 3 dangling citation(s). RESULT:
  RED`. (T1 resolves and is not reported; only the undefined T99 is.)

## Causal proof (the move is what makes the old path dangle)

- `references/c.md` resolved before this workstream and does not after it: the file was
  split into `references/pairs/fortran-to-c.md` (pair rulebook + trap table T1-T27) and
  `references/langs/c.md` (C tooling) and removed. A citation of the old path therefore
  moves from GREEN (before) to RED (after) - which is precisely the dangling-citation
  class this detector exists to catch during such a move.

## Green proof (defect removed)

- A fixture citing only live targets (`references/pairs/fortran-to-c.md`,
  `references/langs/c.md`, `T1`, `T27`): GREEN, exit 0 - `0 dangling citation(s)`.
- The real tree (`bash tools/conformance/check-references.sh`, no arguments): GREEN,
  exit 0 - `49 file(s); 27 trap ID(s) defined; 0 dangling citation(s)`. Every
  reference-path and trap-ID citation across the methodology (including the relative
  `../pairs`/`../langs` sibling links and the trap-ID citations in `verify-anchors.sh`)
  resolves after the split was wired.

## Scope / non-defect signals confirmed

- Defined trap IDs are read from the pair tables themselves (the row's first cell), so
  growing the table to a new ID immediately makes that ID citable without editing this
  check.
- `<angle-bracket>` placeholders in "how to add a pair/lang" docs are not literal paths
  and are correctly not flagged (the path pattern requires a real `.md` suffix with no
  `<`/`>`).
- Conformance/gate/scoping scripts are scanned, so a trap-ID citation in a `.sh`
  (e.g. `verify-anchors.sh` citing T1) is covered, not just the prose docs.
- Relative `../`/`./` links are resolved only for files under a `references/` directory
  (the sibling-link convention), so an ellipsis in ordinary prose elsewhere
  (`docs/evidence/.../report.md`) is not mistaken for a parent-directory link.
- The check itself and its seeded-bug record are excluded by name: both legitimately
  contain illustrative/bogus citations (`references/c.md`, `T99`, the path patterns).

## Comparison-logic version

The comparison logic is: defined IDs = first-cell `T<number>` of every row in
`references/pairs/*.md`; cited paths = `references/[..].md` substrings; cited IDs =
`\bT[0-9]+\b` tokens. Re-run this demonstration after any change to that extraction or
to the scan set (standing seeded-bug rule): a moved/removed reference path and an
out-of-range trap ID must both still go RED, and a fully wired tree must stay GREEN.
