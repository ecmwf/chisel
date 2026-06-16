#!/usr/bin/env python3
"""Extract the SOURCE dependency map (with a confidence model) from a Fortran source tree.

references/team-coordination.md ("the confidence model"): the ready-set and the owned/leaf
partition are computed from this graph, and numerical codes hide coupling no call graph shows.
So every edge carries a CONFIDENCE - proven (a use/call/include resolved in-tree), suspected
(an unresolved reference, or a structural coupling like a shared common block) - and a unit is
SELF-SERVE-ELIGIBLE only if it is unowned, fully parsed, and has no suspected/unknown coupling:
suspected/unknown coupling keeps a unit out of the self-serve leaf pool until review proves it.

CONSERVATISM is the whole point. This is a line-based, FREE-FORM REFERENCE extractor (it does
not resolve generics, procedure pointers, interface callbacks, equivalence, or entry). Rather
than silently call such a file a clean leaf, it marks any file containing a construct it cannot
fully analyze `coverage: partial` and NOT self_serve_eligible - so the failure mode is a unit
needlessly GUARDED (a human looks), never a truly-coupled unit waved into parallel work. Two
further guards close silent-leaf paths a free-form line scan would otherwise miss: fixed-form
sources (a .f/.for/.ftn extension, which a compiler reads as fixed-form, so the lexer would
mis-read their column-1 comments and column-6 continuations) are marked partial wholesale; and an
undeclared reference to an IN-TREE function (`y = foo(3)` with no use/call) draws a SUSPECTED edge
so the consumer is guarded. The two residual UNDER-guard blind spots are a reference to an
EXTERNAL function (defined nowhere in the tree, indistinguishable from an array element) and a
fixed-form file mislabeled with a free-form extension; both are covered by the reviewed
human/charter `unknown`-confidence overlay. `unknown` confidence is reserved for that overlay;
this generated map never emits it, and `--check` drift-checks the generated map exactly.

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
import glob
import os
import re
import subprocess
import sys
from typing import NoReturn

FORT_EXTS = (".f90", ".f95", ".f03", ".f08", ".f", ".for", ".ftn")
# Extensions a compiler reads as FIXED-FORM by default (column-1 C/*/! comments, column-6
# continuation, code in cols 7-72). This free-form line extractor would mis-lex them, so a
# file with one of these extensions is marked coverage: partial and kept out of the leaf pool.
FIXED_FORM_EXTS = (".f", ".for", ".ftn")
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

# Constructs the line-based extractor cannot fully resolve -> the file is coverage: partial and
# kept out of the self-serve pool (conservative). Each maps to a guarded reason.
COVERAGE_GAPS = (
    (re.compile(r"\binterface\b", re.I), "interface-block"),
    (re.compile(r"\bexternal\b", re.I), "external-procedure"),
    (re.compile(r"\bprocedure\b", re.I), "procedure-decl"),
    (re.compile(r"=>"), "pointer-assoc"),
    (re.compile(r"\bequivalence\b", re.I), "equivalence"),
    (re.compile(r"\bentry\b", re.I), "entry"),
    (re.compile(r";"), "multi-statement"),
)
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
ALLOWED_CONF = {"proven", "suspected", "unknown"}
ALLOWED_ROLE = {"owned", "unowned"}
NS_PREFIXES = ("unresolved:", "common:", "include:", "unknown:")


def _fail(msg) -> "NoReturn":
    sys.stderr.write("extract-dependencies: " + msg + "\n")
    sys.exit(2)


def _repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def _strict_loader(yaml):
    """A SafeLoader that REJECTS duplicate mapping keys (so a hand-edited committed map cannot
    hide a second `nodes:`/`edges:` that PyYAML would silently collapse to the last)."""
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


def _source_files(root):
    out = []
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        for name in sorted(files):
            if os.path.splitext(name)[1].lower() in FORT_EXTS:
                out.append(os.path.join(dirpath, name))
    return out


def extract(source_root):
    """Build the deterministic map data model from a Fortran tree under source_root.
    Raises ValueError on a structural problem (duplicate file stem) that must fail closed."""
    files = _source_files(source_root)
    def_module, def_proc, def_func, commons = {}, {}, {}, {}
    nodes, node_modules, raw_by_node, coverage_gaps = {}, {}, {}, {}
    for path in files:
        nid = os.path.splitext(os.path.basename(path))[0]
        rel = os.path.relpath(path, source_root).replace(os.sep, "/")
        if nid in nodes:
            raise ValueError("duplicate file stem '%s' (%s and %s) - node ids must be unique"
                             % (nid, nodes[nid], rel))
        nodes[nid] = rel
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                rawlines = fh.readlines()
        except OSError as exc:
            _fail("cannot read source '%s' (%s)" % (path, exc))
        code = [_strip_comment(ln) for ln in rawlines]
        raw_by_node[nid] = code
        node_modules[nid] = []
        gaps = set()
        if os.path.splitext(path)[1].lower() in FIXED_FORM_EXTS:
            gaps.add("fixed-form")
        for orig in rawlines:
            if orig.lstrip().startswith("#"):
                gaps.add("preprocessor")
        for ln in code:
            if ln.rstrip().endswith("&"):
                gaps.add("continuation")
            for rx, reason in COVERAGE_GAPS:
                if rx.search(ln):
                    gaps.add(reason)
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
                def_func[mf.group(1).lower()] = nid
            mp = RE_PROG.match(ln)
            if mp:
                def_proc[mp.group(1).lower()] = nid
        for ln in code:
            mc = RE_COMMON.search(ln)
            if mc:
                commons.setdefault(mc.group(1).lower(), set()).add(nid)
        coverage_gaps[nid] = gaps

    edges = set()
    module_dependents = {}
    suspected_from = set()
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
                    elif owner is None:
                        edges.add((nid, "unresolved:" + tgt, "use", "suspected"))
                        suspected_from.add(nid)
            mcall = RE_CALL.search(ln)
            if mcall:
                tgt = mcall.group(1).lower()
                if tgt not in INTRINSIC_SUBS:
                    owner = def_proc.get(tgt)
                    if owner and owner != nid:
                        edges.add((nid, owner, "call", "proven"))
                    elif owner is None:
                        edges.add((nid, "unresolved:" + tgt, "call", "suspected"))
                        suspected_from.add(nid)
            minc = RE_INC.match(ln)
            if minc:
                inc = minc.group(1)
                base = os.path.basename(inc)
                coverage_gaps[nid].add("include")
                edges.add((nid, "include:" + base, "include", "suspected"))
                suspected_from.add(nid)
    for blk, parts in commons.items():
        if len(parts) >= 2:
            for nid in parts:
                edges.add((nid, "common:/%s/" % blk, "common-block", "suspected"))
                suspected_from.add(nid)

    # Function-reference coupling: a reference to an in-tree FUNCTION whose dependency is NOT
    # already captured by a use/call edge is an UNDECLARED coupling that would otherwise leave the
    # consumer a silent leaf. A line extractor cannot tell `f(i)` (call) from `a(i)` (array), so
    # emit a SUSPECTED edge (guard the consumer), and only when no edge to that owner already
    # exists - a declared `use`/`call` of the same owner already explains the dependency.
    have_edge = {(a, b) for (a, b, _k, _c) in edges}
    for nid in sorted(nodes):
        for ln in raw_by_node[nid]:
            if RE_CALL.search(ln):
                continue
            for mm in re.finditer(r"\b(\w+)\s*\(", ln):
                owner = def_func.get(mm.group(1).lower())
                if owner and owner != nid and (nid, owner) not in have_edge:
                    edges.add((nid, owner, "call-ref", "suspected"))
                    suspected_from.add(nid)
                    have_edge.add((nid, owner))

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
        if coverage_gaps[nid]:
            for g in coverage_gaps[nid]:
                reasons.add("coverage-gap:" + g)
        if nid in suspected_from:
            reasons.add("suspected-coupling")
        for surf in shared_participants.get(nid, []):
            reasons.add("shared-surface:" + surf)
        node_list.append({"id": nid, "source": nodes[nid], "role": role,
                          "self_serve_eligible": len(reasons) == 0,
                          "guarded_reasons": sorted(reasons),
                          "coverage": "partial" if coverage_gaps[nid] else "full",
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
        if to not in idset and not to.startswith(NS_PREFIXES):
            v.append("edge target '%s' is neither a node nor a typed surface" % to)
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
            generated = extract(src_abs)
        except ValueError as exc:
            _fail(str(exc))
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
        model = extract(src)
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
