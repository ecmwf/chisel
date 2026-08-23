#!/usr/bin/env python3
"""Extract the SOURCE dependency map from a Fortran source tree - the ROBUST core only.

The map gives the planner its foundation-first ORDERING and feeds two conformance gates: the file
INVENTORY (one node per source unit) is check-completeness's independent SOURCE accounting, and the
PROVEN in-tree use/call edges are check-contracts' producer->consumer cross-check. It also marks the
STRUCTURAL surfaces a line scan resolves unambiguously: a module USEd by >=2 units is an owned
foundation; a common block shared by >=2 is a shared surface - both keep their units out of the
self-serve pool (a human/owner handles them).

It does NOT guess. A reference the line scan cannot resolve in-tree draws NO edge and NO guard - the
extractor never invents a coupling it could not prove. The conservatism that used to come from those
guesses now comes from the real net: a unit wrongly ported in isolation fails its R1 DIFFERENTIAL gate
or the INDEPENDENT review. So the map carries only what a resolved `USE foo` / `CALL bar` / `COMMON
/blk/` states unambiguously - it is deterministic and drift-checkable, with nothing fragile to clear.

The map is GENERATED, never hand-maintained. The generic framework lives here (methodology,
tools/coordination/); the per-project map it produces is project data (tools/scoping/).

Usage:
  extract_dependencies.py [--source-root DIR]                     print the generated map
  extract_dependencies.py --check [--map FILE] [--source-root DIR] drift-check a committed map
  extract_dependencies.py --owned-surfaces [--source-root DIR]    list owned-surface SOURCE paths
                                                                  (for check-claims --owned-surfaces)
Exit (--check): 0 the committed map matches SOURCE (or there is none yet); 1 DRIFT/malformed; 2 UNRELIABLE.
"""
import argparse
import fnmatch
import glob
import os
import re
import subprocess
import sys
from typing import NoReturn
from _chisel_lib import strict_loader as _strict_loader, repo_root as _repo_root

FORT_EXTS = (".f90", ".f95", ".f03", ".f08", ".f", ".for", ".ftn")
RE_END = re.compile(r"^\s*end\b", re.I)
RE_MODULE = re.compile(r"^\s*module\s+(\w+)", re.I)
RE_SUB = re.compile(r"\bsubroutine\s+(\w+)", re.I)
RE_FUNC = re.compile(r"\bfunction\s+(\w+)", re.I)
RE_PROG = re.compile(r"^\s*program\s+(\w+)", re.I)
RE_COMMON = re.compile(r"\bcommon\s*/\s*(\w+)\s*/", re.I)
# use NAME | use :: NAME | use, intrinsic :: NAME | use NAME, only: ...
RE_USE = re.compile(r"^\s*use\b(?:\s*,[^:]*::|\s*::)?\s*(\w+)", re.I)
RE_USE_INTRINSIC = re.compile(r"^\s*use\b\s*,\s*intrinsic\b", re.I)
RE_CALL = re.compile(r"\bcall\s+(\w+)", re.I)
RE_INC = re.compile(r"""^\s*#?\s*include\s+['"]([^'"]+)['"]""", re.I)
# A FUNCTION invocation in Fortran carries NO syntactic marker - `F(I)` is indistinguishable from
# array indexing or a statement function by shape alone. So a call graph built only from `CALL`
# sites is a SUBROUTINE-ONLY graph that silently drops every function-call edge. These two resolve
# the ambiguity the only way a line scan honestly can (see _function_call_targets).
RE_INVOKE = re.compile(r"\b(\w+)\s*\(")
# Names bound locally in this file: dummy arguments, and entities on the RHS of a `::` declaration.
# A local binding SHADOWS any same-named global FUNCTION, so it must suppress the edge.
RE_DUMMY_ARGS = re.compile(r"\b(?:subroutine|function)\s+\w+\s*\(([^)]*)\)", re.I)
RE_DECL_RHS = re.compile(r"::\s*([^!]*)")
RE_NAME = re.compile(r"\b[A-Za-z_]\w*")

# Intrinsic subroutines/modules - calls/uses of these are NOT dependencies, so no edge.
INTRINSIC_SUBS = frozenset((
    "cpu_time", "random_number", "random_seed", "date_and_time", "system_clock",
    "get_command", "get_command_argument", "get_environment_variable", "move_alloc",
    "mvbits", "execute_command_line", "abort", "backtrace", "flush", "exit", "getarg", "getenv",
))
INTRINSIC_MODS = frozenset((
    "iso_fortran_env", "iso_c_binding", "ieee_arithmetic", "ieee_features",
    "ieee_exceptions", "omp_lib", "omp_lib_kinds",
))
ALLOWED_TOP = {"schema_version", "source_root", "nodes", "owned_surfaces", "edges"}


def _locally_declared(code):
    """Names BOUND LOCALLY in this file: dummy arguments, plus entities declared after a `::`.

    Fortran resolves `W1(I)` against local scope first, so a local array or dummy named `W1`
    shadows any global FUNCTION of the same name. Without this, a bare-invocation scan pulls in
    whole unrelated modules through what is really an array subscript.

    This is a FILE-granularity heuristic, not a symbol table: a name declared in ANY scoping unit
    of the file suppresses the edge everywhere in that file. It is deliberately biased toward the
    FALSE NEGATIVE (a missed edge), because this extractor's contract is to emit only what it can
    prove - and a missed edge costs ordering conservatism, while a fabricated edge would corrupt
    the ready-set with coupling that does not exist.
    """
    names = set()
    for ln in code:
        for m in RE_DUMMY_ARGS.finditer(ln):
            names.update(a.strip().lower() for a in m.group(1).split(",") if a.strip())
        md = RE_DECL_RHS.search(ln)
        if md:
            names.update(n.group(0).lower() for n in RE_NAME.finditer(md.group(1)))
    return names


def _function_call_targets(ln, def_func, declared):
    """Names on this line that are BARE FUNCTION INVOCATIONS of an in-tree FUNCTION.

    Emits a name only when all of the following hold, so no edge is ever guessed:
      - it is followed by `(`                       (an invocation or a subscript)
      - it is a FUNCTION defined somewhere in-tree  (resolvable, per the no-guessing rule)
      - it is not bound locally in this file        (not shadowed by an array/dummy)
      - it is not the target of `CALL` on this line (that edge is already drawn as a call)
    """
    if not def_func:
        return ()
    called = {m.group(1).lower() for m in RE_CALL.finditer(ln)}
    out = []
    for m in RE_INVOKE.finditer(ln):
        name = m.group(1).lower()
        if name in def_func and name not in declared and name not in called:
            out.append(name)
    return out
ALLOWED_CONF = {"proven"}
ALLOWED_ROLE = {"owned", "unowned"}

# Coarse out-of-scope SOURCE paths (project-layer). A real SOURCE often ships MULTIPLE build
# variants that share file stems (e.g. a src_fortran/ vs a src_fortran_variant/, both defining the
# same kernel.F90). Only the LIVE subset is ported; the dependency map and TRACE cover that
# subset. Rather than list every dead-variant file as `status: excluded` (and collide on the shared
# stems), the dead variants are excluded COARSELY here - a few source_root-relative path prefixes or
# globs, each with a reason. The extractor never walks into them, so the map is the LIVE source tree
# (still an INDEPENDENT inventory, so check-completeness's map-vs-TRACE cross-check stays meaningful).
EXCLUDE_REL = os.path.join("tools", "scoping", "source-exclude.yaml")


def _fail(msg) -> "NoReturn":
    sys.stderr.write("extract-dependencies: " + msg + "\n")
    sys.exit(2)


def _strip_comment(line):
    """Strip a trailing free-form comment at the first '!' OUTSIDE a string. A naive cut at the
    first '!' would truncate `print *, "a!b"; call c()` inside the string literal and hide the
    `; call c()` after it - so track single/double-quote state and honor only an unquoted '!'."""
    q = None
    for i, ch in enumerate(line):
        if q is not None:
            if ch == q:
                q = None
        elif ch in ("'", '"'):
            q = ch
        elif ch == "!":
            return line[:i]
    return line


def _as_list(x):
    return x if isinstance(x, list) else []


def _load_excludes(root, yaml):
    """Read the committed coarse-exclusion list (tools/scoping/source-exclude.yaml) into a list of
    source_root-relative path prefixes/globs. Absent file -> [] (no exclusions). Malformed -> fail
    closed (an unreadable scoping policy must never silently widen the walk)."""
    path = os.path.join(root, EXCLUDE_REL)
    if not os.path.isfile(path):
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.load(fh, Loader=_strict_loader(yaml))
    except (OSError, yaml.YAMLError) as exc:
        _fail("cannot read source-exclude '%s' (%s)" % (EXCLUDE_REL, exc))
    if data is None:
        return []
    if not isinstance(data, dict) or (set(data) - {"exclude"}):
        _fail("source-exclude '%s' must be a mapping with only an 'exclude:' list" % EXCLUDE_REL)
    items = data.get("exclude") or []
    if not isinstance(items, list):
        _fail("source-exclude 'exclude' must be a list")
    pats = []
    for it in items:
        if not isinstance(it, dict) or "path" not in it:
            _fail("each source-exclude entry must be a mapping with a 'path' and a 'reason'")
        if not str(it.get("reason") or "").strip():
            _fail("source-exclude entry '%s' needs a non-empty 'reason'" % (it.get("path"),))
        p = str(it.get("path") or "").strip().strip("/")
        if p:
            pats.append(p)
    return pats


def _excluded(rel, pats):
    """True if the source_root-relative path `rel` is out of scope: an exact match, under an excluded
    subtree prefix, or matching an excluded glob."""
    for p in pats:
        if rel == p or rel.startswith(p + "/") or fnmatch.fnmatch(rel, p):
            return True
    return False


def _source_files(root, excludes=()):
    out = []
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        # Prune excluded directories so we never descend into a dead build variant.
        dirs[:] = [d for d in dirs
                   if not _excluded(os.path.relpath(os.path.join(dirpath, d), root).replace(os.sep, "/"), excludes)]
        for name in sorted(files):
            if os.path.splitext(name)[1].lower() in FORT_EXTS:
                rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
                if not _excluded(rel, excludes):
                    out.append(os.path.join(dirpath, name))
    return out


def extract(source_root, excludes=()):
    """Build the deterministic map data model from a Fortran tree under source_root. `excludes` are
    coarse out-of-scope path prefixes/globs (dead build variants) the walk skips, so the map is the
    LIVE source tree. Emits the file INVENTORY (one node per source unit), the PROVEN in-tree use/call
    edges, and the STRUCTURAL owned/shared surfaces (a module USEd by >=2 units is an owned foundation;
    a common block shared by >=2 is a shared surface). It does NOT guess: a reference the line scan
    cannot resolve in-tree draws no edge and no guard. Raises ValueError on a structural problem
    (duplicate file stem among the LIVE files) that must fail closed."""
    files = _source_files(source_root, excludes)
    def_module, def_proc, commons = {}, {}, {}
    nodes, node_modules, raw_by_node = {}, {}, {}
    def_func, declared_by_node = set(), {}
    for path in files:
        nid = os.path.splitext(os.path.basename(path))[0]
        rel = os.path.relpath(path, source_root).replace(os.sep, "/")
        if nid in nodes:
            raise ValueError("duplicate file stem '%s' (%s and %s) - node ids must be unique. If these "
                             "are sibling BUILD VARIANTS of one SOURCE (only one is ported), exclude the "
                             "dead variant(s) coarsely in tools/scoping/source-exclude.yaml so only the "
                             "LIVE subset is mapped" % (nid, nodes[nid], rel))
        nodes[nid] = rel
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                rawlines = fh.readlines()
        except OSError as exc:
            _fail("cannot read source '%s' (%s)" % (path, exc))
        code = [_strip_comment(ln) for ln in rawlines]
        raw_by_node[nid] = code
        node_modules[nid] = []
        for ln in code:
            if RE_END.match(ln):
                continue
            m = RE_MODULE.match(ln)
            if m and m.group(1).lower() != "procedure":
                def_module[m.group(1).lower()] = nid
                node_modules[nid].append("module:" + m.group(1).lower())
                continue
            ms = RE_SUB.search(ln)
            if ms:
                def_proc[ms.group(1).lower()] = nid
            mf = RE_FUNC.search(ln)
            if mf:
                def_proc[mf.group(1).lower()] = nid
                def_func.add(mf.group(1).lower())
            mp = RE_PROG.match(ln)
            if mp:
                def_proc[mp.group(1).lower()] = nid
        declared_by_node[nid] = _locally_declared(code)
        for ln in code:
            mc = RE_COMMON.search(ln)
            if mc:
                commons.setdefault(mc.group(1).lower(), set()).add(nid)

    edges = set()
    module_dependents = {}
    for nid in sorted(nodes):
        for ln in raw_by_node[nid]:
            mu = RE_USE.match(ln)
            if mu:
                tgt = mu.group(1).lower()
                if not (RE_USE_INTRINSIC.match(ln) or tgt in INTRINSIC_MODS):
                    owner = def_module.get(tgt)
                    if owner and owner != nid:
                        edges.add((nid, owner, "use", "proven"))
                        module_dependents.setdefault(tgt, set()).add(nid)
            mcall = RE_CALL.search(ln)
            if mcall:
                tgt = mcall.group(1).lower()
                if tgt not in INTRINSIC_SUBS:
                    owner = def_proc.get(tgt)
                    if owner and owner != nid:
                        edges.add((nid, owner, "call", "proven"))
            # Bare FUNCTION invocations carry no `CALL`, so they are invisible to the scan above.
            for tgt in _function_call_targets(ln, def_func, declared_by_node.get(nid, ())):
                if tgt not in INTRINSIC_SUBS:
                    owner = def_proc.get(tgt)
                    if owner and owner != nid:
                        edges.add((nid, owner, "call", "proven"))

    owned_surfaces, owned_nodes, shared_participants = [], set(), {}
    for mod, deps in sorted(module_dependents.items()):
        if len(deps) >= 2:
            owner = def_module.get(mod)
            owned_surfaces.append({"name": "module:" + mod, "owner": owner,
                                   "dependents": sorted(deps)})
            if owner:
                owned_nodes.add(owner)
    for blk, parts in sorted(commons.items()):
        if len(parts) >= 2:
            owned_surfaces.append({"name": "common:/%s/" % blk, "owner": None,
                                   "dependents": sorted(parts)})
            for nid in parts:
                shared_participants.setdefault(nid, []).append("common:/%s/" % blk)

    node_list = []
    for nid in sorted(nodes):
        role = "owned" if nid in owned_nodes else "unowned"
        reasons = set()
        if role == "owned":
            reasons.add("owned-foundation")
        for surf in shared_participants.get(nid, []):
            reasons.add("shared-surface:" + surf)
        node_list.append({"id": nid, "source": nodes[nid], "role": role,
                          "self_serve_eligible": len(reasons) == 0,
                          "guarded_reasons": sorted(reasons),
                          "coverage": "full",
                          "provides": sorted(node_modules.get(nid, []))})
    edge_list = [{"from": a, "to": b, "confidence": conf, "kind": kind}
                 for (a, b, kind, conf) in sorted(edges)]
    return {"schema_version": 1, "source_root": source_root,
            "nodes": node_list, "owned_surfaces": owned_surfaces, "edges": edge_list}


def _dump(model, yaml):
    class IndentDumper(yaml.Dumper):
        def increase_indent(self, flow=False, indentless=False):
            return super(IndentDumper, self).increase_indent(flow, False)
    return yaml.dump(model, Dumper=IndentDumper, sort_keys=False,
                     default_flow_style=False, indent=2, allow_unicode=True)


def _norm(m):
    """A comparison view (schema_version, nodes, owned_surfaces, edges), str-coerced and sorted
    so ordering and source_root spelling do not matter and a malformed value cannot crash it."""
    def node(n):
        return (str(n.get("id")), str(n.get("source")), str(n.get("role")),
                bool(n.get("self_serve_eligible")),
                tuple(sorted(str(r) for r in _as_list(n.get("guarded_reasons")))),
                str(n.get("coverage")),
                tuple(sorted(str(p) for p in _as_list(n.get("provides")))))
    def surf(s):
        return (str(s.get("name")), str(s.get("owner")),
                tuple(sorted(str(d) for d in _as_list(s.get("dependents")))))
    def edge(e):
        return (str(e.get("from")), str(e.get("to")), str(e.get("kind")), str(e.get("confidence")))
    return (m.get("schema_version"),
            sorted(node(n) for n in _as_list(m.get("nodes"))),
            sorted(surf(s) for s in _as_list(m.get("owned_surfaces"))),
            sorted(edge(e) for e in _as_list(m.get("edges"))))


def _validate_committed(m):
    """Schema violations of a committed map (beyond drift): unknown keys, bad enums, duplicate
    node ids, dangling edge targets. A generated map always passes; a hand-corrupted one is RED."""
    v = []
    for k in m:
        if k not in ALLOWED_TOP:
            v.append("unknown top-level key '%s'" % k)
    for req in ("schema_version", "source_root", "nodes", "edges"):
        if m.get(req) is None:
            v.append("missing required top-level key '%s'" % req)
    for key in ("nodes", "owned_surfaces", "edges"):
        val = m.get(key)
        if val is not None and (not isinstance(val, list) or any(not isinstance(x, dict) for x in val)):
            v.append("'%s' must be a list of mappings" % key)
    if v:
        return v
    ids = [str(n.get("id")) for n in _as_list(m.get("nodes"))]
    for d in sorted({x for x in ids if ids.count(x) > 1}):
        v.append("duplicate node id '%s'" % d)
    for n in _as_list(m.get("nodes")):
        if n.get("role") not in ALLOWED_ROLE:
            v.append("node '%s' has invalid role %r" % (n.get("id"), n.get("role")))
    idset = set(ids)
    for e in _as_list(m.get("edges")):
        if e.get("confidence") not in ALLOWED_CONF:
            v.append("edge %s->%s has invalid confidence %r"
                     % (e.get("from"), e.get("to"), e.get("confidence")))
        to = str(e.get("to"))
        if to not in idset:
            v.append("edge target '%s' is not a node (every edge resolves to an in-tree node)" % to)
    return v


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--source-root", default=None)
    ap.add_argument("--map", default=None)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--owned-surfaces", action="store_true", dest="owned")
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

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot emit/parse the map (install pyyaml)")

    if args.check:
        if not os.path.isfile(map_path):
            if args.map is not None:
                _fail("--map '%s' is not a file" % args.map)
            print("check-depmap: no committed map at tools/scoping/dependency-map.yaml - "
                  "nothing to check (skipping).")
            sys.exit(0)
        try:
            with open(map_path, encoding="utf-8") as fh:
                committed = yaml.load(fh, Loader=_strict_loader(yaml))
        except (OSError, yaml.YAMLError) as exc:
            _fail("cannot read committed map '%s' (%s)" % (map_path, exc))
        if not isinstance(committed, dict):
            print("check-depmap: committed map '%s' is not a mapping." % map_path, file=sys.stderr)
            print("RESULT: RED (exit 1) - the committed map is malformed; regenerate it.", file=sys.stderr)
            sys.exit(1)
        schema_v = _validate_committed(committed)
        if schema_v:
            for msg in schema_v:
                print("  [FAIL] %s" % msg, file=sys.stderr)
            print("RESULT: RED (exit 1) - the committed map is malformed; regenerate it.", file=sys.stderr)
            sys.exit(1)
        # The source root to extract from: --source-root wins; else the committed map's. If both
        # are known and disagree, that is itself drift (a map pointing at the wrong tree).
        committed_src = committed.get("source_root")
        src = args.source_root if args.source_root is not None else committed_src
        if not src:
            _fail("committed map has no source_root and --source-root was not given")
        src_abs = src if os.path.isabs(src) else os.path.join(orig if args.source_root else root, src)
        if not os.path.isdir(src_abs):
            _fail("source root '%s' is not a directory" % src)
        if args.source_root is not None and committed_src and \
                os.path.normpath(str(committed_src)) != os.path.normpath(os.path.relpath(src_abs, root)):
            print("check-depmap: committed source_root '%s' does not match the checked tree '%s'."
                  % (committed_src, os.path.relpath(src_abs, root)), file=sys.stderr)
            print("RESULT: RED (exit 1) - the map was generated against a different source root.", file=sys.stderr)
            sys.exit(1)
        try:
            generated = extract(src_abs, _load_excludes(root, yaml))
        except ValueError as exc:
            print("  [FAIL] %s" % exc, file=sys.stderr)
            print("RESULT: RED (exit 1) - regenerate the map from SOURCE.", file=sys.stderr)
            sys.exit(1)
        gen_sv, gen_nodes, gen_surf, gen_edges = _norm(generated)
        com_sv, com_nodes, com_surf, com_edges = _norm(committed)
        if (gen_sv, gen_nodes, gen_surf, gen_edges) == (com_sv, com_nodes, com_surf, com_edges):
            print("check-depmap: committed map matches SOURCE (%d node(s), %d edge(s)). RESULT: GREEN"
                  % (len(gen_nodes), len(gen_edges)))
            sys.exit(0)
        print("check-depmap: committed map DRIFTS from what SOURCE generates.", file=sys.stderr)
        if gen_nodes != com_nodes:
            gids = {n[0] for n in gen_nodes}
            cids = {n[0] for n in com_nodes}
            for x in sorted(gids - cids):
                print("  node '%s' is in SOURCE but not the committed map." % x, file=sys.stderr)
            for x in sorted(cids - gids):
                print("  committed node '%s' has no SOURCE file." % x, file=sys.stderr)
            if gids == cids:
                print("  a node's role/eligibility/coverage/provides differs from SOURCE.", file=sys.stderr)
        if gen_edges != com_edges:
            for e in sorted(set(gen_edges) - set(com_edges)):
                print("  edge %s is in SOURCE but not the committed map." % (e,), file=sys.stderr)
            for e in sorted(set(com_edges) - set(gen_edges)):
                print("  committed edge %s is not in SOURCE." % (e,), file=sys.stderr)
        if gen_surf != com_surf:
            print("  the owned-surface set differs from SOURCE.", file=sys.stderr)
        print("RESULT: RED (exit 1) - regenerate the map from SOURCE.", file=sys.stderr)
        sys.exit(1)

    src = resolve(args.source_root, "source")
    if not os.path.isdir(src):
        if args.source_root is not None:
            _fail("--source-root '%s' is not a directory" % args.source_root)
        print("extract-dependencies: no source tree at 'source/' - nothing to extract.", file=sys.stderr)
        sys.exit(0)
    try:
        model = extract(src, _load_excludes(root, yaml))
    except ValueError as exc:
        _fail(str(exc))
    src_rel = os.path.relpath(src, root)
    model["source_root"] = src_rel
    if args.owned:
        # Owned-surface SOURCE paths (repo-relative), for check-claims --owned-surfaces. For a
        # shared common block (owner null) every participant path is emitted (no single owner).
        by_id = {str(n.get("id")): n.get("source") for n in _as_list(model["nodes"])}

        def relp(nid):
            s = by_id.get(nid)
            return None if s is None else (str(s) if src_rel == "." else src_rel + "/" + str(s))
        paths = set()
        for s in _as_list(model["owned_surfaces"]):
            if s.get("owner"):
                p = relp(str(s.get("owner")))
                if p:
                    paths.add(p)
            else:
                for d in _as_list(s.get("dependents")):
                    p = relp(str(d))
                    if p:
                        paths.add(p)
        for p in sorted(paths):
            print(p)
        sys.exit(0)
    sys.stdout.write(_dump(model, yaml))


if __name__ == "__main__":
    main()
