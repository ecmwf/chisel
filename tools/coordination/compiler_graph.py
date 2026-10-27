#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""compiler_graph.py - the dependencies between SOURCE files as the compiler sees them.

The dependency map (extract_dependencies.py) is read from the text of the SOURCE, line by line, so it
misses what only the compiler resolves: a call split over a continuation line, a function called
without CALL, a USE inside an included file, a USE or #include that the build's own macros switch
on or off. This tool asks the compiler. It reads the compile commands of a finished SOURCE build - the
standard compile_commands.json, which Bear writes for any build (`bear -- make`) and CMake writes with
CMAKE_EXPORT_COMPILE_COMMANDS=ON - and for every Fortran file under the SOURCE root:

  - reruns its command with `-fsyntax-only -MMD` (gfortran) when the file is preprocessed, and reads
    the dependency file the compiler writes: the modules the file provides and uses and the in-tree
    files it includes, after the build's own preprocessing;
  - reads the built object with `nm -P`: the procedures and data it defines, and those it uses from
    other files (a module procedure or variable, an external procedure, a COMMON block);
  - for a file that shares a COMMON block, compiles it once more with `-fdump-tree-gimple` and reads
    whether it writes the block: a store into it, or its address taken (handed to a procedure or to
    I/O, which may write it). A BLOCK DATA that gives the block initial values writes it too.

It writes tools/scoping/compiler-graph.yaml: file-to-file edges (use, include, call, data), each with
the modules or symbols behind it, and the COMMON blocks with the files that share them and those that
write them. It records the
git tree of the SOURCE root it came from; extract_dependencies.py adds these edges to the ones it
reads itself and refuses a graph made from another SOURCE tree. A call the compiler drops because
its branch can never run (`if (.false.)`) is still kept by the line scan: a literal port translates
it, so it stays a dependency.

Usage:  compiler_graph.py --compile-commands FILE [--source-root DIR] [--out FILE]
Exit:   0 written; 2 UNRELIABLE (no Fortran entry under the SOURCE root, a command that does not
        rerun, an object that is missing, uncommitted SOURCE changes, or nm missing).
"""
import argparse
import gzip
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile


FORTRAN = {".f", ".for", ".f90", ".f95", ".f03", ".f08", ".fpp"}
PREPROCESSED = {".F", ".FOR", ".F90", ".F95", ".F03", ".F08", ".FPP", ".fpp"}
DROP_WITH_VALUE = {"-o", "-MF", "-MT", "-MQ"}
DROP = {"-c", "-MD", "-MMD", "-M", "-MM", "-MP"}
CODE = set("TW")                 # a defined procedure (text, or weak)
DATA = set("BDGRSV")             # defined data: module variables, initialized COMMON


def _fail(msg):
    print("compiler-graph: %s (UNRELIABLE)" % msg, file=sys.stderr)
    sys.exit(2)


def _args(entry):
    if isinstance(entry.get("arguments"), list):
        return [str(a) for a in entry["arguments"]]
    return shlex.split(str(entry.get("command") or ""))


def _output(entry, args):
    if entry.get("output"):
        return str(entry["output"])
    for i, a in enumerate(args):
        if a == "-o" and i + 1 < len(args):
            return args[i + 1]
        if a.startswith("-o") and len(a) > 2:
            return a[2:]
    return None


def _replay(args):
    """The command with its outputs taken off, to rerun for dependencies only."""
    out, skip = [], False
    for a in args:
        if skip:
            skip = False
        elif a in DROP_WITH_VALUE:
            skip = True
        elif a in DROP or any(a.startswith(p) and len(a) > len(p) for p in DROP_WITH_VALUE):
            continue
        else:
            out.append(a)
    return out


def _make_deps(path):
    """(targets, prerequisites) of a make dependency file."""
    text = open(path, encoding="utf-8", errors="replace").read().replace("\\\n", " ")
    targets, prereqs = [], []
    for line in text.splitlines():
        if ":" not in line or line.startswith("\t"):
            continue
        left, right = line.split(":", 1)
        targets += left.split()
        prereqs += right.split()
    return targets, prereqs


def _mod_source(path):
    """The file name a gfortran module file says it was made from ("... created from base.f90")."""
    try:
        with gzip.open(path, "rt", encoding="utf-8", errors="replace") as f:
            m = re.search(r"created from (\S+)", f.readline())
    except OSError:
        return None
    return os.path.basename(m.group(1)) if m else None


def _writes(src, base, args, blocks):
    """The COMMON blocks among `blocks` (their names as GIMPLE shows them) that a file writes: a store
    into the block, or its address taken, in gfortran's GIMPLE. A file with no procedure (a BLOCK
    DATA) has no GIMPLE; nm tells whether it initializes a block."""
    with tempfile.TemporaryDirectory() as tmp:
        dump = os.path.join(tmp, "unit.gimple")
        cmd = _replay(args) + ["-S", "-o", os.devnull, "-fdump-tree-gimple=" + dump]
        p = subprocess.run(cmd, cwd=base, capture_output=True, text=True)
        if p.returncode != 0:
            _fail("%s does not recompile: %s" % (src, (p.stderr.strip().splitlines() or ["?"])[-1]))
        if not os.path.isfile(dump):
            return set()
        lines = [ln for ln in open(dump, encoding="utf-8", errors="replace") if "value-expr" not in ln]
    out = set()
    for b in blocks:
        addr = re.compile(r"&" + re.escape(b) + r"\b")                  # &blk: handed on, may be written
        named = re.compile(r"(?<![\w.])" + re.escape(b) + r"\s*[.\[]")   # blk.c1 or blk[...]
        for ln in lines:
            if addr.search(ln) or (" = " in ln and named.search(ln.split(" = ", 1)[0])):
                out.add(b)
                break
    return out


def _nm(path):
    """{symbol: type} for the global symbols of an object, undefined ones as U."""
    try:
        p = subprocess.run(["nm", "-P", path], capture_output=True, text=True)
    except OSError:
        _fail("nm is not available")
    if p.returncode != 0:
        _fail("nm cannot read %s: %s" % (path, p.stderr.strip()))
    syms = {}
    for line in p.stdout.splitlines():
        f = line.split()
        if len(f) >= 2 and (f[1] == "U" or f[1].isupper()):
            syms[f[0]] = f[1]
    return syms


def graph(entries, source_root):
    """The graph as a dict: edges (from, to, kind, via) and commons, paths relative to source_root."""
    root = os.path.realpath(source_root)

    def rel(path, base):
        p = os.path.realpath(os.path.join(base, path))
        return os.path.relpath(p, root) if p == root or p.startswith(root + os.sep) else None

    units = {}
    for e in entries:
        base = str(e.get("directory") or ".")
        args = _args(e)
        src = rel(str(e.get("file") or ""), base)
        if not src or os.path.splitext(src)[1].lower() not in FORTRAN:
            continue
        obj = _output(e, args)
        if not obj or not os.path.isfile(os.path.join(base, obj)):
            _fail("the object of %s is missing - finish the build first" % src)
        u = units.setdefault(src, {"provides": set(), "uses": set(), "includes": set(), "syms": {}})
        u["entry"] = (base, args)
        u["syms"].update(_nm(os.path.join(base, obj)))
        ext = os.path.splitext(src)[1]
        if ext not in PREPROCESSED and "-cpp" not in args:
            continue
        with tempfile.TemporaryDirectory() as tmp:
            dfile = os.path.join(tmp, "deps.d")
            cmd = _replay(args) + ["-fsyntax-only", "-MMD", "-MF", dfile]
            p = subprocess.run(cmd, cwd=base, capture_output=True, text=True)
            if p.returncode != 0 or not os.path.isfile(dfile):
                _fail("%s does not rerun: %s" % (src, (p.stderr.strip().splitlines() or ["no dependency file"])[-1]))
            targets, prereqs = _make_deps(dfile)
        for t in targets:
            if t.endswith(".mod"):
                u["provides"].add(os.path.basename(t)[:-4].lower())
        for q in prereqs:
            if q.endswith(".mod"):
                u["uses"].add(os.path.basename(q)[:-4].lower())
                u.setdefault("mod_files", {})[os.path.basename(q)[:-4].lower()] = os.path.join(base, q)
            else:
                r = rel(q, base)
                if r and r != src:
                    u["includes"].add(r)
    if not units:
        _fail("no Fortran file under %s in the compile commands" % source_root)

    module_of, definers, common = {}, {}, {}
    by_name = {}
    for src in units:
        by_name.setdefault(os.path.basename(src), []).append(src)
    for src, u in units.items():
        for m in u["provides"]:
            module_of[m] = src
    for u in units.values():            # a module provided by a file that was not rerun
        for m, path in u.get("mod_files", {}).items():
            made = by_name.get(_mod_source(path) or "", [])
            if m not in module_of and len(made) == 1:
                module_of[m] = made[0]
    for src, u in units.items():
        for s, t in u["syms"].items():
            if t == "C":
                common.setdefault(s, set()).add(src)
            elif t != "U":
                definers.setdefault(s, {})[src] = t
    for s, d in definers.items():
        if s in common:
            common[s] |= set(d)                  # a BLOCK DATA that initializes the block
    edges = {}

    def add(frm, to, kind, via):
        if to != frm:
            edges.setdefault((frm, to, kind), set()).add(via)

    for src, u in units.items():
        for m in u["uses"]:
            if m in module_of:
                add(src, module_of[m], "use", m)
        for h in u["includes"]:
            add(src, h, "include", h)
        for s, t in u["syms"].items():
            d = definers.get(s, {})
            if t != "U" or s in common or len(d) != 1:
                continue
            (to, tt), = d.items()
            if tt in CODE:
                add(src, to, "call", s)
            elif tt in DATA:
                add(src, to, "data", s)
    shared = {s: m for s, m in common.items() if len(m) >= 2}
    writers = {s: {src for src in m if definers.get(s, {}).get(src) == "D"} for s, m in shared.items()}
    for src in sorted({src for m in shared.values() for src in m}):
        mine = {s for s, m in shared.items() if src in m}
        names = {_gimple_name(s): s for s in mine}
        for b in _writes(src, *units[src]["entry"], names):
            writers[names[b]].add(src)
    return {
        "edges": [{"from": f, "to": t, "kind": k, "via": sorted(v)} for (f, t, k), v in sorted(edges.items())],
        "commons": [{"name": _gimple_name(s), "members": sorted(m), "writers": sorted(writers[s])}
                    for s, m in sorted(shared.items())],
    }


def _gimple_name(symbol):
    """The COMMON block's name as GIMPLE and the source show it: the symbol without its trailing
    underscore (blank COMMON keeps its own name)."""
    return symbol[:-1] if symbol.endswith("_") and len(symbol) > 1 else symbol


def source_tree(source_root):
    """The git tree of the committed SOURCE root; uncommitted changes there are refused."""
    def git(*a):
        return subprocess.run(["git", "-C", source_root] + list(a), capture_output=True, text=True)
    st = git("status", "--porcelain", "--", ".")
    if st.returncode != 0:
        _fail("%s is not in a git repository" % source_root)
    if st.stdout.strip():
        _fail("%s has uncommitted changes - commit them, so the graph names the tree it came from" % source_root)
    return git("rev-parse", "HEAD:./").stdout.strip()


def main():
    ap = argparse.ArgumentParser(description="The SOURCE dependencies as the compiler sees them.")
    ap.add_argument("--compile-commands", required=True)
    ap.add_argument("--source-root", default="source")
    ap.add_argument("--out", default=os.path.join("tools", "scoping", "compiler-graph.yaml"))
    a = ap.parse_args()
    try:
        import yaml
        entries = json.load(open(a.compile_commands, encoding="utf-8"))
    except ImportError:
        _fail("PyYAML is not available - run the tools with `uv run`")
    except (OSError, ValueError) as e:
        _fail("cannot read %s: %s" % (a.compile_commands, e))
    if not isinstance(entries, list) or not all(isinstance(x, dict) for x in entries):
        _fail("%s is not a list of compile commands" % a.compile_commands)
    tree = source_tree(a.source_root)
    g = graph(entries, a.source_root)
    fc = next((_args(x)[0] for x in entries if _args(x)), "gfortran")
    try:
        version = subprocess.run([fc, "--version"], capture_output=True, text=True).stdout.splitlines()[0]
    except (OSError, IndexError):
        version = fc
    doc = {"schema_version": 1, "source_root": a.source_root.rstrip("/") + "/", "source_tree": tree,
           "compiler": version, "edges": g["edges"], "commons": g["commons"]}
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out, "w", encoding="utf-8") as f:
        f.write("# Generated by tools/coordination/compiler_graph.py from a build of the SOURCE; do not edit.\n")
        yaml.safe_dump(doc, f, sort_keys=False, default_flow_style=False)
    print("compiler-graph: %d edge(s), %d shared COMMON block(s) -> %s"
          % (len(g["edges"]), len(g["commons"]), a.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
