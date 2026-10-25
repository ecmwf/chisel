#!/usr/bin/env python3
"""Verify TRACE COMPLETENESS: every SOURCE unit the dependency map knows has a TRACE row.

The drift check (generate_trace --check) proves the canonical TRACE matches the fragments that
EXIST - but it cannot notice a fragment that is MISSING. Since TRACE is generated from whatever
fragments are present, a SOURCE unit with no fragment is simply absent from TRACE, and nothing
flags it: a whole module can be silently omitted from the trust accounting and every other check
stays green. The dependency map (tools/scoping/dependency-map.yaml) is the canonical SOURCE
INVENTORY - one node per SOURCE unit, generated from the tree and drift-checked by check-depmap.
This check joins the two: every map node must appear as a TRACE row (as unmapped/in-progress/
proven/excluded - an unstarted unit is `unmapped`, not absent), and every TRACE row must
correspond to a real map node (no fragment for a unit the SOURCE does not have).

Assembly-proven deliverables are the narrow exception to the reverse direction: a TRACE row whose
id is not a map node is accepted only when it is a declared assembly id in
tools/scoping/assemblies.yaml (or --assemblies FILE) and every declared member is a real map
node. This preserves completeness in both directions: SOURCE units still cannot disappear from
TRACE, and an assembly row cannot smuggle phantom units via fake/empty membership.

So the failure it catches is the one the drift check cannot: a unit that is missing from TRACE
entirely. Committing the dependency map is the signal that the inventory is known (Phase-0/1
scoping done); from then on TRACE must account for all of it.

The join is one row per unit, so an id that appears twice - two TRACE rows, or two map nodes - is
RED rather than silently collapsed into one: a bad merge or a hand edit that duplicates a row leaves
two entries that can disagree (one proven, one in-progress) while a set comparison stays green. The
drift check catches a duplicated row only when fragments exist; this check runs either way.

Reads the map (--map, default tools/scoping/dependency-map.yaml), the generated TRACE
(--trace, default port/TRACE.yaml), and the optional assembly registry
(--assemblies, default tools/scoping/assemblies.yaml). Until BOTH map+TRACE exist there is
nothing to compare, so it skips. A missing assemblies registry means "no assemblies declared".

Usage:  check_completeness.py [--map FILE] [--trace FILE] [--assemblies FILE]
Exit:   0 every SOURCE unit has a TRACE row and vice versa (or nothing wired yet); 1 a unit is
        missing from TRACE, a TRACE row has no SOURCE unit / valid declared assembly, or an id
        appears twice in the map or in TRACE; 2 UNRELIABLE (no PyYAML, malformed).
"""
import argparse
import os
import sys
from collections import Counter
from typing import Dict, List, NoReturn
from _chisel_lib import strict_loader as _strict_loader, repo_root as _repo_root
from _chisel_lib import modern as _modern, VocabularyConflict


def _fail(msg) -> "NoReturn":
    sys.stderr.write("check-completeness: " + msg + "\n")
    sys.exit(2)


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


def _load_assemblies(path: str, yaml, loader) -> Dict[str, List[str]]:
    """Parse assemblies registry; missing file means no assemblies declared.

    Parse failures are UNRELIABLE (exit 2). Semantic membership checks are done against map_set
    during the main comparison so they surface as RED (exit 1), not parse failures.
    """
    if not os.path.isfile(path):
        return {}

    try:
        with open(path, encoding="utf-8") as fh:
            data = _modern(yaml.load(fh, Loader=loader))
    except (OSError, yaml.YAMLError, VocabularyConflict) as exc:
        _fail("cannot read assemblies registry '%s' (%s)" % (path, exc))

    if not isinstance(data, dict):
        _fail("assemblies registry '%s' is not a mapping" % path)
    if "assemblies" not in data:
        _fail("assemblies registry '%s' is missing required key 'assemblies'" % path)

    raw = data.get("assemblies")
    if not isinstance(raw, list):
        _fail("assemblies registry 'assemblies' must be a list")

    out: Dict[str, List[str]] = {}
    for idx, item in enumerate(raw, start=1):
        if not isinstance(item, dict):
            _fail("assemblies registry entry #%d is not a mapping" % idx)

        aid = _s(item.get("id"))
        if not aid:
            _fail("assemblies registry entry #%d has empty/missing 'id'" % idx)
        if aid in out:
            _fail("assemblies registry has duplicate id '%s'" % aid)

        members = item.get("members")
        if not isinstance(members, list):
            _fail("assembly '%s' has non-list/missing 'members'" % aid)

        parsed_members: List[str] = []
        for midx, m in enumerate(members, start=1):
            if not isinstance(m, str):
                _fail("assembly '%s' member #%d must be a string" % (aid, midx))
            ms = m.strip()
            if not ms:
                _fail("assembly '%s' member #%d is empty" % (aid, midx))
            parsed_members.append(ms)

        out[aid] = parsed_members

    return out


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--map", default=None)
    ap.add_argument("--trace", default=None)
    ap.add_argument("--assemblies", default=None)
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
    assemblies_path = resolve(args.assemblies, os.path.join("tools", "scoping", "assemblies.yaml"))

    if not os.path.isfile(map_path):
        print("check-completeness: no dependency map yet (the SOURCE inventory is not committed) - "
              "nothing to check (skipping).")
        sys.exit(0)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse the artifacts (install pyyaml)")

    if not os.path.isfile(trace_path):
        print("  [FAIL] the dependency map exists (the SOURCE inventory is known) but the generated "
              "TRACE '%s' is absent - every SOURCE unit is outside the trust accounting."
              % os.path.relpath(trace_path, os.getcwd()))
        print("RESULT: RED (exit 1) - generate TRACE so it accounts for the committed inventory.")
        sys.exit(1)
    loader = _strict_loader(yaml)

    def load(path, label):
        try:
            with open(path, encoding="utf-8") as fh:
                data = _modern(yaml.load(fh, Loader=loader))
        except (OSError, yaml.YAMLError, VocabularyConflict) as exc:
            _fail("cannot read %s '%s' (%s)" % (label, path, exc))
        if not isinstance(data, dict):
            _fail("%s '%s' is not a mapping" % (label, path))
        return data

    dep = load(map_path, "dependency map")
    trace = load(trace_path, "TRACE")
    assemblies = _load_assemblies(assemblies_path, yaml, loader)
    map_ids = _ids(dep.get("nodes"), "id", "dependency map 'nodes'")
    trace_ids = _ids(trace.get("files"), "id", "TRACE 'files'")

    if not map_ids:
        print("check-completeness: the dependency map has no nodes - nothing to check (skipping).")
        sys.exit(0)

    map_set, trace_set = set(map_ids), set(trace_ids)
    fails = 0
    for label, ids, noun in (("dependency map", map_ids, "nodes"), ("TRACE", trace_ids, "rows")):
        for dup, count in sorted(Counter(ids).items()):
            if count > 1:
                print("  [FAIL] %s has %d %s with id '%s' - one unit has exactly one entry; a "
                      "duplicate (a bad merge or a hand edit) would otherwise be collapsed silently"
                      % (label, count, noun, dup))
                fails += 1
    assembly_exemptions = 0
    for missing in sorted(map_set - trace_set):
        src = next((_s(n.get("source")) for n in dep["nodes"] if _s(n.get("id")) == missing), "")
        print("  [FAIL] SOURCE unit '%s' (%s) has no TRACE row - it is silently outside the trust "
              "accounting (give it a fragment, even status: unmapped)" % (missing, src or "?"))
        fails += 1
    for extra in sorted(trace_set - map_set):
        members = assemblies.get(extra)
        if members is None:
            print("  [FAIL] TRACE row '%s' has no SOURCE unit in the dependency map (a fragment for a "
                  "unit the SOURCE does not have, or a stale map)" % extra)
            fails += 1
            continue
        if not members:
            print("  [FAIL] TRACE row '%s' is declared as an assembly but has an empty members list in "
                  "'%s' - a real assembly must compose real SOURCE units"
                  % (extra, os.path.relpath(assemblies_path, os.getcwd())))
            fails += 1
            continue
        non_nodes = sorted(m for m in set(members) if m not in map_set)
        if non_nodes:
            print("  [FAIL] TRACE row '%s' is a declared assembly, but member(s) %s are not SOURCE "
                  "units in the dependency map - assembly exemption refused"
                  % (extra, ", ".join("'%s'" % m for m in non_nodes)))
            fails += 1
            continue
        assembly_exemptions += 1

    print("check-completeness: %d SOURCE unit(s), %d TRACE row(s); %d declared assembly row(s) "
          "accepted; %d gap(s)."
          % (len(map_set), len(trace_set), assembly_exemptions, fails))
    if fails:
        print("RESULT: RED (exit 1) - TRACE does not completely account for the SOURCE inventory.")
        sys.exit(1)
    print("RESULT: GREEN (exit 0) - every SOURCE unit has a TRACE row and every row is either a "
          "real unit or a valid declared assembly.")
    sys.exit(0)


if __name__ == "__main__":
    main()
