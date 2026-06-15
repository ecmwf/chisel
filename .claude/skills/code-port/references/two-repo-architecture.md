# The two-repo architecture: workbench and product

The port is kept in **two repositories**, so that the people who consume the ported
code never see the machinery that produced it, while every product commit remains
provably tied to its fidelity evidence.

- The **workbench** (the chisel instance): the methodology layer, `source/` at the
  pinned commit, `port/` state, `tools/`, the **porting conventions**, the
  reference-run definitions, all gate/review **evidence**, and the full porting
  history. This is where the work happens and where trust is established.
- The **product** (the target codebase): a clean, normal repository - product README,
  ordinary tooling config (formatter/linter/build/CI), and a history of only code
  commits. Chisel is invisible here.

The split is safe **only because the workbench is the attestation authority for exact
product commits**: every integrated product commit is bound, in the workbench, to the
evidence that it reproduces the SOURCE. Read this before executing the split, and
whenever touching linkage, manifests, gates, or migration.

> Status: this reference SPECIFIES the architecture and the decisions taken (the
> recommended v2 defaults). The two irreversible actions - creating the product repo
> and migrating an existing instance - are executed only on explicit human go-ahead
> (see Migration, last section).

## Linkage: a sibling clone (C1)

The product is its own repository. The workbench references it through a committed
`port/product.yaml` (template: `assets/product.yaml.template`):

- `repo` - the product repository URL;
- `checkout` - the local path where the workbench expects the product working tree
  (a sibling directory by convention, e.g. `../<name>-product`);
- `default_branch` - the product's protected mainline (e.g. `main`);
- `attested_commit` - the latest product commit the workbench has attested (the head
  of the manifest chain below).

Not a submodule (it entangles the two histories and adds friction to every product
commit) and not a workbench worktree (a worktree shares one history, so it could not
give the product its own clean history). `tools/base-repo.txt` keeps pointing at the
**methodology base only**; it is never overloaded with the product pointer.

## Provenance anchors: KEEP (C2)

The default is unchanged from v1: every ported routine and nontrivial constant carries
an inline SOURCE anchor, and `tools/conformance/verify-anchors.sh` machine-checks each
against the pinned SOURCE. This survives the split:

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

The rendering conventions cannot live in a chisel-invisible product. At the split they
move from `target/CONVENTIONS.md` to `port/conventions/<source>-to-<target>.md` in the
workbench; only normal tooling files (`.clang-format`, build/CI config, lint config)
remain in the product. Every instruction that says "read `target/CONVENTIONS.md`"
updates to the new path **in the same change that performs the move** - this is a
mechanical rewiring whose surface is checked by `tools/conformance/check-references.sh`
(extended to the conventions path at split time). The move is executed with the split,
not before, so the live single-repo instructions stay coherent until then.

## Audit manifest: bind evidence to the FINAL product commit (C4)

Clean product history (C5) means the integrator lands a reviewed deliverable as one
**squashed** product commit; the evidence must bind to *that* commit, not to the
pre-squash branch (no stale evidence - the validation ladder's rule). One manifest per
integrated deliverable, kept in the workbench (template:
`assets/audit-manifest.template.yaml`), with fields:

- `product_repo`, `product_commit`, `product_tree_hash` - the exact attested product
  state;
- `reviewed_commit`, `tree_equivalence` - the reviewed commit and a proof that the
  reviewed tree equals the squashed product tree;
- `source_pin` - the pinned SOURCE commit the work was rendered against;
- `reference_run_id` + checksum - the canonical reference run used;
- `gate_logic_commit` - the workbench commit whose gate scripts produced the result
  (so a later gate change cannot retroactively bless old code);
- `gate_evidence`, `review_evidence` - paths to the gate logs and the review report;
- `integration.state` - `gated` / `integrated`;
- `epoch_certificate` - the integration-epoch certificate, where applicable;
- `workbench_evidence_commit` - the workbench commit that holds all of the above.

The manifests form a chain; `port/product.yaml`'s `attested_commit` is the head.

## Clean product history (C5)

The product receives only code commits (conventional `feat`/`fix` per coherent
deliverable). The messy per-piece history, the TRACE matrix, the reviews, and the gate
logs stay in the workbench. Done when the product's `git log` reads like a normal
project's, with no chisel terms.

## Two-root gate invocation (C6)

SOURCE stays in the workbench; gates and epochs run **from the workbench against the
product checkout**. The contract is five environment variables, so any gate/conformance
script can be pointed at either a single repo (today) or two roots (after the split):

- `WORKBENCH_ROOT` - the workbench working tree (defaults to the repo root);
- `PRODUCT_ROOT` - the product working tree (defaults to `WORKBENCH_ROOT`, i.e. the
  single-repo case, so nothing breaks before the split);
- `SOURCE_PIN_REF` - the pinned SOURCE ref (already honored by `verify-anchors.sh`);
- `SOURCE_SUBDIR` - where SOURCE lives under the workbench (default `source/`);
- `REFERENCE_RUN_ID` - the canonical reference run for acceptance.

Product CI builds and tests the code normally. The fidelity gates, conformance checks,
and epoch verification run in workbench (or integrator-run) CI against product commits.

## Cross-repo trust boundary (C7)

Product `main` is **protected**: only integrator / merge-queue commits are
fidelity-certified, and workbench CI refuses when the configured product HEAD differs
from the latest attested manifest. Product PRs may NOT alter the workbench's gates,
SOURCE, tolerances, conventions, or evidence - those protected surfaces live in the
workbench, out of a product contributor's reach. A product contributor can change code;
only the workbench can attest it.

## Two-layer model rewrite (C8)

Today `target/**` is a workbench project-layer path (`merge=ours`) and
`/port-sync-with-base` restores `target/` from the pre-merge HEAD. After the split the
product code is not a workbench directory at all:

- remove `target/**` from the `.gitattributes` layer map;
- make sync/contribute never touch the product (WS-D's two-repo adjustment);
- `tools/base-repo.txt` = methodology base; `port/product.yaml` = product linkage.

This `.gitattributes` change is executed WITH the split (when `target/` actually leaves
the workbench), not before, so the layer model stays correct in the single-repo phase.

## Chisel-invisibility check (C9)

A workbench conformance check (`tools/conformance/check-product-invisibility.sh`)
asserts the product tree carries no methodology leakage: no `port/`, no porting
`AGENTS.md`/`CLAUDE.md`, and no chisel vocabulary in code, comments, or commit subjects -
beyond whatever C2 keeps as plain SOURCE anchors (`/* src: ... */`, which are explicitly
allowed). It reuses the product-README denylist vocabulary and extends it tree-wide. It
is seeded red->green like every detector.

## Consumer verification (C10)

For a private or owned port, *chisel-invisible* (anchors kept, per C2) is sufficient: a
consumer sees a normal codebase that happens to cite its SOURCE origin. Only if
downstream consumers must independently verify fidelity do we publish a **neutral**
release artifact (e.g. a `FIDELITY.json` or a release-note link to the workbench
manifest) that exposes no process jargon. Default: chisel-invisible, no extra artifact.

## Migration + commit-equivalence ledger (C11) - executed on human go-ahead

Splitting an existing single-repo instance (the **warmup is the migration test case**):

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
