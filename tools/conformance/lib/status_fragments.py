#!/usr/bin/env python3
"""The rules of check-status-fragments.sh, applied to each fragment's loaded YAML data.

check-status-fragments.sh finds the fragments and runs this with their paths, from the repo root.
Each fragment is loaded by the strict loader the TRACE generator uses (tools/coordination/
_chisel_lib.py: a repeated key is an error), with every scalar kept as the text written in the file,
and the old unit vocabulary mapped by modern(). So the check judges the same data the generator
reads: an alias is the value it points to (`reviewer_id: *w` equals the `&w` author_id it names),
and a list is the same list in block or flow form.

The schema is two levels deep: top-level keys, and the keys of a section such as `ownership:` or
`proof:`, are checked against the known keys; a value is a scalar, null, or a list of scalars. The
rules and messages are listed in check-status-fragments.sh.

Usage: status_fragments.py FRAGMENT...   (run from the repo root; prints the report)
Exit:  0 GREEN, 1 RED (a fragment violates the schema), 2 UNRELIABLE (no PyYAML, or a claim that
       could not be compared).
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
COORD = os.path.join(HERE, "..", "..", "coordination")
sys.path.insert(0, COORD)
from _chisel_lib import text_loader, modern, VocabularyConflict  # noqa: E402

KNOWN_SCALAR = set("""id source target status provides_contract ownership.kind ownership.workstream
 ownership.owned_surface author_id author_team reviewer_id reviewer_team reviewer_session
 claim.ref claim.claimant claim.state product.branch_commit product.main_commit proof.tier
 proof.validation proof.commit proof.evidence review.evidence review.targets integration.state
 integration.epoch_certificate workbench_manifest notes""".split())
# notes accepts BOTH a scalar string (legacy) and a list (preferred): it is in KNOWN_SCALAR above AND
# KNOWN_LIST here, so a synced instance's existing string notes never breaks.
KNOWN_LIST = {"author_sessions", "depends_on", "consumes_contracts", "notes"}
SECTIONS = {k.split(".", 1)[0] for k in KNOWN_SCALAR if "." in k}


def is_set(v):
    return bool(v) and v != "null" and v != "[]" and "<" not in v


def text(v):
    """A value as the text the rules compare: a list in flow form, null as ''."""
    if v is None:
        return ""
    if isinstance(v, list):
        return "[" + ", ".join("null" if i is None else str(i) for i in v) + "]"
    return str(v)


def yaml_reason(exc):
    """A YAML error in one line, with the line it points at."""
    problem = getattr(exc, "problem", None)
    mark = getattr(exc, "problem_mark", None)
    if problem and mark is not None:
        return "%s, line %d" % (problem, mark.line + 1)
    return " ".join(str(exc).split())


def is_scalar(v):
    return v is None or isinstance(v, str)


class Fragment:
    """The fragment flattened to the form the rules read: F["key"] / F["section.key"] as text, plus
    the author_sessions and notes items. Shape violations are collected in `fails`."""

    def __init__(self, doc):
        self.F = {}
        self.raw = {}
        self.author_sessions = []
        self.notes_items = []
        self.fails = []
        if doc is None:
            doc = {}
        if not isinstance(doc, dict):
            self.fails.append("is not a mapping of fields")
            return
        for key, val in doc.items():
            if not isinstance(key, str):
                self.fails.append("unknown key '%s'" % (key,))
                continue
            if isinstance(val, dict):
                for sub, sval in val.items():
                    self._field("%s.%s" % (key, sub), sval)
                continue
            if val is None and key in SECTIONS:
                continue  # an empty section
            self._field(key, val)

    def _field(self, key, val):
        if isinstance(val, list):
            if key not in KNOWN_LIST and key not in KNOWN_SCALAR:
                self.fails.append("unknown list key '%s'" % key)
                return
            for item in val:
                if not is_scalar(item):
                    self.fails.append("'%s' must list scalars, not a mapping or a list" % key)
                    return
            items = [i for i in val if i]
            if key == "author_sessions":
                self.author_sessions = items
            elif key == "notes":
                self.notes_items = items
        elif not is_scalar(val):
            self.fails.append("'%s' nests deeper than the fragment schema allows" % key)
            return
        if key not in KNOWN_SCALAR and key not in KNOWN_LIST:
            self.fails.append("unknown key '%s'" % key)
        self.F[key] = text(val)
        self.raw[key] = val

    def get(self, key):
        return self.F.get(key, "")


def duplicate_keys(yaml, node, path=(), seen_nodes=None):
    """The keys a mapping holds twice, section-qualified ('status', 'claim.claimant'), found on the
    composed node tree so each is named with its section; the strict loader would stop at the
    first one with no section."""
    seen_nodes = set() if seen_nodes is None else seen_nodes
    if id(node) in seen_nodes:
        return []
    seen_nodes.add(id(node))
    out = []
    if isinstance(node, yaml.MappingNode):
        names = set()
        for key_node, value_node in node.value:
            name = key_node.value if isinstance(key_node, yaml.ScalarNode) else "?"
            if name in names:
                out.append(".".join(path + (name,)))
            names.add(name)
            out += duplicate_keys(yaml, value_node, path + (name,), seen_nodes)
    elif isinstance(node, yaml.SequenceNode):
        for item in node.value:
            out += duplicate_keys(yaml, item, path, seen_nodes)
    return out


def claim_worker(uid):
    """(exit code, stdout, stderr) of the coordination tools' own claim reader (thread_ledger.py
    resume), which validates the whole claims dir - session-id form, one (piece, role) per id -
    before it answers: 0 prints the worker session, 3 none recorded, 1 the ledger is inconsistent,
    2 PyYAML is unavailable."""
    try:
        r = subprocess.run([sys.executable, os.path.join(COORD, "thread_ledger.py"), "resume", uid,
                            "--role", "worker", "--claims-dir", "port/claims"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        return 2, "", str(exc)
    out = r.stdout.decode("utf-8", "replace").rstrip("\n")
    return r.returncode, out, r.stderr.decode("utf-8", "replace")


def check(f, yaml, loader):
    """[(level, message)] for one fragment; level is FAIL or UNRELIABLE."""
    try:
        with open(f, encoding="utf-8") as fh:
            raw = fh.read()
    except OSError:
        return [("FAIL", "not found/readable")]
    except UnicodeDecodeError:
        return [("FAIL", "is not valid YAML (not UTF-8 text)")]
    try:
        dups = duplicate_keys(yaml, yaml.compose(raw, Loader=loader))
        if dups:
            return [("FAIL", "duplicate key '%s'" % d) for d in dups]
        doc = modern(yaml.load(raw, Loader=loader))
    except VocabularyConflict as exc:
        return [("FAIL", "duplicate key: %s - a field is recorded under its old and its new name; "
                 "keep one" % exc)]
    except Exception as exc:  # a YAML error, or a key that cannot be a mapping key
        return [("FAIL", "is not valid YAML (%s)" % yaml_reason(exc))]

    fr = Fragment(doc)
    out = [("FAIL", m) for m in fr.fails]
    F = fr.get

    def fail(msg):
        out.append(("FAIL", msg))

    st = F("status")

    # Base required fields.
    for req in ("id", "source", "status", "ownership.kind"):
        if not is_set(F(req)):
            fail("missing/placeholder required field '%s'" % req)

    # Enums (validated when set).
    if is_set(st) and st not in ("unmapped", "in-progress", "proven", "excluded"):
        fail("invalid status '%s'" % st)
    if is_set(F("ownership.kind")) and F("ownership.kind") not in ("owned", "leaf"):
        fail("invalid ownership.kind '%s'" % F("ownership.kind"))
    if is_set(F("claim.state")) and F("claim.state") not in ("created", "active", "stale"):
        fail("invalid claim.state '%s'" % F("claim.state"))
    if is_set(F("integration.state")) and F("integration.state") not in ("proven", "integrated"):
        fail("invalid integration.state '%s'" % F("integration.state"))
    if is_set(F("proof.validation")) and F("proof.validation") != "transitive":
        fail("proof.validation must be 'transitive' or null (declaration-only marker)")

    # Owned items name an owner.
    if F("ownership.kind") == "owned" and not is_set(F("ownership.workstream")):
        fail("ownership.kind=owned but ownership.workstream is unset")
    if F("ownership.kind") == "owned" and not is_set(F("ownership.owned_surface")):
        fail("ownership.kind=owned but ownership.owned_surface is unset")

    # Status-dependent requirements.
    if st == "excluded":
        # A reason is required: a scalar `notes:` string (legacy) OR at least one list item.
        if not (is_set(F("notes")) or fr.notes_items):
            fail("excluded row needs a reason in notes")
    elif st == "in-progress":
        # author_id may still be null: the orchestrator records it from the worker's Task result.
        for req in ("target", "claim.ref", "claim.claimant", "claim.state"):
            if not is_set(F(req)):
                fail("status '%s' requires '%s'" % (st, req))
    elif st == "proven":
        for req in ("target", "claim.ref", "claim.claimant", "claim.state", "author_id"):
            if not is_set(F(req)):
                fail("status '%s' requires '%s'" % (st, req))

    # The cited claim is this unit's own: the local port/claims/<id>.yaml or the pushed ref
    # refs/claims/<id>. Another unit's claim (a fragment copied from a sibling) binds this unit to a
    # reservation that does not cover it.
    uid = F("id")
    ref = F("claim.ref")
    if is_set(ref) and is_set(uid) and ref not in ("port/claims/%s.yaml" % uid, "refs/claims/%s" % uid):
        fail("claim.ref '%s' is not this unit's claim (expected port/claims/%s.yaml or refs/claims/%s)"
             % (ref, uid, uid))

    # A set author_id agrees with the worker session the local claim records: the orchestrator
    # writes both from the same Task result, so a mismatch is an identity typed by hand, guessed by
    # the worker, or pasted from another unit. The claim is local and gitignored (absent in CI,
    # removed once released), so only a present claim with a recorded worker is compared.
    claim_file = "port/claims/%s.yaml" % uid
    if is_set(F("author_id")) and is_set(uid) and "/" not in uid and os.path.isfile(claim_file):
        rc, worker, err = claim_worker(uid)
        if rc == 3:
            pass  # the claim records no worker thread: nothing to compare
        elif rc == 0:
            if worker != F("author_id"):
                fail("author_id '%s' does not match the worker session '%s' recorded in %s "
                     "threads.worker - author_id is recorded by the orchestrator from the worker's "
                     "Task result, never typed or guessed (a worker leaves it null)"
                     % (F("author_id"), worker, claim_file))
        elif rc == 1:
            fail("the claims ledger cannot vouch for author_id (%s)" % " ".join(err.split()))
        else:
            out.append(("UNRELIABLE", "python3 with PyYAML is needed to compare author_id with %s "
                        "threads.worker" % claim_file))

    # target, when set, must be a list (the TRACE generator requires it); reject a bare scalar,
    # including one that only looks like a list ("[a.c]" in quotes).
    if is_set(F("target")) and not isinstance(fr.raw.get("target"), list):
        fail("target must be a list like [path.c], not a bare scalar (the TRACE generator "
             "requires a list)")

    # proven => a real, independent review and a tier-R1+ proof.
    if st == "proven":
        if is_set(F("reviewer_id")):
            if F("reviewer_id") == F("author_id"):
                fail("reviewer_id == author_id ('%s') - independence violated" % F("author_id"))
        else:
            fail("proven requires reviewer_id (independent reviewer)")
        if is_set(F("reviewer_session")):
            for s in fr.author_sessions:
                if s == F("reviewer_session"):
                    fail("reviewer_session '%s' appears in author_sessions - independence violated" % s)
        else:
            fail("proven requires reviewer_session")
        if not fr.author_sessions:
            fail("proven requires a non-empty author_sessions (list)")
        if is_set(F("proof.tier")):
            if not re.fullmatch(r"R[1-9][0-9]*", F("proof.tier")):
                fail("proof.tier '%s' must be R1 or higher (R0 cannot prove)" % F("proof.tier"))
        else:
            fail("proven requires proof.tier (R1+)")
        if not is_set(F("proof.commit")):
            fail("proven requires proof.commit (the product commit the proof ran against)")
        if not is_set(F("proof.evidence")):
            fail("proven requires proof.evidence")
        if not is_set(F("review.evidence")):
            fail("proven requires review.evidence")

    # Any non-null integration state requires the piece be proven first.
    if is_set(F("integration.state")) and st != "proven":
        fail("integration.state '%s' set but status is not proven" % F("integration.state"))

    # integrated => proven, on the canonical line (product.main_commit records where it landed).
    if F("integration.state") == "integrated":
        if st != "proven":
            fail("integration.state=integrated requires status: proven")
        if not is_set(F("product.main_commit")):
            fail("integrated requires product.main_commit")
    return out


def main(files):
    try:
        import yaml
    except Exception:
        print("check-status-fragments: python3 with PyYAML is needed to read the fragments "
              "(install pyyaml).")
        print("RESULT: UNRELIABLE (exit 2) - %d fragment(s) could not be checked." % len(files))
        return 2
    loader = text_loader(yaml)
    fails = unreliable = 0
    for f in files:
        findings = check(f, yaml, loader)
        for level, msg in findings:
            print("[%s] %s: %s" % (level, f, msg))
        fails += sum(1 for level, _ in findings if level == "FAIL")
        unreliable += 1 if any(level == "UNRELIABLE" for level, _ in findings) else 0
        if not findings:
            print("  ok: %s" % f)
    print("check-status-fragments: checked %d fragment(s); %d violation(s)." % (len(files), fails))
    if fails:
        print("RESULT: RED (exit 1) - a status fragment is malformed or violates independence.")
        return 1
    if unreliable:
        print("RESULT: UNRELIABLE (exit 2) - %d fragment(s) could not be fully checked." % unreliable)
        return 2
    print("RESULT: GREEN (exit 0) - all status fragments are well-formed.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:  # never a traceback and exit 1: that would read as a RED verdict
        print("check-status-fragments: unexpected error (%s) - UNRELIABLE (exit 2)." % exc)
        sys.exit(2)
