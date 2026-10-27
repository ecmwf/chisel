---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Drive the port from the planner, at the autonomy level set in port/autodrive.yaml
---

Drive the wave loop from the deterministic planner, within the level, scope and budgets of
`port/autodrive.yaml` (charter section 12). You act as Ptah-Orchestrator. Autodrive removes the
pauses between actions, never a check, the review's independence, or the guarded scripts. The design
and its stop conditions are in the code-port skill's `references/auto-mode.md`.

Argument: `enable [L1|L2|L3]` writes the settings; a level runs at that level, never above the
configured one; `status` prints the plan only: $ARGUMENTS

Never stop the whole run for a human decision. When units need one (a section 7 band, a seam to
scope, marking proven without `auto-prove`), park those units, ask the human once, and keep driving
the rest. The run ends on DONE, a red check, a spent budget, or nothing left to drive.

1. **Enable** (`enable [L1|L2|L3]`). Write `port/autodrive.yaml` from
   `assets/autodrive.template.yaml`: `level` as given (default L1), `scope` the full action list, and
   the budgets (L2 and L3 need `max_waves` above 0 - the enable default is 30 - and a
   `max_wall_clock`, default `24h`). Then ask the human, once, what the run would otherwise wait for:
   may clean, audited units be marked proven without asking (`auto-prove: clean-only` in the
   charter)? Are the section 7 bands the proofs need set (if not, `/port-calibrate` each)? Record the
   answers, report what you wrote, and stop: enabling does not drive.
2. **Settings.** Read `level`, `scope` and `budgets`. If the file is absent or `level` is L0, print
   the plan, say autodrive is off and that `/port-autodrive enable L1` turns it on, and stop. An action
   outside `scope` is reported as a recommendation, never taken.
3. **Check, then plan.** Run `bash tools/run-conformance.sh`; if any check is not green, stop before
   planning. Then pick the planner by the state:
   - a `port/phase1-plan.yaml` with units not yet integrated: `python3
     tools/coordination/phase1_drive.py` (Phase 1, the tools);
   - no Phase-1 plan: it needs a signed Phase 0 (the `phase0-signed` tag, an ancestor of HEAD), else
     stop and name that as the blocker. With it, write the plan with `python3
     tools/coordination/scaffold_phase1_plan.py` (`--dry-run` only at L1), commit it, and plan again;
   - Phase 1 complete: `python3 tools/coordination/autodrive.py` (Phase 2, the translation).

   The planner exits 0 with a plan (or DONE), 1 when stuck (step 4), 2 when an artifact is malformed
   (regenerate it and stop). Print the plan. At L1 or with `status`, stop here.
4. **When the planner is stuck.** At L1, recommend each fix with its reason and stop. At L2 and L3,
   do the derivable ones, commit each as a setup act, and plan again:
   - *A TRACE without ids* (the planner says so): write one minimal `port/status/<id>.yaml` per live,
     unmapped TRACE row (`assets/status-fragment.template.yaml`; `id` is the file's stem) and
     `port/status/_meta.yaml`, then run `python3 tools/coordination/extract_dependencies.py >
     tools/scoping/dependency-map.yaml` and `python3 tools/coordination/generate_trace.py`. Never
     write one for a row in progress or proven: its evidence must be real. A duplicate-stem error
     means SOURCE variants share a name; which is live is the human's call
     (`tools/scoping/source-exclude.yaml`).
   - *Owned foundations* (`assign`): assign each to its owner as the first wave, and record it.
   - *No R1 proof yet* for a reviewed, R0-clean unit: the R1 harness and proof are Phase-1 tooling
     units (`proofs-r1` in `scaffold_phase1_plan.py`). Add them to the Phase-1 plan if missing and
     build them through `phase1_drive.py` like any tool; each is trusted only with its seeded-bug
     record and an independent review.
   - *Declaration-only foundations parked* while their consumers stay blocked: prove the closure as
     one assembly. Derive its members from the dependency closure, port them, prove the closure at
     R1, have the assembled tree reviewed as one unit, and land it with `/port-land`; that validates
     the parked foundations too. Recording the assembly id and members is a setup act, not a question.
   - *A human decision:* a shared surface (`guarded`) to scope, a missing section 7 band, a
     conflicting standard. Park the units that depend on it and ask once. Only the human sets section
     7 (`/port-calibrate`); never write a band yourself.
   - *A leftover claim* (`release`): `tools/coordination/release_claim.sh <id>`.

   A mechanization idea or a retrospective item is recorded for the next phase boundary, never a
   reason to stop.
5. **Before each dispatch**, run `bash tools/coordination/unit_state.sh <id> ...` and cite only the
   commits it prints, never one from memory: a rebase changes them.
6. **Run the wave.** Take the state-changing actions first, one at a time, planning again after each
   (an integrate moves the base): `mark-proven`, `integrate`. Then launch the isolated ones for the
   whole ready-set at once, capped only by `max_in_flight` (AGENTS.md, "Parallel dispatch"):
   - `claim <id>`: `tools/coordination/provision_worker.sh add <id>`, one at a time, in a message that
     launches nothing. It writes the claim `port/claims/<id>.yaml` and prints the worker's contract.
   - `work <id>`: one Kha-Worker per unit, all in the next message, each given its contract. You
     author nothing.
   - `review <id>`: `/port-review`, one `port-review` subagent per unit.
   - `rework <id>`: back to the unit's worker, in its own session, to fix the findings; then a
     re-review.
   - `mark-proven <id>`: apply `/port-review`'s disposition (the audit, then `auto-prove` or the
     human's answer). Never a verdict of your own.
   - `integrate <id>`: start Seshat-Integrator as a subagent to run `/port-land <id>`.
   - `park`, `assign`, `guarded`, `blocked`, `triage`, `release`: handled as in step 4, or reported.

   **Sessions.** After each worker or reviewer dispatch, record its session id from the subagent
   result: `python3 tools/coordination/thread_ledger.py record <id> --role worker|reviewer
   --session-id <ses_...>`. To rework or re-review, get the id from `thread_ledger.py resume <id>
   --role <role>` and pass it as the `subagent` tool's `sessionID`; on any non-zero exit, dispatch
   fresh. Take the id from the ledger, never from the conversation, and never give a worker's session
   to a reviewer or the reverse (`check-threads` checks this).

   **Gathering** (Phase 2). Check each returned branch against its claim (`bash
   tools/conformance/check-claims.sh --claim <id> --branch work/<id> --base main`). Then, as the one
   writer, bring the wave's fragments onto `main` exactly as the branches have them (`git checkout
   work/<id> -- port/status/<id>.yaml`) and commit; stamp the authors
   (`tools/coordination/stamp_author_id.py <id>`) and commit again.

   **Phase 1.** The unit is a tool: `work` builds it, seeds it red-then-green and records its
   acceptance evidence under `docs/evidence/phase1/<id>/`; `mark-proven` sets `accepted: true` once
   all five records of `references/parallel-phase-1.md` (F3) hold. Its records stay on `work/<id>`
   and land with it.
7. **Keep the product visible.** As pieces pass review, put them on the product's `bring-up` preview
   branch with `tools/coordination/integrate_bringup.sh <id>` (conformance-checked, no proof needed,
   never the mainline), so the product fills up, builds and is pushed during the run; each moves to
   the mainline unchanged through `/port-land` once proven. Keep the product README current
   (`assets/PRODUCT-README.template.md`, `references/product-readme.md`). At L1, recommend; push
   nothing.
8. **Loop and seal.** Plan again after each wave until DONE or a stop. The land scripts run the
   conformance suite themselves and roll back on red; a red from a land stops the run, and a trust
   violation is never repaired automatically. On DONE, seal the milestone with
   `tools/coordination/finalize.sh <tag> --auto`: it refuses unless the level is L2 or L3 and the
   full suite is green at HEAD. The acceptance is those checks, each proven unit's clean independent
   review, and the section 7 standard the human set. At L2, stop at the phase boundary; at L3, go on
   to the next phase. Whenever you stop, tell the human exactly what waits and why.
9. **Before the final milestone, make the product usable.** DONE means every SOURCE unit is
   integrated, not that a consumer can build and run the product. Before the last `finalize.sh
   --auto`: land the non-code run assets (example inputs, sample data, runtime configs, docs) with
   `tools/coordination/integrate_assets.sh <branch>`, which refuses source and build files
   (`references/two-repo-architecture.md`, "Product run assets"); confirm each ported unit's tests
   ship in the product and run in its build (`check-product-tests.sh` cannot see a test never brought
   over); fill the README (`check-product-readme.sh --require-filled`); and check that a fresh clone
   builds and runs its self-test, with tests for every ported unit. At L1, recommend this.
