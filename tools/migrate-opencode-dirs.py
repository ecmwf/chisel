#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""migrate-opencode-dirs.py - point paths at opencode 2's folder names.

Chisel's commands and skills moved from `.opencode/command/` and `.opencode/skill/` to opencode 2's
`.opencode/commands/` and `.opencode/skills/`. A sync brings the moved files, but a port's own
documents keep citing the old paths. This rewrites those citations:

    .opencode/command/...  ->  .opencode/commands/...
    .opencode/skill/...    ->  .opencode/skills/...

  migrate-opencode-dirs.py [--apply] [PATH...]

With no PATH it rewrites the port's living documents: port/ (but never LESSONS.md, lessons-archive/
or retrospectives/, which stay as written), reference/ and the port's own tool directories. source/
and docs/evidence/ are never touched. Only tracked text files change. Without --apply it lists what
it would change. Running it again changes nothing.

Exit: 0 done (or nothing to do); 2 usage or environment error.
"""

import os
import re
import subprocess
import sys

DEFAULT = ["port", "reference", "tools/scoping", "tools/proofs", "tools/diff", "tools/conformance/project"]
KEEP = ("port/LESSONS.md", "port/lessons-archive/", "port/retrospectives/", "source/", "docs/evidence/")
OLD = re.compile(r"\.opencode/(command|skill)\b")


def main(argv):
    apply = "--apply" in argv
    paths = [a for a in argv if a != "--apply"]
    bad = [a for a in paths if a.startswith("-")]
    if bad:
        sys.stderr.write("migrate-opencode-dirs: unknown option %s\n" % bad[0])
        return 2
    try:
        files = subprocess.run(["git", "ls-files", "-z", "--", *(paths or DEFAULT)], check=True,
                               capture_output=True).stdout.decode().split("\0")
    except (OSError, subprocess.CalledProcessError) as exc:
        sys.stderr.write("migrate-opencode-dirs: cannot list the tracked files (%s)\n" % exc)
        return 2
    changed = 0
    for path in files:
        if not path or path.startswith(KEEP) or os.path.islink(path):
            continue
        try:
            text = open(path, encoding="utf-8").read()
        except (OSError, UnicodeDecodeError):
            continue  # a binary file, a symlink to a directory, or gone from the work tree
        new, n = OLD.subn(lambda m: ".opencode/%ss" % m.group(1), text)
        if n:
            changed += 1
            print("%s: %d path(s)" % (path, n))
            if apply:
                with open(path, "w", encoding="utf-8") as fh:
                    fh.write(new)
    if not changed:
        print("migrate-opencode-dirs: nothing to change")
    elif not apply:
        print("migrate-opencode-dirs: %d file(s) would change; re-run with --apply" % changed)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
