# HANDOFF - Fortran→C pilot / main

> Rewritten at the END of every session. The next session starts by reading this file,
> then LESSONS.md (STANDING RULES at minimum), then the relevant charter section, then
> KNOWN-DIVERGENCES.md - before doing anything else.

## Written by: repo bootstrap (no work sessions yet)

### Current state
- Base commit: see latest commit touching this file (bootstrap; no work sessions yet)
- Phase: 0 (scoping) - not started
- Last git tag passed: none
- Build status: no SOURCE program selected yet; `source/` and `target/` are empty
- Ladder status: no gates exist yet

### Canonical reference artifacts in force
- Reference run: not yet defined (charter §2 is TBD)

### NEXT TASK (single, narrow - one session's worth)
Phase 0 kickoff, with the human: (1) choose the pilot Fortran program (selection
criteria in charter §10 - it must have a parameter file, a multi-step iteration, a
nontrivial constant set, and a mix of pure and wide-footprint routines so both the
workflow and the per-procedure verification policy are actually exercised); (2) place it in
`source/` at a pinned commit; (3) pin the configuration into charter §3 with
provenance; (4) define and archive the canonical reference run (charter §2,
`reference/runs.md`); (5) populate `port/TRACE.yaml` with the live subset.
Done = charter §§1–3 filled, reference archived with checksums, TRACE populated,
and the human's Phase 0 SIGNOFF.md recorded in docs/evidence/ - only then the
`pilot-phase0-signed` tag.

### In-flight anomalies / open questions
- none

### Do-not-touch
- nothing locked

### Notes for the human
- Repo structure and workflow are freshly bootstrapped; the pilot's purpose is to
  validate this machinery end-to-end before the large port.
