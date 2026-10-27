---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Land a proven piece through its guarded script, then record it and tear its worktree down
---

Integrate one proven piece. Ptah-Orchestrator runs this, hand-driven and in autodrive alike, as soon
as a piece is `proven`: never in a later "integration sprint". It marks nothing proven; that is
`/port-review`'s disposition.

Piece (its trace-id; for an assembly, the assembly id): $ARGUMENTS

1. **Check.** The piece is proven: its fragment on the workbench mainline says `status: proven` (a
   Phase-1 tool: `accepted: true` on `work/<id>`). If not, stop and name what is missing - a review,
   the human's answer, a divergence to ratify - and leave it to `/port-review`. The land scripts read
   the fragments: a port kept in TRACE alone builds them first (`/port-autodrive` step 4, "A TRACE
   without ids").
2. **Land** with the guarded script for its kind. Each refuses a piece that is not proven and ready,
   runs the full conformance suite on the land's result, rolls back on red, and pushes from inside:
   - a translated piece: `tools/coordination/integrate_product.sh <id>`. It lands only the proven
     commit: the product branch `work/<id>` must end at the fragment's `proof.commit` and include the
     product mainline. After a base move, rebase and re-prove; a fresh review is owed only if the
     rebase changed the piece's own target files (`tools/coordination/review_revalidate.sh <id>`);
   - an assembly: `tools/coordination/integrate_assembly.sh <assembly-id> --members "<id> ..."`,
     with the same rule for its `proof.commit`;
   - a Phase-1 tool: `tools/coordination/integrate_land.sh <id>`, a fast-forward onto the workbench.
3. **Gather.** A product land carries only the product. Bring the piece's workbench evidence (review
   reports, proof logs, its fragment) from `work/<id>` onto the workbench mainline exactly as the
   branch has it (`git checkout work/<id> -- <paths>`), and commit that before recording anything on
   top. For a Phase-1 tool, commit any evidence still uncommitted in its worktree.
4. **Record.** A translated piece or an assembly: write the printed `product.main_commit` and
   `integration.state: integrated` into its fragment (an assembly: into its own and every member's,
   and set `attested_commit` in `port/product.yaml`), then run
   `tools/coordination/generate_trace.py`. A Phase-1 tool: set `integrated: true` for the unit (its
   `port/phase1/units/<id>.yaml`, then `tools/coordination/generate_phase1_plan.py`, when the plan is
   generated from unit files), commit, and release its claim (`tools/coordination/release_claim.sh
   <id>`).
5. **Close.** Commit, push `main`, and tear the worktrees down (`tools/coordination/provision_worker.sh
   remove <id>`; it refuses while any evidence is not gathered). Report the piece, the
   `product.main_commit`, and any other piece now ready to land; land those too.
