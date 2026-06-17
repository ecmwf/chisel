#!/usr/bin/env python3
"""grant_product_access - let opencode reach the linked product without prompting.

In the two-repo layout (references/two-repo-architecture.md) the PRODUCT lives in its own repo,
checked out as a SIBLING of the workbench - so it is OUTSIDE opencode's working directory, and
opencode guards every read/edit/glob/grep/bash touch of an outside path behind its
`permission.external_directory` prompt. During a hands-off run (auto-mode, gates, a worker editing
TARGET code) that prompt stalls the loop. This writes a SCOPED allow for exactly the product
checkout into the instance-local `opencode.json`, so product operations stop prompting - and nothing
broader is opened (no blanket `~/**`).

It is a no-op in the single-repo phase (no port/product.yaml, or the product is the in-workbench
`target/`): then the product is INSIDE the working dir and needs no grant.

Idempotent and re-runnable. Run after linking a product (tools/new-product.sh does it for you); an
existing instance runs it once. opencode.json is instance-local (gitignored), so the absolute path
written here is per-machine and re-derived on a fresh clone.

Exit: 0 done (granted, already-present, or nothing to do); 2 refused (malformed opencode.json - not
clobbered).
"""
import argparse
import json
import os
import subprocess
import sys


def repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def parse_checkout(product_yaml):
    """The `checkout:` scalar, stripped of an inline comment, quotes, and whitespace. '' if absent."""
    try:
        with open(product_yaml, encoding="utf-8") as fh:
            for ln in fh:
                s = ln.strip()
                if s.startswith("checkout:"):
                    v = s[len("checkout:"):].strip()
                    v = v.split("#", 1)[0].strip().strip('"').strip("'")
                    return "" if v in ("null", "~") else v
    except Exception:
        pass
    return ""


def main():
    ap = argparse.ArgumentParser(description="Grant opencode external_directory access to the linked product.")
    ap.add_argument("--dry-run", action="store_true", help="print what would change; write nothing")
    args = ap.parse_args()

    root = repo_root()
    product_yaml = os.path.join(root, "port", "product.yaml")
    if not os.path.isfile(product_yaml):
        print("grant-product-access: no port/product.yaml - single-repo (product is in-workbench); nothing to grant.")
        return
    checkout = parse_checkout(product_yaml)
    if not checkout or "<" in checkout or ">" in checkout:
        print("grant-product-access: product checkout is unset/placeholder - link the product first; nothing to grant.")
        return

    product_abs = os.path.realpath(os.path.join(root, checkout))
    pattern = product_abs.rstrip("/") + "/**"

    oc = os.path.join(root, "opencode.json")
    cfg = {}
    if os.path.isfile(oc):
        try:
            loaded = json.load(open(oc, encoding="utf-8"))
        except Exception as exc:
            sys.stderr.write("grant-product-access: %s is not valid JSON (%s) - NOT modifying it. "
                             "Fix it, then re-run.\n" % (oc, exc))
            sys.exit(2)
        if not isinstance(loaded, dict):
            sys.stderr.write("grant-product-access: %s is not a JSON object - NOT modifying it.\n" % oc)
            sys.exit(2)
        cfg = loaded

    ext = cfg.get("permission", {}).get("external_directory", {}) if isinstance(cfg.get("permission"), dict) else {}
    if isinstance(ext, dict) and ext.get(pattern) == "allow":
        print("grant-product-access: already granted (%s)." % pattern)
        return

    if args.dry_run:
        print("[dry-run] would grant opencode access to the product: external_directory['%s'] = allow" % pattern)
        return

    cfg.setdefault("$schema", "https://opencode.ai/config.json")
    perm = cfg.setdefault("permission", {})
    if not isinstance(perm, dict):
        sys.stderr.write("grant-product-access: opencode.json `permission` is not an object - NOT modifying it.\n")
        sys.exit(2)
    extd = perm.setdefault("external_directory", {})
    if not isinstance(extd, dict):
        sys.stderr.write("grant-product-access: opencode.json `permission.external_directory` is not an object - NOT modifying it.\n")
        sys.exit(2)
    extd[pattern] = "allow"

    with open(oc, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(cfg, indent=2) + "\n")
    print("grant-product-access: granted opencode access to the product checkout (no more prompts):")
    print("  external_directory['%s'] = allow  (in opencode.json, instance-local)" % pattern)


if __name__ == "__main__":
    main()
