#!/usr/bin/env python3
"""Verify TRACE COMPLETENESS: every SOURCE unit the dependency map knows has a TRACE row.

The drift check (generate_trace --check) proves the canonical TRACE matches the fragments that
EXIST - but it cannot notice a fragment that is MISSING. Since TRACE is generated from whatever
fragments are present, a SOURCE unit with no fragment is simply absent from TRACE, and nothing
flags it: a whole module can be silently omitted from the trust accounting and every other check
stays green. The dependency map (tools/scoping/dependency-map.yaml) is the canonical SOURCE
INVENTORY - one node per SOURCE unit, generated from the tree and drift-checked by check-depmap.
This gate joins the two: every map node must appear as a TRACE row (as unmapped/in-progress/
gated/excluded - an unstarted unit is `unmapped`, not absent), and every TRACE row must
correspond to a real map node (no fragment for a unit the SOURCE does not have).

So the failure it catches is the one the drift check cannot: a unit that is missing from TRACE
entirely. Committing the dependency map is the signal that the inventory is known (Phase-0/1
scoping done); from then on TRACE must account for all of it.

Reads the map (--map, default tools/scoping/dependency-map.yaml) and the generated TRACE
(--trace, default port/TRACE.yaml). Until BOTH exist there is nothing to compare, so it skips.

Usage:  check_completeness.py [--map FILE] [--trace FILE]
Exit:   0 every SOURCE unit has a TRACE row and vice versa (or nothing wired yet); 1 a unit is
        missing from TRACE, or a TRACE row has no SOURCE unit; 2 UNRELIABLE (no PyYAML, malformed).
"""
import argparse
import os
import subprocess
import sys
from typing import NoReturn


def _fail(msg) -> "NoReturn":
    sys.stderr.write("check-completeness: " + msg + "\n")
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


def _s(v):
    return "" if v is None else str(v).strip()


def _ids(seq, key, label):
    """Collect the non-empty `key` of each mapping in a list, rejecting a malformed shape."""
    if seq is None:
        return []
    if not isinstance(seq, list):
        _fail("%s must be a list" % label)
    out = []
    for item in seq:
        if not isinstance(item, dict):
            _fail("%s has a non-mapping entry" % label)
        rid = _s(item.get(key))
        if rid:
            out.append(rid)
    return out


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--map", default=None)
    ap.add_argument("--trace", default=None)
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

    map_path = resolve(args.map, os.path.join("tools", "scoping", "dependency-map.yaml"))
    trace_path = resolve(args.trace, os.path.join("port", "TRACE.yaml"))

    if not os.path.isfile(map_path) or not os.path.isfile(trace_path):
        print("check-completeness: need both the dependency map and the generated TRACE to "
              "compare - one or both is absent, nothing to check (skipping).")
        sys.exit(0)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse the artifacts (install pyyaml)")
    loader = _strict_loader(yaml)

    def load(path, label):
        try:
            with open(path, encoding="utf-8") as fh:
                data = yaml.load(fh, Loader=loader)
        except (OSError, yaml.YAMLError) as exc:
            _fail("cannot read %s '%s' (%s)" % (label, path, exc))
        if not isinstance(data, dict):
            _fail("%s '%s' is not a mapping" % (label, path))
        return data

    dep = load(map_path, "dependency map")
    trace = load(trace_path, "TRACE")
    map_ids = _ids(dep.get("nodes"), "id", "dependency map 'nodes'")
    trace_ids = _ids(trace.get("files"), "id", "TRACE 'files'")

    if not map_ids:
        print("check-completeness: the dependency map has no nodes - nothing to check (skipping).")
        sys.exit(0)

    map_set, trace_set = set(map_ids), set(trace_ids)
    fails = 0
    for missing in sorted(map_set - trace_set):
        src = next((_s(n.get("source")) for n in dep["nodes"] if _s(n.get("id")) == missing), "")
        print("  [FAIL] SOURCE unit '%s' (%s) has no TRACE row - it is silently outside the trust "
              "accounting (give it a fragment, even status: unmapped)" % (missing, src or "?"))
        fails += 1
    for extra in sorted(trace_set - map_set):
        print("  [FAIL] TRACE row '%s' has no SOURCE unit in the dependency map (a fragment for a "
              "unit the SOURCE does not have, or a stale map)" % extra)
        fails += 1

    print("check-completeness: %d SOURCE unit(s), %d TRACE row(s); %d gap(s)."
          % (len(map_set), len(trace_set), fails))
    if fails:
        print("RESULT: RED (exit 1) - TRACE does not completely account for the SOURCE inventory.")
        sys.exit(1)
    print("RESULT: GREEN (exit 0) - every SOURCE unit has a TRACE row and every row is a real unit.")
    sys.exit(0)


if __name__ == "__main__":
    main()
