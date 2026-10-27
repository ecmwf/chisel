#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# chisel-init (mode new) must tell a fresh clone of the BASE - which it flips into a new instance -
# from an existing INSTANCE - whose setup it resumes. The base is recognized by repository identity,
# never by URL spelling: an HTTPS clone of an SSH-recorded base, or a clone of a renamed base under
# its former name, is still the base. A clone whose origin is not the base is an instance only when it
# holds a port's own state; a GitHub fork of the base without one is a copy of the base; anything
# else (a mirror) needs --new-repo to be set up as a new port, and without it init stops rather than
# guess. Each case runs init in --dry-run against a throwaway repo, with a gh stub answering GitHub's
# rename redirects and fork parents from fixtures (no network, nothing is changed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# gh stub: `gh repo view <owner/name> --json isFork,parent ...` prints the parent listed for
# <owner/name> in $GH_STUB_FORKS ("<slug> <parent>" lines), or nothing; any other `gh repo view
# <owner/name>` prints the canonical name listed in $GH_STUB_MAP ("<slug> <canonical>" lines) and
# fails for anything unlisted; every other gh call fails, as an offline or unauthenticated gh would.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "repo view" ] && [ "${5:-}" = "isFork,parent" ]; then
	[ -s "${GH_STUB_FORKS:-}" ] && awk -v s="${3:-}" '$1 == s { print $2 }' "$GH_STUB_FORKS"
	exit 0
fi
if [ "${1:-} ${2:-}" = "repo view" ] && [ -s "${GH_STUB_MAP:-}" ]; then
	awk -v s="${3:-}" '$1 == s { print $2; found = 1 } END { exit !found }' "$GH_STUB_MAP"
	exit
fi
exit 1
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" NO_COLOR=1

n=0
# run_init <recorded base pointer> <origin> <upstream or ''> <gh map or ''> <forks or ''> <port|''> [args]
# sets $out and $rc
run_init() {
	local pointer="$1" origin="$2" upstream="$3" ghmap="$4" forks="$5" state="$6" repo
	shift 6
	n=$((n + 1))
	repo="$TMP/r$n"
	mkdir -p "$repo/tools" "$repo/.opencode/skills/code-port" "$repo/port"
	cp "$ROOT/tools/chisel-init.py" "$repo/tools/"
	: >"$repo/.opencode/skills/code-port/SKILL.md"
	printf '# the base this clone syncs from\n%s\n' "$pointer" >"$repo/tools/base-repo.txt"
	[ "$state" != port ] || printf 'repo: "git@github.com:me/foo-product.git"\n' >"$repo/port/product.yaml"
	git -C "$repo" init -q
	git -C "$repo" remote add origin "$origin"
	[ -z "$upstream" ] || git -C "$repo" remote add upstream "$upstream"
	printf '%s\n' "$ghmap" >"$TMP/ghmap$n"
	printf '%s\n' "$forks" >"$TMP/forks$n"
	set +e
	out="$(cd "$repo" && GH_STUB_MAP="$TMP/ghmap$n" GH_STUB_FORKS="$TMP/forks$n" python3 tools/chisel-init.py \
		--mode new --dry-run --non-interactive --yes --skip-source --skip-models --skip-product "$@" 2>&1)"
	rc=$?
	set -e
}

# expect <base|instance> <label> <pointer> <origin> <upstream or ''> <gh map or ''> [forks] [port]
expect() {
	local want="$1" label="$2" pointer="$3" origin="$4" upstream="$5" ghmap="$6" forks="${7:-}" state="${8:-}"
	local got=unknown args=()
	# A base clone needs the new instance's name to flip; an instance resumes without one. Either
	# misreading therefore also exits non-zero, not just with the wrong marker.
	[ "$want" = instance ] || args+=(--new-repo me/port-foo)
	run_init "$pointer" "$origin" "$upstream" "$ghmap" "$forks" "$state" "${args[@]}"
	grep -q 'would run: bash tools/new-instance.sh me/port-foo' <<<"$out" && got=base
	grep -q 'already your workbench' <<<"$out" && got=instance
	if [ "$rc" -ne 0 ] || [ "$got" != "$want" ]; then
		printf 'not ok - %s (expected %s, got %s, exit %s)\n%s\n' "$label" "$want" "$got" "$rc" "$out" >&2
		exit 1
	fi
	# An instance inferred from the origin alone (no upstream remote) must say so, naming the
	# recorded base, so a stale tools/base-repo.txt is visible instead of silently resumed past.
	if [ "$want" = instance ] && [ -z "$upstream" ] \
		&& ! grep -q "treating this clone as a port's workbench" <<<"$out"; then
		printf 'not ok - %s (no warning that the instance was inferred from origin)\n%s\n' "$label" "$out" >&2
		exit 1
	fi
	printf 'ok - %s\n' "$label"
}

B_SSH=git@github.com:acme/chisel.git
B_HTTPS=https://github.com/acme/chisel.git

expect base "HTTPS clone of an SSH-recorded base is the base" \
	"$B_SSH" "$B_HTTPS" "" ""
expect base "SSH clone of an HTTPS-recorded base is the base (case and .git ignored)" \
	"$B_HTTPS" "git@github.com:Acme/Chisel" "" ""
expect base "a clone whose origin is the recorded base verbatim is the base" \
	"$B_HTTPS" "$B_HTTPS" "" ""
expect base "a non-GitHub base is recognized across SSH and HTTPS too" \
	"https://git.example.org/team/chisel.git" "git@git.example.org:team/chisel.git" "" ""
expect base "a clone made under the base's former name is the base (GitHub redirect)" \
	"$B_HTTPS" "git@github.com:acme/old-name.git" "" \
	$'acme/old-name acme/chisel\nacme/chisel acme/chisel'
expect base "a pointer still naming the base's former home finds the base" \
	"git@github.com:someone/old-name.git" "$B_HTTPS" "" \
	$'someone/old-name acme/chisel\nacme/chisel acme/chisel'
expect instance "a fresh clone of an instance is an instance" \
	"$B_HTTPS" "git@github.com:me/port-foo.git" "" \
	$'acme/chisel acme/chisel\nme/port-foo me/port-foo' "" port
expect instance "an instance stays an instance when gh cannot answer" \
	"$B_HTTPS" "git@github.com:me/port-foo.git" "" "" "" port
expect instance "a flipped clone (upstream remote set) is an instance" \
	"$B_HTTPS" "git@github.com:me/port-foo.git" "$B_HTTPS" ""
expect instance "a workbench made as a fork is still an instance once it holds a port" \
	"$B_HTTPS" "git@github.com:me/port-foo.git" "" \
	$'acme/chisel acme/chisel\nme/port-foo me/port-foo' "me/port-foo acme/chisel" port

FORK_MAP=$'acme/chisel acme/chisel\nme/chisel me/chisel'
run_init "$B_HTTPS" "git@github.com:me/chisel.git" "" "$FORK_MAP" "me/chisel acme/chisel" ""
if grep -q 'is a fork of Chisel' <<<"$out" && ! grep -q 'cannot tell what this clone is' <<<"$out" \
	&& ! grep -q 'already your workbench' <<<"$out"; then
	printf 'ok - a clone of a fork of the base is a copy of the base\n'
else
	printf 'not ok - a clone of a fork of the base is a copy of the base (exit %s)\n%s\n' "$rc" "$out" >&2
	exit 1
fi
run_init "$B_HTTPS" "/srv/mirrors/chisel.git" "" "" "" ""
if [ "$rc" -ne 0 ] && grep -q 'cannot tell what this clone is' <<<"$out" && grep -q -- '--new-repo' <<<"$out" \
	&& ! grep -q 'already your workbench' <<<"$out"; then
	printf 'ok - a mirror of the base without --new-repo stops and says how to go on\n'
else
	printf 'not ok - a mirror of the base without --new-repo stops and says how to go on (exit %s)\n%s\n' "$rc" "$out" >&2
	exit 1
fi
expect base "a mirror of the base with --new-repo is a copy of the base" \
	"$B_HTTPS" "/srv/mirrors/chisel.git" "" ""

run_init "$B_HTTPS" "$B_HTTPS" "" "" "" "" --new-repo /srv/repos/port-foo.git
if [ "$rc" -ne 0 ] && grep -q "is not a repo" <<<"$out" && grep -q "file://" <<<"$out" \
	&& ! grep -q 'would run: bash tools/new-instance.sh' <<<"$out"; then
	printf 'ok - a bare local path for the new repo is refused, with the file:// form\n'
else
	printf 'not ok - a bare local path for the new repo is refused, with the file:// form (exit %s)\n%s\n' "$rc" "$out" >&2
	exit 1
fi

printf '# test-chisel-init: all %d cases passed\n' "$n"
