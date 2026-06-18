#!/usr/bin/env python3
"""Verify contributor identity: every author/reviewer/claimant id and session in the status
fragments (and claims) resolves to a registered contributor, and an author and reviewer are
never the SAME human - the anti-aliasing/anti-collusion check the fragment schema cannot do.

Why (references/team-coordination.md, "Identity is enforced only syntactically"):
check-status-fragments.sh enforces only that reviewer_id != author_id and reviewer_session is
not in author_sessions - SYNTACTIC independence. It cannot tell one human wearing two ids
apart, nor catch a reviewer working in the author's session. The contributor registry
(port/contributors.yaml, template assets/contributors.template.yaml) names, per contributor
id, the underlying HUMAN and the sessions they work in. This checker resolves every fragment
identity against the registry and fails if:

  REGISTRY   - it is malformed: schema_version is not the integer 1, an entry missing a string
               id/human, a duplicate id, or a session owned by two contributors.
  RESOLUTION - a fragment's author_id / reviewer_id (or a claim's claimant) is absent where
               required, not a string, not registered, or a session is registered to a
               DIFFERENT contributor than the id that used it.
  INDEPENDENCE - for a reviewed/gated fragment, author and reviewer resolve to the SAME human
               (two ids, one person), or the reviewer_session belongs to the author's human.

All identity values are compared by a CANONICAL key (Unicode NFC, trimmed, casefolded), so the
same human/session/id cannot be spelled two ways ("Person-Alice" vs " person-alice ") to look
distinct. Identity fields must be strings: a present-but-non-string author_id/reviewer_id/
reviewer_session, or a non-string author_sessions item, is a violation (not silently skipped).

Trust boundary: this defeats accidental aliasing and enforces the distinctness the registry
DECLARES; it cannot prove the registry's human keys match reality. The registry is
human-curated, reviewed like any protected surface.

Reads the registry (--registry, default port/contributors.yaml) and the fragments
(--status-dir, default port/status); --claims-dir additionally resolves claim claimants.
Before a registry exists (single-operator pilot) there is nothing to resolve against, so the
no-arg pass skips - only the syntactic fragment check applies until a registry is adopted.

Usage:  check_contributors.py [--registry FILE] [--status-dir DIR] [--claims-dir DIR]
Exit:   0 everything resolves (or no registry yet); 1 a violation; 2 UNRELIABLE.
"""
import argparse
import glob
import os
import subprocess
import sys
import unicodedata
from typing import NoReturn


def _fail(msg) -> "NoReturn":
    sys.stderr.write("check-contributors: " + msg + "\n")
    sys.exit(2)


def _repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def _strict_loader(yaml):
    """A SafeLoader that REJECTS duplicate mapping keys (so a second `sessions:` cannot quietly
    override a bad first one)."""
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


def _is_id_string(v):
    """An identity value must be a non-empty string. A YAML int/bool/float (123, true) or a
    mapping/list is NOT a valid id/human/session - rejecting them closes the 'non-scalar field
    silently treated as absent' gap."""
    return isinstance(v, str) and v.strip() != ""


def _is_placeholder(v):
    """An unfilled scaffold placeholder like <worker-human>: a string still carrying a <...> marker.
    Not a real identity (mirrors finalize.sh's Signed placeholder guard), so a scaffolded-but-unfilled
    registry is honestly RED until the distinct humans are filled in."""
    return isinstance(v, str) and ("<" in v or ">" in v)


def _key(v):
    """Canonical comparison key for an identity value: NFC-normalized, trimmed, casefolded - so
    the same human/session/id cannot be spelled two ways to look distinct."""
    return unicodedata.normalize("NFC", str(v).strip()).casefold()


def _fragment_paths(status_dir):
    # _meta.yaml holds the TRACE meta block, not a work item; exclude it (as generate_trace).
    return sorted(p for p in glob.glob(os.path.join(status_dir, "*.yaml"))
                  if os.path.basename(p) != "_meta.yaml")


def _team_mode_active(status_dir, claims_dir, yaml, loader):
    """Team mode = independence is being asserted or parallel claims exist, so a registry is
    MANDATORY (without one, a single human under two ids passes the syntactic check). True if any
    claim exists (refs/claims/* or a --claims-dir) or any fragment is gated."""
    if claims_dir is not None:
        if os.path.isdir(claims_dir) and glob.glob(os.path.join(claims_dir, "*.yaml")):
            return True
    else:
        try:
            raw = subprocess.check_output(["git", "for-each-ref", "--format=%(refname)", "refs/claims/"],
                                          stderr=subprocess.DEVNULL).decode()
            if [ln for ln in raw.splitlines() if ln.strip()]:
                return True
        except Exception:
            pass
    for p in _fragment_paths(status_dir):
        try:
            with open(p) as fh:
                frag = yaml.load(fh, Loader=loader)
        except Exception:
            continue
        if isinstance(frag, dict) and str(frag.get("status") or "").strip().casefold() == "gated":
            return True
    return False


def load_registry(path, yaml, loader):
    """Validate the registry and build the resolution index. Returns (violations, index|None).
    index = {id_human: {key(id)->key(human)|None}, id_raw: {key(id)->raw}, session_owner:
    {key(session)->key(id)}}."""
    try:
        with open(path) as fh:
            reg = yaml.load(fh, Loader=loader)
    except OSError as exc:
        _fail("cannot read registry '%s' (%s)" % (path, exc))
    except yaml.YAMLError as exc:
        return (["registry is not valid YAML (%s)" % exc], None)
    v = []
    if not isinstance(reg, dict):
        return (["registry is not a mapping"], None)
    sv = reg.get("schema_version")
    if not (type(sv) is int and sv == 1):
        v.append("registry schema_version must be the integer 1")
    contributors = reg.get("contributors")
    if not isinstance(contributors, list) or len(contributors) == 0:
        return (v + ["registry 'contributors' must be a non-empty list"], None)
    id_human, id_raw, session_owner, session_raw = {}, {}, {}, {}
    for i, c in enumerate(contributors):
        if not isinstance(c, dict):
            v.append("contributors[%d] is not a mapping" % i)
            continue
        cid = c.get("id")
        if not _is_id_string(cid):
            v.append("contributors[%d] 'id' must be a non-empty string" % i)
            continue
        if _is_placeholder(cid):
            v.append("contributors[%d] id '%s' is an unfilled <placeholder> - replace it with a real "
                     "identity (the registry was scaffolded)" % (i, cid))
            continue
        ck = _key(cid)
        human = c.get("human")
        ch = None
        if not _is_id_string(human):
            v.append("contributor '%s' 'human' must be a non-empty string" % cid)
        elif _is_placeholder(human):
            v.append("contributor '%s' 'human' is an unfilled <placeholder> '%s' - replace it with a "
                     "real distinct human (the registry was scaffolded)" % (cid, human))
        else:
            ch = _key(human)
        if ck in id_human:
            v.append("duplicate contributor id '%s' (ids are compared case/space-insensitively)" % cid)
            continue
        id_human[ck] = ch
        id_raw[ck] = cid
        sessions = c.get("sessions")
        if sessions is None:
            sessions = []
        if not isinstance(sessions, list):
            v.append("contributor '%s' 'sessions' must be a list" % cid)
            sessions = []
        for s in sessions:
            if not _is_id_string(s):
                v.append("contributor '%s' has a non-string session entry" % cid)
                continue
            sk = _key(s)
            if sk in session_owner:
                v.append("session '%s' is registered to both '%s' and '%s' (a session belongs "
                         "to one contributor)" % (s, session_raw[sk], cid))
                continue
            session_owner[sk] = ck
            session_raw[sk] = s
    return (v, {"id_human": id_human, "id_raw": id_raw, "session_owner": session_owner})


def _field(frag, name, v, fid):
    """Read an identity field: ('ok', raw) if a non-empty string, ('absent', None) if null/
    missing, ('bad', None) + a violation if present but not a string."""
    val = frag.get(name)
    if val is None:
        return ("absent", None)
    if not _is_id_string(val):
        v.append("%s: %s must be a string identity (got %s)" % (fid, name, type(val).__name__))
        return ("bad", None)
    return ("ok", val)


def verify_identity(fid, frag, idx):
    """Resolve a fragment's identity against the registry index; return violations."""
    v = []
    id_human = idx["id_human"]
    id_raw = idx["id_raw"]
    session_owner = idx["session_owner"]
    gated = str(frag.get("status") or "").strip().casefold() == "gated"

    a_state, aid = _field(frag, "author_id", v, fid)
    r_state, rid = _field(frag, "reviewer_id", v, fid)
    rs_state, rses = _field(frag, "reviewer_session", v, fid)

    asess = []
    asess_raw = frag.get("author_sessions")
    if asess_raw is not None:
        if not isinstance(asess_raw, list):
            v.append("%s: author_sessions must be a list" % fid)
        else:
            for s in asess_raw:
                if not _is_id_string(s):
                    v.append("%s: author_sessions has a non-string entry" % fid)
                else:
                    asess.append(s)

    # A gated piece must carry the full identity, or independence is not even checkable.
    if gated:
        if a_state != "ok":
            v.append("%s: a gated fragment needs a string author_id" % fid)
        if not asess:
            v.append("%s: a gated fragment needs a non-empty author_sessions" % fid)
        if r_state != "ok":
            v.append("%s: a gated fragment needs a string reviewer_id" % fid)
        if rs_state != "ok":
            v.append("%s: a gated fragment needs a string reviewer_session" % fid)

    ak = _key(aid) if aid else None
    rk = _key(rid) if rid else None
    rsk = _key(rses) if rses else None

    if aid and ak not in id_human:
        v.append("%s: author_id '%s' is not in the registry" % (fid, aid))
    for s in asess:
        owner = session_owner.get(_key(s))
        if owner is None:
            v.append("%s: author_session '%s' is not in the registry" % (fid, s))
        elif ak is not None and owner != ak:
            v.append("%s: author_session '%s' is registered to '%s', not author_id '%s'"
                     % (fid, s, id_raw.get(owner), aid))
    if rid and rk not in id_human:
        v.append("%s: reviewer_id '%s' is not in the registry" % (fid, rid))
    if rses:
        owner = session_owner.get(rsk)
        if owner is None:
            v.append("%s: reviewer_session '%s' is not in the registry" % (fid, rses))
        elif rk is not None and owner != rk:
            v.append("%s: reviewer_session '%s' is registered to '%s', not reviewer_id '%s'"
                     % (fid, rses, id_raw.get(owner), rid))

    # INDEPENDENCE: author and reviewer must be DISTINCT humans (not two ids of one person).
    if ak is not None and rk is not None:
        ha, hr = id_human.get(ak), id_human.get(rk)
        if ha is not None and hr is not None and ha == hr:
            v.append("%s: author '%s' and reviewer '%s' are the same human '%s' (aliased ids - "
                     "not an independent review)" % (fid, aid, rid, ha))
    # ... and the reviewer's session must not belong to the author's human.
    if ak is not None and rsk is not None:
        ha = id_human.get(ak)
        howner = id_human.get(session_owner.get(rsk))
        if ha is not None and howner is not None and ha == howner:
            v.append("%s: reviewer_session '%s' belongs to the author's human '%s' (not an "
                     "independent review)" % (fid, rses, ha))
    return v


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--registry", default=None)
    ap.add_argument("--status-dir", default=None)
    ap.add_argument("--claims-dir", default=None)
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

    registry = resolve(args.registry, "port/contributors.yaml")
    status_dir = resolve(args.status_dir, "port/status")
    if args.status_dir is not None and not os.path.isdir(status_dir):
        _fail("--status-dir '%s' is not a directory" % args.status_dir)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse the registry (install pyyaml)")
    loader = _strict_loader(yaml)

    # Registry presence: an explicit --registry must be a file. The default may be ABSENT only in
    # SOLO mode; once independence is asserted (a gated fragment) or parallel claims exist, a
    # missing registry is RED - syntactic independence alone cannot bind ids to distinct humans.
    if args.registry is not None:
        if not os.path.isfile(registry):
            _fail("--registry '%s' is not a file" % args.registry)
    else:
        if not os.path.lexists(registry):
            cdir = (args.claims_dir if os.path.isabs(args.claims_dir)
                    else os.path.join(orig, args.claims_dir)) if args.claims_dir else None
            if _team_mode_active(status_dir, cdir, yaml, loader):
                print("  [FAIL] no contributor registry at port/contributors.yaml, but team mode is "
                      "active (a gated fragment or a claim exists): independence cannot be bound to "
                      "distinct humans. Add port/contributors.yaml.")
                print("check-contributors: RESULT: RED (exit 1) - team mode requires a registry.")
                sys.exit(1)
            print("check-contributors: no registry at port/contributors.yaml and no team-mode "
                  "artifacts (no gated fragment, no claims) - nothing to resolve against (skipping; "
                  "the syntactic fragment check still applies).")
            sys.exit(0)
        if not os.path.isfile(registry):
            _fail("port/contributors.yaml exists but is not a regular file")

    reg_viol, idx = load_registry(registry, yaml, loader)
    fails = 0
    for msg in reg_viol:
        print("  [FAIL] registry: %s" % msg)
        fails += 1
    if idx is None:
        print("check-contributors: the registry is unusable; %d violation(s)." % fails)
        print("RESULT: RED (exit 1) - fix the registry before identities can be resolved.")
        sys.exit(1)

    n_frag = 0
    for p in _fragment_paths(status_dir):
        try:
            with open(p) as fh:
                frag = yaml.load(fh, Loader=loader)
        except OSError as exc:
            _fail("cannot read fragment '%s' (%s)" % (p, exc))
        except yaml.YAMLError as exc:
            print("  [FAIL] %s: not valid YAML (%s)" % (os.path.basename(p), exc))
            fails += 1
            continue
        if not isinstance(frag, dict):
            print("  [FAIL] %s: fragment is not a mapping" % os.path.basename(p))
            fails += 1
            continue
        n_frag += 1
        fid = str(frag.get("id") or os.path.splitext(os.path.basename(p))[0])
        for msg in verify_identity(fid, frag, idx):
            print("  [FAIL] %s" % msg)
            fails += 1

    n_claim = 0
    if args.claims_dir is not None:
        cdir = resolve(args.claims_dir, "")
        if not os.path.isdir(cdir):
            _fail("--claims-dir '%s' is not a directory" % args.claims_dir)
        for p in sorted(glob.glob(os.path.join(cdir, "*.yaml"))):
            try:
                with open(p) as fh:
                    claim = yaml.load(fh, Loader=loader)
            except OSError as exc:
                _fail("cannot read claim '%s' (%s)" % (p, exc))
            except yaml.YAMLError:
                continue  # claim YAML well-formedness is check-claims' job, not ours
            if not isinstance(claim, dict):
                continue
            n_claim += 1
            cid = str(claim.get("id") or os.path.splitext(os.path.basename(p))[0])
            claimant = claim.get("claimant")
            if claimant is None:
                continue  # a missing claimant is check-claims' required-field concern
            if not _is_id_string(claimant):
                print("  [FAIL] claim %s: claimant must be a string identity (got %s)"
                      % (cid, type(claimant).__name__))
                fails += 1
            elif _key(claimant) not in idx["id_human"]:
                print("  [FAIL] claim %s: claimant '%s' is not in the registry" % (cid, claimant))
                fails += 1

    print("check-contributors: registry of %d contributor(s); checked %d fragment(s)%s; "
          "%d violation(s)." % (len(idx["id_human"]), n_frag,
                                (" and %d claim(s)" % n_claim) if args.claims_dir else "", fails))
    if fails:
        print("RESULT: RED (exit 1) - an identity does not resolve, or a review was not independent.")
        sys.exit(1)
    print("RESULT: GREEN (exit 0) - every identity resolves and every review is between distinct humans.")
    sys.exit(0)


if __name__ == "__main__":
    main()
