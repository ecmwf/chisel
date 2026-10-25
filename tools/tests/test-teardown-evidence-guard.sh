#!/usr/bin/env bash
# Test the provision_worker.sh remove teardown guard.
#
# A reviewer writes its report into the worker's worktree, and the worker commits its fragment and gate
# evidence on work/<id>; a product land lands only the PRODUCT, so that workbench evidence survives only
# if it was gathered onto the trusted line (the workbench root's HEAD). Teardown used to fall back to
# `git worktree remove --force` (deleting untracked reports), `git branch -D` (deleting committed but
# ungathered evidence), and print success even when removal failed. The guard must refuse - removing
# nothing - while evidence is ungathered, pass once it is gathered or fast-forward landed, discard only
# on --discard-ungathered, and report success only when every removal succeeded. Revert the guard in
# provision_worker.sh and every refusal case, the discard case and the failed-removal case go RED; only
# the fast-forward pass and the option-usage refusal stay green (the swap-and-fail).
#
# Every case runs in its own subshell and fixture so one RED case does not hide the others.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVISION="$ROOT/tools/coordination/provision_worker.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail_test() {
	printf 'not ok - %s\n' "$1" >&2
	exit 1
}

pass_test() {
	printf 'ok - %s\n' "$1"
}

new_repo() {
	local repo="$1"
	mkdir -p "$repo"
	git -C "$repo" init -q -b main
	git -C "$repo" config user.name tester
	git -C "$repo" config user.email tester@example.invalid
	printf '%s\n' seed >"$repo/README.md"
	git -C "$repo" add README.md
	git -C "$repo" commit -q -m "seed repository"
}

run_provision() {
	local repo="$1"
	shift
	(cd "$repo" && bash "$PROVISION" "$@")
}

# remove_rc <repo> <out-file> <args...> : run remove, capture combined output, echo the exit code.
remove_rc() {
	local repo="$1" out="$2" rc
	shift 2
	set +e
	run_provision "$repo" remove "$@" >"$out" 2>&1
	rc=$?
	set -e
	printf '%s' "$rc"
}

# provision <repo> <id> : a provisioned piece whose workbench worktree sits at <repo>/.worktrees/<id>.
provision() {
	run_provision "$1" add "$2" --claimant tester >"$TMP/$2-contract" 2>"$TMP/$2-add-log"
}

# commit_in <worktree> <path> <content> <message> : write + commit one file on the worktree's branch.
commit_in() {
	local wt="$1" path="$2" content="$3" msg="$4"
	mkdir -p "$wt/$(dirname "$path")"
	printf '%s\n' "$content" >"$wt/$path"
	git -C "$wt" add -- "$path"
	git -C "$wt" commit -q -m "$msg"
}

registered() { grep -qxF "worktree $2" <<<"$(git -C "$1" worktree list --porcelain)"; }
has_branch() { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }

assert_intact() {   # <label> <repo> <wt> <branch>
	registered "$2" "$3" || fail_test "$1: the worktree was unregistered"
	[ -d "$3" ] || fail_test "$1: the worktree directory was deleted"
	has_branch "$2" "$4" || fail_test "$1: the branch was deleted"
}

assert_gone() {     # <label> <repo> <wt> <branch> <out-file>
	registered "$2" "$3" && fail_test "$1: the worktree is still registered"
	[ ! -e "$3" ] || fail_test "$1: the worktree directory still exists"
	has_branch "$2" "$4" && fail_test "$1: the branch still exists"
	grep -qF "removed worktrees for" "$5" || fail_test "$1: no success line"
}

# (a) An UNTRACKED review report in the workbench worktree: refused, the report and the worktree survive.
case_untracked_report() {
	local repo="$TMP/a" wt="$TMP/a/.worktrees/a1" report="docs/evidence/2026-01-01-review-a1/report.md" rc
	new_repo "$repo"
	provision "$repo" a1
	mkdir -p "$wt/$(dirname "$report")"
	printf '%s\n' "verdict: clean" >"$wt/$report"
	rc="$(remove_rc "$repo" "$TMP/a-out" a1)"
	[ "$rc" = 2 ] || fail_test "untracked report: expected exit 2, got $rc: $(cat "$TMP/a-out")"
	[ -f "$wt/$report" ] || fail_test "untracked report: the report was deleted"
	assert_intact "untracked report" "$repo" "$wt" work/a1
	grep -qF "$report" "$TMP/a-out" || fail_test "untracked report: the refusal does not name the report"
	grep -qF "removed worktrees for" "$TMP/a-out" && fail_test "untracked report: success printed on refusal"
	pass_test "an untracked review report in the workbench worktree refuses teardown and survives"
}

# (a') A tracked file modified but not committed is uncommitted too.
case_modified_tracked() {
	local repo="$TMP/am" wt="$TMP/am/.worktrees/am1" rc
	new_repo "$repo"
	provision "$repo" am1
	printf '%s\n' "edited" >>"$wt/README.md"
	rc="$(remove_rc "$repo" "$TMP/am-out" am1)"
	[ "$rc" = 2 ] || fail_test "modified tracked file: expected exit 2, got $rc"
	assert_intact "modified tracked file" "$repo" "$wt" work/am1
	grep -qF "README.md" "$TMP/am-out" || fail_test "modified tracked file: the refusal does not name it"
	pass_test "an uncommitted modification in the workbench worktree refuses teardown"
}

# (b) Evidence COMMITTED on work/<id> but never gathered onto HEAD: refused, the branch survives.
# (b') Gathered but altered is not gathered. (c) Gathered byte-identically onto HEAD: removed.
case_committed_then_gathered() {
	local repo="$TMP/b" wt="$TMP/b/.worktrees/b1" log="docs/evidence/b1/gate.log" rc
	new_repo "$repo"
	provision "$repo" b1
	commit_in "$wt" "$log" "gate: R1 pass" "record gate evidence"
	rc="$(remove_rc "$repo" "$TMP/b-out" b1)"
	[ "$rc" = 2 ] || fail_test "ungathered evidence: expected exit 2, got $rc: $(cat "$TMP/b-out")"
	assert_intact "ungathered evidence" "$repo" "$wt" work/b1
	grep -qF "$log" "$TMP/b-out" || fail_test "ungathered evidence: the refusal does not name the path"
	pass_test "committed but ungathered evidence on the branch refuses teardown and keeps the branch"

	mkdir -p "$repo/$(dirname "$log")"
	printf '%s\n' "gate: R1 pass (edited)" >"$repo/$log"
	git -C "$repo" add -- "$log"
	git -C "$repo" commit -q -m "gather altered evidence"
	rc="$(remove_rc "$repo" "$TMP/b2-out" b1)"
	[ "$rc" = 2 ] || fail_test "altered gather: expected exit 2, got $rc"
	assert_intact "altered gather" "$repo" "$wt" work/b1
	pass_test "evidence gathered with different bytes still refuses teardown"

	git -C "$repo" show "work/b1:$log" >"$repo/$log"
	git -C "$repo" add -- "$log"
	git -C "$repo" commit -q -m "gather evidence byte-for-byte"
	rc="$(remove_rc "$repo" "$TMP/b3-out" b1)"
	[ "$rc" = 0 ] || fail_test "gathered evidence: expected exit 0, got $rc: $(cat "$TMP/b3-out")"
	assert_gone "gathered evidence" "$repo" "$wt" work/b1 "$TMP/b3-out"
	pass_test "evidence gathered byte-identically onto HEAD lets teardown proceed"
}

# (d) work/<id> fast-forward merged into HEAD (the Phase-1 land): removed.
case_fast_forward_landed() {
	local repo="$TMP/d" wt="$TMP/d/.worktrees/d1" rc
	new_repo "$repo"
	provision "$repo" d1
	commit_in "$wt" "docs/evidence/d1/gate.log" "gate: R1 pass" "record gate evidence"
	git -C "$repo" merge -q --ff-only work/d1
	rc="$(remove_rc "$repo" "$TMP/d-out" d1)"
	[ "$rc" = 0 ] || fail_test "fast-forward landed: expected exit 0, got $rc: $(cat "$TMP/d-out")"
	assert_gone "fast-forward landed" "$repo" "$wt" work/d1 "$TMP/d-out"
	pass_test "a branch fast-forward landed into HEAD tears down"
}

# State outside the evidence root is re-recorded by the trusted line: a fragment never gathered refuses;
# once HEAD carries its own (evolved) fragment, teardown proceeds.
case_state_fragment() {
	local repo="$TMP/s" wt="$TMP/s/.worktrees/s1" frag="port/status/s1.yaml" rc
	new_repo "$repo"
	provision "$repo" s1
	commit_in "$wt" "$frag" "status: in-progress" "record status fragment"
	rc="$(remove_rc "$repo" "$TMP/s-out" s1)"
	[ "$rc" = 2 ] || fail_test "ungathered fragment: expected exit 2, got $rc"
	assert_intact "ungathered fragment" "$repo" "$wt" work/s1
	grep -qF "$frag" "$TMP/s-out" || fail_test "ungathered fragment: the refusal does not name it"
	mkdir -p "$repo/port/status"
	printf '%s\n' "status: gated" "integration: integrated" >"$repo/$frag"
	git -C "$repo" add -- "$frag"
	git -C "$repo" commit -q -m "record integration"
	rc="$(remove_rc "$repo" "$TMP/s2-out" s1)"
	[ "$rc" = 0 ] || fail_test "re-recorded fragment: expected exit 0, got $rc: $(cat "$TMP/s2-out")"
	assert_gone "re-recorded fragment" "$repo" "$wt" work/s1 "$TMP/s2-out"
	pass_test "a status fragment refuses until the trusted line records its own, then tears down"
}

# (e) --discard-ungathered on an abandoned piece: removed, and every discarded path is printed.
case_discard() {
	local repo="$TMP/e" wt="$TMP/e/.worktrees/e1" log="docs/evidence/e1/gate.log" report="docs/evidence/2026-01-01-review-e1/report.md" rc
	new_repo "$repo"
	provision "$repo" e1
	commit_in "$wt" "$log" "gate: R1 fail" "record gate evidence"
	mkdir -p "$wt/$(dirname "$report")"
	printf '%s\n' "verdict: violations" >"$wt/$report"
	rc="$(remove_rc "$repo" "$TMP/e-out" e1 --discard-ungathered)"
	[ "$rc" = 0 ] || fail_test "discard: expected exit 0, got $rc: $(cat "$TMP/e-out")"
	assert_gone "discard" "$repo" "$wt" work/e1 "$TMP/e-out"
	grep -qF "$log" "$TMP/e-out" || fail_test "discard: the discarded committed path is not printed"
	grep -qF "$report" "$TMP/e-out" || fail_test "discard: the discarded untracked path is not printed"
	grep -qF "DISCARDING" "$TMP/e-out" || fail_test "discard: no loud discard warning"
	pass_test "--discard-ungathered tears an abandoned piece down and prints every discarded path"
}

# --discard-ungathered belongs to remove only.
case_discard_usage() {
	local repo="$TMP/u" rc
	new_repo "$repo"
	set +e
	run_provision "$repo" add u1 --discard-ungathered >"$TMP/u-out" 2>&1
	rc=$?
	set -e
	[ "$rc" = 2 ] || fail_test "discard usage: expected exit 2, got $rc"
	[ ! -e "$repo/.worktrees/u1" ] || fail_test "discard usage: add created a worktree"
	pass_test "--discard-ungathered is refused outside remove"
}

# (f) Two-repo: an uncommitted change in the PRODUCT worktree refuses, and nothing is removed - not even
# the clean workbench worktree. Once committed, both worktrees and both branches go.
case_two_repo_product() {
	local repo="$TMP/f" product="$TMP/f-product" wt="$TMP/f/.worktrees/f1" pwt="$TMP/f/.worktrees/product-f1" rc
	new_repo "$repo"
	new_repo "$product"
	mkdir -p "$repo/port"
	printf 'checkout: %s\ndefault_branch: main\n' "$product" >"$repo/port/product.yaml"
	provision "$repo" f1
	registered "$product" "$pwt" || fail_test "two-repo: the product worktree was not provisioned"
	mkdir -p "$pwt/src"
	printf '%s\n' "int unit(void);" >"$pwt/src/unit.h"
	rc="$(remove_rc "$repo" "$TMP/f-out" f1)"
	[ "$rc" = 2 ] || fail_test "two-repo dirty product: expected exit 2, got $rc: $(cat "$TMP/f-out")"
	[ -f "$pwt/src/unit.h" ] || fail_test "two-repo dirty product: the product file was deleted"
	assert_intact "two-repo dirty product (product)" "$product" "$pwt" work/f1
	assert_intact "two-repo dirty product (workbench)" "$repo" "$wt" work/f1
	grep -qF "src/unit.h" "$TMP/f-out" || fail_test "two-repo dirty product: the refusal does not name the file"
	pass_test "two-repo: an uncommitted product change refuses teardown and nothing is removed"

	git -C "$pwt" add src/unit.h
	git -C "$pwt" commit -q -m "add unit header"
	rc="$(remove_rc "$repo" "$TMP/f2-out" f1)"
	[ "$rc" = 0 ] || fail_test "two-repo clean: expected exit 0, got $rc: $(cat "$TMP/f2-out")"
	assert_gone "two-repo clean (product)" "$product" "$pwt" work/f1 "$TMP/f2-out"
	assert_gone "two-repo clean (workbench)" "$repo" "$wt" work/f1 "$TMP/f2-out"
	pass_test "two-repo: a clean teardown removes both worktrees and both branches"
}

# A removal that fails (a locked worktree) is never forced, never reported as success, and exits non-zero.
case_failed_removal() {
	local repo="$TMP/l" wt="$TMP/l/.worktrees/l1" rc
	new_repo "$repo"
	provision "$repo" l1
	git -C "$repo" worktree lock "$wt"
	rc="$(remove_rc "$repo" "$TMP/l-out" l1)"
	[ "$rc" != 0 ] || fail_test "failed removal: exited 0: $(cat "$TMP/l-out")"
	grep -qF "removed worktrees for" "$TMP/l-out" && fail_test "failed removal: success printed"
	assert_intact "failed removal" "$repo" "$wt" work/l1
	git -C "$repo" worktree unlock "$wt"
	pass_test "a failed removal exits non-zero without a success line"
}

failed=0
for case_fn in case_untracked_report case_modified_tracked case_committed_then_gathered \
	case_fast_forward_landed case_state_fragment case_discard case_discard_usage \
	case_two_repo_product case_failed_removal; do
	# Not `( ... ) || ...`: errexit is ignored inside a ||-list, so a failing setup step would go unseen.
	set +e
	( set -e; "$case_fn" )
	rc=$?
	set -e
	[ "$rc" -eq 0 ] || { printf 'not ok - %s (exit %s)\n' "$case_fn" "$rc" >&2; failed=$((failed + 1)); }
done
[ "$failed" -eq 0 ] || { printf '# test-teardown-evidence-guard: %s case(s) FAILED\n' "$failed" >&2; exit 1; }
printf '# test-teardown-evidence-guard: all assertions passed\n'
