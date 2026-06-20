#!/usr/bin/env python3
"""adopt_substrate.py - bootstrap the autodrive coordination substrate from a hand-driven port.

A port done hand-driven (the single-operator pilot) keeps a SOURCE-keyed `port/TRACE.yaml` (its rows
carry no per-unit `id`) and no per-unit status fragments. Parallel autodrive needs the ID-KEYED
substrate: one `port/status/<id>.yaml` fragment per live unit, from which
`tools/coordination/generate_trace.py` regenerates the canonical id-keyed TRACE, and which the
planner (`autodrive.py`) and the dependency map correlate on. This tool DERIVES those fragments
deterministically from the existing TRACE, so a hand-driven port can switch to autodrive without
hand-authoring fragments.

THE UNIT ID = stem(source) (the source basename without extension) - the SAME key
`extract_dependencies.py` assigns map nodes and the planner unions on. It is IDEMPOTENT: an existing
fragment is never overwritten, so it is safe to re-run after more hand-driven sprints.

It writes (under port/status/, creating it):
  - `_meta.yaml`     from the TRACE `meta` block (source_root/target_root/commits), if absent
  - `<id>.yaml`      one per LIVE, UNMAPPED TRACE row that lacks a fragment (a minimal leaf fragment)

Scope (fail-closed and honest):
  - status `unmapped` (live, not yet started) -> a complete, valid leaf fragment is written. This is
    the fresh-translation-phase case (the reason you adopt at a phase boundary).
  - status `excluded` -> skipped: dead build variants are handled coarsely by
    tools/scoping/source-exclude.yaml, not as per-unit fragments (see team-coordination.md).
  - status `in-progress`/`gated` -> NOT fabricated and REPORTED: their fragments need real claim,
    author, and (gated) INDEPENDENT-review identity/evidence that this tool must never invent (that
    would defeat the independence the gate rests on). Author those few fragments by hand.

Usage:  adopt_substrate.py [--trace FILE] [--status-dir DIR] [--dry-run]
Exit:   0 wrote/verified the fragments (any in-progress/gated rows reported for hand-authoring);
        1 nothing to adopt (no TRACE, or no live rows); 2 UNRELIABLE (no PyYAML, malformed TRACE).
"""
import argparse
import os
import re
import sys
from typing import NoReturn
from _chisel_lib import strict_loader as _strict_loader, repo_root as _repo_root

# A work-item id is the SOURCE file stem and is ALSO the fragment filename (port/status/<id>.yaml) and
# the claim/correlation key, so it must be a safe token (same shape the coordination scripts accept).
_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
# check-status-fragments.sh is a deliberately simple LINE-oriented parser, not a YAML parser: it strips
# `#...` as a comment even inside a quoted value, treats any value containing `<` as the unset
# placeholder, and reads one line per field. So a source/target path PyYAML would emit validly (a `#`,
# `<`, control char, ...) could still be a fragment that checker rejects. Fail closed before writing on
# any LIVE source/target path outside this conservative allowlist the checker provably handles.
_PATH_RE = re.compile(r"^[A-Za-z0-9._/][A-Za-z0-9._/ +-]*$")


def _fail(msg) -> "NoReturn":
    sys.stderr.write("adopt-substrate: " + msg + "\n")
    sys.exit(2)


def _s(v):
    return "" if v is None else str(v).strip()


def _stem(source):
    return os.path.splitext(os.path.basename(_s(source)))[0]


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--trace", default=None)
    ap.add_argument("--status-dir", default=None)
    ap.add_argument("--dry-run", action="store_true")
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

    trace_path = resolve(args.trace, os.path.join("port", "TRACE.yaml"))
    status_dir = resolve(args.status_dir, os.path.join("port", "status"))

    if not os.path.isfile(trace_path):
        print("adopt-substrate: no port/TRACE.yaml to adopt from (run the hand-driven Phase 0/1 first).")
        sys.exit(1)
    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot read TRACE (install pyyaml)")
    try:
        with open(trace_path, encoding="utf-8") as fh:
            trace = yaml.load(fh, Loader=_strict_loader(yaml))
    except (OSError, yaml.YAMLError) as exc:
        _fail("cannot read TRACE '%s' (%s)" % (trace_path, exc))
    if not isinstance(trace, dict):
        _fail("TRACE '%s' is not a mapping" % trace_path)

    rows = trace.get("files")
    if rows is None:
        rows = []
    if not isinstance(rows, list):
        _fail("TRACE 'files' must be a list")

    # Validate every row up front, and collect by class - fail closed before writing anything.
    live, excluded, needs_hand, seen = [], 0, [], {}
    for row in rows:
        if not isinstance(row, dict):
            _fail("TRACE 'files' has a non-mapping row")
        src = _s(row.get("source"))
        if not src:
            _fail("a TRACE row has no 'source' - cannot derive a unit id")
        nid = _stem(src)
        if not nid:
            _fail("TRACE row source '%s' yields an empty unit id" % src)
        st = _s(row.get("status")) or "unmapped"
        if st == "excluded":
            # Excluded rows never become fragments (dead variants are coarse-excluded via
            # tools/scoping/source-exclude.yaml), so they do not participate in id-uniqueness.
            excluded += 1
            continue
        # A LIVE row becomes a fragment file named <id>.yaml and a correlation key, so the id (the
        # source stem) must be a safe token. Fail closed rather than emit an unsafe filename/key.
        if not _ID_RE.match(nid) or nid.lower() == "null":
            _fail("unit id '%s' (from source '%s') is not a usable id (must be a safe token "
                  "[A-Za-z0-9][A-Za-z0-9._-]* and not the reserved sentinel 'null') - rename the SOURCE "
                  "file or assign an explicit id; adopt will not invent one" % (nid, src))
        if not _PATH_RE.match(src):
            _fail("source path '%s' (unit '%s') has a character the line-oriented status-fragment checker "
                  "cannot carry (e.g. '#', '<', or a control char) - rename it; adopt will not emit a "
                  "fragment the checker would reject" % (src, nid))
        # Among the LIVE rows (the ones that become fragments) the unit id MUST be unique.
        if nid in seen and seen[nid] != src:
            _fail("two LIVE TRACE rows share unit id '%s' (%s and %s) - sources must have unique stems; "
                  "exclude a dead build variant in tools/scoping/source-exclude.yaml" % (nid, seen[nid], src))
        seen[nid] = src
        if st == "unmapped":
            tgt_raw = row.get("target")
            tgt = [str(t).strip() for t in tgt_raw] if isinstance(tgt_raw, list) else []
            tgt = [t for t in tgt if t]
            for t in tgt:
                if not _PATH_RE.match(t):
                    _fail("target path '%s' (unit '%s') has a character the line-oriented status-fragment "
                          "checker cannot carry - rename it" % (t, nid))
            live.append((nid, src, tgt))
        else:  # in-progress | gated
            needs_hand.append((nid, src, st))

    if not live and not needs_hand:
        print("adopt-substrate: TRACE has no live (non-excluded) rows - nothing to adopt.")
        sys.exit(1)

    made, skipped = [], []
    if not args.dry_run:
        os.makedirs(status_dir, exist_ok=True)

    # _meta.yaml (the generator reads it for the port-wide meta block) - never overwrite.
    meta_path = os.path.join(status_dir, "_meta.yaml")
    meta = trace.get("meta")
    if not isinstance(meta, dict):
        meta = {}
    if not os.path.isfile(meta_path):
        header = ("# Port-wide TRACE meta (adopted from port/TRACE.yaml by adopt_substrate.py).\n"
                  "# generate_trace.py reads this for source_root/target_root/commits.\n")
        meta_out = {k: meta.get(k) for k in ("source_root", "target_root", "upstream_commit", "source_commit")}
        _write(meta_path, header + _ydump(yaml, meta_out), args.dry_run)
        made.append(os.path.relpath(meta_path, root))

    for nid, src, tgt in live:
        frag_path = os.path.join(status_dir, nid + ".yaml")
        if os.path.isfile(frag_path):
            skipped.append(nid)
            continue
        # Build the fragment as data and let PyYAML emit it - it quotes/escapes ANY string safely. The
        # source/target paths were already allowlist-validated above to what the line-oriented checker
        # carries, so a hostile path can neither inject keys nor produce a fragment the checker rejects.
        text = ("# Adopted from the hand-driven port/TRACE.yaml by adopt_substrate.py. id = stem(source).\n"
                + _ydump(yaml, {"id": nid})
                + _ydump(yaml, {"source": src}))
        if tgt:
            # target must be an inline list (check-status-fragments requires `^\[.*\]$`).
            text += "target: " + _yflow(yaml, tgt) + "\n"
        text += _ydump(yaml, {"status": "unmapped"})
        text += _ydump(yaml, {"ownership": {"kind": "leaf", "workstream": None, "owned_surface": None}})
        _write(frag_path, text, args.dry_run)
        made.append(os.path.relpath(frag_path, root))

    tag = " [dry-run]" if args.dry_run else ""
    print("adopt-substrate: %d fragment file(s) written, %d already present, %d excluded row(s) skipped.%s"
          % (len(made), len(skipped), excluded, tag))
    for m in made:
        print("  + %s" % m)
    if needs_hand:
        print("adopt-substrate: %d live row(s) are already in-progress/gated - NOT fabricated (their claim/"
              "author/review evidence must be authored by hand, never invented):" % len(needs_hand))
        for nid, src, st in needs_hand:
            print("  ! %s (%s) %s" % (nid, st, src))
    print("adopt-substrate: next, build the map (extract_dependencies.py) and regenerate the id-keyed "
          "TRACE (generate_trace.py); then re-run the planner.")
    sys.exit(0)


def _ydump(yaml, d):
    """Emit a (small) mapping as block-style YAML text via PyYAML, which correctly quotes/escapes any
    string - the only safe way to serialize arbitrary path-derived values."""
    return yaml.safe_dump(d, default_flow_style=False, sort_keys=False, allow_unicode=True, width=10 ** 9)


def _yflow(yaml, seq):
    """Emit a list as an inline `[a, b]` scalar (each element safely quoted), for the `target` field
    which check-status-fragments requires in inline form (`^\\[.*\\]$`)."""
    return yaml.safe_dump(seq, default_flow_style=True, allow_unicode=True, width=10 ** 9).strip()


def _write(path, text, dry):
    if dry:
        return
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


if __name__ == "__main__":
    main()
