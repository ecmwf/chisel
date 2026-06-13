# HANDOFF - <project name> / <workstream>

> Rewritten at the END of every sprint. The next sprint starts by reading this file,
> then LESSONS.md (STANDING RULES at minimum), then the relevant charter/plan section,
> then KNOWN-DIVERGENCES.md - before doing anything else. Keep it short: a fresh
> sprint must be able to rebuild working context from this file in a few reads.

## Written by session <id> on <date>

### Current state
- Base commit (HEAD when this was written): <hash> - if HEAD has moved, reconcile
  against TRACE and the plan before trusting this file
- Phase: <n>  Last git tag passed: <tag>
- Build status: <SOURCE ref build OK? port build OK? which backends?>
- Ladder status: highest tier currently green: <R-n>, on <run definition>

### Canonical reference artifacts in force
- Reference run: <path/ID>  (unchanged since charter §2? yes/no - if no, why)
- Recorded fp floor for accelerator gate: <values, where stored>

### NEXT TASK (one coherent unit - a sprint's worth, e.g. a module and its checks)
<exact task. Inputs it needs. The gate that defines "done".>

### In-flight anomalies / open questions
- <anything observed but not resolved; suspicions; a divergence not yet bracketed>

### Do-not-touch
- <files locked by another workstream (see COORDINATION.md), runs in progress, etc.>

### Notes for the human
- <decisions awaiting sign-off; evidence ready for review in docs/evidence/>
