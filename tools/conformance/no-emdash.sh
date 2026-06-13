#!/usr/bin/env bash
# Conformance: no em-dashes anywhere in the repository (AGENTS.md hard rule).
# Vendored SOURCE text under source/ is excluded: it is read-only upstream code.
# Files listed in no-emdash-allow.txt (one path per line, comments with #) are
# exempt: TARGET string literals ported verbatim from the SOURCE are program
# output and must stay byte-identical; each entry carries its justification.
# Exit-code contract: 0 = clean, 1 = em-dash found, 2 = detector error.
set -euo pipefail
cd "$(dirname "$0")/../.."

EMDASH=$(printf '\xe2\x80\x94')
ALLOW="tools/conformance/no-emdash-allow.txt"

set +e
hits=$(grep -rn --binary-files=without-match \
  --exclude-dir=.git --exclude-dir=source --exclude-dir=node_modules \
  -e "$EMDASH" .)
status=$?
set -e

if [ "$status" -eq 0 ] && [ -f "$ALLOW" ]; then
  set +e
  hits=$(echo "$hits" | grep -v -F -f <(grep -v '^#' "$ALLOW" | grep -v '^$' | sed 's|^|./|;s|$|:|'))
  [ -z "$hits" ] && status=1
  set -e
fi

case $status in
  0) echo "FAIL: em-dash found:"; echo "$hits"; exit 1 ;;
  1) echo "OK: no em-dashes." ;;
  *) echo "ERROR: grep itself failed (exit $status); detector unreliable" >&2; exit 2 ;;
esac
