#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""index_helper_defs.py - which listed index helpers the central helper files really define.

Used by check-index-helpers.sh when a port lists its own helper names. A listed name is
trusted only if the central helper header/source DEFINES it, and that is a question about the
program, not about its text: a call, a comment, or a declaration in an inactive preprocessor
branch must never count. So each central file is parsed with libclang, in the configuration
it has when compiled with no command-line macros, and a name counts only if that file itself
holds, at file scope:

  - a FUNCTION_DECL of exactly that name (a definition with a body, or a prototype), or
  - a MACRO_DEFINITION of exactly that name.

Comments and inactive regions never produce such cursors, and a declaration that lives in some
other (included) file does not count for this one.

Usage:
  index_helper_defs.py [-I DIR]... NAME... -- FILE...

Exit codes:
  0  every NAME is defined in at least one FILE
  1  at least one NAME is not; the undefined names are printed, one per line, on stdout
  2  the question cannot be answered: libclang is unavailable, a FILE cannot be read, or a
     FILE does not parse cleanly (any error, including a call to an undeclared function)
"""
import os
import subprocess
import sys


def _usage(msg):
    sys.stderr.write(f"index_helper_defs: {msg}\n")
    sys.stderr.write("usage: index_helper_defs.py [-I DIR]... NAME... -- FILE...\n")
    return 2


def _resource_dir():
    """The compiler's own resource directory, so <stddef.h> and friends resolve; None if
    clang cannot report it (a header that needs it then fails to parse - UNRELIABLE)."""
    try:
        out = subprocess.run(
            ["clang", "-print-resource-dir"], capture_output=True, text=True, timeout=10, check=True
        )
    except Exception:
        return None
    rd = out.stdout.strip()
    return rd if rd and os.path.isdir(rd) else None


def main(argv):
    include_dirs, names, files = [], [], []
    i = 0
    while i < len(argv) and argv[i] != "--":
        if argv[i] == "-I":
            if i + 1 >= len(argv):
                return _usage("-I needs a directory")
            include_dirs.append(argv[i + 1])
            i += 2
            continue
        names.append(argv[i])
        i += 1
    if i >= len(argv):
        return _usage("missing '--' before the files")
    files = argv[i + 1 :]
    if not names or not files:
        return _usage("need at least one NAME and one FILE")

    try:
        import clang.cindex as ci

        index = ci.Index.create()
    except Exception as exc:
        sys.stderr.write(f"index_helper_defs: libclang (clang.cindex) is not usable: {exc}\n")
        return 2

    args = ["-x", "c", "-std=c17", "-Werror=implicit-function-declaration"]
    rd = _resource_dir()
    if rd:
        args.append(f"-resource-dir={rd}")
    for d in include_dirs:
        args.append(f"-I{d}")
    # Every central file's own directory, so a source finds the header it includes by name wherever
    # the port keeps the two (include/idx.h beside src/idx.c).
    for p in files:
        args.append(f"-I{os.path.dirname(os.path.realpath(p))}")

    defined = set()
    for path in files:
        if not os.path.isfile(path) or not os.access(path, os.R_OK):
            sys.stderr.write(f"index_helper_defs: cannot read '{path}'\n")
            return 2
        real = os.path.realpath(path)
        try:
            tu = index.parse(
                path,
                args=args,
                options=ci.TranslationUnit.PARSE_DETAILED_PROCESSING_RECORD,
            )
        except Exception as exc:
            sys.stderr.write(f"index_helper_defs: libclang could not parse '{path}': {exc}\n")
            return 2
        for d in tu.diagnostics:
            if d.severity >= ci.Diagnostic.Error:
                sys.stderr.write(
                    f"index_helper_defs: '{path}' does not parse cleanly, so its definitions "
                    f"cannot be trusted: {d.location.line}: {d.spelling}\n"
                )
                return 2
        for cur in tu.cursor.get_children():
            if cur.location.file is None or os.path.realpath(cur.location.file.name) != real:
                continue
            if cur.kind in (ci.CursorKind.FUNCTION_DECL, ci.CursorKind.MACRO_DEFINITION):
                defined.add(cur.spelling)

    undefined = [n for n in names if n not in defined]
    for n in undefined:
        print(n)
    return 1 if undefined else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
