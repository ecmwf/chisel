#!/usr/bin/env bash
#
# run-conformance.sh - run every tools/conformance/*.sh check in PARALLEL and aggregate.
#
# The conformance checks are independent and read-only, so wall-clock collapses from the SUM
# of the checks to the SLOWEST one. On the base fixtures the suite is already sub-second and
# this changes little; the win shows at PORT scale - a real port has hundreds of status
# fragments, a large SOURCE tree, and many anchors, so each check does real work and the
# integrate/seal gates (which re-run the whole suite) feel the serial sum.
#
# This lives at tools/ root, NOT in tools/conformance/, on purpose: the gates and CI glob
# `tools/conformance/*.sh`, so a runner inside that directory would recurse. Callers invoke it
# via the relative path within whatever working tree they are in (the main checkout or a merge
# worktree), and it resolves its root from its own location, so it always runs the checks that
# live alongside it. The serial form still works and stays the documented fallback:
#   for s in tools/conformance/*.sh; do bash "$s"; done
#
# Concurrency defaults to the CPU count; override with CONFORMANCE_JOBS=<n>.
#
# Exit-code contract:
#   0  every check GREEN
#   1  at least one check NON-GREEN (RED or UNRELIABLE) - its full output is printed
#   2  the runner itself could not run (no checks found)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CDIR="$ROOT/tools/conformance"
cd "$ROOT" || { echo "run-conformance: cannot enter repo root '$ROOT'" >&2; exit 2; }

JOBS="${CONFORMANCE_JOBS:-}"
[ -n "$JOBS" ] || JOBS="$( { command -v nproc >/dev/null 2>&1 && nproc; } || echo 4 )"

checks=()
for s in "$CDIR"/*.sh; do [ -e "$s" ] && checks+=("$s"); done
[ "${#checks[@]}" -gt 0 ] || { echo "run-conformance: no checks found in $CDIR" >&2; exit 2; }

tmp="$(mktemp -d)" || { echo "run-conformance: cannot make a temp dir" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# Launch each check in its own subshell, capturing combined output + exit code, throttled to
# $JOBS at a time (wait -n needs bash >= 4.3; if absent the throttle simply degrades to no cap,
# which is still correct - just more concurrent).
idx=0
for s in "${checks[@]}"; do
	idx=$((idx + 1))
	d="$tmp/$idx"; mkdir -p "$d"; printf '%s' "$s" >"$d/name"
	( bash "$s" >"$d/log" 2>&1; printf '%s' "$?" >"$d/rc" ) &
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || break; done
done
wait

fails=0
summary=()
for d in "$tmp"/*/; do
	name="$(cat "$d/name")"; base="$(basename "$name")"
	rc="$(cat "$d/rc" 2>/dev/null || echo 99)"
	case "$rc" in
		0) verdict="GREEN     " ;;
		2) verdict="UNRELIABLE"; fails=$((fails + 1)) ;;
		*) verdict="RED       "; fails=$((fails + 1)) ;;
	esac
	summary+=("$verdict $base (exit $rc)")
done
printf '%s\n' "${summary[@]}" | sort
echo

if [ "$fails" -gt 0 ]; then
	echo "== output of non-green checks =="
	for d in "$tmp"/*/; do
		rc="$(cat "$d/rc" 2>/dev/null || echo 99)"
		[ "$rc" = 0 ] && continue
		echo "--- $(basename "$(cat "$d/name")") (exit $rc) ---"
		cat "$d/log"
		echo
	done
	echo "run-conformance: $fails of ${#checks[@]} check(s) NOT green."
	exit 1
fi
echo "run-conformance: all ${#checks[@]} checks GREEN."
exit 0
