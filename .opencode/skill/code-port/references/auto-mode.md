# Auto-mode: driving the port with no human in the loop

How the orchestrator (Ptah-Orchestrator) **auto-drives** a port - claiming, dispatching,
reviewing, gating, integrating, advancing phases - performing every recommended action itself,
with no human keystroke, while the fidelity trust core stays exactly as strong as in the
human-driven flow. Read `references/team-coordination.md` (the substrate) and
`references/parallel-phase-2.md` (the roles and the wave loop) first; this reference adds only the
autonomy layer on top of them.

## What auto-mode does and does NOT change

The instinct "removing the human makes it less trustworthy" is half right, and the half that is
wrong is the important half. The port's trust does **not** come from a human clicking the buttons.
It comes from five structural properties, none of which auto-mode touches:

1. **Every gate runs and lands commit-bound evidence** (R0-R5, the seeded detectors, the 15
   conformance checks). Auto-mode runs the same gates; it cannot mark a piece done without them.
2. **Independence is STRUCTURAL, not procedural.** The one who carves is never the one who
   reviews. Auto-mode dispatches the worker and the reviewer as **separate agent sessions**,
   registered as **distinct contributors** (different ids, different sessions, and - by default -
   a different model for the reviewer). `check-contributors` still resolves them to distinct
   humans/agents and fails if author == reviewer. The orchestrator coordinates the work; it never
   reviews its own dispatched work.
3. **The conformance checks fail closed.** A binding/trust violation (`check-bindings`,
   `check-claims`, `check-trace-evidence`, ...) returns RED, and a RED **always halts** auto-mode.
   Auto-mode never "fixes" a trust failure to keep going.
4. **Everything is bound and auditable.** Every auto-decision is appended to the **autodrive
   ledger** (below): what, why, which agent, the result. A run is reconstructable and reversible
   after the fact, exactly as if a human had narrated each step.
5. **Conservatism holds.** A guarded unit (suspected coupling, partial coverage, a shared surface)
   is never auto-claimed into the self-serve pool; auto-mode leaves it for human scoping.

So what auto-mode actually removes is the human as an **extra, outer safety check** - the pair of
eyes that might catch something the gates do not. That is a real thing to give up. Auto-mode is
therefore **opt-in per charter**, loud about the trade, and built so the ledger lets a human audit
or roll back any run. It is for trusted, supervised, or low-stakes batches - not a license to skip
review (it never skips review; it automates *requesting* it from a separate agent).

## Autonomy levels (the charter picks one)

`port/plan/00-charter.md` sets `autodrive.level`. Higher means less human interaction:

- **L0 - off (default).** The orchestrator SUGGESTS the next action; a human runs each. Today's behavior.
- **L1 - plan.** The orchestrator computes and prints the full next-action plan with rationale and
  the exact commands, and executes **nothing**. A dry run, for inspection and for trust-building.
- **L2 - auto within a phase.** The orchestrator auto-executes recommended actions inside a phase,
  but **stops at every phase boundary** for a human (or the charter-bot) to sign off before the
  next phase. Each phase drives itself; the phase gate is still a deliberate step.
- **L3 - full auto.** The orchestrator auto-executes **across phase boundaries** too: it does all
  the porting WORK of every phase without pause and, at each boundary, the **charter-bot** records
  a `BOT_ATTESTATION.md` (the prepared `/port-digest` evidence pack plus the auto-decisions). This
  is "no human interaction during the porting work." But the human sign-off is the methodology's
  TOP-LEVEL acceptance authority - that the physics is preserved - and a bot cannot BE that
  authority without it being a different thing. So `BOT_ATTESTATION.md` is NOT `SIGNOFF.md`: the
  milestone git-tag and final phase acceptance still require a human COUNTERSIGN of the bot's
  attestation - a committed accept-`SIGNOFF.md`, which is exactly what `tools/coordination/finalize.sh`
  (the tag/land/push) requires; a `BOT_ATTESTATION.md` alone does not satisfy that gate. L3 minimizes the human to
  exactly that irreducible acceptance, and never forges it. It otherwise halts only on a stop
  condition or completion.

Independent of the level, the charter also bounds the run: `autodrive.max_wall_clock`,
`autodrive.max_waves`, `autodrive.max_cost`, and `autodrive.scope` (which actions the bot may
perform - e.g. a charter may allow auto-claim and auto-review but withhold auto-integrate). A
withheld action is reported as a recommendation and the loop pauses for it, even at L3.

## The loop

Auto-mode is the wave loop of `parallel-phase-2.md`, turned by a planner instead of a human:

```text
repeat:
  plan = autodrive.py            # read-only: the deterministic next-action plan from the artifacts
  if plan.halt:    record + STOP (surface for a human)
  if plan.done:    prepare the sign-off digest + STOP (success)
  # state-mutating actions SETTLE serially, each gated, re-planning between (an integrate moves the base):
  for each ready mark-gated / integrate, one at a time:
     dispatch it; re-run conformance (RED -> HALT); ledger it; re-plan
  # isolated actions FAN OUT concurrently, bounded by budgets.max_in_flight (1 = serial):
  batch := the plan's claim / work / review / rework  (<= max_in_flight)
     claim serially + atomically (check-claims green) -> provision -> dispatch workers/reviewers in parallel
     gather through ONE writer (per-branch claim + owned-surface check before accepting); commit fragments once
  re-run the conformance suite once; any RED -> HALT; ledger the batch rows with a shared batch_id
until halt or done
```

The **planner** (`tools/coordination/autodrive.py`) is read-only and deterministic: given the
current TRACE + dependency map + claims + manifests + phase, it returns the same ordered plan every
time. It computes nothing authoritative and writes nothing - it only *recommends*, exactly like the
dashboard it builds on. The **orchestrator** is the executor that turns the plan into dispatched
agents and git operations, and is the only component that writes (the ledger, the claims, the
dispatches). Keeping the planner pure is what makes the run auditable and re-runnable.

Per-unit, the planner maps the unit's derived state to one recommended action:

| Unit state (derived from the artifacts) | Action | Who executes (a DISTINCT session each) |
|---|---|---|
| unmapped, unclaimed, self-serve-eligible, all proven deps integrated | `claim` | orchestrator pushes `refs/claims/<id>`, dispatches a **worker** |
| claimed, in-progress, no gate evidence yet | `work` | the dispatched **worker** ports + runs the gate, records the fragment |
| in-progress, gate evidence present, no clean review | `review` | a **separate reviewer** agent (distinct id/session/model) |
| in-progress, gate + a VIOLATIONS review | `rework` | back to the **worker** (never auto-gated) |
| gated, not integrated, all proven deps integrated | `integrate` | the **integrator** (Seshat) builds the manifest, lands the product, records integration |
| gated/unmapped but guarded (coupling/partial/shared) | `guarded` | nobody - reported for human scoping (conservatism) |
| live claim on a stale/invalid state | `triage` | nobody - HALT-worthy; a human looks |

## Dispatching a wave - concurrent where it is isolated, serial where it is trusted

A wave's actions split by whether they touch the TRUSTED shared tree. The isolated ones -
`claim`/`work`/`review`/`rework` - each run in their own provisioned `.worktrees/<id>` worktree (two-repo:
a separate product worktree too) and write only their own fragment + `docs/evidence/<id>/`, so they FAN
OUT concurrently, bounded by `budgets.max_in_flight` (1 = serial; you raise the ceiling per the ramp rule,
width earned after clean epochs, never parallel-by-default). The state-mutating ones - `mark-gated`,
`integrate` - go through the single integrator funnel, so they stay SERIAL and conformance-gated one at a
time, re-planning between (an integrate moves the base; Seshat rejects a stale branch). `claim` itself is
orchestrator-owned and atomic (push the shared `refs/claims/<id>` and confirm `check-claims` before
dispatching its worker); the orchestrator GATHERS through one writer, running each piece's per-branch
claim + owned-surface check before accepting it, and commits the batch's fragments once. Conformance then
runs ONCE for the batch; its rows share a `batch_id` and that one verdict in the ledger.

## Phase 1: the tool-build driver

The same loop drives **Phase 1** (building the comparison infrastructure - the differential harness,
the gates, the conformance checks, the dependency-map extractor, the diff tools) before any
translation. The planner is `tools/coordination/phase1_drive.py`; it reads `port/phase1-plan.yaml`
(the tool-build plan - scaffold it with `tools/coordination/scaffold_phase1_plan.py`, or copy
`assets/phase1-plan.template.yaml`) instead of the SOURCE
dependency map, and emits the SAME verbs (`claim`/`work`/`review`/`rework`/`mark-gated`/`integrate`)
with the SAME exit-code contract, autonomy levels, ledger, and `check-autodrive-integrity` gate.
`/port-autodrive` routes to it automatically while a Phase-1 plan has un-integrated units. The unit
is a **tooling component**, not a translated module, so the lifecycle differs (`references/parallel-phase-1.md`):

- **F0 - a signed Phase 0 (HALT until true).** The plan's `source_signed` must be true; the driver
  refuses to fan out tooling over an unsigned Phase 0 (it would build against a moving target).
- **F1 - Layer-0 bootstrap.** Everything compares *through* the differential harness, which cannot
  validate itself through the harness, so Layer 0 is accepted on its own terms and gated FIRST: no
  `layer>=1` unit is claimable until every Layer-0 unit is integrated. The pool opens only then.
- **F2 - producer-before-consumer.** A unit's `depends_on` and the producer of every contract it
  `consumes_contracts` must be integrated first; a consumed version behind the producer's current is
  STALE (rebase + re-accept), surfaced as triage - never silently driven.
- **F3 - acceptance is broader than a seed.** `work` builds the tool, seeds it red->green, and records
  its evidence (each a COMMITTED file under `docs/evidence/phase1/<id>/`); the unit is not `mark-gated`
  until ALL its required records hold - the seeded red->green, a source-side demo, inertness (diff
  tools/harness) or non-vacuity (checks/extractors), an INDEPENDENT review (distinct
  `author_id`/`reviewer_id`) whose verdict is clean, and the `tools/README` enforcement row - because
  every later wave trusts this tooling. `integrate` merges into the **workbench** (Phase 1 never
  touches the product, so there is no audit manifest). Because no conformance check validates this
  plan's flags, the driver SELF-VALIDATES: a unit flagged `accepted` or `integrated` whose
  evidence/review is incomplete (or whose deps/Layer-0 are not integrated) is reported as triage
  (fail-closed), never trusted as done.

Enable it the same way (`/port-autodrive enable L1`), scaffold `port/phase1-plan.yaml` with
`tools/coordination/scaffold_phase1_plan.py` (a signed Phase 0; `/port-autodrive` also does this for
you when the plan is absent), and run `/port-autodrive`; at L1 it prints the tool-build plan and stops.

## Stop conditions (auto-mode HALTS, never pushes through)

- **Any conformance/gate check RED.** A binding/independence/evidence violation halts the run; it
  is never auto-repaired. This is the primary safety: the same fail-closed checks a human relies on.
- **A review that returns VIOLATIONS** sends the piece to `rework`, not `gated`; if a piece churns
  review more than `autodrive.max_rework` times, HALT (it is not converging - a human looks).
- **A stuck ready-set:** nothing ready, nothing in flight, and not done (a tangled graph with no
  self-serve leaves) - HALT for human scoping / seam work.
- **A stale or invalid claim, an owned-surface reach, an UNSAFE claim** - HALT; never auto-freed.
- **A budget exceeded** (`max_wall_clock` / `max_waves` / `max_cost`) - HALT with the partial ledger.
- **A withheld-scope action is the only way forward** - pause and surface it (even at L3, the
  charter can withhold, e.g., auto-integrate).
- **Done:** every non-excluded SOURCE unit `integrated`, completeness + all gates green - STOP and
  emit the prepared digest (`/port-digest`); the human countersigns it for the milestone tag (at L3
  the charter-bot writes `BOT_ATTESTATION.md` alongside it, but never the human's `SIGNOFF.md`).

## The autodrive ledger (the audit + rollback record)

Every auto-decision is appended to a per-run, MACHINE-READABLE ledger at
`docs/evidence/autodrive/<run-id>/ledger.yaml` (evidence, committed; template
`assets/autodrive-ledger.template.yaml`): `run_id`, `level`, a `decisions` list (each with `at`,
`action`, `unit`, `rationale`, `dispatched`, `result`, `conformance_after`, and - for the rows of a
concurrent batch - a shared `batch_id`), and the final `verdict` (`done` or `halt: <reason>`). The
fail-closed invariant is group-aware: `conformance_after` is `green` for every GROUP (a serial action,
or a whole concurrent batch sharing one post-batch verdict) except possibly the LAST, which may be
non-green only when the run halts there - so a ledger can never record the run driving PAST a red check;
only isolated actions may carry a `batch_id` (mark-gated/integrate stay serial).

Because the planner is deterministic and pure, the ledger plus the committed artifacts fully
reconstruct the run: a human (or `check-autodrive-integrity`) can replay the planner the run used at
that state (`phase1_drive.py` for a Phase-1 run, `autodrive.py` for Phase 2) at any committed state
and get the same plan the bot acted on, and every dispatch names the distinct agent that did the
work and the evidence it produced. The **`check-autodrive-integrity` gate**
machine-checks the config, the charter-bot's distinct identity, and this fail-closed ledger
invariant; a run with no ledger, or one that violates it, is not a trustworthy auto-run.

## How to turn it on

1. Turn it on with the toggle - `/port-autodrive enable L1` (or `python3
   tools/coordination/enable_autodrive.py --level L1`) - which scaffolds `port/autodrive.yaml` from
   `assets/autodrive.template.yaml` and runs `check-autodrive-integrity` so you see at once that it is
   valid. It writes the `level` (start at **L1** to watch it plan), the `scope`, the `budgets`, and
   (at L3) the `charter_bot`; pass `--max-waves N --max-wall-clock 4h` for L2/L3 and `--charter-bot
   <id>` for L3. The charter §12 explains it in prose; this file is the machine-checked source. Keep
   L0/L1 until you trust the plans on your codebase, then re-run `enable` with `--force` to raise the
   level. (You can still hand-edit the YAML; the template is the reference.)
2. Register the worker / reviewer / integrator / charter-bot identities in `port/contributors.yaml`
   as **distinct** contributors (the reviewer a different model is the strongest cheap independence
   control). `check-autodrive-integrity` fails if the charter-bot is the same human as any
   author/reviewer; `check-contributors` fails if a gated piece's author and reviewer are.
3. Run `/port-autodrive` (it reads `port/autodrive.yaml` and loops). At L1 it prints the plan and
   stops; at L2/L3 it runs the conformance suite, plans, drives within scope/budget, appends to the
   ledger, and HALTS on any red.
4. Read the ledger. Anything the bot halted on is waiting for you; everything it did is recorded with
   its evidence and re-checked by `check-autodrive-integrity`.

## Independently reviewing an auto-run

`check-autodrive-integrity` machine-checks the CHEAP invariants (config bounds, the charter-bot's
distinct identity, the fail-closed ledger). The STRONGEST verification - that the bot only ever did
what the pure planner recommended - is a procedure a human or a SEPARATE agent runs, so an
auto-driven port gets the same independent eyes a hand-driven one gets. Run it in a fresh session
that did NOT drive the run (the orchestrator never reviews its own run, exactly as it never reviews
its own dispatched code), via `/port-review-autorun`:

1. **Machine checks.** Run `check-autodrive-integrity` (green) and the FULL conformance suite at HEAD
   (all green). This is the single strongest check: whatever the bot did, the END STATE passes every
   gate - independence (check-contributors), gated evidence (check-trace-evidence), the cross-artifact
   bindings, completeness, the lot. A red here is a finding, full stop.
2. **Planner replay - "did the bot only do what the planner said".** For each decision (or a
   representative sample), check out its `planned_at_commit` in an ephemeral `.worktrees/replay`
   worktree, run the planner the run used at that commit (`python3
   tools/coordination/phase1_drive.py` for a Phase-1 run, else `python3
   tools/coordination/autodrive.py`), and confirm the decision's `action <unit>` is in that plan's DO
   list. An action the planner never recommended is a finding. (Honest
   limit: TRACE/map-derived decisions - work/review/mark-gated/integrate - replay EXACTLY; a `claim`
   decision also reads the live `refs/claims/*`, which are not snapshotted per commit, so confirm
   those against the claim refs' reflog and the decision's recorded `result` instead.)
3. **Independence spot-check.** For each `mark-gated`/`integrate` decision, confirm the ledger's
   `dispatched` reviewer is a registered identity DISTINCT from the unit's author (ideally a
   different model) and matches the fragment's recorded reviewer. The gates enforce this at HEAD;
   you confirm the run actually dispatched a separate reviewer, not the orchestrator.
4. **Ledger read.** Every decision's `conformance_after` is green (the fail-closed rule held), the
   `verdict` matches the final state, and no decision drove past a red check.
5. **Verdict.** Record `VERDICT: clean` or the findings in the run's evidence dir
   (`docs/evidence/autodrive/<run>/review.md`). At L3 the human's COUNTERSIGN of `BOT_ATTESTATION.md`
   - and therefore the milestone tag - is contingent on a clean auto-run review; a run with findings
   goes back exactly like a unit with a violations review.

This is the auto-run analogue of `/port-review`: the gates and the integrity check are the machine
floor, and this independent pass is the human (or separate-agent) ceiling that an auto-run must clear
before its results are trusted as if hand-driven.

Auto-mode is the same port, driven by a planner instead of a hand - the gates, the independence, the
bindings, and the conservatism are unchanged, and the ledger + integrity gate + this independent
review keep it honest.
