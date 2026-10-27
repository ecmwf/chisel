#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""thread_ledger - record / resume the per-piece subagent THREAD ids, so a rework resumes the
WORKER's thread and a re-review resumes the REVIEWER's thread (context preserved across
work->review->rework->re-review) WITHOUT crossing the author<->reviewer independence boundary.

THE HANDLE IS THE OPENCODE SESSION ID, NEVER A COMPOSED NAME. The resume handle is the `ses_...`
session id captured from the subagent result - UNIQUE per dispatch (two identically-NAMED workers
still get distinct ids). A composed display name like `kha-worker-<model>-<unit>-<date>` COLLIDES for
split work and would cross threads, so this tool REFUSES to store any handle that is not a `ses_` id,
and REFUSES to record one id under two (piece, role) keys (the cross-contamination guard - a worker's
thread can never be resumed as the reviewer's).

The ids live in the per-piece LOCAL claim port/claims/<id>.yaml (operational, gitignored, retired with
the claim when the piece integrates), under `threads: {worker: <ses_id>, reviewer: <ses_id>}`. The
committed fragment keeps `reviewer_id != author_id` for the fidelity AUDIT; these resume handles are
operational, not fidelity evidence. See docs/dev/0.5.0-thread-continuity.md.

Usage:
  thread_ledger.py record <id> --role worker|reviewer --session-id <ses_...> [--claims-dir DIR]
  thread_ledger.py resume <id> --role worker|reviewer [--claims-dir DIR]
  thread_ledger.py --check [--claims-dir DIR]
Exit: 0 ok (record/check) ; for `resume` 0 = printed the ses id (pass it as the subagent tool's sessionID) and ANY
      non-zero = DISPATCH FRESH: 3 = none recorded, or 1 = REFUSED (resume validates the whole claims dir
      at the point of use, so it can never hand back a cross-(piece,role)-reused or non-ses handle that
      would land in the wrong thread); 1 also = a record/check invariant violation; 2 = UNRELIABLE (no PyYAML).
"""
import argparse
import glob
import os
import re
import sys
from typing import NoReturn
from _chisel_lib import strict_loader as _strict_loader, repo_root as _repo_root

ROLES = ("worker", "reviewer")
# A real opencode session/task id: `ses_` + alphanumerics. NOT a composed name (which has '-'/'.').
SES_RE = re.compile(r"^ses_[A-Za-z0-9]+$")


def _fail(msg) -> "NoReturn":
    sys.stderr.write("thread-ledger: " + msg + "\n")
    sys.exit(1)


def _unreliable(msg) -> "NoReturn":
    sys.stderr.write("thread-ledger: " + msg + "\n")
    sys.exit(2)


def _claims_dir(arg):
    return arg if arg is not None else os.path.join("port", "claims")


def _load(path, yaml):
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.load(fh, Loader=_strict_loader(yaml))
    except (OSError, yaml.YAMLError) as exc:
        _fail("cannot read claim '%s' (%s)" % (path, exc))
    if not isinstance(data, dict):
        _fail("claim '%s' is not a mapping" % path)
    return data


def _threads_of(claim, path):
    """Return the claim's `threads` mapping (validated), or {} if absent. RED on a malformed shape
    or a value that is not a `ses_` id (a composed name must never have been stored as a key)."""
    t = claim.get("threads")
    if t is None:
        return {}
    if not isinstance(t, dict):
        _fail("claim '%s': 'threads' must be a mapping {worker/reviewer: <ses_id>}" % path)
    out = {}
    for role, tid in t.items():
        rk = str(role).strip()
        if rk not in ROLES:
            _fail("claim '%s': 'threads' has an unknown role '%s' (expected worker/reviewer)" % (path, rk))
        sid = str(tid).strip()
        if not SES_RE.match(sid):
            _fail("claim '%s': threads.%s = '%s' is not a session id (must match ses_<alnum>); a composed "
                  "name like kha-worker-<unit>-<date> COLLIDES across split work and must never be a resume key"
                  % (path, rk, sid))
        out[rk] = sid
    return out


def _scan(cdir, yaml):
    """{ (piece_id, role): ses_id } over every claim, with the no-cross-(piece,role)-reuse invariant
    enforced: a single ses_id may map to at most ONE (piece, role). Returns the map and the reverse."""
    fwd, rev = {}, {}
    for p in sorted(glob.glob(os.path.join(cdir, "*.yaml"))):
        pid = os.path.splitext(os.path.basename(p))[0]
        claim = _load(p, yaml)
        for role, sid in _threads_of(claim, p).items():
            fwd[(pid, role)] = sid
            owner = rev.get(sid)
            if owner is not None and owner != (pid, role):
                _fail("session id '%s' is recorded under BOTH %s and %s - one thread cannot be two "
                      "(piece, role)s; resuming it for the wrong role/piece would cross threads "
                      "(a worker's thread reviewed as the reviewer = independence breach)"
                      % (sid, owner, (pid, role)))
            rev[sid] = (pid, role)
    return fwd, rev


def _cmd_record(args, yaml, cdir):
    role = args.role
    sid = (args.session_id or "").strip()
    if not SES_RE.match(sid):
        _fail("--session-id '%s' is not a session id (must match ses_<alnum>). Pass the opencode SESSION id "
              "from the subagent result, NEVER a composed display name (it collides for split work)." % sid)
    path = os.path.join(cdir, args.id + ".yaml")
    if not os.path.isfile(path):
        _fail("no claim at '%s' - provision the worktree first (provision_worker.sh add %s)" % (path, args.id))
    # Refuse to bind a ses id already owned by a different (piece, role).
    _, rev = _scan(cdir, yaml)
    owner = rev.get(sid)
    if owner is not None and owner != (args.id, role):
        _fail("session id '%s' is already the %s thread of '%s' - refusing to also bind it as the %s "
              "thread of '%s' (that would cross threads)" % (sid, owner[1], owner[0], role, args.id))
    claim = _load(path, yaml)
    threads = claim.get("threads")
    if not isinstance(threads, dict):
        threads = {}
    threads[role] = sid
    claim["threads"] = threads

    class _ID(yaml.Dumper):
        def increase_indent(self, flow=False, indentless=False):
            return super(_ID, self).increase_indent(flow, False)
    text = yaml.dump(claim, Dumper=_ID, sort_keys=False, default_flow_style=False, allow_unicode=True, width=10 ** 9)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("thread-ledger: recorded %s thread of '%s' = %s" % (role, args.id, sid))
    sys.exit(0)


def _cmd_resume(args, yaml, cdir):
    path = os.path.join(cdir, args.id + ".yaml")
    if not os.path.isfile(path):
        sys.exit(3)  # no claim -> nothing to resume -> dispatch fresh
    # Defense AT THE POINT OF USE: validate the whole claims dir is consistent before handing back a
    # resume handle - _scan fails closed (exit 1) on any cross-(piece, role) reuse or non-ses handle, so
    # `resume` can NEVER return an id that is also recorded under a different (piece, role) (which, resumed
    # for the wrong role, would breach independence). Do not trust that --check ran separately.
    _scan(cdir, yaml)
    sid = _threads_of(_load(path, yaml), path).get(args.role)
    if not sid:
        sys.exit(3)  # no recorded thread -> dispatch fresh
    print(sid)
    sys.exit(0)


def _cmd_check(yaml, cdir):
    if not os.path.isdir(cdir):
        print("thread-ledger: no claims dir '%s' - nothing to check (skipping)." % cdir)
        sys.exit(0)
    fwd, _ = _scan(cdir, yaml)  # _scan fails closed on any invariant breach
    print("thread-ledger: %d recorded thread id(s) across %d (piece, role) key(s); all ses-form, "
          "distinct per (piece, role), no cross-reuse. RESULT: GREEN" % (len(set(fwd.values())), len(fwd)))
    sys.exit(0)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--claims-dir", default=None)
    sub = ap.add_subparsers(dest="cmd")
    for name in ("record", "resume"):
        sp = sub.add_parser(name)
        sp.add_argument("id")
        sp.add_argument("--role", required=True, choices=ROLES)
        # SUPPRESS (not None): so a top-level `--claims-dir X` placed BEFORE the subcommand is NOT
        # clobbered back to None by the subparser default. The flag now works in either position.
        sp.add_argument("--claims-dir", default=argparse.SUPPRESS)
        if name == "record":
            sp.add_argument("--session-id", "--task-id", dest="session_id", required=True)  # --task-id: the old name
    args = ap.parse_args()

    orig = os.getcwd()
    root = _repo_root()
    try:
        os.chdir(root)
    except OSError:
        _fail("cannot enter repo root '%s'" % root)

    def resolve(p):
        if p is None:
            return None
        return p if os.path.isabs(p) else os.path.join(orig, p)

    try:
        import yaml
    except Exception:
        _unreliable("PyYAML not available - cannot read claims (install pyyaml)")

    cdir_arg = resolve(getattr(args, "claims_dir", None))
    cdir = _claims_dir(cdir_arg)

    if args.check:
        _cmd_check(yaml, cdir)
    if args.cmd == "record":
        _cmd_record(args, yaml, cdir)
    if args.cmd == "resume":
        _cmd_resume(args, yaml, cdir)
    ap.print_help()
    sys.exit(1)


if __name__ == "__main__":
    main()
