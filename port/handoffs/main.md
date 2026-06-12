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
Phase 0 kickoff, with the human. Candidate programs are DECIDED: miniWeather
(github.com/mrnorman/miniWeather, ~500 LoC, BSD-2, warm-up) and SPEEDY.f90
(github.com/samhatfield/speedy.f90, ~10-15 kLoC, namelist + NetCDF, pilot
proper). Open decisions for the human at this session:
- structure: which program is THE chartered pilot in this repo instance; per the
  reuse model the other runs in its own clone (recommended: miniWeather here to
  validate the machinery, SPEEDY in a fresh clone, which also rehearses /upstream
  and the fresh-clone flow)
- known criteria gap to accept or mitigate: miniWeather has NO runtime parameter
  file (compile-time -D options only), so the configuration-pinning exercise is
  weaker there; SPEEDY's namelist covers it later
- verify SPEEDY.f90's license before pinning anything (unverified)
Then: (1) fork/pin the chosen program into `source/`; (2) pin the configuration
into charter §3 with provenance; (3) define and archive the canonical reference
run and fast rig in `reference/runs.md`, reference their IDs from charter §2;
(4) populate `port/TRACE.yaml` (live subset; set meta.source_commit = charter
§2); (5) fill charter §§1-3.
Done = charter §§1-3 filled, reference archived with checksums, TRACE populated,
and the human's Phase 0 SIGNOFF.md recorded in docs/evidence/ - only then the
`pilot-phase0-signed` tag.

### In-flight anomalies / open questions
- none

### Do-not-touch
- nothing locked

### Notes for the human
- Repo structure and workflow are freshly bootstrapped; the pilot's purpose is to
  validate this machinery end-to-end before the large port.
