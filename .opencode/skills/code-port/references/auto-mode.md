<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Auto-mode: driving the port with no human in the loop

How the orchestrator (Ptah-Orchestrator) **auto-drives** a port - claiming, dispatching,
reviewing, proving, integrating, advancing phases - performing every recommended action itself,
with no human keystroke, while the fidelity trust core stays exactly as strong as in the
human-driven flow. Read `references/team-coordination.md` (the substrate) and
`references/parallel-phase-2.md` (the roles and the wave loop) first; this reference adds only the
autonomy layer on top of them.

## What auto-mode does and does NOT change

The instinct "removing the human makes it less trustworthy" is half right, and the half that is
wrong is the important half. The port's trust does **not** come from a human clicking the buttons.
It comes from five structural properties, none of which auto-mode touches:

1. **Every check runs and lands commit-bound evidence** (R0-R5, the seeded detectors, the full
   conformance suite). Auto-mode runs the same checks; it cannot mark a piece done without them.
2. **Independence is STRUCTURAL, not procedural.** The one who carves is never the one who
   reviews. Auto-mode dispatches the worker and the reviewer as **separate agent sessions on
   different models** - the different-model reviewer is the independence control (a dispatch
   convention). The machine-checked part: each unit records a distinct `reviewer_id != author_id`
   (`check-status-fragments`), and `check-trace-evidence` binds a clean review verdict to the proven
   commit. There is no contributor registry. The orchestrator coordinates the work; it never reviews
   its own dispatched work.
3. **The conformance checks fail closed.** A trust violation (`check-claims`,
   `check-trace-evidence`, `check-status-fragments`, ...) returns RED, and a RED **always halts** auto-mode.
   Auto-mode never "fixes" a trust failure to keep going.
3a. **Local green is not green - READ CI BEFORE THE NEXT LAND.** After each land that pushes,
   run `gh run list --limit 1` (or the equivalent) and confirm the run SUCCEEDED before landing
   the next unit. A local suite passes with whatever happens to be installed on the machine
   driving it; the runner has only what the workflow installs. The usual symptom is a suite that
   is green locally and red in CI with nothing in the diff to explain it - a check needing a
   parser the runner lacks, correctly reporting UNRELIABLE. Landing again on top of a red CI
   compounds it: the second failure hides the first, and the bisect gets longer every wave.
   If CI is red, fix CI before dispatching more work. Installing the missing tool is the fix;
   loosening the check so it tolerates absence is not.
4. **Everything is bound and auditable.** Every action commits its evidence to git - the proof
   evidence, the recorded clean review bound to the proven commit, the fragment, the regenerated TRACE.
   The git history is the record: a run is reconstructable and reversible after the fact, and the pure
   planner can be re-run at any committed state to confirm the plan the bot acted on.
5. **Conservatism holds.** A guarded unit (an owned foundation, or a shared surface) is never
   auto-claimed into the self-serve pool; auto-mode leaves it for its owner / human scoping. (The map
   records only resolved in-tree dependencies and structural surfaces - it does not guess at coupling;
   a hidden coupling is caught by the R1 differential proof and the independent review.)

So what auto-mode actually removes is the human as an **extra, outer safety check** - the pair of
eyes that might catch something the checks do not. That is a real thing to give up. Auto-mode is
therefore **opt-in per charter**, loud about the trade, and built so the committed git history lets a
human audit or roll back any run. It is for trusted, supervised, or low-stakes batches - not a license
to skip review (it never skips review; it automates *requesting* it from a separate agent).

## Autonomy levels (the charter picks one)

`port/plan/00-charter.md` sets `autodrive.level`. Higher means less human interaction:

- **L0 - off (default).** The orchestrator SUGGESTS the next action; a human runs each. Today's behavior.
- **L1 - plan.** The orchestrator computes and prints the full next-action plan with rationale and
  the exact commands, and executes **nothing**. A dry run, for inspection and for trust-building.
- **L2 - auto through the whole CURRENT phase.** The orchestrator drives every sprint of the current
  phase HANDS-OFF - many sprints in one go - and AUTO-FINALIZES that phase's milestone (tags + lands
  via `finalize.sh --auto`), then stops at the phase boundary. No human interaction within the phase.
- **L3 - auto across ALL phases.** Same continuous, auto-finalizing drive, but it proceeds across phase
  boundaries too - the whole port end-to-end, hands-off, until DONE.

**Auto-finalize - the checks are the acceptance authority, not a keystroke.** In both L2 and L3 the
milestone is sealed by `finalize.sh --auto`, which refuses unless: autodrive is L2/L3 (the operator's
authorization, by enabling it) and the FULL conformance suite is green at HEAD (the machine fidelity
floor - per-unit R1 differentials via check-trace-evidence, completeness, the lot). The "is the
physics preserved" acceptance is the **§7 whole-program criterion the human set ONCE in the charter**
(the parity band the differentials are checked against) plus the per-piece INDEPENDENT review
check-trace-evidence binds to every proven commit - not a per-phase human keystroke. So the human sets
the standard once, and never interacts during the run; auto-mode otherwise halts only on a genuine
decision (a withheld-scope action, a real coupling to scope) or completion. (`finalize.sh` without
`--auto` still takes a human accept-`SIGNOFF.md` for a hand-driven port.)

Independent of the level, the charter also bounds the run: `autodrive.max_wall_clock`,
`autodrive.max_waves`, `autodrive.max_cost`, and `autodrive.scope` (which actions the bot may
perform - e.g. a charter may allow auto-claim and auto-review but withhold auto-integrate). A
withheld action is reported as a recommendation and the loop pauses for it, even at L3.

## The loop

Auto-mode is the wave loop of `parallel-phase-2.md`, turned by a planner instead of a human:

```text
repeat:
  plan = autodrive.py            # read-only: the deterministic next-action plan from the artifacts
  if plan.halt:    STOP (surface for a human; the git history is the record)
  if plan.done:    prepare the sign-off digest + STOP (success)
  # state-mutating actions SETTLE serially, re-planning between (an integrate moves the base);
  # the land script itself runs conformance and ROLLS BACK on red, so it cannot land over a red check:
  for each ready mark-proven / integrate, one at a time:
     dispatch it (the land script checks + rolls back on RED -> HALT); re-plan
  # isolated actions FAN OUT concurrently - the whole ready-set by default (cap with budgets.max_in_flight);
  # a review returning VIOLATIONS is NOT a stop - it becomes the next wave's `rework`, driven automatically:
  batch := the plan's claim / work / review / rework  (whole ready-set, or <= max_in_flight if set)
     claim serially + atomically (check-claims green) -> provision (a message that launches nothing) -> LAUNCH workers/reviewers as parallel background subagent tasks in the next single message
     gather through ONE writer (per-branch claim + owned-surface check before accepting); commit fragments once
until halt or done
```

The **planner** (`tools/coordination/autodrive.py`) is read-only and deterministic: given the
current TRACE + dependency map + claims + phase, it returns the same ordered plan every
time. It computes nothing authoritative and writes nothing - it only *recommends*, exactly like the
dashboard it builds on. The **orchestrator** is the executor that turns the plan into dispatched
agents and git operations, and is the only component that writes (the claims, the fragments, the
commits). Keeping the planner pure is what makes the run auditable and re-runnable: anyone can re-run
the planner at a committed state and get the same plan the bot acted on.

Per-unit, the planner maps the unit's derived state to one recommended action:

| Unit state (derived from the artifacts) | Action | Who executes (a DISTINCT session each) |
|---|---|---|
| unmapped, unclaimed, self-serve-eligible, all proven deps integrated | `claim` | orchestrator provisions the worktree (writes the local `port/claims/<id>.yaml`), dispatches a **worker** |
| claimed, in-progress, no proof evidence yet | `work` | the dispatched **worker** ports + runs the proof, records the fragment |
| in-progress, proof evidence present, no clean review | `review` | a **separate reviewer** agent (distinct id/session/model) |
| in-progress, proof + a VIOLATIONS review | `rework` | back to the **worker** (never auto-proven) |
| proven, not integrated, all proven deps integrated | `integrate` | the **integrator** (Seshat-Integrator) lands the product, records integration (`product.main_commit` + `integration.state`) |
| proven/unmapped but guarded (coupling/partial/shared) | `guarded` | nobody - reported for human scoping (conservatism) |
| live claim on a stale/invalid state | `triage` | nobody - HALT-worthy; a human looks |

## Dispatching a wave - concurrent where it is isolated, serial where it is trusted

A wave's actions split by whether they touch the TRUSTED shared tree. The isolated ones -
`claim`/`work`/`review`/`rework` - each run in their own provisioned `.worktrees/<id>` worktree (two-repo:
a separate product worktree too) and write only their own fragment + `docs/evidence/<id>/`, so they FAN
OUT concurrently - the orchestrator LAUNCHES the whole ready-set as parallel background subagent tasks by
default (fan out is automatic), capped only when `budgets.max_in_flight` is set. **Fan-out is one turn,
not many:** launch them as multiple `subagent` calls in a SINGLE message - not one worker, wait, then
the next. Workers going out in consecutive turns IS the serial anti-pattern. And **foundation-first is a
one-time ordering constraint, not a license to serialize:** once a foundation (owned surface, shared
header, Layer 0) integrates, its dependents that do not depend on EACH OTHER are ready at the SAME time -
re-derive the ready-set after every integrate and launch the newly-unblocked siblings TOGETHER, never one
at a time. Parallel by default
(references/parallel-phase-2.md): there is NO earned-width ramp - after the hard entry check (Layer 0
proven, traps mechanized), LAUNCH the whole safe ready-set at once, every wave. Launch fewer than the
whole ready-set ONLY for a named reason: an unrepresented kind (prove one, then fan out the rest of it
at once) or a set `max_in_flight`; a late bug does not narrow the wave - mechanize the missing check
and rework the cohort in parallel, each piece's own proof + the conformance suite still guard what LANDS. The state-mutating ones - `mark-proven`,
`integrate` - go through the single integrator funnel, so they stay SERIAL and conformance-checked one at a
time, re-planning between (an integrate moves the base; Seshat-Integrator rejects a stale branch).
`claim` itself is orchestrator-owned and atomic (provisioning the worktree writes the local `port/claims/<id>.yaml`; confirm `check-claims` before
dispatching its worker). The orchestrator PROVISIONS each piece's worktree before launching its worker
(`provision_worker.sh add <id>`) in a message that launches nothing (calls in one message run
concurrently, so provisioning beside the launch races it), and NEVER launches one unprovisioned - an unprovisioned worker edits and
commits in the SHARED tree and races every sibling (the worker runs `assert_isolated.sh` first and refuses
if unprovisioned). The orchestrator GATHERS through one writer, running each piece's per-branch
claim + owned-surface check before accepting it, and commits the batch's fragments once. The conformance suite is enforced where work LANDS - each land script (`integrate_product.sh` / `integrate_land.sh` /
`integrate_assembly.sh`) runs the suite and rolls back on red - not as a hand re-run after every action.

**Thread continuity (resume the per-role thread).** The isolated actions run as subagents; on a
dispatch the orchestrator captures the opencode SESSION id (`ses_...`) from the result and records it
(`thread_ledger.py record <id> --role worker|reviewer --session-id <ses_...>`), and on a REVISIT - `rework`
(the worker) or a re-review (the reviewer) - RESUMES that thread (`thread_ledger.py resume <id> --role
<role>` -> the `subagent` tool's `sessionID`) so context carries across the loop instead of rebuilding each round. Any
non-zero exit (3 none, or `resume` refusing a cross-reused/bad handle) -> dispatch fresh with a brief
(never a halt). The worker's thread and the reviewer's thread are NEVER
crossed (independence: the reviewer never inherits the author's context; `check-threads` rejects a crossed
or composed-name handle), and the handle is the unique `ses_` id, never a composed display name (which
collides for split work). This preserves context/cost/consistency; it changes nothing about independence
(still a different-model reviewer in its own thread) or the proofs.

## Phase 1: the tool-build driver

The same loop drives **Phase 1** (building the comparison infrastructure - the differential harness,
the proofs, the conformance checks, the dependency-map extractor, the diff tools) before any
translation. The planner is `tools/coordination/phase1_drive.py`; it reads `port/phase1-plan.yaml`
(the tool-build plan - scaffold it with `tools/coordination/scaffold_phase1_plan.py`, or copy
`assets/phase1-plan.template.yaml`) instead of the SOURCE
dependency map, and emits the SAME verbs (`claim`/`work`/`review`/`rework`/`mark-proven`/`integrate`)
with the SAME exit-code contract and autonomy levels.
`/port-autodrive` routes to it automatically while a Phase-1 plan has un-integrated units. The unit
is a **tooling component**, not a translated module, so the lifecycle differs (`references/parallel-phase-1.md`):

- **F0 - a signed Phase 0 (HALT until true).** The plan's `source_signed` must be true; the driver
  refuses to fan out tooling over an unsigned Phase 0 (it would build against a moving target).
- **F1 - Layer-0 bootstrap, THEN fan out.** Everything compares *through* the differential harness, which
  cannot validate itself through the harness, so Layer 0 is accepted on its own terms and proven FIRST: no
  `layer>=1` unit is claimable until every Layer-0 unit is integrated. Layer 0 is the ONLY near-serial
  part - once the pool opens, the orchestrator fans out the whole Layer-1 ready-set as parallel worker
  subagents exactly as in Phase 2 ("Dispatching a wave"), never one at a time.
- **F2 - producer-before-consumer.** A unit's `depends_on` and the producer of every contract it
  `consumes_contracts` must be integrated first; a consumed version behind the producer's current is
  STALE (rebase + re-accept), surfaced as triage - never silently driven.
- **F3 - acceptance is broader than a seed.** `work` builds the tool, seeds it red->green, and records
  its evidence (each a COMMITTED file under `docs/evidence/phase1/<id>/`); the unit is not `mark-proven`
  until ALL its required records hold - the seeded red->green, a source-side demo, inertness (diff
  tools/harness) or non-vacuity (checks/extractors), an INDEPENDENT review (distinct
  `author_id`/`reviewer_id`) whose verdict is clean, and the `tools/README` enforcement row - because
every later wave trusts this tooling. `integrate` merges into the **workbench** (Phase 1 never
   touches the product, so there is no product land) and then RELEASES the unit's now-done claim
   (`release_claim.sh`, the sanctioned guarded ref-delete) so it cannot linger into Phase 2. Because no
   conformance check validates this
  plan's flags, the driver SELF-VALIDATES: a unit flagged `accepted` or `integrated` whose
  evidence/review is incomplete (or whose deps/Layer-0 are not integrated) is reported as triage
  (fail-closed), never trusted as done.

Enable it the same way (`/port-autodrive enable L1`), scaffold `port/phase1-plan.yaml` with
`tools/coordination/scaffold_phase1_plan.py` (a signed Phase 0; `/port-autodrive` also does this for
you when the plan is absent), and run `/port-autodrive`; at L1 it prints the tool-build plan and stops.

## Stop conditions (auto-mode HALTS, never pushes through)

- **Any conformance/proof check RED.** A binding/independence/evidence violation halts the run; it
  is never auto-repaired. This is the primary safety: the same fail-closed checks a human relies on.
- **A review that returns VIOLATIONS is NOT a halt** - it is the normal review->rework->review loop,
  driven automatically: the next wave emits `rework`, the orchestrator dispatches the worker to fix in
  its own worktree, and the piece is re-reviewed, with no human pause. The loop self-limits - only when
  ONE piece churns review more than `autodrive.max_rework` times does it HALT (not converging - a human
  looks). A rework that cannot be done inside the unit's own claim - its fix needs a surface OUTSIDE that
  claim (an owned-surface reach), or a charter decision that has not been set (an acceptance standard, a
  withheld scope action) - is surfaced as THAT unit's blocker while the rest keep driving; the whole run
  HALTS only when nothing is left to drive.
- **A retrospective is NOT a halt** - an accumulated list of mechanization candidates (recurring manual
  steps worth a future tool) is RECORDED and the loop keeps driving; the candidates are built at a phase
  boundary, never mid-run. Do NOT mis-classify a wave-unblock (scoping the owned-foundation bootstrap
  wave) as one of these deferred candidates - that is derive-and-proceed work done NOW to widen the
  wave, not a tool to build later.
- **A stuck ready-set is NOT a halt at L2/L3:** nothing ready, nothing in flight, and not done (a
  tangled graph with no self-serve leaves) - do NOT just HALT with a blocker list, run the GUIDED
  BOOTSTRAP. At **L2/L3 you DERIVE-AND-PROCEED**: derive the §7 acceptance criterion (per-field
  atol/rtol, principled from the reference-run fields and the Phase-1 baseline tolerances) and scope the
  owned-foundation bootstrap wave NOW, FILL charter §7 / open the wave, record the rationale, and
  re-plan - this is the same wave-unblock work as the bullet above, committed and checked (the §7 band is
  checked by the differential proofs at every land), never silently invented. At **L1/`status`**
  the opposite: RECOMMEND the §7 criterion and the bootstrap wave each with rationale and STOP for the
  human's explicit OK before writing. HALT (even at L2/L3) only when the bootstrap rests on a GENUINE
  decision the artifacts cannot derive - a real shared-surface seam to scope, a conflicting
  standard - and surface the scoping/seam work.
- **The declaration-only deadlock is the ASSEMBLY-PROVING DRIVE, never a halt.** When the planner is
  stuck because every FOUNDATION is declaration-only (`validation: transitive` -> parked -> never proven
  at R0) and the numeric consumers stay `blocked` behind foundations that never integrate per-id, that
  is NOT a deadlock to hand back. At L2/L3 it DERIVES the next move: build the (possibly deferred) R1
  twin harness as Phase-1 tooling (`phase1_drive.py`), derive the assembly membership from the dependency
  closure (kernel -> driver -> entry + their transitive parked foundations), port the foundations
  (assign-bootstrap) and numeric units, prove the closure at R1, and land it as ONE reviewed assembly
  (`integrate_assembly.sh`), which transitively validates the parked foundations. Recording the derived
  assembly id + members is a setup act, not a decision to ask about. (Full drive: `/port-autodrive`,
  the deferred-R1 / assembly-proving clause.)
- **A stale or invalid claim, an owned-surface reach, an UNSAFE claim** - HALT; never auto-freed.
- **A budget exceeded** (`max_wall_clock` / `max_waves` / `max_cost`) - HALT; the partial run is in git.
- **A large or hard upcoming wave is NOT a stop** - dispatch it, do not checkpoint. The orchestrator
  dispatches each piece to a worker carrying its OWN context, so the next unit being big (a kernel, a
  seam) burdens the WORKER, not the orchestrator; the hand-driven "focused sprints / context grows
  heavy" end-trigger does not apply to pausing an autonomous run. The L2/L3 drive is continuous - it
  ends only on DONE, a genuine HALT, or a budget, never on "the next wave is the central effort."
- **A withheld-scope action is the only way forward** - pause and surface it (even at L3, the
  charter can withhold, e.g., auto-integrate).
- **Phase/port done:** every non-excluded SOURCE unit `integrated`, completeness + all checks green -
  AUTO-FINALIZE the milestone with `finalize.sh --auto` (no keystroke; the checks, the per-piece
  independent reviews bound to each proven commit, and the §7 standard set once in the charter are the
  acceptance authority). At L2, stop at the phase boundary; at L3, continue into the next phase until
  the whole port is done.

## The audit trail (the git history)

There is no separate ledger. Every action commits its evidence to git as it goes - the proof evidence
under `docs/evidence/<id>/`, the recorded clean independent review bound to the proven commit, the
status fragment, and the regenerated TRACE - so the run is reconstructable from the history alone.
Because the planner is deterministic and pure, a human can re-run the planner the run used
(`phase1_drive.py` for a Phase-1 run, `autodrive.py` for Phase 2) at any committed state and get the
same plan the bot acted on, and `git log` shows the distinct agent that produced each piece's evidence.
The fidelity floor is the same fail-closed conformance suite a human relies on: it guards every land
(the land scripts roll back on red) and it guards the milestone seal (`finalize.sh --auto`), so the run
can never land or seal over a red check.

## How to turn it on

1. Turn it on - `/port-autodrive enable L1` writes `port/autodrive.yaml` directly from
   `assets/autodrive.template.yaml` (the template documents every field). It sets the `level` (start at
   **L1** to watch it plan), the `scope`, and the `budgets` (L2/L3 need `max_waves > 0` and a
   `max_wall_clock`). The charter §12 explains it in prose; this file is the machine-readable source.
   Keep L0/L1 until you trust the plans on your codebase, then raise the level. There is no identity
   setup: independence is the different-model reviewer, dispatched as a separate agent session and
   recorded per unit.
2. Run `/port-autodrive` (it reads `port/autodrive.yaml` and loops). At L1 it prints the plan and
   stops; at L2/L3 it runs one conformance preflight, plans, drives within scope/budget, and HALTS on
   any red surfaced by a land.
3. Read the git history. Anything the bot halted on is waiting for you; everything it did is committed
   with its evidence, and the end state passes the full conformance suite.

Auto-mode is the same port, driven by a planner instead of a hand - the proofs, the independence, the
bindings, and the conservatism are unchanged. The per-piece independent review (a different-model
reviewer, bound to each proven commit by check-trace-evidence) and the fail-closed conformance suite
keep it honest, exactly as in the hand-driven flow.
