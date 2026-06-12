#!/usr/bin/env bash
# Conformance: no em-dashes anywhere in the repository (AGENTS.md hard rule).
# Vendored SOURCE text under source/ is excluded: it is read-only upstream code.
# Exit-code contract: 0 = clean, 1 = em-dash found, 2 = detector error.
set -euo pipefail
cd "$(dirname "$0")/../.."

EMDASH=$(printf '\xe2\x80\x94')

set +e
hits=$(grep -rn --binary-files=without-match \
  --exclude-dir=.git --exclude-dir=source --exclude-dir=node_modules \
  -e "$EMDASH" .)
status=$?
set -e

case $status in
  0) echo "FAIL: em-dash found:"; echo "$hits"; exit 1 ;;
  1) echo "OK: no em-dashes." ;;
  *) echo "ERROR: grep itself failed (exit $status); detector unreliable" >&2; exit 2 ;;
esac
