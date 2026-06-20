#!/usr/bin/env python3
"""autodrive - the READ-ONLY, DETERMINISTIC planner for orchestrator auto-mode.

references/auto-mode.md: the orchestrator can drive a port with no human keystroke by turning the
wave loop with a planner instead of a hand. This is that planner. Given the current artifacts
(generated TRACE + dependency map + claims), it maps each SOURCE unit's derived state to the ONE
recommended next action and reports the stop conditions - and writes nothing, computes nothing
authoritative, exactly like the dashboard it is built on. The orchestrator (the executor) turns the
plan into dispatched agents and git operations, within the charter's autonomy level / scope /
budget, and commits every piece's evidence to git as it goes. Keeping this planner pure is what makes
an auto-run auditable and re-runnable: re-run autodrive at any committed state and you get the same
plan the bot acted on.

It reuses dashboard.py's fail-closed join (load + guard) so the "what is ready / guarded / unsafe"
logic is single-source with the human-facing dashboard. A guarded unit (coupling, partial coverage,
shared surface) is NEVER recommended for an auto-claim; an owned foundation is reported for its
owner; a malformed artifact HALTS (fail-closed), never a false "nothing to do".

Per-unit action: claim (ready) | work (claimed, porting+gating) | review (gate passed, needs a
DISTINCT reviewer) | rework (review returned violations) | mark-gated (gate + clean review) |
integrate (gated, deps integrated) | park (declaration-only unit: R0-done + reviewed, validated
TRANSITIVELY by a consuming unit's R1 - never gated at R0, never halts the drive) | assign (owned
foundation) | guarded | blocked | triage | done.

Usage:  autodrive.py [--trace FILE] [--map FILE] [--claims-dir DIR | --from-refs] [--phase LABEL]
Exit:   0 a plan with actions, or DONE; 1 HALT (a stop condition needs a human); 2 UNRELIABLE
        (a present artifact is malformed, or PyYAML missing).
"""
import argparse
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dashboard as D  # noqa: E402  (reuse the read-only join + fail-closed guard)

ACTIONABLE = ("claim", "work", "review", "rework", "mark-gated", "integrate")
ORDER = {a: i for i, a in enumerate(
    ("integrate", "mark-gated", "review", "rework", "work", "claim",
     "assign", "blocked", "guarded", "park", "release", "triage", "done"))}


def _fail(msg):
    sys.stderr.write("autodrive: " + msg + "\n")
    sys.exit(2)


def _verdict(path):
    """clean | violations | none, from a review report (the same strict grammar
    check-trace-evidence uses). Violations is checked FIRST and includes 'not clean', so a
    'VERDICT: not clean' line can never be read as clean; clean requires the word 'clean'
    immediately after 'verdict' + separators (so 'cleanup'/'not clean' do not count)."""
    if not path or not os.path.isfile(path):
        return "none"
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return "none"
    if re.search(r"verdict[: ].*(violation|not clean)", text, re.I):
        return "violations"
    if re.search(r"verdict[: ]+clean\b", text, re.I):
        return "clean"
    return "none"


def _unit_action(uid, trace, nodes, surfaces, edges, claims, integrated, deps_of):
    t = trace.get(uid) or {}
    status = D._s(t.get("status"), "")
    integ = D._s(t.get("integration"), "")
    claim = claims.get(uid)
    cstate = D._s(claim.get("state"), "") if claim else ""
    _guarded, reasons, _inc = D._guard(uid, nodes, surfaces, edges)
    non_owner = [r for r in reasons if r != "owned-foundation"]
    unmet = sorted(d for d in deps_of.get(uid, set()) if d not in integrated)

    if status == "excluded":
        return None
    # Fail closed: a unit absent from the generated TRACE is never actionable (no status to act on);
    # the planner must not assume check-completeness ran before it, so it blocks here too.
    if uid not in trace:
        if uid in nodes:
            return ("triage", uid, "no TRACE row - absent from the generated TRACE (run check-completeness)")
        # A claim-only id, in neither the TRACE nor the dependency map: a leftover/stray claim, not a
        # current-phase unit - typically a completed PRIOR-PHASE claim (e.g. Phase-1 tooling whose unit
        # is not in the Phase-2 TRACE). Surface it as releasable CLEANUP, never a scoping/seam HALT.
        return ("release", uid, "leftover/stray claim - its unit is in neither this phase's TRACE nor "
                "the map; release it (release_claim.sh %s removes port/claims/%s.yaml + any pushed ref)" % (uid, uid))
    if integ == "integrated":
        return ("done", uid, "integrated")
    if status == "gated":
        # A gated piece that still carries UNRESOLVED coupling (a suspected/unknown out-edge or a
        # shared surface - not just owned-foundation) must NOT auto-integrate: the dep graph it would
        # integrate against is incomplete, so a human resolves the coupling first.
        if non_owner:
            return ("triage", uid, "gated but has unresolved coupling (%s); a human reviews the "
                    "integration (suspected/shared edges are never auto-cleared)" % ", ".join(non_owner))
        if unmet:
            return ("blocked", uid, "gated; waiting on deps to integrate: " + ", ".join(unmet))
        return ("integrate", uid, "gated + clean-reviewed; all proven deps integrated")
    if claim and cstate in D.LIVE_CLAIM:
        if non_owner:
            return ("triage", uid, "UNSAFE live claim on a guarded unit: " + ", ".join(non_owner))
        gate_tier = D._s(t.get("gate_tier"), "")
        if not gate_tier:
            return ("work", uid, "claimed; worker porting + gating")
        verdict = _verdict(t.get("review"))
        if verdict == "violations":
            return ("rework", uid, "review returned VIOLATIONS; re-work (never auto-gate)")
        if verdict == "clean":
            # A declaration-only unit (validation: transitive) has no behavior to differentially test
            # in isolation, so R0 + a clean review is its terminal in-isolation state; R0 can NEVER gate
            # (check-trace-evidence), and it is validated TRANSITIVELY when a unit that consumes it passes
            # its R1 differential. PARK it (never mark-gated) so the drive CONTINUES instead of halting on
            # a gate it can physically never reach.
            if D._s(t.get("validation"), "") == "transitive":
                return ("park", uid, "declaration-only (validation: transitive); R0-done + clean review - "
                        "validated transitively by a consuming unit's R1, parked (not gated)")
            return ("mark-gated", uid, "gate %s passed + clean review; record gated" % gate_tier)
        return ("review", uid, "gate %s passed; awaiting independent review (a DISTINCT agent)" % gate_tier)
    if cstate == "stale":
        return ("triage", uid, "stale claim; human triage (never auto-freed)")
    if claim:
        return ("triage", uid, "claim state '%s' is not valid" % cstate)
    if uid not in nodes:
        return ("triage", uid, "no dependency-map node; cannot assess")
    if "owned-foundation" in reasons and not non_owner:
        return ("assign", uid, "owned foundation; assign to its owner (not auto-claimed from the pool)")
    if non_owner:
        return ("guarded", uid, "guarded (%s); human scoping, not auto-claimed" % ", ".join(non_owner))
    if unmet:
        return ("blocked", uid, "waiting on deps: " + ", ".join(unmet))
    return ("claim", uid, "ready: unclaimed, eligible, all proven deps integrated")


def build_plan(trace, nodes, surfaces, edges, claims):
    integrated = {u for u, t in trace.items() if D._s(t.get("integration"), "") == "integrated"}
    deps_of = {}
    for e in edges:
        frm, to = D._s(e.get("from"), ""), D._s(e.get("to"), "")
        if frm and to and D._s(e.get("confidence"), "") == "proven":
            deps_of.setdefault(frm, set()).add(to)
    ids = sorted(set(trace) | set(nodes) | set(claims))
    out = []
    for uid in ids:
        a = _unit_action(uid, trace, nodes, surfaces, edges, claims, integrated, deps_of)
        if a is not None:
            out.append(a)
    out.sort(key=lambda a: (ORDER.get(a[0], 99), a[1]))
    return out


def _table(rows):
    if not rows:
        return "  (none)"
    w0 = max(len(r[0]) for r in rows)
    w1 = max(len(r[1]) for r in rows)
    return "\n".join("  %s  %s  - %s" % (r[0].ljust(w0), r[1].ljust(w1), r[2]) for r in rows)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--trace", default=None)
    ap.add_argument("--map", default=None)
    ap.add_argument("--claims-dir", default=None)
    ap.add_argument("--from-refs", action="store_true",
                    help="read the pushed refs/claims/* (advanced multi-operator path)")
    ap.add_argument("--phase", default="2 (translation)")
    args = ap.parse_args()
    if args.from_refs and args.claims_dir is not None:
        _fail("--from-refs and --claims-dir are mutually exclusive (one claim source)")

    orig = os.getcwd()
    root = D._repo_root()
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
    loader = D._strict_loader(yaml)

    trace_path = resolve(args.trace, os.path.join("port", "TRACE.yaml"))
    t_state, trace = D.load_trace(trace_path, yaml, loader)
    m_state, nodes, surfaces, edges = D.load_map(
        resolve(args.map, os.path.join("tools", "scoping", "dependency-map.yaml")), yaml, loader)
    c_state, claims = D.load_claims(resolve(args.claims_dir, None) if args.claims_dir else None,
                                    yaml, loader, from_refs=args.from_refs)

    print("autodrive plan  (read-only; the orchestrator executes within charter scope/budget)")
    print("  phase: %s   artifacts: TRACE %s, map %s, claims %s" % (args.phase, t_state, m_state, c_state))
    print()

    if "malformed" in (t_state, m_state, c_state):
        bad = [n for n, s in (("TRACE", t_state), ("map", m_state), ("claims", c_state)) if s == "malformed"]
        print("HALT: %s malformed - the plan is UNRELIABLE. Regenerate and re-run." % ", ".join(bad))
        sys.exit(2)
    if not trace and not nodes and not claims:
        if os.path.isfile(trace_path):
            # A TRACE file exists but the id-keyed join is empty - a hand-driven, SOURCE-keyed pilot
            # TRACE (rows without `id`). Build the substrate (the Phase-2 analogue of the Phase-1
            # scaffold), then re-run; this is deterministic derive-and-proceed, not a human decision.
            print("HALT: a port/TRACE.yaml exists but yields no id-keyed units - a hand-driven (pilot) "
                  "TRACE with no per-unit fragments/map. Build the substrate: WRITE one minimal "
                  "port/status/<id>.yaml per live UNMAPPED row (id = stem(source); see "
                  "assets/status-fragment.template.yaml) + port/status/_meta.yaml, NEVER fabricating an "
                  "in-progress/gated fragment; then extract_dependencies.py (the map) and generate_trace.py "
                  "(id-keyed TRACE); then re-run. (A duplicate-stem error from extract_dependencies means a "
                  "multi-variant SOURCE - declare the dead variants in tools/scoping/source-exclude.yaml.)")
        else:
            print("HALT: no coordination substrate yet (solo / pre-scoping) - nothing to drive.")
        sys.exit(1)

    plan = build_plan(trace, nodes, surfaces, edges, claims)
    do = [a for a in plan if a[0] in ACTIONABLE]
    wait = [a for a in plan if a[0] not in ACTIONABLE and a[0] != "done"]
    done_units = [a for a in plan if a[0] == "done"]

    print("DO (actionable now - dispatch within charter scope/budget):")
    print(_table(do))
    print()
    print("WAIT / REPORT (not auto-driven):")
    print(_table(wait + done_units))
    print()

    non_excluded = [a for a in plan]  # excluded units already dropped (None)
    all_done = bool(non_excluded) and all(a[0] == "done" for a in non_excluded)
    if all_done:
        print("DONE: every non-excluded SOURCE unit is integrated - prepare the sign-off digest (/port-digest).")
        sys.exit(0)
    if not do:
        releases = [a for a in wait if a[0] == "release"]
        parked = [a for a in wait if a[0] == "park"]
        scoping = [a for a in wait if a[0] not in ("release", "park")]
        if scoping:
            print("HALT: nothing actionable and not done (stuck). A human looks - typically guarded/blocked.")
            print("  units needing scoping or seam work: %s" % ", ".join(sorted(a[1] for a in scoping)))
            if parked:
                print("  declaration-only units parked (NOT blocking; validated transitively): %s"
                      % ", ".join(sorted(a[1] for a in parked)))
            if releases:
                print("  leftover claims to release (cleanup, not scoping): %s"
                      % ", ".join(sorted(a[1] for a in releases)))
            sys.exit(1)
        # Only parked (declaration-only) units (and maybe stray releases) remain: NOT stuck. The real
        # work is done; these await TRANSITIVE validation by a consuming unit's R1. Report and let the
        # human confirm at sign-off; never a HALT.
        print("PARKED (not stuck): no actionable units; the remaining are declaration-only, validated "
              "transitively by their consumers - confirm those consumers gated at R1, then sign off.")
        print("  parked: %s" % ", ".join(sorted(a[1] for a in parked)))
        if releases:
            print("  leftover claims to release: %s" % ", ".join(sorted(a[1] for a in releases)))
        print("  Prepare the sign-off digest (/port-digest).")
        sys.exit(0)
    print("VERDICT: ACTIONS - %d to do, %d waiting, %d done." % (len(do), len(wait), len(done_units)))
    sys.exit(0)


if __name__ == "__main__":
    main()
