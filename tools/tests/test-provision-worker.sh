#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVISION="$ROOT/tools/coordination/provision_worker.sh"
CLAIMS_CHECK="$ROOT/tools/coordination/check_claims.py"
THREAD_LEDGER="$ROOT/tools/coordination/thread_ledger.py"
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

expect_refusal() {
	local label="$1" repo="$2" output rc
	shift 2
	set +e
	output="$(run_provision "$repo" "$@" 2>&1)"
	rc=$?
	set -e
	if [ "$rc" -ne 2 ]; then
		printf 'not ok - %s (expected exit 2, got %s)\n%s\n' "$label" "$rc" "$output" >&2
		exit 1
	fi
	pass_test "$label"
}

expect_path_refusal_no_mutation() {
	local label="$1" repo="$2" id="$3" path="$4" claim before wt
	claim="$repo/port/claims/$id.yaml"
	before="$TMP/$id-before"
	wt="$repo/.worktrees/$id"
	mkdir -p "$repo/port/claims"
	printf '%s\n' "sentinel claim for $id" >"$claim"
	cp "$claim" "$before"
	expect_refusal "$label" "$repo" add "$id" --claim-path "$path"
	cmp -s "$before" "$claim" || fail_test "$label changed the existing claim"
	[ ! -e "$wt" ] || fail_test "$label created a worktree"
	if git -C "$repo" show-ref --verify --quiet "refs/heads/work/$id"; then
		fail_test "$label created a branch"
	fi
	if git -C "$repo" worktree list --porcelain | grep -qxF "worktree $wt"; then
		fail_test "$label registered a worktree"
	fi
}

expect_reconcile_refusal_no_mutation() {
	local label="$1" repo="$2" id="$3" claim before
	claim="$repo/port/claims/$id.yaml"
	before="$TMP/$id-reconcile-before"
	cp "$claim" "$before"
	expect_refusal "$label" "$repo" reconcile "$id" --claim-path tools/conformance/narrow.sh
	cmp -s "$before" "$claim" || fail_test "$label changed the claim"
}

write_headerless_claim() {
	local claim="$1" id="$2"
	cat >"$claim" <<EOF
id: $id
claimant: Initial
created: 2026-06-01 02:03:04+00:00
state: active
paths:
  - target/
  - port/status/$id.yaml
  - docs/evidence/$id/
threads:
  worker: ses_worker123
EOF
}

assert_default_claim() {
	local claim="$1" id="$2" claimant="$3" mode="$4" created_line expected
	created_line="$(while IFS= read -r line; do case "$line" in created:*) printf '%s' "$line";; esac; done <"$claim")"
	case "$created_line" in created:\ 20??-??-??T??:??:??Z) ;; *) fail_test "default claim has canonical created line" ;; esac
	expected="$TMP/expected-$id.yaml"
	{
		printf '%s\n' '# Local claim (worktree-lock model) - the provisioned worktree is the write lock; this file'
		printf '%s\n' '# records what the claim covers. Default store: port/claims/ (local). See release_claim.sh.'
		printf 'id: %s\n' "$id"
		printf 'claimant: "%s"\n' "$claimant"
		printf '%s\n' "$created_line"
		printf '%s\n' 'state: active' 'paths:'
		[ "$mode" != "single-repo" ] || printf '%s\n' '  - target/'
		printf '  - port/status/%s.yaml\n' "$id"
		printf '  - docs/evidence/%s/\n' "$id"
	} >"$expected"
	cmp -s "$expected" "$claim" || fail_test "$id default claim byte shape"
}

default_repo="$TMP/default"
new_repo "$default_repo"
run_provision "$default_repo" add default-one --claimant "Default User" >"$TMP/default-contract" 2>"$TMP/default-log"
assert_default_claim "$default_repo/port/claims/default-one.yaml" default-one "Default User" single-repo
pass_test "no-option single-repo default claim is byte-compatible"

phase2_repo="$TMP/phase2"
phase2_product="$TMP/phase2-product"
new_repo "$phase2_repo"
new_repo "$phase2_product"
mkdir -p "$phase2_repo/port"
printf 'checkout: %s\ndefault_branch: main\n' "$phase2_product" >"$phase2_repo/port/product.yaml"
run_provision "$phase2_repo" add default-two --claimant "Phase Two" >"$TMP/phase2-contract" 2>"$TMP/phase2-log"
assert_default_claim "$phase2_repo/port/claims/default-two.yaml" default-two "Phase Two" two-repo
pass_test "no-option two-repo default claim is byte-compatible"

narrow_repo="$TMP/narrow"
new_repo "$narrow_repo"
run_provision "$narrow_repo" add narrow --claimant Narrow \
	--claim-path tools/conformance/check-one.sh \
	--claim-path docs/evidence/narrow/report.txt >"$TMP/narrow-contract" 2>"$TMP/narrow-log"
cat >"$TMP/narrow-expected" <<'EOF'
# Local claim (worktree-lock model) - the provisioned worktree is the write lock; this file
# records what the claim covers. Default store: port/claims/ (local). See release_claim.sh.
id: narrow
claimant: "Narrow"
EOF
created_line="$(while IFS= read -r line; do case "$line" in created:*) printf '%s' "$line";; esac; done <"$narrow_repo/port/claims/narrow.yaml")"
{
	printf '%s\n' "$created_line" 'state: active' 'paths:' '  - target/'
	printf '%s\n' '  - tools/conformance/check-one.sh' '  - docs/evidence/narrow/report.txt'
} >>"$TMP/narrow-expected"
cmp -s "$TMP/narrow-expected" "$narrow_repo/port/claims/narrow.yaml" \
	|| fail_test "explicit narrow claim contains only authorized paths"
pass_test "explicit narrow paths are accepted without shared defaults"

run_provision "$narrow_repo" add safe-name --claimant Narrow \
	--claim-path 'src/.config/naïve.txt' >"$TMP/safe-name-contract" 2>"$TMP/safe-name-log"
case "$(tail -1 "$narrow_repo/port/claims/safe-name.yaml")" in
	'  - "src/.config/naïve.txt"') ;;
	*) fail_test "safe dotted Unicode path spelling is preserved" ;;
esac
pass_test "safe dotted filenames and ordinary Unicode letters are accepted"

invalid_repo="$TMP/invalid"
new_repo "$invalid_repo"
expect_path_refusal_no_mutation "blanket tools path is refused" "$invalid_repo" blanket-tools tools/
expect_path_refusal_no_mutation "blanket port path is refused" "$invalid_repo" blanket-port port/
expect_path_refusal_no_mutation "blanket docs path is refused" "$invalid_repo" blanket-docs docs/
expect_path_refusal_no_mutation "blanket source path is refused" "$invalid_repo" blanket-source source/
expect_path_refusal_no_mutation "blanket reference path is refused" "$invalid_repo" blanket-reference reference/
expect_path_refusal_no_mutation "blanket target path is refused" "$invalid_repo" blanket-target target/
expect_path_refusal_no_mutation "empty path is refused" "$invalid_repo" empty ""
expect_path_refusal_no_mutation "POSIX absolute path is refused" "$invalid_repo" absolute-posix /absolute/file
expect_path_refusal_no_mutation "root escape is refused" "$invalid_repo" root-escape safe/../../../escape
expect_path_refusal_no_mutation "interior parent segment is refused" "$invalid_repo" interior-parent tools/../narrow.txt
expect_path_refusal_no_mutation "drive-qualified slash path is refused" "$invalid_repo" drive-slash 'C:/absolute.txt'
expect_path_refusal_no_mutation "drive-qualified backslash path is refused" "$invalid_repo" drive-backslash 'D:\absolute.txt'
expect_path_refusal_no_mutation "UNC path is refused" "$invalid_repo" unc-path '\\server\share\file.txt'
expect_path_refusal_no_mutation "star glob is refused" "$invalid_repo" star-glob 'tools/*.sh'
expect_path_refusal_no_mutation "character glob is refused" "$invalid_repo" character-glob 'tools/[ab].sh'
expect_path_refusal_no_mutation "repository root is refused" "$invalid_repo" repository-root .
expect_path_refusal_no_mutation "C0 control character is refused" "$invalid_repo" control-c0 $'tools/\001file'
expect_path_refusal_no_mutation "C1 control character is refused" "$invalid_repo" control-c1 $'tools/\u0085file'
expect_path_refusal_no_mutation "Unicode format character is refused" "$invalid_repo" control-format $'tools/\u202efile'

repair_repo="$TMP/repair"
new_repo "$repair_repo"
run_provision "$repair_repo" add repair --claimant Initial >"$TMP/repair-contract" 2>"$TMP/repair-log"
repair_claim="$repair_repo/port/claims/repair.yaml"
cat >"$repair_claim" <<'EOF'
# Local claim (worktree-lock model) - the provisioned worktree is the write lock; this file
# records what the claim covers. Default store: port/claims/ (local). See release_claim.sh.
id: repair
claimant: 'Original Claimant'
created: "2026-06-01 02:03:04Z"
state: active
source:
  - source/unit.f90
target:
  - target/unit.c
owner:
  team: numeric
# retain this comment before paths
paths: # retain paths comment
  - target/ # retain product comment
  - port/status/repair.yaml # retain status comment
  - docs/evidence/repair/ # retain evidence comment
# retain this trailing comment
other: "value spelling"
EOF
chmod 0640 "$repair_claim"
cat >"$TMP/repair-expected" <<'EOF'
# Local claim (worktree-lock model) - the provisioned worktree is the write lock; this file
# records what the claim covers. Default store: port/claims/ (local). See release_claim.sh.
id: repair
claimant: 'Original Claimant'
created: "2026-06-01 02:03:04Z"
state: active
source:
  - source/unit.f90
target:
  - target/unit.c
owner:
  team: numeric
# retain this comment before paths
# Explicit claim paths set by provision_worker.sh reconcile.
paths: # retain paths comment
  - target/ # retain product comment
  - tools/conformance/narrow.sh # retain status comment
  - docs/evidence/repair/report.txt # retain evidence comment
# retain this trailing comment
other: "value spelling"
EOF
run_provision "$repair_repo" reconcile repair \
	--claim-path tools/conformance/narrow.sh \
	--claim-path docs/evidence/repair/report.txt >"$TMP/reconcile-output" 2>"$TMP/reconcile-log"
cmp -s "$TMP/repair-expected" "$repair_claim" || {
	diff -u "$TMP/repair-expected" "$repair_claim" >&2 || true
	fail_test "reconciliation preserves non-path bytes"
}
[ "$(stat -c '%a' "$repair_claim")" = 640 ] || fail_test "reconciliation preserves file mode"
cp "$repair_claim" "$TMP/repair-once"
run_provision "$repair_repo" reconcile repair \
	--claim-path tools/conformance/narrow.sh \
	--claim-path docs/evidence/repair/report.txt >"$TMP/reconcile-second-output" 2>"$TMP/reconcile-second-log"
cmp -s "$TMP/repair-once" "$repair_claim" || fail_test "second reconciliation is byte-idempotent"
pass_test "exact legacy claim reconciles narrowly and preserves metadata"

threaded_repo="$TMP/threaded"
new_repo "$threaded_repo"
mkdir -p "$threaded_repo/tools/scoping"
cat >"$threaded_repo/tools/scoping/dependency-map.yaml" <<'EOF'
nodes:
  - id: threaded
    source: source/threaded.f90
EOF
run_provision "$threaded_repo" add threaded --claimant "Threaded User" >"$TMP/threaded-contract" 2>"$TMP/threaded-log"
threaded_claim="$threaded_repo/port/claims/threaded.yaml"
(cd "$threaded_repo" && python3 "$THREAD_LEDGER" record threaded --role worker --task-id ses_worker123) \
	>"$TMP/threaded-ledger-output" 2>"$TMP/threaded-ledger-log"
IFS= read -r threaded_first_line <"$threaded_claim"
case "$threaded_first_line" in \#*) fail_test "thread ledger should normalize away the provisioner header" ;; esac
cp "$threaded_claim" "$TMP/threaded-before"
run_provision "$threaded_repo" reconcile threaded \
	--claim-path tools/conformance/narrow.sh \
	--claim-path docs/evidence/threaded/report.txt >"$TMP/threaded-reconcile-output" 2>"$TMP/threaded-reconcile-log"
python3 - "$TMP/threaded-before" "$threaded_claim" <<'PY' || fail_test "threaded reconciliation changed non-path metadata"
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as fh:
    before = yaml.safe_load(fh)
with open(sys.argv[2], encoding="utf-8") as fh:
    after = yaml.safe_load(fh)
before["paths"] = ["target/", "tools/conformance/narrow.sh", "docs/evidence/threaded/report.txt"]
if after != before or after.get("threads") != {"worker": "ses_worker123"}:
    raise SystemExit(1)
PY
cp "$threaded_claim" "$TMP/threaded-once"
run_provision "$threaded_repo" reconcile threaded \
	--claim-path tools/conformance/narrow.sh \
	--claim-path docs/evidence/threaded/report.txt >"$TMP/threaded-second-output" 2>"$TMP/threaded-second-log"
cmp -s "$TMP/threaded-once" "$threaded_claim" || fail_test "threaded second reconciliation is not byte-idempotent"
pass_test "provisioned claim survives thread-ledger normalization and reconciles narrowly"

forged_repo="$TMP/forged"
new_repo "$forged_repo"
run_provision "$forged_repo" add forged --claimant Initial >"$TMP/forged-contract" 2>"$TMP/forged-log"
forged_claim="$forged_repo/port/claims/forged.yaml"

write_headerless_claim "$forged_claim" forged
printf '%s\n' 'unexpected: forged' >>"$forged_claim"
expect_reconcile_refusal_no_mutation "headerless unknown metadata is refused unchanged" "$forged_repo" forged

write_headerless_claim "$forged_claim" forged
sed -i '/^claimant:/d' "$forged_claim"
expect_reconcile_refusal_no_mutation "headerless missing metadata is refused unchanged" "$forged_repo" forged

write_headerless_claim "$forged_claim" forged
sed -i 's/^created:.*/created: yesterday/' "$forged_claim"
expect_reconcile_refusal_no_mutation "headerless malformed created metadata is refused unchanged" "$forged_repo" forged

write_headerless_claim "$forged_claim" forged
sed -i 's/^id: forged$/id: another/' "$forged_claim"
expect_reconcile_refusal_no_mutation "headerless mismatched id is refused unchanged" "$forged_repo" forged

write_headerless_claim "$forged_claim" forged
sed -i '/^threads:/,$d' "$forged_claim"
expect_reconcile_refusal_no_mutation "headerless missing threads are refused unchanged" "$forged_repo" forged

write_headerless_claim "$forged_claim" forged
sed -i 's/^  worker:/  integrator:/' "$forged_claim"
expect_reconcile_refusal_no_mutation "headerless unknown thread role is refused unchanged" "$forged_repo" forged

write_headerless_claim "$forged_claim" forged
sed -i 's/ses_worker123/worker-name/' "$forged_claim"
expect_reconcile_refusal_no_mutation "headerless invalid thread handle is refused unchanged" "$forged_repo" forged

write_headerless_claim "$forged_claim" forged
sed -i 's#port/status/forged.yaml#tools/#' "$forged_claim"
expect_reconcile_refusal_no_mutation "headerless wrong legacy paths are refused unchanged" "$forged_repo" forged

write_headerless_claim "$forged_claim" forged
sed -i 's/^state: active$/state: stale/' "$forged_claim"
expect_reconcile_refusal_no_mutation "headerless stale state is refused unchanged" "$forged_repo" forged

write_headerless_claim "$forged_claim" forged
git -C "$forged_repo/.worktrees/forged" switch -q -c unrelated-forged
expect_reconcile_refusal_no_mutation "headerless wrong-branch claim is refused unchanged" "$forged_repo" forged
git -C "$forged_repo/.worktrees/forged" switch -q work/forged

write_headerless_claim "$forged_claim" forged
git -C "$forged_repo" worktree remove "$forged_repo/.worktrees/forged"
expect_reconcile_refusal_no_mutation "headerless orphan claim is refused unchanged" "$forged_repo" forged

run_provision "$repair_repo" add wrong-branch --claimant Initial >"$TMP/wrong-contract" 2>"$TMP/wrong-log"
wrong_claim="$repair_repo/port/claims/wrong-branch.yaml"
cp "$wrong_claim" "$TMP/wrong-before"
git -C "$repair_repo/.worktrees/wrong-branch" switch -q -c unrelated-branch
expect_refusal "wrong-branch reconciliation is refused" "$repair_repo" reconcile wrong-branch --claim-path tools/conformance/narrow.sh
cmp -s "$TMP/wrong-before" "$wrong_claim" || fail_test "wrong-branch refusal changes claim"

run_provision "$repair_repo" add broadened --claimant Initial >"$TMP/broad-contract" 2>"$TMP/broad-log"
broad_claim="$repair_repo/port/claims/broadened.yaml"
printf '%s\n' '  - tools/' >>"$broad_claim"
cp "$broad_claim" "$TMP/broad-before"
expect_refusal "pre-broadened reconciliation is refused" "$repair_repo" reconcile broadened --claim-path tools/conformance/narrow.sh
cmp -s "$TMP/broad-before" "$broad_claim" || fail_test "pre-broadened refusal changes claim"

run_provision "$repair_repo" add preauthorized --claimant Initial >"$TMP/preauthorized-contract" 2>"$TMP/preauthorized-log"
preauthorized_claim="$repair_repo/port/claims/preauthorized.yaml"
cat >"$preauthorized_claim" <<'EOF'
# Local claim (worktree-lock model) - the provisioned worktree is the write lock; this file
# records what the claim covers. Default store: port/claims/ (local). See release_claim.sh.
id: preauthorized
claimant: "Initial"
created: 2026-06-01T02:03:04Z
state: active
paths:
  - target/
  - tools/conformance/narrow.sh
EOF
cp "$preauthorized_claim" "$TMP/preauthorized-before"
expect_refusal "unmarked requested paths are treated as pre-broadened" "$repair_repo" reconcile preauthorized --claim-path tools/conformance/narrow.sh
cmp -s "$TMP/preauthorized-before" "$preauthorized_claim" || fail_test "unmarked pre-broadened refusal changes claim"

run_provision "$repair_repo" add stale --claimant Initial >"$TMP/stale-contract" 2>"$TMP/stale-log"
stale_claim="$repair_repo/port/claims/stale.yaml"
sed -i 's/^state: active$/state: stale/' "$stale_claim"
cp "$stale_claim" "$TMP/stale-before"
expect_refusal "stale reconciliation is refused" "$repair_repo" reconcile stale --claim-path tools/conformance/narrow.sh
cmp -s "$TMP/stale-before" "$stale_claim" || fail_test "stale refusal changes claim"

run_provision "$repair_repo" add orphan --claimant Initial >"$TMP/orphan-contract" 2>"$TMP/orphan-log"
orphan_claim="$repair_repo/port/claims/orphan.yaml"
cp "$orphan_claim" "$TMP/orphan-before"
git -C "$repair_repo" worktree remove "$repair_repo/.worktrees/orphan"
expect_refusal "orphan reconciliation is refused" "$repair_repo" reconcile orphan --claim-path tools/conformance/narrow.sh
cmp -s "$TMP/orphan-before" "$orphan_claim" || fail_test "orphan refusal changes claim"

branch_repo="$TMP/branch-diff"
new_repo "$branch_repo"
branch_base="$(git -C "$branch_repo" rev-parse HEAD)"
run_provision "$branch_repo" add branch-diff --claimant Branch \
	--claim-path allowed/file.txt >"$TMP/branch-contract" 2>"$TMP/branch-log"
printf '%s\n' unrelated >"$branch_repo/.worktrees/branch-diff/unrelated.txt"
git -C "$branch_repo/.worktrees/branch-diff" add unrelated.txt
git -C "$branch_repo/.worktrees/branch-diff" commit -q -m "touch unrelated file"
set +e
branch_output="$(cd "$branch_repo" && python3 "$CLAIMS_CHECK" \
	--claims-dir "$branch_repo/port/claims" --claim branch-diff \
	--branch work/branch-diff --base "$branch_base" 2>&1)"
branch_rc=$?
set -e
[ "$branch_rc" -eq 1 ] || {
	printf 'not ok - unrelated branch file should be RED (got %s)\n%s\n' "$branch_rc" "$branch_output" >&2
	exit 1
}
case "$branch_output" in *"branch touched 'unrelated.txt' outside claim 'branch-diff' write surface"*) ;; *)
	printf 'not ok - branch-diff did not name the unrelated file\n%s\n' "$branch_output" >&2
	exit 1
esac
pass_test "unrelated branch files remain RED under claim branch-diff"
