<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# The two-repo architecture: workbench and product

The port is kept in **two repositories**, so the people who consume the ported code never see the
machinery that produced it, while every product commit stays tied to its fidelity evidence.

- The **workbench** (the chisel instance): the methodology layer, `source/` at the pinned commit,
  `port/` state, `tools/`, the porting conventions, the reference-run definitions, all proof and
  review evidence, and the full porting history. The work happens and trust is established here.
- The **product** (the target codebase): a clean, normal repository - its README, ordinary tooling
  configuration (formatter, linter, build, CI), its own test suite (`tests/`: the unit drivers and
  the captured vectors they replay), the run assets a consumer needs (example inputs, sample data,
  runtime configs; "Product run assets" below), and a history of code commits only. Chisel is
  invisible there. The product is done not when it compiles but when a fresh clone builds **and
  runs** from what it contains.

The split is safe only because the workbench is the attestation authority for exact product
commits: every integrated product commit is tied, in the workbench, to the evidence that it
reproduces the SOURCE. `chisel-init` creates both (`tools/new-product.sh` makes the product).
Read this before the first land, and whenever touching linkage, proofs or the product's history.

## Linkage: a sibling clone (C1)

The workbench references the product through a committed `port/product.yaml`, written by
`tools/new-product.sh`:

- `repo` - the product repository URL;
- `checkout` - where the workbench expects the product working tree (a sibling directory by
  convention, such as `../<name>-product`);
- `default_branch` - the product's protected mainline (such as `main`);
- `attested_commit` - the latest product commit the workbench has attested.

Not a submodule (it entangles the two histories) and not a workbench worktree (a worktree shares one
history, so the product could not have its own). `tools/base-repo.txt` points at the methodology base
only, never at the product.

## Provenance anchors: optional (C2)

`tools/conformance/verify-anchors.sh` binds every comparable TARGET constant to its SOURCE constant
by name - or by an anchor where a name cannot be matched - and compares the two by value against the
pinned SOURCE. Anchors are hints: one names the SOURCE file (and the module or the literal), never a
line number, which goes stale. The product keeps the anchors it has but no chisel branding: it reads
as code that cites its origin, which already satisfies chisel-invisibility. Stripping the anchors at
release leaves unchecked only the constants whose names cannot be matched; pair those in
`port/conventions/anchors.yaml` (`names`) first.

## Porting conventions live in the workbench (C3)

The rendering conventions cannot live in a chisel-invisible product, so they are at
`port/conventions/<source>-to-<target>.md` in the workbench. Only normal tooling files (formatter,
build, CI and lint configuration) live with the product. `check-references.sh` validates the cited
reference paths and trap IDs.

## Land only the reviewed commit (C4)

The independent review must have seen the exact tree that ships. The proof runs on one product
commit, recorded as the fragment's `proof.commit`, and the review is done on that same commit.
`integrate_product.sh` and `integrate_assembly.sh` refuse unless the `work/<id>` tip IS
`proof.commit`, so a commit added after the proof and review cannot ride in; they then squash it
onto the mainline (C5) and re-run the full conformance suite on the merge result, rolling back on
red. A rebase that moves the tip owes a re-prove, and a fresh review only when
`review_revalidate.sh` finds the piece's own target files changed. `check-trace-evidence` checks
that a proven unit has an R1+ proof with its commit and a clean review report; it does not tie the
review to a commit. `finalize.sh` seals on the same state: hand-driven, HEAD must be the commit that
recorded the `SIGNOFF.md`; with `--auto`, the full suite must be green at HEAD. The fragment's
`product.main_commit` records the squash commit; `workbench_manifest` is optional and unchecked.

## Clean product history (C5)

The product receives only code commits, one conventional `feat` or `fix` per deliverable. The
per-piece history, TRACE, the reviews and the proof logs stay in the workbench.
`integrate_product.sh <id>` enforces this: it squash-merges each reviewed piece as one commit, after
two-root conformance at HEAD, stale-base rejection and the proven-commit check, and rolls back on a
red merge result before it pushes. Done when the product's `git log` reads like any project's, with
no chisel terms.

## The bring-up preview branch

The mainline receives only R1-proven pieces, so early in a port it stays empty and you cannot see
the target take shape. That is a visibility gap, not a reason to weaken the mainline's guard. The
**`bring-up` branch** fills it: `integrate_bringup.sh <id>` squash-lands a piece's `work/<id>` onto
`bring-up` without requiring `proven` (no R1, no planner readiness), but with the full conformance
suite green at HEAD and on the merge result, and a rollback on red. So `bring-up` is buildable code in
progress, not certified faithful: check it out and build the target so far. A piece graduates to the
mainline unchanged once it is R1-proven (`integrate_product.sh`); `bring-up` is never the shipped
line, and C5 is untouched. Keep it current: Ptah-Orchestrator lands each wave's independently
reviewed pieces there as it goes (under autodrive this is part of driving), so the product repo
visibly fills up and stays buildable. This matters most for an assembly, where nothing reaches the
mainline until the whole closure is proven.

During an assembly bring-up, base new workers on it: `provision_worker.sh add <id> --product-base
bring-up`. A worker branched from the empty mainline cannot compile against the skeleton and the
reviewed peers it depends on; branched from `bring-up`, its product branch carries the accumulating
closure, which the assembly land later composes by merging member branches.

## Product run assets

A runnable product needs more than ported code and per-module fixtures: the example inputs, sample
data, runtime configs and a finished README a consumer needs to run and self-test it. These have no
SOURCE file, so they are not pieces: the planner never recommends them and the code lands never carry
them. Their land is `integrate_assets.sh <branch>`, conformance-checked like the code land (two-root
suite green at HEAD and on the merge result, rollback on red, then it pushes).

- **The safety boundary:** it refuses any TARGET source or build file (source files of any language,
  build-system files). Those decide numerical behavior and land only through `integrate_product.sh`
  or `integrate_assembly.sh`, under review.
- **What rides which path:** a module's own `tests/fixtures/` vectors ride its proven code piece
  (they are its proof's oracle); standalone run assets and the README land through
  `integrate_assets.sh`. The product is ready for handover only when these are present and pushed,
  so a fresh clone builds and runs.

### Assembly-proven deliverables land as ONE reviewed tree (no manifest)

`integrate_product.sh <id>` assumes each piece is independently composable and independently proven.
Some deliverables are not: their **proof is assembly-level** (one differential links several
modules, and no single module passes alone), and their work branches are **full-closure trees** that
each carry the whole dependency closure and define the same build target. Landing such a deliverable
member by member fails: the first land stales the rest, the build files collide, and an intermediate
mainline cannot pass the assembly proof (failure mode B7).

Treat the deliverable as one **assembly piece**:

- a `work/<assembly-id>` branch carrying the **assembled tree**: the proven members' whole reviewed
  product trees plus the build glue that wires them, which is product code under review, never
  unreviewed integrator glue. **Compose by merging the member branches wholesale, never by copying
  chosen directories.** Each member ships its `tests/` drivers and fixtures as well as its sources;
  copying only the sources and the build files drops those tests, and the land faithfully ships the
  loss. (`check-product-tests.sh` catches a test source that is not wired into the build; the
  integration review owns the rest.)
- a proven fragment `port/status/<assembly-id>.yaml` recording the **assembly-level proof** and one
  **integration-level review** that walks the assembled commit itself (the assembly's
  `proof.commit`), build glue included (and subject to the no-process-meta rule for comments and
  commit subjects). A per-module review covers the module's tree, never the assembled one. The
  integration review also catches a spurious extractor edge, not just a missing one, and owns "the
  clone is self-testing": the assembled product builds its tests, and a fresh clone's test command
  runs a test for every member. A member whose tests did not survive composition is sent back.

Land it with `integrate_assembly.sh <assembly-id> --members "<id> ..."`. In a freshly generated TRACE
it requires the assembly `proven` and every member either `proven` or validated transitively (below);
it refuses unless the branch tip is the assembly's `proof.commit`, runs two-root conformance at HEAD
and on the merge result with an armed rollback, squash-merges the assembled branch as one commit, and
pushes. Then record `integrated` on the assembly and every member.

**Assembly-proven acceptance (when the proof is inherently whole-program).** Some members compute
nothing meaningful alone, so a per-member R1 twin cannot be built for them; their numerical
correctness is proven by the assembly's whole-program differential. The rule:
- **The assembly** carries the strict proof: an R1+ whole-program differential against the
  reference and one independent integration-level review of the assembled commit. It is the `proven`
  unit.
- **A member** is accepted if it is `proven` in its own right (when an R1 twin can be built for it,
  that is required: transitive is never a shortcut), or if it is a **transitive** member: its
  fragment carries `proof.validation: transitive` (R0 is its last tier on its own; it is never
  `proven`), the assembly differential actually exercises it, and it still has its own independent,
  clean faithfulness review on disk that clears the same bar as a proven member's: `reviewer_id` set
  and different from `author_id`, `reviewer_session` not in a non-empty `author_sessions`,
  `review.evidence` tracked by git, and an explicit `clean` verdict. The transitive path replaces only
  the impossible per-member differential, never the review controls (B1, B2, B3).
- `integrate_assembly.sh` enforces exactly this. A transitive member's honest record reads: reviewed
  for faithfulness on its own, validated numerically as part of assembly `<id>`.

**Declare the assembly so the completeness check accepts it.** An assembly has no single SOURCE unit,
so its TRACE row would fail `check-completeness.sh`, and `integrate_assembly.sh` refuses on that red.
Declare it, before landing, in `tools/scoping/assemblies.yaml` (project layer; template
`assets/assemblies.template.yaml`), with members matching `--members`. `check_completeness.py`
accepts the row only when the assembly is declared and every member is a real dependency-map node, so
SOURCE units still cannot vanish and an assembly cannot smuggle in a phantom unit.

## Two-root proof invocation (C6)

The SOURCE stays in the workbench; proofs and epochs run **from the workbench against the product
checkout**. Four environment variables let any proof or conformance script work with one repo or
two:

- `WORKBENCH_ROOT` - the workbench working tree (defaults to the repo root);
- `PRODUCT_ROOT` - the product tree (the TARGET code): the product checkout from
  `port/product.yaml`, or `$WORKBENCH_ROOT/target` when no product is wired. It is never the
  workbench root;
- `SOURCE_PIN_REF` - the pinned SOURCE commit (default: TRACE `source_commit`, the local import);
- `SOURCE_SUBDIR` - where the SOURCE lives in the workbench (default: TRACE `source_root`).

Product CI builds and tests the code normally, since the test suite is product-owned; the fixture
generator that instruments the SOURCE stays in the workbench (`tools/diff/`). The fidelity proofs,
conformance checks and epochs run in workbench CI against product commits. For workbench CI to check
out a private product, give it a read-only token as the Actions secret `PRODUCT_RO_TOKEN`; without
it the product checks fail closed (UNRELIABLE), never pass silently.

Locally, the sibling product checkout is a directory outside the workbench. opencode 2 lets agents
read and edit such directories without asking, so a hands-off run never stalls on a prompt for the
product or for scratch space.

## Cross-repo trust boundary (C7)

Product `main` is protected: only lands through the guarded scripts are fidelity-certified. Product
changes cannot alter the workbench's proofs, SOURCE, tolerances, conventions or evidence, which live
out of a product contributor's reach: a product contributor can change code, and only the workbench
can attest it. A workbench check that refuses when the product HEAD differs from `attested_commit`
is not built yet.

## Two-layer model (C8)

The product code is not a workbench directory: `.gitattributes` has no rule for it,
`/port-sync-with-base` and `/port-contribute-to-base` never touch the product,
`tools/base-repo.txt` points at the methodology base, and `port/product.yaml` records the product
linkage.

## Chisel-invisibility check (C9)

`tools/conformance/check-product-invisibility.sh` asserts the product carries no methodology
leakage: no methodology structure at any depth (a `port/` directory, `.claude` or `.opencode`,
`AGENTS.md` or `CLAUDE.md`, dangling symlinks included); no chisel vocabulary in file contents
(case-insensitive, from `chisel-vocabulary.txt`, shared with the product README check); and none in
the product's commit subjects. Plain SOURCE anchors and inherited-comment markers are the provenance
C2 keeps and match no listed term. Each arm has a seeded red-then-green record.

## Consumer verification (C10)

For a private or owned port, chisel-invisible is enough: consumers see a normal codebase. Only if
downstream consumers must verify fidelity themselves does the port publish a neutral release
artifact (such as a `FIDELITY.json`, or a release note linking the workbench evidence) with no
process jargon.

## A single-repo instance

An instance that keeps the TARGET in a workbench `target/` directory still works: with no
`port/product.yaml`, `PRODUCT_ROOT` is `target/` and the product-facing checks scan it. Splitting it
is a one-time, human-approved change, since creating and pushing a repo is irreversible: extract
`target/` into a fresh product repo with clean history and anchors kept, record a mapping from old
workbench paths to new product commits with evidence that the bytes are unchanged, link the two with
`port/product.yaml`, move the conventions to `port/conventions/`, drop `target/` from the layer map,
point `PRODUCT_ROOT` at the product in CI, re-seed every detector whose inputs moved, and land it all
together with the full suite green across both roots.
