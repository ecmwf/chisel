#!/usr/bin/env python3
"""Generate canonical port/TRACE.yaml from the per-work-item status fragments.

Shard-and-generate (references/team-coordination.md): contributors write
port/status/<id>.yaml fragments in their own branches; the canonical TRACE is GENERATED
from them, never hand-merged. This is the deterministic generator: the same fragments
always produce the same TRACE, which is what the drift check relies on and what makes a
crashed wave safely re-runnable.

It emits the SAME canonical TRACE format the hand-written template uses (indented block
sequences, `source` first in each row, `gate`/`review` as bare evidence paths), so every
TRACE consumer agrees: the awk evidence checker (check-trace-evidence.sh), the YAML drift
check (--check below), and port-progress.py. Generated rows additionally carry `id`,
`integration`, `gate_tier`, and `gate_commit`; consumers that key on names ignore them.

This is the generic framework (methodology-layer, tools/coordination/); the per-project
fragments and DAG data live under port/ and tools/scoping/ (project-layer).

Usage:
  generate_trace.py [--status-dir DIR] [--meta FILE]            print canonical TRACE
  generate_trace.py --check [--status-dir DIR] [--meta FILE] [--trace FILE]
                                                                drift-check the committed TRACE

--check exit codes: 0 the committed TRACE matches what the fragments generate (or there
are no fragments yet); 1 DRIFT (the committed TRACE disagrees with the fragments); 2
UNRELIABLE (cannot run - missing PyYAML/meta, malformed fragment, duplicate keys).

Defaults: status-dir=port/status, meta=port/status/_meta.yaml, trace=port/TRACE.yaml.
"""
import argparse
import glob
import os
import subprocess
import sys
from _chisel_lib import strict_loader as _strict_loader, repo_root as _repo_root

META_REQUIRED = ("source_root", "target_root", "source_commit")


def _fail(msg, code):
    sys.stderr.write("generate-trace: " + msg + "\n")
    sys.exit(code)


def _load(path, yaml, loader):
    try:
        with open(path) as fh:
            return yaml.load(fh, Loader=loader) or {}
    except yaml.YAMLError as exc:
        _fail("'{}' is not valid YAML ({})".format(path, exc), 2)


def _fragment_paths(status_dir):
    # _meta.yaml holds the TRACE meta block, not a work item; exclude it.
    return sorted(p for p in glob.glob(os.path.join(status_dir, "*.yaml"))
                  if os.path.basename(p) != "_meta.yaml")


def _scalar(v):
    return v is not None and not isinstance(v, (dict, list)) and str(v).strip() != ""


def _row_from_fragment(frag, path):
    """The canonical, deterministic mapping: one fragment -> one TRACE row. `source` is
    first so the awk evidence checker sees the row; gate/review are bare evidence paths."""
    if not _scalar(frag.get("id")):
        _fail("fragment '{}' has no non-empty scalar 'id'".format(path), 2)
    if not _scalar(frag.get("source")):
        _fail("fragment '{}' has no non-empty scalar 'source'".format(path), 2)
    target = frag.get("target")
    if target is not None and not isinstance(target, list):
        _fail("fragment '{}' field 'target' must be a list".format(path), 2)
    own = frag.get("ownership") or {}
    gate = frag.get("gate") or {}
    review = frag.get("review") or {}
    integ = frag.get("integration") or {}
    return {
        "source": frag.get("source"),
        "target": target or [],
        "status": frag.get("status"),
        "integration": integ.get("state"),
        "workstream": own.get("workstream") or own.get("kind"),
        "gate": gate.get("evidence"),
        "gate_tier": gate.get("tier"),
        "gate_commit": gate.get("commit"),
        "validation": gate.get("validation"),
        "review": review.get("evidence"),
        "author_sessions": frag.get("author_sessions") or [],
        "reviewer_session": frag.get("reviewer_session"),
        "tag": None,
        "id": frag.get("id"),
        "notes": frag.get("notes", ""),
    }


def build_trace(status_dir, meta_path, yaml):
    """Build the canonical TRACE data model from the fragments + meta. Deterministic."""
    loader = _strict_loader(yaml)
    if not os.path.isfile(meta_path):
        _fail("meta file '{}' is missing (it holds the TRACE meta block)".format(meta_path), 2)
    meta = _load(meta_path, yaml, loader)
    if not isinstance(meta, dict) or any(k not in meta for k in META_REQUIRED):
        _fail("meta '{}' must define {}".format(meta_path, ", ".join(META_REQUIRED)), 2)
    rows = []
    seen = set()
    for p in _fragment_paths(status_dir):
        frag = _load(p, yaml, loader)
        if not isinstance(frag, dict):
            _fail("fragment '{}' is not a mapping".format(p), 2)
        row = _row_from_fragment(frag, p)
        if row["id"] in seen:
            _fail("duplicate work-item id '{}' across fragments".format(row["id"]), 2)
        seen.add(row["id"])
        rows.append(row)
    rows.sort(key=lambda r: (str(r.get("id")), str(r.get("source"))))
    return {"meta": meta, "files": rows}


def _dump(model, yaml):
    """Emit the template-compatible canonical TRACE: indented block sequences (so rows
    read `  - source:` / `    field:`, what the awk evidence checker keys on)."""
    class IndentDumper(yaml.Dumper):
        def increase_indent(self, flow=False, indentless=False):
            return super(IndentDumper, self).increase_indent(flow, False)

    return yaml.dump(model, Dumper=IndentDumper, sort_keys=False,
                     default_flow_style=False, indent=2, allow_unicode=True)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--status-dir", default=None)
    ap.add_argument("--meta", default=None)
    ap.add_argument("--trace", default=None)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    orig = os.getcwd()
    root = _repo_root()
    try:
        os.chdir(root)
    except OSError:
        _fail("cannot enter repo root '{}'".format(root), 2)

    # Omitted paths use the repo-root defaults; an explicit path is taken as-is if
    # absolute, else resolved against the ORIGINAL cwd (so a fixture can be targeted).
    def resolve(p, default_rel):
        if p is None:
            return default_rel
        return p if os.path.isabs(p) else os.path.join(orig, p)

    status_dir = resolve(args.status_dir, "port/status")
    trace_path = resolve(args.trace, "port/TRACE.yaml")
    if args.meta is not None:
        meta_path = args.meta if os.path.isabs(args.meta) else os.path.join(orig, args.meta)
    else:
        meta_path = os.path.join(status_dir, "_meta.yaml")

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse fragments (install pyyaml)", 2)

    if not args.check:
        sys.stdout.write(_dump(build_trace(status_dir, meta_path, yaml), yaml))
        return

    # --check: drift-check the committed TRACE against the fragments.
    if not _fragment_paths(status_dir):
        print("check-trace-drift: no fragments under '{}' - nothing to check (skipping)."
              .format(status_dir))
        sys.exit(0)
    generated = build_trace(status_dir, meta_path, yaml)
    if not os.path.isfile(trace_path):
        _fail("fragments exist but committed TRACE '{}' is missing".format(trace_path), 2)
    committed = _load(trace_path, yaml, _strict_loader(yaml))
    # Compare DATA MODELS (robust to formatting/comments), normalizing file order by id.
    committed_files = sorted((committed.get("files") or []),
                             key=lambda r: (str(r.get("id")), str(r.get("source"))))
    committed_norm = {"meta": committed.get("meta") or {}, "files": committed_files}
    if generated == committed_norm:
        print("check-trace-drift: committed TRACE matches the {} fragment(s). RESULT: GREEN"
              .format(len(generated["files"])))
        sys.exit(0)
    print("check-trace-drift: committed TRACE DRIFTS from the fragments.", file=sys.stderr)
    if (committed.get("meta") or {}) != generated["meta"]:
        print("  meta differs (committed vs generated-from-fragments).", file=sys.stderr)
    gen_ids = {str(r.get("id")) for r in generated["files"]}
    com_ids = {str(r.get("id")) for r in committed_files}
    for missing in sorted(gen_ids - com_ids):
        print("  fragment '{}' has no row in the committed TRACE.".format(missing), file=sys.stderr)
    for extra in sorted(com_ids - gen_ids):
        print("  committed TRACE row '{}' has no fragment.".format(extra), file=sys.stderr)
    gen_by = {str(r.get("id")): r for r in generated["files"]}
    com_by = {str(r.get("id")): r for r in committed_files}
    for i in sorted(gen_ids & com_ids):
        if gen_by[i] != com_by[i]:
            print("  row '{}' differs from what its fragment generates.".format(i), file=sys.stderr)
    print("RESULT: RED (exit 1) - regenerate canonical TRACE from the fragments.", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
