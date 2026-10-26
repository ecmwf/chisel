#!/usr/bin/env bash
# Tools that read a path list from git must read it NUL-separated (-z). The line form C-quotes a path
# holding a non-ASCII byte, a double quote or a newline ("src/\303\251.f90"), and the quoted string
# matches no real name:
#   - check_live_tracked.py reads `git ls-files`: a tracked SOURCE file with such a name read as
#     untracked (a false RED);
#   - check_claims.py reads `git diff --name-only` for a branch diff: a change under an owned surface
#     with such a name matched no owned path, so a claim with a wide write surface passed it (a false
#     GREEN);
#   - check_claims.py also lists both sides of a move (--no-renames): with rename detection only the
#     new path showed, so a branch could move a file out of an owned surface into its own;
#   - check-references.sh reads `git ls-files` for its scan set: a doc with such a name matched no
#     filter and was never scanned, so its dangling citation passed (a false GREEN).
# Each case drives the real tool on a throwaway repo; with the line form restored they go RED.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
	GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# KEEP_GOING=1 reports every failing case instead of stopping at the first (for a red demonstration).
failed=0
pass() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; [ -n "${KEEP_GOING:-}" ] || exit 1; failed=$((failed + 1)); }
# expect <exit-code> <label> <dir> <command...>; EXPECT_OUT, if set, must appear in the output
expect() {
	local want="$1" label="$2" dir="$3" out rc
	shift 3
	set +e; out="$(cd "$dir" && "$@" 2>&1)"; rc=$?; set -e
	if [ "$rc" != "$want" ]; then
		bad "$label (expected exit $want, got $rc)"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	elif [ -n "${EXPECT_OUT:-}" ] && ! grep -qF -- "$EXPECT_OUT" <<<"$out"; then
		bad "$label (exit $rc as expected, but the output lacks '$EXPECT_OUT')"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	else
		pass "$label"
	fi
}

# ---- check_live_tracked.py: a tracked file is tracked, whatever its name ----------------------------
lt="$TMP/lt"
git init -q -b main "$lt"
mkdir -p "$lt/source" "$lt/tools/scoping"
live() { # live <file name>: a map naming one SOURCE file, tracked in git
	rm -rf "$lt/source"/* && printf 'x\n' >"$lt/source/$1"
	git -C "$lt" add -A && git -C "$lt" commit -q -m "track" --allow-empty
	printf "source_root: source\nnodes:\n  - id: u1\n    source: '%s'\n" "$1" >"$lt/tools/scoping/dependency-map.yaml"
}
live 'plain.f90'
expect 0 "live-tracked: an ASCII name is tracked (control)" "$lt" python3 "$ROOT/tools/coordination/check_live_tracked.py"
live 'höhe.f90'
expect 0 "live-tracked: a non-ASCII name is tracked" "$lt" python3 "$ROOT/tools/coordination/check_live_tracked.py"
live 'say"hi".f90'
expect 0 "live-tracked: a name with a double quote is tracked" "$lt" python3 "$ROOT/tools/coordination/check_live_tracked.py"
printf 'y\n' >"$lt/source/untracked.f90"
printf 'source_root: source\nnodes:\n  - id: u1\n    source: untracked.f90\n' >"$lt/tools/scoping/dependency-map.yaml"
EXPECT_OUT="UNTRACKED" expect 1 "live-tracked: an untracked file is still RED (control)" \
	"$lt" python3 "$ROOT/tools/coordination/check_live_tracked.py"

# ---- check_claims.py: a branch change under an owned surface is seen, whatever its name -------------
cc="$TMP/cc"
git init -q -b main "$cc"
mkdir -p "$cc/src/core" "$TMP/claims"
printf 'x\n' >"$cc/src/core/base.c"
git -C "$cc" add -A && git -C "$cc" commit -q -m base
printf 'id: u1\nclaimant: op\ncreated: 2026-01-01T00:00:00Z\nstate: active\npaths:\n  - "**"\n' >"$TMP/claims/u1.yaml"
printf 'src/core\n' >"$TMP/owned.txt"
branch() { # branch <file name>: work/u1 adds src/core/<name>
	git -C "$cc" checkout -q -B work/u1 main
	printf 'y\n' >"$cc/src/core/$1"
	git -C "$cc" add -A && git -C "$cc" commit -q -m change
	git -C "$cc" checkout -q main
}
claims() {
	python3 "$ROOT/tools/coordination/check_claims.py" --claims-dir "$TMP/claims" --claim u1 \
		--branch work/u1 --base main --owned-surfaces "$TMP/owned.txt"
}
branch 'kernel.c'
EXPECT_OUT="reaches owned surface 'src/core'" expect 1 "claims: an ASCII change under an owned surface is RED (control)" "$cc" claims
branch 'höhe.c'
EXPECT_OUT="reaches owned surface 'src/core' via 'src/core/höhe.c'" \
	expect 1 "claims: a non-ASCII change under an owned surface is RED" "$cc" claims
branch 'say"hi".c'
EXPECT_OUT="reaches owned surface 'src/core' via 'src/core/say\"hi\".c'" \
	expect 1 "claims: a change with a double quote in its name under an owned surface is RED" "$cc" claims

# A name that is not valid UTF-8 is still reported, never a traceback, even where the output encoding
# is strict UTF-8 (as under a UTF-8 locale).
branch $'bad\xff.c'
set +e; out="$(cd "$cc" && PYTHONIOENCODING=utf-8:strict claims 2>&1)"; rc=$?; set -e
if [ "$rc" = 1 ] && grep -qF "reaches owned surface 'src/core'" <<<"$out" && ! grep -q Traceback <<<"$out"; then
	pass "claims: a change whose name is not UTF-8 is reported, not a traceback"
else
	bad "claims: a change whose name is not UTF-8 is reported, not a traceback (exit $rc)"
	printf '%s\n' "$out" | sed 's/^/#   /' >&2
fi

# A move is two changes: the old path leaves the owned surface. With rename detection the diff listed
# only the new path, inside the claim's surface, so the claim passed a branch that emptied an owned file.
printf 'id: u1\nclaimant: op\ncreated: 2026-01-01T00:00:00Z\nstate: active\npaths:\n  - src/mine\n' >"$TMP/claims/u1.yaml"
git -C "$cc" checkout -q -B work/u1 main
mkdir -p "$cc/src/mine"
git -C "$cc" mv src/core/base.c src/mine/base.c
git -C "$cc" commit -q -m move
git -C "$cc" checkout -q main
EXPECT_OUT="touched 'src/core/base.c' outside claim 'u1' write surface" \
	expect 1 "claims: moving a file out of an owned surface is RED" "$cc" claims

# ---- check-references.sh: a tracked doc is scanned, whatever its name -------------------------------
cr="$TMP/cr"
git init -q -b main "$cr"
mkdir -p "$cr/tools/conformance" "$cr/tools/notes" "$cr/.opencode/skill/target-conventions/references/pairs"
cp "$ROOT/tools/conformance/check-references.sh" "$cr/tools/conformance/"
printf '| T1 | a trap row |\n' >"$cr/.opencode/skill/target-conventions/references/pairs/fortran-to-c.md"
# The missing path is put together at run time, so this file itself cites no reference path.
gone="references/gone"
cite() { # cite <file name>: the only note, tracked, citing a reference file that does not exist
	rm -f "$cr/tools/notes"/*
	printf 'See %s.md for the rule.\n' "$gone" >"$cr/tools/notes/$1"
	git -C "$cr" add -A && git -C "$cr" commit -q -m note --allow-empty
}
cite 'plain.md'
EXPECT_OUT="dangling reference path '$gone.md'" \
	expect 1 "references: an ASCII-named doc is scanned (control)" "$cr" bash tools/conformance/check-references.sh
cite 'résumé.md'
EXPECT_OUT="tools/notes/résumé.md: dangling reference path" \
	expect 1 "references: a non-ASCII-named doc is scanned" "$cr" bash tools/conformance/check-references.sh

[ "$failed" -eq 0 ] || { printf '# test-git-paths-z: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-git-paths-z: all assertions passed\n'
