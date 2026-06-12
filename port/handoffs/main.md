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
Phase 0 decision session, with the human. The plan on the table (charter header):
miniWeather is the chartered WARM-UP in this repo; SPEEDY.f90 is the pilot proper
in a fresh clone afterwards. This session resolves and records:
1. Confirm or amend that structure (charter header note says "pending Phase 0
   sign-off" - this is where it stops being pending).
2. Verify BOTH licenses before anything is pinned (miniWeather expected BSD-2,
   SPEEDY.f90 unverified - check the repos, record findings in the charter risk
   table).
3. Accept or mitigate the known criteria gap: miniWeather has NO runtime
   parameter file (compile-time -D options only), so the configuration-pinning
   exercise is weaker here; SPEEDY's namelist covers it at the pilot proper.
4. Decide the miniWeather configuration to pin (which DATA_SPEC, grid, SIM_TIME).
Done = decisions recorded in charter §§1+10 and this handoff rewritten with the
next task.

### Phase 0 remaining queue (subsequent sessions, in order)
- Vendor miniWeather into `source/`: clone upstream, copy the tree at the chosen
  commit, commit it here. Record BOTH commits: the upstream hash + URL in charter
  §2 (provenance), and our local vendor commit in TRACE meta.source_commit (what
  the anchor verifier reads via git show). No upstream fork needed - vendored
  bytes are self-sufficient; a fork would only matter on the submodule route,
  which we are not taking.
- Pin the configuration into charter §3 with provenance.
- Define and archive the canonical reference run + fast rig in
  `reference/runs.md`; reference their IDs from charter §2.
- Populate `port/TRACE.yaml` (live subset; meta.source_commit = charter §2).
- /evidence-digest, human SIGNOFF.md, then the `warmup-phase0-signed` tag.

### In-flight anomalies / open questions
- none

### Do-not-touch
- nothing locked

### Notes for the human
- Repo structure and workflow are freshly bootstrapped; the pilot's purpose is to
  validate this machinery end-to-end before the large port.
