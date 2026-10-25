#!/usr/bin/env python3
"""stamp_author_id - write a piece's author identity into its status fragment FROM the worker thread
already recorded in its claim, so the fidelity record and the resume handle cannot disagree.

A dispatched worker cannot see its own `ses_` id; the orchestrator captures it from the Task result and
must record it twice - the resume thread in the claim (thread_ledger.py record ... --role worker) and
the committed identity in the fragment (`author_id`, `author_sessions`). Doing the second write by hand
across a wave is how a field is silently left null (failure mode B16), and a null `author_id` makes the
`reviewer_id != author_id` independence check pass vacuously. This tool derives the second write from
the first: record the thread, then stamp.

It reads the worker thread through thread_ledger's own validation (the whole claims dir: ses_ form, one
(piece, role) per id), and edits only the `author_id:` and `author_sessions:` lines of the fragment
(comments and the rest of the file are kept). It:
  - sets `author_id` when it is unset (null, empty, or a `<...>` placeholder); an `author_id` that is
    already this session is left alone; one that is already ANOTHER `ses_` id is kept (it names the first
    worker - a later fresh rework session is appended to `author_sessions` only); one that is not a
    `ses_` id is refused (a fabricated identity is fixed by a human, never overwritten);
  - appends the session to `author_sessions` if absent, in BLOCK form (the fragment check reads only
    block items, so an inline list is rewritten as a block);
  - refuses when the session is the fragment's `reviewer_id` or `reviewer_session` (an author can never
    be the reviewer), or when the fragment's `id` is not <id>;
  - re-reads the result with the strict loader and writes it only if `author_id` and `author_sessions`
    hold what was intended and every other field is unchanged - it verifies, never counts edits.

Usage:  stamp_author_id.py <id> [--status-file FILE] [--claims-dir DIR]
        (defaults: port/status/<id>.yaml and port/claims/, both from the repo root)
Exit:   0 stamped, or already current; 1 refused (no worker thread recorded, a conflicting identity, a
        ledger or fragment invariant breach); 2 UNRELIABLE (PyYAML missing, fragment unreadable or
        malformed).
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import thread_ledger as TL  # noqa: E402  (the one validated reader of claim threads)
from _chisel_lib import strict_loader as _strict_loader, repo_root as _repo_root  # noqa: E402

AUTHOR_ID_RE = re.compile(r"^author_id:[^\n]*$", re.M)
SESSIONS_RE = re.compile(r"^author_sessions:[^\n]*(?:\n[ \t]+-[^\n]*)*", re.M)


def _refuse(msg):
    sys.stderr.write("stamp-author-id: " + msg + "\n")
    sys.exit(1)


def _unreliable(msg):
    sys.stderr.write("stamp-author-id: " + msg + "\n")
    sys.exit(2)


def _unset(v):
    s = "" if v is None else str(v).strip()
    return not s or s.lower() in ("null", "none", "~") or s.startswith("<")


def _comment(line):
    m = re.search(r"[ \t]+#.*$", line)
    return m.group(0) if m else ""


def _load(text, yaml):
    try:
        d = yaml.load(text, Loader=_strict_loader(yaml))
    except yaml.YAMLError as exc:
        return None, str(exc).replace("\n", " ")
    if not isinstance(d, dict):
        return None, "not a mapping"
    return d, None


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("id")
    ap.add_argument("--status-file", default=None)
    ap.add_argument("--claims-dir", default=None)
    args = ap.parse_args()
    uid = args.id
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", uid):
        _refuse("id '%s' is not a valid trace-id" % uid)

    orig = os.getcwd()
    root = _repo_root()

    def resolve(p, default_rel):
        if p is None:
            return os.path.join(root, default_rel)
        return p if os.path.isabs(p) else os.path.join(orig, p)

    try:
        import yaml
    except Exception:
        _unreliable("PyYAML not available - cannot read the claim or the fragment (install pyyaml)")

    cdir = resolve(args.claims_dir, os.path.join("port", "claims"))
    frag = resolve(args.status_file, os.path.join("port", "status", uid + ".yaml"))

    # The worker thread, validated across the whole claims dir (thread_ledger exits 1 on a breach).
    if not os.path.isfile(os.path.join(cdir, uid + ".yaml")):
        _refuse("no claim %s - nothing records this piece's worker thread" % os.path.join(cdir, uid + ".yaml"))
    fwd, _rev = TL._scan(cdir, yaml)
    ses = fwd.get((uid, "worker"))
    if not ses:
        _refuse("claim of '%s' records no worker thread - record it first: thread_ledger.py record %s "
                "--role worker --task-id <ses_...>" % (uid, uid))

    try:
        with open(frag, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as exc:
        _unreliable("cannot read fragment %s (%s)" % (frag, exc))
    d, err = _load(text, yaml)
    if d is None:
        _unreliable("fragment %s is malformed (%s)" % (frag, err))

    if str(d.get("id", "")).strip() != uid:
        _refuse("fragment %s has id '%s', not '%s'" % (frag, d.get("id"), uid))
    for k in ("reviewer_id", "reviewer_session"):
        if not _unset(d.get(k)) and str(d.get(k)).strip() == ses:
            _refuse("the recorded worker thread %s is this piece's %s - an author can never be its reviewer"
                    % (ses, k))

    cur = d.get("author_id")
    if _unset(cur):
        new_author = ses
    elif TL.SES_RE.match(str(cur).strip()):
        new_author = str(cur).strip()
    else:
        _refuse("fragment %s has author_id '%s', which is not a session id - fix it by hand, it is never "
                "overwritten" % (frag, cur))

    sessions = d.get("author_sessions")
    if sessions is None:
        sessions = []
    if not isinstance(sessions, list) or not all(isinstance(s, str) for s in sessions):
        _refuse("fragment %s: author_sessions must be a list of session ids" % frag)
    new_sessions = list(sessions) + ([ses] if ses not in sessions else [])

    # Targeted text edit: only the two top-level lines (and the sessions block items) change.
    out = text
    m = AUTHOR_ID_RE.search(out)
    if m is None:
        _refuse("fragment %s has no top-level 'author_id:' line" % frag)
    out = out[:m.start()] + "author_id: " + new_author + _comment(m.group(0)) + out[m.end():]
    block_items = "".join("\n  - " + s for s in new_sessions)
    m = SESSIONS_RE.search(out)
    if m is None:
        a = AUTHOR_ID_RE.search(out)
        out = out[:a.end()] + "\nauthor_sessions:" + block_items + out[a.end():]
    else:
        header = m.group(0).split("\n", 1)[0]
        out = out[:m.start()] + "author_sessions:" + _comment(header) + block_items + out[m.end():]

    # Postcondition: the intended values, and nothing else moved.
    nd, err = _load(out, yaml)
    if nd is None:
        _refuse("the stamped fragment would not parse (%s) - %s left unchanged" % (err, frag))
    rest = lambda x: {k: v for k, v in x.items() if k not in ("author_id", "author_sessions")}  # noqa: E731
    if (str(nd.get("author_id")) != new_author or nd.get("author_sessions") != new_sessions
            or rest(nd) != rest(d)):
        _refuse("the stamped fragment does not hold exactly the intended identity - %s left unchanged" % frag)

    if out == text:
        print("stamp-author-id: '%s' already current (author_id %s, %d author session(s))"
              % (uid, new_author, len(new_sessions)))
        sys.exit(0)
    tmp = frag + ".stamp-tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(out)
    os.replace(tmp, frag)
    print("stamp-author-id: '%s' author_id %s, author_sessions %s (%s)"
          % (uid, new_author, ", ".join(new_sessions), frag))
    sys.exit(0)


if __name__ == "__main__":
    main()
