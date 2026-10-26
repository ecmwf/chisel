#!/usr/bin/env python3
"""yaml_get - read one value from a YAML file, for the shell tools.

A shell tool that pulls a value out of a YAML file with sed or awk reads the text, not the data: an
alias does not read as the value it points to, a key nested under another mapping looks like a
top-level key, and a repeated key is read once. The Python tools read the same files with PyYAML,
so a shell check and a Python tool could disagree about one file. This is the one reader the shell
tools use instead. It loads the file through the strict loader the Python tools share
(_chisel_lib.text_loader: a repeated key is an error), and reads every scalar as text, never
converting it to a number, a bool or a date, so `0001` or a commit id keeps its digits. It does not
map the old unit vocabulary; the tools that read unit state do that themselves.

Usage:
  yaml_get.py FILE KEY.PATH          print one scalar
  yaml_get.py --list FILE KEY.PATH   print each item of a list of scalars, one per line

KEY.PATH is a dot-separated chain of mapping keys from the top of the document, for example
`checkout` or `meta.source_commit`. A key that itself holds a dot cannot be named.

What a printed scalar is: the text YAML reads, which is not always the characters in the file.
The quotes are removed; a double-quoted scalar has its escapes applied (`"a\tb"` holds a tab,
`"\x41"` is A, `''` in a single-quoted one is one quote); a scalar written over several lines is
folded (a line break becomes a space); a comment is not part of it; an alias is the value it
names. Nothing else is applied: no type conversion. So equal text is not typed equality, in either
direction: `1.0` and `1`, or `yes` and `true`, are different text that PyYAML's typed loader reads as
equal values, and `"1"` and `1` are the same text that it reads as a string and a number.

Contract (stdout and exit code):
  0  found. A scalar is printed as described above, then a newline; an empty string prints an
     empty line. In --list mode each item is printed on its own line, and an empty list prints
     nothing.
  3  no value: a key on the path is absent, or the value (or a mapping on the way to it) is null
     (`~`, `null` or empty). Nothing is printed. A caller with a default uses it on 3 only.
  2  cannot answer, with the reason on stderr: FILE is missing or unreadable, it is not valid
     YAML, it repeats a key, PyYAML is missing, a step on the path is not a mapping, the value is
     a mapping or a list where a scalar is expected (in --list mode: the value is not a list, or
     an item is null, a mapping or a list), a value spans more than one line or holds any other
     control character but a tab (a shell would drop a NUL from `$(...)`, so "L3\0" would read
     as L3), or the arguments are wrong. A caller treats 2 as UNRELIABLE or refuses; never as an
     empty value or a default.
"""
import sys

from _chisel_lib import text_loader, control_char

USAGE = "usage: yaml_get.py [--list] FILE KEY.PATH"


def _fail(msg):
    sys.stderr.write("yaml_get: %s\n" % msg)
    sys.exit(2)


def _line(value, what):
    """The value as one line of text; exit 2 when it is not a single-line scalar."""
    if isinstance(value, dict):
        _fail("%s is a mapping, not a scalar" % what)
    if isinstance(value, list):
        _fail("%s is a list, not a scalar" % what)
    if not isinstance(value, str):
        _fail("%s is not a plain scalar (%s)" % (what, type(value).__name__))
    if "\n" in value or "\r" in value:
        _fail("%s spans more than one line" % what)
    bad = control_char(value)
    if bad is not None:
        _fail("%s holds the control character U+%04X" % (what, ord(bad)))
    return value


def _out(lines):
    sys.stdout.buffer.write("".join(line + "\n" for line in lines).encode("utf-8"))
    sys.stdout.flush()


def main(argv):
    as_list = bool(argv) and argv[0] == "--list"
    if as_list:
        argv = argv[1:]
    if len(argv) != 2:
        _fail(USAGE)
    path, keypath = argv
    keys = keypath.split(".")
    if not all(keys):
        _fail("bad KEY.PATH '%s' (%s)" % (keypath, USAGE))
    try:
        import yaml
    except Exception:
        _fail("PyYAML is not available - cannot read '%s' (install pyyaml)" % path)
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.load(fh, Loader=text_loader(yaml))
    except OSError as exc:
        _fail("cannot read '%s' (%s)" % (path, exc.strerror or exc))
    except Exception as exc:  # a YAML error, a repeated key, a key that cannot be a mapping key
        _fail("'%s' is not valid YAML (%s)" % (path, " ".join(str(exc).split())))

    node = data
    for depth, key in enumerate(keys):
        if node is None:
            sys.exit(3)
        if not isinstance(node, dict):
            where = "'%s'" % ".".join(keys[:depth]) if depth else "the document"
            _fail("%s in '%s' is not a mapping, so it has no key '%s'" % (where, path, key))
        if key not in node:
            sys.exit(3)
        node = node[key]
    if node is None:
        sys.exit(3)

    what = "'%s' in '%s'" % (keypath, path)
    if not as_list:
        _out([_line(node, what)])
        sys.exit(0)
    if not isinstance(node, list):
        _fail("%s is not a list" % what)
    items = []
    for i, item in enumerate(node, 1):
        if item is None:
            _fail("%s item %d is null" % (what, i))
        items.append(_line(item, "%s item %d" % (what, i)))
    _out(items)
    sys.exit(0)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception as exc:  # never a traceback and exit 1: a caller could read 1 as an answer
        _fail("unexpected error (%s)" % exc)
