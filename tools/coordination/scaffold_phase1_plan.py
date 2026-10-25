#!/usr/bin/env python3
"""scaffold_phase1_plan - write a starter port/phase1-plan.yaml so auto-mode has a Phase-1 loop to drive.

Phase 1 builds the comparison infrastructure (the differential harness, the proofs, the conformance
checks, the dependency-map extractor, the diff-tool classes) BEFORE any translation. The Phase-1
driver (tools/coordination/phase1_drive.py) reads port/phase1-plan.yaml; with no plan it HALTs with
nothing to drive, and /port-autodrive falls through to a Phase-2 plan that is all-guarded (every unit
waits on tooling that does not exist yet). Hand-authoring that plan from the template is the friction
this removes: it writes the methodology's canonical REPRESENTATIVE unit set - one valid BY
CONSTRUCTION (phase1_drive.py accepts it) - so the orchestrator can immediately claim Layer 0.

This is ABSTRACT, methodology-layer scaffolding: the unit set is the base charter's Phase-1 baseline
(references/parallel-phase-1.md, assets/phase1-plan.template.yaml), NOT anything program- or
language-specific. Every unit is written UNBUILT (accepted/integrated false, no evidence, no author);
the driver's fail-closed self-validation then walks each one through claim -> work -> independent
review -> mark-proven -> integrate on its real, committed F3 evidence. The scaffold is a to-do list of
tooling to build, never a claim that any of it is done.

What it does NOT do (by design - these stay human/domain inputs, not invented):
  - it does not sign Phase 0 (source_signed mirrors the phase0-signed tag; F0 still guards the driver);
  - it does not fill the §7 whole-program acceptance criterion (the parity band / tolerance table) -
    that is the domain-expert call the whole port is measured against, agreed with the human;
  - it does not add instance-specific tooling (extra diff classes, higher ladder tiers) - add those
    per port as it scales past the representative baseline.

Usage:
  scaffold_phase1_plan.py                 # write port/phase1-plan.yaml (source_signed from the phase0-signed tag)
  scaffold_phase1_plan.py --dry-run       # print what would be written; change nothing
  scaffold_phase1_plan.py --force         # overwrite an existing plan
  scaffold_phase1_plan.py --no-verify     # do not run phase1_drive.py after writing

Exit: 0 written and (when checkable) the driver finds an actionable plan; 1 refused / invalid input;
2 written but not yet drivable (e.g. Phase 0 unsigned, or PyYAML missing to verify).
"""
import argparse
import os
import subprocess
import sys
from _chisel_lib import repo_root as _repo_root

# The canonical REPRESENTATIVE Phase-1 unit set (base charter §7 "Phase 1 - Tooling", scope
# REPRESENTATIVE not exhaustive: each mechanism demonstrated once). Layer 0 is the harness everything
# compares THROUGH (proven first, F1); Layer 1 fans out once it integrates. Contracts wire
# producer-before-consumer (F2). An instance ADDS to this as it scales (the remaining diff-tool
# classes - boundary/communication probe, subsystem disable-switches, executable contracts - and the
# higher ladder tiers R2-R5); it does not need to remove from it.
UNITS = (
    dict(id="harness", layer=0, kind="harness", depends_on=(), provides="dump-format@1", consumes=(),
         note="the differential / capture-replay harness - everything else compares THROUGH it (Layer 0, proven first)"),
    dict(id="conventions", layer=1, kind="conventions", depends_on=(), provides="rendering-rules@1", consumes=(),
         note="port/conventions/<source>-to-<target>.md - naming map, type/precision table, comment policy, trap table + enforcement scripts"),
    dict(id="depmap", layer=1, kind="depmap", depends_on=(), provides="source-depmap@1", consumes=(),
         note="the SOURCE dependency-map extractor - inventory + proven in-tree edges + structural surfaces"),
    dict(id="diff-staged-dump", layer=1, kind="diff-tool", depends_on=("harness",), provides=None, consumes=("dump-format@1",),
         note="tool class 1: staged reference dump (operator-by-operator state at fixed probe points)"),
    dict(id="diff-operator", layer=1, kind="diff-tool", depends_on=("harness",), provides=None, consumes=("dump-format@1",),
         note="tool class 2: identical-input operator diff (localizes a divergence in the space of causes)"),
    dict(id="diff-range-probe", layer=1, kind="diff-tool", depends_on=("harness",), provides=None, consumes=("dump-format@1",),
         note="tool class 3: always-on range / sanity probe (catches silent 'allocated but never computed' corruption)"),
    dict(id="proofs-r0", layer=1, kind="proof", depends_on=("conventions",), provides=None, consumes=("rendering-rules@1",),
         note="validation-ladder R0 - intrinsic / bring-up checks, CI-runnable"),
    dict(id="proofs-r1", layer=1, kind="proof",
         depends_on=("harness", "diff-staged-dump", "diff-operator", "diff-range-probe", "conventions"),
         provides=None, consumes=("dump-format@1", "rendering-rules@1"),
         note="validation-ladder R1 - the first differential proof against the canonical reference run"),
    dict(id="anchor-verifier", layer=1, kind="check", depends_on=("conventions",), provides=None, consumes=("rendering-rules@1",),
         note="provenance-anchor verifier - constant anchors vs the pinned SOURCE line vs the TARGET rendering, plus coverage"),
)


def _phase0_signed(root):
    """True iff the phase0-signed milestone tag exists AND is an ancestor of HEAD. Base charter §8:
    that tag is created only after the human Phase-0 SIGNOFF.md, so it is the sign-off artifact; the
    ancestry check rejects a stray or unrelated tag (the signed commit must be in THIS history). The
    driver's F0 check refuses to fan out over an unsigned Phase 0; tracking the tag (no force-flag)
    keeps the scaffold from asserting a sign-off the human did not make."""
    try:
        rev = subprocess.run(["git", "rev-parse", "-q", "--verify", "refs/tags/phase0-signed^{commit}"],
                             cwd=root, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if rev.returncode != 0:
            return False
        tag_commit = rev.stdout.decode().strip()
        return subprocess.run(["git", "merge-base", "--is-ancestor", tag_commit, "HEAD"],
                              cwd=root, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except Exception:
        return False


def _evidence_keys(kind):
    """Required F3 evidence keys per kind (phase1_drive.KIND_EVIDENCE), in render order; readme_row is
    appended by the renderer as the one boolean. harness/diff-tool prove inertness; proof/check/depmap
    prove non-vacuity; all prove a seed, a source-side demo, and an independent review."""
    keys = ["seeded", "source_demo"]
    if kind in ("harness", "diff-tool"):
        keys.append("inertness")
    elif kind in ("proof", "check", "depmap"):
        keys.append("non_vacuity")
    keys.append("review")
    return keys


def _flow(items):
    return "[%s]" % ", ".join(items)


def render_unit(u):
    out = []
    if u.get("note"):
        out.append("  # %s" % u["note"])
    out.append("  - id: %s" % u["id"])
    out.append("    layer: %d" % u["layer"])
    out.append("    kind: %s" % u["kind"])
    out.append("    depends_on: %s" % _flow(u["depends_on"]))
    out.append("    provides_contract: %s" % (u["provides"] if u["provides"] else "null"))
    out.append("    consumes_contracts: %s" % _flow(u["consumes"]))
    out.append("    author_id: null            # set when the unit is claimed/worked")
    out.append("    reviewer_id: null          # the INDEPENDENT reviewer; MUST differ from author_id before mark-proven")
    out.append("    evidence:                  # each (but readme_row) a COMMITTED file under docs/evidence/phase1/%s/" % u["id"])
    for k in _evidence_keys(u["kind"]):
        out.append("      %s: null" % k)
    out.append("      readme_row: false        # set true once the tools/README enforcement row is ENFORCED")
    out.append("    accepted: false            # the orchestrator records this AFTER an independent clean review (mark-proven)")
    out.append("    integrated: false          # the integrator merged the component into the WORKBENCH (never the product)")
    return "\n".join(out)


def render(source_signed):
    header = (
        "# port/phase1-plan.yaml - the Phase-1 TOOL-BUILD plan the driver (phase1_drive.py) reads.\n"
        "# Scaffolded by tools/coordination/scaffold_phase1_plan.py from the methodology's canonical\n"
        "# representative unit set (base charter §7 'Phase 1'; references/parallel-phase-1.md). Every\n"
        "# unit is written UNBUILT - the driver walks each through claim/work/review/mark-proven/integrate\n"
        "# on its real committed F3 evidence; this file claims nothing is done. Adapt per port: add the\n"
        "# remaining diff-tool classes and higher ladder tiers as the port scales; the §7 whole-program\n"
        "# acceptance criterion (the parity band / tolerance table) stays a human-agreed domain input.\n"
        "\n"
        "schema_version: 1\n"
        "\n"
        "# F0 PREREQUISITE: do not fan out Phase-1 tooling over an unsigned Phase 0 (it would build\n"
        "# against a moving target). The driver HALTS until this is true; it mirrors the phase0-signed\n"
        "# milestone tag (an ancestor of HEAD, per charter §8), which the driver RE-VERIFIES - tag your\n"
        "# Phase-0 sign-off rather than hand-setting this.\n"
        "source_signed: %s\n"
        "\n"
        "units:\n"
    ) % ("true" if source_signed else "false")
    return header + "\n".join(render_unit(u) for u in UNITS) + "\n"


def main():
    ap = argparse.ArgumentParser(add_help=True, description="Scaffold a starter port/phase1-plan.yaml.")
    ap.add_argument("--force", action="store_true", help="overwrite an existing port/phase1-plan.yaml")
    ap.add_argument("--dry-run", action="store_true", help="print what would be written; change nothing")
    ap.add_argument("--no-verify", action="store_true", help="do not run phase1_drive.py after writing")
    args = ap.parse_args()

    root = _repo_root()
    target = os.path.join(root, "port", "phase1-plan.yaml")
    here = os.path.dirname(os.path.abspath(__file__))

    signed = _phase0_signed(root)
    text = render(signed)

    rel = os.path.relpath(target, os.getcwd())
    if args.dry_run:
        print("[dry-run] would write %s (source_signed: %s):\n" % (rel, "true" if signed else "false"))
        print(text)
        return
    if os.path.isfile(target) and not args.force:
        sys.stderr.write("scaffold-phase1-plan: %s already exists. Edit it by hand, or re-run with "
                         "--force to overwrite.\n" % rel)
        sys.exit(1)

    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("scaffold-phase1-plan: wrote %s (%d units; source_signed: %s)"
          % (rel, len(UNITS), "true" if signed else "false"))

    if not signed:
        print("  source_signed is false - the driver will HALT (F0) until Phase 0 is human-signed.")
        print("  Sign Phase 0 (pin SOURCE + config, archive the reference run, tag phase0-signed), then re-run.")
    print("  next: /port-autodrive drives Layer 0 (claim the harness) first; the Layer-1 pool opens once it integrates.")
    print("  human input auto-mode CANNOT invent: fill the §7 whole-program acceptance criterion (the")
    print("  parity band + tolerance table) before Phase 2 - it is the standard the port is measured against.")

    if args.no_verify:
        return
    driver = os.path.join(here, "phase1_drive.py")
    if not os.path.isfile(driver):
        return
    print("\n  verifying the plan is drivable (phase1_drive.py):")
    res = subprocess.run([sys.executable, driver], cwd=root)
    if res.returncode == 0:
        print("  -> the driver found an actionable Phase-1 plan.")
        sys.exit(0)
    if res.returncode == 1:
        print("  -> the driver HALTed (expected if Phase 0 is unsigned; otherwise see its output above).")
        sys.exit(2)
    print("  -> the plan did not verify (exit %d) - see the driver output above." % res.returncode)
    sys.exit(2)


if __name__ == "__main__":
    main()
