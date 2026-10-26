#!/usr/bin/env bash
# Regression tests for how the product-facing conformance checks choose the tree they scan.
#
# tools/run-conformance.sh resolves the product root ONCE and exports it as PRODUCT_ROOT, so every
# product-facing check must honor that variable; a check that ignores it re-derives the root on its
# own and can scan a different tree than the rest of the suite (typically an empty one, which it
# then reports as a clean skip). Whichever root is selected, a check must also refuse to call a scan
# clean when it cannot have examined the right files: the wrong tree (a worker's populated product
# worktree beside an empty configured one), an unreadable root or subdirectory, or a directory that
# lists but cannot be searched. Each case drives a byte copy of the shipped checks and their lib/
# inside a throwaway workbench, over synthetic product trees.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
	chmod -R u+rwx "$TMP" 2>/dev/null || true
	rm -rf "$TMP"
}
trap cleanup EXIT

# The checks read these from the environment; keep the caller's settings out of the fixtures.
unset PRODUCT_ROOT TARGET_DIR PRODUCT_README VOCAB_FILE INDEX_HELPER_WAIVERS REQUIRE_FILLED \
	_PR_LOAD_CWD

CHECKS=(
	check-index-helpers.sh
	check-no-silenced-detectors.sh
	check-product-invisibility.sh
	check-product-readme.sh
	check-product-tests.sh
)

failures=0
# expect EXIT LABEL DIR CMD... - run CMD from DIR and compare its exit code.
expect() {
	local expected="$1" label="$2" dir="$3" output rc
	shift 3
	set +e
	output="$(cd "$dir" && "$@" 2>&1)"
	rc=$?
	set -e
	if [ "$rc" -ne "$expected" ]; then
		printf 'not ok - %s (expected exit %s, got %s)\n%s\n' "$label" "$expected" "$rc" "$output" >&2
		failures=$((failures + 1))
		return 0
	fi
	printf 'ok - %s\n' "$label"
}

WB="$TMP/wb"
mkdir -p "$WB/tools/conformance"
for c in "${CHECKS[@]}"; do cp "$ROOT/tools/conformance/$c" "$WB/tools/conformance/"; done
cp -R "$ROOT/tools/conformance/lib" "$WB/tools/conformance/"
cp "$ROOT/tools/conformance/chisel-vocabulary.txt" "$WB/tools/conformance/"
mkdir -p "$WB/tools/coordination"
cp "$ROOT/tools/coordination/yaml_get.py" "$ROOT/tools/coordination/_chisel_lib.py" "$WB/tools/coordination/"
git -C "$WB" init -q -b main
git -C "$WB" config user.name tester
git -C "$WB" config user.email tester@example.invalid
git -C "$WB" add tools
git -C "$WB" commit -q -m "add the product-facing checks"

# A product tree every one of the five checks finds a defect in.
RED="$TMP/red"
mkdir -p "$RED/src"
cat >"$RED/src/model.c" <<'EOF'
#pragma GCC diagnostic ignored "-Wunused"
void step(double *z, int i, int j, int nx) { z[i + j * nx] = 0.0; }
EOF
printf '%s\n' '# Model' '' 'Built by following the port charter.' >"$RED/README.md"
printf '%s\n' 'add_executable(unit ../tests/unit/test_model.c)' >"$RED/CMakeLists.txt"

# The same shape with no defect.
CLEAN="$TMP/clean"
mkdir -p "$CLEAN/src"
printf '%s\n' 'void step(double *z, int i) { z[i] = 0.0; }' >"$CLEAN/src/model.c"
printf '%s\n' '# Model' >"$CLEAN/README.md"
printf '%s\n' 'add_library(model src/model.c)' >"$CLEAN/CMakeLists.txt"

C="$WB/tools/conformance"

# 1. Every check scans the tree PRODUCT_ROOT names (the runner's single resolution), not the
#    target/ fallback it would derive on its own.
for c in "${CHECKS[@]}"; do
	expect 1 "$c scans the tree named by PRODUCT_ROOT" "$WB" env PRODUCT_ROOT="$RED" bash "$C/$c"
	expect 0 "$c stays green on a clean tree named by PRODUCT_ROOT" "$WB" env PRODUCT_ROOT="$CLEAN" bash "$C/$c"
done

# 2. A check's own, finer-grained override still wins over the suite-wide PRODUCT_ROOT.
expect 0 "TARGET_DIR wins over PRODUCT_ROOT (index helpers)" "$WB" \
	env PRODUCT_ROOT="$RED" TARGET_DIR="$CLEAN" bash "$C/check-index-helpers.sh"
expect 0 "TARGET_DIR wins over PRODUCT_ROOT (silenced detectors)" "$WB" \
	env PRODUCT_ROOT="$RED" TARGET_DIR="$CLEAN" bash "$C/check-no-silenced-detectors.sh"
expect 0 "PRODUCT_README wins over PRODUCT_ROOT" "$WB" \
	env PRODUCT_ROOT="$RED" PRODUCT_README="$CLEAN/README.md" bash "$C/check-product-readme.sh"

# 3. The README check takes the same --product-root flag as the other product checks, and an
#    explicitly named product without a README is UNRELIABLE, never a skip.
expect 1 "check-product-readme.sh --product-root scans that tree's README" "$WB" \
	bash "$C/check-product-readme.sh" --product-root "$RED"
mkdir -p "$TMP/no-readme"
expect 2 "an explicit product root without a README is UNRELIABLE" "$WB" \
	env PRODUCT_ROOT="$TMP/no-readme" bash "$C/check-product-readme.sh"

# 4. Wrong tree: a worker runs from its own workbench worktree (.worktrees/<id>), whose product
#    worktree (.worktrees/product-<id>) holds the TARGET files, while the configured product (or a
#    stale explicit PRODUCT_ROOT) is the empty shared checkout. Scanning the shared tree would examine
#    none of the worker's files and report a vacuous pass; every check must refuse (UNRELIABLE).
WT="$TMP/wt"
mkdir -p "$WT/tools/conformance" "$WT/tools/coordination" "$WT/port" "$TMP/shared"
cp -R "$WB/tools/conformance/." "$WT/tools/conformance/"
cp -R "$WB/tools/coordination/." "$WT/tools/coordination/"
printf '%s\n' 'checkout: ../shared' 'attested_commit: none' >"$WT/port/product.yaml"
git -C "$WT" init -q -b main
git -C "$WT" config user.name tester
git -C "$WT" config user.email tester@example.invalid
git -C "$WT" add tools port
git -C "$WT" commit -q -m "add checks"
git -C "$WT" worktree add -q -b work/w1 "$WT/.worktrees/w1"
mkdir -p "$WT/.worktrees/product-w1"
cp -R "$CLEAN/." "$WT/.worktrees/product-w1/"
printf '%s\n' '# Model' >"$TMP/shared/README.md"
printf '%s\n' 'add_library(model)' >"$TMP/shared/CMakeLists.txt"
for c in "${CHECKS[@]}"; do
	expect 2 "$c refuses the configured tree when the worker's own product worktree is populated" \
		"$WT/.worktrees/w1" bash "tools/conformance/$c"
	expect 2 "$c refuses an explicit PRODUCT_ROOT naming the wrong tree" \
		"$WT/.worktrees/w1" env PRODUCT_ROOT="$TMP/shared" bash "tools/conformance/$c"
	expect 0 "$c scans the worker's own product worktree when named" \
		"$WT/.worktrees/w1" env PRODUCT_ROOT="$WT/.worktrees/product-w1" bash "tools/conformance/$c"
	expect 0 "$c scans the configured tree from the main workbench" "$WT" bash "tools/conformance/$c"
done

# 5. Unreadable trees: a walk or read that fails is not a confirmed-empty or clean scan. Mode bits
#    do not bind a privileged user, so these cases need an unprivileged one.
if [ "$(id -u)" -eq 0 ]; then
	printf 'ok - # SKIP permission cases: running as root, mode bits are not enforced\n'
else
	LOCKED="$TMP/locked"
	cp -R "$RED" "$LOCKED"
	chmod 000 "$LOCKED"
	for c in "${CHECKS[@]}"; do
		expect 2 "$c reports an unreadable product root as UNRELIABLE" "$WB" \
			env PRODUCT_ROOT="$LOCKED" bash "$C/$c"
	done
	chmod 755 "$LOCKED"

	# A defect inside a subdirectory the walk cannot enter.
	HIDDEN="$TMP/hidden"
	cp -R "$CLEAN" "$HIDDEN"
	mkdir -p "$HIDDEN/src/deep"
	cp "$RED/src/model.c" "$HIDDEN/src/deep/kernel.c"
	cp "$RED/CMakeLists.txt" "$HIDDEN/src/deep/CMakeLists.txt"
	printf '%s\n' 'Built by following the port charter.' >"$HIDDEN/src/deep/notes.txt"
	chmod 000 "$HIDDEN/src/deep"
	for c in check-index-helpers.sh check-no-silenced-detectors.sh check-product-invisibility.sh \
		check-product-tests.sh; do
		expect 2 "$c reports an unreadable subdirectory as UNRELIABLE" "$WB" \
			env PRODUCT_ROOT="$HIDDEN" bash "$C/$c"
	done

	# Readable but not searchable: `find` lists the entries without error, every read fails.
	chmod 644 "$HIDDEN/src/deep"
	for c in check-index-helpers.sh check-no-silenced-detectors.sh check-product-invisibility.sh \
		check-product-tests.sh; do
		expect 2 "$c reports an unsearchable subdirectory as UNRELIABLE" "$WB" \
			env PRODUCT_ROOT="$HIDDEN" bash "$C/$c"
	done
	chmod 755 "$HIDDEN/src/deep"

	# A file the check cannot read, holding the defect: its contents were never examined.
	FLOCK="$TMP/filelock"
	cp -R "$CLEAN" "$FLOCK"
	cp "$RED/src/model.c" "$FLOCK/src/kernel.c"
	printf '%s\n' 'Built by following the port charter.' >"$FLOCK/notes.txt"
	cp "$RED/CMakeLists.txt" "$FLOCK/CMakeLists.txt"
	chmod 000 "$FLOCK/src/kernel.c" "$FLOCK/notes.txt" "$FLOCK/CMakeLists.txt"
	for c in check-index-helpers.sh check-no-silenced-detectors.sh check-product-invisibility.sh \
		check-product-tests.sh; do
		expect 2 "$c reports an unreadable file as UNRELIABLE" "$WB" env PRODUCT_ROOT="$FLOCK" bash "$C/$c"
	done
	chmod 644 "$FLOCK/src/kernel.c" "$FLOCK/notes.txt" "$FLOCK/CMakeLists.txt"

	# The configured product's README exists but cannot be read.
	printf '%s\n' 'Built by following the port charter.' >>"$TMP/shared/README.md"
	chmod 000 "$TMP/shared/README.md"
	expect 2 "check-product-readme.sh reports an unreadable configured README as UNRELIABLE" "$WT" \
		bash "tools/conformance/check-product-readme.sh"
	chmod 644 "$TMP/shared/README.md"
fi

if [ "$failures" -gt 0 ]; then
	printf '%s product-root check case(s) failed\n' "$failures" >&2
	exit 1
fi
