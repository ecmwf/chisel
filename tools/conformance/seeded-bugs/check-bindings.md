# SEEDED-BUG DEMONSTRATION - conformance/check-bindings

- Date: 2026-06-17 (new detector: the cross-artifact binding gate)
- Detector: tools/conformance/check-bindings.sh (wraps tools/coordination/check_bindings.py)
- Failure class targeted: every OTHER coordination check validates one artifact in isolation -
  a fragment, a claim ref, a manifest, the dependency map - but the trust claim lives in the
  JOINS between them. A fragment can self-report a claim block naming a different claimant than
  the real ref; an `integrated` fragment can point at a manifest that attests a different commit
  or evidence; the product mainline can advance past the commit the workbench attested. No
  single-artifact check sees any of that. This gate recomputes the joins and fails closed.
- Exit-code contract: 0 GREEN (every binding holds, or nothing is wired yet), 1 RED (a binding
  does not hold), 2 UNRELIABLE (no python3/PyYAML/git, product wired but absent, malformed input).

The five binding families (all loaded with a duplicate-key-rejecting loader; claims read from
refs/claims/* by default or a --claims-dir fixture; the product is its own repo via
port/product.yaml `checkout` or --product-root):

- **FILENAME** - `port/status/<id>.yaml` must have `id == <id>` (the basename is the work-item id).
- **CLAIM** - a fragment with a claim block binds to the real `refs/claims/<id>`: ref name,
  existence, and claimant all match; a fragment citing a claim while the namespace is absent is RED.
- **MANIFEST** - an `integration.state: integrated` fragment binds to `port/manifests/<id>.yaml`
  whose `deliverable`, `product.commit`, `gate.product_commit`, `gate.evidence`, and
  `review.evidence` all equal the fragment's, and whose `integration.state` is `integrated`.
- **PRODUCT** - each manifest's `product.repo` equals `port/product.yaml` `repo`.
- **ATTESTED** - the product `default_branch` tip is exactly `attested_commit` (no unattested
  commit ahead); `attested_commit` IS some integrated manifest's `product.commit`; and every
  integrated manifest's `product.commit` is reachable from it (the attested head caps the chain).

## Per-arm red proofs (against the end-to-end scenario, each restored before the next)

The scenario (a miniature two-repo parallel port: grid_mod owned+gated, io_mod leaf
gated+integrated with a manifest, util ready-to-claim) is internally consistent, so the gate is
GREEN on it. Each defect is injected, caught, and reverted:

- **FILENAME:** `port/status/util.yaml` with `id: wrongid` -> RED: `fragment id 'wrongid' does
  not match its filename 'util.yaml'`. (Every other binding keys on the id, so a wrong filename
  is caught first and stops the rest from running on a poisoned key.)
- **CLAIM - claimant mismatch:** the io_mod fragment's `claim.claimant` changed to `mallory`
  while `refs/claims/io_mod` still says `alice` -> RED: `fragment claimant 'mallory' != claim ref
  claimant 'alice'`.
- **CLAIM - namespace absent:** run with `--claims-dir` pointing at an empty directory while the
  fragments still cite claims -> RED: `fragment cites a claim but the claim namespace is absent
  (did CI fetch refs/claims/*?)`. This is the CI-checkout-forgot-the-refs failure: a fragment's
  self-reported claim is never trusted when the canonical refs are not present.
- **MANIFEST - evidence mismatch:** the io_mod manifest's `gate.evidence` repointed to a
  different path than the fragment's -> RED: `gate evidence differs - fragment '...' vs manifest
  '...'`. (The same arm covers `deliverable`, `product.commit`, `gate.product_commit`, and
  `review.evidence` divergence.)
- **PRODUCT - repo mismatch:** the io_mod manifest's `product.repo` changed to `file:///wrong`
  -> RED: `product.repo '...' != port/product.yaml repo '...'`.
- **ATTESTED - mainline ahead:** an unattested commit added to the product repo's `main` after
  the attested commit -> RED: `main is at <sha>, ahead of the attested_commit <sha> (unattested
  commits on the mainline)`. This is the product-advanced-past-attestation failure: a deliverable
  could be slipped onto the product mainline without a manifest and the workbench would never know.

## Green proof (defects removed)

- The consistent scenario: GREEN, exit 0 - `fragments, claims, manifests, and the product
  mainline agree.` (3 fragments, 2 claims, 1 manifest.) After every defect above is reverted, the
  gate returns to GREEN.
- The base repo (no port/status, no claims, no manifests, no port/product.yaml): GREEN, exit 0 -
  `no coordination artifacts wired yet - nothing to check (skipping).`
- A fragment whose claim block is entirely null (an unmapped, unclaimed leaf like util) is not
  required to bind to any claim; a `gated`-not-`integrated` fragment (grid_mod) is not required to
  bind to a manifest. Only the states that ASSERT a binding are held to it.

## Scope / non-defect signals confirmed

- This gate does NOT recompute tree hashes or evidence sha256 (that is check-audit-manifest's job)
  - it checks that the fragment and the manifest AGREE on which commits and evidence they name, and
  that the product mainline matches the attestation. The two gates compose: check-audit-manifest
  proves the manifest's evidence binding is real; check-bindings proves the fragment and product
  point at that same manifest and commit.
- Fail-closed UNRELIABLE (exit 2), distinct from RED: PyYAML/git absent, port/product.yaml wired
  with a real attested_commit but the product checkout missing or not a git repo, or
  port/product.yaml not valid YAML. A product checkout that resolves to the workbench itself is
  rejected (the product must be its own repository).

## Comparison-logic version

The logic is: load fragments (port/status/*.yaml except _meta.yaml), claims (refs/claims/* or
--claims-dir), manifests (port/manifests/*.yaml), and port/product.yaml; then enforce FILENAME
(id==basename), CLAIM (ref==refs/claims/<id>, claim exists with matching claimant, namespace
present when cited), MANIFEST (integrated fragment's deliverable/product.commit/gate.product_commit/
gate.evidence/review.evidence/integration.state all equal the named port/manifests/<id>.yaml),
PRODUCT (manifest.product.repo == product.yaml.repo), and ATTESTED (default_branch tip ==
attested_commit == an integrated manifest's product.commit, with every integrated manifest commit
reachable from it). Re-run this demonstration after any change to those join rules (standing
seeded-bug rule): every arm above must go RED and the consistent scenario stay GREEN.
