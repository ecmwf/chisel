# HANDOFF - <instance name> / main

> Rewritten at the END of every sprint. The next sprint starts by reading this file,
> then LESSONS.md (STANDING RULES at minimum), then the relevant charter section, then
> KNOWN-DIVERGENCES.md - before doing anything else.

## Written by: repo bootstrap (no work sprints yet)

### Current state
- Base commit: see latest commit touching this file (bootstrap; no work sprints yet)
- Phase: 0 (scoping) - not started
- Last git tag passed: none
- Build status: no SOURCE program selected yet; `source/` and `target/` are empty
- Ladder status: no gates exist yet

### Canonical reference artifacts in force
- Reference run: not yet defined (charter §2 is TBD)

### NEXT TASK (one coherent unit - a sprint's worth, e.g. a module and its checks)
Instantiate the warm-up, with the human. This base copy stays abstract (AGENTS:
the base repo names no program); the human brings the candidate decision into
the instance. This sprint:
1. Create the warm-up instance: fork/clone this base repo (the instance is where
   everything below happens; this base copy's only change is via /port-contribute-to-base).
2. In the instance, ASK the human and record in charter §1: the chosen program,
   the SOURCE and TARGET languages with standards, and the compilers + flags for
   both sides (propose defaults with rationale; the human approves). Verify the
   program's license before anything is pinned (charter risk table). Language
   choices are never inherited silently from the base.
3. Record and have the human accept or mitigate any selection-criteria gaps
   (charter §10 - e.g., a program configured at compile time rather than by a
   runtime parameter file weakens the configuration-pinning exercise; note the
   accepted weakening and where the pilot proper covers it).
4. Decide the exact configuration to pin (the single build/run variant ported).
Done = instance exists; decisions recorded in ITS charter §§1+10; ITS handoff
rewritten with the next task. This base repo's handoff then simply points at the
instance.

### Phase 0 remaining queue (for the instance, subsequent sprints, in order)
- Import the program into `source/`: clone upstream under `source/`, then RUN
  `tools/import-source.sh source/<program>` - it captures the provenance, refuses
  on a dirty tree or submodules, strips the nested `.git` (the gitlink trap: a
  clone committed as-is becomes a broken link, not files), and runs the
  completeness check (so the SOURCE's own `.gitignore` cannot silently drop
  force-tracked files). Do not hand-roll these steps; the script is the safety
  net. Then transcribe its printed provenance (upstream hash + URL) into charter
  §2, verify the license, and `git add` per its hint (one writer per worktree;
  the script never commits). The local import commit goes in TRACE
  meta.source_commit (what the anchor verifier reads via git show). No upstream
  fork needed - imported bytes are self-sufficient.
- Pin the configuration into charter §3 with provenance.
- Define and archive the canonical reference run + fast rig in
  `reference/runs.md`; reference their IDs from charter §2.
- Populate `port/TRACE.yaml` (live subset; meta.source_commit = charter §2).
- /port-digest, human SIGNOFF.md, then the `warmup-phase0-signed` tag.

### In-flight anomalies / open questions
- none

### Do-not-touch
- nothing locked

### Notes for the human
- Repo structure and workflow are freshly bootstrapped; the pilot's purpose is to
  validate this machinery end-to-end before the large port.
