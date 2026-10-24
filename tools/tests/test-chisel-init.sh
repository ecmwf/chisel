#!/usr/bin/env bash
# chisel-init (mode new) must tell a fresh clone of the BASE - which it flips into a new instance -
# from an existing INSTANCE - whose setup it resumes. The base is recognized by repository identity,
# never by URL spelling: an HTTPS clone of an SSH-recorded base, or a clone of a renamed base under
# its former name, is still the base. Each case runs init in --dry-run against a throwaway repo, with
# a gh stub answering GitHub's rename redirects from a fixture (no network, nothing is changed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# gh stub: `gh repo view <owner/name> --json nameWithOwner -q .nameWithOwner` prints the canonical
# name listed for <owner/name> in $GH_STUB_MAP ("<slug> <canonical>" lines) and fails for anything
# unlisted; every other gh call fails, as an offline or unauthenticated gh would.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "repo view" ] && [ -s "${GH_STUB_MAP:-}" ]; then
	awk -v s="${3:-}" '$1 == s { print $2; found = 1 } END { exit !found }' "$GH_STUB_MAP"
	exit
fi
exit 1
SH
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" NO_COLOR=1

n=0
# expect <base|instance> <label> <recorded base pointer> <origin> <upstream or ''> <gh map or ''>
expect() {
	local want="$1" label="$2" pointer="$3" origin="$4" upstream="$5" ghmap="$6"
	local repo out rc got=unknown
	n=$((n + 1))
	repo="$TMP/r$n"
	mkdir -p "$repo/tools" "$repo/.opencode/skill/code-port"
	cp "$ROOT/tools/chisel-init.py" "$repo/tools/"
	: >"$repo/.opencode/skill/code-port/SKILL.md"
	printf '# the base this clone syncs from\n%s\n' "$pointer" >"$repo/tools/base-repo.txt"
	git -C "$repo" init -q
	git -C "$repo" remote add origin "$origin"
	[ -z "$upstream" ] || git -C "$repo" remote add upstream "$upstream"
	printf '%s\n' "$ghmap" >"$TMP/ghmap$n"
	# A base clone needs the new instance's name to flip; an instance resumes without one. Either
	# misreading therefore also exits non-zero, not just with the wrong marker.
	local args=(--mode new --dry-run --non-interactive --yes --skip-source --skip-models --skip-product)
	[ "$want" = instance ] || args+=(--new-repo me/port-foo)
	set +e
	out="$(cd "$repo" && GH_STUB_MAP="$TMP/ghmap$n" python3 tools/chisel-init.py "${args[@]}" 2>&1)"
	rc=$?
	set -e
	grep -q 'would run: bash tools/new-instance.sh me/port-foo' <<<"$out" && got=base
	grep -q 'already flipped to instance' <<<"$out" && got=instance
	if [ "$rc" -ne 0 ] || [ "$got" != "$want" ]; then
		printf 'not ok - %s (expected %s, got %s, exit %s)\n%s\n' "$label" "$want" "$got" "$rc" "$out" >&2
		exit 1
	fi
	# An instance inferred from the origin alone (no upstream remote) must say so, naming the
	# recorded base, so a stale tools/base-repo.txt is visible instead of silently resumed past.
	if [ "$want" = instance ] && [ -z "$upstream" ] \
		&& ! grep -q 'treating this clone as an existing instance' <<<"$out"; then
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
	$'acme/chisel acme/chisel\nme/port-foo me/port-foo'
expect instance "an instance stays an instance when gh cannot answer" \
	"$B_HTTPS" "git@github.com:me/port-foo.git" "" ""
expect instance "a flipped clone (upstream remote set) is an instance" \
	"$B_HTTPS" "git@github.com:me/port-foo.git" "$B_HTTPS" ""

printf '# test-chisel-init: all %d cases passed\n' "$n"
