#!/usr/bin/env bash
# check-trace-evidence.sh - TRACE-to-evidence integrity for review/gate metadata.
#
# The hard rule: a module is `gated` only with a gate (tier R1+) AND an independent review
# report, both RECORDED in docs/evidence/. TRACE points at those reports, but nothing
# verified the pointers resolve, so recollection ("it was reviewed") could outweigh the
# absence of a durable report. This makes the desync loud:
#   - every `gated` entry MUST cite a `gate` and a `review` whose paths exist on disk, and
#     that review must be CLEAN (a gated entry whose review verdict is VIOLATIONS is gated
#     by omission of the required clean re-review);
#   - an entry with a `gate` but status not `gated` is the review queue - it still owes a
#     clean review, whether `review` is null (never reviewed) or set to a violations
#     verdict (reviewed, not clean): listed, never failed;
#   - any cited `gate`/`review` path that does not resolve is a violation.
# A review exists iff its report exists here; handoff prose and memory never count.
#
# Scope: this is the CI BACKSTOP on a solo TRACE. Reviewer-session independence and the
# clean-verdict disposition are enforced at /port-review (the gate); this check re-verifies
# that a gated entry records gate_tier R1+ and a gate_commit, cites a gate AND review report
# that EXIST on disk, and that the review is not a recorded-violations verdict.
#
# Exit-code contract: 0 = clean, 1 = integrity violation, 2 = could not run.
#
# Seeded-bug record: tools/conformance/seeded-bugs/check-trace-evidence.md (the red/green
# demonstration of this check's comparison logic). Re-run and update it after ANY change to
# the parse/comparison logic below - the standing seeded-bug rule: a detector unseen to fail
# is unproven.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

TRACE="${TRACE_FILE:-port/TRACE.yaml}"
# Evidence durability (workbench-relative, under docs/evidence/, git-tracked) is enforced only on
# the REAL committed TRACE; a TRACE_FILE fixture exercises the parsing/verdict arms with throwaway
# evidence paths, so the durability arm is off there.
DURABLE_EVIDENCE=1; [ -n "${TRACE_FILE:-}" ] && DURABLE_EVIDENCE=0

command -v awk >/dev/null 2>&1 || { echo "check-trace-evidence: awk not found" >&2; exit 2; }
[ -f "$TRACE" ] || { echo "check-trace-evidence: $TRACE not found; nothing to check (skipping)."; exit 0; }

# Emit one TAB-separated record per file entry: source, status, gate, review. Entry fields
# live at 4-space indent; the nested symbols block (deeper indent) is ignored, as is notes.
records="$(awk '
  function val(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s); return s }
  function key(s) { sub(/^[ \t]*-?[ \t]*/, "", s); sub(/:.*$/, "", s); return s }
  # Entry START is any list item under files:, at ANY indent, whatever its first key.
  # PyYAML-generated TRACE emits "- id:" at column 0; a hand-written one may emit
  # "  - source:" at two-space indent. Both are the same document; keying on one
  # spelling silently parses ZERO records (see the fail-closed guard below).
  /^files:/ { infiles = 1; next }
  infiles && /^[ \t]*[^ \t#-]/ && !/^[ \t]/ { infiles = 0 }   # a new top-level key ends the block
  infiles && /^[ \t]*-[ \t]*[A-Za-z_]+:/ {
    if (have) print src "\t" status "\t" gate "\t" review "\t" gate_tier "\t" gate_commit
    src = ""; status = ""; gate = ""; review = ""; gate_tier = ""; gate_commit = ""; have = 1
    if (key($0) == "source") src = val($0)
    next
  }
  infiles && have {
    k = key($0)
    if      (k == "source")      src         = val($0)
    else if (k == "status")      status      = val($0)
    else if (k == "gate_tier")   gate_tier   = val($0)
    else if (k == "gate_commit") gate_commit = val($0)
    else if (k == "gate")        gate        = val($0)
    else if (k == "review")      review      = val($0)
    next
  }
  END { if (have) print src "\t" status "\t" gate "\t" review "\t" gate_tier "\t" gate_commit }
' "$TRACE")"

# FAIL CLOSED on an unreadable TRACE. Parsing zero records from a file that PLAINLY has a
# `files:` block is not "nothing to check" - it is "I could not read this", which must be
# UNRELIABLE, never a silent green. A layout this scanner does not understand would otherwise
# make the check skip forever while every gated entry goes unverified.
if [ -z "$records" ]; then
  if grep -qE '^files:[[:space:]]*$' "$TRACE" && grep -qE '^[[:space:]]*-[[:space:]]*[A-Za-z_]+:' "$TRACE"; then
    echo "check-trace-evidence: $TRACE has a non-empty 'files:' block but ZERO entries parsed -" >&2
    echo "  the layout is not understood by this scanner. Refusing to report green on a TRACE" >&2
    echo "  it cannot read (UNRELIABLE)." >&2
    exit 2
  fi
  echo "check-trace-evidence: no file entries in $TRACE; nothing to check (skipping)."
  exit 0
fi

is_set() { [ -n "$1" ] && [ "$1" != "null" ] && [ "$1" != "[]" ]; }

fails=0; gated=0; queue=0
while IFS=$'\t' read -r src status gate review gate_tier gate_commit; do
  [ -z "$src" ] && continue
  for pair in "gate=$gate" "review=$review"; do
    name="${pair%%=*}"; path="${pair#*=}"
    if is_set "$path" && [ ! -e "$path" ]; then
      echo "  [FAIL] $src: $name cites a report that does not exist: $path"
      fails=$((fails + 1))
    fi
  done
  if [ "$status" = "gated" ]; then
    gated=$((gated + 1))
    is_set "$gate"   || { echo "  [FAIL] $src: gated but gate is null (R1+ gate evidence required)"; fails=$((fails + 1)); }
    is_set "$review" || { echo "  [FAIL] $src: gated but review is null (independent review report required)"; fails=$((fails + 1)); }
    if is_set "$gate_tier"; then
      [[ "$gate_tier" =~ ^R[1-9][0-9]*$ ]] || { echo "  [FAIL] $src: gated gate_tier '$gate_tier' must be R1 or higher (R0 cannot gate)"; fails=$((fails + 1)); }
    else
      echo "  [FAIL] $src: gated requires gate_tier (R1+)"; fails=$((fails + 1))
    fi
    is_set "$gate_commit" || { echo "  [FAIL] $src: gated requires gate_commit (the product commit the gate ran against)"; fails=$((fails + 1)); }
    if [ "$DURABLE_EVIDENCE" = 1 ]; then
      for pair in "gate=$gate" "review=$review"; do
        name="${pair%%=*}"; path="${pair#*=}"; is_set "$path" || continue
        case "$path" in
          docs/evidence/*) : ;;
          *) echo "  [FAIL] $src: gated $name '$path' must be a workbench-relative path under docs/evidence/ (durable evidence, not /tmp or an absolute path)"; fails=$((fails + 1)); continue ;;
        esac
        case "$path" in *..*) echo "  [FAIL] $src: gated $name '$path' must not contain '..'"; fails=$((fails + 1)); continue ;; esac
        git ls-files --error-unmatch -- "$path" >/dev/null 2>&1 || { echo "  [FAIL] $src: gated $name '$path' is not git-tracked (gated evidence must be committed, not a working-tree-only file)"; fails=$((fails + 1)); }
      done
    fi
    # gated demands an EXPLICIT clean review verdict. A violations verdict, OR a report with no
    # clean verdict at all (an empty or verdict-less file), both leave the piece owing the clean
    # re-review the hard rule requires - "it was reviewed" must be recorded, not assumed.
    if is_set "$review" && [ -e "$review" ]; then
      # Violations FIRST and it includes "not clean", so a "VERDICT: not clean" line can never be
      # read as clean; clean requires the word "clean" immediately after verdict+separators (so
      # "cleanup" / "not clean" do not count). Same strict grammar as autodrive's planner.
      if grep -qiE 'verdict[: ].*(violation|not clean)' "$review"; then
        echo "  [FAIL] $src: gated but its review report records a VIOLATIONS verdict - a clean re-review is required before gating: $review"
        fails=$((fails + 1))
      elif ! grep -qiE 'verdict[: ]+clean\b' "$review"; then
        echo "  [FAIL] $src: gated but its review report records no explicit clean verdict (a gated review must state e.g. 'VERDICT: clean'): $review"
        fails=$((fails + 1))
      fi
    fi
  elif is_set "$gate"; then
    # gate passed but not gated: still owes a clean review (the review queue), whether never
    # reviewed (review null) or reviewed-with-violations (review set, still in-progress).
    if is_set "$review"; then
      echo "  [queue] $src: gate passed, review recorded but status not gated (reviewed-not-clean - a clean re-review is still required before gating)"
    else
      echo "  [queue] $src: gate passed, awaiting first independent review (review: null)"
    fi
    queue=$((queue + 1))
  fi
done <<< "$records"

echo "check-trace-evidence: ${gated} gated, ${queue} awaiting review, ${fails} integrity violation(s)."
if [ "$fails" -gt 0 ]; then
  echo "RESULT: RED - TRACE review/gate metadata does not match docs/evidence/."
  exit 1
fi
echo "RESULT: GREEN - every gated entry cites a gate and a review report that exist."
exit 0
