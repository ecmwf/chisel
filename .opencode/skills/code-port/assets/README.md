# code-port templates

Each template, the file a port makes from it, and what writes and reads that file. The port's
own state files (charter, LESSONS, KNOWN-DIVERGENCES, COORDINATION, TRACE) start as the files in
`port/`; the rendering-convention templates are in the target-conventions skill's `assets/`.

| Template | Becomes | Written by | Read by |
|---|---|---|---|
| `FIRST-HANDOFF.template.md` | `port/handoffs/main.md`, before the first sprint | `tools/chisel-init.py` | `/port-sprint-start` |
| `HANDOFF.template.md` | `port/handoffs/<workstream>.md` | `/port-sprint-end` | `/port-sprint-start`; chisel-init keeps a handoff whose `Written by:` line names a sprint |
| `TRACE.template.yaml` | the row format of `port/TRACE.yaml` | `/port-sprint-end`, or `generate_trace.py` from the status fragments | `check-trace-evidence.sh`, `check-completeness.sh`, `port-progress.py` |
| `status-fragment.template.yaml` | `port/status/<id>.yaml` | Kha-Worker on its branch; Ptah-Orchestrator records the ids | `check-status-fragments.sh`, `generate_trace.py` |
| `status-meta.template.yaml` | `port/status/_meta.yaml` | once per port | `generate_trace.py` |
| `claim.template.yaml` | `port/claims/<id>.yaml` (local, gitignored) | `provision_worker.sh` | `check_claims.py`, `thread_ledger.py`, the planners |
| `phase1-plan.template.yaml` | `port/phase1-plan.yaml` | `scaffold_phase1_plan.py`, or `generate_phase1_plan.py` | `phase1_drive.py`, `check-phase1-plan.sh` |
| `phase1-meta.template.yaml` | `port/phase1/_meta.yaml` | once per port | `generate_phase1_plan.py` |
| `phase1-unit-fragment.template.yaml` | `port/phase1/units/<id>.yaml` | the unit's Kha-Worker | `generate_phase1_plan.py` |
| `autodrive.template.yaml` | `port/autodrive.yaml` | `/port-autodrive enable` | `/port-autodrive`, `finalize.sh --auto` |
| `dependency-map.template.yaml` | the schema of `tools/scoping/dependency-map.yaml` | `extract_dependencies.py`, or an extractor written for another SOURCE language | the planners, `check-depmap.sh`, `check-completeness.sh`, `check-contracts.sh` |
| `macro-state.template.yaml` | `tools/scoping/macro-state.yaml` | Phase 0 | `extract_dependencies.py` |
| `source-exclude.template.yaml` | `tools/scoping/source-exclude.yaml` | Phase 0 | `extract_dependencies.py` |
| `assemblies.template.yaml` | `tools/scoping/assemblies.yaml` | before `integrate_assembly.sh` | `check-completeness.sh` |
| `PRODUCT-README.template.md` | the product's `README.md` | `tools/new-product.sh` seeds it | `check-product-readme.sh --require-filled` |
| `BRING-UP-HARNESS.template.md` | `port/bring-up-harness.md` | when the first module cannot yet be proven | the bring-up sprint |
| `SEEDED-BUG.template.md` | `docs/evidence/<date>-seeded-<detector>/SEEDED-BUG.md` | `/port-seed` | `/port-review`, `/port-digest` |
| `CALIBRATION.template.md` | `docs/evidence/<date>-calibration-<metric>/` | `/port-calibrate` | the human, who sets the band |
| `SIGNOFF.template.md` | `SIGNOFF.md` in an evidence pack | `/port-digest`, with the human's answer | `finalize.sh` |
| `SOURCE-FINDINGS.template.md` | `port/SOURCE-FINDINGS.md`, if a port lacks it | Kha-Worker, Ptah-Orchestrator | the human, for the upstream owners |
| `CONTRIBUTIONS.template.md` | `port/CONTRIBUTIONS.md`, if absent | `/port-contribute-to-base` | `/port-contribute-to-base` |
