#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# The shell tools must read a YAML value as data, the way the Python tools read the same file.
# A sed/awk line scan takes the first matching line: a key nested under another mapping reads as the
# top-level key, a repeated key reads as its first copy, an alias reads as its `*name` text, and an
# inline comment or a quote is kept or cut wrongly. Each case drives a real tool on a throwaway repo:
#   - finalize.sh --auto: a nested `level: L3` must not authorize the auto-seal, and a config it
#     cannot read authorizes nothing;
#   - product-root.sh: the product checkout is the top-level `checkout:`, and a product.yaml with a
#     repeated key is UNRELIABLE;
#   - integrate_assets.sh: the product mainline is the top-level `default_branch:` (null means main);
#   - checkout-product.sh: the clone goes to the top-level `checkout:`;
#   - check-source-import.sh: an inline comment is not part of `path:`, and a repeated
#     `tracked_files:` or a missing PyYAML is UNRELIABLE, never a pass;
#   - chisel-init.py: the handoff quotes the top-level provenance `commit:`/`remote:`, comment-free;
#   - a value holding a control character other than a tab (a YAML "\0" escape, which `$(...)` would
#     drop) is refused by every reader above, never read as the value without it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
	GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset PRODUCT_ROOT _PR_LOAD_CWD

# KEEP_GOING=1 reports every failing case instead of stopping at the first (for a red demonstration).
failed=0
pass() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; [ -n "${KEEP_GOING:-}" ] || exit 1; failed=$((failed + 1)); }

mkdir -p "$TMP/noyaml"
printf 'raise ImportError("PyYAML hidden by the test")\n' >"$TMP/noyaml/yaml.py"

# run <dir> <command...>: run from <dir>; sets OUT and RC.
run() {
	local dir="$1"
	shift
	set +e; OUT="$(cd "$dir" && "$@" 2>&1)"; RC=$?; set -e
}
# check <label> <want-rc> [text the output must hold]
check() {
	if [ "$RC" != "$2" ]; then
		bad "$1 (expected exit $2, got $RC)"; printf '%s\n' "$OUT" | sed 's/^/#   /' >&2
	elif [ -n "${3:-}" ] && ! grep -qF -- "$3" <<<"$OUT"; then
		bad "$1 (exit $RC as expected, but the output lacks '$3')"; printf '%s\n' "$OUT" | sed 's/^/#   /' >&2
	else
		pass "$1"
	fi
}

# ---- finalize.sh --auto reads the top-level level ---------------------------------------------------
fin="$TMP/fin"
git init -q -b main "$fin"
mkdir -p "$fin/tools" "$fin/port"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fin/tools/run-conformance.sh"   # a green suite, for the rig
autodrive() { # autodrive <yaml text>: commit it as port/autodrive.yaml, then run finalize --auto
	printf '%s' "$1" >"$fin/port/autodrive.yaml"
	git -C "$fin" add -A && git -C "$fin" commit -q -m "autodrive" --allow-empty
	run "$fin" env ${2:+"$2"} bash "$ROOT/tools/coordination/finalize.sh" m1 --auto --no-push --dry-run
}
autodrive $'budgets:\n  level: L3\nlevel: L1\n'
check "finalize: a level nested under another key does not authorize the auto-seal" 2 "got 'L1'"
autodrive $'level: L3\nlevel: L0\n'
check "finalize: a repeated level key authorizes nothing" 2 "cannot read the autodrive level"
autodrive $'level: L2   # auto within a phase\n' "PYTHONPATH=$TMP/noyaml"
check "finalize: without PyYAML the level cannot be read, which authorizes nothing" 2 "cannot read the autodrive level"
autodrive $'level: "L3"\n'
check "finalize: a quoted level is read as its value" 0 "auto-finalize check OK: level L3"
autodrive $'level: "L3\\0"\n'
check "finalize: a level holding a NUL escape authorizes nothing" 2 "control character U+0000"
autodrive $'level: L2   # auto within a phase\n'
check "finalize: a plain top-level level authorizes the auto-seal (control)" 0 "auto-finalize check OK: level L2"

# ---- product-root.sh reads the top-level checkout ---------------------------------------------------
pr="$TMP/pr"
git init -q -b main "$pr"
mkdir -p "$pr/port"
root_of() { # root_of <product.yaml text>: default_product_root's answer from the repo
	printf '%s' "$1" >"$pr/port/product.yaml"
	run "$pr" bash -c 'source "$1"; default_product_root' _ "$ROOT/tools/conformance/lib/product-root.sh"
}
root_of $'mirror:\n  checkout: ../elsewhere\ncheckout: ../product\n'
check "product-root: a checkout nested under another key is not the product checkout" 0 "$pr/../product"
root_of $'paths:\n  main: &co ../product\ncheckout: *co\n'
check "product-root: an aliased checkout reads as its value" 0 "$pr/../product"
root_of $'checkout: ../a\ncheckout: ../b\n'
check "product-root: a product.yaml with a repeated key is UNRELIABLE" 2 "duplicate key"
root_of $'checkout: ~\n'
check "product-root: a null checkout is unset (control)" 2
# A product.yaml that cannot be read is named as such, not as an unset checkout: the fixes differ.
printf 'checkout: ../a\ncheckout: ../b\n' >"$pr/port/product.yaml"
run "$pr" bash "$ROOT/tools/conformance/check-product-tests.sh"
check "check-product-tests: an unreadable product.yaml is named as such" 2 "port/product.yaml cannot be read"
run "$pr" bash "$ROOT/tools/coordination/assert_isolated.sh" u1
check "assert_isolated: an unreadable product.yaml is named as such" 2 "port/product.yaml cannot be read"
printf 'checkout: ~\n' >"$pr/port/product.yaml"
run "$pr" bash "$ROOT/tools/conformance/check-product-tests.sh"
check "check-product-tests: an unset checkout is still named as unset (control)" 2 "checkout is unset/placeholder"
root_of $'checkout: "../prod\\0uct"\n'
check "product-root: a checkout holding a NUL escape is UNRELIABLE, not ../product" 2 "control character U+0000"

# ---- integrate_assets.sh lands on the top-level default_branch --------------------------------------
wb="$TMP/wb"
prod="$TMP/product"
git init -q -b main "$wb"
mkdir -p "$wb/tools/coordination" "$wb/tools/conformance/lib" "$wb/port"
cp "$ROOT/tools/coordination/integrate_assets.sh" "$ROOT/tools/coordination/yaml_get.py" \
	"$ROOT/tools/coordination/_chisel_lib.py" "$wb/tools/coordination/"
cp "$ROOT/tools/conformance/lib/product-root.sh" "$wb/tools/conformance/lib/"
git init -q -b main "$prod"
printf 'readme\n' >"$prod/README.md"
git -C "$prod" add -A && git -C "$prod" commit -q -m product
git -C "$prod" checkout -q -b assets/x
printf 'more\n' >"$prod/NOTES.md"
git -C "$prod" add -A && git -C "$prod" commit -q -m asset
git -C "$prod" checkout -q main
assets() { # assets <product.yaml text>: commit it, then run the real asset land (dry-run)
	printf '%s' "$1" >"$wb/port/product.yaml"
	git -C "$wb" add -A && git -C "$wb" commit -q -m wb --allow-empty
	run "$wb" bash tools/coordination/integrate_assets.sh assets/x --no-push --dry-run
}
# Reaching the conformance step (absent in this rig) means the default-branch checks passed.
assets $'repo: none\ncheckout: ../product\nmirror:\n  default_branch: other\ndefault_branch: main\n'
check "integrate_assets: a default_branch nested under another key is not the mainline" 2 "conformance check(s) RED"
assets $'repo: none\ncheckout: ../product\ndefault_branch: ~\n'
check "integrate_assets: a null default_branch means main" 2 "conformance check(s) RED"
assets $'repo: none\ncheckout: ../product\ndefault_branch: main\ndefault_branch: other\n'
check "integrate_assets: a product.yaml with a repeated key is refused" 2 "duplicate key"
check "integrate_assets: an unreadable product.yaml is named as such" 2 "port/product.yaml cannot be read"
assets $'repo: none\ncheckout: ../product\ndefault_branch: "main\\0"\n'
check "integrate_assets: a default_branch holding a NUL escape is refused" 2 "control character U+0000"

# ---- checkout-product.sh clones to the top-level checkout -------------------------------------------
git clone -q --bare "$prod" "$TMP/product.git"
cw="$TMP/cw/wb"
git init -q -b main "$cw"
mkdir -p "$cw/tools/coordination" "$cw/tools/conformance/lib" "$cw/port"
cp "$ROOT/tools/checkout-product.sh" "$cw/tools/"
cp "$ROOT/tools/coordination/yaml_get.py" "$ROOT/tools/coordination/_chisel_lib.py" "$cw/tools/coordination/"
cp "$ROOT/tools/conformance/lib/product-root.sh" "$cw/tools/conformance/lib/"
printf 'repo: %s\nmirror:\n  checkout: ../wrong\ncheckout: ../right\n' "$TMP/product.git" >"$cw/port/product.yaml"
run "$cw" bash tools/checkout-product.sh
if [ "$RC" = 0 ] && [ -d "$TMP/cw/right/.git" ] && [ ! -e "$TMP/cw/wrong" ]; then
	pass "checkout-product: the clone goes to the top-level checkout, not a nested one"
else
	bad "checkout-product: the clone goes to the top-level checkout, not a nested one (exit $RC)"
	printf '%s\n' "$OUT" | sed 's/^/#   /' >&2
fi

# ---- check-source-import.sh reads the provenance as YAML --------------------------------------------
si="$TMP/si"
git init -q -b main "$si"
mkdir -p "$si/src" "$si/port/provenance"
printf 'a\n' >"$si/src/a.f90"
printf 'b\n' >"$si/src/b.f90"
git -C "$si" add -A && git -C "$si" commit -q -m import
provenance() { # provenance <yaml text> [env assignment]
	printf '%s' "$1" >"$si/port/provenance/s.yaml"
	run "$si" env ${2:+"$2"} bash "$ROOT/tools/conformance/check-source-import.sh"
}
provenance $'name: s\npath: src   # the imported tree\ntracked_files: 2\n'
check "check-source-import: an inline comment is not part of path" 0 "2 tracked = 2 upstream"
provenance $'name: s\npath: src\ntracked_files: 2\ntracked_files: 3\n'
check "check-source-import: a repeated tracked_files is UNRELIABLE, not a pass" 2 "duplicate key"
provenance $'name: s\npath: src\ntracked_files: 2\n' "PYTHONPATH=$TMP/noyaml"
check "check-source-import: without PyYAML the provenance cannot be read, which is UNRELIABLE" 2 "UNRELIABLE"
provenance $'name: s\npath: src\ntracked_files: 3\n'
check "check-source-import: a missing file is still RED (control)" 1 "1 MISSING"

# ---- chisel-init.py quotes the top-level provenance fields in the bootstrap handoff -----------------
ci="$TMP/ci"
mkdir -p "$ci/port/provenance" "$ci/tools/coordination"
cp "$ROOT/tools/coordination/yaml_get.py" "$ROOT/tools/coordination/_chisel_lib.py" "$ci/tools/coordination/"
printf 'name: s\nupstream:\n  commit: wrong\ncommit: right\nremote: git@host:o/s.git   # origin\n' \
	>"$ci/port/provenance/s.yaml"
prov() { # prov <field> [env assignment]: chisel-init's own _prov_field, imported from the script
	run "$ci" env ${2:+"$2"} python3 -c 'import importlib.util, sys
spec = importlib.util.spec_from_file_location("chisel_init", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print("[%s]" % mod._prov_field(sys.argv[2], "s", sys.argv[3]))' "$ROOT/tools/chisel-init.py" "$ci" "$1"
}
prov commit
check "chisel-init: the provenance commit is the top-level one, not a nested one" 0 "[right]"
prov remote
check "chisel-init: an inline comment is not part of the provenance remote" 0 "[git@host:o/s.git]"
prov commit "PYTHONPATH=$TMP/noyaml"
check "chisel-init: without PyYAML the handoff quotes no provenance value" 0 "[None]"

[ "$failed" -eq 0 ] || { printf '# test-yaml-callers: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-yaml-callers: all assertions passed\n'
