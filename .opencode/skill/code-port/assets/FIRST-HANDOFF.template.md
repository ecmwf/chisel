# HANDOFF - ${name} / main

> Rewritten at the END of every sprint. The next sprint starts by reading this file,
> then LESSONS.md (STANDING RULES at minimum), then the relevant charter section, then
> KNOWN-DIVERGENCES.md - before doing anything else.

## Written by: chisel-init bootstrap (no work sprints yet)

### Current state
- Freshly bootstrapped by chisel-init. Phase: 0 (scoping) - NOT started.
- No PORT milestone tag yet. (Any inherited tag like `0.1.0` is the METHODOLOGY's own release
  version from the base clone - semver per VERSION, NOT a port milestone; do not treat it as one.)
- The bootstrap below is UNCOMMITTED - the expected fresh-instance state, NOT a divergence;
  committing it is your first Phase 0 step (routine commits AND pushing them to the workbench origin are yours; only product-code landing / milestone tag / upstream / claim refs stay guarded).
${imported}
- Charter `port/plan/00-charter.md` sections 1/2/3: still the un-instantiated template (TBD).
- `port/TRACE.yaml`: empty; `meta.upstream_commit` and `meta.source_commit` still null.

### Canonical reference artifacts in force
${pin}- Reference run: not yet defined (charter section 2 is TBD).

### NEXT TASK (Phase 0 scoping - one coherent arc)
DRIVE Phase 0 to completion in this sprint - it is one bounded scoping arc (no TARGET code
yet). Do the ROUTINE work without stalling and COMMIT it yourself. But Phase 0 opens with TWO
FOUNDATIONAL decisions that are the human's to make - the **TARGET language** and the **SCOPE** -
and you must ASK and get their answer BEFORE proceeding (this is a genuine human decision, not the
don't-pester case). Steps:
1. COMMIT the bootstrap yourself, in two conventional commits: first `source/` and
   `port/provenance/` alone (the import commit, which TRACE `meta.source_commit` names), then
   `port/product.yaml` and this handoff. Report what you committed. Routine commits (and
   pushing this project-layer state to the workbench origin) are YOURS - they carry the human's
   authorship, no AI attribution; only product-code landing / the milestone tag+sign-off / upstream
   / claim refs stay guarded, so do NOT ask whether to commit or push routine state. (`opencode.json` is gitignored.)
2. ASK THE HUMAN the two foundational decisions, then WAIT for their answer - do not pick for them
   and march on. OBSERVE the SOURCE first so you can lead with a recommendation (a quick confirm,
   not an open-ended question), but the decision is theirs:
   a. **TARGET** language/standard, compilers + flags, and execution model (charter section 1).
      OBSERVE the SOURCE language/standard from the imported tree (cite file:line); PROPOSE a
      recommended TARGET + rationale. NEVER silently infer the TARGET from the repo/instance/product
      name or the tree (a product repo named `<x>-c` is NOT a decision to port to C).
   b. **SCOPE** (charter section 3): the pinned configuration, the LIVE subset, and the EXCLUDED
      subsystems. PROPOSE a scope from coverage/build-log/link-map evidence; the human confirms
      what is in and out of the port.
   Record their decisions in sections 1 and 3 only once you have them.
3. Set charter section 2 and TRACE `meta.upstream_commit` to the `commit` in
   `port/provenance/<name>.yaml` (the upstream commit), and TRACE `meta.source_commit` to the LOCAL
   commit that added `source/` (`git log --reverse --format=%H -- source/ | head -1`): the anchor
   verifier reads the SOURCE from that one.
4. Record selection-criteria gaps (section 10); finalize the pinned configuration (section 3) with provenance.
5. Define the canonical reference run + fast rig in `reference/runs.md`; populate `port/TRACE.yaml`.
6. /port-digest - compile the evidence pack + a prefilled SIGNOFF.md for the human.
Done = decisions recorded in the charter, provenance pinned, state committed, this handoff
rewritten, and the /port-digest pack prepared -> human SIGNOFF.md -> the `phase0-signed` tag.

### In-flight anomalies / open questions
- none

### Do-not-touch
- nothing locked (single stream)

### Notes for the human
- This instance was freshly bootstrapped by chisel-init; the SOURCE commit is already captured
  under port/provenance/, so Phase 0 never needs to ask for a URL or commit.
- The TARGET language and the SCOPE are YOUR decisions: the agent proposes a recommendation with
  rationale and ASKS you up front, never silently assuming the target from how this instance or the
  product was named. Everything else in Phase 0 is routine and proceeds without pestering you.
