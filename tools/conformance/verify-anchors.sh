#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

#
# verify-anchors.sh - the constant verifier of the TARGET code.
#
# Every comparable TARGET constant is compared BY VALUE with the SOURCE constant it renders:
# gfortran evaluates the SOURCE side, clang the TARGET side, bit for bit, in every precision build
# (regime) of port/conventions/anchors.yaml. A constant is bound to its SOURCE constant by its
# provenance anchor, checked against the pinned SOURCE, or, without one, by name (the naming rule,
# in the SOURCE files its file maps to: those its anchors name and those a port/TRACE.yaml row lists
# with it). The rules - anchor grammar, binding, verdicts - are those of the anchor-verifier corpus,
# tools/conformance/seeded-bugs/verify-anchors/README.md; the record is
# tools/conformance/seeded-bugs/verify-anchors.md.
#
# This wrapper resolves the product root and runs lib/anchor_driver.py over its TARGET files: every
# *.c / *.h file (any case, links to files included) under the product root, `tests/` and `.git`
# pruned, a link to a directory followed inside the product root and refused out of it
# (anchor_binding.target_files), or the files named on the command line.
#
# Anchor forms:
#   file           /* src: <path> */, /* src: <path> = <literal> */, /* src: <path> (module <NAME>) */
#                  - the SOURCE file (and module or literal) to bind by name in
#   constant       /* src: <path>:<line> = <literal-as-read> */
#   module header  /* src: <path>:<line> (module <NAME>) */
#   routine        /* src: <path> (subroutine|function|program <NAME>) */, or /* src: <path>:<line> */
#   runtime-helper /* runtime-helper: <TRAP> - <language contract> */  (declared helper files only)
# <path> is relative to the pinned SOURCE root (port/TRACE.yaml meta source_root). Anchors resolve
# against the in-repo import commit (meta source_commit), overridable by SOURCE_PIN_REF or --ref.
#
# Exit:
#   0  GREEN       every anchor holds and every constant bound to a SOURCE constant equals its
#                  value (run-time values are reported UNVERIFIED)
#   1  RED         a value mismatch or a broken anchor rule
#   2  UNRELIABLE  something could not be judged (a tool or parser missing, the pin unresolved,
#                  the file set incomplete, a file unreadable, a SOURCE file that does not parse
#                  or compile, a pairing the naming rule cannot decide) - never reported as a pass
# NOTEs - constants no SOURCE name matches - follow the result and never change it.

set -uo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/product-root.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WB="$(cd "$HERE/../.." && pwd)"

# Precedence: --target-dir > TARGET_DIR > PRODUCT_ROOT (set once by tools/run-conformance.sh) >
# port/product.yaml.
TARGET_DIR="${TARGET_DIR:-${PRODUCT_ROOT:-}}"
REF_ARGS=()

usage() {
	cat <<'USAGE'
Usage: verify-anchors.sh [--ref <git-ref>] [--target-dir <dir>] [files...]

  --ref <git-ref>      In-repo ref holding the pinned SOURCE.
                       Default: port/TRACE.yaml meta source_commit (the local import commit).
  --target-dir <dir>   Product root to scan for TARGET *.c / *.h. Default: the product checkout
                       (port/product.yaml), else target/.
  files...             Explicit TARGET files to check (instead of the scan).

Exit: 0 GREEN, 1 RED, 2 UNRELIABLE.
USAGE
}

EXPLICIT_FILES=()
while [[ $# -gt 0 ]]; do
	case "$1" in
	--ref)
		REF_ARGS=(--ref "${2:?--ref needs a value}")
		shift 2
		;;
	--target-dir)
		TARGET_DIR="${2:?--target-dir needs a value}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		EXPLICIT_FILES+=("$@")
		break
		;;
	-*)
		echo "verify-anchors: unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	*)
		EXPLICIT_FILES+=("$(cd "$(dirname "$1")" 2>/dev/null && pwd)/$(basename "$1")")
		shift
		;;
	esac
done

# ---- the product root and the TARGET file set ------------------------------------------------
TARGET_DIR="$(product_root_for_scan "$TARGET_DIR")"
_prc=$?
case "$_prc" in
2) echo "verify-anchors: $(pr_checkout_problem) (UNRELIABLE)." >&2; exit 2 ;;
3) exit 2 ;; # the wrong-tree diagnosis is already printed by product_root_for_scan
esac
FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
	FILES=(-- "${EXPLICIT_FILES[@]}")
else
	if [[ "$_prc" -eq 0 && ! -d "$TARGET_DIR" ]]; then
		echo "verify-anchors: the product is wired but its checkout '${TARGET_DIR}' is not present beside the workbench - clone it; refusing to skip (UNRELIABLE)." >&2
		exit 2
	fi
	if [[ "$_prc" -eq 0 ]]; then
		_unread="$(_pr_unreadable_msg "$TARGET_DIR")"
		[[ -n "$_unread" ]] && { echo "verify-anchors: ${_unread} (UNRELIABLE)." >&2; exit 2; }
	fi
	# An absent root was scanned completely - there is no TARGET code yet. A present root is scanned
	# by the driver (anchor_binding.target_files), which refuses a scan it could not complete.
	if [[ ! -e "$TARGET_DIR" ]]; then
		echo "verify-anchors: no TARGET source tree at '${TARGET_DIR}' yet - nothing to verify (skipping)."
		exit 0
	fi
	FILES=(--scan)
fi
for f in "${EXPLICIT_FILES[@]}"; do
	if [[ ! -f "$f" || ! -r "$f" ]]; then
		echo "verify-anchors: TARGET file '${f}' cannot be read - its anchors and coverage cannot be judged (UNRELIABLE)." >&2
		exit 2
	fi
done

# ---- the driver ----------------------------------------------------------------------------------
command -v python3 >/dev/null 2>&1 || {
	echo "verify-anchors: python3 not found - the verifier needs it, with libclang, fparser and PyYAML (UNRELIABLE)." >&2
	exit 2
}
# The driver runs as a child this shell waits for, so a TERM or INT sent here reaches it: it then
# stops UNRELIABLE and removes its scratch directory.
python3 "$HERE/lib/anchor_driver.py" --workbench "$WB" --product-root "$TARGET_DIR" "${REF_ARGS[@]}" "${FILES[@]}" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null' TERM INT
wait "$child"
rc=$?
while kill -0 "$child" 2>/dev/null; do
	wait "$child"
	rc=$?
done
trap - TERM INT
case "$rc" in
0 | 1 | 2) exit "$rc" ;;
*)
	echo "verify-anchors: the driver exited ${rc} - not a verdict (UNRELIABLE)." >&2
	exit 2
	;;
esac
