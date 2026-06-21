#!/usr/bin/env python3
"""phase1_drive - the READ-ONLY, DETERMINISTIC planner for Phase-1 tool-build auto-mode.

Phase 1 builds the comparison infrastructure (the differential harness, the gates, the conformance
checks, the dependency-map extractor, the six diff-tool classes) before any translation. This is the
autodrive.py analog for that build: given the Phase-1 plan (port/phase1-plan.yaml) + the live claims
+ which evidence records are COMMITTED, it maps each tooling unit to the ONE recommended next action
and reports the stop conditions - writing nothing, computing nothing authoritative, exactly like
autodrive.py and the dashboard whose fail-closed load layer it reuses. The orchestrator (the
executor) turns the plan into dispatched agents and git operations within the charter's autonomy
level/scope/budget and commits every piece's evidence to git as it goes; the action vocabulary is
identical to Phase 2.

Unlike Phase 2 (where the conformance suite validates TRACE/fragments BEFORE the planner
runs), no gate validates the Phase-1 plan's self-reported flags - so this planner SELF-VALIDATES and
fails CLOSED: `integrated`/`accepted` are trusted only when backed by complete, committed F3 evidence
and an independent clean review; anything malformed, forged, inconsistent, or unverifiable becomes
triage/blocked, never a false claim/work/mark-gated/integrate/done.

Phase-1-specific rules it enforces (references/parallel-phase-1.md):
  F0  source_signed must be true (a human-signed Phase 0) - else HALT: no fan-out over a moving target.
  F1  Layer-0 bootstrap: no layer>=1 unit is claimable/integratable until EVERY layer-0 unit is
      trusted-integrated (the harness everything compares through is gated before the pool opens).
  F2  producer-before-consumer: a unit's depends_on, and the producer of every contract it consumes,
      must be integrated first; a consumed version behind the producer's current is STALE.
  F3  acceptance is broader than a seed: a unit is not mark-gated/accepted until ALL required records
      hold - a seeded red->green, a source-side demo, inertness (harness/diff-tool) or non-vacuity
      (gate/check/depmap), an INDEPENDENT review (distinct author_id/reviewer_id) whose verdict is
      clean, and the README enforcement row - each a COMMITTED file under docs/evidence/phase1/<id>/.

Independence is the different-model reviewer recorded per unit (a distinct reviewer_id != author_id);
there is no contributor registry - in a solo+agents port the reviewer agent on a different model is
the independence control, not an anti-collusion registry.

Per-unit action: claim | work (build + seed + record F3 evidence) | review (a DISTINCT reviewer) |
rework | mark-gated (record acceptance) | integrate (into the workbench) | blocked | triage | done.

Usage:  phase1_drive.py [--plan FILE] [--claims-dir DIR | --from-refs] [--phase LABEL]
Exit:   0 a plan with actions, or DONE; 1 STUCK/blocked (at L2/L3 usually a drivable ordering - Layer 0
        first, an unmet dep - or a genuine blocker like an unsigned Phase 0 (F0), which IS a human gate;
        derive-and-proceed where drivable, halt only on the genuine decision); 2 UNRELIABLE
        (the plan is malformed, or PyYAML missing).
"""
import argparse
import os
import re
import subprocess
import sys
import unicodedata
from typing import NoReturn

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import dashboard as D  # noqa: E402  (reuse the read-only load + fail-closed helpers + claim loader)
import autodrive as A  # noqa: E402  (reuse the strict review-verdict grammar + the table - single source)

ACTIONABLE = ("claim", "work", "review", "rework", "mark-gated", "integrate")
ORDER = {a: i for i, a in enumerate(
    ("integrate", "mark-gated", "review", "rework", "work", "claim", "blocked", "release", "triage", "done"))}

KINDS = ("harness", "diff-tool", "gate", "check", "depmap", "conventions")
_BASE_EVIDENCE = ("seeded", "source_demo", "review", "readme_row")
# Required F3 evidence per kind: inertness for the byte-inert harness / diff tools; non_vacuity for
# the detectors (a gate/check/extractor must exercise its target set and fail closed on a missing root).
KIND_EVIDENCE = {
    "harness": _BASE_EVIDENCE + ("inertness",),
    "diff-tool": _BASE_EVIDENCE + ("inertness",),
    "gate": _BASE_EVIDENCE + ("non_vacuity",),
    "check": _BASE_EVIDENCE + ("non_vacuity",),
    "depmap": _BASE_EVIDENCE + ("non_vacuity",),
    "conventions": _BASE_EVIDENCE,
}
KNOWN_EVIDENCE = ("seeded", "source_demo", "inertness", "non_vacuity", "review", "readme_row")
EVIDENCE_ROOT = "docs/evidence/phase1/"
_CONTRACT_RE = re.compile(r"^[^@\s]+@[^@\s]+$")  # name@version, both non-empty, single @
_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
TOP_KEYS = {"schema_version", "source_signed", "units"}
UNIT_KEYS = {"id", "layer", "kind", "depends_on", "provides_contract", "consumes_contracts",
             "author_id", "reviewer_id", "evidence", "accepted", "integrated", "extra_evidence"}
_committed_cache = {}


def _fail(msg) -> "NoReturn":
    sys.stderr.write("phase1-drive: " + msg + "\n")
    sys.exit(2)


def _phase0_signed():
    """F0 verified INDEPENDENTLY of the plan's self-reported source_signed: the phase0-signed
    milestone tag (base charter §8 - created only after the human Phase-0 SIGNOFF.md) exists AND is an
    ancestor of HEAD. The plan's boolean is the author's claim; this is what a stale or hand-edited
    plan cannot self-certify. Run at repo root (main() chdir's there); fail closed on any git error."""
    try:
        rev = subprocess.run(["git", "rev-parse", "-q", "--verify", "refs/tags/phase0-signed^{commit}"],
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if rev.returncode != 0:
            return False
        return subprocess.run(["git", "merge-base", "--is-ancestor", rev.stdout.decode().strip(), "HEAD"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except Exception:
        return False


def _str_list_ok(v):
    return v is None or (isinstance(v, list) and all(isinstance(x, str) and x.strip() for x in v))


def load_plan(path, yaml, loader):
    """(state, source_signed, units): state absent|malformed|ok. Fail closed - schema_version must be
    1; ids unique and safe; layer a non-negative int; kind known; accepted/integrated booleans;
    author_id/reviewer_id non-empty strings; depends_on/consumes/extra_evidence string lists; every
    extra_evidence key known; provides/consumes a 'name@version'; no two units provide the same
    contract name; and unknown top-level/unit/evidence keys are rejected (a typo like depends_onn
    cannot silently drop a dependency)."""
    state, data = D._load(path, yaml, loader)
    if state != "ok":
        return (state, False, {})
    if data.get("schema_version") != 1 or (set(data) - TOP_KEYS):
        return ("malformed", False, {})
    raw = data.get("units")
    if raw is None:
        raw = []
    if not isinstance(raw, list):
        return ("malformed", False, {})
    units, provided = {}, {}
    for u in raw:
        if not isinstance(u, dict) or (set(u) - UNIT_KEYS):  # reject unknown/typo'd keys (e.g. depends_onn)
            return ("malformed", False, {})
        rid = u.get("id")
        if not isinstance(rid, str):
            return ("malformed", False, {})
        uid = rid.strip()
        if not uid or uid in units or not _ID_RE.match(uid):
            return ("malformed", False, {})
        layer = u.get("layer")
        if isinstance(layer, bool) or not isinstance(layer, int) or layer < 0:
            return ("malformed", False, {})
        if not isinstance(u.get("kind"), str) or u.get("kind") not in KINDS:
            return ("malformed", False, {})
        for b in ("accepted", "integrated"):
            if u.get(b) is not None and not isinstance(u.get(b), bool):
                return ("malformed", False, {})
        for sk in ("author_id", "reviewer_id"):
            sv = u.get(sk)
            if sv is not None and not (isinstance(sv, str) and sv.strip()):
                return ("malformed", False, {})
        for lk in ("depends_on", "consumes_contracts", "extra_evidence"):
            if not _str_list_ok(u.get(lk)):
                return ("malformed", False, {})
        for ek in (u.get("extra_evidence") or []):
            if ek not in KNOWN_EVIDENCE:
                return ("malformed", False, {})
        ev = u.get("evidence")
        if ev is not None and (not isinstance(ev, dict) or (set(ev) - set(KNOWN_EVIDENCE))):
            return ("malformed", False, {})
        pc = u.get("provides_contract")
        if pc is not None:
            if not (isinstance(pc, str) and _CONTRACT_RE.match(pc.strip())):
                return ("malformed", False, {})
            name = pc.strip().split("@", 1)[0]
            provided[name] = provided.get(name, 0) + 1
        for c in (u.get("consumes_contracts") or []):
            if not _CONTRACT_RE.match(c.strip()):
                return ("malformed", False, {})
        units[uid] = u
    if any(n > 1 for n in provided.values()):  # two units provide the same contract name -> ambiguous
        return ("malformed", False, {})
    return ("ok", data.get("source_signed") is True, units)


def _key(s):
    return unicodedata.normalize("NFC", str(s)).strip().casefold()


def _required(u):
    out, seen = [], set()
    for k in tuple(KIND_EVIDENCE.get(D._s(u.get("kind"), ""), _BASE_EVIDENCE)) + tuple(u.get("extra_evidence") or []):
        if k not in seen:
            seen.add(k); out.append(k)
    return tuple(out)


def _committed(path, unit_id):
    """A real evidence record for `unit_id`: a workbench-relative path under
    docs/evidence/phase1/<unit_id>/, with no '..' and no control chars, that is NOT a symlink (nor
    reached through a symlinked parent that escapes the evidence root), is git-tracked, AND is CLEAN
    (worktree == HEAD, so the on-disk bytes equal the committed blob - a dirtied file does not count).
    Fail CLOSED on any error or ambiguity, including git being unavailable. Memoized per (unit, path)."""
    p = (path or "").strip()
    ck = (unit_id, p)
    if ck in _committed_cache:
        return _committed_cache[ck]
    ok = False
    prefix = EVIDENCE_ROOT + unit_id + "/"
    try:
        if (p and unit_id and not os.path.isabs(p) and "\x00" not in p
                and not any(ord(c) < 32 for c in p)
                and ".." not in p.replace("\\", "/").split("/")
                and p.startswith(prefix)
                and os.path.isfile(p) and not os.path.islink(p)
                and os.path.commonpath([os.path.realpath(p), os.path.realpath(EVIDENCE_ROOT)])
                == os.path.realpath(EVIDENCE_ROOT)):
            tracked = subprocess.run(["git", "ls-files", "--error-unmatch", "--", p],
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            clean = subprocess.run(["git", "diff", "--quiet", "HEAD", "--", p],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
            ok = tracked and clean
    except (OSError, ValueError, subprocess.SubprocessError):
        ok = False  # cannot verify (fs/git error) => not trusted evidence
    _committed_cache[ck] = ok
    return ok


def _ev_satisfied(u, key):
    v = (u.get("evidence") or {}).get(key)
    if key == "readme_row":
        return v is True  # the only non-file assertion
    return isinstance(v, str) and _committed(v, D._s(u.get("id"), ""))


def _missing_evidence(u):
    return [k for k in _required(u) if k != "review" and not _ev_satisfied(u, k)]


def _review_verdict(u):
    v = (u.get("evidence") or {}).get("review")
    if not (isinstance(v, str) and _committed(v, D._s(u.get("id"), ""))):
        return "none"  # an uncommitted/absent/symlinked/dirty/out-of-tree review path is not a review
    return A._verdict(v.strip())


def _accept_ready(u):
    """(ready, reason): all required F3 evidence committed, an INDEPENDENT review (distinct
    author_id/reviewer_id) whose verdict is clean. The single source of 'is this unit acceptable'."""
    miss = _missing_evidence(u)
    if miss:
        return (False, "missing evidence: " + ", ".join(miss))
    v = _review_verdict(u)
    if v != "clean":
        return (False, "independent review not clean (%s)" % v)
    author, reviewer = D._s(u.get("author_id"), ""), D._s(u.get("reviewer_id"), "")
    if not author or not reviewer:
        return (False, "missing author_id/reviewer_id (review independence unverified)")
    if _key(author) == _key(reviewer):
        return (False, "author_id and reviewer_id are the same identity (review not independent)")
    return (True, "")


def _contract_index(units):
    """{contract_name: (producer_id, version)} - load_plan guarantees a valid name@version and no
    duplicate provider, so the split is safe and the mapping unambiguous."""
    idx = {}
    for uid, u in units.items():
        pc = D._s(u.get("provides_contract"), "")
        if pc and "@" in pc:
            name, ver = pc.split("@", 1)
            idx[name.strip()] = (uid, ver.strip())
    return idx


def _contract_deps(u, cidx):
    """(producer_ids, issues): map each consumed name@version to its producer; an absent producer or
    a version behind the producer's current is an issue (fail closed)."""
    producers, issues = [], []
    for c in (u.get("consumes_contracts") or []):
        name, ver = c.strip().split("@", 1)
        name, ver = name.strip(), ver.strip()
        if name not in cidx:
            issues.append("consumes contract '%s' but no unit provides it" % c.strip())
            continue
        pid, pver = cidx[name]
        producers.append(pid)
        if ver != pver:
            issues.append("consumes %s@%s but the producer provides %s@%s (stale; rebase + re-accept)"
                          % (name, ver, name, pver))
    return (producers, issues)


def _deps(u, units, cidx):
    deps = {D._s(d, "") for d in (u.get("depends_on") or []) if D._s(d, "")}
    cprod, cissues = _contract_deps(u, cidx)
    return (deps | set(cprod), cissues)


def _trusted_integrated(units, cidx):
    """Fixpoint of the units that are LEGITIMATELY integrated: integrated:true AND accepted:true AND
    acceptance-ready AND no contract issue AND every dep already trusted-integrated AND (layer>=1) all
    layer-0 trusted-integrated. An integrated:true unit failing any of these is NOT trusted (and is
    surfaced as triage by _unit_action) - so a forged flag can never open the pool or report DONE."""
    layer0 = [uid for uid, u in units.items() if u.get("layer") == 0]
    integ, changed = set(), True
    while changed:
        changed = False
        l0_done = bool(layer0) and all(x in integ for x in layer0)
        for uid, u in units.items():
            if uid in integ or u.get("integrated") is not True or u.get("accepted") is not True:
                continue
            if not _accept_ready(u)[0]:
                continue
            deps, cissues = _deps(u, units, cidx)
            if cissues or any(d not in integ for d in deps):
                continue
            if u.get("layer") >= 1 and not l0_done:
                continue
            integ.add(uid); changed = True
    return (integ, bool(layer0) and all(x in integ for x in layer0), bool(layer0))


def _unit_action(uid, units, claims, integrated, layer0_present, layer0_done, cidx):
    u = units[uid]
    layer = u.get("layer")
    claim = claims.get(uid)
    cstate = D._s(claim.get("state"), "") if claim else ""
    accepted = u.get("accepted") is True
    integ_flag = u.get("integrated") is True
    deps, cissues = _deps(u, units, cidx)
    unknown = sorted(d for d in deps if d not in units)
    unmet = sorted(d for d in deps if d in units and d not in integrated)
    pool_closed = layer >= 1 and not layer0_done
    pool_reason = ("the plan defines no Layer 0 unit - F1 requires the differential harness gated first"
                   if not layer0_present else
                   "Layer 0 not fully integrated yet (F1: gate Layer 0 before the pool opens)")
    ready, accept_why = _accept_ready(u)

    if claim and claim.get("mismatch"):
        return ("triage", uid, "claim ref/file id does not match the unit id (misfiled claim)")
    if cissues:
        return ("triage", uid, "; ".join(cissues))
    if unknown:
        return ("triage", uid, "depends on a unit not in the plan: " + ", ".join(unknown))

    if uid in integrated:
        return ("done", uid, "accepted + integrated into the workbench")
    if integ_flag:  # flag set but NOT trusted-integrated - surface exactly why (fail closed)
        if not ready:
            return ("triage", uid, "marked integrated but not acceptance-ready: " + accept_why)
        if unmet:
            return ("triage", uid, "marked integrated but a dependency is not integrated: " + ", ".join(unmet))
        if pool_closed:
            return ("triage", uid, "marked integrated but " + pool_reason)
        return ("triage", uid, "marked integrated but inconsistent with the trusted-integrated set")

    if accepted:
        if not ready:
            return ("triage", uid, "marked accepted but not acceptance-ready: " + accept_why)
        if unmet:
            return ("blocked", uid, "accepted; waiting on deps to integrate: " + ", ".join(unmet))
        if pool_closed:
            return ("blocked", uid, "accepted; " + pool_reason)
        return ("integrate", uid, "accepted (F3 complete, independent clean review) + deps integrated; merge into the workbench")

    if claim and cstate in D.LIVE_CLAIM:
        if pool_closed:
            return ("triage", uid, "UNSAFE live claim: " + pool_reason)
        if unmet:
            return ("triage", uid, "UNSAFE live claim: deps not integrated: " + ", ".join(unmet))
        miss = _missing_evidence(u)
        if miss:
            return ("work", uid, "claimed; build + seed + record evidence (missing: %s)" % ", ".join(miss))
        verdict = _review_verdict(u)
        if verdict == "violations":
            return ("rework", uid, "independent review returned VIOLATIONS; re-work (never auto-accept)")
        if verdict != "clean":
            return ("review", uid, "F3 evidence complete; awaiting INDEPENDENT review (a DISTINCT agent/session)")
        if not ready:  # evidence + clean verdict, but reviewer independence is unverified
            return ("triage", uid, "review present but " + accept_why)
        return ("mark-gated", uid, "F3 complete + independent clean review; record acceptance")
    if cstate == "stale":
        return ("triage", uid, "stale claim; human triage (never auto-freed)")
    if claim:
        return ("triage", uid, "claim state '%s' is not valid" % cstate)

    if unmet:
        return ("blocked", uid, "waiting on deps to integrate: " + ", ".join(unmet))
    if pool_closed:
        return ("blocked", uid, pool_reason)
    return ("claim", uid, "ready: Phase 0 signed, unclaimed, deps + Layer 0 integrated")


def build_plan(units, claims):
    cidx = _contract_index(units)
    integrated, layer0_done, layer0_present = _trusted_integrated(units, cidx)
    out = []
    for uid in sorted(set(units) | set(claims)):
        if uid in units:
            out.append(_unit_action(uid, units, claims, integrated, layer0_present, layer0_done, cidx))
        else:  # a claim for an id absent from the plan: a leftover/stray claim (typically a completed
            # prior-phase claim) - surfaced as releasable CLEANUP, never invisible and never a stop
            out.append(("release", uid, "leftover/stray claim for a unit absent from the Phase-1 plan; "
                        "release it (release_claim.sh %s removes port/claims/%s.yaml + any pushed ref)" % (uid, uid)))
    out.sort(key=lambda a: (ORDER.get(a[0], 99), a[1]))
    return out


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--plan", default=None)
    ap.add_argument("--claims-dir", default=None)
    ap.add_argument("--from-refs", action="store_true",
                    help="read the pushed refs/claims/* (advanced multi-operator path)")
    ap.add_argument("--phase", default="1 (tooling)")
    args = ap.parse_args()
    if args.from_refs and args.claims_dir is not None:
        _fail("--from-refs and --claims-dir are mutually exclusive (one claim source)")

    orig = os.getcwd()
    root = D._repo_root()
    try:
        os.chdir(root)
    except OSError:
        _fail("cannot enter repo root '%s'" % root)
    _committed_cache.clear()

    def resolve(p, default_rel):
        if p is None:
            return default_rel
        return p if os.path.isabs(p) else os.path.join(orig, p)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot read the Phase-1 plan (install pyyaml)")
    loader = D._strict_loader(yaml)

    p_state, signed, units = load_plan(resolve(args.plan, os.path.join("port", "phase1-plan.yaml")), yaml, loader)
    c_state, claims = D.load_claims(resolve(args.claims_dir, None) if args.claims_dir else None,
                                    yaml, loader, from_refs=args.from_refs)

    print("phase1-drive plan  (read-only; the orchestrator executes within charter scope/budget)")
    print("  phase: %s   artifacts: plan %s, claims %s" % (args.phase, p_state, c_state))
    print()

    if p_state == "malformed" or c_state == "malformed":
        bad = [n for n, s in (("plan", p_state), ("claims", c_state)) if s == "malformed"]
        print("HALT: %s malformed - the plan is UNRELIABLE. Fix and re-run." % ", ".join(bad))
        sys.exit(2)
    if p_state == "absent" or not units:
        print("HALT: no Phase-1 plan yet (port/phase1-plan.yaml) - nothing to drive.")
        print("  Scaffold the canonical set with tools/coordination/scaffold_phase1_plan.py (or author")
        print("  from assets/phase1-plan.template.yaml) once Phase 0 is signed; then re-run.")
        sys.exit(1)
    if not signed:
        print("HALT: source_signed is not true - do NOT fan out Phase-1 tooling over an unsigned Phase 0 (F0).")
        print("  Pin the SOURCE + configuration, archive the reference run, and sign Phase 0 first.")
        sys.exit(1)
    if not _phase0_signed():
        print("HALT: the plan declares source_signed: true but no phase0-signed tag is an ancestor of HEAD (F0).")
        print("  Auto-mode will not fan out on a self-certified sign-off: tag the human Phase-0 sign-off as")
        print("  phase0-signed (base charter §8). A hand-set source_signed cannot substitute for the tag.")
        sys.exit(1)

    plan = build_plan(units, claims)
    do = [a for a in plan if a[0] in ACTIONABLE]
    wait = [a for a in plan if a[0] not in ACTIONABLE and a[0] != "done"]
    done_units = [a for a in plan if a[0] == "done"]

    print("DO (actionable now - dispatch within charter scope/budget):")
    print(A._table(do))
    print()
    print("WAIT / REPORT (not auto-driven):")
    print(A._table(wait + done_units))
    print()

    all_done = bool(plan) and all(a[0] == "done" for a in plan)
    if all_done:
        print("DONE: every Phase-1 unit is accepted + integrated into the workbench - Layer 0 and the")
        print("  Layer-1 components are ready. Prepare the phase digest (/port-digest) for human sign-off.")
        sys.exit(0)
    if not do:
        releases = [a for a in wait if a[0] == "release"]
        stuck = [a for a in wait if a[0] != "release"] or [("triage", "-", "no actionable units")]
        print("STUCK: nothing per-unit actionable. At L2/L3 this is usually a DRIVABLE ordering (Layer 0")
        print("  must gate first, an unmet dep) - drive it, do not auto-halt; HALT only for a genuine")
        print("  blocker (an unsigned Phase 0, a stale contract, an inconsistent unit): %s" % ", ".join(sorted(a[1] for a in stuck)))
        if releases:
            print("  leftover claims to release (cleanup, not blocking): %s"
                  % ", ".join(sorted(a[1] for a in releases)))
        sys.exit(1)
    print("VERDICT: ACTIONS - %d to do, %d waiting, %d done." % (len(do), len(wait), len(done_units)))
    sys.exit(0)


if __name__ == "__main__":
    main()
