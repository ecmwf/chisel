#!/usr/bin/env bash
#
# run-conformance.sh - run every tools/conformance/*.sh check in PARALLEL and aggregate.
#
# The conformance checks are independent and read-only, so wall-clock collapses from the SUM
# of the checks to the SLOWEST one. On the base fixtures the suite is already sub-second and
# this changes little; the win shows at PORT scale - a real port has hundreds of status
# fragments, a large SOURCE tree, and many anchors, so each check does real work and the
# integrate/seal scripts (which re-run the whole suite) feel the serial sum.
#
# This lives at tools/ root, NOT in tools/conformance/, on purpose: the guarded land/seal scripts and CI
# `tools/conformance/*.sh`, so a runner inside that directory would recurse. Callers invoke it
# via the relative path within whatever working tree they are in (the main checkout or a merge
# worktree), and it resolves its root from its own location, so it always runs the checks that
# live alongside it. The serial form still works and stays the documented fallback:
#   for s in tools/conformance/*.sh; do bash "$s"; done
#
# Concurrency defaults to the CPU count; override with CONFORMANCE_JOBS=<n>.
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
# CONFORMANCE_SKIP + --allow-skip - a caller-named exclusion list, for a land script whose own
# scope makes some checks irrelevant (e.g. a preview land that should not be rolled back by
# workbench bookkeeping). CONFORMANCE_SKIP is a whitespace- or comma-separated list of check FILE
# NAMES exactly as the summary prints them (`check-claims.sh`; a project check by its own file
# name). It takes effect ONLY when the invocation itself passes --allow-skip: an environment
# variable is inherited by every child process, so without that opt-in a stray or stale export
# would silently weaken every guarded land and seal script that runs this suite (and those
# discard its output). Without --allow-skip a set CONFORMANCE_SKIP is reported on stderr and
# IGNORED - every check runs, so the variable alone can never remove a check. With --allow-skip
# the runner:
#   - refuses (exit 2) a name that matches no check, or more than one, so a typo or a renamed check
#     cannot quietly leave the list meaning something else, and refuses a list that leaves nothing
#     to run;
#   - prints the list before running and a `SKIP` line per excluded check in the summary, and
#     counts the skips in its final line - an exclusion is never silent;
#   - does not run the excluded checks; every other check runs and decides the exit code as usual.
# Names only - no patterns. Unset or empty means no exclusion. The caller that passes
# --allow-skip owns the claim that the excluded checks do not bear on what it is landing; the
# guarded mainline land and seal scripts never pass it.
#
# Exit-code contract:
#   0  every check that ran is GREEN
#   1  at least one check NON-GREEN (RED or UNRELIABLE) - its full output is printed
#   2  the runner itself could not run (no checks found, a bad CONFORMANCE_SKIP under --allow-skip)
set -uo pipefail

# Captured BEFORE anything else (arg parsing, the `cd "$ROOT"` below) - the directory THIS RUNNER
# was actually invoked from. Exported so every check it launches as a child process (bash "$s")
# inherits the SAME invocation identity lib/product-root.sh's `_PR_LOAD_CWD` needs for the
# wrong-tree check, rather than each independently re-deriving it from its OWN cwd at spawn time -
# which would be this runner's post-`cd "$ROOT"` location (its OWN script's directory), not the
# caller's, the moment run-conformance.sh is invoked via a path outside the caller's cwd (a
# cross-worktree absolute path, or any wrapper that does not `cd` into the target tree first).
export _PR_LOAD_CWD="$(pwd -P 2>/dev/null || pwd)"

# --product-root <dir> - explicit, top-of-precedence override (see the header comment).
# --allow-skip - this invocation honors CONFORMANCE_SKIP (see the header comment). Any other
# argument is rejected (usage error, exit 2) rather than silently ignored.
PRODUCT_ROOT_FLAG=""
ALLOW_SKIP=0
while [ $# -gt 0 ]; do
	case "$1" in
	--product-root)
		[ $# -ge 2 ] || { echo "run-conformance: --product-root needs a value" >&2; exit 2; }
		PRODUCT_ROOT_FLAG="$2"; shift 2 ;;
	--product-root=*)
		PRODUCT_ROOT_FLAG="${1#*=}"; shift ;;
	--allow-skip)
		ALLOW_SKIP=1; shift ;;
	-h | --help)
		echo "Usage: run-conformance.sh [--product-root <dir>] [--allow-skip]"
		echo "  --product-root <dir>  Explicit PRODUCT tree, resolved once and passed to every check"
		echo "                        (precedence: this flag > a pre-set PRODUCT_ROOT env > port/product.yaml)."
		echo "  --allow-skip          Honor CONFORMANCE_SKIP (exact check file names to exclude); without"
		echo "                        this flag the variable is reported and ignored, and every check runs."
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

# CONFORMANCE_SKIP (see the header): only under --allow-skip; resolve every name to exactly one
# check before running any. skip_reason is keyed by the check's PATH, so two checks sharing a file
# name never skip together.
declare -A skip_reason=()
if [ -n "${CONFORMANCE_SKIP:-}" ] && [ "$ALLOW_SKIP" != 1 ]; then
	echo "run-conformance: CONFORMANCE_SKIP is set ('$CONFORMANCE_SKIP') but this invocation did not pass --allow-skip - IGNORING it; every check runs." >&2
	echo >&2
elif [ -n "${CONFORMANCE_SKIP:-}" ]; then
	IFS=$' \t\n,' read -r -a _skip_names <<<"$CONFORMANCE_SKIP"
	for _sk in ${_skip_names[@]+"${_skip_names[@]}"}; do
		_hits=0; _hit=""
		for s in "${checks[@]}"; do
			[ "$(basename "$s")" = "$_sk" ] && { _hits=$((_hits + 1)); _hit="$s"; }
		done
		if [ "$_hits" -ne 1 ]; then
			echo "run-conformance: CONFORMANCE_SKIP names '$_sk', which matches $_hits checks (it must name exactly one check file, e.g. check-claims.sh) - refusing to run." >&2
			exit 2
		fi
		skip_reason["$_hit"]="excluded by CONFORMANCE_SKIP"
	done
	if [ "${#skip_reason[@]}" -gt 0 ]; then
		echo "run-conformance: CONFORMANCE_SKIP excludes ${#skip_reason[@]} check(s): $(for _sk in "${!skip_reason[@]}"; do basename "$_sk"; done | sort | paste -sd ' ' -)"
		echo
	fi
	unset _skip_names _sk _hits _hit
fi
[ "${#skip_reason[@]}" -lt "${#checks[@]}" ] \
	|| { echo "run-conformance: every check is excluded by CONFORMANCE_SKIP - nothing would run." >&2; exit 2; }

tmp="$(mktemp -d)" || { echo "run-conformance: cannot make a temp dir" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# Launch each check in its own subshell, capturing combined output + exit code, throttled to
# $JOBS at a time (wait -n needs bash >= 4.3; if absent the throttle simply degrades to no cap,
# which is still correct - just more concurrent). An excluded check is recorded, not launched.
idx=0
for s in "${checks[@]}"; do
	idx=$((idx + 1))
	d="$tmp/$idx"; mkdir -p "$d"; printf '%s' "$s" >"$d/name"
	if [ -n "${skip_reason[$s]:-}" ]; then
		printf '%s' "${skip_reason[$s]}" >"$d/skipped"
		continue
	fi
	( bash "$s" >"$d/log" 2>&1; printf '%s' "$?" >"$d/rc" ) &
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n 2>/dev/null || break; done
done
wait

fails=0
skips=0
summary=()
for d in "$tmp"/*/; do
	name="$(cat "$d/name")"; base="$(basename "$name")"
	if [ -e "$d/skipped" ]; then
		skips=$((skips + 1))
		summary+=("SKIP       $base ($(cat "$d/skipped"))")
		continue
	fi
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
		[ -e "$d/skipped" ] && continue
		rc="$(cat "$d/rc" 2>/dev/null || echo 99)"
		[ "$rc" = 0 ] && continue
		echo "--- $(basename "$(cat "$d/name")") (exit $rc) ---"
		cat "$d/log"
		echo
	done
	echo "run-conformance: $fails of $(( ${#checks[@]} - skips )) check(s) run NOT green$([ "$skips" -gt 0 ] && echo "; $skips skipped (see the SKIP lines)")."
	exit 1
fi
if [ "$skips" -gt 0 ]; then
	echo "run-conformance: all $(( ${#checks[@]} - skips )) check(s) run GREEN; $skips skipped (see the SKIP lines)."
	exit 0
fi
echo "run-conformance: all ${#checks[@]} checks GREEN."
exit 0
