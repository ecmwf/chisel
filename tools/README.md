# tools/

All instrumentation, gates, and automation. Design rules (full detail in the skill's
`references/differential-tooling.md`):

- Every diff/probe tool is gated so it is inert when off (prefer a compile-time switch over a runtime
  env var). The inertness guarantee is on RESULTS: with it off, the build reproduces the reference
  run's outputs byte-for-byte - not a hash-identical binary.
- Dump formats are raw and exactly specified (endianness, record layout, step/substep/location/field
  tags), and read back exactly by the other side.
- One small module per tool; resist merging them. Gates have exit-code semantics, are CI-callable,
  and land evidence in `docs/evidence/`.
- Run a whole class by globbing its directory, as CI does (`for s in tools/conformance/*.sh; do bash
  "$s"; done`) - never hand-list scripts (a hardcoded list goes stale the moment one is added/removed).

| Dir | Contents |
|---|---|
| `diff/` | The six differential tool classes (staged reference dump, identical-input/replay operator diff, range probes, boundary/communication probe, subsystem disable-switches, executable contracts) plus the poison-discriminator helper. |
| `gates/` | Validation-ladder tiers (R0–R5) as scripts, one per tier/kernel-group. |
| `conformance/` | One `check-*.sh` per convention/trust property - exit-code-clean, CI-callable, each backed by a seeded red→green record in `seeded-bugs/`. The full list and enforcement status is the honesty table below. Base-shipped checks here are methodology; a port's OWN program-specific checks (and their seeded-bug records) go under `conformance/project/`, carved out as project-layer (`merge=ours`) in `.gitattributes`. |
| `coordination/` | The generic (methodology-layer) framework for a parallel, many-contributor port: the deterministic TRACE generator, the SOURCE dependency-map extractor, the claim / contributor / audit-manifest / interface-contract checkers, the cross-artifact binding gate, the read-only dashboard, the auto-mode planners (Phase-2 translation + Phase-1 tool-build), the integrity gate, the enable scaffolder, the sign-off-gated finalize (auto-land: tag/land/push/teardown), the worker-worktree provisioner (isolated workbench + product worktrees per piece before dispatch, serialized), the sanctioned contribute push (auto-opens a methodology-layer-only PR to the base for `/port-contribute-to-base`; never merges), the external-access grant (scoped opencode `external_directory` allows so automation never prompts: a `/tmp` scratch allow always, plus the sibling product checkout when two-repo), the Phase-1 plan scaffolder (writes the canonical representative tool-build plan so auto-mode has a Layer-0-first Phase 1 to drive instead of dead-ending on an absent plan), the Phase-1 plan generator (`generate_phase1_plan.py`: assembles the canonical `port/phase1-plan.yaml` from per-unit `port/phase1/units/*.yaml` fragments + `_meta.yaml` so parallel authors never hand-merge the one central plan, exactly as TRACE is generated from status fragments), and the sanctioned sync-resolution merge (the layer-driver base→instance merge into the ephemeral `sync/<id>` branch, shape-checked never to touch `main`), and the sanctioned claim-release (`release_claim.sh`: a fail-closed gated `push --delete` of an integrated, unbound Phase-1 tooling claim's ref plus its `port/claims/` file, so a completed claim never lingers into a later phase's planner), and the worker-isolation preflight (`assert_isolated.sh`: a Kha-Worker's fail-closed first check that it is confined to its own provisioned `.worktrees/<id>` worktree on `work/<id>` and an isolated product worktree, refusing to edit or commit in the shared tree if it was dispatched unprovisioned), and the sanctioned integration auto-land (`integrate_land.sh`: a gated fast-forward merge of a Phase-1 workbench piece the deterministic planner reports integration-ready - conformance green, clean FF, a performer distinct from its author/reviewer - so a charter-bot lands integration with no manual git; the Phase-2 product land stays the integrator's procedure). Each checker `.py` is wrapped by a `conformance/check-*.sh`; the per-project fragments and DAG data it reads live under `port/` and `scoping/`. |
| `scoping/` | Per-project live-subset and dependency/call-graph extraction (porting order, workstream partitioning), plus `port-progress.py` - a read-only progress view derived from TRACE, wired into `/port-sprint-start`. |

Naming: gate scripts are `gates/ci-<tier>-<subject>.sh` (CI-runnable, fast) or
`gates/manual-<tier>-<subject>.sh` (compute-system); diff tools live one per dir as `diff/<tool-id>/`.
Mechanical mass-transforms (charter §5) also live here as reviewed, committed scripts.

## Enforcement status (honesty table - keep current)

Documentation must never imply a check exists before it does. Each ENFORCED check below is CI-run and
has a seeded red→green record in `seeded-bugs/` (what it catches lives there). Until a row says
ENFORCED, agents check that property by hand and must not rely on CI; move a row up only in the same
commit that lands its script.

| Property | Status |
|---|---|
| TRACE review/gate evidence integrity | ENFORCED - `conformance/check-trace-evidence.sh` |
| Product README stays product-focused | ENFORCED - `conformance/check-product-readme.sh` |
| Product tree is chisel-invisible | ENFORCED - `conformance/check-product-invisibility.sh` (fail-closed if a wired product is absent) |
| Tests are product-owned (ship in the product tree) | ENFORCED - `conformance/check-product-tests.sh` (fail-closed if a wired product is absent) |
| Reference path / trap-ID citations resolve | ENFORCED - `conformance/check-references.sh` |
| Status fragments well-formed (reviewer != author) | ENFORCED - `conformance/check-status-fragments.sh` (skips until `port/status/`) |
| Canonical TRACE matches the fragments (no drift) | ENFORCED - `conformance/check-trace-drift.sh` (skips until `port/status/`) |
| Phase-1 plan matches the unit fragments (no drift) | ENFORCED - `conformance/check-phase1-plan.sh` (skips until `port/phase1/units/`; seeded red→green in `seeded-bugs/check-phase1-plan.md`) |
| TRACE completeness vs the SOURCE inventory | ENFORCED - `conformance/check-completeness.sh` (skips until the map + TRACE exist) |
| Audit manifest binds the product commit to committed evidence | ENFORCED - `conformance/check-audit-manifest.sh` (skips until `port/manifests/`) |
| Work-item claims well-formed and non-overlapping | ENFORCED - `conformance/check-claims.sh` (schema+duplicate in CI, branch-diff on demand; skips until `refs/claims/*`) |
| Author/reviewer/claimant ids are distinct registered humans | ENFORCED - `conformance/check-contributors.sh` (skips until `port/contributors.yaml`) |
| Dependency map matches SOURCE (no drift) | ENFORCED - `conformance/check-depmap.sh` (skips until `tools/scoping/dependency-map.yaml`) |
| Interface contracts honored (gated producer, current version) | ENFORCED - `conformance/check-contracts.sh` (skips until `port/status/`) |
| Cross-artifact bindings hold (fragment↔claim↔manifest↔product) | ENFORCED - `conformance/check-bindings.sh` (skips until coordination artifacts are wired) |
| Auto-mode obeys its own trust rules | ENFORCED - `conformance/check-autodrive-integrity.sh` (skips until `port/autodrive.yaml`) |
| Provenance-anchor verifier | ENFORCED - `conformance/verify-anchors.sh` (skips until TARGET code exists; per-TARGET aliases at Phase 1) |
| Naming map / index-helper conformance | `conformance/check-index-helpers.sh` shipped; instantiate helper names + seeded evidence per TARGET |
| No suppression annotations / silenced detectors | ENFORCED - `conformance/check-no-silenced-detectors.sh` (skips until TARGET files exist; C/C++ pattern set, instantiate per TARGET; seeded red→green in `seeded-bugs/check-no-silenced-detectors.md`) |
| Formatter / linter / sanitizers / coverage | Phase 1 deliverable |
| Ladder gates (R0–R5) | Phase 1+ deliverables, each seeded-bug-demonstrated |
