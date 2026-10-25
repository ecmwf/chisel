#!/usr/bin/env python3
"""grant_external_access - let opencode reach the dirs it needs to run hands-off, without prompting.

opencode guards every read/edit/glob/grep/bash touch of a path OUTSIDE its working directory behind a
`permission.external_directory` prompt. During a hands-off run (auto-mode, proofs, parallel workers)
that prompt STALLS the loop - and in a PARALLEL run every worker prompts at once, so the run wedges.
This writes the SCOPED allows opencode needs into the instance-local `opencode.json`:

  - SCRATCH (always): /tmp/** and /tmp/* - the agent and its build/test tooling use /tmp for scratch
    (mktemp). Without this, every worker prompts on its first temp file; a parallel wave deadlocks.
  - PRODUCT (two-repo only): the sibling product checkout (references/two-repo-architecture.md), which
    lives OUTSIDE the workbench - so product reads/edits/proofs stop prompting.

Nothing broader is opened (no blanket ~/** ). Idempotent and re-runnable. opencode.json is
instance-local (gitignored), so the absolute paths written here are per-machine and re-derived on a
fresh clone. In the single-repo phase it still grants scratch (only the product part is skipped).

Exit: 0 done (granted, already-present, or nothing new); 2 refused (malformed opencode.json - not clobbered).
"""
import argparse
import json
import os
import subprocess
import sys

SCRATCH_PATTERNS = ("/tmp/**", "/tmp/*")  # the agent's + tooling's scratch space (mktemp); always granted


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


def product_patterns(root):
    """Scoped allow patterns for the linked product: its working tree (nested + direct child) AND its
    shared git store (.git, nested + direct). A worker commits through a LINKED worktree, so the new
    objects/refs land in <product>/.git/... . The explicit `.git` and direct-child (`/*`) entries are
    DEFENSIVE: rather than assume how opencode's glob treats a hidden `.git` segment or a direct child
    under `**`, each level is listed so the commit never prompts whatever the matcher does. [] when
    single-repo / unlinked / placeholder."""
    product_yaml = os.path.join(root, "port", "product.yaml")
    if not os.path.isfile(product_yaml):
        return []
    checkout = parse_checkout(product_yaml)
    if not checkout or "<" in checkout or ">" in checkout:
        return []
    rp = os.path.realpath(os.path.join(root, checkout)).rstrip("/")
    return [rp + "/**", rp + "/*", rp + "/.git/**", rp + "/.git/*"]


def main():
    ap = argparse.ArgumentParser(description="Grant opencode the external_directory access it needs (scratch + product).")
    ap.add_argument("--dry-run", action="store_true", help="print what would change; write nothing")
    args = ap.parse_args()

    root = repo_root()
    patterns: list = list(SCRATCH_PATTERNS)
    patterns += product_patterns(root)

    oc = os.path.join(root, "opencode.json")
    cfg = {}
    if os.path.isfile(oc):
        try:
            loaded = json.load(open(oc, encoding="utf-8"))
        except Exception as exc:
            sys.stderr.write("grant-external-access: %s is not valid JSON (%s) - NOT modifying it. "
                             "Fix it, then re-run.\n" % (oc, exc))
            sys.exit(2)
        if not isinstance(loaded, dict):
            sys.stderr.write("grant-external-access: %s is not a JSON object - NOT modifying it.\n" % oc)
            sys.exit(2)
        cfg = loaded

    # Validate the existing permission shape UP FRONT, so dry-run and the real run fail closed alike.
    perm = cfg.get("permission", {})
    if not isinstance(perm, dict):
        sys.stderr.write("grant-external-access: opencode.json `permission` is not an object - NOT modifying it.\n")
        sys.exit(2)
    extd = perm.get("external_directory", {})
    if not isinstance(extd, dict):
        sys.stderr.write("grant-external-access: opencode.json `permission.external_directory` is not an object - NOT modifying it.\n")
        sys.exit(2)
    missing = [p for p in patterns if extd.get(p) != "allow"]
    if not missing:
        print("grant-external-access: already granted (%s)." % ", ".join(patterns))
        return
    if args.dry_run:
        print("[dry-run] would grant opencode external_directory access: %s" % ", ".join(missing))
        return

    cfg.setdefault("$schema", "https://opencode.ai/config.json")
    extd = cfg.setdefault("permission", {}).setdefault("external_directory", {})
    for p in patterns:
        extd[p] = "allow"

    with open(oc, "w", encoding="utf-8") as fh:
        fh.write(json.dumps(cfg, indent=2) + "\n")
    print("grant-external-access: granted opencode external_directory access (no more prompts):")
    for p in patterns:
        print("  %s = allow" % p)
    print("  (in opencode.json, instance-local + gitignored; reload opencode to apply)")


if __name__ == "__main__":
    main()
