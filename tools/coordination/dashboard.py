#!/usr/bin/env python3
"""Coordination dashboard - a READ-ONLY human-readable view of a parallel port, joining the
generated TRACE, the dependency map, and the claim refs by work-item id. This is what
Ptah-Orchestrator (the orchestrator agent) RUNS to report status; it computes nothing authoritative and writes nothing
(references/team-coordination.md "The dashboard"; parallel-phase-2.md the orchestrator's report).

It FAILS CLOSED, because the human and Ptah-Orchestrator make scheduling decisions from it: a piece is shown
"ready to claim" ONLY when it is self-serve-eligible (re-checked locally, not merely trusted from
the map), unclaimed, present in TRACE, and every proven dependency is integrated. Anything
missing, malformed, ambiguous, guarded, or reserved is reported as such - never as ready. A
present-but-malformed artifact makes the whole report UNRELIABLE (the ready-set is suppressed and
the exit code is 2); only a truly-absent substrate is a clean "nothing to report".

It DEGRADES gracefully and is HONEST about what it knows: an artifact-health line states whether
each input is present, absent, or malformed, and staleness/needs-rebase is explicitly noted as
not modeled here (it is enforced by the gate's commit-binding, not derived in this view).

Sources (all optional; defaults to the conventional locations):
  --trace FILE        generated canonical TRACE        (default port/TRACE.yaml)
  --map FILE          dependency map                   (default tools/scoping/dependency-map.yaml)
  --claims-dir DIR    claim files <id>.yaml            (default: the pushed refs/claims/* refs)

Exit: 0 a trustworthy report (substrate present or absent); 2 UNRELIABLE (a present artifact is
malformed, or PyYAML is missing).
"""
import argparse
import glob
import os
import subprocess
import sys
from typing import NoReturn

LIVE_CLAIM = ("created", "active")
CLAIM_STATES = ("created", "active", "stale")


def _fail(msg) -> "NoReturn":
    sys.stderr.write("dashboard: " + msg + "\n")
    sys.exit(2)


def _repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def _strict_loader(yaml):
    """A SafeLoader that REJECTS duplicate mapping keys (a duplicate key is corruption, so the
    artifact is treated as malformed rather than silently keeping the last value)."""
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


def _s(v, dash="-"):
    return dash if v is None or (isinstance(v, str) and v.strip() == "") else str(v)


def _load(path, yaml, loader):
    """(state, data): 'absent' if the file is missing, 'malformed' if it does not parse to a
    mapping, else 'ok'."""
    if not os.path.isfile(path):
        return ("absent", {})
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.load(fh, Loader=loader)
    except (OSError, yaml.YAMLError):
        return ("malformed", {})
    if not isinstance(data, dict):
        return ("malformed", {})
    return ("ok", data)


def load_trace(path, yaml, loader):
    state, data = _load(path, yaml, loader)
    if state != "ok":
        return (state, {})
    files = data.get("files")
    if files is not None and not isinstance(files, list):
        return ("malformed", {})
    out = {}
    for row in (files or []):
        if not isinstance(row, dict):
            return ("malformed", {})
        rid = _s(row.get("id"), "")
        if rid:
            out[rid] = {"status": row.get("status"), "gate_tier": row.get("gate_tier"),
                        "review": row.get("review"), "integration": row.get("integration")}
    return ("ok", out)


def load_map(path, yaml, loader):
    state, data = _load(path, yaml, loader)
    if state != "ok":
        return (state, {}, [], [])
    nodes, edges, surfaces = {}, [], []
    for key in ("nodes", "edges", "owned_surfaces"):
        v = data.get(key)
        if v is not None and (not isinstance(v, list) or any(not isinstance(x, dict) for x in v)):
            return ("malformed", {}, [], [])
    for n in (data.get("nodes") or []):
        rid = _s(n.get("id"), "")
        if rid:
            nodes[rid] = n
    edges = [e for e in (data.get("edges") or [])]
    surfaces = [s for s in (data.get("owned_surfaces") or [])]
    return ("ok", nodes, surfaces, edges)


def load_claims(claims_dir, yaml, loader):
    """(state, {ref_id: {claimant, state, mismatch}}). Keyed by the ref/file id (the item the
    claim reserves); a claim whose internal id differs is flagged `mismatch`, not silently
    re-keyed. A malformed claim makes the claim set malformed (fail closed - we cannot be sure
    what is reserved)."""
    out = {}
    if claims_dir is not None:
        if not os.path.isdir(claims_dir):
            return ("absent", out)
        paths = sorted(glob.glob(os.path.join(claims_dir, "*.yaml")))
        if not paths:
            return ("absent", out)
        for p in paths:
            ref_id = os.path.splitext(os.path.basename(p))[0]
            try:
                with open(p, encoding="utf-8") as fh:
                    c = yaml.load(fh, Loader=loader)
            except (OSError, yaml.YAMLError):
                return ("malformed", out)
            if not isinstance(c, dict):
                return ("malformed", out)
            out[ref_id] = {"claimant": c.get("claimant"), "state": c.get("state"),
                           "mismatch": _s(c.get("id"), ref_id) != ref_id}
        return ("ok", out)
    try:
        raw = subprocess.check_output(
            ["git", "for-each-ref", "--format=%(refname) %(objecttype)", "refs/claims/"],
            stderr=subprocess.DEVNULL).decode()
    except Exception:
        return ("absent", out)
    refs = [ln for ln in raw.splitlines() if ln.strip()]
    if not refs:
        return ("absent", out)
    for line in refs:
        refname, _, objtype = line.strip().partition(" ")
        ref_id = refname[len("refs/claims/"):]
        if objtype.strip() != "blob":
            return ("malformed", out)
        try:
            blob = subprocess.check_output(["git", "cat-file", "blob", refname], stderr=subprocess.DEVNULL)
            c = yaml.load(blob, Loader=loader)
        except Exception:
            return ("malformed", out)
        if not isinstance(c, dict):
            return ("malformed", out)
        out[ref_id] = {"claimant": c.get("claimant"), "state": c.get("state"),
                       "mismatch": _s(c.get("id"), ref_id) != ref_id}
    return ("ok", out)


def _guard(wid, nodes, surfaces, edges):
    """(guarded, reasons, inconsistent): recompute the self-serve guard LOCALLY (fail closed)
    rather than trusting the map's self_serve_eligible flag alone."""
    n = nodes.get(wid)
    if n is None:
        return (True, ["no dependency-map node"], False)
    reasons = set()
    if _s(n.get("role")) == "owned":
        reasons.add("owned-foundation")
    if _s(n.get("coverage")) == "partial":
        reasons.add("coverage-partial")
    for e in edges:
        if _s(e.get("from")) == wid and _s(e.get("confidence")) in ("suspected", "unknown"):
            reasons.add("suspected-or-unknown-coupling")
    for s in surfaces:
        if s.get("owner") in (None, "", "null") and wid in [_s(d) for d in (s.get("dependents") or [])]:
            reasons.add("shared-surface:" + _s(s.get("name")))
    for r in (n.get("guarded_reasons") or []):
        reasons.add(_s(r))
    map_eligible = n.get("self_serve_eligible") is True
    locally_clean = len(reasons) == 0
    inconsistent = map_eligible != locally_clean  # the map and our local recompute disagree
    if inconsistent:
        reasons.add("map-inconsistency")
    guarded = (not map_eligible) or (not locally_clean)
    return (guarded, sorted(reasons), inconsistent)


def _table(headers, rows):
    widths = [len(h) for h in headers]
    for r in rows:
        for i, cell in enumerate(r):
            widths[i] = max(widths[i], len(cell))
    out = ["  " + "  ".join(h.ljust(widths[i]) for i, h in enumerate(headers)),
           "  " + "  ".join("-" * widths[i] for i in range(len(headers)))]
    for r in rows:
        out.append("  " + "  ".join(r[i].ljust(widths[i]) for i in range(len(headers))))
    return "\n".join(out)


def _claim_label(claim):
    return "-" if not claim else "%s(%s)" % (_s(claim.get("claimant")), _s(claim.get("state")))


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--trace", default=None)
    ap.add_argument("--map", default=None)
    ap.add_argument("--claims-dir", default=None)
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
        _fail("PyYAML not available - cannot read the coordination artifacts (install pyyaml)")
    loader = _strict_loader(yaml)

    t_state, trace = load_trace(resolve(args.trace, os.path.join("port", "TRACE.yaml")), yaml, loader)
    m_state, nodes, surfaces, edges = load_map(
        resolve(args.map, os.path.join("tools", "scoping", "dependency-map.yaml")), yaml, loader)
    c_state, claims = load_claims(resolve(args.claims_dir, None) if args.claims_dir else None, yaml, loader)

    print("Coordination dashboard  (read-only; derived from TRACE + dependency map + claims)")
    print("  Artifact health: TRACE %s, dependency map %s, claims %s." % (t_state, m_state, c_state))

    unreliable = "malformed" in (t_state, m_state, c_state)
    if not unreliable and not trace and not nodes and not claims:
        print("  Coordination substrate not present yet - nothing to report (solo / pre-Phase-0,")
        print("  or an empty skeleton).")
        sys.exit(0)

    ids = sorted(set(trace) | set(nodes) | set(claims))
    print("  %d work item(s); %d owned surface(s); %d dependency edge(s)." % (len(ids), len(surfaces), len(edges)))
    print()

    rows = []
    for wid in ids:
        t = trace.get(wid) or {}
        n = nodes.get(wid) or {}
        elig = n.get("self_serve_eligible")
        rows.append([wid, _s(t.get("status")), _s(n.get("role")),
                     ("yes" if elig is True else "no" if elig is False else "-"),
                     _claim_label(claims.get(wid)), _s(t.get("gate_tier")),
                     ("yes" if _s(t.get("review"), "") else "-"), _s(t.get("integration"))])
    print("Work items")
    print(_table(["id", "status", "role", "self-serve", "claim", "gate", "review", "integ"], rows))
    print()

    if unreliable:
        bad = [name for name, st in (("TRACE", t_state), ("map", m_state), ("claims", c_state)) if st == "malformed"]
        print("Ready set: SUPPRESSED - %s malformed; this report is UNRELIABLE. Regenerate the"
              % ", ".join(bad))
        print("  artifact(s) and re-run before using this to schedule work.")
        sys.exit(2)

    # Cross-id sanity warnings (a piece that exists in only one artifact, or a misfiled claim).
    warns = []
    for wid in ids:
        where = [w for w, present in (("TRACE", wid in trace), ("map", wid in nodes), ("claim", wid in claims)) if present]
        if nodes and trace and wid in nodes and wid not in trace:
            warns.append("%s: in the map but not TRACE" % wid)
        if claims.get(wid, {}).get("mismatch"):
            warns.append("%s: claim file's internal id does not match the ref/file name" % wid)

    integrated = {wid for wid, t in trace.items() if _s(t.get("integration")) == "integrated"}
    deps_of = {}
    for e in edges:
        frm, to = _s(e.get("from"), ""), _s(e.get("to"), "")
        if frm and to and _s(e.get("confidence")) == "proven":
            deps_of.setdefault(frm, set()).add(to)

    ready, in_prog, needs_triage, blocked, guarded, unsafe = [], [], [], [], [], []
    for wid in ids:
        claim = claims.get(wid)
        g_is, g_reasons, _inc = _guard(wid, nodes, surfaces, edges)
        if claim:
            st = _s(claim.get("state"))
            if st in LIVE_CLAIM:
                if g_is:
                    unsafe.append("%s -> %s [GUARDED: %s]" % (wid, _claim_label(claim), ", ".join(g_reasons)))
                else:
                    in_prog.append("%s -> %s" % (wid, _claim_label(claim)))
            elif st == "stale":
                needs_triage.append("%s -> %s (stale claim - triage; never auto-freed)" % (wid, _claim_label(claim)))
            else:
                needs_triage.append("%s -> %s (claim state '%s' is not valid)" % (wid, _claim_label(claim), st))
            continue
        if wid not in nodes:
            needs_triage.append("%s (no dependency-map node - cannot assess)" % wid)
            continue
        if g_is:
            guarded.append("%s (%s)" % (wid, ", ".join(g_reasons)))
            continue
        if not trace or wid not in trace:
            blocked.append("%s (no TRACE row - status unknown)" % wid)
            continue
        unmet = sorted(d for d in deps_of.get(wid, set()) if d not in integrated)
        if unmet:
            blocked.append("%s (waiting on: %s)" % (wid, ", ".join(unmet)))
        else:
            ready.append(wid)

    print("Ready set  (fail-closed: only unclaimed, eligible, fully-integrated-deps pieces are ready)")
    print("  ready to claim : %s" % (", ".join(ready) if ready else "(none)"))
    print("  in progress    : %s" % ("; ".join(in_prog) if in_prog else "(none)"))
    print("  blocked on deps: %s" % ("; ".join(blocked) if blocked else "(none)"))
    print("  guarded        : %s" % ("; ".join(guarded) if guarded else "(none)"))
    print("  needs triage   : %s" % ("; ".join(needs_triage) if needs_triage else "(none)"))
    if unsafe:
        print("  UNSAFE claims  : %s" % "; ".join(unsafe))
    print()

    conf = {"proven": 0, "suspected": 0, "unknown": 0}
    for e in edges:
        c = _s(e.get("confidence"), "")
        if c in conf:
            conf[c] += 1
    partial = sorted(wid for wid, n in nodes.items() if _s(n.get("coverage")) == "partial")
    eligible = sum(1 for n in nodes.values() if n.get("self_serve_eligible") is True)
    print("Coverage / ramp")
    print("  edges: %d proven, %d suspected, %d unknown" % (conf["proven"], conf["suspected"], conf["unknown"]))
    print("  nodes: %d self-serve-eligible of %d; %d with partial coverage%s"
          % (eligible, len(nodes), len(partial), (" (" + ", ".join(partial) + ")") if partial else ""))
    if surfaces:
        print("  owned surfaces: %s"
              % ", ".join("%s[owner %s]" % (_s(s.get("name")), _s(s.get("owner"), "UNASSIGNED")) for s in surfaces))
    print("  staleness/needs-rebase: not modeled in this view (enforced by the gate's commit-binding).")
    if warns:
        print()
        print("Warnings")
        for w in warns:
            print("  - %s" % w)
    sys.exit(0)


if __name__ == "__main__":
    main()
