#!/usr/bin/env python3
"""Verify the CROSS-ARTIFACT bindings no single-artifact check can enforce.

Every other coordination check validates one artifact in isolation: check-status-fragments
a fragment, check-claims a claim ref, check-audit-manifest a manifest, check-depmap the map.
But the trust claim - "this piece is claimed by who it says, gated on the evidence it cites,
integrated as the manifest attests, and the product's mainline is exactly what we attested" -
lives in the JOINS between them. A fragment can self-report a claim that names a different
claimant than the real ref; an integrated fragment can point at a manifest that attests a
different commit; the product mainline can advance past the commit the workbench attested. No
isolated check sees any of that. This gate recomputes the joins and fails closed.

It verifies, fail-closed:

  FILENAME  - each port/status/<id>.yaml has `id` == <id> (the basename is the work-item id).
  CLAIM     - a fragment with a claim block binds to the REAL claim ref: claim.ref ==
              refs/claims/<id>, a claim with that id exists, and its claimant equals the
              fragment's. A fragment that cites a claim while the claim namespace is absent
              (a CI checkout that did not fetch refs/claims/*) is RED, not silently skipped.
  MANIFEST  - an `integration.state: integrated` fragment binds to port/manifests/<id>.yaml,
              whose deliverable, product.commit, gate.product_commit, gate.evidence, and
              review.evidence all equal the fragment's, and whose integration.state is
              integrated. A fragment cannot claim an integration the manifest does not attest.
  PRODUCT   - each manifest's product.repo equals port/product.yaml `repo`.
  ATTESTED  - the product's protected mainline (default_branch) is exactly the attested commit
              (port/product.yaml `attested_commit`): no unattested commit sits ahead of it; the
              attested commit IS some integrated manifest's product.commit; and every integrated
              manifest's product.commit is reachable from it (the attested head caps the chain).

Claims come from refs/claims/* (git cat-file each blob) by default; --claims-dir reads
<id>.yaml fixtures. The product repo is its own repository: --product-root, else port/product.yaml
`checkout`. All YAML is loaded with a duplicate-key-REJECTING loader.

Usage:  check_bindings.py [--status-dir DIR] [--claims-dir DIR] [--manifests-dir DIR]
                          [--product-root DIR] [--product-yaml FILE]
Exit:   0 every binding holds (or there is nothing wired yet); 1 a binding violation;
        2 UNRELIABLE (no PyYAML/git, product wired but absent, an artifact too malformed to join).
"""
import argparse
import glob
import os
import subprocess
import sys
from typing import NoReturn

PLACEHOLDER = ("", "none", "null", "~")


def _fail(msg) -> "NoReturn":
    sys.stderr.write("check-bindings: " + msg + "\n")
    sys.exit(2)


def _repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def _strict_loader(yaml):
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


def _get(d, dotted):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict):
            return None
        cur = cur.get(part)
    return cur


def _s(v):
    return "" if v is None else str(v).strip()


def _is_real(v):
    return _s(v).lower() not in PLACEHOLDER and "<" not in _s(v) and ">" not in _s(v)


def _load_one(path, yaml, loader):
    with open(path, encoding="utf-8") as fh:
        return yaml.load(fh, Loader=loader)


def _load_fragments(status_dir, yaml, loader):
    out = []
    for p in sorted(glob.glob(os.path.join(status_dir, "*.yaml"))):
        if os.path.basename(p) == "_meta.yaml":
            continue
        base = os.path.splitext(os.path.basename(p))[0]
        try:
            frag = _load_one(p, yaml, loader)
        except yaml.YAMLError as exc:
            out.append((base, None, "not valid YAML (%s)" % exc))
            continue
        out.append((base, frag if isinstance(frag, dict) else None,
                    None if isinstance(frag, dict) else "fragment is not a mapping"))
    return out


def _load_claims(claims_dir, yaml, loader):
    """(present, {id: claim_dict}). present is False when the claim namespace is entirely
    absent (no refs/claims/* and no fixtures) - which a fragment citing a claim turns into a
    violation, never a silent pass."""
    out = {}
    if claims_dir is not None:
        if not os.path.isdir(claims_dir):
            return (False, out)
        paths = sorted(glob.glob(os.path.join(claims_dir, "*.yaml")))
        if not paths:
            return (False, out)
        for p in paths:
            cid = os.path.splitext(os.path.basename(p))[0]
            try:
                c = _load_one(p, yaml, loader)
            except yaml.YAMLError:
                continue
            if isinstance(c, dict):
                out[_s(c.get("id")) or cid] = c
        return (True, out)
    try:
        raw = subprocess.check_output(
            ["git", "for-each-ref", "--format=%(refname) %(objecttype)", "refs/claims/"],
            stderr=subprocess.DEVNULL).decode()
    except Exception:
        return (False, out)
    refs = [ln for ln in raw.splitlines() if ln.strip()]
    if not refs:
        return (False, out)
    for line in refs:
        refname, _, objtype = line.strip().partition(" ")
        rid = refname[len("refs/claims/"):]
        if objtype.strip() != "blob":
            continue
        try:
            blob = subprocess.check_output(["git", "cat-file", "blob", refname],
                                           stderr=subprocess.DEVNULL)
            c = yaml.load(blob, Loader=loader)
        except Exception:
            continue
        if isinstance(c, dict):
            out[_s(c.get("id")) or rid] = c
    return (True, out)


def _git_rev(repo, ref):
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "%s^{commit}" % ref],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def _is_ancestor(repo, anc, desc):
    return subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", anc, desc],
                          capture_output=True).returncode == 0


def check_fragment_bindings(fragments, claims_present, claims, manifests_dir, fails):
    """FILENAME + CLAIM + MANIFEST bindings. Returns updated fail count; prints [FAIL]s."""
    for base, frag, err in fragments:
        if frag is None:
            print("  [FAIL] %s: %s" % (base, err)); fails += 1
            continue
        fid = _s(frag.get("id"))
        if fid != base:
            print("  [FAIL] %s: fragment id '%s' does not match its filename '%s.yaml'"
                  % (base, fid, base)); fails += 1
            continue  # every other binding keys on the id; a wrong filename poisons them

        ref = _s(_get(frag, "claim.ref"))
        claimant = _s(_get(frag, "claim.claimant"))
        if _is_real(ref) or _is_real(claimant):
            expect = "refs/claims/%s" % fid
            if ref != expect:
                print("  [FAIL] %s: claim.ref '%s' must be '%s'" % (fid, ref, expect)); fails += 1
            if not claims_present:
                print("  [FAIL] %s: fragment cites a claim but the claim namespace is absent "
                      "(did CI fetch refs/claims/*?)" % fid); fails += 1
            elif fid not in claims:
                print("  [FAIL] %s: no claim '%s' exists for this fragment's claim block"
                      % (fid, fid)); fails += 1
            else:
                real = _s(claims[fid].get("claimant"))
                if real != claimant:
                    print("  [FAIL] %s: fragment claimant '%s' != claim ref claimant '%s'"
                          % (fid, claimant, real)); fails += 1

        if _s(_get(frag, "integration.state")) == "integrated":
            mref = _s(frag.get("workbench_manifest"))
            expect_m = os.path.join("port", "manifests", "%s.yaml" % fid)
            if os.path.normpath(mref) != os.path.normpath(expect_m):
                print("  [FAIL] %s: integrated fragment workbench_manifest '%s' must be '%s'"
                      % (fid, mref, expect_m)); fails += 1
                continue
            mpath = os.path.join(manifests_dir, "%s.yaml" % fid)
            if not os.path.isfile(mpath):
                print("  [FAIL] %s: integrated fragment names a manifest that is missing: %s"
                      % (fid, mref)); fails += 1
                continue
            try:
                import yaml
                man = _load_one(mpath, yaml, _strict_loader(yaml))
            except Exception as exc:
                print("  [FAIL] %s: manifest does not parse (%s)" % (fid, exc)); fails += 1
                continue
            for label, fv, mv in (
                    ("deliverable", fid, _s(_get(man, "deliverable"))),
                    ("product commit", _s(_get(frag, "product.main_commit")), _s(_get(man, "product.commit"))),
                    ("gate commit", _s(_get(frag, "gate.commit")), _s(_get(man, "gate.product_commit"))),
                    ("gate evidence", _s(_get(frag, "gate.evidence")), _s(_get(man, "gate.evidence"))),
                    ("review evidence", _s(_get(frag, "review.evidence")), _s(_get(man, "review.evidence")))):
                if fv != mv:
                    print("  [FAIL] %s: %s differs - fragment '%s' vs manifest '%s'"
                          % (fid, label, fv, mv)); fails += 1
            if _s(_get(man, "integration.state")) != "integrated":
                print("  [FAIL] %s: manifest integration.state is not 'integrated'" % fid); fails += 1
    return fails


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--status-dir", default=None)
    ap.add_argument("--claims-dir", default=None)
    ap.add_argument("--manifests-dir", default=None)
    ap.add_argument("--product-root", default=None)
    ap.add_argument("--product-yaml", default=None)
    args = ap.parse_args()

    orig = os.getcwd()
    root = _repo_root()
    try:
        os.chdir(root)
    except OSError:
        _fail("cannot enter repo root '%s'" % root)

    def resolve(p, default_rel):
        if p is None:
            return default_rel
        return p if os.path.isabs(p) else os.path.join(orig, p)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse the coordination artifacts (install pyyaml)")
    loader = _strict_loader(yaml)

    status_dir = resolve(args.status_dir, "port/status")
    manifests_dir = resolve(args.manifests_dir, os.path.join("port", "manifests"))
    product_yaml = resolve(args.product_yaml, "port/product.yaml")
    claims_dir = resolve(args.claims_dir, None) if args.claims_dir else None

    fragments = _load_fragments(status_dir, yaml, loader) if os.path.isdir(status_dir) else []
    claims_present, claims = _load_claims(claims_dir, yaml, loader)
    have_manifests = os.path.isdir(manifests_dir) and glob.glob(os.path.join(manifests_dir, "*.yaml"))
    have_product = os.path.isfile(product_yaml)

    if not fragments and not claims_present and not have_manifests and not have_product:
        print("check-bindings: no coordination artifacts wired yet - nothing to check (skipping).")
        sys.exit(0)

    # Resolve the product repo (its own repository, never the workbench) for the attested-head join.
    product_root, product_repo, attested = None, None, ""
    if have_product:
        try:
            pdoc = _load_one(product_yaml, yaml, loader) or {}
        except yaml.YAMLError as exc:
            _fail("port/product.yaml is not valid YAML (%s)" % exc)
        product_repo = _s(pdoc.get("repo")) or None
        attested = _s(pdoc.get("attested_commit"))
        default_branch = _s(pdoc.get("default_branch")) or "main"
        pr = args.product_root or pdoc.get("checkout")
        if pr and _is_real(pr):
            product_root = os.path.realpath(pr if os.path.isabs(pr)
                                            else os.path.join(orig if args.product_root else root, pr))
            if not os.path.isdir(product_root):
                if _is_real(attested):
                    _fail("product checkout '%s' is not a directory, but attested_commit is set" % pr)
                product_root = None
            elif subprocess.run(["git", "-C", product_root, "rev-parse", "--show-toplevel"],
                                capture_output=True).returncode != 0:
                _fail("product checkout '%s' is not a git repository" % pr)
    else:
        default_branch = "main"

    fails = 0
    fails = check_fragment_bindings(fragments, claims_present, claims, manifests_dir, fails)

    # PRODUCT (manifest repo identity) + ATTESTED (mainline == attested == chain head).
    man_paths = sorted(glob.glob(os.path.join(manifests_dir, "*.yaml"))) if have_manifests else []
    integrated = []
    for mp in man_paths:
        try:
            man = _load_one(mp, yaml, loader)
        except Exception:
            continue
        if not isinstance(man, dict):
            continue
        if product_repo is not None:
            mrepo = _s(_get(man, "product.repo"))
            if mrepo != product_repo:
                print("  [FAIL] %s: product.repo '%s' != port/product.yaml repo '%s'"
                      % (os.path.basename(mp), mrepo, product_repo)); fails += 1
        if _s(_get(man, "integration.state")) == "integrated":
            integrated.append((os.path.basename(mp), _s(_get(man, "product.commit"))))

    if have_product and _is_real(attested):
        if product_root is None:
            _fail("attested_commit is set but no usable product checkout to verify it against")
        att = _git_rev(product_root, attested)
        if att is None:
            print("  [FAIL] port/product.yaml: attested_commit '%s' does not resolve in the product repo"
                  % attested); fails += 1
        else:
            tip = _git_rev(product_root, default_branch)
            if tip is None:
                print("  [FAIL] port/product.yaml: default_branch '%s' does not resolve in the product repo"
                      % default_branch); fails += 1
            elif tip != att:
                print("  [FAIL] port/product.yaml: %s is at %s, ahead of the attested_commit %s "
                      "(unattested commits on the mainline)" % (default_branch, tip[:12], att[:12])); fails += 1
            commits = [c for _n, c in integrated]
            if commits and att not in [_git_rev(product_root, c) for c in commits]:
                print("  [FAIL] port/product.yaml: attested_commit %s is not the product.commit of any "
                      "integrated manifest" % att[:12]); fails += 1
            for name, c in integrated:
                rc = _git_rev(product_root, c)
                if rc is None:
                    print("  [FAIL] %s: product.commit '%s' does not resolve" % (name, c)); fails += 1
                elif rc != att and not _is_ancestor(product_root, rc, att):
                    print("  [FAIL] %s: product.commit %s is not reachable from attested_commit %s"
                          % (name, rc[:12], att[:12])); fails += 1
    elif have_product and integrated and not _is_real(attested):
        print("  [FAIL] port/product.yaml: %d integrated manifest(s) exist but attested_commit is unset"
              % len(integrated)); fails += 1

    nfrag = sum(1 for _b, f, _e in fragments if f is not None)
    print("check-bindings: %d fragment(s), %d claim(s), %d manifest(s); %d binding violation(s)."
          % (nfrag, len(claims), len(man_paths), fails))
    if fails:
        print("RESULT: RED (exit 1) - a cross-artifact binding does not hold.")
        sys.exit(1)
    print("RESULT: GREEN (exit 0) - fragments, claims, manifests, and the product mainline agree.")
    sys.exit(0)


if __name__ == "__main__":
    main()
