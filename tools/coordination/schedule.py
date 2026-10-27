#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""schedule.py - the build schedule of the units left to port: which can be built at the same time,
and in which order.

It reads the dependency map (tools/scoping/dependency-map.yaml) and the TRACE, leaves out the units
already integrated or excluded, and works on the rest with networkx:

  - CYCLES. Units that depend on each other, directly or through others (a strongly connected
    component), never become ready one at a time: they are ported and proven together, as one
    assembly (references/two-repo-architecture.md, "Assembly-proven deliverables").
  - WAVES. The topological generations of the graph, each cycle taken as one node. A unit in a wave
    depends only on units in earlier waves or already integrated, so a whole wave can be built at
    the same time. The first wave is what is ready now, claims and guards aside.
  - PRIORITY. A unit's remaining chain is its own size plus the longest chain of units waiting on it;
    the size is its SOURCE line count (--weight units counts each unit as 1). The longest chain is
    the critical path, which sets how long the port takes, so its units go first. Ties go to the
    unit more units wait on, then to the id.

The autodrive planner orders its actions by this priority and names the cycles. A dependency on a
unit neither the map nor the TRACE knows is listed: it can never be met, so the unit waiting on it
never becomes ready.

Usage: schedule.py [--trace FILE] [--map FILE] [--weight lines|units] [--json]
Exit:  0 printed; 2 UNRELIABLE (a malformed artifact, or PyYAML or networkx missing).
"""
import argparse
import json
import os
import sys

import dashboard as D


def _fail(msg):
    print("schedule: %s (UNRELIABLE)" % msg, file=sys.stderr)
    sys.exit(2)


def sizes(map_path, nodes, yaml, loader):
    """{unit id: SOURCE line count}, read from each map node's `source` under the map's
    `source_root`; a unit whose file cannot be read counts 1."""
    try:
        root = (yaml.load(open(map_path, encoding="utf-8"), Loader=loader) or {}).get("source_root") or ""
    except (OSError, ValueError, AttributeError, yaml.YAMLError):
        root = ""
    out = {}
    for uid, n in nodes.items():
        try:
            with open(os.path.join(str(root), D._s(n.get("source"), "")), encoding="utf-8", errors="replace") as f:
                out[uid] = max(1, sum(1 for _ in f))
        except OSError:
            out[uid] = 1
    return out


def compute(trace, nodes, edges, size=None):
    """The schedule as a dict: cycles, waves, critical_path (a list of groups), critical_size,
    priority (every unit left, first to last) and unknown ({unit: [missing dependencies]})."""
    import networkx as nx
    size = size or {}
    done = {u for u, t in trace.items() if D._s(t.get("integration"), "") == "integrated"}
    gone = {u for u, t in trace.items() if D._s(t.get("status"), "") == "excluded"}
    known = set(trace) | set(nodes)
    g = nx.DiGraph()
    g.add_nodes_from(sorted(known - done - gone))
    unknown = {}
    for e in edges:
        frm, to = D._s(e.get("from"), ""), D._s(e.get("to"), "")
        if not frm or not to or frm == to or frm not in g or D._s(e.get("confidence"), "") != "proven":
            continue
        if to in g:
            g.add_edge(to, frm)          # `to` is built before `frm`, which uses it
        elif to not in known:
            unknown.setdefault(frm, set()).add(to)

    c = nx.condensation(g)
    members = {n: sorted(c.nodes[n]["members"]) for n in c}
    chain = {}
    for n in reversed(list(nx.topological_sort(c))):
        own = sum(size.get(u, 1) for u in members[n])
        chain[n] = own + max((chain[s] for s in c.successors(n)), default=0)
    waiting = {n: sum(len(members[d]) for d in nx.descendants(c, n)) for n in c}

    def first(n):
        return (-chain[n], -waiting[n], members[n][0])

    path, n = [], min((h for h in c if c.in_degree(h) == 0), key=first, default=None)
    while n is not None:
        path.append(members[n])
        n = min(c.successors(n), key=first, default=None)
    return {
        "cycles": sorted(members[n] for n in c if len(members[n]) > 1),
        "waves": [sorted(u for n in gen for u in members[n]) for gen in nx.topological_generations(c)],
        "critical_path": path,
        "critical_size": sum(sum(size.get(u, 1) for u in grp) for grp in path),
        "priority": [u for n in sorted(c, key=first) for u in members[n]],
        "unknown": {u: sorted(v) for u, v in sorted(unknown.items())},
    }


def main():
    ap = argparse.ArgumentParser(description="The build schedule of the units left to port.")
    ap.add_argument("--trace", default=None)
    ap.add_argument("--map", default=None)
    ap.add_argument("--weight", choices=("lines", "units"), default="lines")
    ap.add_argument("--json", action="store_true", help="print the schedule as JSON")
    args = ap.parse_args()
    orig = os.getcwd()
    try:
        os.chdir(D._repo_root())
    except OSError:
        _fail("cannot enter the repo root")

    def resolve(p, default_rel):
        return default_rel if p is None else (p if os.path.isabs(p) else os.path.join(orig, p))

    try:
        import yaml
        import networkx  # noqa: F401  (compute needs it; fail early with a clear message)
    except ImportError as e:
        _fail("%s is not available - run the tools with `uv run`" % e.name)
    loader = D._strict_loader(yaml)
    map_path = resolve(args.map, os.path.join("tools", "scoping", "dependency-map.yaml"))
    t_state, trace = D.load_trace(resolve(args.trace, os.path.join("port", "TRACE.yaml")), yaml, loader)
    m_state, nodes, _surfaces, edges = D.load_map(map_path, yaml, loader)
    if "malformed" in (t_state, m_state):
        _fail("the %s is malformed" % ("TRACE" if t_state == "malformed" else "dependency map"))
    size = sizes(map_path, nodes, yaml, loader) if args.weight == "lines" else {}
    s = compute(trace, nodes, edges, size)
    if args.json:
        print(json.dumps(s, indent=2))
        return 0

    left = len(s["priority"])
    unit = "lines" if args.weight == "lines" else "units"
    print("build schedule  (read-only; from the dependency map and the TRACE)")
    if m_state != "ok":
        print("  no dependency map yet: nothing orders the units, so they all fall in one wave")
    if not left:
        print("  nothing left to port")
        return 0
    print("  %d unit(s) left in %d wave(s); the widest wave has %d; the critical path is %d %s"
          % (left, len(s["waves"]), max(len(w) for w in s["waves"]), s["critical_size"], unit))
    if s["cycles"]:
        print("\ncycles - each is ported and proven as one assembly:")
        for cyc in s["cycles"]:
            print("  " + ", ".join(cyc))
    print("\nwaves - a wave can be built at the same time, after the waves before it:")
    for i, w in enumerate(s["waves"], 1):
        print("  %2d  %s" % (i, ", ".join(w)))
    print("\ncritical path: " + " -> ".join("+".join(grp) for grp in s["critical_path"]))
    print("priority (first to last): " + ", ".join(s["priority"]))
    for u, missing in s["unknown"].items():
        print("never ready: %s depends on %s, which neither the map nor the TRACE knows"
              % (u, ", ".join(missing)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
