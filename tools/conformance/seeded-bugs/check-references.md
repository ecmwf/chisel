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

The detector scans the methodology text (skills, commands, agents, the code-port
templates, tools/README, AGENTS.md, README.md, and port/ lessons; seeded-bug records
excluded) and checks (1) every `references/.../<name>.md` path exists under a skill's
references/ tree, and (2) every `T<number>` trap-ID citation is a row in some pair
table under `references/pairs/`. Explicit file arguments scan just those files (used
here), against the trap definitions in the real repo.

## Seeded defect (representative of the class)

A file that cites a moved reference path and an undefined trap ID:

```
See the trap table in references/c.md for rendering rules; in particular T1 and T99.
Also consult references/pairs/nonexistent.md.
```

`references/c.md` is exactly the pre-split path this workstream removed; `T99` is a
trap ID no pair table defines; `references/pairs/nonexistent.md` is a missing pair file.

## Red proof

- The fixture above: RED, exit 1, 3 dangling citations, each with the offending
  file:line - `references/c.md`, `references/pairs/nonexistent.md`, and trap-ID `T99`.
  `27 trap ID(s) defined; 3 dangling citation(s). RESULT: RED`. (T1 resolves and is not
  reported; only the undefined T99 is.)

## Causal proof (the move is what makes the old path dangle)

- `references/c.md` resolved before this workstream and does not after it: the file was
  split into `references/pairs/fortran-to-c.md` (pair rulebook + trap table T1-T27) and
  `references/langs/c.md` (C tooling) and removed. A citation of the old path therefore
  moves from GREEN (before) to RED (after) - which is precisely the dangling-citation
  class this detector exists to catch during such a move.

## Green proof (defect removed)

- A fixture citing only live targets (`references/pairs/fortran-to-c.md`,
  `references/langs/c.md`, `T1`, `T27`): GREEN, exit 0 - `0 dangling citation(s)`.
- The real tree (default scan, no arguments): GREEN, exit 0 - every reference-path and
  trap-ID citation across the methodology resolves after the split was wired.

## Scope / non-defect signals confirmed

- Defined trap IDs are read from the pair tables themselves (the row's first cell), so
  growing the table to a new ID immediately makes that ID citable without editing this
  check.
- `<angle-bracket>` placeholders in "how to add a pair/lang" docs are not literal paths
  and are correctly not flagged (the path pattern requires a real `.md` suffix with no
  `<`/`>`).
- Seeded-bug records are excluded from the default scan because they intentionally
  discuss bogus citations (this file cites `references/c.md` and `T99` as examples).

## Comparison-logic version

The comparison logic is: defined IDs = first-cell `T<number>` of every row in
`references/pairs/*.md`; cited paths = `references/[..].md` substrings; cited IDs =
`\bT[0-9]+\b` tokens. Re-run this demonstration after any change to that extraction or
to the scan set (standing seeded-bug rule): a moved/removed reference path and an
out-of-range trap ID must both still go RED, and a fully wired tree must stay GREEN.
