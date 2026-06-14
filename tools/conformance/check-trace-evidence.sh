#!/usr/bin/env bash
# check-trace-evidence.sh - TRACE-to-evidence integrity for review/gate metadata.
#
# The hard rule: a module is `gated` only with a gate (tier R1+) AND an independent review
# report, both RECORDED in docs/evidence/. TRACE points at those reports, but nothing
# verified the pointers resolve, so recollection ("it was reviewed") could outweigh the
# absence of a durable report. This makes the desync loud:
#   - every `gated` entry MUST cite a `gate` and a `review` whose paths exist on disk;
#   - an entry with `gate` set and `review: null` (not yet gated) is the legitimate review
#     queue: listed, never failed;
#   - any cited `gate`/`review` path that does not resolve is a violation.
# A review exists iff its report exists here; handoff prose and memory never count.
#
# Exit-code contract: 0 = clean, 1 = integrity violation, 2 = could not run.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

TRACE="${TRACE_FILE:-port/TRACE.yaml}"

command -v awk >/dev/null 2>&1 || { echo "check-trace-evidence: awk not found" >&2; exit 2; }
[ -f "$TRACE" ] || { echo "check-trace-evidence: $TRACE not found; nothing to check (skipping)."; exit 0; }

# Emit one TAB-separated record per file entry: source, status, gate, review. Entry fields
# live at 4-space indent; the nested symbols block (deeper indent) is ignored, as is notes.
records="$(awk '
  function val(s) { sub(/^[^:]*:[ \t]*/, "", s); sub(/[ \t]+#.*$/, "", s); sub(/[ \t]+$/, "", s); return s }
  /^files:/ { infiles = 1 }
  infiles && /^  - source:/ {
    if (have) print src "\t" status "\t" gate "\t" review
    src = val($0); status = ""; gate = ""; review = ""; have = 1; next
  }
  infiles && /^    status:/ { status = val($0); next }
  infiles && /^    gate:/   { gate   = val($0); next }
  infiles && /^    review:/ { review = val($0); next }
  END { if (have) print src "\t" status "\t" gate "\t" review }
' "$TRACE")"

[ -z "$records" ] && { echo "check-trace-evidence: no file entries in $TRACE; nothing to check (skipping)."; exit 0; }

is_set() { [ -n "$1" ] && [ "$1" != "null" ] && [ "$1" != "[]" ]; }

fails=0; gated=0; queue=0
while IFS=$'\t' read -r src status gate review; do
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
  elif is_set "$gate" && ! is_set "$review"; then
    echo "  [queue] $src: gate passed, awaiting independent review (review: null)"
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
