#!/usr/bin/env python3
"""Verify audit manifests: each binds a PRODUCT commit to the evidence that it reproduces
the SOURCE, and the binding must be machine-checkable, not prose.

Two-repo model (references/two-repo-architecture.md, C4): the integrator lands a reviewed
deliverable as one squashed PRODUCT commit and writes a manifest (port/manifests/<id>.yaml,
template assets/audit-manifest.template.yaml) in the WORKBENCH. This checker recomputes the
binding and refuses a manifest that cites evidence produced against a DIFFERENT tree - the
stale-evidence gap an independent review of WS-C flagged.

Per manifest it verifies:
  - product.commit resolves in the product repo and its tree hash == product.tree_hash;
  - gate.product_tree_hash == product.tree_hash (the gate ran on the ATTESTED tree), and
    gate.product_commit's tree == that hash; gate.tier is R1+; gate.exit_code == 0;
  - review.reviewed_tree_hash == product.tree_hash, or tree_equivalence is an
    empty-diff-proof whose file exists and matches its recorded sha256;
  - gate.evidence and review.evidence exist in the workbench and match their sha256;
  - source.pin resolves in the workbench; reference_run.id is set;
  - integration.state is gated|integrated.

Product repo: --product-root, else port/product.yaml `checkout`. Workbench: the repo root.

Usage:  check_manifest.py [--manifest FILE ...] [--product-root DIR]
Exit:   0 every manifest verifies (or there are none); 1 a binding violation; 2 UNRELIABLE.
"""
import argparse
import glob
import hashlib
import os
import subprocess
import sys


def _fail(msg):
    sys.stderr.write("check-audit-manifest: " + msg + "\n")
    sys.exit(2)


def _repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def _git_tree(repo, commit):
    """Tree hash of a commit in `repo`, or None if it does not resolve."""
    try:
        return subprocess.check_output(
            ["git", "-C", repo, "rev-parse", "--verify", "%s^{tree}" % commit],
            stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return None


def _git_resolves(repo, ref):
    try:
        subprocess.check_output(["git", "-C", repo, "rev-parse", "--verify", "%s^{commit}" % ref],
                                stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False


def _hash_path(path):
    """sha256 of a file, or a deterministic tree-hash of a directory; None if missing."""
    if os.path.isfile(path):
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    if os.path.isdir(path):
        agg = hashlib.sha256()
        for root, _dirs, files in os.walk(path):
            for name in sorted(files):
                fp = os.path.join(root, name)
                rel = os.path.relpath(fp, path)
                agg.update(rel.encode() + b"\0" + _hash_path(fp).encode() + b"\n")
        return agg.hexdigest()
    return None


def verify(manifest, mpath, product_root, workbench):
    """Return a list of human-readable binding violations for one manifest (empty == ok)."""
    v = []

    def need(cond, msg):
        if not cond:
            v.append(msg)

    product = manifest.get("product") or {}
    gate = manifest.get("gate") or {}
    review = manifest.get("review") or {}
    teq = manifest.get("tree_equivalence") or {}
    source = manifest.get("source") or {}
    refrun = manifest.get("reference_run") or {}
    integ = manifest.get("integration") or {}

    pcommit = product.get("commit")
    ptree = product.get("tree_hash")
    need(pcommit and ptree, "product.commit and product.tree_hash are required")
    if pcommit:
        actual = _git_tree(product_root, pcommit)
        need(actual is not None, "product.commit '%s' does not resolve in the product repo" % pcommit)
        if actual is not None:
            need(str(actual) == str(ptree),
                 "product.tree_hash %s != actual tree %s of product.commit" % (ptree, actual))

    # The stale-evidence gap closer: the gate ran on the ATTESTED tree. Compare as strings
    # (an all-digit hash is coerced to an int by YAML and must still compare faithfully).
    need(str(gate.get("product_tree_hash")) == str(ptree),
         "gate.product_tree_hash %s != product.tree_hash %s (gate ran on a different tree)"
         % (gate.get("product_tree_hash"), ptree))
    gcommit = gate.get("product_commit")
    if gcommit:
        gtree = _git_tree(product_root, gcommit)
        need(gtree is not None, "gate.product_commit '%s' does not resolve" % gcommit)
        if gtree is not None:
            need(str(gtree) == str(gate.get("product_tree_hash")),
                 "gate.product_commit's tree %s != gate.product_tree_hash %s" % (gtree, gate.get("product_tree_hash")))
    tier = str(gate.get("tier") or "")
    need(tier[:1] == "R" and tier[1:2].isdigit() and tier[1:] != "0" and int(tier[1:] or 0) >= 1,
         "gate.tier '%s' must be R1 or higher (R0 can never gate)" % tier)
    need(gate.get("exit_code") == 0, "gate.exit_code is %r, not 0 (the gate did not pass)" % gate.get("exit_code"))

    # Review tree equivalence to the attested tree.
    method = teq.get("method")
    if str(review.get("reviewed_tree_hash")) == str(ptree):
        pass
    elif method == "empty-diff-proof":
        proof = teq.get("proof_path")
        need(proof and os.path.exists(os.path.join(workbench, proof)),
             "tree_equivalence empty-diff-proof file is missing: %s" % proof)
        if proof and os.path.exists(os.path.join(workbench, proof)):
            need(str(_hash_path(os.path.join(workbench, proof))) == str(teq.get("proof_sha256")),
                 "tree_equivalence proof_sha256 does not match %s" % proof)
    else:
        v.append("review.reviewed_tree_hash %s != product.tree_hash %s and no empty-diff-proof"
                 % (review.get("reviewed_tree_hash"), ptree))

    # Evidence exists in the workbench and matches its recorded sha256. The sha is
    # REQUIRED (a missing/zero sha would otherwise skip the content binding), and compared
    # as a string (YAML coerces an all-digit hash to an int, which must not bypass this).
    for label, ev, sha in (("gate.evidence", gate.get("evidence"), gate.get("evidence_sha256")),
                           ("review.evidence", review.get("evidence"), review.get("evidence_sha256"))):
        need(ev, "%s is required" % label)
        need(sha not in (None, ""), "%s_sha256 is required for the evidence binding" % label)
        if ev:
            actual = _hash_path(os.path.join(workbench, ev))
            need(actual is not None, "%s path does not exist: %s" % (label, ev))
            if actual is not None and sha not in (None, ""):
                need(str(actual) == str(sha),
                     "%s sha256 mismatch (recorded %s, actual %s)" % (label, sha, actual))

    need(source.get("pin") and _git_resolves(workbench, source["pin"]),
         "source.pin '%s' does not resolve in the workbench" % source.get("pin"))
    need(bool(refrun.get("id")), "reference_run.id is required")
    need(integ.get("state") in ("gated", "integrated"),
         "integration.state '%s' must be gated|integrated" % integ.get("state"))
    return v


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--manifest", action="append", default=None)
    ap.add_argument("--product-root", default=None)
    args = ap.parse_args()

    orig = os.getcwd()
    workbench = _repo_root()
    try:
        os.chdir(workbench)
    except OSError:
        _fail("cannot enter repo root '%s'" % workbench)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse manifests (install pyyaml)")

    if args.manifest:
        manifests = [m if os.path.isabs(m) else os.path.join(orig, m) for m in args.manifest]
    else:
        manifests = sorted(glob.glob(os.path.join("port", "manifests", "*.yaml")))

    if not manifests:
        print("check-audit-manifest: no manifests under port/manifests/ - nothing to check (skipping).")
        sys.exit(0)

    product_root = args.product_root
    if product_root is None:
        if os.path.isfile("port/product.yaml"):
            with open("port/product.yaml") as fh:
                product_root = (yaml.safe_load(fh) or {}).get("checkout")
        if not product_root:
            _fail("manifests exist but no product checkout (set --product-root or port/product.yaml checkout)")
    if not os.path.isabs(product_root):
        product_root = os.path.join(orig if args.product_root else workbench, product_root)
    if not os.path.isdir(product_root):
        _fail("product checkout '%s' is not a directory" % product_root)

    fails = 0
    for mpath in manifests:
        try:
            with open(mpath) as fh:
                manifest = yaml.safe_load(fh) or {}
        except yaml.YAMLError as exc:
            print("  [FAIL] %s: not valid YAML (%s)" % (mpath, exc))
            fails += 1
            continue
        for msg in verify(manifest, mpath, product_root, workbench):
            print("  [FAIL] %s: %s" % (os.path.basename(mpath), msg))
            fails += 1

    print("check-audit-manifest: checked %d manifest(s); %d binding violation(s)." % (len(manifests), fails))
    if fails:
        print("RESULT: RED (exit 1) - an audit manifest's evidence binding does not verify.")
        sys.exit(1)
    print("RESULT: GREEN (exit 0) - every audit manifest binds its product commit to verified evidence.")
    sys.exit(0)


if __name__ == "__main__":
    main()
