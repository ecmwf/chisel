---
description: Start a port sprint - load state files, restate directives, confirm scope
---

Begin a porting sprint. Do this BEFORE any other work, in this order:

0. **Are the FOUNDATIONAL decisions made yet? If not, STOP and ask - do not begin work.** Check the
   charter `port/plan/00-charter.md`: if it is ABSENT, or its section 1 TARGET still holds an
   un-instantiated template placeholder (e.g. `<language>`, `<TARGET>`), or its section 3 scope (the
   live subset / pinned configuration) is still a placeholder, the project is NOT yet scoped. (Once a
   decision is recorded it is NOT a placeholder, so this never re-asks something already answered.) When
   a decision is still unset, this is Phase 0 scoping, and its FIRST act is the human's two
   FOUNDATIONAL decisions - the **TARGET language** (section 1: language/standard, compilers+flags,
   execution model) and the **SCOPE** (section 3: pinned configuration, the live subset, excluded
   subsystems). OBSERVE the SOURCE first so you can LEAD with a recommendation + rationale (a quick
   confirm, not an open-ended question), then **ASK the human and WAIT for their answer** before
   recording them and proceeding. This is a GENUINE human decision, NOT the don't-pester case below:
   never infer the TARGET from the repo/instance/product name or the tree, and never pick a default and
   march on. (Everything else in Phase 0 - pinning the SOURCE commit, the reference run, populating
   TRACE - is routine and proceeds without pestering. The full Phase 0 arc is in the bootstrap handoff.)

1. Read `port/handoffs/<workstream>.md` (default: `main.md`, or the workstream given as
   argument: $ARGUMENTS). Identify the single NEXT TASK. Check the handoff's base
   commit against current HEAD: if the repo has moved, reconcile against TRACE and
   the plan before trusting the handoff's picture of the world. **Reconcile the NEXT
   TASK itself against TRACE before acting on it**, not just the handoff's wording: TRACE
   is the source of truth for module status, the handoff is only a hint, and a handoff
   written before this rule puts review/gate tasks in NEXT TASK prose rather than in a
   dedicated field. If the NEXT TASK (or any "Awaiting independent review" line) names a
   module whose TRACE entry is already `gated`. **`gated` is the ONLY signal that the
   review is satisfied** - a non-null `review` field is NOT: a review that recorded
   VIOLATIONS leaves the module `in-progress` and, per the gating rule, still owes a clean
   independent re-review before it can gate. So a review or gate task is stale only when
   `status: gated`; a module with a `gate` but not `gated` genuinely still needs a clean
   review - whether `review` is null (never reviewed) or set to a violations verdict
   (reviewed, not clean) - and that is NOT the stale-handoff case, so do not skip it. When
   the task IS stale (the named module is already `gated`), move to the genuinely next
   unfinished unit (the next `unmapped`/`in-progress` module, or one with a `gate` but not
   `gated` that still owes its clean review), and have sprint-end rewrite the handoff from
   TRACE.
2. Show overall progress: run `python3 tools/scoping/port-progress.py` and display its
   output to the human. It is a read-only view derived from `port/TRACE.yaml` (never a
   separate source of truth). Only `gated` is real progress (translated AND gate-passed
   AND independently reviewed); the `in-progress` band is work that exists but is not yet
   trustworthy, and the bar is volume converted, not effort or time remaining (the costly
   wide-footprint and seam routines cluster late). If it reports no live files yet, Phase
   0 scoping has not populated the live subset.
3. Read the STANDING RULES block at the top of `port/LESSONS.md`.
4. Read the section of `port/plan/00-charter.md` (and the phase/module plan file)
   relevant to the next task.
5. Read `port/KNOWN-DIVERGENCES.md`, and `port/COORDINATION.md` whenever more than
   one workstream exists (locks and interface contracts bind your scope).
6. Restate, verbatim and briefly: the prime directives from AGENTS.md (all of them,
   including never self-certify) plus the current standing rules.
7. Confirm the task scope back to the user in 2-3 sentences: what will be done, which
   gate defines "done", and what will NOT be touched (do-not-touch list, other
   workstreams' locks in `port/COORDINATION.md`).

Then BEGIN (unless step 0 stopped you for an un-chartered project - the TARGET language and scope are
a genuine human decision you must get first). The scope restatement in step 7 is for the record, NOT a
checkpoint that pesters the user for an OK: when the task is unambiguous, just start - do not stop to
ask "shall I proceed?". Pause only when the scope is genuinely ambiguous or rests on a human decision
the state files cannot settle (the new-project scope/language decision above, a real do-not-touch
conflict, an unset acceptance standard). Stay within the single task named in the handoff; if it balloons, that is an
end-now condition (AGENTS.md): split it - update the plan, rewrite the handoff, and run
`/port-sprint-end` into a fresh sprint - because the re-scope itself is the work, not a
reflexive stop.
