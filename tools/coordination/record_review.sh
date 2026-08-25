#!/usr/bin/env bash
# record_review.sh - commit a unit's independent review report and record a CLEAN verdict in TRACE.
#
# /port-review already instructs that the review commits ITSELF ("left uncommitted, it is lost").
# That instruction is correct and was still skipped repeatedly in practice, in one direction only:
# when a verdict is `violations` the WORKER commits the report as part of its rework evidence, so it
# survives; when a verdict is `clean` the worker never runs again, so nothing commits it. The
# reviews that actually authorize landing were the only ones being lost - several units were found
# reviewed clean with the report existing solely as an untracked file inside a reviewer's worktree,
# and the claim-release check then correctly refused them because TRACE still read `review: null`.
#
# Per the meta-lesson in references/failure-modes.md: when the ORCHESTRATOR is the failure point the
# remedy is a tool at the point of use, not more diligence. This is that tool.
#
# The verdict is READ from line 1 of the report, never taken as an argument: this cannot be used to
# assert that a review passed. A `violations` report is committed (it is evidence too) but is
# deliberately NOT recorded as a passing review.
#
#   record_review.sh <unit-id> [--worktree <path>] [--trace <path>]
#
# Exit: 0 recorded, 1 refused (a guard tripped), 2 unusable input.
set -uo pipefail

UNIT=""
WB=""
TRACE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --worktree) WB="${2:-}"; shift 2 ;;
        --trace)    TRACE="${2:-}"; shift 2 ;;
        -*)         echo "record-review: unknown option '$1'" >&2; exit 2 ;;
        *)          [ -z "$UNIT" ] && UNIT="$1"; shift ;;
    esac
done

[ -n "$UNIT" ] || { echo "usage: record_review.sh <unit-id> [--worktree <path>] [--trace <path>]" >&2; exit 2; }

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "record-review: not a git repo" >&2; exit 2; }
[ -n "$WB" ]    || WB="$REPO/.worktrees/$UNIT"
[ -n "$TRACE" ] || TRACE="$REPO/port/TRACE.yaml"
[ -d "$WB" ]    || { echo "record-review: no worktree at '$WB'" >&2; exit 2; }

# Locate the report. Candidates are EXPLICIT rather than a recursive search: a worktree contains the
# whole tree, so a pattern matching the unit id also matches the WORKTREE DIRECTORY NAME and will
# happily return an unrelated unit's report from inside it. That mistake produced four byte-identical
# "reviews" of an unrelated unit in one harvest and was caught only by hashing the files.
REL=""
for cand in "docs/evidence/$UNIT/review.md" \
            "docs/evidence/phase1/$UNIT/review.md" \
            "docs/evidence/phase2/$UNIT/review.md"; do
    [ -f "$WB/$cand" ] && REL="$cand" && break
done
[ -n "$REL" ] || { echo "record-review: no review report found for '$UNIT' under $WB/docs/evidence/" >&2; exit 2; }

VERDICT_LINE="$(head -1 "$WB/$REL")"
case "$VERDICT_LINE" in
    *clean*)      VERDICT=clean ;;
    *violations*) VERDICT=violations ;;
    *)            echo "record-review: line 1 of $REL is not a verdict: '$VERDICT_LINE'" >&2; exit 2 ;;
esac

if ! git -C "$WB" ls-files --error-unmatch "$REL" >/dev/null 2>&1 || ! git -C "$WB" diff --quiet -- "$REL"; then
    git -C "$WB" add -- "$REL" || exit 1
    git -C "$WB" commit -q -m "docs(review): record independent review of $UNIT ($VERDICT)" -- "$REL" || exit 1
    echo "record-review: committed $REL"
else
    echo "record-review: $REL already committed"
fi

if [ "$VERDICT" != clean ]; then
    echo "record-review: '$UNIT' verdict is '$VERDICT' - report committed, NOT recorded as a passing review"
    exit 0
fi

[ -f "$TRACE" ] || { echo "record-review: no TRACE at '$TRACE'" >&2; exit 2; }

python3 - "$TRACE" "$UNIT" "$REL" <<'PY'
import re, sys
trace, unit, rel = sys.argv[1:4]
lines = open(trace).read().split("\n")
start = next((i for i, l in enumerate(lines) if l == f"- id: {unit}"), None)
if start is None:
    print(f"record-review: no TRACE row for '{unit}'", file=sys.stderr); sys.exit(1)
end = next((j for j in range(start + 1, len(lines)) if lines[j].startswith("- id: ")), len(lines))
for j in range(start, end):
    if re.match(r"^  review:\s", lines[j]):
        cur = lines[j].split(":", 1)[1].strip()
        if cur not in ("null", "", "~"):
            print(f"record-review: '{unit}' review already set to {cur} - unchanged"); sys.exit(0)
        lines[j] = f"  review: {rel}"
        open(trace, "w").write("\n".join(lines))
        print(f"record-review: TRACE '{unit}'.review -> {rel}"); sys.exit(0)
print(f"record-review: '{unit}' row has no 'review:' field", file=sys.stderr); sys.exit(1)
PY
