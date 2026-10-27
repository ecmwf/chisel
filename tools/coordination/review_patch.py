#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""review_patch.py - check that a reviewer's patch is small and was applied exactly.

A reviewer who finds something small writes the fix as a patch beside its report, instead of only
describing it; the unit's Kha-Worker applies it verbatim and re-runs its proof. No second full review
is needed, because every changed line is still seen twice: the reviewer wrote it, and the worker and
the proof checked it. That holds only if the patch is small and nothing else changed, which this
checks with git itself:

  - small: at most --max-lines changed lines (added plus removed, default 10) in at most --max-hunks
    places (default 3), only in the --allow files (the unit's own TARGET files - never its tests,
    proof, build or conventions), and no file added, deleted, renamed or given another mode;
  - exact: the patch applied to the reviewed commit gives exactly the tree of the applied commit.

Usage: review_patch.py --repo DIR --reviewed REV --applied REV --patch FILE --allow PATH [PATH ...]
                       [--max-lines N] [--max-hunks N]
Exit:  0 the applied commit is the reviewed commit plus exactly this small patch; 1 it is not (the
       reason is printed); 2 UNRELIABLE (a missing file, a revision that does not resolve, git failing).
"""
import argparse
import os
import subprocess
import sys
import tempfile


def git(repo, *args, env=None):
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, env=env)


def main():
    ap = argparse.ArgumentParser(description="Check that a review patch is small and was applied exactly.")
    ap.add_argument("--repo", required=True, help="the git repository the unit's code is in")
    ap.add_argument("--reviewed", required=True, help="the commit the reviewer reviewed")
    ap.add_argument("--applied", required=True, help="the commit with the patch applied")
    ap.add_argument("--patch", required=True)
    ap.add_argument("--allow", nargs="+", required=True, help="the files the patch may change")
    ap.add_argument("--max-lines", type=int, default=10)
    ap.add_argument("--max-hunks", type=int, default=3)
    a = ap.parse_args()

    def unreliable(msg):
        print("review-patch: %s (UNRELIABLE)" % msg, file=sys.stderr)
        sys.exit(2)

    def refuse(msg):
        print("review-patch: %s - not a small review patch applied exactly; send the unit back for an "
              "ordinary rework and review" % msg)
        sys.exit(1)

    patch = os.path.abspath(a.patch)
    if not os.path.isfile(patch):
        unreliable("no patch at %s" % a.patch)
    revs = {}
    for name in ("reviewed", "applied"):
        p = git(a.repo, "rev-parse", "--verify", "%s^{commit}" % getattr(a, name))
        if p.returncode != 0:
            unreliable("%s commit '%s' does not resolve in %s" % (name, getattr(a, name), a.repo))
        revs[name] = p.stdout.strip()

    numstat = git(a.repo, "apply", "--numstat", patch)
    summary = git(a.repo, "apply", "--summary", patch)
    if numstat.returncode != 0 or summary.returncode != 0:
        refuse("the patch cannot be read: %s" % (numstat.stderr or summary.stderr).strip())
    if summary.stdout.strip():
        refuse("the patch adds, deletes, renames or changes the mode of a file (%s)" % summary.stdout.strip())
    allowed = {os.path.normpath(p) for p in a.allow}
    lines = 0
    for row in numstat.stdout.splitlines():
        added, removed, path = row.split("\t", 2)
        if added == "-":
            refuse("the patch changes a binary file, %s" % path)
        if os.path.normpath(path) not in allowed:
            refuse("the patch changes %s, which is not one of the unit's files" % path)
        lines += int(added) + int(removed)
    hunks = sum(1 for ln in open(patch, encoding="utf-8", errors="replace") if ln.startswith("@@"))
    if lines == 0:
        refuse("the patch changes nothing")
    if lines > a.max_lines or hunks > a.max_hunks:
        refuse("the patch changes %d line(s) in %d place(s), more than %d line(s) in %d place(s)"
               % (lines, hunks, a.max_lines, a.max_hunks))

    with tempfile.TemporaryDirectory() as tmp:
        env = dict(os.environ, GIT_INDEX_FILE=os.path.join(tmp, "index"))
        steps = (("read-tree", revs["reviewed"]), ("apply", "--cached", patch), ("write-tree",))
        for step in steps:
            p = git(a.repo, *step, env=env)
            if p.returncode != 0:
                refuse("the patch does not apply to the reviewed commit: %s" % p.stderr.strip())
        expected = p.stdout.strip()
    actual = git(a.repo, "rev-parse", "%s^{tree}" % revs["applied"]).stdout.strip()
    if expected != actual:
        changed = git(a.repo, "diff", "--stat", expected, actual).stdout.strip()
        refuse("the applied commit differs from the reviewed commit plus the patch:\n%s" % changed)
    print("review-patch: %s is %s plus exactly the patch (%d line(s) in %d place(s)). RESULT: GREEN"
          % (revs["applied"][:12], revs["reviewed"][:12], lines, hunks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
