<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Auto-mode: driving the port without a keystroke

How Ptah-Orchestrator drives a port on its own - claiming, dispatching, reviewing, proving,
integrating, advancing phases - while the fidelity safeguards stay exactly as strong as in the
hand-driven flow. Read `references/team-coordination.md` (the substrate) and
`references/parallel-phase-2.md` (the roles and the wave loop) first; this file adds only the
autonomy layer. The procedure is `/port-autodrive`.

## What auto-mode changes, and what it does not

The port's trust does not come from a human pressing the buttons. It comes from five properties that
auto-mode leaves untouched:

1. **Every check runs and commits its evidence** (the R0-R5 proofs, the seeded detectors, the
   conformance suite). Auto-mode cannot mark a piece done without them.
2. **Independence is structural.** The worker and the reviewer run in separate sessions (required);
   the reviewer should run on a different model, which `chisel-init` sets up. The machine checks:
   `reviewer_id != author_id` and `reviewer_session` not in `author_sessions`
   (`check-status-fragments`), a clean review report for every proven unit (`check-trace-evidence`),
   and lands that take only the proven commit (`proof.commit`), the one that was reviewed.
   Ptah-Orchestrator never reviews work it dispatched.
3. **Checks fail closed.** A red trust check (`check-claims`, `check-trace-evidence`,
   `check-status-fragments`, ...) always halts the run, and auto-mode never "fixes" a trust failure
   to keep going. After each land that pushes, confirm CI passed before the next land (B19).
4. **Everything is in git.** Each action commits its evidence: the proof evidence and its commit, the
   review report, the status fragment, the regenerated TRACE. There is no separate ledger: the history
   is the record, and because the planner is pure, anyone can re-run it at a committed state and get
   the plan the run acted on.
5. **Conservatism holds.** A guarded unit (an owned foundation or a shared surface) is never
   auto-claimed. The dependency map records only resolved edges and structural surfaces; a hidden
   coupling is caught by the R1 proof and the independent review.

What auto-mode removes is the human as an extra check between steps. So it is opt-in per port, and
the human's own decisions stay theirs: TARGET and scope, the section 7 tolerance bands, the
acceptance policy, sign-off, the contribution PR. Auto-mode asks for each once, up front where
possible, and never takes one itself.

## Autonomy levels

`port/autodrive.yaml` holds `level`, `scope` and `budgets` (template `assets/autodrive.template.yaml`;
charter section 12 explains them). `/port-autodrive enable L1` writes it.

- **L0 - off (the default).** Ptah-Orchestrator suggests the next action; a human runs each one.
- **L1 - plan.** Prints the full plan with its rationale and exact commands, and executes nothing.
- **L2 - the current phase.** Drives every sprint of the current phase, seals its milestone with
  `finalize.sh --auto`, and stops at the phase boundary.
- **L3 - every phase.** The same, across phase boundaries, until the port is done.

`scope` lists the actions auto-mode may take (`claim`, `work`, `review`, `rework`, `mark-proven`,
`integrate`). An action not listed is reported as a recommendation and waits for the human, while
the rest of the run continues. `budgets.max_waves`, `max_wall_clock` and `max_cost` end the run (L2
and L3 need `max_waves > 0` and a `max_wall_clock`); `budgets.max_in_flight` caps how many workers
run at once (unset: the whole ready-set); `budgets.max_rework` parks a piece that fails review more
often than that - autodrive's round cap; charter section 6a sets the cap for review by hand. Start at L1, and raise
the level once its plans look right on this codebase.

**Where a person must merge.** Some organisations forbid an AI agent to merge into a main branch on
its own; ECMWF's guideline on AI-assisted code does. There, leave `integrate` out of `scope`: the run
still claims, works, reviews and proves, and each land waits as a recommendation until the human
approves it with `/port-land`.

**Who records `proven`.** `mark-proven` is `/port-review`'s disposition: it records the human's
choice, or applies auto-prove when the charter allows it (`auto-prove: clean-only`). Without
auto-prove, the clean pieces wait for one batched answer from the human, and the run keeps driving
everything else.

**Sealing a milestone.** At L2 and L3, `finalize.sh --auto` refuses unless the level is L2 or L3 and
the full conformance suite is green at HEAD. The suite checks the recorded evidence (every proven
unit has an R1+ proof and a clean review report, completeness, and the rest); it does not re-run the
proofs, which ran before each piece was proven. The acceptance is the section 7 standard the human
set once, plus each piece's independent review; there is no countersign per milestone. Hand-driven,
`finalize.sh` takes a human accept `SIGNOFF.md` instead.

## The loop

Auto-mode is the wave loop of `parallel-phase-2.md`, turned by a planner instead of a human:

```text
plan = autodrive.py             # read-only: the deterministic next actions, derived from the artifacts
start the plan's claim / work / review / rework in the background   # the ready-set, max_in_flight at most
on each agent's result, as it arrives:
  thread_ledger.py done <id>; gather the piece through the one writer of main
  a worker done          -> start its review in the background
  a review with findings -> resume the same worker in the background
  a clean review         -> apply the disposition; land it in the foreground, one land at a time
  after a land: plan again and start what it freed
  plan.done              -> prepare the sign-off digest, seal with finalize.sh --auto, stop (L2) or go on (L3)
  nothing can start      -> end the turn (WAITING); the next result wakes the loop
until a stop condition
```

The planner (`tools/coordination/autodrive.py`) is read-only and deterministic: from the TRACE, the
dependency map, the claims and the phase, it returns the same ordered plan every time. It only
recommends. Ptah-Orchestrator executes the plan and writes the shared state (claims, gathered
fragments, workbench commits); workers commit only on their own `work/<id>` branches, and lands go
through Seshat-Integrator and the guarded scripts.

| Unit state (derived from the artifacts) | Action | Who executes |
|---|---|---|
| unmapped, unclaimed, unguarded, all deps integrated | `claim` | Ptah-Orchestrator provisions the worktree (writing the claim) and dispatches a Kha-Worker |
| claimed, no proof evidence yet | `work` | the Kha-Worker ports, proves and records the fragment |
| proof evidence, no clean review | `review` | port-review, in its own session |
| proof evidence, a violations review | `rework` | back to the Kha-Worker; never auto-proven |
| proof evidence, a clean review | `mark-proven` | `/port-review`'s disposition (above) |
| declaration-only, R0 and a clean review | `park` | nobody: validated through a consuming unit's proof, never proven at R0 |
| proven, all deps integrated | `integrate` | Seshat-Integrator lands it and records `product.main_commit` and `integration.state` |
| waiting on deps | `blocked` | nobody yet |
| owned foundation, unclaimed | `assign` | its owner; never auto-claimed |
| guarded (shared surface) | `guarded` | nobody: reported for human scoping |
| stale, invalid or unsafe claim | `triage` | nobody: reported for a human, never auto-freed |
| claim whose unit is in neither TRACE nor map | `release` | `release_claim.sh` (leftover cleanup) |

## Dispatching

The isolated actions (`claim`, `work`, `review`, `rework`) each run in their own provisioned
`.worktrees/<id>` (plus a product worktree in the two-repo layout) and write only their own fragment
and `docs/evidence/<id>/`, so they fan out: the whole ready-set as background subagents in one
message, provisioned in the message before, each marked running (`thread_ledger.py start`), exactly as `parallel-phase-2.md` describes ("Parallel by default", "Keep the pipeline
full"). A claim is made by provisioning (`provision_worker.sh add <id>` writes the local claim);
confirm `check-claims` before dispatch. Each worker runs `assert_isolated.sh` first and refuses if
it was not provisioned. The state-changing actions (`mark-proven`, `integrate`) go one at a time
through Seshat-Integrator, re-planning between them, since a land moves the base. Ptah-Orchestrator
gathers through one writer, running each piece's branch-diff-vs-claim and owned-surface check
(`check-claims --claim <id> --branch <ref> ...`) before accepting it, and commits each piece's
fragment and reports as its result arrives. The conformance suite runs where work lands: each land script runs it and rolls
back on red.

**Thread continuity.** On each dispatch, Ptah-Orchestrator records the subagent's `ses_` session id
(`thread_ledger.py record <id> --role worker|reviewer --session-id <ses_...>`). A rework resumes the
worker's thread and a re-review the reviewer's (`thread_ledger.py resume <id> --role <role>` gives the
`subagent` tool's `sessionID`); any non-zero exit means dispatch fresh with a brief, never a halt.
The worker's and the reviewer's threads are never crossed, and the handle is always the `ses_` id,
never a display name (`check-threads` enforces both).

## Phase 1: the tool-build driver

The same loop drives Phase 1, which builds the comparison tooling before any translation. The
planner is `tools/coordination/phase1_drive.py`; it reads `port/phase1-plan.yaml` (scaffold it with
`tools/coordination/scaffold_phase1_plan.py`, or copy `assets/phase1-plan.template.yaml`) instead of
the dependency map, and emits the same verbs with the same exit codes and levels. `/port-autodrive`
routes to it while a Phase-1 plan has unintegrated units, and scaffolds the plan when it is absent.
The unit is a tooling component, governed by rules F0-F3 of `references/parallel-phase-1.md`: a
signed Phase 0 before anything fans out, Layer 0 proven before Layer 1 opens, producer contracts
before consumers, and acceptance broader than a seeded bug. The driver enforces them fail-closed and
validates its own plan: a unit flagged `accepted` or `integrated` whose evidence or review is
incomplete is reported as triage, never trusted. `integrate` lands on the workbench
(`integrate_land.sh`), then releases the unit's claim (`release_claim.sh`) so it cannot linger.

## Stop conditions

The run stops only for:
- **A red check.** Any conformance or proof failure halts the run; it is never auto-repaired.
- **A budget reached** (`max_waves`, `max_wall_clock`, `max_cost`). The partial run is in git.
- **Done.** Every non-excluded unit is `integrated` and every check is green: seal the milestone
  with `finalize.sh --auto`. L2 stops at the phase boundary; L3 goes on to the next phase.
- **Nothing left to drive.** Every remaining unit waits on the human; the run ends with that list.

None of these is a stop:
- **A review with violations.** The next wave emits `rework`, the worker fixes it in its own
  worktree, and the piece is reviewed again. A piece that exceeds `max_rework` stops on its own and
  is reported; the others continue.
- **A missing human decision.** An unset section 7 band, a withheld scope action, a seam or scoping
  decision, a stale or unsafe claim, a branch that reached into an owned surface: each parks only the
  units that depend on it. The human gets one question per decision, and the run drives everything
  else. Auto-mode never fills in a tolerance band or any other human decision itself.
- **A stuck ready-set** (nothing ready, nothing in flight, not done). At L2 and L3, derive and
  proceed: scope the owned-foundation bootstrap wave, record the rationale, commit it and re-plan.
  At L1 or `status`, recommend it and stop.
- **The declaration-only deadlock.** When every foundation is declaration-only (`validation:
  transitive`, parked, never proven at R0) and its numeric consumers stay blocked, drive the assembly
  proof: build the R1 harness as Phase-1 tooling if it is missing, derive the assembly membership
  from the dependency closure, port the members, prove the closure at R1, and land it as one reviewed
  assembly (`integrate_assembly.sh`), which validates the parked foundations. Recording the assembly
  id and members is setup, not a question for the human.
- **A retrospective.** Mechanization candidates are recorded and built at a phase boundary, never
  mid-run. Scoping the bootstrap wave is not one of them: it is unblock work done now.
- **A large or hard next wave.** Dispatch it. Each worker carries its own context, so a big unit
  burdens the worker, not Ptah-Orchestrator; the hand-driven "context grows heavy" trigger does not
  apply to an autonomous run.
