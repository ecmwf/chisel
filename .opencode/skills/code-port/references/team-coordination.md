<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Team coordination substrate (parallel work on one port)

How many contributors, human or agent, work one large port at once without colliding, while the
fidelity safeguards stay untouched. This substrate serves both parallel Phase 1 (tooling) and
parallel Phase 2 (translation). Read it before running either with more than one worker.

## Derive coordination from validated artifacts

"Derive coordination from what already exists" is false as stated: a local branch is invisible to
others, a pushed branch can be abandoned, a branch named for module A can edit shared file B, and a
dependency map can be incomplete. So coordination is derived from **canonical, validated artifacts**:

- a **claim** (the local `port/claims/<id>.yaml`, or a pushed ref) with a parseable work-item id;
- the **diff against the merge-base** (what a branch actually touches, not what it is named);
- **generated** status, never hand-merged;
- versioned, tested dependency **contracts**;
- evidence **bound to a commit**.

## Shard and generate: status is generated, never hand-merged

Many branches editing one central `port/TRACE.yaml` collide and break one writer per worktree. So
the "derived values have one source of truth" rule applies to TRACE:

- each contributor writes a **per-work-item status fragment** on their own branch,
  `port/status/<id>.yaml` (template `assets/status-fragment.template.yaml`), never the central file;
- one port-wide **meta block**, `port/status/_meta.yaml` (template `assets/status-meta.template.yaml`),
  holds `source_root`, `target_root`, `source_commit` (the local import commit) and `upstream_commit`
  for the generator to stamp into TRACE's `meta:`. It is not a work item - the generator and checks
  skip it - and it changes only when the SOURCE is re-pinned;
- the canonical `port/TRACE.yaml` is **generated** from the fragments and the meta block on the
  integration line (`tools/coordination/generate_trace.py`), and `check-trace-drift.sh` fails if the
  committed file differs from what the fragments generate;
- only the generator, run by the integrator, writes canonical TRACE.

A hand-driven single stream may edit TRACE directly until it adopts fragments (below). The same
pattern covers build and test registries (module lists, tolerance tables, test indices), which
otherwise become accidental shared foundations.

**Append-only registries collide too.** A growing central file - the `port/LESSONS.md` ledger, the
`tools/README.md` enforcement table - is the same problem in another shape: siblings append at the
end, and the edits conflict or, worse, both take the same next id. Where tooling reads the file,
shard it and generate the central view. Where it is human narrative that resists generation (the
lessons ledger), each branch writes its entry with a provisional id, and the integration step assigns
the final number and concatenates in a fixed order, once, on the integration line (failure mode B25).

## The three "done" states (do not blur them)

- **`proven`** (per piece): ported, its R1+ proof passed, and an independent review clean, recorded
  in its fragment (AGENTS.md defines it).
- **`integrated`**: the proven piece has landed on the canonical line and records where
  (`product.main_commit`). It stays `proven`; never let `proven` quietly mean "landed". The
  cross-piece **integration epoch** is a separate cadence check per wave, not part of marking a piece
  integrated: per-piece fidelity is the piece's own R1 proof.
- **milestone-accepted**: the sealed acceptance over a group of pieces, through `finalize.sh`
  (AGENTS.md; for L2 and L3, `auto-mode.md`).

## Claims: the local lock, atomic

A claim reserves a work item before work begins. By default it is the local file
`port/claims/<id>.yaml` that `provision_worker.sh` writes when it provisions the worker's worktree:
the worktree is the write lock, and the file records the claimant, what it covers and its state.
`port/claims/` is gitignored local state that the planner, the dashboard and `check-claims` read
directly. Provisioning leaves an existing claim untouched and is the single serialized writer of the
worktrees, so claiming is atomic for the operator who owns them. When several people share a port, a
pushed ref `refs/claims/<id>` (read with `--from-refs`) uses git's push-to-create as the
cross-operator collision detector. Either way the dashboard shows the claimed item next to the files
the branch actually touches, flagging a mismatch or a reach into an owned surface.

Lifecycle: **created -> active** (provisioning writes it active) **-> stale**, which means "needs
triage": a human looks, and it is never freed automatically. The TTL and who may release a foundation
claim are charter values. Releasing a claim after its piece integrates goes through
`release_claim.sh`, which removes the local file and, if a pushed ref exists, performs the one guarded
`push --delete`.

## Worker isolation: provisioned worktrees

One writer per worktree is the substrate's core safety property, and it has to be structural:
opencode subagents share the dispatcher's checkout, so workers launched against the same tree
corrupt each other - and in the two-repo layout they would share the one product checkout that
`tools/conformance/lib/product-root.sh` resolves every linked worktree back to. Ptah-Orchestrator,
the only actor that touches worktree metadata, provisions each piece before dispatch:

- `provision_worker.sh add <id>` creates `.worktrees/<id>` on branch `work/<id>` (the piece's state,
  fragment and `docs/evidence/<id>/`) and, when a product is wired (`port/product.yaml`), a separate
  product worktree `.worktrees/product-<id>` on its own `work/<id>` (the TARGET code). It serializes
  every `git worktree` operation behind a lock and refuses (UNRELIABLE) if a wired product checkout is
  missing, rather than sharing a tree.
- It prints the **dispatch contract**: `WORKBENCH_ROOT`, `PRODUCT_ROOT`, the branches, the base
  commits and the evidence prefix. The worker confines every edit and git command to those roots and
  never runs `git worktree` or `gc`. A subagent does not inherit its dispatcher's shell, so the
  worker's first action, `assert_isolated.sh <id> --export`, derives and re-exports the roots from the
  id and the layout (an explicit contract still wins and is cross-checked). It refuses, fail-closed,
  unless the roots are this piece's own worktrees, so a worker handed no worktree, the shared
  checkout or another piece's tree stops instead of racing.
- Teardown (`provision_worker.sh remove <id>`) belongs to Ptah-Orchestrator, after the piece is
  integrated and its workbench evidence (review reports, fragment, proof logs) is gathered onto the
  workbench mainline and committed, the branch's exact bytes first. It refuses, removing nothing,
  while the worktree holds an uncommitted file or `work/<id>` carries evidence the mainline lacks;
  `--discard-ungathered` is for an abandoned piece only. Provisioning never pushes; lands go through
  the guarded scripts.

Parallelism is many subagents in one session, one provisioned worktree per piece, never shared: each
piece has a unique id, and two subagents never point at one worktree. The claim and the
branch-diff-vs-claim and owned-surface checks remain the backstops for a branch that strays.

Isolation is not enough on its own: a worktree is provisioned once while the mainline moves on, so a
piece can be built against a base that no longer exists. `assert_isolated.sh` therefore also refuses a
stale worktree, naming the rebase that fixes it, rather than moving the worker's base silently.
`check-worktree-freshness.sh` reports every stale live claim as a `NOTICE:` at preflight so
Ptah-Orchestrator rebases before dispatch; staleness is drift, not a defect, so it does not fail the
suite. Both exist because "remember to rebase" is an intention of the one participant nobody audits
(the meta-lesson in `failure-modes.md`).

For very wide or long waves, each worker may instead run as its own opencode session opened in its
provisioned worktree. The substrate, the artifacts and the safeguards are the same; subagents are the
default.

## Owned surfaces vs the leaf pool

Numerical codes hide coupling no call graph shows: global state, shared constants, data layout,
indexing and halo conventions, I/O formats, build flags, units, precision policy, random streams,
boundary conditions, initialization order, generated code. So:

- an **owned surface** is any high-impact contract, not just a high-centrality node;
- the dependency map carries only what the extractor resolves without ambiguity: the file inventory,
  the proven in-tree edges, and the structural surfaces - a unit imported by two or more units
  (`owned-foundation`) and global state shared by two or more (`shared-surface:*`). These guards keep
  a unit out of the self-serve leaf pool, and an owner handles the seam;
- the extractor does not guess. A reference it cannot resolve draws no edge and no guard. A unit
  claimed from the pool that has a hidden coupling fails its R1 proof or its independent review;
  that is where coupling the extractor cannot see is caught.

Core foundations keep durable **owners** (of contracts and owned surfaces, not of TRACE rows). The
**leaf base** is a self-serve pool: a claim and a fragment per piece, no pre-assigned owner, no
hand-declared locks.

The shipped extractor, `tools/coordination/extract_dependencies.py`, reads a Fortran SOURCE with
preprocessor guards. A SOURCE in another language needs an extractor that writes the same map schema
(`assets/dependency-map.template.yaml`). For a SOURCE that ships several build variants sharing file
names, declare the dead variants coarsely in `tools/scoping/source-exclude.yaml` (template
`assets/source-exclude.template.yaml`) - a few path prefixes, each with a reason - rather than listing
every dead file as `excluded`. The extractor skips them, so the map stays an independent inventory of
the live tree, and a forgotten live file still needs a TRACE row (`check-completeness.sh`).

## Interface contracts and foundation-change invalidation

Two independently proven modules can each pass their own proof while encoding conflicting
assumptions (layout, units, indexing, halos, initialization order, precision, I/O schema, buffer
ownership) - a silent conflict no merge flags. Shared seams therefore get **versioned interface
contracts** with seam tests, enforced producer before consumer. Each fragment declares
`provides_contract` and `consumes_contracts` (`"<name>@<version>"`), and `check-contracts.sh` requires
one provider per contract, a proven producer, an exact version match, and a consumer that consumes
the contract of every producer it has a proven map edge to. `port/COORDINATION.md` describes the
contracts in prose.

Proof evidence is commit-bound (the commit and the proof-logic version), so "passed" always means a
specific state. When an owned surface a branch depends on moves, or a new standing rule or check
lands, the branch needs a rebase and its proof re-runs before it lands. The independent review is
tied to the piece's own target-file bytes instead: a rebase that leaves them byte-identical keeps the
review (`review_revalidate.sh <id>` decides, fail-closed). Mechanize lessons into checks quickly, so
propagation never depends on memory.

## The integrator is a role with a queue

The serialization point is the land funnel, not a person: fast pre-land checks, dependency-ordered
lands, stale-base rejection, land windows, a maximum queue age, and backup or rotation of the role.
Which checks guard every land and which run on a schedule, and the bisection policy, are charter
values. In the two-repo model, the integrator lands the product piece and records the land
(`product.main_commit` and `integration.state` in the fragment) as one logical step.

## The dashboard

`tools/coordination/dashboard.py` is the read-only coordination view Ptah-Orchestrator runs to report
status: claims (local or pushed), the derived ready-set, owned-surface flags, and graph coverage,
joined by work-item id. It fails closed: a piece shows as ready only when every check passes, and a
malformed artifact makes the report UNRELIABLE. `tools/scoping/port-progress.py` is the simpler
progress view derived from TRACE alone. Neither writes state.

## Adopting a hand-driven port into the substrate

A hand-driven port keeps a SOURCE-keyed `port/TRACE.yaml` with no per-unit `id` and no fragments, so
the planner finds nothing. The reshape is mechanical: write one minimal `port/status/<id>.yaml` per
live, unmapped TRACE row, with **id = the SOURCE file stem** (the key the extractor, the claims and the
planner all use; minimal form in the fragment template), plus `port/status/_meta.yaml` from the TRACE
meta. Skip excluded rows. Never fabricate an in-progress or proven fragment: its claim, author and
review evidence are real and must be written from the real record (`check-trace-evidence` and
`check-status-fragments` reject invented ones). Then build the map with `extract_dependencies.py` and
regenerate TRACE with `generate_trace.py`, and the planner can drive.

## Additional team-scale rules

- **Duplicate work resolves to the SOURCE-faithful copy.** When two contributors port the same item,
  "better" means more literal to the SOURCE, not cleaner or faster: compare both against the SOURCE
  and the proofs, keep the faithful one, archive the other, and record any semantic discrepancy
  between them as a lesson.
- **A favorable topology is a hypothesis to test.** "Small tangled core, wide independent ring" is
  common, not guaranteed; cyclic, preprocessor-heavy or global-state-heavy codes have a thin
  ready-set. Run the parallelizability assessment (`parallel-phase-2.md`) before Phase 2; if the graph
  is tangled, invest in seams and contracts first or accept more serial work.
- **Every owned surface has a backup or escalation rule.** An unavailable, overloaded or
  over-cautious owner must not serialize the team. Owners own contracts, not every dependent detail.
- **Independence is enforced syntactically.** The fragment schema requires `reviewer_id != author_id`
  and `reviewer_session` outside `author_sessions`; the reviewer always runs in a separate session and
  should run on a different model. There is no contributor-identity registry, so the check cannot tell
  two ids that name the same person.

## What is built, and what to check by hand

**Built, each with a seeded record:** the fragment schema and `check-status-fragments.sh`; the TRACE
generator and `check-trace-drift.sh`; `check-trace-evidence.sh` (a proven unit has an R1+ proof with
its commit and a clean review report); the dependency-map extractor and `check-depmap.sh`;
`check-completeness.sh` (every SOURCE node has a TRACE row); `check-claims.sh` (schema, duplicates,
and branch-diff-vs-claim on demand); `check-contracts.sh`; the dashboard; and the guarded land
scripts, which land only the proven commit and roll back on red.

**Not built:** a queue system with land windows and a maximum age; the two-repo check that the
product HEAD equals `port/product.yaml`'s `attested_commit`; a machine-readable registry of reference
runs.

**Check these by hand, since a green run does not cover them:**
- Branch-diff-vs-claim runs only on demand: `check-claims.sh` with no arguments checks schema and
  duplicates. Before each land, run `check-claims.sh --claim <id> --branch <ref> --base <base>
  --owned-surfaces ...` for the piece (Ptah-Orchestrator does at gather, autodrive included).
- The reference run is confirmed by hand at sign-off; `reference/runs.md` is prose.
- Fragment independence is syntactic: the check compares ids, not people.

Charter decisions for a team port: the stale-claim TTL and foundation-claim release; where the owned
and leaf line falls on this code; the integration cadence (what guards every land, what runs on a
schedule); queue rotation; how much up-front seam and contract work a tangled graph needs; and how
contracts are expressed and tested for this language pair.
