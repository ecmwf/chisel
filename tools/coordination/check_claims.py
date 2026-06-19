#!/usr/bin/env python3
"""Verify work-item claims: each claim is well-formed, no two live claims cover the same
SOURCE, and (per branch) a claimant's branch touches only what its claim allows.

Claims (references/team-coordination.md, "Claims: the local lock, atomic"): a claim RESERVES a
work item before porting begins. By default the claim is a LOCAL file port/claims/<trace-id>.yaml
that provision_worker.sh writes alongside the worker's isolated worktree - the worktree IS the
write lock, the file records what it covers. The pushed ref refs/claims/<trace-id> (read with
--from-refs) is the advanced multi-operator path, where push-to-create is the atomic collision
detector. This tool checks the things the file system / git ref machinery cannot:

  SCHEMA     - each claim is valid YAML; id/claimant/created/state are non-empty scalars; the
               `id` is a valid trace-id and equals the file/ref name's <trace-id>; `state` is
               created|active|stale; source/target/paths, WHEN PRESENT, are non-empty block lists
               of clean repo-relative paths (source/target concrete - no glob, no '..', not
               absolute; paths may use directory-aware globs). A claim ref must point to a BLOB.
  DUPLICATE  - no two NON-RELEASED claims (created|active|stale) cover overlapping source or
               target, and no two share an id. Overlap with a STALE claim is RED on purpose:
               stale means "needs human triage", never auto-freed, so a new claim over a stale
               one is the offline-active-branch duplication the substrate warns about.
  BRANCH-DIFF- run per branch (not in the no-arg CI pass): every file the branch changed lies
               within the claim's write surface (its `paths`, or the derived default = target
               + port/status/<id>.yaml), and - when an owned-surface list is supplied - the
               branch does not reach into an owned surface its claim was not explicitly granted.

Paths are canonicalized and validated (posixpath.normpath; absolute paths and any that escape
the repo root via '..' are rejected). Glob matching is directory-aware: '*'/'?' do not cross
'/', and '**' spans directories. Character-class globs ('[...]') are not supported.

Claims are read from port/claims/*.yaml by default; --from-refs reads refs/claims/* instead (git
cat-file the blob each ref points to), and --claims-dir DIR reads <trace-id>.yaml files from an
arbitrary dir (fixtures/tests). The branch file list comes from EITHER --files-from FILE (one
repo-relative path per line) OR `git diff --name-only BASE..REF` (--branch REF --base BASE); the
two are mutually exclusive.

Usage:
  check_claims.py [--from-refs|--claims-dir DIR]                       schema + duplicate
  check_claims.py [--from-refs|--claims-dir DIR] --claim ID --files-from FILE [--owned-surfaces FILE]
  check_claims.py [--from-refs|--claims-dir DIR] --claim ID --branch REF --base BASE [--owned-surfaces FILE]

Exit: 0 every claim verifies (or there are none); 1 a claim violation; 2 UNRELIABLE
(no PyYAML / no git when reading refs / unreadable or missing inputs / bad invocation).
"""
import argparse
import glob
import os
import posixpath
import re
import subprocess
import sys
from typing import NoReturn

LIVE_STATES = ("created", "active")
ALL_STATES = ("created", "active", "stale")
VALID_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")


def _fail(msg) -> "NoReturn":
    sys.stderr.write("check-claims: " + msg + "\n")
    sys.exit(2)


def _repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def _strict_loader(yaml):
    """A SafeLoader that REJECTS duplicate mapping keys (so a second `state:` cannot quietly
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


# ---- path canonicalization + matching ----------------------------------------------------

def _canon(p):
    """Canonical repo-relative path, or None if it is not a usable in-repo path: not a
    string, empty, absolute, or escaping the repo root via '..'. normpath collapses '.',
    '//', and interior '..' (so io/../io/x -> io/x), which closes the path-aliasing gap."""
    if not isinstance(p, str):
        return None
    s = p.strip().replace("\\", "/")
    if s == "" or s.startswith("/") or os.path.isabs(s):
        return None
    s = posixpath.normpath(s)
    if s == "." or s == ".." or s.startswith("../"):
        return None
    return s


def _has_glob(s):
    return any(c in s for c in "*?")


def _glob_to_re(pat):
    """Directory-aware glob -> anchored regex: '*' and '?' do NOT cross '/'; '**' does."""
    i, n, out = 0, len(pat), ["^"]
    while i < n:
        c = pat[i]
        if c == "*":
            if i + 1 < n and pat[i + 1] == "*":
                out.append(".*")
                i += 2
                if i < n and pat[i] == "/":
                    i += 1
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        else:
            out.append(re.escape(c))
        i += 1
    out.append("$")
    return re.compile("".join(out))


def _matches(path, entry):
    """True if a canonical path is matched by a surface/owned entry: exact, a containing
    directory/prefix, or a directory-aware glob. `entry` is canonicalized first."""
    e = _canon(entry)
    if e is None:
        return False
    if _has_glob(e):
        return bool(_glob_to_re(e).match(path))
    return path == e or path.startswith(e + "/")


def _overlap(a, b):
    """True if two CONCRETE paths overlap: equal, or one is an ancestor directory of the
    other (so io/ and io/read.f90 conflict). Both are canonicalized."""
    a, b = _canon(a), _canon(b)
    if not a or not b:
        return False
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


def _covered(changed_canon, surface):
    return any(_matches(changed_canon, entry) for entry in surface)


def _is_nonempty_scalar(x):
    return x is not None and not isinstance(x, (dict, list)) and str(x).strip() != ""


# ---- claim loading -----------------------------------------------------------------------

def _claims_from_dir(status_dir, yaml, loader):
    """[(expected_id, claim_or_None, detail)] from <id>.yaml files. A YAML error is a schema
    violation (RED); an OSError reading the file is UNRELIABLE (exit 2)."""
    out = []
    for p in sorted(glob.glob(os.path.join(status_dir, "*.yaml"))):
        expected = os.path.splitext(os.path.basename(p))[0]
        try:
            with open(p) as fh:
                claim = yaml.load(fh, Loader=loader)
        except OSError as exc:
            _fail("cannot read claim file '%s' (%s)" % (p, exc))
        except yaml.YAMLError as exc:
            out.append((expected, None, "%s: not valid YAML (%s)" % (os.path.basename(p), exc)))
            continue
        out.append((expected, claim, p))
    return out


def _claims_from_refs(yaml, loader):
    """[(expected_id, claim_or_None, detail)] from refs/claims/*. A ref that does not point
    to a blob, or whose blob is not valid YAML, is a schema violation (RED)."""
    try:
        raw = subprocess.check_output(
            ["git", "for-each-ref", "--format=%(refname) %(objecttype)", "refs/claims/"],
            stderr=subprocess.DEVNULL).decode()
    except Exception:
        _fail("cannot enumerate refs/claims/* (is this a git repo?)")
    out = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        refname, _, objtype = line.partition(" ")
        expected = refname[len("refs/claims/"):]
        if objtype.strip() != "blob":
            out.append((expected, None, "%s points to a %s, not a blob" % (refname, objtype.strip())))
            continue
        try:
            blob = subprocess.check_output(["git", "cat-file", "blob", refname],
                                           stderr=subprocess.DEVNULL)
            claim = yaml.load(blob, Loader=loader)
        except subprocess.CalledProcessError:
            out.append((expected, None, "%s: cannot read blob" % refname))
            continue
        except yaml.YAMLError as exc:
            out.append((expected, None, "%s: blob is not valid YAML (%s)" % (refname, exc)))
            continue
        out.append((expected, claim, refname))
    return out


# ---- checks ------------------------------------------------------------------------------

def _check_path_list(claim, field, allow_glob, v):
    """Validate a source/target/paths list. All three are OPTIONAL (a local worktree-lock claim
    records its write surface in `paths`; the worktree is the structural lock and `source` enables
    duplicate-source detection when declared). WHEN PRESENT each must be a non-empty block list of
    clean repo-relative paths; globs allowed only when allow_glob (and never character classes)."""
    val = claim.get(field)
    if val is None or val == []:
        return  # optional; absent/empty -> nothing to validate (and, for target, surface derives from paths)
    if not isinstance(val, list) or len(val) == 0:
        v.append("'%s' must be a non-empty block list (or omit it)" % field)
        return
    for idx, item in enumerate(val):
        if not _is_nonempty_scalar(item):
            v.append("%s[%d] must be a non-empty path string" % (field, idx))
            continue
        s = str(item).strip()
        if "[" in s or "]" in s:
            v.append("%s[%d] '%s': character-class globs are not supported" % (field, idx, s))
            continue
        if not allow_glob and _has_glob(s):
            v.append("%s[%d] '%s' must be a concrete path, not a glob" % (field, idx, s))
            continue
        if ".." in s.split("/"):
            v.append("%s[%d] '%s' must not contain a '..' segment" % (field, idx, s))
            continue
        if _canon(s) is None:
            v.append("%s[%d] '%s' must be a clean repo-relative path (not absolute)"
                     % (field, idx, s))


def verify_schema(expected_id, claim):
    """Violations for one claim's well-formedness (empty == ok)."""
    v = []
    if not isinstance(claim, dict):
        return ["claim is not a mapping"]
    for f in ("id", "claimant", "created", "state"):
        if not _is_nonempty_scalar(claim.get(f)):
            v.append("missing or non-scalar required field '%s'" % f)
    if not VALID_ID.match(str(expected_id)):
        v.append("ref/file name '%s' is not a valid trace-id (^[A-Za-z0-9][A-Za-z0-9_.-]*$)"
                 % expected_id)
    cid = claim.get("id")
    if _is_nonempty_scalar(cid):
        if not VALID_ID.match(str(cid)):
            v.append("id '%s' is not a valid trace-id (^[A-Za-z0-9][A-Za-z0-9_.-]*$)" % cid)
        if str(cid) != str(expected_id):
            v.append("id '%s' does not match the ref/file name '%s'" % (cid, expected_id))
    state = claim.get("state")
    if state is not None and str(state) not in ALL_STATES:
        v.append("state '%s' must be one of %s" % (state, "|".join(ALL_STATES)))
    _check_path_list(claim, "source", False, v)
    _check_path_list(claim, "target", False, v)
    _check_path_list(claim, "paths", True, v)
    return v


def find_duplicates(claims):
    """Violations across schema-valid claims: duplicate ids, and overlapping source/target
    among NON-RELEASED claims (created|active|stale). `claims` is [(id, claim_dict)]."""
    v = []
    seen = set()
    for cid, _claim in claims:
        if cid in seen:
            v.append("duplicate work-item id '%s' across claims" % cid)
        seen.add(cid)
    pool = [(cid, claim) for cid, claim in claims if str(claim.get("state")) in ALL_STATES]
    for i in range(len(pool)):
        for j in range(i + 1, len(pool)):
            id_a, ca = pool[i]
            id_b, cb = pool[j]
            sa, sb = str(ca.get("state")), str(cb.get("state"))
            for field in ("source", "target"):
                for pa in (ca.get(field) or []):
                    for pb in (cb.get(field) or []):
                        if not _overlap(pa, pb):
                            continue
                        if sa in LIVE_STATES and sb in LIVE_STATES:
                            v.append("live claims '%s' and '%s' overlap on %s: '%s' vs '%s'"
                                     % (id_a, id_b, field, _canon(pa), _canon(pb)))
                        else:
                            stale_id = id_a if sa == "stale" else id_b
                            v.append("claims '%s' and '%s' overlap on %s ('%s'); '%s' is stale "
                                     "and must be triaged before reclaiming (stale is never "
                                     "auto-freed)" % (id_a, id_b, field, _canon(pa), stale_id))
    return list(dict.fromkeys(v))  # dedupe, preserve order


def _surface(claim, cid):
    """The write surface a claim's branch may touch: its `paths` if given, else the derived
    default (target paths + the item's status fragment). Evidence is NOT in the default - a
    branch that writes evidence must list it in `paths` (so a leaf cannot touch arbitrary
    evidence packs or another item's review via the default)."""
    paths = claim.get("paths") or []
    if paths:
        return [str(p) for p in paths]
    derived = [str(t) for t in (claim.get("target") or [])]
    derived.append("port/status/%s.yaml" % cid)
    return derived


def _granted(owned_surface_canon, claim_paths):
    """True if the claim explicitly takes responsibility for an owned surface: some claim path
    equals it or names something INSIDE it. A merely-broader ancestor path (io/ over
    io/formats/) does NOT grant the owned sub-surface."""
    for p in claim_paths:
        pc = _canon(p)
        if pc is None:
            continue
        if pc == owned_surface_canon or pc.startswith(owned_surface_canon + "/"):
            return True
    return False


def verify_branch_diff(cid, claim, changed, owned_surfaces):
    """Violations for a branch's changed files against its claim (empty == ok)."""
    v = []
    surface = _surface(claim, cid)
    claim_paths = claim.get("paths") or []
    for f in changed:
        cf = _canon(f)
        if cf is None:
            v.append("branch changed path '%s' is not a clean in-repo path (escapes root?)" % f)
            continue
        if not _covered(cf, surface):
            v.append("branch touched '%s' outside claim '%s' write surface" % (cf, cid))
            continue
        for s in owned_surfaces:
            sc = _canon(s)
            if sc is None:
                continue
            if _matches(cf, s) and not _granted(sc, claim_paths):
                v.append("branch '%s' reaches owned surface '%s' via '%s' (not granted in "
                         "claim paths)" % (cid, sc, cf))
    return v


# ---- main --------------------------------------------------------------------------------

def _read_lines(path):
    try:
        with open(path) as fh:
            return [ln.strip() for ln in fh if ln.strip() and not ln.lstrip().startswith("#")]
    except OSError as exc:
        _fail("cannot read '%s' (%s)" % (path, exc))


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--claims-dir", default=None, help="read <id>.yaml from this dir (fixtures/tests)")
    ap.add_argument("--from-refs", action="store_true",
                    help="read the pushed refs/claims/* (advanced multi-operator path)")
    ap.add_argument("--claim", default=None, help="work-item id for branch-diff mode")
    ap.add_argument("--files-from", default=None, help="file of changed paths (branch-diff)")
    ap.add_argument("--branch", default=None, help="branch ref (branch-diff via git diff)")
    ap.add_argument("--base", default=None, help="base ref for the diff (required with --branch)")
    ap.add_argument("--owned-surfaces", default=None, help="file of owned-surface globs")
    args = ap.parse_args()

    if args.files_from and args.branch:
        _fail("--files-from and --branch are mutually exclusive (one source of changed files)")
    if args.branch and not args.base:
        _fail("--branch requires an explicit --base (the integration base to diff against)")
    if args.from_refs and args.claims_dir is not None:
        _fail("--from-refs and --claims-dir are mutually exclusive (one claim source)")

    orig = os.getcwd()
    root = _repo_root()
    try:
        os.chdir(root)
    except OSError:
        _fail("cannot enter repo root '%s'" % root)

    def resolve(p):
        return None if p is None else (p if os.path.isabs(p) else os.path.join(orig, p))

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse claims (install pyyaml)")
    loader = _strict_loader(yaml)

    # Enumerate claims: --from-refs reads the pushed refs; --claims-dir reads an arbitrary dir
    # (fixtures/tests); the DEFAULT is the local lock store port/claims/ (cwd is the repo root).
    if args.from_refs:
        loaded = _claims_from_refs(yaml, loader)
    elif args.claims_dir is not None:
        cdir = args.claims_dir if os.path.isabs(args.claims_dir) else os.path.join(orig, args.claims_dir)
        if not os.path.isdir(cdir):
            _fail("--claims-dir '%s' is not a directory" % args.claims_dir)
        loaded = _claims_from_dir(cdir, yaml, loader)
    elif os.path.isdir("port/claims"):
        loaded = _claims_from_dir("port/claims", yaml, loader)
    else:
        print("check-claims: no claims (port/claims/ absent; --from-refs for pushed refs) - nothing to check (skipping).")
        sys.exit(0)

    if not loaded:
        print("check-claims: no claims (the store is empty) - nothing to check (skipping).")
        sys.exit(0)

    fails = 0
    valid = []  # (id, claim) for schema-valid claims, fed to duplicate + branch-diff
    for expected_id, claim, detail in loaded:
        if claim is None:
            print("  [FAIL] %s: %s" % (expected_id, detail))
            fails += 1
            continue
        viol = verify_schema(expected_id, claim)
        if viol:
            for msg in viol:
                print("  [FAIL] %s: %s" % (expected_id, msg))
            fails += len(viol)
            continue
        valid.append((str(claim.get("id")), claim))

    for msg in find_duplicates(valid):
        print("  [FAIL] %s" % msg)
        fails += 1

    # Branch-diff: only when a branch/file-list is supplied.
    if args.files_from or args.branch:
        if not args.claim:
            _fail("branch-diff needs --claim ID (which claim the branch is for)")
        match = [c for cid, c in valid if cid == str(args.claim)]
        if match:
            owned = _read_lines(resolve(args.owned_surfaces)) if args.owned_surfaces else []
            if args.files_from:
                changed = _read_lines(resolve(args.files_from))
            else:
                try:
                    out = subprocess.check_output(
                        ["git", "diff", "--name-only", "%s..%s" % (args.base, args.branch)],
                        stderr=subprocess.DEVNULL).decode()
                except Exception:
                    _fail("cannot diff '%s..%s'" % (args.base, args.branch))
                changed = [ln.strip() for ln in out.splitlines() if ln.strip()]
            for msg in verify_branch_diff(str(args.claim), match[0], changed, owned):
                print("  [FAIL] %s" % msg)
                fails += 1
        elif any(str(args.claim) == eid for eid, _c, _d in loaded) or \
                any(isinstance(c, dict) and str(c.get("id")) == str(args.claim) for _e, c, _d in loaded):
            # The selected claim is present but schema-invalid: that is already a RED [FAIL]
            # above (do not downgrade to UNRELIABLE); note it and keep the verdict RED.
            print("  [FAIL] claim '%s' is malformed; branch-diff skipped until it is fixed" % args.claim)
            fails += 1
        else:
            _fail("no claim '%s' to diff the branch against" % args.claim)

    print("check-claims: checked %d claim(s); %d violation(s)." % (len(loaded), fails))
    if fails:
        print("RESULT: RED (exit 1) - a claim does not verify.")
        sys.exit(1)
    print("RESULT: GREEN (exit 0) - every claim is well-formed, unique, and within its surface.")
    sys.exit(0)


if __name__ == "__main__":
    main()
