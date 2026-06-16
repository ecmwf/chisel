# SEEDED-BUG DEMONSTRATION - conformance/check-audit-manifest

- Date: 2026-06-15 (new detector, WS-E0; hardened after independent review)
- Detector: tools/conformance/check-audit-manifest.sh (wraps tools/coordination/check_manifest.py)
- Failure class targeted: an audit manifest that attests a product commit but whose
  evidence binding does not actually verify - the stale/forged-attestation gap (a gate or
  review that ran on a DIFFERENT tree), a swapped or out-of-workbench evidence file, a
  tier-R0 "gate", a failed gate, an unresolvable commit/pin, or a duplicate-key forge. The
  workbench owes the product a machine-checkable attestation; a plausible-looking manifest
  must not pass.
- Exit-code contract: 0 GREEN (every manifest verifies, or there are none), 1 RED (a
  binding violation), 2 UNRELIABLE (no python3 / PyYAML; product checkout missing, not its
  own git repo, or == the workbench).

The binding is RECOMPUTED, never self-attested: the checker resolves `product.commit`,
`gate.product_commit`, and `review.reviewed_commit` in the product repo and requires each
commit's tree to equal `product.tree_hash` (and the recorded `*_tree_hash` to match the
recomputed tree). There is no "equivalence proof" escape - identical content has an
identical git tree hash, so equivalence IS tree-hash identity. Manifests load with a
duplicate-key-rejecting loader; hashes/shas compare as strings (an all-digit hash coerced
to an int cannot pass). Fixtures use a separate workbench git repo and product git repo
(`--workbench`, `--product-root`); the default scans `port/manifests/*.yaml` with the
product checkout from `port/product.yaml`.

## Per-arm red proofs (each isolates one binding)

Against a fixture: a workbench git repo (evidence under it, a resolvable source/logic/
evidence commit) and a SEPARATE product git repo with an attested commit (tree A) and a
stale commit (tree B):

- **Stale gate (the core gap):** `gate.product_commit` = the stale commit -> RED:
  `gate ran on tree <B>, not the attested product tree <A>`.
- **Forged review:** `review.reviewed_commit` = the stale commit -> RED:
  `review ran on tree <B>, not the attested product tree <A>`. (The review must have seen
  the attested tree, recomputed - not a self-declared `reviewed_tree_hash`.)
- **Missing required commit:** no `gate.product_commit` -> RED:
  `missing required field 'gate.product_commit'` (it can no longer be optional).
- **Swapped / missing evidence sha:** a wrong or absent `review.evidence_sha256` -> RED
  (`sha256 mismatch`, or `missing required field`).
- **Evidence escapes the workbench:** `gate.evidence: /etc/hostname` (or a `../` / symlink
  path) -> RED: `is not a workbench-relative path under the workbench`.
- **Evidence swapped in the working tree AFTER the manifest (the commit-binding gap, I2):**
  the working-tree evidence is replaced AND `gate.evidence_sha256` is updated to match the
  new bytes, so the sha256 check still passes - but `evidence_commit` still holds the
  ORIGINAL -> RED: `gate.evidence differs from its version in evidence_commit <sha> (a
  working-tree edit after the manifest...)`. Hashing the mutable working tree alone would
  miss this; the binding is to the COMMITTED object (`git diff --quiet evidence_commit -- <path>`).
  Also RED: `evidence_commit <sha> is not an ancestor of HEAD` (the cited evidence is not on
  the committed history the manifest sits on).
- **Duplicate key:** a second `integration:` mapping -> RED: `not valid YAML (duplicate
  key 'integration')` (the strict loader refuses last-key-wins).
- **Missing schema field:** no `schema_version` -> RED: `missing required field
  'schema_version'` + `schema_version must be 1`.
- **R0 cannot gate / gate did not pass:** `gate.tier: R0` -> RED; `gate.exit_code: 1` -> RED.
- **Unresolvable pin:** a `source.pin` not in the workbench -> RED: `does not resolve in
  the workbench`.

## Green proof (defect removed)

- A manifest whose `product.commit`, `gate.product_commit`, and `review.reviewed_commit`
  all resolve in the product repo with the attested tree; whose gate (R1, exit 0) and
  review evidence are workbench-relative files under the workbench with matching sha256;
  whose `source.pin`/`gate.logic_commit`/`evidence_commit` resolve in the workbench; with
  the full schema and `integration.state: gated`: GREEN, exit 0 - `0 binding violation(s)`.
- The base repo (no `port/manifests/`): GREEN, exit 0 (skip) - no manifests exist until a
  deliverable is integrated (post-WS-C-split).

## Causal proof (the binding is recomputed, not trusted)

Each tree is recomputed with `git -C <product> rev-parse <commit>^{tree}` and each
evidence hash from the file/dir content; the manifest passes only if its recorded values
match what is recomputed and every commit's tree equals the attested product tree. So
"attested" means "the gate and review demonstrably ran on the exact attested tree," never
"the manifest says so." A prior version trusted a hashed empty-diff "proof" file and an
optional gate commit; an independent review showed both were forgeable, and they were
removed.

## Scope / non-defect signals confirmed

- No equivalence-proof escape: the reviewed tree must BE the attested tree (recomputed).
- Evidence paths are workbench-relative and confined to the workbench (no absolute path,
  `..`, or symlink escape); directory evidence is hashed deterministically and
  symlink-safe.
- The product checkout must be its own git repo and not the workbench (C6); otherwise
  UNRELIABLE (exit 2), kept distinct from RED.

## Comparison-logic version

The comparison logic is: require the full schema and `schema_version: 1`; recompute the
trees of `product.commit`/`gate.product_commit`/`review.reviewed_commit` and require each
equals `product.tree_hash` (string compare); require `gate.tier` R1+, `gate.exit_code` 0;
require each evidence path workbench-relative-and-contained, existing, with a matching
required sha256, AND identical to its version in `evidence_commit` (`git diff --quiet
evidence_commit -- <path>`, so a working-tree edit after the manifest cannot slip past the
sha256 check); require `source.pin`/`gate.logic_commit`/`evidence_commit` resolve in the
workbench and `evidence_commit` be an ancestor of HEAD; and `integration.state` in
{gated,integrated}. Load manifests with a duplicate-key-rejecting loader. Re-run this
demonstration after any change to these rules (standing seeded-bug rule).
