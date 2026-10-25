#!/usr/bin/env bash
# integrate_assets.sh - the sanctioned PRODUCT land for NON-CODE assets (the asset analogue of
# integrate_product.sh). A clone-build-RUN-able product needs more than ported code: the README, docs,
# example inputs / sample data, runtime configs - the files a consumer needs to actually run and self-test
# it. Those have no SOURCE file, so they are not pieces, the Phase-2 planner never recommends them, and
# integrate_product.sh / integrate_assembly.sh (which require a proven, fidelity-reviewed CODE piece) will
# never push them. Without this, a human must `git push` the product by hand for every README/input change.
#
# This lands a product branch of NON-CODE asset changes onto the product mainline, conformance-checked and
# crash-safe exactly like integrate_product.sh (two-root suite green at HEAD AND at the merge RESULT,
# roll-back-on-red, then push), so the product is kept a complete, pushed, clone-build-run-able mirror
# with no manual git push - the keystroke is never the trust check, the conformance-green RESULT is.
#
# It pushes from INSIDE this script, bypassing the per-agent `git push` deny exactly as integrate_product.sh
# / integrate_land.sh / finalize.sh do - and only ever for ONE asset-only, conformance-green, non-stale branch.
#
# THE SAFETY BOUNDARY: it REFUSES if the branch changes any fidelity-reviewed TARGET source or build file
# (*.c/*.h/*.cpp/*.rs/*.f90/..., CMakeLists.txt/*.cmake/Makefile/Cargo.toml/...). Such changes determine
# numerical behaviour and MUST land through integrate_product.sh / integrate_assembly.sh under an independent
# review - they can never ride the asset path. Everything else (README, docs, example inputs, data, configs)
# lands here, with conformance-green at the merge result as the backstop that the product still builds/runs.
#
# FAIL-CLOSED (refuse, exit 2, merge/push NOTHING) unless ALL hold:
#  - a two-repo product is wired (port/product.yaml + a present checkout) and is on its clean default branch.
#  - the named branch exists in the product, INCLUDES the current mainline (not stale-based), and changes
#    ONLY non-code asset files (no TARGET source / build glue).
#  - the FULL conformance suite is green at HEAD (both roots), and AGAIN at the product merge RESULT.
#
#   integrate_assets.sh <branch> [--message <msg>] [--remote origin] [--no-push] [--dry-run]
# Exit: 0 landed (squash-merged onto the product mainline + pushed); 2 refused.
set -euo pipefail

fail() { echo "integrate-assets: $*" >&2; exit 2; }
say()  { echo "integrate-assets: $*"; }
run()  { echo "  + $*"; [ "$DRY" = 1 ] || "$@"; }

# Crash-safe rollback: from the moment we mutate the product until the merge RESULT is verified green, ARM a
# rollback so ANY exit (failed git command, signal/kill) resets the product mainline to its pre-land commit.
ROLLBACK_ARMED=0; PC=""; PRE_LAND=""
rollback_product() {
	[ "$ROLLBACK_ARMED" = 1 ] || return 0
	echo "integrate-assets: land did not complete verified - rolling product back to $PRE_LAND" >&2
	git -C "$PC" reset --hard "$PRE_LAND" >/dev/null 2>&1 \
		|| echo "integrate-assets: WARNING - rollback FAILED; the product mainline may sit at an UNVERIFIED commit (nothing was pushed). Reset it by hand: git -C '$PC' reset --hard $PRE_LAND" >&2
}
trap rollback_product EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

BR=""; REMOTE="origin"; PUSH=1; DRY=0; MSG=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--message) [ "$#" -ge 2 ] || fail "--message needs a commit message"; MSG="$2"; shift 2 ;;
		--remote)  [ "$#" -ge 2 ] || fail "--remote needs a remote name"; REMOTE="$2"; shift 2 ;;
		--no-push) PUSH=0; shift ;;
		--dry-run) DRY=1; shift ;;
		--*)       fail "unknown option: $1" ;;
		*)         [ -z "$BR" ] || fail "only one <branch> allowed (got '$BR' and '$1')"; BR="$1"; shift ;;
	esac
done

[ -n "$BR" ] || fail "usage: integrate_assets.sh <branch> [--message <msg>] [--remote origin] [--no-push] [--dry-run]"
case "$BR" in *[!A-Za-z0-9._/-]*|""|/*|*/|-*|*..*) fail "branch '$BR' must be a plain branch name ([A-Za-z0-9._/-], no leading '-' or '/', no '..')" ;; esac
case "$REMOTE" in ""|-*|*:*|*/*|*" "*) fail "remote '$REMOTE' must be a configured remote name" ;; esac

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../conformance/lib/product-root.sh"
wb="$(_pr_repo_root)" || fail "not inside a git repository"
cd "$wb"

# Proof 0 (TWO-REPO WIRED): resolve the product checkout, fail-closed on single-repo / placeholder / absent.
set +e; PC="$(default_product_root)"; PRC=$?; set -e
case "$PRC" in
	0)  : ;;
	10) fail "single-repo (no port/product.yaml) - there is no separate product to land assets onto" ;;
	2)  fail "product is wired but its checkout is unset/placeholder - set it in port/product.yaml first (UNRELIABLE)" ;;
	*)  fail "cannot resolve the product checkout" ;;
esac
[ -d "$PC" ] || fail "product checkout '$PC' is absent - clone it first (tools/checkout-product.sh)"
git -C "$PC" rev-parse --show-toplevel >/dev/null 2>&1 || fail "product checkout '$PC' is not a git repo"

# The product's default branch (the mainline we land onto), from port/product.yaml; default 'main'.
DB="$(sed -nE 's/^[[:space:]]*default_branch:[[:space:]]*(.*)$/\1/p' port/product.yaml | head -1 \
	| sed -E 's/[[:space:]]*#.*$//; s/^["'\'']//; s/["'\'']$//; s/[[:space:]]*$//')"
[ -n "$DB" ] || DB="main"
[ "$BR" != "$DB" ] || fail "<branch> must be a feature branch, not the mainline '$DB' itself"

# Proof 1 (PRODUCT ON ITS MAINLINE, clean): land onto the real mainline, exactly the branch's bytes.
pcur="$(git -C "$PC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
[ "$pcur" = "$DB" ] || fail "product checkout is on '$pcur', not '$DB' - check out the product mainline before landing"
[ -z "$(git -C "$PC" status --porcelain)" ] || fail "product working tree is dirty - commit/clean it first (we land exactly the branch's bytes)"

# Proof 2 (BRANCH EXISTS, NOT STALE): a product branch that INCLUDES the current mainline, so the squash
# result tree == the branch tip tree (a stale base would land a stale mix).
git -C "$PC" rev-parse -q --verify "refs/heads/$BR" >/dev/null 2>&1 || fail "branch '$BR' not found in the product repo ('$PC')"
pmain="$(git -C "$PC" rev-parse "$DB")"
brtip="$(git -C "$PC" rev-parse "$BR")"
[ "$brtip" != "$pmain" ] || fail "'$BR' is already at '$DB' - nothing to integrate"
git -C "$PC" merge-base --is-ancestor "$pmain" "$BR" \
	|| fail "'$BR' does not include the current '$DB' (the base moved) - rebase '$BR' onto '$DB', then retry; nothing landed (stale-base rule)"

# Proof 3 (ASSET-ONLY): the branch must change NO fidelity-reviewed TARGET source or build file. Such files
# determine numerical behaviour and MUST land through integrate_product.sh / integrate_assembly.sh under an
# independent review - the asset path can never ship them. Over-refusing is safe (route through the reviewed
# land); under-refusing would let unreviewed code ride, so the list is deliberately broad and case-insensitive.
# Source code (the fidelity-reviewed target, every language the methodology targets - including the
# INCLUDE/header fragments that are compiled code: Fortran .inc/.fi/.fh/.fpp, C/C++ .inc):
REFUSE_RE='\.(c|cc|cpp|cxx|c\+\+|h|hh|hpp|hxx|h\+\+|ipp|inl|tcc|inc|cu|cuh|rs|f|f77|f90|f95|f03|f08|for|ftn|fi|fh|fpp)$'
# Build glue by extension (incl. Make include fragments .mak):
REFUSE_RE="$REFUSE_RE"'|\.(cmake|mk|mak|make|am|m4|bazel|bzl|gn|gni|ninja|pro|pri|gyp|gypi)$'
# Build glue by basename (incl. the extensionless ones - Bazel, SCons, autotools, ...):
REFUSE_RE="$REFUSE_RE"'|(^|/)(CMakeLists\.txt|CMakePresets\.json|CMakeUserPresets\.json|Makefile|Makefile\.in|GNUmakefile|Kbuild|meson\.build|meson_options\.txt|meson\.options|configure|configure\.ac|configure\.in|config\.h\.in|aclocal\.m4|BUILD|BUILD\.bazel|WORKSPACE|WORKSPACE\.bazel|MODULE\.bazel|BUCK|SConstruct|SConscript|build\.ninja|Cargo\.toml|Cargo\.lock|build\.rs|wscript|wscript_build|fpm\.toml|conanfile\.txt|conanfile\.py|vcpkg\.json)$'
# Build-control dotfiles / nested build config (Bazel/Buck rc files, Rust cargo config + toolchain pin):
REFUSE_RE="$REFUSE_RE"'|(^|/)(\.bazelrc|\.bazelversion|\.buckconfig|rust-toolchain|rust-toolchain\.toml)$'
REFUSE_RE="$REFUSE_RE"'|(^|/)\.cargo/config(\.toml)?$'
# Autotools auxiliary build scripts (committed by some projects; they shape the build):
REFUSE_RE="$REFUSE_RE"'|(^|/)(config\.guess|config\.sub|ltmain\.sh|libtool|compile|depcomp|install-sh|missing|mkinstalldirs|ar-lib|test-driver)$'
# --no-renames so a rename of a code/build file (e.g. src/foo.c -> docs/foo.txt) shows the OLD path too
# (a delete of src/foo.c), which the source-code rule catches - a rename must not launder code out of review.
# Paths travel NUL-delimited (-z): the default line form C-quotes a path with a non-ASCII byte, a quote or
# a newline ("src/h\303\266he.c" ends in a quote), so no $-anchored rule would match and the code would land
# unreviewed. A path holding a newline is matched line by line, so its real ending is still tested (and any
# other line that looks like code only over-refuses, which is safe).
nchanged=0
refused=""
while IFS= read -r -d '' f; do
	[ -n "$f" ] || continue
	nchanged=$((nchanged + 1))
	printf '%s\n' "$f" | grep -qiE "$REFUSE_RE" && refused="${refused}
  - ${f}"
done < <(git -C "$PC" diff -z --no-renames --name-only "$pmain" "$brtip")
[ "$nchanged" -gt 0 ] || fail "'$BR' changes no files vs '$DB' - nothing to integrate"
[ -z "$refused" ] || fail "'$BR' changes fidelity-reviewed CODE / build files, which must NOT land via the asset path:${refused}
Land code/build glue through integrate_product.sh / integrate_assembly.sh (under a proven independent review).
integrate_assets.sh is for non-code product assets only (README, docs, example inputs, sample data, configs)."

if [ "$PUSH" = 1 ]; then
	git -C "$PC" remote get-url "$REMOTE" >/dev/null 2>&1 || fail "product remote '$REMOTE' is not configured (in '$PC')"
fi

# Proof 4 (TRUST FLOOR, both roots): full conformance green at HEAD before we mutate anything.
bash tools/run-conformance.sh >/dev/null 2>&1 \
	|| fail "conformance check(s) RED at HEAD - never land over a red proof; fix them first (see: bash tools/run-conformance.sh)"

# Land: ONE squashed product commit onto the mainline. ARM the crash-safe rollback first.
[ -n "$MSG" ] || MSG="chore(assets): land product assets from $BR"
PRE_LAND="$pmain"
say "landing asset branch '$BR' onto product '$DB' as one squashed commit (asset-only, conformance green, non-stale)$([ "$DRY" = 1 ] && echo ' [dry-run]')"
[ "$DRY" = 1 ] || ROLLBACK_ARMED=1
run git -C "$PC" merge --squash "$BR"
run git -C "$PC" commit -m "$MSG"

# Proof 5 (LANDED BYTES, two-root merge RESULT): re-run the FULL suite against the merge result; an asset that
# breaks the build/run/self-test turns it red - the armed rollback resets the mainline and we refuse (push NOTHING).
if [ "$DRY" != 1 ]; then
	if ! bash tools/run-conformance.sh >/dev/null 2>&1; then
		fail "conformance check(s) RED at the product merge result - rolling product '$DB' back to $pmain, nothing pushed. The asset change broke the product (see: bash tools/run-conformance.sh)."
	fi
fi
# Verified green (or dry-run): DISARM the rollback and KEEP the commit. A later push failure leaves the
# verified commit in place (just retry the push), exactly like integrate_product.
ROLLBACK_ARMED=0

[ "$PUSH" = 1 ] && run git -C "$PC" push "$REMOTE" "$DB"

newmain="$(git -C "$PC" rev-parse "$DB" 2>/dev/null || echo "$pmain")"
say "done - asset branch '$BR' landed on product '$DB'$([ "$PUSH" = 1 ] && echo " (pushed to $REMOTE)")$([ "$DRY" = 1 ] && echo ' [dry-run]')."
say "product.main_commit=$newmain - the product mainline now carries these assets."
