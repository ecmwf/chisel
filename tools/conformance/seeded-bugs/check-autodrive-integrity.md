# SEEDED-BUG DEMONSTRATION - conformance/check-autodrive-integrity

- Date: 2026-06-18 (new detector: machine-enforce orchestrator auto-mode's trust rules)
- Detector: tools/conformance/check-autodrive-integrity.sh (wraps tools/coordination/check_autodrive_integrity.py)
- Failure class targeted: auto-mode (references/auto-mode.md) lets the orchestrator drive a port with
  no human in the loop. Its trust properties - the charter-bot is a DISTINCT identity from every
  author/reviewer, the autonomy level is bounded, and a run NEVER drives past a red conformance check
  - were initially only PROSE instructions to an LLM agent. An agent that deviates (signs as an
  author, runs L3 with no budget, or keeps going after a red check) would be caught by nothing. This
  gate makes the machine-checkable properties machine-checked, fail-closed.
- Exit-code contract: 0 GREEN (config, identity, and every ledger verify, or auto-mode is off), 1
  RED (a violation), 2 UNRELIABLE (no python3 / PyYAML / git).

Auto-mode is configured by `port/autodrive.yaml` (template assets/autodrive.template.yaml); each run
appends to `docs/evidence/autodrive/<run>/ledger.yaml` (template assets/autodrive-ledger.template.yaml).
Absent config -> auto-mode is off (L0); the gate skips.

## Per-arm red proofs (each isolates one rule)

### CONFIG (the autonomy config is well-formed and the level is bounded)

- **L3 without a charter_bot:** `level: L3`, `charter_bot: null` -> RED: `level L3 requires a
  charter_bot id (the distinct identity that records attestations)`.
- **L2/L3 with no wave budget:** `level: L2`, `budgets.max_waves: 0` -> RED: `level L2 requires
  budgets.max_waves > 0 (it cannot auto-run otherwise)`; an L2/L3 with no `max_wall_clock`/`max_cost`
  is RED the same way (an unbounded auto-run is never allowed).
- Also RED: `schema_version` != 1, a `level` not in L0..L3, a `scope` action outside
  {claim, work, review, rework, mark-gated, integrate}, or a non-integer `max_waves`/`max_rework`.

### IDENTITY (the charter-bot never authored or reviewed) - the independence crux

- **charter_bot is also an author/reviewer:** `charter_bot: alice` while a fragment has
  `author_id: alice` -> RED: `charter_bot 'alice' is the same human as an author/reviewer ... (a bot
  that signs attestations must never author or review)`. The comparison is by registered HUMAN (NFC
  + casefold), so a second id for the same human cannot disguise it.
- **charter_bot's human reused by another contributor:** `charter_bot: ci-bot` (human `ci-bot`) and
  a `worker` whose `human: ci-bot` -> RED: `charter_bot 'ci-bot' shares its human with registered
  contributor(s) worker - the bot ... must be a DISTINCT identity from every contributor`. This is a
  REGISTRY-level check (no fragment needed), so filling a scaffold with the bot's human reused as a
  role is caught at enable/setup time, not only once a piece is gated.
- **L2/L3 with no registry:** `port/contributors.yaml` absent -> RED: `level L2 requires a
  contributor registry ... but it is absent` (auto-mode needs registered identities to resolve
  independence at all). `enable_autodrive.py` at L2/L3 now SCAFFOLDS a starter registry when absent,
  so this arm is mostly reached only if the file is deleted - the common state is the next one.
- **A scaffolded-but-unfilled registry:** a `port/contributors.yaml` whose worker/reviewer/integrator
  `human` keys are still `<...>` placeholders -> RED: `port/contributors.yaml has unfilled
  <placeholder> identities (...) - replace them with the REAL distinct humans ... and re-run`. The
  gate refuses to GREEN on placeholder strings (`_registry_humans` skips them and `_registry_placeholders`
  flags them), so raising the level to L2/L3 lands on a ready-to-fill file that is honestly RED until
  the human declares the distinct humans - the genuine separation-of-powers input, not the tool's.

### LEDGER (a run never drove past a red check) - the fail-closed crux

- **A non-green conformance mid-run:** a ledger whose second of three decisions records
  `conformance_after: "red: check-bindings"` while `verdict: done` -> RED: `decision 1 has
  conformance_after 'red: ...' but the run did not HALT there - auto-mode drove past a trust
  violation`. A red verdict is allowed ONLY on the last decision of a `verdict: halt` run.
- Also RED: a ledger missing `run_id`/`level`/`decisions`/`verdict`, a decision missing any field, a
  decision `action` outside the valid set, or a ledger `level` exceeding the configured level.
- **A decision with no `planned_at_commit`:** every decision must record the workbench commit the
  planner ran against -> RED: `decision <i> missing 'planned_at_commit'`. Without it, the independent
  reviewer cannot REPLAY `autodrive.py` at that state to confirm the action was in the plan (the
  strongest auto-run check; see references/auto-mode.md "Independently reviewing an auto-run", run by
  `/port-review-autorun`). The gate enforces the field's PRESENCE; the replay itself is the
  independent reviewer's procedure, not a machine gate.

## Green proof (defects removed)

- A valid L1 config (`level: L1`, empty scope, `max_waves: 0`): GREEN - a plan-only level needs no
  bot, budget, or registry.
- A valid L3 config with a positive wave budget, a wall-clock budget, and `charter_bot: botsign` (a
  registered contributor whose human differs from every author/reviewer), plus a ledger whose every
  `conformance_after` is `green` and `verdict: done`: GREEN, exit 0.
- The base repo with no `port/autodrive.yaml`: GREEN, exit 0 (skip) - auto-mode is not configured.

## Scope / non-defect signals confirmed

- This gate does NOT replay the planner at each ledger commit (that is the documented audit
  procedure: `autodrive.py` is pure, so replaying it at a decision's commit reproduces the action).
  It machine-checks the cheap, high-value invariants: config bounds, the charter-bot's distinct human,
  and the fail-closed ledger rule. The planner-replay and the per-action conformance are the
  orchestrator's runtime duty, recorded in the ledger this gate then audits.
- Fail-closed UNRELIABLE (exit 2) distinct from RED: no PyYAML/git, or a config that is not valid
  YAML / not a mapping. Absent config skips (exit 0), never a false pass.

## Comparison-logic version

The logic is: load `port/autodrive.yaml` (skip if absent); validate schema_version/level/scope/
budgets and the L2/L3 (positive wave budget + wall-clock-or-cost) and L3 (charter_bot) requirements;
for L2/L3 require the registry, that it has no unfilled `<placeholder>` identities, and that the
charter_bot resolves to a HUMAN distinct from every fragment author/reviewer; for every
`docs/evidence/autodrive/<run>/ledger.yaml` require the structure,
a level not exceeding the config, valid actions, a `planned_at_commit` on every decision (so the run
is replayable), and the fail-closed invariant (a non-green conformance_after only on the last
decision of a halted run). Empty violations -> GREEN, any -> RED,
bad env -> UNRELIABLE. Re-run this demonstration after any change to those rules (standing seeded-bug
rule): every arm above must go RED and the valid configs/ledger stay GREEN.
