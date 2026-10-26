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
(piece, role) per id). It changes at most the `author_id` value and adds at most one `author_sessions`
item (and the key, when absent): every other line - comments, existing list items and their comments -
is kept byte-for-byte, except that a one-line inline list (which cannot carry comments) is rewritten as
a block; a list in any other multi-line form is refused. The result always names the claim's recorded
worker for THIS piece as `author_id`, with that session in `author_sessions`. It:
  - sets `author_id` when it is unset (null, empty, or a `<...>` placeholder) or already this session;
  - accepts a DIFFERENT existing `author_id` only as a prior author of this piece - a `ses_` id already
    listed in `author_sessions` (so recorded as an author before, e.g. the worker a fresh rework
    replaced); `author_id` then moves to the recorded worker and the prior author stays in
    `author_sessions`. Any other existing `author_id` is refused, never overwritten: a value that is not
    a session id, one absent from `author_sessions` (a prior author cannot be told from a misrecorded
    one), or one the claims ledger records for another piece or role;
  - appends the session to `author_sessions` if absent, in BLOCK form (the fragment check reads only
    block items, so an inline list is rewritten as a block); every existing item must be a `ses_` id
    that the ledger does not record for another piece or role, else it refuses;
  - refuses when any author identity (the session, the existing `author_id`, any `author_sessions` item)
    is this piece's reviewer - its `reviewer_id`, `reviewer_session`, or recorded reviewer thread - or
    when the fragment's `id` is not <id>;
  - re-reads the result with the strict loader and writes it only if `author_id` and `author_sessions`
    hold what was intended and every other field is unchanged - it verifies, never counts edits.
A session whose claim was already released is no longer in the ledger, so a value borrowed from such a
piece cannot be detected here; only what the ledger records is cross-checked.

It stamps unit status fragments only (they carry `status` and `claim`); a Phase-1 plan unit has no
`author_sessions` and is refused.

Usage:  stamp_author_id.py <id> [--status-file FILE] [--claims-dir DIR]
        (defaults: port/status/<id>.yaml and port/claims/, both from the repo root - run it from the
        main workbench checkout, where the claims are, not from a worker's worktree)
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
SESSIONS_HDR_RE = re.compile(r"^author_sessions:([^\n]*)$", re.M)
ITEM_RE = re.compile(r"^([ \t]*-[ \t]+)")


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


def _add_session(text, ses, sessions, after):
    """Return `text` with `ses` in the top-level author_sessions list, changing as little as possible:
    an existing block keeps every line byte-for-byte (item comments included) and gains one item line
    after its last item; an absent key is added after offset `after` (the author_id line); a one-line
    inline list - which cannot carry item comments - is rewritten as a block; a header without a list
    value (empty, null, ~) gains the item. None when the list is spread over lines in another form."""
    m = SESSIONS_HDR_RE.search(text)
    if m is None:
        return text[:after] + "\nauthor_sessions:\n  - " + ses + text[after:]
    cmt = _comment(m.group(0))
    value = m.group(1)[:len(m.group(1)) - len(cmt)].strip()
    if value.startswith("["):
        if not value.endswith("]"):
            return None
        items = "".join("\n  - " + s for s in list(sessions) + ([ses] if ses not in sessions else []))
        return text[:m.start()] + "author_sessions:" + cmt + items + text[m.end():]
    if value not in ("", "null", "~"):
        return None
    if ses in sessions:
        return text
    header = text[:m.start()] + ("author_sessions:" + cmt if value else m.group(0))
    # The block runs until the next line that starts at column 0 and is neither a comment nor an item.
    lines = text[m.end():].split("\n")
    last_item, prefix = 0, "  - "
    for i, line in enumerate(lines[1:], start=1):
        if line and not line[0].isspace() and not line.startswith(("#", "-")):
            break
        im = ITEM_RE.match(line)
        if im:
            last_item, prefix = i, im.group(1)
    lines.insert(last_item + 1, prefix + ses)
    return header + "\n".join(lines)


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
        _refuse("no claim %s - nothing records this piece's worker thread (run from the main workbench "
                "checkout, where port/claims/ is)" % os.path.join(cdir, uid + ".yaml"))
    fwd, rev = TL._scan(cdir, yaml)
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
    if "status" not in d or "claim" not in d:
        _refuse("%s is not a unit status fragment (no 'status' or 'claim' key) - only those record "
                "author_sessions" % frag)

    # This piece's reviewer identities: none of them may ever be recorded as an author.
    reviewers = {str(d.get(k)).strip(): k for k in ("reviewer_id", "reviewer_session") if not _unset(d.get(k))}
    if fwd.get((uid, "reviewer")):
        reviewers.setdefault(fwd[(uid, "reviewer")], "recorded reviewer thread")

    def vet(s, what):
        """Refuse an author identity that is not a session id, belongs to another (piece, role) in the
        claims ledger, or is this piece's reviewer."""
        if not TL.SES_RE.match(s):
            _refuse("fragment %s: %s '%s' is not a session id - fix it by hand, it is never overwritten"
                    % (frag, what, s))
        owner = rev.get(s)
        if owner is not None and owner != (uid, "worker"):
            _refuse("fragment %s: %s %s is the recorded %s thread of '%s' - not an author of '%s'"
                    % (frag, what, s, owner[1], owner[0], uid))
        if s in reviewers:
            _refuse("fragment %s: %s %s is this piece's %s - an author can never be its reviewer"
                    % (frag, what, s, reviewers[s]))

    vet(ses, "the recorded worker thread")

    sessions = d.get("author_sessions")
    if sessions is None:
        sessions = []
    if not isinstance(sessions, list) or not all(isinstance(s, str) for s in sessions):
        _refuse("fragment %s: author_sessions must be a list of session ids" % frag)
    for s in sessions:
        if s != s.strip():
            _refuse("fragment %s: author_sessions item %r has surrounding whitespace - fix it by hand"
                    % (frag, s))
        vet(s, "author_sessions item")

    cur = d.get("author_id")
    prior = None
    if not _unset(cur) and str(cur).strip() != ses:
        prior = str(cur).strip()
        vet(prior, "author_id")
        if prior not in sessions:
            _refuse("fragment %s: author_id %s is not the recorded worker %s and is not in author_sessions - "
                    "a prior author cannot be told from a misrecorded one; fix it by hand" % (frag, prior, ses))
    new_author = ses
    new_sessions = list(sessions) + ([ses] if ses not in sessions else [])

    # Targeted text edit: the author_id value, and one added author_sessions item; nothing else moves.
    out = text
    m = AUTHOR_ID_RE.search(out)
    if m is None:
        _refuse("fragment %s has no top-level 'author_id:' line" % frag)
    if str(d.get("author_id")).strip() != new_author:
        out = out[:m.start()] + "author_id: " + new_author + _comment(m.group(0)) + out[m.end():]
    out = _add_session(out, ses, sessions, AUTHOR_ID_RE.search(out).end())
    if out is None:
        _refuse("fragment %s: author_sessions is neither a block list nor a one-line inline list - "
                "rewrite it as a block list by hand" % frag)

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
    print("stamp-author-id: '%s' author_id %s%s, author_sessions %s (%s)"
          % (uid, new_author, " (was prior author %s, kept in author_sessions)" % prior if prior else "",
             ", ".join(new_sessions), frag))
    sys.exit(0)


if __name__ == "__main__":
    main()
