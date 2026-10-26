#!/usr/bin/env python3
"""Verify every file the dependency map / TRACE calls LIVE is actually git-TRACKED.

check-source-import.sh already proves an AGGREGATE invariant: the number of git-tracked files
under each imported SOURCE `path` (port/provenance/*.yaml) equals its upstream `tracked_files`
count. That is a real, durable guard, but it is a whole-tree SUM - it can hold even while a
SPECIFIC file the map/TRACE names as live is the one missing, as long as some unrelated file
elsewhere under the same provenance `path` happens to offset the count (the provenance path is
typically the WHOLE imported repo - tests, docs, cmake, ... - a much larger set than the map/TRACE
ever names). that failure's root cause (a nested .gitignore, stripped-of-its-.git, silently
excluding a real live file from `git add -A`) is a PER-FILE failure; nothing before this checked
the map/TRACE's specific claims against git file by file.

This is that missing per-file half: for every dependency-map NODE (the full SOURCE inventory) and
every TRACE row whose status is not `excluded` (the LIVE subset), the named source path must exist
on disk AND be resolvable by `git ls-files` - i.e. genuinely tracked, not merely present in a
working tree that happens to still hold an untracked copy (main tree vs. a fresh worktree is
exactly the split it produced).

Reads the map (--map, default tools/scoping/dependency-map.yaml) and TRACE
(--trace, default port/TRACE.yaml). Until the map exists there is nothing to check (mirrors
check-completeness.py); a map with no TRACE alongside it is itself check-completeness's problem to
flag, not this one's, so TRACE is checked only when present.

Usage:  check_live_tracked.py [--map FILE] [--trace FILE]
Exit:   0 every named file exists on disk and is git-tracked (or nothing to check yet);
        1 a map/TRACE-named file is missing from disk or is present-but-UNTRACKED;
        2 UNRELIABLE (no PyYAML/git, or malformed input).
"""
import argparse
import os
import subprocess
import sys
from typing import NoReturn
from _chisel_lib import strict_loader as _strict_loader, repo_root as _repo_root
from _chisel_lib import modern as _modern, VocabularyConflict


def _fail(msg) -> "NoReturn":
    sys.stderr.write("check-live-tracked: " + msg + "\n")
    sys.exit(2)


def _s(v):
    return "" if v is None else str(v).strip()


def _tracked_set(root, source_root):
    """All git-tracked paths (repo-root-relative, '/'-separated) under source_root. A single `git
    ls-files` call - not one subprocess per file - so this stays fast at hundreds of files. The list
    is NUL-separated (-z): the line form C-quotes a path holding a non-ASCII byte, a double quote or
    a newline, and that quoted string matches no name, so a tracked file would read as untracked."""
    try:
        out = subprocess.run(["git", "ls-files", "-z", "--", source_root], cwd=root,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        _fail("cannot run git (%s)" % exc)
    if out.returncode != 0:
        _fail("git ls-files failed (%s)" % out.stderr.decode(errors="replace").strip())
    return {os.fsdecode(p) for p in out.stdout.split(b"\0") if p}


def _check_ignore_hint(root, rel):
    """The .gitignore rule (if any) responsible for `rel` being untracked, for an actionable
    message - same technique check-source-import.sh already uses. Best-effort: absence of a hint
    is never treated as absence of the problem."""
    try:
        out = subprocess.run(["git", "check-ignore", "-v", "--", rel], cwd=root,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        line = out.stdout.decode(errors="replace").strip()
        return line or None
    except OSError:
        return None


def verify(root, source_root, map_nodes, trace_rows, tracked):
    """map_nodes: [(id, source_rel)] from the map (the full inventory). trace_rows: [(id,
    source_rel, status)] from TRACE (checked only when status != excluded). `tracked`: the git
    ls-files set. Returns violation strings (empty == ok), and the count of files checked."""
    v = []
    seen = set()

    def check_one(label, id_, rel):
        full = (source_root + "/" + rel) if rel else ""
        key = (label, id_)
        if key in seen:
            return
        seen.add(key)
        if not rel:
            v.append("%s '%s' has no source path" % (label, id_))
            return
        on_disk = os.path.isfile(os.path.join(root, full))
        is_tracked = full in tracked
        if on_disk and is_tracked:
            return
        if not on_disk:
            v.append("%s '%s' (%s) is LIVE but MISSING from disk (truncated checkout?)"
                     % (label, id_, full))
            return
        hint = _check_ignore_hint(root, full)
        if hint:
            v.append("%s '%s' (%s) is present on disk but UNTRACKED - excluded by: %s"
                     % (label, id_, full, hint))
        else:
            v.append("%s '%s' (%s) is present on disk but UNTRACKED (git ls-files does not list it)"
                     % (label, id_, full))

    for id_, rel in map_nodes:
        check_one("map node", id_, rel)
    for id_, rel, status in trace_rows:
        if status != "excluded":
            check_one("TRACE row", id_, rel)
    return v, len(seen)


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

    command_ok = subprocess.run(["git", "rev-parse", "--is-inside-work-tree"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not command_ok:
        _fail("not inside a git repository")

    def resolve(p, default_rel):
        if p is None:
            return default_rel
        return p if os.path.isabs(p) else os.path.join(orig, p)

    map_path = resolve(args.map, os.path.join("tools", "scoping", "dependency-map.yaml"))
    trace_path = resolve(args.trace, os.path.join("port", "TRACE.yaml"))

    if not os.path.isfile(map_path):
        print("check-live-tracked: no dependency map yet ('%s') - nothing to check (skipping)."
              % os.path.relpath(map_path, os.getcwd()))
        sys.exit(0)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse the artifacts (install pyyaml)")
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
    source_root = _s(dep.get("source_root"))
    if not source_root:
        _fail("dependency map '%s' has no source_root" % map_path)
    raw_nodes = dep.get("nodes")
    if raw_nodes is None:
        raw_nodes = []
    if not isinstance(raw_nodes, list):
        _fail("dependency map '%s' 'nodes' must be a list" % map_path)
    map_nodes = []
    for n in raw_nodes:
        if not isinstance(n, dict):
            _fail("dependency map '%s' has a non-mapping node entry" % map_path)
        nid = _s(n.get("id"))
        if nid:
            map_nodes.append((nid, _s(n.get("source"))))

    if not map_nodes:
        print("check-live-tracked: the dependency map has no nodes - nothing to check (skipping).")
        sys.exit(0)

    trace_rows = []
    if os.path.isfile(trace_path):
        trace = load(trace_path, "TRACE")
        raw_files = trace.get("files")
        if raw_files is None:
            raw_files = []
        if not isinstance(raw_files, list):
            _fail("TRACE '%s' 'files' must be a list" % trace_path)
        for f in raw_files:
            if not isinstance(f, dict):
                _fail("TRACE '%s' has a non-mapping row" % trace_path)
            fid = _s(f.get("id"))
            if fid:
                trace_rows.append((fid, _s(f.get("source")), _s(f.get("status"))))

    tracked = _tracked_set(root, source_root)
    violations, checked = verify(root, source_root, map_nodes, trace_rows, tracked)

    for msg in violations:
        print("  [FAIL] %s" % msg)
    print("check-live-tracked: checked %d distinct LIVE-inventory file(s) (%d map node(s), %d "
          "TRACE row(s)); %d violation(s)." % (checked, len(map_nodes), len(trace_rows), len(violations)))
    if violations:
        print("RESULT: RED (exit 1) - a map/TRACE-named file is not git-tracked; "
              "git add -f it (once tracked, .gitignore no longer applies).")
        sys.exit(1)
    print("RESULT: GREEN (exit 0) - every map node and every live TRACE row is on disk and tracked.")
    sys.exit(0)


if __name__ == "__main__":
    main()
