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

- a **pushed claim ref** with a parseable work-item id;
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

The same shard-and-generate pattern covers build/test registries (module lists,
tolerance tables, test indices) - accidental foundations that otherwise conflict.

## The three "done" states (do not blur them)

- **`gated`** (existing, per-piece): ported, its acceptance gate (tier R1+) passed, and
  an independent fidelity review clean - recorded in its fragment. Unchanged.
- **`integrated`** (new, team-scale): the gated piece is merged into the canonical line
  and the integration checks are green. Distinct from `gated`; never let `gated` quietly
  mean "merged".
- **milestone-accepted** (existing): the human's `SIGNOFF.md` over a *group* of pieces.

## Claims: a pushed ref, atomic

A claim is a **pushed canonical ref** with a parseable work-item id, created *before*
work begins - not "any open branch". Scheme (atomic, preferred): one ref per work item,
`refs/claims/<trace-id>`, claimant recorded in the ref content; push-to-create *is* the
collision detector (two people cannot both create it). The dashboard shows both the
claimed item and the files the branch actually touches (diff vs merge-base), flagging
any mismatch or any reach into an owned surface.

Claim lifecycle: **created -> active** (kept alive by pushes) **-> stale = "needs
triage"** (a human looks; never auto-free, or an offline active branch is silently
duplicated). TTL and who may release a foundation claim are charter values. Per the
git-rules caveat (AGENTS.md keeps push/merge human-run between sprints), the claim is a
small human-confirmed step, never an automatic side effect of starting a sprint.

## Owned surfaces vs the leaf pool; the confidence model

The cheap/expensive boundary is not just call-graph fan-in. Numerical codes hide
coupling no call graph shows: globals/common blocks, shared constants, data layout and
indexing/halo conventions, IO formats, build flags, units, precision policy, RNG
streams, boundary conditions, init/mutation order, generated code. So:

- an **owned surface** is *any high-impact contract*, not just a high-centrality node;
- dependency-map edges carry **confidence**: *proven / suspected / unknown*;
- **unknown coupling stays out of the leaf pool** (default it to guarded) until scoping
  and review prove it cheap;
- the dashboard reports graph coverage, so the team knows how much it can trust.

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
needs-rebase** and its relevant gates must re-run before merge. Mechanize lessons into
checks fast, so propagation never depends on human memory.

## The integrator is a role with a queue

The serialization point is the **integration branch / merge queue**, not one person:
pre-merge fast (preflight) gates, dependency-ordered merge, **stale-base rejection**,
integration windows, a max queue age, and **backup/rotation** of the role. Which gates
are merge-blocking (fast) vs scheduled (expensive, nightly/weekly), and the
failure-bisection policy, are charter values (code-dependent). For the two-repo model
(WS-C), the integrator merges the **product** PR and records the **workbench** audit
manifest as one logical step.

## The dashboard

Extend the shipped `tools/scoping/port-progress.py` (already a derived read-only view of
TRACE) into the coordination dashboard: claims (from pushed claim refs + branch diff),
the derived ready-set, owned-surface flags, stale/needs-rebase markers, and graph
coverage. Read-only; it never writes state.

## New detectors (each seeded before the dashboard/queue is trusted)

Per AGENTS.md, no gate is trusted until it has a current red->green seeded record:

- status-fragment schema check - **BUILT now** (`tools/conformance/check-status-fragments.sh`);
- fragment -> canonical-TRACE **drift** check - **BUILT now**
  (`tools/conformance/check-trace-drift.sh` over `tools/coordination/generate_trace.py`);
- claim-schema parser (valid claim ref?) and duplicate-claim detector;
- branch-diff-vs-claim (does the branch touch only what it claimed?);
- dependency-staleness / foundation-invalidation detector;
- owned-surface-violation detector (a leaf reaching into an owned surface);
- contract-compatibility check;
- contributor-identity check (author/reviewer ids and sessions resolve to DISTINCT
  registered humans). The fragment check enforces only *syntactic* independence
  (`reviewer_id != author_id`, `reviewer_session not in author_sessions`); it cannot tell
  one human under two ids apart, nor catch collusion. Binding ids/sessions to real,
  distinct humans needs a canonical contributor/session registry (a charter/project
  artifact) that this deferred detector checks against.

Each lands with its seeded demo under `tools/conformance/seeded-bugs/`.

## Layer placement

Per `.gitattributes`, `port/`, `docs/evidence/`, and `tools/scoping|gates|diff` are
project-layer (`merge=ours`); `tools/conformance/` carries the generic checks
(methodology). So:

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
- **Identity is enforced only syntactically by the schema.** See the contributor-identity
  detector above: distinct ids/sessions in a fragment do not by themselves prove distinct
  humans; the canonical registry + deferred detector close that gap.

## What is BUILT now vs DESIGNED/deferred

- **Built now:** the status-fragment schema (`assets/status-fragment.template.yaml`) and
  `check-status-fragments.sh` (seeded) - the data model everything else consumes; and the
  **deterministic TRACE generator + drift check** (`tools/coordination/generate_trace.py`,
  `tools/conformance/check-trace-drift.sh`, seeded) - the shard-and-generate linchpin. All
  are self-contained and fixture-seeded. The cutover rule now has its gate: **until the
  TRACE generator + drift check are live and seeded the central-write commands stay serial
  - they now are, so a team can fan out the leaf pool onto sharded+generated status.**
- **Designed, built when a live multi-contributor run needs it** (they require a real
  SOURCE tree / claims / product / multi-PR queue to run against, or a registry): the
  dependency-map extractor + confidence model; the dashboard extension; the claim
  detectors (claim-schema, duplicate, branch-diff-vs-claim); the audit-manifest checker;
  the contributor-identity detector; the integrator/merge-queue; the interface-contract
  machinery.

## Open questions (human / charter decisions)

Claim-ref scheme and its binding to work-item ids; stale-claim TTL and foundation-claim
release; where the owned/leaf line falls (the hidden-coupling checklist on this code);
integration cadence (which gates block every merge vs scheduled); integrator queue
tooling and rotation; how much up-front seam/contract work if the graph is tangled; how
contracts are expressed/tested in this language pair; the generator/dashboard framework
path; and the cutover interim.
