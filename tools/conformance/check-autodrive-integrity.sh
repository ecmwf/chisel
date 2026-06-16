#!/usr/bin/env bash
#
# check-autodrive-integrity.sh - orchestrator auto-mode obeys its own trust rules.
#
# Without this gate, auto-mode's trust properties (references/auto-mode.md) are only PROSE
# instructions to an LLM agent: nothing machine-verifies that the autonomy config is well-formed,
# that the charter-bot is a DISTINCT registered identity from every author/reviewer, or that a run
# ledger never drove past a red conformance check. This wrapper over
# tools/coordination/check_autodrive_integrity.py makes the machine-checkable ones machine-checked:
#   CONFIG    port/autodrive.yaml is well-formed (level, scope, budgets; L2/L3 need a positive
#             wave budget + a wall-clock/cost budget; L3 needs a charter_bot);
#   IDENTITY  for L2/L3 the contributor registry exists and the charter-bot is a DIFFERENT human
#             from every fragment author/reviewer (a bot that signs attestations never authored);
#   LEDGER    every docs/evidence/autodrive/<run>/ledger.yaml is structured and obeys the
#             fail-closed invariant - a non-green conformance_after may appear only on the LAST
#             decision of a HALTED run, never mid-run (auto-mode must never drive past a violation).
#
# Absent port/autodrive.yaml -> auto-mode is not configured (L0); it skips.
#
# Exit-code contract:
#   0  GREEN       config, charter-bot identity, and every run ledger verify (or auto-mode is off)
#   1  RED         a config/identity/ledger violation (incl. a run that drove past a red check)
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / git)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-autodrive-integrity: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-autodrive-integrity: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-autodrive-integrity: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/check_autodrive_integrity.py" "$@"
