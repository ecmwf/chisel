#!/usr/bin/env bash
#
# check-source-import.sh - every file the SOURCE tracked upstream is tracked HERE.
#
# THE FAILURE THIS CATCHES. tools/import-source.sh copies a SOURCE tree and REMOVES its nested
# .git so the tree commits as files. That removal has a side effect: every imported file becomes
# UNTRACKED, and the SOURCE's own .gitignore - which upstream was harmless, because tracked files
# are immune to it - suddenly starts excluding real source. A pattern as ordinary as `build*`
# silently drops a routine named build<something>.f90. The subsequent `git add -A` exits 0 and the
# file is simply never committed.
#
# import-source.sh ALREADY detects this at import time and prints a warning plus a `git add -f`
# hint. That guard is correct but EPHEMERAL: it is one line of output to ONE session. The session
# that actually stages and commits the import is often a later one, and every session after that
# examines a repo whose shortfall is invisible. Meanwhile the provenance file records
# `tracked_files: <N>` FOREVER. So the evidence to detect the drop is committed and permanent, and
# nothing ever re-reads it. This check is that missing durable half: it re-derives the comparison
# on every conformance run, for the life of the project.
#
# Why it matters enough to be a check: the SOURCE is the specification (Prime Directive 1). A
# missing live file is not a cosmetic gap - it is a hole in the spec that the port is measured
# against. It is also invisible in the ordinary place you would look: the main working tree still
# holds the untracked file, so checks pass there, while every fresh clone and every worker
# WORKTREE lacks it and fails. That split - green in the main tree, red in every worktree - is the
# signature of this bug.
#
# WHAT IT CHECKS, per port/provenance/<name>.yaml:
#   - the provenance names a `path` that exists, and a `tracked_files` count
#   - the number of git-TRACKED files under that path equals `tracked_files`
# A shortfall lists the offending paths with the ignore rule responsible (git check-ignore -v), so
# the fix is immediate: `git add -f <paths>`. Once tracked, .gitignore no longer applies, so the
# repair is durable and this check stays green.
#
# It SKIPS cleanly when there is nothing to check (no provenance directory yet - Phase 0 has not
# imported a SOURCE), so it is safe from the first commit of a fresh instance.
#
# Exit-code contract:
#   0  GREEN       every imported SOURCE is fully tracked (or nothing imported yet)
#   1  RED         an imported SOURCE is missing files from git
#   2  UNRELIABLE  cannot run (no git / no python3 or PyYAML to read a provenance file / malformed
#                  provenance)

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
command -v git >/dev/null 2>&1 || { echo "check-source-import: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-source-import: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || { echo "check-source-import: cannot enter repo root" >&2; exit 2; }

PROV_DIR="${1:-port/provenance}"

if [ ! -d "$PROV_DIR" ]; then
	echo "check-source-import: no $PROV_DIR/ yet - no SOURCE imported. RESULT: GREEN (skip)"
	exit 0
fi

shopt -s nullglob
provs=("$PROV_DIR"/*.yaml)
shopt -u nullglob

if [ ${#provs[@]} -eq 0 ]; then
	echo "check-source-import: $PROV_DIR/ holds no provenance files. RESULT: GREEN (skip)"
	exit 0
fi

command -v python3 >/dev/null 2>&1 \
	|| { echo "check-source-import: python3 not found - cannot read $PROV_DIR/*.yaml (UNRELIABLE)" >&2; exit 2; }

# prov_field FILE KEY - the scalar KEY of a provenance file, read as YAML data by the shared strict
# reader, the way the Python tools read it (a line scan kept an inline comment in the value and took
# the first copy of a repeated key). Prints nothing for an absent or null key; returns 2 when the
# file cannot be read, including without PyYAML - UNRELIABLE, never a pass.
prov_field() {
	local v r
	v="$(python3 "$HERE/../coordination/yaml_get.py" "$1" "$2")"; r=$?
	case "$r" in
		0) printf '%s' "$v" ;;
		3) printf '' ;;
		*) return 2 ;;
	esac
}

rc=0
checked=0

for p in "${provs[@]}"; do
	if ! path="$(prov_field "$p" path)" || ! tracked_expected="$(prov_field "$p" tracked_files)"; then
		echo "check-source-import: $p cannot be read as YAML (see above)" >&2
		rc=2
		continue
	fi

	if [ -z "$path" ] || [ -z "$tracked_expected" ]; then
		echo "check-source-import: $p lacks 'path' or 'tracked_files'" >&2
		rc=2
		continue
	fi
	case "$tracked_expected" in
		''|*[!0-9]*)
			echo "check-source-import: $p has a non-numeric tracked_files '$tracked_expected'" >&2
			rc=2
			continue
			;;
	esac
	if [ ! -d "$path" ]; then
		echo "check-source-import: $p names path '$path' which does not exist" >&2
		rc=2
		continue
	fi

	actual="$(git ls-files -- "$path" | wc -l | tr -d ' ')"
	checked=$((checked + 1))

	if [ "$actual" -eq "$tracked_expected" ]; then
		echo "  OK  $path: $actual tracked = $tracked_expected upstream"
		continue
	fi

	[ "$rc" -eq 2 ] || rc=1
	if [ "$actual" -lt "$tracked_expected" ]; then
		missing=$((tracked_expected - actual))
		echo "  FAIL $path: $actual tracked, but $tracked_expected were tracked upstream ($missing MISSING)."
		echo "       These present-but-untracked files are being excluded:"
		# List files git refuses to track, and the exact rule doing it.
		find "$path" \( -type f -o -type l \) -print 2>/dev/null \
			| git check-ignore --stdin -v 2>/dev/null | sed 's/^/         /'
		echo "       The SOURCE is the specification; stage them faithfully with the force flag:"
		echo "         git add -f <the paths above>"
		echo "       (Once tracked, .gitignore no longer applies - the repair is permanent.)"
	else
		echo "  FAIL $path: $actual tracked, but only $tracked_expected were tracked upstream"
		echo "       (MORE files tracked here than upstream - the import carries files the pinned"
		echo "        commit did not have, so the tree no longer matches its provenance.)"
	fi
done

if [ "$rc" -eq 2 ]; then
	echo "RESULT: UNRELIABLE (exit 2) - provenance could not be read; the check did not run."
	exit 2
fi
if [ "$rc" -eq 1 ]; then
	echo "RESULT: RED (exit 1) - an imported SOURCE is not fully tracked; the specification is incomplete."
	exit 1
fi
echo "check-source-import: $checked imported SOURCE(s) fully tracked. RESULT: GREEN"
exit 0
