#!/usr/bin/env bash
#
# run-conformance.sh - run every tools/conformance/*.sh and tools/conformance/project/*.sh check
# in PARALLEL and aggregate.
#
# The conformance checks are independent and read-only, so wall-clock collapses from the SUM
# of the checks to the SLOWEST one. On the base fixtures the suite is already sub-second and
# this changes little; the win shows at PORT scale - a real port has hundreds of status
# fragments, a large SOURCE tree, and many anchors, so each check does real work and the
# integrate/seal scripts (which re-run the whole suite) feel the serial sum.
#
# This lives at tools/ root, NOT in tools/conformance/, on purpose: it globs
# `tools/conformance/*.sh`, so a runner inside that directory would run itself. Callers invoke it
# via the relative path within whatever working tree they are in (the main checkout or a merge
# worktree), and it resolves its root from its own location, so it always runs the checks that
# live alongside it.
#
# Concurrency defaults to the CPU count; override with CONFORMANCE_JOBS=<n>. The serial fallback
# is this runner with one job, `CONFORMANCE_JOBS=1 bash tools/run-conformance.sh`: same product-root
# resolution and project checks, one check at a time. A hand-written loop over
# tools/conformance/*.sh is NOT equivalent - it misses the project checks and the single product-root
# resolution below.
#
# PRODUCT_ROOT resolution - ONE place, not one guess per check. Every product-facing check
# (tools/conformance/lib/product-root.sh's `product_root_for_scan`, sourced by each) independently
# re-derived "where is the product" before this existed - harmless while they agreed, but they
# disagreed on how an OVERRIDE reaches them (some an env var, some a flag, some only the
# port/product.yaml-configured path with no override at all), and NONE of them could tell a
# genuinely-empty product apart from "I am resolving the wrong tree" (the defect that mattered: a per-piece worker worktree,
# .worktrees/<id>, has its OWN product worktree, .worktrees/product-<id>, that the
# port/product.yaml-configured path - anchored at the MAIN workbench, by design, for the ONE
# shared/integrated product - never sees; every check "skipped, nothing to verify" GREEN having
# examined zero of the worker's real translated files). This runner now resolves PRODUCT_ROOT
# ONCE, up front, and EXPORTS it so every child check inherits the SAME answer (bash subshells
# inherit exported vars automatically - no per-check plumbing needed):
#   precedence: --product-root (this runner's own flag) > a PRODUCT_ROOT already in the caller's
#   environment (e.g. a worker's own `export PRODUCT_ROOT=.../product-<id>`, exactly what
#   tools/coordination/assert_isolated.sh --export hands a worker) > port/product.yaml.
# The FAIL-CLOSED outcomes (2 checkout unset/placeholder; 3 wrong-tree - see product-root.sh)
# are deliberately NOT captured/exported here: PRODUCT_ROOT is left unset in that case so every
# check independently calls the SAME `product_root_for_scan` and reaches the SAME diagnosis on its
# own - propagating a "known-broken" sentinel through an env var would be a second, divergeable
# place to get that wrong, exactly what this fix removes. The 10 (not-wired, target/ fallback)
# outcome is ALSO left unexported, on purpose: exporting a concrete path there would make every
# check treat it as an EXPLICIT override (its missing-is-UNRELIABLE branch), destroying the base
# methodology repo's legitimate clean skip when no TARGET code exists anywhere yet.
#
# `product_root_for_scan`, NOT `default_product_root`, is what BOTH this runner and every check
# call: this runner exists to serve the CHECKS' scans (never a coordination/MODE decision), so it
# asks the identical scan-validated question they do, including the wrong-tree test - see that
# function's own header (lib/product-root.sh) for why the two questions are split.
#
# THE `NOTICE:` CONVENTION (project-agnostic - any check, in any port, may use this): a check that
# reaches a determinate, non-blocking finding it still wants visible in CI - e.g. an ADVISORY-style
# check whose verdict is deliberately never allowed to fail the aggregate check (a downstream
# optimizer's discretionary choice, not a fact fixed by the committed inputs) - may print a line
# starting with the literal `NOTICE:` alongside its own exit-0 result. This runner scans every
# check's captured output for that prefix, REGARDLESS of the check's own exit code, and surfaces
# the FULL log of any check that emitted one - otherwise a GREEN check's output is never printed at
# all (see the exit-code contract below), which would make an advisory finding disappear from the
# actual CI log the instant it stopped blocking. A check with no `NOTICE:` line is completely
# unaffected - this is an opt-in addition, not a change to the GREEN/RED/UNRELIABLE contract below.
#
# Exit-code contract:
#   0  every check GREEN
#   1  at least one check NON-GREEN (RED or UNRELIABLE) - its full output is printed
#   2  the runner itself could not run (no checks found)
set -uo pipefail

# Captured BEFORE anything else (arg parsing, the `cd "$ROOT"` below) - the directory THIS RUNNER
# was actually invoked from. Exported so every check it launches as a child process (bash "$s")
# inherits the SAME invocation identity lib/product-root.sh's `_PR_LOAD_CWD` needs for the
# wrong-tree check, rather than each independently re-deriving it from its OWN cwd at spawn time -
# which would be this runner's post-`cd "$ROOT"` location (its OWN script's directory), not the
# caller's, the moment run-conformance.sh is invoked via a path outside the caller's cwd (a
# cross-worktree absolute path, or any wrapper that does not `cd` into the target tree first).
export _PR_LOAD_CWD="$(pwd -P 2>/dev/null || pwd)"

# --product-root <dir> - explicit, top-of-precedence override (see the header comment). Any
# other argument is rejected (usage error, exit 2) rather than silently ignored.
PRODUCT_ROOT_FLAG=""
while [ $# -gt 0 ]; do
	case "$1" in
	--product-root)
		[ $# -ge 2 ] || { echo "run-conformance: --product-root needs a value" >&2; exit 2; }
		PRODUCT_ROOT_FLAG="$2"; shift 2 ;;
	--product-root=*)
		PRODUCT_ROOT_FLAG="${1#*=}"; shift ;;
	-h | --help)
		echo "Usage: run-conformance.sh [--product-root <dir>]"
		echo "  --product-root <dir>  Explicit PRODUCT tree, resolved once and passed to every check"
		echo "                        (precedence: this flag > a pre-set PRODUCT_ROOT env > port/product.yaml)."
		exit 0 ;;
	*)
		echo "run-conformance: unknown option: $1" >&2
		exit 2 ;;
	esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
CDIR="$ROOT/tools/conformance"
cd "$ROOT" || { echo "run-conformance: cannot enter repo root '$ROOT'" >&2; exit 2; }

# Resolve PRODUCT_ROOT once (see the header comment for the full precedence/fail-closed reasoning).
if [ -n "$PRODUCT_ROOT_FLAG" ]; then
	case "$PRODUCT_ROOT_FLAG" in
	/*) export PRODUCT_ROOT="$PRODUCT_ROOT_FLAG" ;;
	*)  export PRODUCT_ROOT="$ROOT/$PRODUCT_ROOT_FLAG" ;;
	esac
	echo "run-conformance: PRODUCT_ROOT explicitly set to '$PRODUCT_ROOT' (--product-root) - every check will honor it."
elif [ -n "${PRODUCT_ROOT:-}" ]; then
	echo "run-conformance: PRODUCT_ROOT already set in the environment to '$PRODUCT_ROOT' - honored as-is (already exported to every check)."
else
	# shellcheck source=tools/conformance/lib/product-root.sh
	. "$CDIR/lib/product-root.sh"
	# product_root_for_scan, NOT default_product_root: this runner exists to serve the CHECKS'
	# scans, so it asks the same scan-validated question they do (including the wrong-tree test)
	# - default_product_root is the coordination/MODE-detection primitive (assert_isolated.sh,
	# provision_worker.sh, integrate_*.sh), a different question this runner does not need to ask.
	_pr_resolved="$(product_root_for_scan)"; _pr_rc=$?
	case "$_pr_rc" in
	0)
		export PRODUCT_ROOT="$_pr_resolved"
		echo "run-conformance: PRODUCT_ROOT resolved once to '$PRODUCT_ROOT' (port/product.yaml) - passed to every check."
		;;
	10)
		echo "run-conformance: no product wired (port/product.yaml absent) - product-facing checks fall back to their own target/ default and skip cleanly if it is absent."
		;;
	2 | 3)
		echo "run-conformance: PRODUCT_ROOT resolution is UNRELIABLE this run (see the per-check output below) - leaving it unset so every product-facing check independently re-derives and reports the SAME diagnosis, rather than guessing."
		;;
	esac
	unset _pr_resolved _pr_rc
fi
echo

JOBS="${CONFORMANCE_JOBS:-}"
[ -n "$JOBS" ] || JOBS="$( { command -v nproc >/dev/null 2>&1 && nproc; } || echo 4 )"

checks=()
for s in "$CDIR"/*.sh; do [ -e "$s" ] && checks+=("$s"); done
# A port's OWN program-specific checks live under conformance/project/ (carved out as
# project layer in .gitattributes). Run them too, so a port's checks are not orphaned
# out of CI; the directory may be absent on a fresh base clone.
for s in "$CDIR"/project/*.sh; do [ -e "$s" ] && checks+=("$s"); done
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

# The `NOTICE:` convention (see header comment): surface a GREEN check's full log anyway if it
# opted in, so an advisory-style finding is never silently dropped from the CI log the instant it
# stops blocking. Scoped to rc=0 checks only - a non-green check's full log is already printed
# unconditionally below, so this never double-prints the same log.
notice_found=0
for d in "$tmp"/*/; do
	rc="$(cat "$d/rc" 2>/dev/null || echo 99)"
	[ "$rc" = 0 ] || continue
	grep -q '^NOTICE:' "$d/log" 2>/dev/null || continue
	if [ "$notice_found" -eq 0 ]; then
		echo "== notices from otherwise-green checks (non-blocking) =="
		notice_found=1
	fi
	echo "--- $(basename "$(cat "$d/name")") (exit $rc) ---"
	cat "$d/log"
	echo
done

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
