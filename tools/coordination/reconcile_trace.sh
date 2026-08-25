#!/usr/bin/env bash
# Reconciles port/TRACE.yaml rows against OBSERVED state, on main.
#
# Why this exists (references/failure-modes.md, B25's fully-silent case): the layering convention
# marks the project layer so that the integration branch always wins, which is right for a
# methodology sync and wrong for merging a piece's own branch - the piece's TRACE edits are then
# discarded with no conflict and no diagnostic. A majority of already-landed pieces were found
# still carrying a row reading `unmapped`. Relaxing the attribute would reopen the sync hazard it
# exists to close, so instead TRACE gets an OWNER at the point of use: rows are DERIVED here, on
# the integration branch.
#
# Every field is derived from something observable, never from an assertion:
#   target      <- the unit's files actually present in the product tree
#   review      <- verdict read from line 1 of the committed review report
#   status      <- in-progress once target files exist AND the review reads clean
#   validation  <- transitive for a declaration-only SOURCE unit (zero executable blocks)
#
# A unit whose review is absent or not `clean` is REPORTED and left untouched: this tool never
# promotes a unit past its review.
#
# --dry-run (default) prints the plan; --apply writes. Exit 0 ok, 1 refused, 2 unusable input.
set -uo pipefail

MODE="dry-run"
[ "${1:-}" = "--apply" ] && MODE="apply"

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "reconcile-trace: not a git repo" >&2; exit 2; }
TRACE="$REPO/port/TRACE.yaml"
[ -f "$TRACE" ] || { echo "reconcile-trace: no $TRACE" >&2; exit 2; }

# Share the ONE definition of "where is the product" with the conformance checks, so this cannot
# drift from them. Fail-closed: once a product is wired, being unable to reach it must not skip.
if [ -z "${PRODUCT_ROOT:-}" ] && [ -f "$REPO/tools/conformance/lib/product-root.sh" ]; then
    # shellcheck source=/dev/null
    . "$REPO/tools/conformance/lib/product-root.sh"
    PRODUCT_ROOT="$(default_product_root)" || {
        echo "reconcile-trace: product root is wired but unreachable -> UNRELIABLE" >&2; exit 2; }
fi
PRODUCT="${PRODUCT_ROOT:-$REPO/target}"
[ -d "$PRODUCT/src" ] || { echo "reconcile-trace: product tree '$PRODUCT/src' absent -> UNRELIABLE" >&2; exit 2; }

SOURCE_ROOT="$REPO/source"
[ -d "$SOURCE_ROOT" ] || { echo "reconcile-trace: source tree absent -> UNRELIABLE" >&2; exit 2; }

python3 - "$TRACE" "$PRODUCT" "$SOURCE_ROOT" "$REPO" "$MODE" <<'PY'
import os, re, sys

trace_path, product, source_root, repo, mode = sys.argv[1:6]
lines = open(trace_path).read().split("\n")

# index rows: id -> (start, end)
bounds, order = {}, []
for i, l in enumerate(lines):
    m = re.match(r"^- id: (.+)$", l)
    if m:
        if order:
            bounds[order[-1]] = (bounds[order[-1]][0], i)
        order.append(m.group(1))
        bounds[m.group(1)] = (i, len(lines))
if order:
    bounds[order[-1]] = (bounds[order[-1]][0], len(lines))

def field(uid, name):
    s, e = bounds[uid]
    for j in range(s, e):
        m = re.match(rf"^  {name}: (.*)$", lines[j])
        if m:
            return j, m.group(1).strip()
    return None, None

def set_field(uid, name, value):
    j, _ = field(uid, name)
    if j is None:
        return False
    lines[j] = f"  {name}: {value}"
    return True

def source_is_declaration_only(rel):
    p = os.path.join(source_root, rel)
    if not os.path.isfile(p):
        return None
    try:
        txt = open(p, errors="replace").read()
    except OSError:
        return None
    # A Fortran function may carry a type prefix (`LOGICAL FUNCTION F`, `REAL(KIND=JWRB)
    # FUNCTION G`, `ELEMENTAL PURE INTEGER FUNCTION H`), so an anchored `^\s*FUNCTION` misses
    # them and would mislabel a computational routine as declaration-only - putting it on the
    # transitive validation path by mistake. Match FUNCTION/SUBROUTINE anywhere before the
    # name, ignoring continuation and comment lines.
    for line in txt.splitlines():
        s = line.strip()
        if not s or s.startswith("!"):
            continue
        if re.match(r"^(END\s+)?(SUBROUTINE|FUNCTION)\b", s, re.I):
            return False
        if re.match(r"^CONTAINS\b", s, re.I):
            return False
        # type-prefixed / attribute-prefixed function statement
        if re.match(r"^[A-Z0-9_()\*=,:\s]*?\bFUNCTION\s+\w+\s*\(", s, re.I):
            return False
    return True

# A few SOURCE units are translated by a DIFFERENT unit (the Layer-0 hoists gather several
# SOURCE units into one reviewable deliverable), so their review lives under that unit's id.
# DECLARED in port/declared-translators.yaml, never inferred - an undeclared unit simply has no
# alias and will be refused for lack of its own review.
def _load_translators():
    p = os.path.join(repo, "port", "declared-translators.yaml")
    m = {}
    if not os.path.isfile(p):
        return m
    cur = None
    for line in open(p, errors="replace"):
        s = line.strip()
        if s.startswith("- source_unit:"):
            cur = s.split(":", 1)[1].strip()
        elif s.startswith("translated_by:") and cur:
            m[cur] = s.split(":", 1)[1].strip()
            cur = None
    return m

TRANSLATORS = _load_translators()

def review_verdict(uid):
    ids = [uid]
    if uid in TRANSLATORS:
        ids.append(TRANSLATORS[uid])
    cands = [f"docs/evidence/phase2/{i}/review.md" for i in ids] + \
            [f"docs/evidence/{i}/review.md" for i in ids]
    for cand in cands:
        p = os.path.join(repo, cand)
        if os.path.isfile(p):
            first = open(p, errors="replace").readline()
            if "clean" in first:
                return cand, "clean"
            if "violations" in first:
                return cand, "violations"
            return cand, "unparsable"
    return None, None

planned, skipped = [], []
for uid in order:
    _, status = field(uid, "status")
    if status != "unmapped":
        continue
    targets = [f"src/{uid}{ext}" for ext in (".c", ".h") if os.path.isfile(os.path.join(product, f"src/{uid}{ext}"))]
    if not targets:
        continue
    rel_path = field(uid, "source")[1]
    verdict_path, verdict = review_verdict(uid)
    if verdict != "clean":
        skipped.append((uid, verdict or "no review report"))
        continue
    decl_only = source_is_declaration_only(rel_path) if rel_path else None
    planned.append((uid, targets, verdict_path, decl_only))

for uid, targets, vp, decl_only in planned:
    val = "transitive" if decl_only else None
    print(f"  {uid:<18} -> status=in-progress  target={targets}"
          + (f"  validation={val}" if val else "")
          + f"  review={vp}")
    if mode == "apply":
        set_field(uid, "status", "in-progress")
        s, e = bounds[uid]
        j, _ = field(uid, "target")
        if j is not None:
            lines[j] = "  target:\n" + "\n".join(f"  - {t}" for t in targets)
        if val:
            if not set_field(uid, "validation", val):
                jj, _ = field(uid, "status")
                lines[jj] = lines[jj] + f"\n  validation: {val}"

print()
for uid, why in skipped:
    print(f"  REFUSED {uid:<16} landed in product but review is '{why}' - left unmapped")

if mode == "apply":
    open(trace_path, "w").write("\n".join(lines))
    print(f"\nreconcile-trace: applied {len(planned)} row(s)")
else:
    print(f"\nreconcile-trace: DRY RUN - {len(planned)} row(s) would change, {len(skipped)} refused")
PY
