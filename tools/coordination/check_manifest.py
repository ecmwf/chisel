#!/usr/bin/env python3
"""Verify audit manifests: each binds a PRODUCT commit to the evidence that it reproduces
the SOURCE, and the binding is RECOMPUTED, never trusted from the manifest's own words.

Two-repo model (references/two-repo-architecture.md, C4): the integrator lands a reviewed
deliverable as one squashed PRODUCT commit and writes a manifest (port/manifests/<id>.yaml,
template assets/audit-manifest.template.yaml) in the WORKBENCH. This checker refuses a
manifest that cites evidence produced against a DIFFERENT tree, or whose commits/paths do
not resolve - the stale/forged-attestation gap an independent review flagged.

Per manifest it RECOMPUTES and confirms:
  - product.commit, gate.product_commit, and review.reviewed_commit all resolve in the
    product repo and their trees all equal product.tree_hash (and the recorded
    *_tree_hash fields match the recomputed trees) - so the gate and the review both ran
    on the exact attested tree; there is no "equivalence proof" escape (identical content
    has an identical git tree hash, so equivalence IS tree-hash identity);
  - gate.tier is R1+, gate.exit_code is 0;
  - gate.evidence and review.evidence are workbench-relative paths that stay UNDER the
    workbench (no absolute path, no `..`, no symlink escape), exist, and match their
    required sha256 (compared as strings; an all-digit hash coerced to an int cannot pass);
  - source.pin, gate.logic_commit, and evidence_commit resolve in the workbench;
  - schema_version is 1; the required schema fields are present; integration.state is
    gated|integrated.

Manifests are loaded with a duplicate-key-REJECTING loader. The product repo is its own
repository (not the workbench): --product-root, else port/product.yaml `checkout`.

Usage:  check_manifest.py [--manifest FILE ...] [--product-root DIR] [--workbench DIR]
Exit:   0 every manifest verifies (or there are none); 1 a binding violation; 2 UNRELIABLE.
"""
import argparse
import glob
import hashlib
import os
import subprocess
import sys

REQUIRED = [
    "schema_version", "deliverable",
    "product.repo", "product.commit", "product.tree_hash",
    "review.reviewed_commit", "review.reviewed_tree_hash", "review.evidence", "review.evidence_sha256",
    "gate.product_commit", "gate.product_tree_hash", "gate.tier", "gate.command",
    "gate.exit_code", "gate.logic_commit", "gate.evidence", "gate.evidence_sha256",
    "source.pin", "source.subdir",
    "reference_run.id", "reference_run.checksum",
    "integration.state", "evidence_commit",
]


def _fail(msg):
    sys.stderr.write("check-audit-manifest: " + msg + "\n")
    sys.exit(2)


def _repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def _strict_loader(yaml):
    """A SafeLoader that REJECTS duplicate mapping keys (so a second `gate:` cannot quietly
    override a bad first one)."""
    class StrictLoader(yaml.SafeLoader):
        pass

    def no_dup(loader, node, deep=False):
        mapping = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node, deep=deep)
            if key in mapping:
                raise yaml.constructor.ConstructorError(
                    None, None, "duplicate key %r" % (key,), key_node.start_mark)
            mapping[key] = loader.construct_object(value_node, deep=deep)
        return mapping

    StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_dup)
    return StrictLoader


def _git_tree(repo, commit):
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


def _under(workbench, rel):
    """Resolve a workbench-relative path and return it only if it stays under the
    workbench (rejecting absolute paths, `..`, and symlink escapes); else None."""
    if not rel or os.path.isabs(rel):
        return None
    wb = os.path.realpath(workbench)
    full = os.path.realpath(os.path.join(wb, rel))
    if full == wb or full.startswith(wb + os.sep):
        return full
    return None


def _hash_path(path):
    """sha256 of a file, or a deterministic, symlink-safe tree-hash of a directory; None
    if missing or if a symlink is encountered (symlinks are not valid evidence)."""
    if os.path.islink(path):
        return None
    if os.path.isfile(path):
        h = hashlib.sha256()
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    if os.path.isdir(path):
        agg = hashlib.sha256()
        for root, dirs, files in os.walk(path, followlinks=False):
            dirs.sort()
            for name in sorted(files):
                fp = os.path.join(root, name)
                if os.path.islink(fp):
                    return None
                sub = _hash_path(fp)
                if sub is None:
                    return None
                agg.update(os.path.relpath(fp, path).encode() + b"\0" + sub.encode() + b"\n")
        return agg.hexdigest()
    return None


def _get(d, dotted):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur


def verify(manifest, product_root, workbench):
    """Return a list of human-readable binding violations for one manifest (empty == ok)."""
    v = []

    def need(cond, msg):
        if not cond:
            v.append(msg)

    for field in REQUIRED:
        val = _get(manifest, field)
        need(val is not None and val != "", "missing required field '%s'" % field)
    need(manifest.get("schema_version") == 1, "schema_version must be 1")

    ptree = str(_get(manifest, "product.tree_hash"))

    # Every commit the manifest names must resolve in the product repo AND have the
    # ATTESTED tree - recomputed, not taken from the manifest's own *_tree_hash fields.
    for label, commit, recorded in (
            ("product", _get(manifest, "product.commit"), _get(manifest, "product.tree_hash")),
            ("gate", _get(manifest, "gate.product_commit"), _get(manifest, "gate.product_tree_hash")),
            ("review", _get(manifest, "review.reviewed_commit"), _get(manifest, "review.reviewed_tree_hash"))):
        if not commit:
            continue
        actual = _git_tree(product_root, commit)
        need(actual is not None, "%s commit '%s' does not resolve in the product repo" % (label, commit))
        if actual is not None:
            need(str(actual) == str(recorded),
                 "%s recorded tree_hash %s != actual tree %s of its commit" % (label, recorded, actual))
            need(str(actual) == ptree,
                 "%s ran on tree %s, not the attested product tree %s" % (label, actual, ptree))

    tier = str(_get(manifest, "gate.tier") or "")
    need(len(tier) >= 2 and tier[0] == "R" and tier[1:].isdigit() and int(tier[1:]) >= 1,
         "gate.tier '%s' must be R1 or higher (R0 can never gate)" % tier)
    need(_get(manifest, "gate.exit_code") == 0,
         "gate.exit_code is %r, not 0 (the gate did not pass)" % _get(manifest, "gate.exit_code"))

    # Evidence stays under the workbench, exists, matches its required sha256, AND is identical to
    # its version committed in evidence_commit. Hashing the working tree alone would let a
    # working-tree edit AFTER the manifest slip through (the manifest names a commit but the bytes
    # checked were the mutable file); the git diff binds the evidence to the committed object.
    ev_commit = _get(manifest, "evidence_commit")
    for label, ev, sha in (("gate.evidence", _get(manifest, "gate.evidence"), _get(manifest, "gate.evidence_sha256")),
                           ("review.evidence", _get(manifest, "review.evidence"), _get(manifest, "review.evidence_sha256"))):
        if not ev:
            continue
        full = _under(workbench, ev)
        need(full is not None, "%s '%s' is not a workbench-relative path under the workbench" % (label, ev))
        if full is not None:
            actual = _hash_path(full)
            need(actual is not None, "%s does not exist (or is a symlink) under the workbench: %s" % (label, ev))
            if actual is not None:
                need(str(actual) == str(sha), "%s sha256 mismatch (recorded %s, actual %s)" % (label, sha, actual))
        if ev_commit and _git_resolves(workbench, ev_commit):
            same = subprocess.run(["git", "-C", workbench, "diff", "--quiet", str(ev_commit), "--", ev],
                                  capture_output=True)
            need(same.returncode == 0,
                 "%s differs from its version in evidence_commit %s (a working-tree edit after the "
                 "manifest, or the evidence is not committed in that commit)" % (label, ev_commit))

    for label in ("source.pin", "gate.logic_commit", "evidence_commit"):
        ref = _get(manifest, label)
        if ref:
            need(_git_resolves(workbench, ref), "%s '%s' does not resolve in the workbench" % (label, ref))
    if ev_commit and _git_resolves(workbench, ev_commit):
        anc = subprocess.run(["git", "-C", workbench, "merge-base", "--is-ancestor", str(ev_commit), "HEAD"],
                             capture_output=True)
        need(anc.returncode == 0, "evidence_commit %s is not an ancestor of HEAD - the cited evidence "
             "is not on the committed history this manifest sits on" % ev_commit)

    need(_get(manifest, "integration.state") in ("gated", "integrated"),
         "integration.state '%s' must be gated|integrated" % _get(manifest, "integration.state"))
    return v


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--manifest", action="append", default=None)
    ap.add_argument("--product-root", default=None)
    ap.add_argument("--workbench", default=None)
    args = ap.parse_args()

    orig = os.getcwd()
    workbench = os.path.realpath(args.workbench) if args.workbench else _repo_root()
    try:
        os.chdir(workbench)
    except OSError:
        _fail("cannot enter workbench '%s'" % workbench)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse manifests (install pyyaml)")
    loader = _strict_loader(yaml)

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
            try:
                with open("port/product.yaml") as fh:
                    product_root = (yaml.load(fh, Loader=loader) or {}).get("checkout")
            except yaml.YAMLError as exc:
                _fail("port/product.yaml is not valid YAML (%s)" % exc)
        if not product_root:
            _fail("manifests exist but no product checkout (set --product-root or port/product.yaml checkout)")
    product_root = os.path.realpath(product_root if os.path.isabs(product_root)
                                    else os.path.join(orig if args.product_root else workbench, product_root))
    if not os.path.isdir(product_root):
        _fail("product checkout '%s' is not a directory" % product_root)
    # The product is its own repository, never the workbench (C6).
    ptop = subprocess.run(["git", "-C", product_root, "rev-parse", "--show-toplevel"],
                          capture_output=True, text=True)
    if ptop.returncode != 0:
        _fail("product checkout '%s' is not a git repository" % product_root)
    if os.path.realpath(ptop.stdout.strip()) == workbench:
        _fail("product checkout resolves to the workbench repo - the product must be its own repository")

    fails = 0
    for mpath in manifests:
        try:
            with open(mpath) as fh:
                manifest = yaml.load(fh, Loader=loader) or {}
        except yaml.YAMLError as exc:
            print("  [FAIL] %s: not valid YAML (%s)" % (os.path.basename(mpath), exc))
            fails += 1
            continue
        if not isinstance(manifest, dict):
            print("  [FAIL] %s: not a mapping" % os.path.basename(mpath))
            fails += 1
            continue
        for msg in verify(manifest, product_root, workbench):
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
