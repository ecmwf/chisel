# Team coordination substrate (parallel work on one port)

How many contributors (human or agent) work one large port at once without colliding,
while the fidelity trust core is untouched. This is the **coordination substrate** used
by both parallel Phase 1 (tooling) and parallel Phase 2 (translation). Read it before
building any of the parallel machinery.

> Status: this reference SPECIFIES the substrate. A first tranche is BUILT now (the
> status-fragment schema and its conformance check). The operational machinery - the
> dependency-map extractor, the TRACE generator + drift check, the dashboard, the
> claim detectors, the integrator/merge-queue, and the interface-contract machinery -
> is DESIGNED here and built when a live multi-contributor run needs it (it needs real
> fragments, claims, and a product checkout to run against), exactly as WS-C deferred
> its irreversible steps. Each new detector lands with a seeded red->green record.

## The premise, corrected: derive from validated artifacts

The tempting line "derive coordination from things that already exist" is false as
stated: a local branch is invisible to others, a pushed branch can be abandoned, a
branch named for module A can edit shared file B, and a dependency map can be
incomplete. So derive coordination not from "things that exist" but from **canonical,
validated artifacts**:

- a **claim** (the local `port/claims/<id>.yaml`, or a pushed ref) with a parseable work-item id;
- the **diff against merge-base** (what a branch actually touches, not what it is named);
- **generated** status (never hand-merged);
- dependency **contracts** (versioned, tested);
- CI evidence **bound to a commit**.

"Derive, don't declare" survives - it just has to read the *right*, validated ground truth.

## Shard-and-generate: status is generated, never hand-merged

Today every workflow hand-writes the central `port/TRACE.yaml`; many branches editing
one file collide, violating one-writer-per-worktree. The fix is the methodology's own
"derived values have one source of truth; generate, don't hand-maintain" rule, finally
applied to TRACE:

- each contributor writes a **per-work-item status fragment** in their own branch,
  `port/status/<trace-id>.yaml` (template: `assets/status-fragment.template.yaml`),
  never the central file;
- one port-wide **meta block** lives alongside them at `port/status/_meta.yaml` (template:
  `assets/status-meta.template.yaml`): the `source_root`, `target_root`, and pinned
  `source_commit` the generator stamps into canonical TRACE's `meta:`. It is not a work
  item - the generator and the fragment/identity checks all exclude the `_meta.yaml`
  basename from their glob - and it changes rarely (a SOURCE re-pin), so it does not
  contend like the central file did;
- the canonical `port/TRACE.yaml` is **generated** from the fragments + meta on the
  integration line, and a CI **drift check** fails if the committed canonical file does
  not match what the fragments generate;
- only the integrator/generator writes canonical TRACE.

The same shard-and-generate pattern covers build/test registries (module lists, tolerance
tables, test indices) - accidental foundations that otherwise conflict.

**Append-only registries collide too.** A *growing* central file - the `port/LESSONS.md`
ledger and the `tools/README.md` enforcement-status table are the standing examples - is the
same anti-pattern in a different shape: parallel siblings each append at the end, and the
edits either conflict or, worse, both pick the **same next id** (two branches that both add
the same next `L-####` ledger entry, or two rows for adjacent tiers). A duplicated lesson id
or a silently-merged table row is exactly the corruption the central-write rule forbids. Two
fixes, by file:

- **Prefer sharding** where the file is consumed by tooling (the enforcement table, any
  machine-read index): give each work item its own fragment and GENERATE the central view, as
  with TRACE and the phase-1 plan, so siblings touch disjoint files.
- **Where the file is a human-read narrative** that resists generation (the lessons ledger),
  the integrator owns a **deterministic append/renumber at integration**: each branch writes
  its entry with a placeholder/branch-local id, and the integration step assigns the final
  monotonic id and concatenates in a fixed order. Never let two un-integrated branches both
  claim the next id; the assignment happens once, on the integration line.

## The three "done" states (do not blur them)

- **`gated`** (existing, per-piece): ported, its acceptance gate (tier R1+) passed, and
  an independent fidelity review clean - recorded in its fragment. Unchanged.
- **`integrated`** (new, team-scale): the gated piece is merged into the canonical line - it
  STAYS `gated` (its own per-piece differential gate, tier R1+, and clean review still hold), and
  it now records where it landed (`product.main_commit`). Distinct from `gated` (reviewed but not
  yet merged); never let `gated` quietly mean "merged". The cross-piece **integration epoch** is a
  SEPARATE cadence check (below), NOT part of marking a piece integrated: per-piece fidelity is the
  piece's own R1 gate; the epoch is the interaction backstop run per wave, not per piece.
- **milestone-accepted** (existing): the gate-sealed acceptance over a *group* of pieces - hand-driven,
  a human `SIGNOFF.md`; in L2/L3 auto-mode, `finalize.sh --auto` after full conformance green at HEAD
  (the per-piece independent reviews bound to each gated commit being the acceptance).

## Claims: the local lock, atomic

A claim RESERVES a work item *before* work begins - not "any open branch". By **default** the
claim is the LOCAL file `port/claims/<trace-id>.yaml` that `provision_worker.sh` writes when it
provisions the worker's isolated worktree: the **worktree IS the write lock** (one writer per tree,
made structural below), and the file records the claimant, what it covers, and the lifecycle state.
`port/claims/` is gitignored local coordination state; the planner, dashboard, and `check-claims`
read it directly. Provision leaves an existing claim untouched (idempotent) and is the single
serialized writer of the worktrees, so claiming is atomic for the one operator who owns them. For the **advanced multi-operator** case there is a pushed ref
`refs/claims/<trace-id>` (the tools read it with `--from-refs`), where git's push-to-create is the
cross-operator collision detector. Either way the dashboard shows both the claimed item and the
files the branch actually touches (diff vs merge-base), flagging any mismatch or any reach into an
owned surface.

Claim lifecycle: **created -> active** (provision writes it active) **-> stale = "needs triage"**
(a human looks; never auto-free). TTL and who may release a foundation claim are charter values.
The claim is written as a side effect of provisioning the worktree; releasing it (after the piece
integrates) goes through `release_claim.sh`, which removes the local file and, if a pushed ref
exists, performs the one gated `push --delete`.

## Worker isolation: provisioned worktrees (one writer per worktree, made structural)

`one-writer-per-worktree` is the substrate's core safety property, but it has to be made
STRUCTURAL, not just promised - because opencode Task subagents share the dispatcher's checkout
(there is no per-subagent cwd). Many parallel workers in one session would otherwise contend on one
working tree, and - in the two-repo layout - on the ONE shared product checkout that
`tools/conformance/lib/product-root.sh` resolves every linked worktree back to.

The orchestrator (the single actor that may touch worktree metadata) provisions each piece's
isolated worktree(s) BEFORE dispatch, with `tools/coordination/provision_worker.sh`:

- `provision_worker.sh add <id>` creates a workbench worktree `.worktrees/<id>` on branch `work/<id>`
  (the piece's state, status fragment, and `docs/evidence/<id>/` evidence) and, when a product is
  wired (`port/product.yaml`), ALSO a SEPARATE product-repo worktree `.worktrees/product-<id>` on its
  own `work/<id>` branch (the TARGET code). Single-repo (pre-split) needs only the workbench worktree -
  its `target/` rides inside it. It serializes every `git worktree add/remove/prune` behind a repo-local
  lock, so concurrent dispatches cannot race on `.git/worktrees/`, and refuses (UNRELIABLE) if a wired
  product checkout is absent rather than silently sharing the tree.
- It prints the **dispatch contract** the worker runs against: `WORKBENCH_ROOT`, `PRODUCT_ROOT`, the
  `work/<id>` branch(es), the base commits, and the `docs/evidence/<id>/` prefix. The orchestrator
  hands these to the worker; the worker confines every edit and git command to those roots
  (`git -C "$WORKBENCH_ROOT"` for state, `git -C "$PRODUCT_ROOT"` + exported `PRODUCT_ROOT` for code
  and gates) and NEVER runs `git worktree`/`gc` or touches a shared root. Because a Task subagent does
  not inherit the orchestrator's shell env, the worker's first action `assert_isolated.sh <id> --export`
  DERIVES and re-exports these roots from `<id>` and the layout (an explicit contract still wins and is
  cross-checked), so the contract never evaporates across the dispatch boundary.
- Teardown (`provision_worker.sh remove <id>`) is the orchestrator's, only AFTER the piece is
  integrated. Provisioning is local-only (no push); the merge lands through the sanctioned gated
  scripts (in autodrive the integrator performs it - the gates are the authority, not a keystroke).

This composes with, and does not replace, the existing backstops: the claim (the worktree + its
local `port/claims/<id>.yaml`, or a pushed ref) is still the collision detector, and the
branch-diff-vs-claim + owned-surface checks still catch a branch that reached outside its claim at
review/integration.

**Parallelism = many Task SUBAGENTS in ONE session (the default).** The orchestrator launches each
worker as a parallel background `kha-worker` SUBTASK in its own session - not as separate opencode
sessions. The hazard this must NEVER hit (the shared-worktree bug): because Task subagents share the
dispatcher's checkout (there is no per-subagent cwd), two workers launched against the SAME tree
corrupt each other. The rule is therefore **one provisioned worktree PER PIECE, never shared**: each
piece has a unique trace-id, `provision_worker.sh add <id>` gives it its own `.worktrees/<id>` (plus a
separate product worktree in two-repo), and the worker confines every edit/git to that root. The
STRUCTURAL backstop is each worker's mandatory FIRST action `assert_isolated.sh <id>`, which REFUSES
(fail-closed) unless the roots it resolves ARE this piece's own `.worktrees/<id>` on `work/<id>` (and
an isolated product tree) - so a subtask handed no worktree, the shared checkout, or another piece's
tree STOPS instead of racing. Provision EVERY piece before launching its subtask, and (the
orchestrator's invariant, since each piece has a unique trace-id) never point two subtasks at one
worktree.

*Advanced - separate-session mode:* each worker is its own opencode session opened in the provisioned
worktree (OS-level isolation, for very wide/long waves). Same substrate, same artifacts, same trust
core. Default to Task-subagent mode.

## Owned surfaces vs the leaf pool

The cheap/expensive boundary is not just call-graph fan-in. Numerical codes hide
coupling no call graph shows: globals/common blocks, shared constants, data layout and
indexing/halo conventions, IO formats, build flags, units, precision policy, RNG
streams, boundary conditions, init/mutation order, generated code. So:

- an **owned surface** is *any high-impact contract*, not just a high-centrality node;
- the dependency map carries only what a line scan resolves UNAMBIGUOUSLY: the file inventory, the
  PROVEN in-tree use/call edges, and the STRUCTURAL surfaces - a module USEd by >= 2 units
  (`owned-foundation`) and a common block shared by >= 2 (`shared-surface:*`). Those structural guards
  keep a unit out of the self-serve leaf pool (a human/owner handles the seam);
- the extractor does NOT guess. A reference it cannot resolve in-tree draws no edge and no guard - so
  there is no guessed-coupling class to audit and nothing to clear. The conservatism that guessing used
  to provide now comes from the real net: a unit auto-claimed from the pool that turns out to have a
  hidden coupling fails its R1 DIFFERENTIAL gate or the INDEPENDENT review. That is where coupling the
  line scan cannot see is caught - not by an upfront guess the parser could never get right.

**Core/foundations** keep durable **owners** (of contracts and owned surfaces, not of
TRACE rows). The **leaf base** is a self-serve pool: branch-as-claim + per-module status
fragments, no pre-assigned owner, no hand-declared locks.

## Interface contracts and foundation-change invalidation

Two independently gated modules can each pass their own gate while encoding conflicting
assumptions (layout, units, indexing, halos, init order, precision, IO schema, buffer
ownership) - a silent semantic conflict no merge conflict flags. So shared seams get
**versioned interface contracts with contract/seam tests**, enforced producer-before-
consumer: a consumer gates against a **gated producer contract**, not a moving target.

Gate evidence is **commit-bound** (records the commit hash + the gate-logic version), so
"passed" always refers to a specific state. When an owned surface a branch depends on
moves, or a new standing rule/check lands, the dashboard marks the branch **stale /
needs-rebase** and its gate must re-run before merge. The independent REVIEW, by contrast,
is bound to the piece's target-file BYTES: a rebase that leaves those files byte-identical
keeps the review valid (only the gate re-runs), and a fresh re-review is owed only when the
rebase changed the piece's own files - `tools/coordination/review_revalidate.sh <id>` decides
this fail-closed. Mechanize lessons into checks fast, so propagation never depends on human
memory.

## The integrator is a role with a queue

The serialization point is the **integration branch / merge queue**, not one person:
pre-merge fast (preflight) gates, dependency-ordered merge, **stale-base rejection**,
integration windows, a max queue age, and **backup/rotation** of the role. Which gates
are merge-blocking (fast) vs scheduled (expensive, nightly/weekly), and the
failure-bisection policy, are charter values (code-dependent). For the two-repo model
(WS-C), the integrator merges the **product** PR and records the land (the fragment's
`product.main_commit` + `integration.state`) as one logical step.

## The dashboard

Extend the shipped `tools/scoping/port-progress.py` (already a derived read-only view of
TRACE) into the coordination dashboard: claims (from the local port/claims/ store, or pushed refs, + branch diff),
the derived ready-set, owned-surface flags, stale/needs-rebase markers, and graph
coverage. Read-only; it never writes state.

## New detectors (each seeded before the dashboard/queue is trusted)

Per AGENTS.md, no gate is trusted until it has a current red->green seeded record:

- status-fragment schema check - **BUILT now** (`tools/conformance/check-status-fragments.sh`);
- fragment -> canonical-TRACE **drift** check - **BUILT now**
  (`tools/conformance/check-trace-drift.sh` over `tools/coordination/generate_trace.py`);
- claim-schema parser (valid claim?) and duplicate-claim detector;
- branch-diff-vs-claim (does the branch touch only what it claimed?);
- dependency-staleness / foundation-invalidation detector;
- owned-surface-violation detector (a leaf reaching into an owned surface);
- contract-compatibility check.

Independence is the different-model reviewer: each unit records a distinct
`reviewer_id != author_id` (the fragment check), and `check-trace-evidence` binds that
clean review to the gated commit. In a solo+agents port the reviewer agent on a different
model is the independence control - there is no contributor-identity registry.

Each lands with its seeded demo under `tools/conformance/seeded-bugs/`.

## Layer placement

Per `.gitattributes`, `port/`, `docs/evidence/`, and `tools/scoping|gates|diff` are
project-layer (`merge=ours`); `tools/conformance/` carries the generic checks
(methodology), with one carve-out: a port's OWN conformance checks (keyed to this
program - e.g. a naming map over this SOURCE's identifiers) and their seeded-bug records
live under `tools/conformance/project/`, which `.gitattributes` marks `merge=ours` so they
stay project-layer and never masquerade as base-verbatim methodology that would block a
sync. So:

- **methodology (syncs to every instance):** the command contracts, the AGENTS rule
  changes (claim discipline, fragment-not-central-TRACE, integrator role), the **generic**
  fragment schema + dashboard/generator *framework*, the claim-ref convention, and the
  generic coordination conformance checks + seeded-bug templates;
- **project (`merge=ours`):** the actual `port/status/*.yaml` fragments, the DAG
  extractor *output* + partition, the gate scripts in `tools/gates/`, the
  interface-contract files + tests, `docs/evidence/` packs, and the charter calls.

Placement (resolved): the generic generator/dashboard *framework* lives at a
methodology-owned path - `tools/coordination/` (methodology by `.gitattributes`, since
only `tools/scoping|gates|diff` are carved out as `merge=ours`) - while the per-project
DAG *data* and the live-subset result stay under `tools/scoping/`. So
`tools/coordination/generate_trace.py` is methodology and syncs to every instance; the
`port/status/*.yaml` fragments it reads are project.

**Coarse exclusion for multi-variant SOURCE.** A real SOURCE often ships several BUILD VARIANTS
that share file stems (e.g. a `src_fortran/` vs a `src_fortran_variant/`, both defining the same
`kernel.F90`). Only the LIVE subset is ported, so the dependency map and TRACE cover that subset.
Declare the dead variants COARSELY in `tools/scoping/source-exclude.yaml` (project-layer; template
`assets/source-exclude.template.yaml`) - a few source_root-relative path prefixes/globs, each with a
reason - rather than listing every dead-variant file as `status: excluded` (whose shared stems would
collide). `extract_dependencies.py` skips those paths while walking, so the map is the LIVE source
tree and stays an INDEPENDENT inventory (a forgotten live file is still mapped and must have a TRACE
row - the completeness cross-check keeps its teeth).

**Adopting a hand-driven port into the substrate.** A port done hand-driven (the single-operator
pilot) keeps a SOURCE-keyed `port/TRACE.yaml` (no per-unit `id`) and no fragments, so the planner's
id-keyed join finds nothing. Derive the substrate by hand (it is a mechanical reshape): WRITE one
minimal `port/status/<id>.yaml` fragment per LIVE, UNMAPPED TRACE row, with **id = `stem(source)`** (the
same key the map extractor and the planner use; the minimal form is in
`assets/status-fragment.template.yaml`), plus `port/status/_meta.yaml` from the TRACE meta
(source_root/target_root/commits). Skip excluded rows (dead variants are coarse-excluded above), and
NEVER fabricate an in-progress/gated fragment - its claim/author/independent-review evidence is REAL and
must be authored by hand, never invented (`check-trace-evidence` catches an invented one, and
`check-status-fragments` validates every fragment you write). Then `extract_dependencies.py` builds the
map and `generate_trace.py` regenerates the id-keyed TRACE, and the planner can drive. The unit-id
contract is fixed: **a work-item id is the
SOURCE file stem** (so the fragment, the claim filename, and the map node all agree).

## Additional team-scale rules

- **Duplicate work resolves to the SOURCE-faithful copy.** When two contributors port
  the same item, "better" is **more literal to the SOURCE**, not cleaner/faster/nicer:
  compare both against SOURCE and the gates, keep the source-faithful one, archive the
  other, and record any semantic discrepancy between them as a lesson.
- **The favorable topology is a hypothesis to test, not an assumption.** "Small tangled
  core + wide independent ring" is a common case, not a guarantee; cyclic, preprocessor-
  heavy, or global-state-heavy codes have a thin ready-set. Run a short **parallelizability
  + owned-surface assessment** at the start of Phase 2 (charter); if the graph is tangled
  or DAG coverage is poor, invest in **seams/contracts first** (create the independence the
  SOURCE does not hand you) or accept more serialization.
- **Every owned surface has a backup / escalation rule.** An owner gone unavailable,
  overloaded, or over-conservative must not serialize the team. Owners own **contracts**,
  not every dependent implementation detail, so they are not in the path of every leaf.
- **Independence is the different-model reviewer, enforced syntactically by the schema.** The
  fragment requires a distinct `reviewer_id != author_id`; the independence that makes it real is
  the reviewer agent dispatched on a different model (in a solo+agents port - there is no contributor
  registry, which only ever existed to police a multi-human team).

## What is BUILT now vs DESIGNED/deferred

- **Built now (all seeded):** the status-fragment schema + `check-status-fragments.sh`; the
  deterministic TRACE generator + drift check (`generate_trace.py`, `check-trace-drift.sh`) and
  the TRACE-to-evidence backstop (`check-trace-evidence.sh`, which also requires an explicit
  clean review verdict); the dependency-map extractor - inventory + proven edges + structural surfaces
  (`extract_dependencies.py`, `check-depmap.sh`); the claim detectors (schema, duplicate, branch-diff-vs-claim,
  `check-claims.sh`); the interface-contract check (`check_contracts.py`); and the read-only
  dashboard. An end-to-end scenario exercises the stack together. (The two-repo product-to-evidence
  PROVENANCE binding is not a gate in this lean system: the integration epoch's differential against
  the reference run, `check-trace-evidence`, and the recorded `product.main_commit` are the
  integration record.)
- **Still DESIGNED, not built** (need a live multi-PR run / human process): the
  integrator/merge-queue and integration-window machinery.

## Known limitations (check these MANUALLY until enforced)

A hardening pass gated several properties: **TRACE completeness** (check-completeness - every SOURCE
node has a TRACE row); and the **contract check** now cross-checks the dependency map (a started
consumer with a proven edge to a contract producer must consume it, so under-declaring `depends_on`
no longer dodges it). The two-repo product-to-evidence PROVENANCE binding is not gated in this lean
system (the integration epoch's differential + `product.main_commit` are the record). The residuals
that remain - documented so no one trusts a green run to cover them:

- **Branch-diff-vs-claim is on-demand, not in the no-arg CI pass.** `check-claims.sh` with no args
  runs schema + duplicate only; integration preflight MUST run `--claim <id> --branch <ref> --base
  <base> --owned-surfaces ...` per branch (the orchestrator runs this at preflight, auto-mode
  included), or a branch that strayed its surface passes "CI green".
- **The reference run is confirmed by hand at sign-off,** not against a machine-readable registry (none
  exists yet; `reference/runs.md` is prose).
- **`check-status-fragments.sh` is an awk subset, not a full YAML validator.** It rejects the duplicate/
  unknown keys it can see in the documented two-level block form; an exotic-but-valid YAML shape is
  outside its grammar. The Python coordination tools use a strict PyYAML loader; a future rewrite would
  unify them. (The Python gates that consume the same fragments DO use the strict loader, so a
  shape that slips the awk parser is still caught the moment it must bind to a claim or dependency map.)

## Open questions (human / charter decisions)

Claim-ref scheme and its binding to work-item ids; stale-claim TTL and foundation-claim
release; where the owned/leaf line falls (the hidden-coupling checklist on this code);
integration cadence (which gates block every merge vs scheduled); integrator queue
tooling and rotation; how much up-front seam/contract work if the graph is tangled; how
contracts are expressed/tested in this language pair; the generator/dashboard framework
path; and the cutover interim.
