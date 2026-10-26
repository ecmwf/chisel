#!/usr/bin/env python3
"""The rules of check-trace-evidence.sh, applied to the loaded TRACE data.

check-trace-evidence.sh runs this from the workbench root with the TRACE path. The TRACE is loaded
by the strict loader the TRACE generator and the drift check use (tools/coordination/_chisel_lib.py:
a repeated key is an error), with every scalar kept as the text written in the file; each `files:`
entry's fields are read by name, and the old unit names are mapped by the shared vocabulary table
and modern(). So the check reads the same entries the other
TRACE readers read, whatever the indentation or key order, and only the entry's own fields - never a
`status:` or `review:` nested in its `symbols:` block. The rules and messages are in
check-trace-evidence.sh.

Usage: trace_evidence.py TRACE DURABLE   (DURABLE 1: proven evidence must be committed under
       docs/evidence/; 0 for a TRACE_FILE fixture)
Exit:  0 GREEN, 1 RED (an integrity violation), 2 UNRELIABLE (no PyYAML, or a TRACE that cannot
       be read as a list of file entries).
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "coordination"))
from _chisel_lib import text_loader, modern, LEGACY_KEYS, VocabularyConflict  # noqa: E402

FIELDS = ("source", "status", "proof", "review", "proof_tier", "proof_commit")
PROOF_FIELDS = ("proof", "proof_tier", "proof_commit")


def unreliable(msg):
    sys.stderr.write("check-trace-evidence: %s\n" % msg)
    sys.exit(2)


def text(v):
    """A value as the text the rules compare: null as '', a list or mapping in flow form."""
    if v is None:
        return ""
    if isinstance(v, list):
        return "[" + ", ".join(text(i) for i in v) + "]"
    if isinstance(v, dict):
        return "{" + ", ".join("%s: %s" % (k, text(i)) for k, i in v.items()) + "}"
    return str(v)


def is_set(v):
    return bool(v) and v != "null" and v != "[]"


def yaml_reason(exc):
    problem = getattr(exc, "problem", None)
    mark = getattr(exc, "problem_mark", None)
    if problem and mark is not None:
        return "%s, line %d" % (problem, mark.line + 1)
    return " ".join(str(exc).split())


def entry_fields(entry):
    """(fields, dup): the entry's six fields as text, and the proof fields it records twice under
    their old and new name (" proof_tier ..."), in the order the second copy appears. When both
    names are set the later one is read, as the line scanner did."""
    named = {}
    dup = ""
    for key, val in entry.items():
        name = LEGACY_KEYS.get(key, key) if isinstance(key, str) else key
        if name in PROOF_FIELDS and name in named:
            dup += " " + name
        if name in FIELDS:
            named[name] = val
    named = modern(named)  # the old status value (legacy-vocab) maps to proven
    return {k: text(named.get(k)) for k in FIELDS}, dup


def verdict_lines(path):
    """The report's lines, split on newlines only - as grep reads them. splitlines() would also
    break at a form feed, U+0085 or U+2028, so `VERDICT: clean<U+2028> - 3 violations` would read
    as a clean verdict line."""
    try:
        with open(path, "rb") as fh:
            return fh.read().decode("utf-8", "replace").split("\n")
    except OSError:
        return []


def git_tracked(path):
    r = subprocess.run(["git", "ls-files", "--error-unmatch", "--", path],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


def main(trace, durable):
    try:
        import yaml
    except Exception:
        unreliable("PyYAML is not available - cannot read %s (install pyyaml) (UNRELIABLE)." % trace)
    loader = text_loader(yaml)
    try:
        with open(trace, encoding="utf-8") as fh:
            doc = yaml.load(fh, Loader=loader)
    except yaml.constructor.ConstructorError as exc:
        if exc.problem and exc.problem.startswith("duplicate key"):
            # A field recorded twice is a corrupt TRACE: RED, as a repeated proof field always was.
            print("  [FAIL] %s: %s - a field is recorded more than once; keep one" % (trace, yaml_reason(exc)))
            print("check-trace-evidence: 0 proven, 0 awaiting review, 1 integrity violation(s).")
            print("RESULT: RED - TRACE review/proof metadata does not match docs/evidence/.")
            return 1
        unreliable("%s is not valid YAML (%s) - refusing to report green on a TRACE it cannot read "
                   "(UNRELIABLE)." % (trace, yaml_reason(exc)))
    except Exception as exc:
        unreliable("%s cannot be read as YAML (%s) - refusing to report green on a TRACE it cannot "
                   "read (UNRELIABLE)." % (trace, yaml_reason(exc)))

    if doc is None:
        doc = {}
    if not isinstance(doc, dict):
        unreliable("%s is not a mapping with a 'files:' list - the layout is not understood. Refusing "
                   "to report green on a TRACE it cannot read (UNRELIABLE)." % trace)
    files = doc.get("files")
    if files is None or files == []:
        print("check-trace-evidence: no file entries in %s; nothing to check (skipping)." % trace)
        return 0
    if not isinstance(files, list) or not all(isinstance(e, dict) for e in files):
        unreliable("%s 'files:' is not a list of file entries - the layout is not understood. "
                   "Refusing to report green on a TRACE it cannot read (UNRELIABLE)." % trace)

    fails = proven = queue = 0

    def fail(msg):
        nonlocal fails
        print("  [FAIL] %s" % msg)
        fails += 1

    for n, entry in enumerate(files, 1):
        try:
            f, dup = entry_fields(entry)
        except VocabularyConflict as exc:
            fail("files entry %d: %s" % (n, exc))
            continue
        src = f["source"] or "files entry %d (no source)" % n
        proof, review, proof_tier, proof_commit = f["proof"], f["review"], f["proof_tier"], f["proof_commit"]
        if dup:
            fail("%s: records%s more than once (under its old and new name, or repeated) - keep one"
                 % (src, dup))
        for name, path in (("proof", proof), ("review", review)):
            if is_set(path) and not os.path.exists(path):
                fail("%s: %s cites a report that does not exist: %s" % (src, name, path))
        if f["status"] == "proven":
            proven += 1
            if not is_set(proof):
                fail("%s: proven but proof is null (R1+ proof evidence required)" % src)
            if not is_set(review):
                fail("%s: proven but review is null (independent review report required)" % src)
            if is_set(proof_tier):
                if not re.fullmatch(r"R[1-9][0-9]*", proof_tier):
                    fail("%s: proven proof_tier '%s' must be R1 or higher (R0 cannot prove)"
                         % (src, proof_tier))
            else:
                fail("%s: proven requires proof_tier (R1+)" % src)
            if not is_set(proof_commit):
                fail("%s: proven requires proof_commit (the product commit the proof ran against)" % src)
            if durable:
                for name, path in (("proof", proof), ("review", review)):
                    if not is_set(path):
                        continue
                    if not path.startswith("docs/evidence/"):
                        fail("%s: proven %s '%s' must be a workbench-relative path under docs/evidence/ "
                             "(durable evidence, not /tmp or an absolute path)" % (src, name, path))
                        continue
                    if ".." in path:
                        fail("%s: proven %s '%s' must not contain '..'" % (src, name, path))
                        continue
                    if not git_tracked(path):
                        fail("%s: proven %s '%s' is not git-tracked (proven evidence must be committed, "
                             "not a working-tree-only file)" % (src, name, path))
            # proven demands an EXPLICIT clean review verdict. A violations verdict, OR a report with
            # no clean verdict at all (an empty or verdict-less file), both leave the piece owing the
            # clean re-review the hard rule requires. Violations FIRST, and it includes "not clean", so
            # a "VERDICT: not clean" line is never read as clean; clean needs the word right after
            # verdict and its separators ("cleanup" / "not clean" do not count). Same strict grammar
            # as autodrive's planner.
            if is_set(review) and os.path.exists(review):
                lines = verdict_lines(review)
                if any(re.search(r"verdict[: ].*(violation|not clean)", ln, re.I) for ln in lines):
                    fail("%s: proven but its review report records a VIOLATIONS verdict - a clean "
                         "re-review is required before it can be marked proven: %s" % (src, review))
                elif not any(re.search(r"verdict[: ]+clean\b", ln, re.I) for ln in lines):
                    fail("%s: proven but its review report records no explicit clean verdict (the review "
                         "of a proven entry must state e.g. 'VERDICT: clean'): %s" % (src, review))
        elif is_set(proof):
            # proof passed but not proven: still owes a clean review (the review queue), whether never
            # reviewed (review null) or reviewed-with-violations (review set, still in-progress).
            if is_set(review):
                print("  [queue] %s: proof passed, review recorded but status not proven "
                      "(reviewed-not-clean - a clean re-review is still required before it can be "
                      "marked proven)" % src)
            else:
                print("  [queue] %s: proof passed, awaiting first independent review (review: null)" % src)
            queue += 1

    print("check-trace-evidence: %d proven, %d awaiting review, %d integrity violation(s)."
          % (proven, queue, fails))
    if fails:
        print("RESULT: RED - TRACE review/proof metadata does not match docs/evidence/.")
        return 1
    print("RESULT: GREEN - every proven entry cites a proof and a review report that exist.")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[2] not in ("0", "1"):
        unreliable("usage: trace_evidence.py TRACE DURABLE(0|1)")
    try:
        sys.exit(main(sys.argv[1], sys.argv[2] == "1"))
    except Exception as exc:  # never a traceback and exit 1: that would read as a RED verdict
        unreliable("unexpected error (%s) (UNRELIABLE)." % exc)
