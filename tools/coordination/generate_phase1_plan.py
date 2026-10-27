#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""Generate canonical port/phase1-plan.yaml from per-unit fragments.

Shard-and-generate pattern (mirrors tools/coordination/generate_trace.py and the TRACE
pattern in references/team-coordination.md): contributors edit only their own
port/phase1/units/<id>.yaml in their branch; the canonical port/phase1-plan.yaml is
GENERATED from those fragments, never hand-merged.  This removes the shared-registry
collision class: two sibling branches that update different units touch DISJOINT files -
port/phase1/units/<id-a>.yaml vs port/phase1/units/<id-b>.yaml - so integration is a
clean merge of fragments followed by a deterministic regeneration, instead of a 3-way
line merge of one central plan that git resolves silently and WRONGLY when near-identical
unit stanzas abut (a rebase drops a "patch already upstream" hunk; a plain merge picks one
side) - corruption with no conflict signal.

phase1_drive.py is UNCHANGED: it reads port/phase1-plan.yaml exactly as before; the
shard-and-generate model is transparent to it.

Meta file (port/phase1/_meta.yaml) owns: schema_version, source_signed (top-level
plan scalars), and the stable ordering of units in the generated file.

Fragment files (port/phase1/units/<id>.yaml) each own exactly ONE unit's stanza
(the id, layer, kind, depends_on, contracts, author/reviewer, evidence, accepted,
integrated).  A 'note' key in a fragment is a human-readable description; the
generator discards it (note is not a UNIT_KEY in phase1_drive.py).

Usage:
  generate_phase1_plan.py [--units-dir DIR] [--meta FILE] [--output FILE]
      Assemble port/phase1-plan.yaml from the fragments.
      --output FILE  write to FILE (default: stdout)

  generate_phase1_plan.py --check [--units-dir DIR] [--meta FILE] [--plan FILE]
      Drift-check: regenerate from fragments and compare to the committed plan.

Exit codes:
  0  OK / GREEN       plan written; or committed plan matches the fragments
  1  RED  / DRIFT     committed plan differs from the fragments (--check only)
  2  UNRELIABLE       cannot run (missing PyYAML / meta / malformed fragment)
"""
import argparse
import glob
import os
import subprocess
import sys
from typing import Any, Dict, List, NoReturn, Optional, Tuple
from _chisel_lib import strict_loader as _strict_loader, repo_root as _repo_root
from _chisel_lib import modern as _modern, VocabularyConflict

# ---------------------------------------------------------------------------
# Known UNIT_KEYS from phase1_drive.py  (generator must not produce others)
# ---------------------------------------------------------------------------
UNIT_KEYS: frozenset = frozenset({
    "id", "layer", "kind", "depends_on", "provides_contract", "consumes_contracts",
    "author_id", "reviewer_id", "reviewed_commit", "evidence", "accepted", "integrated",
    "extra_evidence",
})
KNOWN_EVIDENCE: frozenset = frozenset(
    {"seeded", "source_demo", "inertness", "non_vacuity", "review", "readme_row"}
)
META_REQUIRED: frozenset = frozenset({"schema_version", "source_signed", "ordering"})


def _fail(msg: str, code: int = 2) -> NoReturn:
    sys.stderr.write("generate-phase1-plan: " + msg + "\n")
    sys.exit(code)


def _load_yaml(path: str, yaml: Any, loader: Any) -> Dict:
    """Load a YAML file as a dict, failing on error or wrong type."""
    try:
        with open(path, encoding="utf-8") as fh:
            raw = _modern(yaml.load(fh, Loader=loader))  # legacy-vocab: old names map on load
    except FileNotFoundError:
        _fail("'%s' not found" % path)
    except yaml.YAMLError as exc:
        _fail("'%s' is not valid YAML: %s" % (path, exc))
    except VocabularyConflict as exc:
        _fail("'%s' mixes old and new names: %s" % (path, exc))
    if not isinstance(raw, dict):
        _fail("'%s' must be a YAML mapping, got %s" % (path, type(raw).__name__))
    return raw  # type: ignore[return-value]


def load_meta(meta_path: str, yaml: Any, loader: Any) -> Dict:
    """Load and validate port/phase1/_meta.yaml.  Returns the meta dict."""
    meta = _load_yaml(meta_path, yaml, loader)
    missing = META_REQUIRED - set(meta.keys())
    if missing:
        _fail("meta '%s' is missing required keys: %s"
              % (meta_path, ", ".join(sorted(missing))))
    if meta.get("schema_version") != 1:
        _fail("meta '%s': schema_version must be integer 1" % meta_path)
    if meta.get("source_signed") not in (True, False):
        _fail("meta '%s': source_signed must be a boolean" % meta_path)
    ordering = meta.get("ordering")
    if not (isinstance(ordering, list) and ordering
            and all(isinstance(x, str) and x.strip() for x in ordering)):
        _fail("meta '%s': ordering must be a non-empty list of strings" % meta_path)
    _stripped = [x.strip() for x in ordering]
    _dups = sorted({x for x in _stripped if _stripped.count(x) > 1})
    if _dups:
        _fail("meta '%s': ordering has duplicate id(s): %s - each unit appears exactly once "
              "(a duplicate would generate a plan phase1_drive.py rejects as malformed)"
              % (meta_path, ", ".join(_dups)))
    return meta


def load_fragment(frag_path: str, yaml: Any, loader: Any) -> Tuple[str, Dict]:
    """Load and validate a unit fragment.  Returns (unit_id, unit_dict)."""
    raw = _load_yaml(frag_path, yaml, loader)
    uid_raw = raw.get("id")
    if not isinstance(uid_raw, str) or not uid_raw.strip():
        _fail("fragment '%s': missing or empty 'id'" % frag_path)
    uid = uid_raw.strip()
    # Allow 'note' (human description) - generator discards it; reject anything else unknown
    unknown = set(raw.keys()) - UNIT_KEYS - {"note"}
    if unknown:
        _fail("fragment '%s': unknown keys: %s (only UNIT_KEYS allowed plus 'note')"
              % (frag_path, ", ".join(sorted(unknown))))
    # Validate evidence dict keys
    ev = raw.get("evidence")
    if ev is not None:
        if not isinstance(ev, dict):
            _fail("fragment '%s': 'evidence' must be a mapping" % frag_path)
        bad_ev = set(ev.keys()) - KNOWN_EVIDENCE
        if bad_ev:
            _fail("fragment '%s': unknown evidence keys: %s"
                  % (frag_path, ", ".join(sorted(bad_ev))))
    # Build the clean unit dict (UNIT_KEYS only, dropping 'note')
    unit = {k: raw[k] for k in UNIT_KEYS if k in raw}
    return uid, unit


def _fragment_paths(units_dir: str) -> List[str]:
    return sorted(glob.glob(os.path.join(units_dir, "*.yaml")))


def build_model(units_dir: str, meta_path: str, yaml: Any) -> Dict:
    """Build the canonical plan data model from fragments + meta.  Deterministic."""
    loader = _strict_loader(yaml)
    meta = load_meta(meta_path, yaml, loader)
    ordering: List[str] = [x.strip() for x in meta["ordering"]]

    # Load all fragment files
    fragments: Dict[str, Dict] = {}
    for p in _fragment_paths(units_dir):
        uid, unit = load_fragment(p, yaml, loader)
        if uid in fragments:
            _fail("duplicate unit id '%s' (from file: %s)" % (uid, p))
        fragments[uid] = unit

    # Validate: ordering and fragment ids must be identical sets
    frag_ids = set(fragments.keys())
    order_ids = set(ordering)
    extra_in_order = order_ids - frag_ids
    extra_in_frags = frag_ids - order_ids
    if extra_in_order:
        _fail("meta ordering references unit(s) with no fragment: %s"
              % ", ".join(sorted(extra_in_order)))
    if extra_in_frags:
        _fail("fragment(s) not listed in meta ordering: %s "
              "(add to port/phase1/_meta.yaml ordering)"
              % ", ".join(sorted(extra_in_frags)))

    units: List[Dict] = [fragments[uid] for uid in ordering]
    model = {
        "schema_version": meta["schema_version"],
        "source_signed": meta["source_signed"],
        "units": units,
    }
    # Guarantee the generated plan is one phase1_drive.py ACCEPTS - validate it with the driver's OWN
    # loader (one source of truth), so the generator can never greenlight a plan the driver rejects.
    _assert_driver_valid(model, yaml)
    return model


def _assert_driver_valid(model: Dict, yaml: Any) -> None:
    """Reuse phase1_drive.py's fail-closed `load_plan` validator on the rendered model, so the
    generator never emits a plan the driver would reject (duplicate ids, unknown kind, bad layer or
    booleans or contracts). Reused, not re-implemented, so the two can never drift apart."""
    import tempfile
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import phase1_drive as _drv
    except Exception as exc:
        _fail("cannot import phase1_drive.py to validate the generated plan (%s)" % exc)
    loader = _strict_loader(yaml)
    text = render_plan(model)
    fd, tmp = tempfile.mkstemp(prefix="phase1-plan-gen-", suffix=".yaml")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        state, _signed, _units = _drv.load_plan(tmp, yaml, loader)
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass
    if state != "ok":
        _fail("the generated plan is %s per phase1_drive.py's validator - the fragments/meta would "
              "produce a plan the driver rejects (e.g. duplicate id, unknown kind, bad layer). "
              "Fix the fragments." % state)


# ---------------------------------------------------------------------------
# Renderer - produces readable YAML without relying on PyYAML's dump format
# so the output is stable and human-readable.  Comments are stripped by the
# YAML parser so the data model is all that matters for drift-check.
# ---------------------------------------------------------------------------

def _evidence_key_order(kind: str) -> List[str]:
    """Canonical evidence key order, matching scaffold_phase1_plan.py._evidence_keys.
    readme_row is always last (non-file assertion, rendered separately)."""
    keys = ["seeded", "source_demo"]
    if kind in ("harness", "diff-tool"):
        keys.append("inertness")
    elif kind in ("proof", "check", "depmap"):
        keys.append("non_vacuity")
    keys.append("review")
    keys.append("readme_row")
    return keys


def _scalar(v: Any) -> str:
    """Render a scalar as a bare YAML value (no quoting needed for our value set)."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    # Strings: plain scalar is safe for all values stored here (paths, ids, contract names)
    return str(v)


def _flow_list(items: List) -> str:
    """Render a list as a YAML flow sequence (matches current phase1-plan.yaml style)."""
    if not items:
        return "[]"
    return "[%s]" % ", ".join(_scalar(i) for i in items)


def _render_unit(u: Dict) -> str:
    """Render one unit stanza as YAML text (indented for the units: block sequence)."""
    lines: List[str] = []
    lines.append("  - id: %s" % _scalar(u.get("id")))
    lines.append("    layer: %s" % _scalar(u.get("layer")))
    lines.append("    kind: %s" % _scalar(u.get("kind")))
    lines.append("    depends_on: %s" % _flow_list(u.get("depends_on") or []))
    lines.append("    provides_contract: %s" % _scalar(u.get("provides_contract")))
    lines.append("    consumes_contracts: %s" % _flow_list(u.get("consumes_contracts") or []))
    lines.append("    author_id: %s" % _scalar(u.get("author_id")))
    lines.append("    reviewer_id: %s" % _scalar(u.get("reviewer_id")))
    ev: Optional[Dict] = u.get("evidence")
    if ev is not None:
        lines.append("    evidence:")
        kind: str = u.get("kind") or ""
        canonical_keys = _evidence_key_order(kind)
        # Emit canonical keys that exist in ev, in canonical order
        for k in canonical_keys:
            if k in ev:
                lines.append("      %s: %s" % (k, _scalar(ev[k])))
        # Emit any extra evidence keys not in the canonical order (safety valve)
        for k in sorted(set(ev.keys()) - set(canonical_keys)):
            lines.append("      %s: %s" % (k, _scalar(ev[k])))
    else:
        lines.append("    evidence: null")
    lines.append("    accepted: %s" % _scalar(u.get("accepted")))
    lines.append("    integrated: %s" % _scalar(u.get("integrated")))
    # extra_evidence: include only when present and non-empty (matches phase1_drive.py UNIT_KEYS)
    extra = u.get("extra_evidence")
    if extra:
        lines.append("    extra_evidence: %s" % _flow_list(extra))
    return "\n".join(lines)


_HEADER = """\
# port/phase1-plan.yaml - GENERATED by tools/coordination/generate_phase1_plan.py.
# DO NOT EDIT by hand.  Edit the per-unit fragment in port/phase1/units/<id>.yaml
# then regenerate:
#   python3 tools/coordination/generate_phase1_plan.py --output port/phase1-plan.yaml
# Drift is caught by tools/conformance/check-phase1-plan.sh (CI-enforced).
#
# phase1_drive.py reads this file unchanged; the shard-and-generate model is
# transparent to it.

"""

_F0_COMMENT = """\
# F0 PREREQUISITE: do not fan out Phase-1 tooling over an unsigned Phase 0 (it would
# build against a moving target).  The driver HALTS until source_signed is true and the
# phase0-signed tag (charter §8) is an ancestor of HEAD - it RE-VERIFIES independently.
"""


def render_plan(model: Dict) -> str:
    """Render the plan data model as a canonical YAML string."""
    sv = model["schema_version"]
    ss = model["source_signed"]
    parts = [_HEADER]
    parts.append("schema_version: %s\n\n" % _scalar(sv))
    parts.append(_F0_COMMENT)
    parts.append("source_signed: %s\n\n" % _scalar(ss))
    parts.append("units:\n")
    for u in model["units"]:
        parts.append(_render_unit(u))
        parts.append("\n")
    return "".join(parts)


# ---------------------------------------------------------------------------
# Drift check
# ---------------------------------------------------------------------------

def _model_eq(generated: Dict, committed_raw: Dict) -> Tuple[bool, str]:
    """Return (equal, reason) comparing the generated model to the committed plan."""
    if generated.get("schema_version") != committed_raw.get("schema_version"):
        return False, "schema_version differs (gen=%r committed=%r)" % (
            generated.get("schema_version"), committed_raw.get("schema_version"))
    if generated.get("source_signed") != committed_raw.get("source_signed"):
        return False, "source_signed differs (gen=%r committed=%r)" % (
            generated.get("source_signed"), committed_raw.get("source_signed"))
    g_units: List[Dict] = generated.get("units") or []
    c_units: List[Dict] = committed_raw.get("units") or []
    if len(g_units) != len(c_units):
        return False, "unit count differs (generated=%d committed=%d)" % (
            len(g_units), len(c_units))
    for i, (gu, cu) in enumerate(zip(g_units, c_units)):
        all_keys = set(list(gu.keys()) + list(cu.keys())) - {"note"}
        for k in sorted(all_keys):
            gv = gu.get(k)
            cv = cu.get(k)
            if gv != cv:
                return False, (
                    "unit[%d] id=%s key=%s differs (gen=%r committed=%r)" % (
                        i, gu.get("id", "?"), k, gv, cv))
    return True, ""


def drift_check(units_dir: str, meta_path: str, plan_path: str, yaml: Any) -> int:
    """Compare the committed plan to what the fragments generate.  Returns exit code."""
    if not _fragment_paths(units_dir):
        print("check-phase1-plan: no unit fragments under '%s' - nothing to check (skipping)."
              % units_dir)
        return 0

    generated = build_model(units_dir, meta_path, yaml)

    if not os.path.isfile(plan_path):
        sys.stderr.write(
            "check-phase1-plan: fragments exist but committed plan '%s' is missing.\n"
            "  Regenerate: python3 tools/coordination/generate_phase1_plan.py "
            "--output port/phase1-plan.yaml\n" % plan_path)
        return 2

    loader = _strict_loader(yaml)
    try:
        with open(plan_path, encoding="utf-8") as fh:
            committed_raw = _modern(yaml.load(fh, Loader=loader) or {})
    except (yaml.YAMLError, VocabularyConflict) as exc:
        sys.stderr.write("check-phase1-plan: committed plan '%s' is not valid YAML: %s\n"
                         % (plan_path, exc))
        return 2
    if not isinstance(committed_raw, dict):
        sys.stderr.write("check-phase1-plan: committed plan '%s' is not a mapping\n" % plan_path)
        return 2

    ok, reason = _model_eq(generated, committed_raw)
    if ok:
        print("check-phase1-plan: committed plan matches %d fragment(s).  RESULT: GREEN"
              % len(generated["units"]))
        return 0
    sys.stderr.write("check-phase1-plan: committed plan DRIFTS from the fragments.\n")
    sys.stderr.write("  %s\n" % reason)
    sys.stderr.write("  Regenerate: python3 tools/coordination/generate_phase1_plan.py "
                     "--output port/phase1-plan.yaml\n")
    sys.stderr.write("RESULT: RED (exit 1)\n")
    return 1


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Generate or drift-check port/phase1-plan.yaml from unit fragments.")
    ap.add_argument("--units-dir", default=None,
                    help="directory containing per-unit .yaml fragments "
                         "(default: port/phase1/units)")
    ap.add_argument("--meta", default=None,
                    help="meta YAML with schema_version/source_signed/ordering "
                         "(default: port/phase1/_meta.yaml)")
    ap.add_argument("--output", default=None,
                    help="write generated plan to FILE instead of stdout")
    ap.add_argument("--plan", default=None,
                    help="path to the committed plan for --check "
                         "(default: port/phase1-plan.yaml)")
    ap.add_argument("--check", action="store_true",
                    help="drift-check the committed plan against the fragments")
    args = ap.parse_args()

    orig = os.getcwd()
    root = _repo_root()
    try:
        os.chdir(root)
    except OSError:
        _fail("cannot enter repo root '%s'" % root)

    def resolve(p: Optional[str], default_rel: str) -> str:
        if p is None:
            return default_rel
        return p if os.path.isabs(p) else os.path.join(orig, p)

    units_dir = resolve(args.units_dir, "port/phase1/units")
    meta_path = resolve(args.meta, "port/phase1/_meta.yaml")
    plan_path = resolve(args.plan, "port/phase1-plan.yaml")

    try:
        import yaml as _yaml  # type: ignore[import]
    except Exception:
        _fail("PyYAML not available - install pyyaml")

    if args.check:
        sys.exit(drift_check(units_dir, meta_path, plan_path, _yaml))

    model = build_model(units_dir, meta_path, _yaml)
    text = render_plan(model)

    if args.output:
        out_path = (args.output if os.path.isabs(args.output)
                    else os.path.join(orig, args.output))
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(text)
        print("generate-phase1-plan: wrote %s (%d units, source_signed: %s)"
              % (os.path.relpath(out_path, orig), len(model["units"]),
                 _scalar(model["source_signed"])))
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
