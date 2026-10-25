#!/usr/bin/env python3
"""migrate-proof-vocabulary.py - move from the 'gate / gated' vocabulary to 'proof / proven'.

Chisel used to call the validation-ladder checks "gates" and a unit that passed its gate plus an
independent review "gated". It now calls them PROOFS and PROVEN:

    R1 gate  -> R1 proof          status: gated   -> status: proven
    gate: / gate_tier: / gate_commit:   -> proof: / proof_tier: / proof_commit:
    mark-gated -> mark-proven     kind: gate (Phase-1 unit) -> kind: proof
    auto-gate: clean-only (charter) -> auto-prove: clean-only
    /port-gate -> /port-prove     tools/gates/ -> tools/proofs/
    port/bring-up-gate.md -> port/bring-up-harness.md

Every tool still READS the old names (tools/coordination/_chisel_lib.py: modern()), so a port keeps
working before it migrates. Two modes:

  migrate-proof-vocabulary.py [--apply]        DATA mode (what a port runs, once, after syncing).
      Rewrites only machine-read keys and values in the port's own state - TRACE, status fragments,
      the Phase-1 plan and its units, claims, autodrive config, assemblies, and the charter's
      auto-gate policy key - and renames port/bring-up-gate.md. It never touches prose or history:
      LESSONS, handoffs, retrospectives and evidence stay exactly as written (the ledger is
      append-only). Each rewritten YAML file is re-read and must equal the original once the old
      names are mapped to the new ones, so the migration can change vocabulary and nothing else.
      tools/gates/ is left where it is: it is the port's own directory, still run by CI and still
      port-owned on sync; move it with `git mv tools/gates tools/proofs` when convenient.
      Without --apply it only reports what it would change.

  migrate-proof-vocabulary.py --methodology [--apply]
      The rewrite of the methodology layer itself (prose, comments, templates, fixtures, file names)
      that produced this vocabulary change in the base. A port may run it to bring its own local,
      not-yet-contributed methodology files in line; it is idempotent.

Exit: 0 done (or nothing to do); 1 a rewritten file failed its round-trip check (nothing written);
2 usage / environment error.
"""
import argparse
import glob
import os
import re
import subprocess
import sys

# ---------------------------------------------------------------------------------------------------
# Methodology-layer rewrite rules. Order matters: names and the senses of "gate" that are NOT a proof
# (a guarded operation, a checkpoint, a sealed milestone, a compile-time switch) come first; the
# generic word mapping runs last on whatever is left.
# ---------------------------------------------------------------------------------------------------
RENAMES = [  # (old path, new path) - file and directory renames, applied with git mv
    (".opencode/command/port-gate.md", ".opencode/command/port-prove.md"),
    (".opencode/skill/code-port/assets/BRING-UP-GATE.template.md",
     ".opencode/skill/code-port/assets/BRING-UP-HARNESS.template.md"),
    (".github/workflows/gates.yml", ".github/workflows/ci.yml"),
    ("tools/tests/test-shape-gates.sh", "tools/tests/test-shape-guards.sh"),
]

PHRASES = [
    # names that follow the renames above
    (r"port-gate\b", "port-prove"),
    (r"BRING-UP-GATE\b", "BRING-UP-HARNESS"),
    (r"bring-up-gate\b", "bring-up-harness"),
    (r"bring-up entry gate", "bring-up harness"),
    (r"workflows/gates\.yml", "workflows/ci.yml"),
    (r"\bgates\.yml\b", "ci.yml"),
    (r"\bname: gates\b", "name: ci"),
    (r"test-shape-gates\b", "test-shape-guards"),
    (r"conformance-and-gates\b", "conformance-and-proofs"),
    # a sealed milestone
    (r"\bgate-sealed\b", "sealed"),
    (r"\bGATE-SEALED\b", "SEALED"),
    # operations guarded by checks (not proofs)
    (r"\bconformance-gated\b", "conformance-checked"),
    (r"\bsign-off-gated\b", "sign-off-guarded"),
    (r"\bsign-off-GATED\b", "sign-off-GUARDED"),
    (r"\bhuman-gated\b", "human-approved"),
    (r"\bcontract-gated\b", "contract-checked"),
    (r"\bgated (land|lands|landing|push|path|paths|script|scripts|finalize|crossing|crossings|merge|"
     r"tag|step|operation|operations|sync)\b", r"guarded \1"),
    (r"\bGATED (LAND|PUSH|PATH|SCRIPTS?)\b", r"GUARDED \1"),
    (r"\b(shape|asset-only) gate(s?)\b", r"\1 guard\2"),
    (r"\b([Tt])he gates are the (authority|acceptance|team)", r"\1he checks are the \2"),
    (r"\b([Tt])he GATES are the (authority|acceptance|team)", r"\1he CHECKS are the \2"),
    (r"\bauthority is the GATES\b", "authority is the CHECKS"),
    # checkpoints
    (r"\b(trust|entry|cutover|land|governance|hard|merge-RESULT|HEAD-only) gate\b", r"\1 check"),
    (r"\bmeta-gate\b", "meta-check"),
    (r"\bland-gate\b", "land-check"),
    (r"\bPre-merge Gate ([AB])\b", r"Pre-merge Check \1"),
    (r"\bhuman gate\b", "human checkpoint"),
    (r"\baccept is the gate\b", "accept is the checkpoint"),
    # compile-time switches keep their usual name
    (r"\bfeature gates\b", "feature flags"),
    (r"\bfeature gate\b", "feature flag"),
    (r"\bfeature-gating\b", "feature-flagging"),
    # the charter policy key and who may record a unit proven
    (r"\bauto-gated\b", "auto-proven"),
    (r"\bauto-gate\b", "auto-prove"),
    (r"\bwho-may-gate\b", "who-may-mark-proven"),
    # re-proving a unit
    (r"\bneeds-regate\b", "needs-reprove"),
    (r"\b([Rr])e-gate\b", r"\1e-prove"),
    (r"\b([Rr])e-gates\b", r"\1e-proves"),
    (r"\b([Rr])e-gated\b", r"\1e-proven"),
    (r"\b([Rr])e-gating\b", r"\1e-proving"),
]

WORDS = {"gate": "proof", "gates": "proofs", "gated": "proven", "gating": "proving"}
GENERIC = re.compile(r"(?<![A-Za-z])(gat(?:e|es|ed|ing))(?![A-Za-z])", re.IGNORECASE)


def _cased(src, repl):
    if src.isupper():
        return repl.upper()
    if src[0].isupper():
        return repl[0].upper() + repl[1:]
    return repl


# A line carrying this marker keeps the old names on purpose (a reader's alias); "legacy-vocab-next"
# also keeps the line after it, for formats with no trailing comments (.gitattributes).
KEEP = "legacy-vocab"


def rewrite_text(text):
    kept = []

    def hold(m):
        kept.append(m.group(0))
        return "\0%d\0" % (len(kept) - 1)

    text = re.sub(r"^.*%s-next.*\n.*$" % KEEP, hold, text, flags=re.M)
    text = re.sub(r"^.*%s.*$" % KEEP, hold, text, flags=re.M)
    for pat, rep in PHRASES:
        text = re.sub(pat, rep, text)
    text = GENERIC.sub(lambda m: _cased(m.group(1), WORDS[m.group(1).lower()]), text)
    return re.sub(r"\0(\d+)\0", lambda m: kept[int(m.group(1))], text)


def _git(*a, check=True):
    r = subprocess.run(["git", *a], capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit("migrate-proof-vocabulary: git %s failed: %s" % (" ".join(a), r.stderr.strip()))
    return r.stdout


def methodology(apply, base=False):
    """Rewrite every tracked, non-project-layer text file, and apply the renames. With base=True
    (the base repo only) the starter project-layer files the base ships are rewritten too; a port's
    own project layer - its ledger, handoffs, evidence - is never rewritten."""
    files = [f for f in _git("ls-files", "-z").split("\0") if f]
    attrs = _git("check-attr", "-z", "merge", "--", *files).split("\0")
    project = {attrs[i] for i in range(0, len(attrs) - 2, 3) if attrs[i + 2] == "ours"}
    # this script and the shared reader library hold the old names on purpose (the alias table)
    skip = {"LICENSE", "tools/migrate-proof-vocabulary.py", "tools/coordination/_chisel_lib.py"}
    changed = 0
    for f in files:
        if (f in project and not base) or f in skip or not os.path.isfile(f) or os.path.islink(f):
            continue
        try:
            old = open(f, encoding="utf-8").read()
        except UnicodeDecodeError:
            continue  # binary
        new = rewrite_text(old)
        if new != old:
            changed += 1
            print("rewrite %s" % f)
            if apply:
                open(f, "w", encoding="utf-8").write(new)
    for old, new in RENAMES:
        if old in project and not base:
            continue  # a port's own files are never renamed here
        if os.path.exists(old) and not os.path.exists(new):
            print("rename  %s -> %s" % (old, new))
            if apply:
                os.makedirs(os.path.dirname(new), exist_ok=True)
                _git("mv", old, new)
    print("%s %d file(s)" % ("rewrote" if apply else "would rewrite", changed))


# ---------------------------------------------------------------------------------------------------
# DATA mode - a port's own machine-read state.
# ---------------------------------------------------------------------------------------------------
YAML_GLOBS = ["port/TRACE.yaml", "port/status/*.yaml", "port/phase1-plan.yaml", "port/phase1/units/*.yaml",
              "port/claims/*.yaml", "port/autodrive.yaml", "port/assemblies.yaml"]
YAML_RULES = [
    (re.compile(r"^(\s*(?:-\s+)?)gate(_tier|_commit)?:", re.M), r"\1proof\2:"),
    (re.compile(r"^(\s*(?:-\s+)?(?:status|state|integration):\s*['\"]?)gated\b", re.M), r"\1proven"),
    (re.compile(r"^(\s*(?:-\s+)?kind:\s*['\"]?)gate\b", re.M), r"\1proof"),
    (re.compile(r"(?<![A-Za-z-])mark-gated\b"), "mark-proven"),
]
CHARTER = "port/plan/00-charter.md"
CHARTER_RULE = (re.compile(r"(?<![A-Za-z-])auto-gate:"), "auto-prove:")
FILE_RENAMES = [("port/bring-up-gate.md", "port/bring-up-harness.md")]


def data(apply):
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "coordination"))
    try:
        import yaml
        from _chisel_lib import modern, strict_loader
    except ImportError as exc:
        sys.exit("migrate-proof-vocabulary: %s (PyYAML and tools/coordination/_chisel_lib.py are needed)" % exc)
    loader = strict_loader(yaml)
    plans = []
    for pattern in YAML_GLOBS:
        for path in sorted(glob.glob(pattern)):
            old = open(path, encoding="utf-8").read()
            new = old
            for rx, rep in YAML_RULES:
                new = rx.sub(rep, new)
            if new == old:
                continue
            # Round trip: the rewritten file must hold exactly the data of the original once the old
            # vocabulary is mapped to the new one - the migration renames, it never edits.
            before, after = yaml.load(old, Loader=loader), yaml.load(new, Loader=loader)
            if modern(before) != after:
                print("FAIL    %s: the rewrite would change more than the vocabulary - not written" % path)
                return 1
            plans.append((path, new))
    if os.path.isfile(CHARTER):
        old = open(CHARTER, encoding="utf-8").read()
        new = CHARTER_RULE[0].sub(CHARTER_RULE[1], old)
        if new != old:
            plans.append((CHARTER, new))
    for path, new in plans:
        print("rewrite %s" % path)
        if apply:
            open(path, "w", encoding="utf-8").write(new)
    renames = [(o, n) for o, n in FILE_RENAMES if os.path.exists(o) and not os.path.exists(n)]
    for o, n in renames:
        print("rename  %s -> %s" % (o, n))
        if apply:
            _git("mv", o, n)
    if not plans and not renames:
        print("nothing to migrate - this port already uses proof / proven")
    elif not apply:
        print("dry run: re-run with --apply to write these changes, then commit them")
    if os.path.isdir("tools/gates"):
        print("note    tools/gates/ is kept and still run by CI; rename it when convenient: git mv tools/gates tools/proofs")
    prog = "tools/scoping/port-progress.py"
    if os.path.isfile(prog) and '"gated"' in open(prog, encoding="utf-8").read() and "modern" not in open(prog, encoding="utf-8").read():
        print("note    %s is this port's own copy and predates proof / proven; take the base's: "
              "git checkout upstream/main -- %s" % (prog, prog))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--apply", action="store_true", help="write the changes (default: report only)")
    ap.add_argument("--methodology", action="store_true", help="rewrite the methodology layer")
    ap.add_argument("--base", action="store_true", help="with --methodology, in the base repo only: also its starter files")
    args = ap.parse_args()
    top = _git("rev-parse", "--show-toplevel").strip()
    os.chdir(top)
    if args.methodology:
        methodology(args.apply, args.base)
        return 0
    return data(args.apply)


if __name__ == "__main__":
    sys.exit(main())
