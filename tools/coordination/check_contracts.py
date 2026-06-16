#!/usr/bin/env python3
"""Verify interface contracts between work items: a consumer gates against a GATED producer's
contract version, and is STALE when the producer's contract advances past it.

references/team-coordination.md ("Interface contracts and foundation-change invalidation"): two
independently gated modules can each pass their own gate while encoding conflicting assumptions
about a shared seam (layout, units, indexing, halos, init order, precision, IO schema) - a silent
semantic conflict no merge conflict and no per-piece gate catches. The methodology's answer:
VERSIONED interface contracts, enforced producer-before-consumer (a consumer gates against a
GATED producer's contract version, not a moving target), and because gate evidence is
commit-bound, a consumer goes STALE the moment its producer's contract advances. This checks that
over the per-work-item fragments.

Per fragment (port/status/<id>.yaml): `provides_contract` is "<name>@<version>" (or null) and
`consumes_contracts` is a list of "<name>@<version>". The check requires:
  - each contract name is provided by EXACTLY ONE fragment (>1 == a fork; duplicate work-item ids
    are rejected so a fork cannot hide behind a shared id);
  - a consumer never satisfies its OWN provided contract (producer-before-consumer needs two
    distinct work items);
  - the producer is GATED (status: gated);
  - the consumed version EXACTLY equals the producer's current version (string equality on a
    canonical version) - a consumer behind is STALE, a consumer ahead names a version that does
    not exist;
  - a consumer that `depends_on` a contract-providing foundation also CONSUMES that contract;
  - a consumer with a PROVEN dependency-map edge to a contract producer CONSUMES that producer's
    contract once it is started (in-progress/gated) - the map is ground truth, so a fragment
    cannot dodge producer-before-consumer by omitting the dependency from its self-reported list.

Versions are CANONICAL dotted non-negative integers with no leading zeros (`2`, `1.2`, `1.10`);
anything else (`02`, `2.00`, `1-alpha`) is malformed (RED), so spelling can never alias two
versions into looking equal. `_ver_key` orders canonical versions for the stale-vs-ahead wording
only; satisfaction itself is exact string equality.

Reads port/status/*.yaml (or --status-dir) and the dependency map (--map, default
tools/scoping/dependency-map.yaml) for the proven-edge cross-check; before fragments exist there
is nothing to check.
Usage:  check_contracts.py [--status-dir DIR] [--map FILE]
Exit:   0 every contract resolves (or no fragments); 1 a contract violation; 2 UNRELIABLE.
"""
import argparse
import glob
import os
import re
import subprocess
import sys
from typing import NoReturn

VERSION_RE = re.compile(r"^(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*))*$")


def _fail(msg) -> "NoReturn":
    sys.stderr.write("check-contracts: " + msg + "\n")
    sys.exit(2)


def _repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def _strict_loader(yaml):
    """A SafeLoader that REJECTS duplicate mapping keys (so a second `provides_contract:` cannot
    quietly override a bad first one)."""
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


def _fragment_paths(status_dir):
    return sorted(p for p in glob.glob(os.path.join(status_dir, "*.yaml"))
                  if os.path.basename(p) != "_meta.yaml")


def parse_contract(s):
    """'<name>@<version>' -> (name, version) with a CANONICAL version, or None if malformed."""
    if not isinstance(s, str) or s.count("@") != 1:
        return None
    name, version = (part.strip() for part in s.split("@", 1))
    if not name or not VERSION_RE.match(version):
        return None
    return (name, version)


def _ver_key(version) -> "tuple[int, ...]":
    """Order canonical (dotted-integer) versions for diagnostics only: 2 < 10, 1.2 < 1.10."""
    return tuple(int(p) for p in str(version).split("."))


def verify(fragments, proven_edges=None):
    """fragments: [(id, status, provides_raw, consumes_list, depends_on_list)]. proven_edges:
    [(consumer_id, producer_id)] - proven SOURCE dependencies from the dependency map. Returns
    violation strings (empty == ok)."""
    v = []
    ids = [fid for fid, _st, _p, _c, _d in fragments]
    status_by = {fid: str(st) for fid, st, _p, _c, _d in fragments}
    consumed_by = {}
    for dup in sorted({x for x in ids if ids.count(x) > 1}):
        v.append("duplicate work-item id '%s' across fragments" % dup)

    # Producer index: name -> [(version, owner_id, status)]; provides_by: id -> (name, version).
    producers, provides_by = {}, {}
    for fid, status, provides, _c, _d in fragments:
        if provides is None:
            continue
        pc = parse_contract(provides)
        if pc is None:
            v.append("%s: provides_contract '%s' is not a valid '<name>@<version>' (canonical "
                     "dotted-integer version, no leading zeros)" % (fid, provides))
            continue
        producers.setdefault(pc[0], []).append((pc[1], fid, str(status)))
        provides_by[fid] = pc
    forked = set()
    for name, plist in sorted(producers.items()):
        if len(plist) > 1:
            forked.add(name)
            v.append("contract '%s' is provided by multiple fragments (%s) - one owner per contract"
                     % (name, ", ".join(sorted(pid for _vv, pid, _st in plist))))

    for fid, _status, _provides, consumes, depends_on in fragments:
        consumed_names = set()
        for raw in (consumes or []):
            cc = parse_contract(raw)
            if cc is None:
                v.append("%s: consumes_contracts entry '%s' is not a valid '<name>@<version>' "
                         "(canonical dotted-integer version, no leading zeros)" % (fid, raw))
                continue
            cname, cver = cc
            consumed_names.add(cname)
            if cname not in producers:
                v.append("%s: consumes '%s' but no work item provides contract '%s'" % (fid, raw, cname))
                continue
            if cname in forked:
                v.append("%s: consumes '%s' but contract '%s' is forked (multiple providers) - "
                         "resolve the fork first" % (fid, raw, cname))
                continue
            pver, pid, pstatus = producers[cname][0]
            if pid == fid:
                v.append("%s: consumes '%s' which it also provides - a work item cannot satisfy "
                         "its own contract (producer-before-consumer)" % (fid, raw))
                continue
            if pstatus != "gated":
                v.append("%s: consumes '%s' but its producer '%s' is not gated (status: %s) - "
                         "producer-before-consumer" % (fid, raw, pid, pstatus))
            if cver != pver:
                if _ver_key(cver) < _ver_key(pver):
                    v.append("%s: consumes '%s@%s' but producer '%s' now provides '%s@%s' - STALE, "
                             "re-gate the consumer against the current contract"
                             % (fid, cname, cver, pid, cname, pver))
                else:
                    v.append("%s: consumes '%s@%s' but producer '%s' provides only '%s@%s' - that "
                             "version does not exist" % (fid, cname, cver, pid, cname, pver))
        for dep in (depends_on or []):
            dpc = provides_by.get(str(dep))
            if dpc and dpc[0] not in consumed_names:
                v.append("%s: depends_on '%s' which provides contract '%s@%s', but consumes no '%s' "
                         "contract - gate against the foundation's contract" % (fid, dep, dpc[0], dpc[1], dpc[0]))
        consumed_by[fid] = consumed_names

    # C7 - a PROVEN SOURCE dependency (from the dependency map) on a contract-producer must be
    # consumed by a STARTED consumer, even if the fragment's self-reported depends_on omits it: the
    # map is ground truth, so producer-before-consumer cannot be skipped by under-declaring deps.
    for consumer, producer in (proven_edges or []):
        pc = provides_by.get(producer)
        if pc is None or status_by.get(consumer) not in ("in-progress", "gated"):
            continue
        if pc[0] not in consumed_by.get(consumer, set()):
            v.append("%s: has a proven SOURCE dependency on '%s' (per the dependency map) which "
                     "provides contract '%s@%s', but does not consume it - producer-before-consumer"
                     % (consumer, producer, pc[0], pc[1]))
    return list(dict.fromkeys(v))


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--status-dir", default=None)
    ap.add_argument("--map", default=None)
    args = ap.parse_args()

    orig = os.getcwd()
    root = _repo_root()
    try:
        os.chdir(root)
    except OSError:
        _fail("cannot enter repo root '%s'" % root)

    if args.status_dir is not None:
        status_dir = args.status_dir if os.path.isabs(args.status_dir) else os.path.join(orig, args.status_dir)
        if not os.path.isdir(status_dir):
            _fail("--status-dir '%s' is not a directory" % args.status_dir)
    else:
        status_dir = os.path.join("port", "status")

    paths = _fragment_paths(status_dir)
    if not paths:
        print("check-contracts: no fragments under '%s' - nothing to check (skipping)." % status_dir)
        sys.exit(0)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse fragments (install pyyaml)")
    loader = _strict_loader(yaml)

    fragments, fails = [], 0
    for p in paths:
        try:
            with open(p, encoding="utf-8") as fh:
                frag = yaml.load(fh, Loader=loader)
        except OSError as exc:
            _fail("cannot read fragment '%s' (%s)" % (p, exc))
        except yaml.YAMLError as exc:
            print("  [FAIL] %s: not valid YAML (%s)" % (os.path.basename(p), exc))
            fails += 1
            continue
        if not isinstance(frag, dict):
            print("  [FAIL] %s: fragment is not a mapping" % os.path.basename(p))
            fails += 1
            continue
        fid = str(frag.get("id") or os.path.splitext(os.path.basename(p))[0])
        consumes = frag.get("consumes_contracts")
        if consumes is not None and not isinstance(consumes, list):
            print("  [FAIL] %s: consumes_contracts must be a list" % fid)
            fails += 1
            consumes = []
        depends_on = frag.get("depends_on")
        if depends_on is not None and not isinstance(depends_on, list):
            print("  [FAIL] %s: depends_on must be a list" % fid)
            fails += 1
            depends_on = []
        fragments.append((fid, frag.get("status"), frag.get("provides_contract"),
                          consumes or [], depends_on or []))

    if args.map:
        map_path = args.map if os.path.isabs(args.map) else os.path.join(orig, args.map)
    else:
        map_path = os.path.join("tools", "scoping", "dependency-map.yaml")
    proven_edges = None
    if os.path.isfile(map_path):
        try:
            with open(map_path, encoding="utf-8") as fh:
                dep = yaml.load(fh, Loader=loader)
        except (OSError, yaml.YAMLError) as exc:
            _fail("cannot read dependency map '%s' (%s)" % (map_path, exc))
        if isinstance(dep, dict) and isinstance(dep.get("edges"), list):
            proven_edges = [(str(e.get("from")), str(e.get("to"))) for e in dep["edges"]
                            if isinstance(e, dict) and str(e.get("confidence")) == "proven"]

    for msg in verify(fragments, proven_edges):
        print("  [FAIL] %s" % msg)
        fails += 1

    print("check-contracts: checked %d fragment(s); %d violation(s)." % (len(paths), fails))
    if fails:
        print("RESULT: RED (exit 1) - a contract does not resolve, its producer is not gated, or a consumer is stale.")
        sys.exit(1)
    print("RESULT: GREEN (exit 0) - every consumed contract is provided by a gated producer at the current version.")
    sys.exit(0)


if __name__ == "__main__":
    main()
