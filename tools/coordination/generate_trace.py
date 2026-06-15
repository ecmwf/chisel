#!/usr/bin/env python3
"""Generate canonical port/TRACE.yaml from the per-work-item status fragments.

Shard-and-generate (references/team-coordination.md): contributors write
port/status/<id>.yaml fragments in their own branches; the canonical TRACE is GENERATED
from them, never hand-merged. This is the deterministic generator: the same fragments
always produce the same TRACE, which is what the drift check relies on and what makes a
crashed wave safely re-runnable.

This is the generic framework (methodology-layer, tools/coordination/); the per-project
fragments and DAG data live under port/ and tools/scoping/ (project-layer).

Usage:
  generate_trace.py [--status-dir DIR] [--meta FILE]            print canonical TRACE
  generate_trace.py --check [--status-dir DIR] [--meta FILE] [--trace FILE]
                                                                drift-check the committed TRACE

--check exit codes: 0 the committed TRACE matches what the fragments generate (or there
are no fragments yet); 1 DRIFT (the committed TRACE disagrees with the fragments); 2
UNRELIABLE (cannot run - missing PyYAML/meta/tooling).

Defaults: status-dir=port/status, meta=port/status/_meta.yaml, trace=port/TRACE.yaml.
"""
import argparse
import glob
import os
import subprocess
import sys


def _repo_root():
    try:
        out = subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                      stderr=subprocess.DEVNULL)
        return out.decode().strip()
    except Exception:
        return os.getcwd()


def _fail(msg, code):
    sys.stderr.write("generate-trace: " + msg + "\n")
    sys.exit(code)


def _fragment_paths(status_dir):
    # _meta.yaml holds the TRACE meta block, not a work item; exclude it.
    return sorted(p for p in glob.glob(os.path.join(status_dir, "*.yaml"))
                  if os.path.basename(p) != "_meta.yaml")


def _row_from_fragment(frag):
    """The canonical, deterministic mapping: one fragment -> one TRACE row."""
    own = frag.get("ownership") or {}
    gate = frag.get("gate") or {}
    review = frag.get("review") or {}
    integ = frag.get("integration") or {}
    gate_field = None
    if gate.get("tier") and gate.get("evidence"):
        gate_field = "{} evidence: {}".format(gate["tier"], gate["evidence"])
    # Fixed key order -> deterministic output.
    return {
        "id": frag.get("id"),
        "source": frag.get("source"),
        "target": frag.get("target") or [],
        "status": frag.get("status"),
        "integration": integ.get("state"),
        "workstream": own.get("workstream") or own.get("kind"),
        "gate": gate_field,
        "review": review.get("evidence"),
        "author_sessions": frag.get("author_sessions") or [],
        "reviewer_session": frag.get("reviewer_session"),
        "tag": None,
        "notes": frag.get("notes", ""),
    }


def build_trace(status_dir, meta_path, yaml):
    """Build the canonical TRACE data model from the fragments + meta. Deterministic."""
    paths = _fragment_paths(status_dir)
    if not os.path.isfile(meta_path):
        _fail("meta file '{}' is missing (it holds the TRACE meta block)".format(meta_path), 2)
    with open(meta_path) as fh:
        meta = yaml.safe_load(fh) or {}
    rows = []
    seen = set()
    for p in paths:
        with open(p) as fh:
            frag = yaml.safe_load(fh) or {}
        fid = frag.get("id")
        if fid in seen:
            _fail("duplicate work-item id '{}' across fragments".format(fid), 2)
        seen.add(fid)
        rows.append(_row_from_fragment(frag))
    rows.sort(key=lambda r: (str(r.get("id")), str(r.get("source"))))
    return {"meta": meta, "files": rows}


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--status-dir", default="port/status")
    ap.add_argument("--meta", default=None)
    ap.add_argument("--trace", default="port/TRACE.yaml")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    orig = os.getcwd()
    root = _repo_root()
    try:
        os.chdir(root)
    except OSError:
        _fail("cannot enter repo root '{}'".format(root), 2)

    # Explicit relative paths are resolved against the original CWD (so the seeded-bug
    # demo can point at a fixture); the default 'port/status' resolves at the repo root.
    def resolve(p, default):
        if os.path.isabs(p) or p == default:
            return p
        return os.path.join(orig, p)

    status_dir = resolve(args.status_dir, "port/status")
    trace_path = resolve(args.trace, "port/TRACE.yaml")
    meta_path = resolve(args.meta, None) if args.meta else os.path.join(status_dir, "_meta.yaml")

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse fragments (install pyyaml)", 2)

    if not args.check:
        model = build_trace(status_dir, meta_path, yaml)
        sys.stdout.write(yaml.dump(model, sort_keys=False, default_flow_style=False,
                                   allow_unicode=True))
        return

    # --check: drift-check the committed TRACE against the fragments.
    if not _fragment_paths(status_dir):
        print("check-trace-drift: no fragments under '{}' - nothing to check (skipping)."
              .format(status_dir))
        sys.exit(0)
    generated = build_trace(status_dir, meta_path, yaml)
    if not os.path.isfile(trace_path):
        _fail("fragments exist but committed TRACE '{}' is missing".format(trace_path), 2)
    with open(trace_path) as fh:
        committed = yaml.safe_load(fh) or {}
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
