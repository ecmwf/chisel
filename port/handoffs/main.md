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
Instantiate the warm-up, with the human. This base copy stays abstract (AGENTS:
the base repo names no program); the human brings the candidate decision into
the instance. This session:
1. Create the warm-up instance: fork/clone this base repo (the instance is where
   everything below happens; this base copy's only change is via /upstream).
2. In the instance, record the human's chosen warm-up program in charter §1, and
   verify its license before anything is pinned (charter risk table).
3. Record and have the human accept or mitigate any selection-criteria gaps
   (charter §10 - e.g., a program configured at compile time rather than by a
   runtime parameter file weakens the configuration-pinning exercise; note the
   accepted weakening and where the pilot proper covers it).
4. Decide the exact configuration to pin (the single build/run variant ported).
Done = instance exists; decisions recorded in ITS charter §§1+10; ITS handoff
rewritten with the next task. This base repo's handoff then simply points at the
instance.

### Phase 0 remaining queue (for the instance, subsequent sessions, in order)
- Vendor the program into `source/`: clone upstream, copy the tree at the chosen
  commit, commit it in the instance. Record BOTH commits: the upstream hash +
  URL in charter §2 (provenance), and the local vendor commit in TRACE
  meta.source_commit (what the anchor verifier reads via git show). No upstream
  fork needed - vendored bytes are self-sufficient; a fork would only matter on
  the submodule route, which we are not taking.
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
