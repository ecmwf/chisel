#!/usr/bin/env bash
# Conformance: no em-dashes anywhere in the repository (AGENTS.md hard rule).
# Mechanized so the rule does not depend on being remembered.
set -euo pipefail
cd "$(dirname "$0")/../.."

if hits=$(grep -rn --binary-files=without-match -- $'\u2014' . --exclude-dir=.git 2>/dev/null); then
  echo "FAIL: em-dash found:"
  echo "$hits"
  exit 1
fi
echo "OK: no em-dashes."
