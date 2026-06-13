---
description: Start a port session - load state files, restate directives, confirm scope
---

Begin a porting work session. Do this BEFORE any other work, in this order:

1. Read `port/handoffs/<workstream>.md` (default: `main.md`, or the workstream given as
   argument: $ARGUMENTS). Identify the single NEXT TASK. Check the handoff's base
   commit against current HEAD: if the repo has moved, reconcile against TRACE and
   the plan before trusting the handoff's picture of the world.
2. Read the STANDING RULES block at the top of `port/LESSONS.md`.
3. Read the section of `port/plan/00-charter.md` (and the phase/module plan file)
   relevant to the next task.
4. Read `port/KNOWN-DIVERGENCES.md`, and `port/COORDINATION.md` whenever more than
   one workstream exists (locks and interface contracts bind your scope).
5. Restate, verbatim and briefly: the prime directives from AGENTS.md (all of them,
   including never self-certify) plus the current standing rules.
6. Confirm the task scope back to the user in 2–3 sentences: what will be done, which
   gate defines "done", and what will NOT be touched (do-not-touch list, other
   workstreams' locks in `port/COORDINATION.md`).

Then wait for confirmation or begin if the task is unambiguous. Stay within the single
task named in the handoff; if it balloons, split it - update the plan, rewrite the
handoff, and recommend a fresh session.
