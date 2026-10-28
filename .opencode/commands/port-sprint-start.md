---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Start a port sprint - load the state, restate the directives, pick the work
---

Start a porting sprint. Do this before any other work, in this order.

0. **The human's foundational decisions.** If `port/plan/00-charter.md` is missing, or section 1
   (the TARGET language and standard, compilers, flags and math library, execution model) or
   section 3 (the pinned configuration, live subset and exclusions) still holds a placeholder,
   Phase 0 starts with those decisions. Observe the SOURCE, recommend a choice with its reason, then
   ask the human and wait for the answer before recording it (AGENTS.md, "Sprint protocol"). A
   recorded decision is never asked again. The rest of Phase 0 is routine; the first handoff lists
   it.
1. **The task.** Read `port/handoffs/<workstream>.md` (default `main`; argument: $ARGUMENTS) and take
   its NEXT TASK. TRACE is the truth and the handoff only a hint: if HEAD has moved since the
   handoff's base commit, reconcile with TRACE and the plan first. If the task names a unit TRACE
   already shows `proven`, it is stale: take the next unfinished unit, and let the sprint end rewrite
   the handoff. Only `status: proven` means a review is done; a unit with a `review` but not `proven`
   still owes a clean one.
1b. **The ready-set.** Derive the units ready now - unblocked, unclaimed, independent of each other:
    `python3 tools/coordination/phase1_drive.py` in Phase 1, `python3 tools/coordination/dashboard.py`
    in Phase 2, and in Phase 2 show the build schedule (`python3 tools/coordination/schedule.py`:
    waves, cycles, the critical path). Dispatch them, critical path first, as AGENTS.md "Parallel dispatch" requires - all at once unless one of
    its serial cases applies, with no `max_in_flight` in a hand-driven sprint - and the way
    `/port-autodrive` step 6 describes: provision each worktree, start every Kha-Worker in the
    background in one message, mark and resume their sessions, and handle each result as it arrives
    (a finished unit goes to `/port-review` at once), never waiting for the slowest.
    Ptah-Orchestrator authors none of them. A dispatched Kha-Worker skips this step: its unit is the
    one it was given.
2. **Progress.** Run `python3 tools/scoping/port-progress.py` and show its output. It is read from
   TRACE. Only `proven` counts (translated, proof passed, independently reviewed); `in-progress` is
   work that exists but is not yet trusted. If it reports no live files, Phase 0 has not filled the
   live subset yet.
3. Read the STANDING RULES at the top of `port/LESSONS.md`.
4. Read the charter section and the phase or module plan for the task.
5. Read `port/KNOWN-DIVERGENCES.md`, and `port/COORDINATION.md` when there is more than one
   workstream: its locks and interface contracts bind you.
6. Restate the prime directives (AGENTS.md) and the standing rules, briefly.
7. State the scope in two or three sentences: what will be done, which proof defines done, and what
   will not be touched (the do-not-touch list, other workstreams' locks).

Then begin. Step 7 is for the record, not a request for approval: do not ask "shall I proceed?". Ask
only for a decision the state files cannot settle (step 0, a real do-not-touch conflict, an unset
acceptance standard), and go on with whatever does not depend on it. If a unit balloons, split it:
update the plan, rewrite the handoff, and end with `/port-sprint-end`.
