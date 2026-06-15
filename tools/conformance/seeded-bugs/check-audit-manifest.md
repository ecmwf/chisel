# SEEDED-BUG DEMONSTRATION - conformance/check-audit-manifest

- Date: 2026-06-15 (new detector, WS-E0; the WS-C attestation-binding verifier)
- Detector: tools/conformance/check-audit-manifest.sh (wraps tools/coordination/check_manifest.py)
- Failure class targeted: an audit manifest that attests a product commit but whose
  evidence binding does not actually verify - the stale-evidence gap (a gate/review log
  produced against a DIFFERENT tree), a swapped evidence file, a tier-R0 "gate", a failed
  gate, or an unresolvable commit/pin. The workbench owes the product a machine-checkable
  attestation; a manifest that merely looks plausible must not pass.
- Exit-code contract: 0 GREEN (every manifest verifies, or there are none), 1 RED (a
  binding violation), 2 UNRELIABLE (no python3 / PyYAML / product checkout / not a git repo).

The checker recomputes the binding against the product repo (tree hashes) and the
workbench (evidence files, source pin). Hashes/shas are compared as STRINGS and the
evidence sha is REQUIRED, so an all-digit hash coerced to an int cannot bypass a check.
Fixtures use `--manifest` / `--product-root`; the default scans `port/manifests/*.yaml`
with the product checkout from `port/product.yaml`.

## Per-arm red proofs (each isolates one binding)

Against a fixture product git repo (real commit + tree hash), evidence files (known
sha256), and a resolvable source pin:

- **Stale-evidence gap:** `gate.product_tree_hash` != `product.tree_hash` -> RED:
  `gate.product_tree_hash ... != product.tree_hash ... (gate ran on a different tree)`.
  This is the core gap the manifest exists to close.
- **Swapped evidence:** `review.evidence_sha256` set to a different hash -> RED:
  `review.evidence sha256 mismatch (recorded ..., actual ...)`.
- **Missing evidence binding:** `review.evidence_sha256` empty/absent -> RED:
  `review.evidence_sha256 is required for the evidence binding` (it cannot be skipped).
- **R0 cannot gate:** `gate.tier: R0` -> RED: `gate.tier 'R0' must be R1 or higher`.
- **Gate did not pass:** `gate.exit_code: 1` -> RED: `gate.exit_code is 1, not 0`.
- **Unresolvable product commit:** a `product.commit` not in the product repo -> RED.
- **Unresolvable source pin:** a `source.pin` not in the workbench -> RED:
  `source.pin '...' does not resolve in the workbench`.

## Green proof (defect removed)

- A manifest whose product.commit's tree equals `product.tree_hash` and
  `gate.product_tree_hash` and `review.reviewed_tree_hash`; whose gate (R1, exit 0) and
  review evidence files exist with matching sha256; whose source pin resolves; with
  `reference_run.id` set and `integration.state: gated`: GREEN, exit 0 - `0 binding
  violation(s)`.
- The base repo (no `port/manifests/`): GREEN, exit 0 (skip) - no manifests exist until a
  deliverable is integrated (post-WS-C-split).

## Causal proof (the binding is recomputed, not trusted)

The product tree hash is recomputed with `git -C <product> rev-parse <commit>^{tree}` and
the evidence sha256 with the file/dir content; the manifest passes only if its recorded
values match what is recomputed. So "attested" means "the gate and review demonstrably
ran on the exact tree the manifest names," never "the manifest says so."

## Scope / non-defect signals confirmed

- Tree-hash/sha comparisons are string-based and the evidence sha is required, so an
  all-digit hash coerced by YAML to an int cannot silently bypass a binding (a false
  green this demonstration's hardening closed). The template instructs quoting hashes.
- `tree_equivalence: empty-diff-proof` is accepted when `reviewed_tree_hash` differs but
  the proof file exists and matches its `proof_sha256`.
- No product checkout while manifests exist is UNRELIABLE (exit 2), kept distinct from RED.

## Comparison-logic version

The comparison logic is: recompute product/gate tree hashes from the product repo and
compare (as strings) to `product.tree_hash`/`gate.product_tree_hash`/
`review.reviewed_tree_hash` (or an empty-diff-proof); recompute evidence sha256 (file or
deterministic dir hash) and require it match; require `gate.tier` R1+, `gate.exit_code`
0, a resolvable `source.pin`, a `reference_run.id`, and `integration.state` in
{gated,integrated}. Re-run this demonstration after any change to these rules (standing
seeded-bug rule).
