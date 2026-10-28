#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# The path-shape guards of the two sanctioned pushes must judge the REAL path of every changed file:
#   - contribute.sh refuses a contribution that touches any project-layer (merge=ours) file, so no
#     instance content reaches the shared base;
#   - integrate_assets.sh refuses an asset land that touches any TARGET source or build file, so no
#     code reaches the product mainline without an independent review.
# git's line-oriented path lists C-quote a path holding a non-ASCII byte, a double quote or a newline,
# and a guard reading that form compares the quoted string - which matches no rule - so the file passes.
# Each case drives the real script (--dry-run, nothing is pushed or merged) on a throwaway repo. The
# contribute cases also check that the base's pull request template reaches the pull request's body.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
	GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

pass() { printf 'ok - %s\n' "$1"; }
failt() { printf 'not ok - %s\n%s\n' "$1" "${2:-}" >&2; exit 1; }

NL=$'\n'

# ---- contribute.sh: project-layer files never go upstream ------------------------------------------
inst="$TMP/inst"
git init -q --bare "$TMP/base.git"
git init -q -b main "$inst"
mkdir -p "$inst/tools/coordination" "$inst/docs/evidence"
cp "$ROOT/tools/coordination/contribute.sh" "$inst/tools/coordination/"
cp "$ROOT/.gitattributes" "$inst/"
printf 'kept\n' >"$inst/docs/evidence/kept.md"
git -C "$inst" add -A
git -C "$inst" commit -q -m base
git -C "$inst" remote add upstream "$TMP/base.git"
git -C "$inst" push -q upstream main
git -C "$inst" fetch -q upstream

# contribution <expect: refused|accepted> <label> <change...>: build contribute/x on upstream/main with
# the change (a path to create, or "mv:<from>:<to>"), then run the real shape guard.
contribution() {
	local want="$1" label="$2" out rc got
	shift 2
	git -C "$inst" checkout -q -B contribute/x upstream/main
	local c
	for c in "$@"; do
		case "$c" in
			mv:*) IFS=: read -r _ from to <<<"$c"; mkdir -p "$inst/$(dirname "$to")"; git -C "$inst" mv "$from" "$to" ;;
			*) mkdir -p "$inst/$(dirname "$c")"; printf 'x\n' >"$inst/$c"; git -C "$inst" add -- "$c" ;;
		esac
	done
	git -C "$inst" commit -q -m change
	set +e
	out="$(cd "$inst" && bash tools/coordination/contribute.sh --branch contribute/x --no-pr --dry-run 2>&1)"
	rc=$?
	set -e
	git -C "$inst" checkout -q main
	git -C "$inst" branch -q -D contribute/x
	case "$rc:$out" in
		2:*"changes project-layer file"*) got=refused ;;
		0:*) got=accepted ;;
		*) got="exit $rc" ;;
	esac
	[ "$got" = "$want" ] || failt "contribute: $label (expected $want, got $got)" "$out"
	pass "contribute: $label"
}

contribution refused "an ASCII project file is refused" "docs/evidence/plain.md"
contribution refused "a project file with a non-ASCII name is refused" "docs/evidence/résumé.md"
contribution refused "a project file with a double quote in its name is refused" 'port/say "hi".md'
contribution refused "a project file with a newline in its name is refused" "port/two${NL}lines.md"
contribution refused "a project file renamed into a methodology path is refused" \
	"mv:docs/evidence/kept.md:.opencode/kept.md"
contribution accepted "a methodology file with a non-ASCII name is accepted" ".opencode/skills/notes/résumé.md"

# The base's pull request template (the contributor licence agreement) reaches a pull request opened
# from the command line: taken from the base, its HTML comments dropped, and not repeated when the
# body already carries it. A github-shaped remote whose main is the base gives the PR its slug.
mkdir -p "$inst/.github"
printf '<!-- guidance -->\n\nI agree to the CLA.\n' >"$inst/.github/pull_request_template.md"
git -C "$inst" add .github && git -C "$inst" commit -q -m template && git -C "$inst" push -q upstream main
git -C "$inst" fetch -q upstream
git -C "$inst" remote add gh git@github.com:org/base.git
git -C "$inst" update-ref refs/remotes/gh/main refs/remotes/upstream/main
git -C "$inst" checkout -q -B contribute/x upstream/main
mkdir -p "$inst/.opencode" && printf 'x\n' >"$inst/.opencode/new.md" && git -C "$inst" add .opencode && git -C "$inst" commit -q -m change
printf 'What and why.\n' >"$TMP/body.md"
out="$(cd "$inst" && bash tools/coordination/contribute.sh --branch contribute/x --remote gh --title t --body-file "$TMP/body.md" --dry-run 2>&1)" \
	|| failt "contribute: a pull request with the template is prepared" "$out"
grep -qF '    What and why.' <<<"$out" && grep -qF '    I agree to the CLA.' <<<"$out" && ! grep -qF 'guidance' <<<"$out" \
	|| failt "contribute: the base's pull request template is added to the body, without its comments" "$out"
pass "contribute: the base's pull request template is added to the body, without its comments"
printf 'What and why.\n\nI agree to the CLA.\n' >"$TMP/body.md"
out="$(cd "$inst" && bash tools/coordination/contribute.sh --branch contribute/x --remote gh --title t --body-file "$TMP/body.md" --dry-run 2>&1)"
[ "$(grep -cF 'I agree to the CLA.' <<<"$out")" = 1 ] || failt "contribute: a body that carries the template's text gets no second copy" "$out"
pass "contribute: a body that carries the template's text gets no second copy"
git -C "$inst" checkout -q main && git -C "$inst" branch -q -D contribute/x

# ---- integrate_assets.sh: code and build files never ride the asset path ---------------------------
wb="$TMP/wb"
prod="$TMP/product"
git init -q -b main "$wb"
mkdir -p "$wb/tools/coordination" "$wb/tools/conformance/lib" "$wb/port"
cp "$ROOT/tools/coordination/integrate_assets.sh" "$ROOT/tools/coordination/yaml_get.py" \
	"$ROOT/tools/coordination/_chisel_lib.py" "$wb/tools/coordination/"
cp "$ROOT/tools/conformance/lib/product-root.sh" "$wb/tools/conformance/lib/"
printf 'repo: none\ncheckout: ../product\ndefault_branch: main\n' >"$wb/port/product.yaml"
git -C "$wb" add -A
git -C "$wb" commit -q -m workbench
git init -q -b main "$prod"
printf 'readme\n' >"$prod/README.md"
git -C "$prod" add -A
git -C "$prod" commit -q -m product

# asset_land <expect: refused|passed> <label> <path>: a product branch adding <path>; "passed" means it
# cleared the asset-only guard (the run then stops at the next proof, conformance, absent in this rig).
asset_land() {
	local want="$1" label="$2" path="$3" out rc got
	git -C "$prod" checkout -q -B assets/x main
	mkdir -p "$prod/$(dirname "$path")"
	printf 'x\n' >"$prod/$path"
	git -C "$prod" add -- "$path"
	git -C "$prod" commit -q -m asset
	git -C "$prod" checkout -q main
	set +e
	out="$(cd "$wb" && bash tools/coordination/integrate_assets.sh assets/x --no-push --dry-run 2>&1)"
	rc=$?
	set -e
	git -C "$prod" branch -q -D assets/x
	case "$rc:$out" in
		2:*"fidelity-reviewed CODE"*) got=refused ;;
		2:*"conformance check(s) RED"*) got=passed ;;
		*) got="exit $rc" ;;
	esac
	[ "$got" = "$want" ] || failt "assets: $label (expected $want, got $got)" "$out"
	pass "assets: $label"
}

asset_land refused "an ASCII C source is refused" "src/hoehe.c"
asset_land refused "a C source with a non-ASCII name is refused" "src/höhe.c"
asset_land refused "a C source with a double quote in its name is refused" 'src/say"hi".c'
asset_land refused "a C source whose name holds a newline is refused" "src/notes${NL}kernel.c"
asset_land refused "a build file under a non-ASCII directory is refused" "módulo/CMakeLists.txt"
asset_land passed "a non-ASCII documentation file clears the asset guard" "docs/résumé.md"

printf '# test-shape-guards: all assertions passed\n'
