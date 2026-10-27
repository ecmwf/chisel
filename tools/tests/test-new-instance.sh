#!/usr/bin/env bash
# tools/new-instance.sh flips a fresh clone of the base into a port instance. Run by hand, it is only
# the first step of setting up a port, so it must send the user on to chisel-init (which imports the
# original code, creates the product repo and chooses the models) - never straight to a sprint, which
# would skip all of that. Run by chisel-init (CHISEL_INIT=1), it adds no next step of its own.
# Throwaway bare repositories stand in for GitHub; nothing leaves the machine.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/    /'; failures=$((failures + 1)); }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
# The base, as a bare repository holding this checkout's tree in one commit.
mkdir -p "$TMP/gh/ecmwf" "$TMP/gh/you" "$TMP/seed"
(cd "$ROOT" && git ls-files -z | tar --null -T - -cf -) | tar -xf - -C "$TMP/seed"
git -C "$TMP/seed" init -q -b main && git -C "$TMP/seed" add -A && git -C "$TMP/seed" commit -q -m base
git clone -q --bare "$TMP/seed" "$TMP/gh/ecmwf/chisel.git"

flip() { # flip NAME [ENV...]: clone the base as NAME, create you/NAME, run new-instance.sh
	local name="$1"
	shift
	git init -q --bare -b main "$TMP/gh/you/$name.git"
	git clone -q "file://$TMP/gh/ecmwf/chisel.git" "$TMP/work/$name"
	(cd "$TMP/work/$name" && env "$@" bash tools/new-instance.sh "file://$TMP/gh/you/$name.git" 2>&1)
}

mkdir -p "$TMP/work"
out="$(flip port-a CHISEL_INIT=)" || true
remotes="$(git -C "$TMP/work/port-a" remote -v)"
if grep -q "origin	file://$TMP/gh/you/port-a.git" <<<"$remotes" && grep -q "upstream	file://$TMP/gh/ecmwf/chisel.git" <<<"$remotes"; then
	ok "the clone is flipped: origin is the new repo, upstream the base"
else
	not_ok "the clone is flipped: origin is the new repo, upstream the base" "$remotes"
fi
if grep -q "Next: run uv run tools/chisel-init.py" <<<"$out" && ! grep -q "port-sprint-start" <<<"$out"; then
	ok "run by hand, it sends the user on to chisel-init, not to a sprint"
else
	not_ok "run by hand, it sends the user on to chisel-init, not to a sprint" "$out"
fi
out="$(flip port-b CHISEL_INIT=1)" || true
if ! grep -q "^Next:" <<<"$out"; then
	ok "run by chisel-init, it adds no next step of its own"
else
	not_ok "run by chisel-init, it adds no next step of its own" "$out"
fi
# A bare local path is neither a git URL nor a GitHub owner/name: refused before anything changes.
git clone -q "file://$TMP/gh/ecmwf/chisel.git" "$TMP/work/port-c"
rc=0
out="$(cd "$TMP/work/port-c" && bash tools/new-instance.sh "$TMP/gh/you/port-c.git" 2>&1)" || rc=$?
if [ "$rc" -eq 2 ] && grep -q "file://" <<<"$out" \
	&& [ "$(git -C "$TMP/work/port-c" remote get-url origin)" = "file://$TMP/gh/ecmwf/chisel.git" ] \
	&& ! git -C "$TMP/work/port-c" remote get-url upstream >/dev/null 2>&1; then
	ok "a bare local path is refused, with the file:// form, before anything changes"
else
	not_ok "a bare local path is refused, with the file:// form, before anything changes" "exit $rc: $out"
fi

if [ "$failures" -ne 0 ]; then
	echo "# test-new-instance: $failures failure(s)" >&2
	exit 1
fi
echo "# test-new-instance: all assertions passed"
