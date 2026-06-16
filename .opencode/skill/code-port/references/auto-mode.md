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
- **L3 - full auto.** The orchestrator auto-executes **across phase boundaries** too, the
  phase/milestone sign-off performed by the **charter-bot** (an explicitly authorized non-human
  gate that records its verdict in `SIGNOFF.md` like a human would). It halts only on a stop
  condition (below) or completion. This is "no human interaction in any phase."

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
  for action in plan.actions, within charter scope and budget:
     dispatch it (claim / worker / independent review / integrate / advance-phase)
     append the decision + result to the ledger
  re-run the conformance suite; any RED -> HALT
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
  emit the prepared sign-off digest (`/port-digest`) for the human's records (recorded by the
  charter-bot at L3).

## The autodrive ledger (the audit + rollback record)

Every auto-decision the orchestrator makes is appended to a per-run ledger under
`docs/evidence/autodrive/<run-id>/ledger.md` (evidence, committed). One row per decision:

```text
<iso-8601>  action=<claim|work|review|integrate|advance|halt|done>  unit=<id>  level=L3
  rationale: <the planner's reason, verbatim>
  dispatched: <agent/session id, or the command run>
  result: <claimed ref | fragment commit | review verdict | manifest id | exit code>
  conformance-after: <green | RED: which check>
```

Because the planner is deterministic and pure, the ledger plus the committed artifacts fully
reconstruct the run: a human can replay `autodrive.py` at any committed state and get the same plan
the bot acted on, and every dispatch names the distinct agent that did the work and the evidence it
produced. A run with no ledger, or a ledger whose decisions do not match a replay of the planner, is
not a trustworthy auto-run - it is treated as if hand-driven without records.

## How to turn it on

1. In `port/plan/00-charter.md`, set `autodrive.level` (start at **L1** to watch it plan), the
   budgets, and the scope. Keep L0/L1 until you trust the plans on your codebase.
2. Register the worker / reviewer / integrator agent identities in `port/contributors.yaml` as
   **distinct** contributors (the reviewer a different model is the strongest cheap independence
   control). Auto-mode will not gate a piece whose author and reviewer resolve to the same identity.
3. Run `/port-autodrive` (it reads the level and loops). At L1 it prints the plan and stops; at
   L2/L3 it drives, appending to the ledger and halting on any RED.
4. Read the ledger. Anything the bot halted on is waiting for you; everything it did is recorded
   with its evidence.

Auto-mode is the same port, driven by a planner instead of a hand - the gates, the independence,
the bindings, and the conservatism are unchanged, and the ledger keeps it honest.
