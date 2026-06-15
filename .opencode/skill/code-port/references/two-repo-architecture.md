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

The rendering conventions cannot live in a chisel-invisible product, so they live in the
workbench at `port/conventions/<source>-to-<target>.md`; only normal tooling files
(`.clang-format`, build/CI config, lint config) live with the product. Every instruction
reads that workbench path. `tools/conformance/check-references.sh` validates the cited
`references/` links and trap IDs; a dedicated stale-`target/CONVENTIONS.md` rule is a
possible future addition, not yet built.

## Audit manifest: bind evidence to the FINAL product commit (C4)

Clean product history (C5) means the integrator lands a reviewed deliverable as one
**squashed** product commit; the evidence must bind to *that* commit, not to the
pre-squash branch (no stale evidence - the validation ladder's rule). One manifest per
integrated deliverable, kept in the workbench (template:
`assets/audit-manifest.template.yaml`).

The binding must be **machine-checkable, not prose**: it is not enough to list a gate
log and a product commit side by side; the manifest must tie the gate and review
evidence to the *exact tree* they concern, by recomputable hash. So the schema records,
besides the product commit/tree and the source pin / reference run:

- `review.reviewed_commit` and `review.reviewed_tree_hash` - the checker recomputes the
  reviewed commit's tree and requires it equal `product.tree_hash`, so the review
  demonstrably saw the attested tree (identical content has an identical git tree hash, so
  equivalence IS tree-hash identity - there is no separate, forgeable "equivalence proof");
- `gate.product_tree_hash` (alongside `gate.product_commit`, `tier`, `command`,
  `exit_code`, `logic_commit`) - the tree the gates ACTUALLY ran against;
- `gate.evidence_sha256`, `review.evidence_sha256` - the cited logs are the ones that
  were produced, not later substitutes;
- `evidence_commit` - the workbench commit that already holds the cited evidence
  (committed *before* the manifest, so the field is not self-referential; the pointer
  from the product to its manifest is `port/product.yaml`'s `attested_commit`).

A manifest is valid only if the checker recomputes and confirms: the trees of
`product.commit`, `gate.product_commit`, and `review.reviewed_commit` (all resolved in the
product repo) each equal `product.tree_hash` (and match the recorded `*_tree_hash`
fields), so the gate and the review both ran on the exact attested tree; the gate tier is
R1+ and its exit code 0; the evidence files are workbench-relative, stay under the
workbench, exist, and match the recorded sha256; and `source.pin`, `gate.logic_commit`,
and `evidence_commit` resolve in the workbench. That
**manifest checker is built** - `tools/conformance/check-audit-manifest.sh` over
`tools/coordination/check_manifest.py`, seeded on fixtures and skipping until manifests
exist (they appear only once a deliverable is integrated, post-split). The manifests form
a chain; `port/product.yaml`'s `attested_commit` is the head.

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
- `PRODUCT_ROOT` - the **product tree** root (the TARGET code), consistently: before the
  split it is `$WORKBENCH_ROOT/target`, after the split it is the product checkout from
  `port/product.yaml`. It is never the workbench root - the workbench is methodology by
  design, so scanning it as "the product" would be meaningless. A script that needs the
  product's repo root separately uses `PRODUCT_REPO_ROOT`; do not overload one variable
  with two meanings;
- `SOURCE_PIN_REF` - the pinned SOURCE ref (already honored by `verify-anchors.sh`);
- `SOURCE_SUBDIR` - where SOURCE lives under the workbench (default `source/`);
- `REFERENCE_RUN_ID` - the canonical reference run for acceptance.

Product CI builds and tests the code normally. The fidelity gates, conformance checks,
and epoch verification run in workbench (or integrator-run) CI against product commits.

## Cross-repo trust boundary (C7)

Product `main` is **protected**: only integrator / merge-queue commits are
fidelity-certified, and workbench CI is to refuse when the configured product HEAD differs
from the latest attested manifest (the attestation-head check binding port/product.yaml's
`attested_commit` to the manifest chain is a Phase-1 deliverable, not yet enforced). Product PRs may NOT alter the workbench's gates,
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
manifest) that exposes no process jargon. Default: chisel-invisible, no extra artifact.

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
5. **Repoint the checks/gates** (C6/C9): set `PRODUCT_ROOT` to the product checkout in
   CI; the chisel-invisibility check now scans the product, and its commit-subject arm
   activates; the two-root gate contract drives the product checkout.
6. **Update `tools/new-instance.sh`** (C11): from "make one repo" to "make a workbench +
   a linked, empty, clean product repo".
7. **Update the consumer-facing docs**: the workbench README gains the two-repo model;
   the product carries only its product README.
8. **Re-seed** every detector whose inputs changed (anchors path, invisibility against a
   real product, the new manifest checker), and run the full conformance suite green
   across both roots before landing.
