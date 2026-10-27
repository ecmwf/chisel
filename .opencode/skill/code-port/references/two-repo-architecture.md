# The two-repo architecture: workbench and product

The port is kept in **two repositories**, so that the people who consume the ported
code never see the machinery that produced it, while every product commit remains
provably tied to its fidelity evidence.

- The **workbench** (the chisel instance): the methodology layer, `source/` at the
  pinned commit, `port/` state, `tools/`, the **porting conventions**, the
  reference-run definitions, all proof/review **evidence**, and the full porting
  history. This is where the work happens and where trust is established.
- The **product** (the target codebase): a clean, normal repository - product README,
  ordinary tooling config (formatter/linter/build/CI), **its own test suite** (`tests/`: the
  unit drivers and the captured input/output vectors they replay), **the run assets a consumer
  needs to actually use it** (example inputs, sample data, runtime configs - see "Product run
  assets" below), and a history of only code commits. Chisel is invisible here. The product is
  not "done" when the code compiles; it is done when a fresh clone can be **built AND run** from
  what is in it.

The split is safe **only because the workbench is the attestation authority for exact
product commits**: every integrated product commit is bound, in the workbench, to the
evidence that it reproduces the SOURCE. Read this before executing the split, and
whenever touching linkage, proofs, or migration.

> Status: this is the standard architecture. New ports are created this way by
> `chisel-init` / `tools/new-product.sh` (a workbench + a linked, clean product repo).
> Migrating a pre-existing single-repo instance follows the documented procedure (last
> section); the only irreversible step - creating/pushing a repo - is run interactively by
> the tools and is the human's to confirm.

## Linkage: a sibling clone (C1)

The product is its own repository. The workbench references it through a committed
`port/product.yaml` (template: `assets/product.yaml.template`):

- `repo` - the product repository URL;
- `checkout` - the local path where the workbench expects the product working tree
  (a sibling directory by convention, e.g. `../<name>-product`);
- `default_branch` - the product's protected mainline (e.g. `main`);
- `attested_commit` - the latest product commit the workbench has attested (advanced by
  each integrated unit's `product.main_commit`, the commit its independent review was bound to).

Not a submodule (it entangles the two histories and adds friction to every product
commit) and not a workbench worktree (a worktree shares one history, so it could not
give the product its own clean history). `tools/base-repo.txt` keeps pointing at the
**methodology base only**; it is never overloaded with the product pointer.

## Provenance anchors: KEEP (C2)

The default is unchanged from v1: every ported routine and nontrivial constant carries
an inline SOURCE anchor, and `tools/conformance/verify-anchors.sh` machine-checks each
against the pinned SOURCE, comparing every anchored constant with the SOURCE constant by
value. This survives the split:

- **KEEP (default):** the product code carries SOURCE anchors but no chisel branding.
  That already satisfies "chisel-invisible" - it reads as a port that cites its origin,
  not as our scaffolding - and it preserves the verifier and side-by-side review at no
  cost. This is the v2 default.
- **STRIP (a final release transform only):** clean code, but the released product can
  no longer be anchor-verified directly; it requires a comments-only / code-equivalence
  certificate from the anchored commit to the stripped commit.
- **RELOCATE (inline anchors -> an external, commit-bound provenance database in the
  workbench):** fidelity-safe ONLY after a replacement provenance-map verifier exists
  and is seeded, keyed by `product_commit + product_path + symbol/span + content-hash`
  (never mutable file:line alone); the product is then no longer self-verifying.

Do NOT adopt strip or relocate until that replacement machinery is built and
seeded-bug-demonstrated. Until then, KEEP.

## Porting conventions move to the workbench (C3)

The rendering conventions cannot live in a chisel-invisible product, so they live in the
workbench at `port/conventions/<source>-to-<target>.md`; only normal tooling files
(`.clang-format`, build/CI config, lint config) live with the product. Every instruction
reads that workbench path. `tools/conformance/check-references.sh` validates the cited
`references/` links and trap IDs; a dedicated stale-`target/CONVENTIONS.md` rule is a
possible future addition, not yet built.

## Bind the review to the FINAL product commit (C4)

Clean product history (C5) means the integrator lands a reviewed deliverable as one
**squashed** product commit; the evidence must bind to *that* commit, not to the
pre-squash branch (no stale evidence - the validation ladder's rule). The core property is
that the independent review demonstrably saw the EXACT tree that ships.

In this lean system that binding lives in the LAND/SEAL checks, with no separate provenance
artifact to maintain: `tools/coordination/integrate_land.sh` re-runs the full conformance suite on the
MERGE RESULT (the landed tree) and rolls back if red; and `tools/coordination/finalize.sh`
binds the acceptance to the reviewed commit - hand-driven, HEAD must be the commit that recorded
the `SIGNOFF.md` (no unsigned commits on top); in L2/L3 auto-mode (`--auto`), it seals on full
conformance green at HEAD, with each landed piece's INDEPENDENT review already bound to its proven
commit by check-trace-evidence (so what was reviewed is exactly what is sealed). The acceptance is
enforced at the check that seals, with no manifest to maintain. The fragment's `product.main_commit` records where the unit
landed; `workbench_manifest` is an optional extra binding, not enforced.

## Clean product history (C5)

The product receives only code commits (conventional `feat`/`fix` per coherent
deliverable). The messy per-piece history, the TRACE matrix, the reviews, and the proof
logs stay in the workbench. The sanctioned land `tools/coordination/integrate_product.sh <id>`
enforces this: it SQUASH-merges each reviewed piece onto the product mainline as one clean commit
(two-root conformance at HEAD and on the merge result, stale-base rejection, roll-back-on-red, then
pushes). Done when the product's `git log` reads like a normal project's, with no chisel terms.

## The bring-up PREVIEW branch (see progress before the mainline fills)

The mainline only receives R1-proven pieces, so early in a port it is empty for a while - "0% proven,
all work on branches" - and you cannot see or build the target taking shape. That is a visibility
gap, not a reason to weaken the mainline's landing guard. Fill it with a **`bring-up` preview branch**, separate
from the certified mainline: `tools/coordination/integrate_bringup.sh <id>` SQUASH-lands a piece's
`work/<id>` onto `bring-up` with the `proven` requirement RELAXED (no R1, no `proven` status, no
planner-readiness) but the FULL conformance suite still green at HEAD AND on the merge result + rolled
back on red - so `bring-up` is real, BUILDABLE code-in-progress, just not certified faithful. Clone
the product, `git checkout bring-up`, and build the target so far. A piece graduates to the mainline
UNCHANGED when it is R1-proven (`integrate_product.sh`); `bring-up` never IS the shipped line and C5
(clean mainline history) is untouched. **Keep `bring-up` CURRENT as the run proceeds:** the
orchestrator pushes each wave's independently-reviewed pieces to `bring-up` as it goes, so the target
repo visibly fills up and stays clone-build-runnable throughout - it is the DELIVERABLE's in-flight
view, not a final-land surprise. This matters most in an ASSEMBLY bring-up, where NOTHING reaches the
proven mainline until the whole closure is R1-proven: without the preview the target would sit empty and
unpushed for the entire run. (You may also run `integrate_bringup.sh <id>` by hand anytime; under
autodrive it is part of driving.)

**Base new workers on `bring-up` during an assembly bring-up.** A freshly provisioned worker's
product work/<id> branch defaults to the product MAINLINE, which is empty early in a port (the
proven mainline receives nothing until a closure is R1-proven; transitive foundations reach it only via
an assembly land). Branching a worker from an empty mainline leaves it unable to compile against
the skeleton + the already-reviewed peer pieces it depends on. During bring-up, provision each
worker with `provision_worker.sh add <id> --product-base bring-up` so its product branch CARRIES
the accumulating closure from the bring-up preview - the assembly-proving bring-up flow, where each
work branch carries its whole dependency closure and the closure is composed by MERGING member
branches (not hand-copying subdirs) at the assembly land.

## Product run assets (the clone-build-RUN-able product)

A runnable product needs more than ported code and per-module fixtures: the **example inputs,
sample data, runtime configs, and a finalized README** a consumer needs to actually run and
self-test it. These have NO SOURCE file, so they are not pieces, the Phase-2 planner never
recommends them, and the code-land paths (`integrate_product.sh` / `integrate_assembly.sh`, which
require a proven, fidelity-reviewed code piece) will never push them. Without a path of their own,
they fall through - the program lands but the inputs/examples/README never reach the product, and a
human must `git push` them by hand. They have a sanctioned home:

- **`tools/coordination/integrate_assets.sh <branch>`** lands a product branch of NON-CODE asset
  changes onto the product mainline, conformance-checked and crash-safe exactly like
  `integrate_product.sh` (two-root suite green at HEAD AND at the merge RESULT, roll-back-on-red,
  then pushes from inside the script). It is the asset analogue of the code land: the keystroke is
  never the trust check, the conformance-green RESULT is.
- **The safety boundary:** it REFUSES any change to a fidelity-reviewed TARGET source or build file
  (`*.c`/`*.h`/`*.rs`/`*.f90`/..., `CMakeLists.txt`/`*.cmake`/`Cargo.toml`/...). Those determine
  numerical behaviour and can never ride the asset path - they land through `integrate_product.sh`
  / `integrate_assembly.sh` under an independent review. Conformance-green at the merge result is
  the backstop that a landed asset did not break the build/run/self-test.
- **What rides which path:** a module's own `tests/fixtures/` vectors ride that module's proven code
  piece (they are the proof's oracle - `kha-worker.md`); standalone consumer run assets (example
  inputs, sample data, configs) and README finalization land via `integrate_assets.sh`. The product
  is handover-ready only when these are present AND pushed (a fresh clone builds and runs).

### Assembly-proven deliverables land as ONE reviewed tree (no manifest)

`integrate_product.sh <id>` assumes each piece is an **independently-composable, independently-proven**
layer. Some deliverables are not: their **proof is assembly-level** (one differential links several
modules - no single module passes the proof in isolation), and their parallel-port work branches are
**independent full-closure trees** (each carries its whole dependency closure and defines the same build
target with a different source set), authored for an *assembly*, not as incremental layers. Landing such a
deliverable per-id fails structurally - landing one member moves the mainline and **stales** the rest, the
members' build files conflict, and an intermediate mainline holding only some members **cannot pass the
assembly-level proof**. Detector: the proof differential links multiple modules, OR the work branches each
carry the full closure / share a build target (failure mode B7).

The fix keeps the lean model - it does NOT re-introduce an audit manifest. Treat the deliverable as one
**assembly piece**:

- a `work/<assembly-id>` branch carrying the **assembled tree** (the proven members' WHOLE reviewed product
  trees PLUS the build glue that wires them - the glue is product code, reviewed below, not unreviewed
  integrator hand-glue). **Compose by MERGING the member branches wholesale, never by hand-copying selected
  subdirs.** Each member shipped not just `src/` but its `tests/` driver(s) and any fixtures/vectors
  (`kha-worker.md`: tests are product-owned); hand-picking `src/` + CMake silently DROPS those tests, and
  because the land faithfully ships whatever the assembled branch holds, a fresh clone's `ctest` then runs
  only the few tests that happened to come along (failure-mode: tests present on the member branches but
  never composed; `check-product-tests` arm 3 catches the milder "shipped a test source but never wired it
  into the build", and the integration review below owns "the clone is actually self-testing").
- a proven fragment `port/status/<assembly-id>.yaml` recording its **assembly-level proof** AND one
  **INTEGRATION-LEVEL review** that walks the assembled commit itself (`reviewed_commit == the assembly
  commit`), including the build glue (subject to review + the no-process-meta rule for comments and commit
  subjects). A per-module review binds the per-module tree and never the assembled tree, so the assembly
  needs its OWN review - bound to the assembly commit by `check-trace-evidence` exactly like any piece's
  review. That integration review's map audit also catches a *spurious* extractor edge, not just a missing
  one (a line-based extractor can over-report). The integration review also OWNS "the clone is genuinely
  self-testing": confirm the assembled product builds its test target and a fresh clone's `ctest` runs a
  test for each ported member (not just one) - a member whose `tests/` did not survive composition is a
  dropped regression net, sent back, not waved through.

Land it with `tools/coordination/integrate_assembly.sh <assembly-id> --members "<id> ..."`: it requires
(in a freshly generated TRACE) the assembly `proven` and every member EITHER `proven` OR transitively validated
(see "Assembly-proven acceptance" below), runs two-root conformance at HEAD and
on the merge RESULT (armed rollback, push nothing on red), SQUASH-merges the assembled branch as one clean
commit, then pushes - the SAME fail-closed contract as `integrate_product.sh`, for a deliverable whose unit
of review and proof is the assembled tree. "The review saw the shipped bytes" is enforced exactly as for a
per-id land (the squash lands the reviewed branch tip; conformance re-runs on the merge result) - no
tree-hash manifest. (A first-class **assembly-piece in the planner** - a member group routed to the
assembly land rather than per-id triage - is a natural follow-up.)

**Assembly-proven acceptance (when the proof is inherently whole-program).** Some members of an assembly
CANNOT be exercised in isolation - they compute nothing meaningful alone, only as part of the assembled
program - so a per-member runtime differential (the R1 twin) is not constructible for them. Their numerical
correctness is proven TRANSITIVELY by the assembly's whole-program differential, not by a standalone proof.
The acceptance rule:
- **The assembly** carries the strict proof: an R1+ whole-program differential against the reference AND
  ONE independent integration-level review of the assembled commit. It is the `proven` unit.
- **A member** is accepted if EITHER (i) it is `proven` in its own right (it had a constructible R1 twin -
  use it; transitive is never a shortcut for a unit that COULD be proven alone), OR (ii) it is a
  **transitive** member: its fragment carries `proof.validation: transitive` (terminal in-isolation tier R0,
  never `proven`), it is **covered by - actually exercised by - the assembly differential** (non-vacuous), and
  it STILL has its own **independent, clean faithfulness review on disk** that clears the SAME bar a proven
  member's review does: `reviewer_id` set and `!= author_id`, `reviewer_session` not in `author_sessions`,
  `author_sessions` non-empty, `review.evidence` git-tracked, and the verdict explicitly `clean` (a
  `violations` verdict is rejected first - the exact controls `check-status-fragments` + `check-trace-evidence`
  apply to a proven row). The transitive path replaces ONLY the impossible per-member runtime differential; it
  never relaxes the independent-review controls - the anti-self-approval control (B1/B2/B3) is non-negotiable.
- So an inherently whole-program deliverable does NOT owe a separate runtime R1 per member; it owes one
  whole-program R1 + one integration review + a per-member faithfulness review. `integrate_assembly.sh`
  enforces exactly this (a non-proven member must be `validation: transitive` with a clean review, else it
  refuses); a member with no review, a violations verdict, or that could have been proven alone does not ride
  in. The honest record on each transitive member reads: faithfully reviewed in isolation, numerically
  validated as part of assembly `<id>`.

**Declare the assembly so the completeness check accepts it.** The assembly's proven fragment makes it a
TRACE row, but an assembly has NO single SOURCE unit, so the completeness check (every TRACE row maps to a
dependency-map node) would reject it - and `integrate_assembly.sh` fail-closes on that red before it can
land, so **no assembly can land until the check knows it is one**. Resolve it WITHOUT weakening completeness:
declare the assembly in an assemblies registry (`tools/scoping/assemblies.yaml`, project layer like the
dependency map; template in `assets/assemblies.template.yaml`) listing the assembly id and its members.
`check_completeness.py` then EXEMPTS the assembly row from the reverse direction **only when** it is
declared AND every declared member is a real dependency-map node - so SOURCE units still cannot vanish from
TRACE, and a fake/empty-member assembly cannot smuggle a phantom unit. The forward direction (every SOURCE
unit has a row) is untouched. Trigger: add the assembly to `tools/scoping/assemblies.yaml` (from the
template) BEFORE running `integrate_assembly.sh`; the registry's members must match its `--members` list.
This is a methodology-layer change to the completeness check - build it through the meta-check (a seeded-bug
demo that a dropped real unit, a non-assembly phantom row, AND a fake-member assembly each still go RED,
plus an independent review), since the check is part of the trust core.

## Two-root proof invocation (C6)

SOURCE stays in the workbench; proofs and epochs run **from the workbench against the
product checkout**. The contract is five environment variables, so any proof/conformance
script can be pointed at either a single repo (today) or two roots (after the split):

- `WORKBENCH_ROOT` - the workbench working tree (defaults to the repo root);
- `PRODUCT_ROOT` - the **product tree** root (the TARGET code), consistently: before the
  split it is `$WORKBENCH_ROOT/target`, after the split it is the product checkout from
  `port/product.yaml`. It is never the workbench root - the workbench is methodology by
  design, so scanning it as "the product" would be meaningless. A script that needs the
  product's repo root separately uses `PRODUCT_REPO_ROOT`; do not overload one variable
  with two meanings;
- `SOURCE_PIN_REF` - the pinned SOURCE ref (already honored by `verify-anchors.sh`);
- `SOURCE_SUBDIR` - where SOURCE lives under the workbench (default `source/`);
- `REFERENCE_RUN_ID` - the canonical reference run for acceptance.

Product CI builds and tests the code normally - the test suite is **product-owned** (it lives
in the product's `tests/`, so a clone is self-testing), while the fixture GENERATOR that
instruments the SOURCE stays in the workbench (`tools/diff/`). The fidelity proofs, conformance
checks, and epoch verification run in workbench (or integrator-run) CI against product commits.
For workbench CI to check out a PRIVATE product, give it a read-only product credential as the
Actions secret `PRODUCT_RO_TOKEN` (ci.yml uses it to authorize the clone); without it the
product checkout is unreachable in CI and the product-facing checks fail closed (UNRELIABLE),
never a silent pass.

Locally, the sibling product checkout is a directory outside the workbench. opencode 2 allows the
agents to read and edit such directories without asking (its default `external_directory` policy), so
a hands-off run never stalls on a prompt for the product or for `/tmp` scratch, and nothing needs
granting.

## Cross-repo trust boundary (C7)

Product `main` is **protected**: only integrator / merge-queue commits are
fidelity-certified, and workbench CI is to refuse when the configured product HEAD differs
from `port/product.yaml`'s `attested_commit` (that attestation-head check is a Phase-1
deliverable, not yet enforced). Product PRs may NOT alter the workbench's proofs,
SOURCE, tolerances, conventions, or evidence - those protected surfaces live in the
workbench, out of a product contributor's reach. A product contributor can change code;
only the workbench can attest it.

## Two-layer model (C8)

In the two-repo layout the product code is NOT a workbench directory: `target/**` is absent
from the `.gitattributes` layer map, `/port-sync-with-base` and `/port-contribute-to-base`
never touch the product, `tools/base-repo.txt` points at the methodology base, and
`port/product.yaml` records the product linkage. (Migrating a pre-existing single-repo instance
makes exactly these changes WITH the split, when `target/` leaves the workbench.)

## Chisel-invisibility check (C9)

A workbench conformance check (`tools/conformance/check-product-invisibility.sh`)
asserts the product tree carries no methodology leakage, over three arms: no methodology
STRUCTURE at any depth (a `port/` directory, `.claude`/`.opencode`, or `AGENTS.md`/
`CLAUDE.md` - including dangling symlinks, found with `find`); no chisel vocabulary in
file CONTENTS (case-insensitive, from the shared `chisel-vocabulary.txt`); and no chisel
vocabulary in the product's COMMIT SUBJECTS over its whole history (when `PRODUCT_ROOT`
is a separate repo). Plain SOURCE anchors (`/* src: ... */`) and inherited-comment
markers are the provenance C2 keeps and are explicitly allowed (they match no denylist
term). It shares the denylist with the product-README check and is seeded red->green per
arm, like every detector.

## Consumer verification (C10)

For a private or owned port, *chisel-invisible* (anchors kept, per C2) is sufficient: a
consumer sees a normal codebase that happens to cite its SOURCE origin. Only if
downstream consumers must independently verify fidelity do we publish a **neutral**
release artifact (e.g. a `FIDELITY.json` or a release-note link to the workbench
evidence) that exposes no process jargon. Default: chisel-invisible, no extra artifact.

## Migration of a pre-existing single-repo instance (C11)

Splitting a pre-existing single-repo instance into the two-repo layout (the legacy case):

1. extract `target/` into a fresh product repo with a clean history;
2. emit a **mapping ledger** (old workbench commit/path -> new product
   commit/path/tree-hash) plus a one-time migration evidence pack proving the code
   bytes are preserved except intentional strip/relocate transforms (none, under the
   KEEP default);
3. link the two via `port/product.yaml`;
4. apply the C3 conventions move and the C8 layer-map change.

`tools/new-instance.sh` changes from "make one repo" to "make a workbench + a linked,
empty, clean product repo" with the chosen linkage. Existing instances migrate via this
procedure when they choose to; none are forced.

**These two actions - creating/pushing the product repo and migrating an instance - are
the only irreversible steps and are performed only on explicit human go-ahead.** Every
other part of this architecture is methodology design that lands on the branch first.

## Split execution checklist

When the human gives the go-ahead, the split is one coherent change. Do all of it, in
this order, in one ephemeral worktree (WS-D), and land it together:

1. **Create the product repo** and its first clean commit (the extracted `target/`
   tree, anchors kept); record the mapping ledger + migration evidence pack (C11).
2. **Link** the two: instantiate `port/product.yaml` from
   `assets/product.yaml.template` (`repo`, `checkout`, `default_branch`,
   `attested_commit`).
3. **Move the conventions** (C3): `git mv target/CONVENTIONS.md
   port/conventions/<source>-to-<target>.md`, and rewire every citation of
   `target/CONVENTIONS.md` -> the new path across the skills, commands, templates, and
   conformance scripts (`verify-anchors.sh` cites it). Extend
   `check-references.sh` to validate the `port/conventions/` path.
4. **Rewrite the layer map** (C8): remove `target/**` from `.gitattributes`; make
   `/port-sync-with-base` and `/port-contribute-to-base` never touch the product
   (WS-D's two-repo adjustment); confirm `tools/base-repo.txt` = methodology base and
   `port/product.yaml` = product linkage.
5. **Repoint the checks/proofs** (C6/C9): set `PRODUCT_ROOT` to the product checkout in
   CI; the chisel-invisibility check now scans the product, and its commit-subject arm
   activates; the two-root proof contract drives the product checkout.
6. **Update `tools/new-instance.sh`** (C11): from "make one repo" to "make a workbench +
   a linked, empty, clean product repo".
7. **Update the consumer-facing docs**: the workbench README gains the two-repo model;
   the product carries only its product README.
8. **Re-seed** every detector whose inputs changed (anchors path, invisibility against a
   real product), and run the full conformance suite green
   across both roots before landing.
