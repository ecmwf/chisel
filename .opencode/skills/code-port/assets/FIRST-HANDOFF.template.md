# HANDOFF - ${name} / main

> Rewritten at the end of every sprint. The next sprint reads this file first, then LESSONS.md
> (the STANDING RULES at least), the relevant charter section and KNOWN-DIVERGENCES.md.

## Written by: chisel-init bootstrap (no work sprints yet)

### Current state
- Set up by chisel-init; Phase 0 (scoping) not started.
- No port milestone tag yet. A tag such as `0.1.0` inherited from Chisel is Chisel's own release
  (VERSION), not a port milestone.
- The setup below is not committed yet. That is the expected state; committing it is step 1.
${imported}
- Charter `port/plan/00-charter.md` sections 1, 2 and 3: still placeholders.
- `port/TRACE.yaml`: empty; `meta.upstream_commit` and `meta.source_commit` still null.

### Canonical reference artifacts in force
${pin}- Reference run: not defined yet (charter section 2).

### NEXT TASK (Phase 0 scoping, one sprint)
Drive Phase 0 to its sign-off in this sprint; it writes no TARGET code. Do the routine work and
commit it yourself. Two decisions are the human's: the TARGET and the scope. Ask for each once, with
a recommendation, and record it only once the human answers; the steps that do not depend on an
answer go on meanwhile.
1. Commit the setup yourself, in two commits: first `source/` and `port/provenance/` alone (the
   import commit, which TRACE `meta.source_commit` names), then `port/product.yaml` and this
   handoff. Push them and report what you committed (AGENTS.md, "Git"). `opencode.json` stays
   local.
2. Ask for the TARGET: its language and standard, compilers and flags, and the execution model
   (charter section 1). Observe the SOURCE language and standard first (cite file:line) and lead
   with a recommended TARGET and its rationale. Never infer the TARGET from a repository, instance
   or product name, or from the tree: a product repo named `<x>-c` is not a decision to port to C.
3. Pin the SOURCE: charter section 2 and TRACE `meta.upstream_commit` take the `commit` in
   `port/provenance/<name>.yaml`; TRACE `meta.source_commit` takes the local commit that added
   `source/` (`git log --reverse --format=%H -- source/ | head -1`), which the anchor verifier
   reads. Never ask the human for a commit.
4. Gather the liveness evidence (coverage, build log, link map; `tools/scoping/`), then propose the
   scope - the pinned configuration, the live subset and the excluded subsystems (charter
   section 3) - and ask the human to confirm it. Record risks in section 10, such as a program
   configured at compile time rather than by a parameter file.
5. With both decisions recorded: finish the pinned configuration (section 3) with its provenance,
   define the canonical reference run and the fast rig in `reference/runs.md`, and populate
   `port/TRACE.yaml`.
6. Run `/port-digest`: the evidence pack and a prefilled SIGNOFF.md for the human.

Done = the decisions recorded in the charter, the provenance pinned, the state committed, this
handoff rewritten and the digest ready; the human's SIGNOFF.md then lets `finalize.sh` create the
`phase0-signed` tag.

### In-flight anomalies / open questions
- none

### Do-not-touch
- nothing locked (single stream)

### Notes for the human
- chisel-init captured the SOURCE commit under `port/provenance/`, so Phase 0 never asks you for a
  URL or a commit.
- The TARGET and the scope are your decisions: the agent recommends and asks you, once each, and
  never assumes the TARGET from how the port or the product is named. Everything else in Phase 0
  goes ahead without asking you.
