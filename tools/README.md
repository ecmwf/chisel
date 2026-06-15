# tools/

All instrumentation, gates, and automation. Design rules (full detail in the skill's
`references/differential-tooling.md`):

- Every diff/probe tool is gated so it is inert when off - prefer compile-time removal
  (a preprocessor switch) over a runtime env var. The inertness guarantee is on RESULTS:
  with instrumentation off the build reproduces the reference run's outputs byte-for-byte,
  NOT a hash-identical binary (see `references/differential-tooling.md`).
- Dump formats are raw and exactly specified (endianness, record layout, tags:
  step/substep/location/field) and read back exactly by the other side.
- One small module per tool; resist merging them.
- Gates have exit-code semantics and are CI-callable. Evidence goes to `docs/evidence/`.
- Run a whole class in bulk by globbing its directory, exactly as CI does (`for s in
  tools/conformance/*.sh; do bash "$s"; done`); never hand-list scripts. A hardcoded list
  goes stale the moment a check is added or removed (the one-source-of-truth rule), and an
  agent reciting it from memory will call a script that has been deleted.

| Dir | Contents |
|---|---|
| `diff/` | The six tool classes: staged reference dump, identical-input/replay operator diff, range probes, boundary/communication probe, subsystem disable-switches, executable contracts. Plus the poison-discriminator helper. |
| `gates/` | Validation-ladder tiers (R0–R5) as scripts, one per tier/kernel-group. |
| `conformance/` | Convention enforcement: central index helpers only (`check-index-helpers.sh`), sizing rules, no raw vendor API in portable code, TRACE completeness check, TRACE-to-evidence integrity (`check-trace-evidence.sh`: every gated entry cites a gate and a review report that exist on disk; lists the awaiting-review queue), provenance-anchor verifier (anchors vs pinned SOURCE lines vs TARGET renderings, plus constant-definition coverage), product-README focus (`check-product-readme.sh`: no porting-process vocabulary leaks into the product's own README), product-tree invisibility (`check-product-invisibility.sh`: no `port/`, governance files, or chisel vocabulary in the product tree, anchors excepted), reference-citation integrity (`check-references.sh`: every cited reference path and trap ID resolves after the pairs/langs rulebook split), status-fragment schema (`check-status-fragments.sh`: per-work-item `port/status/*.yaml` fragments are well-formed and reviewer differs from author, before they generate canonical TRACE), TRACE drift (`check-trace-drift.sh`: canonical TRACE matches what the fragments generate, the shard-and-generate cutover gate), audit-manifest binding (`check-audit-manifest.sh`: each WS-C manifest binds its product commit to evidence produced against that exact tree), claim integrity (`check-claims.sh`: each work-item claim ref is well-formed, no two open claims - stale included - reserve the same SOURCE, and - per branch, on demand - a branch touches only its claim's surface). The product-facing checks share one denylist, `chisel-vocabulary.txt`. |
| `coordination/` | The generic (methodology-layer) coordination framework: `generate_trace.py` deterministically builds canonical `port/TRACE.yaml` from the per-work-item fragments (`port/status/*.yaml`), and `--check` is the drift gate run by `conformance/check-trace-drift.sh`; `check_manifest.py` verifies the WS-C audit-manifest binding, run by `conformance/check-audit-manifest.sh`; `check_claims.py` verifies work-item claims (schema, duplicate-source, branch-diff-vs-claim), run by `conformance/check-claims.sh`, reading `refs/claims/*` (or `--claims-dir` fixtures in `coordination/fixtures/claims/`). The generic framework lives here (methodology); the per-project DAG data and the live-subset result stay under `scoping/` (project). |
| `scoping/` | Live-subset determination (build-log/coverage/link-map analysis) and dependency/call-graph extraction (computes porting order and workstream partitioning) - per-project DAG data. At scale TRACE is generated, never hand-written, by the generic `coordination/generate_trace.py` from the fragments. Also `port-progress.py`: a read-only progress view derived from TRACE (gated vs in-progress vs unmapped, weighted by SLOC and files), wired into /port-sprint-start. |

Mechanical mass-transforms (charter §5) also live here as reviewed, committed scripts.

Naming convention: gate scripts are `gates/ci-<tier>-<subject>.sh` (CI-runnable,
fast) or `gates/manual-<tier>-<subject>.sh` (compute-system runs); diff tools live
one per directory as `diff/<tool-id>/`.

## Enforcement status (honesty table - keep current)

Documentation must never imply a check exists before it does. As of bootstrap:

| Check | Status |
|---|---|
| TRACE review/gate evidence integrity | ENFORCED (`conformance/check-trace-evidence.sh`, CI; seeded-bug recorded) |
| Product README stays product-focused | ENFORCED (`conformance/check-product-readme.sh`, CI; seeded-bug recorded) |
| Product tree is chisel-invisible | ENFORCED (`conformance/check-product-invisibility.sh`, CI; seeded-bug recorded; scans `target/` until the split, then the product checkout) |
| Reference path / trap-ID citations resolve | ENFORCED (`conformance/check-references.sh`, CI; seeded-bug recorded) |
| Status fragments well-formed (reviewer != author) | ENFORCED (`conformance/check-status-fragments.sh`, CI; seeded-bug recorded; skips until `port/status/` fragments exist) |
| Canonical TRACE matches the fragments (no drift) | ENFORCED (`conformance/check-trace-drift.sh` over `coordination/generate_trace.py`, CI; seeded-bug recorded; skips until `port/status/` fragments exist) |
| Audit manifest binds product commit to verified evidence | ENFORCED (`conformance/check-audit-manifest.sh` over `coordination/check_manifest.py`, CI; seeded-bug recorded; skips until `port/manifests/` exist) |
| Work-item claims well-formed and non-overlapping (branch-diff on demand) | ENFORCED (`conformance/check-claims.sh` over `coordination/check_claims.py`: schema + duplicate in the no-arg CI pass, branch-diff per branch on demand; seeded-bug recorded; skips until `refs/claims/*` exist) |
| TRACE completeness vs SOURCE tree | Phase 1 deliverable |
| Provenance-anchor verifier | Phase 1 deliverable |
| Naming map / index-helper conformance | index-helper script shipped; instantiate helper names and seeded-bug evidence per TARGET |
| Formatter / linter / sanitizers / coverage | Phase 1 deliverable |
| Ladder gates (R0-R5) | Phase 1+ deliverables, each seeded-bug-demonstrated |

Until a row says ENFORCED, agents check the property manually and must not rely on
CI to catch it. Move a row up only in the same commit that lands its script.
