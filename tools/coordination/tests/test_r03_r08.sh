#!/usr/bin/env bash
# test_r03_r08.sh - discriminating tests for R03 (canonical report paths) and R08 (parked drop)
set -uo pipefail
# Resolve THIS checkout from the script's own location, so the test runs anywhere. Kept
# distinct from REPO_ROOT, which the fixtures below deliberately rebind to a temp repo.
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
say() { echo "$*"; }
check() { local label="$1" rc="$2" expected="$3"; if [ "$rc" -eq "$expected" ]; then echo "[PASS] $label rc $rc"; pass=$((pass+1)); else echo "[FAIL] $label got $rc expected $expected"; fail=$((fail+1)); fi; }

# ---- R03: canonical dated report path ----
# Simulate a worktree with a canonical report docs/evidence/2026-01-02-review-mymod/report.md
WB="$TMP/wb"
mkdir -p "$WB/docs/evidence/2026-01-02-review-mymod"
printf 'verdict: clean\nbody\n' > "$WB/docs/evidence/2026-01-02-review-mymod/report.md"
# Need to be inside a git repo for record_review to resolve REPO
git init -q "$TMP/repo"
# Create .worktrees/mymod as WB and pretend it's a worktree (record_review checks -d)
# Instead, create the structure that record_review expects: it is given --worktree and --trace
TRACE="$TMP/trace.yaml"
cat > "$TRACE" <<'EOF'
files:
  - id: mymod
    source: src/mymod.F90
    status: in-progress
    review: null
EOF
mkdir -p "$TMP/repo/.worktrees/mymod/docs/evidence/2026-01-02-review-mymod"
cp "$WB/docs/evidence/2026-01-02-review-mymod/report.md" "$TMP/repo/.worktrees/mymod/docs/evidence/2026-01-02-review-mymod/report.md"
# Initialize git in the worktree so ls-files/commit works
git -C "$TMP/repo/.worktrees/mymod" init -q 2>/dev/null || true
git -C "$TMP/repo/.worktrees/mymod" config user.email "t@e.st"
git -C "$TMP/repo/.worktrees/mymod" config user.name "T"
# Also need REPO to have a git repo - already init, but record_review does git rev-parse --show-toplevel
# It will find /tmp/repo as REPO, but we want WB to be the worktree we pass explicitly
# Call record_review with explicit --worktree and --trace and --report canonical path explicitly, plus glob discovery
# Test explicit --report finds canonical path
REPO_ROOT="$(git -C "$TMP/repo" rev-parse --show-toplevel)"
# Use the actual workbench root .worktrees/contribute-c0005 as REPO for the script's REPO detection?
# Instead, call via bash with explicit args: it will use WB we pass, so REPO detection not critical if we pass --worktree
# We need a TRACE that has an - id: row so the python part succeeds; we pass --trace pointing to our TRACE file
# Create a minimal git repo at WB so record_review's git -C "$WB" works
git -C "$WB" init -q 2>/dev/null || true
git -C "$WB" config user.email "t@e.st"
git -C "$WB" config user.name "T"
# Now run record_review with canonical path via --report
SCRIPT="$SRC_ROOT/tools/coordination/record_review.sh"
# Test 1: canonical dated path discovered via glob (no --report)
# Use a fresh WB that is also a git repo with the canonical file under docs/evidence/<date>-review-<id>/report.md
TMP_WB="$TMP/wb2"
mkdir -p "$TMP_WB/docs/evidence/2026-01-15-review-unitx"
printf 'verdict: clean\n' > "$TMP_WB/docs/evidence/2026-01-15-review-unitx/report.md"
git -C "$TMP_WB" init -q
git -C "$TMP_WB" config user.email "t@e.st"
git -C "$TMP_WB" config user.name "T"
# Create TRACE with unitx row (solo TRACE uses "- id:" at column 0)
TRACE2="$TMP/trace2.yaml"
cat > "$TRACE2" <<'EOF'
files:
- id: unitx
  source: src/unitx.F90
  status: in-progress
  review: null
EOF
# Need to run record_review with REPO being somewhere that has .worktrees/unitx? We pass --worktree and --trace explicitly, so it will use those
# But script also does REPO="$(git rev-parse --show-toplevel)" which will be TMP_WB's repo (since we are not chdir)
# That's fine; WB existence check passes
set +e
bash "$SCRIPT" unitx --worktree "$TMP_WB" --trace "$TRACE2" >"$TMP/out1.log" 2>&1
rc=$?
set -e
# Should succeed (0) and have found the canonical report via glob
if [ "$rc" -eq 0 ] && grep -q "committed docs/evidence/2026-01-15-review-unitx/report.md" "$TMP/out1.log"; then
    echo "[PASS] R03 canonical dated report path discovered via glob"
    pass=$((pass+1))
else
    echo "[FAIL] R03 canonical dated path not discovered rc=$rc log:"
    cat "$TMP/out1.log"
    fail=$((fail+1))
fi
# Verify TRACE was updated with review path
if grep -q "review: docs/evidence/2026-01-15-review-unitx/report.md" "$TRACE2"; then
    echo "[PASS] R03 TRACE updated with canonical report path"
    pass=$((pass+1))
else
    echo "[FAIL] R03 TRACE not updated"
    cat "$TRACE2"
    fail=$((fail+1))
fi

# Test explicit --report still works
TMP_WB3="$TMP/wb3"
mkdir -p "$TMP_WB3/docs/evidence/custom/path"
printf 'verdict: clean\n' > "$TMP_WB3/docs/evidence/custom/path/report.md"
git -C "$TMP_WB3" init -q
git -C "$TMP_WB3" config user.email "t@e.st"
git -C "$TMP_WB3" config user.name "T"
TRACE3="$TMP/trace3.yaml"
cat > "$TRACE3" <<'EOF'
files:
- id: unitx
  source: src/unitx.F90
  status: in-progress
  review: null
EOF
set +e
bash "$SCRIPT" unitx --worktree "$TMP_WB3" --trace "$TRACE3" --report "docs/evidence/custom/path/report.md" >"$TMP/out2.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q "committed docs/evidence/custom/path/report.md" "$TMP/out2.log"; then
    echo "[PASS] R03 explicit --report path works"
    pass=$((pass+1))
else
    echo "[FAIL] R03 explicit --report failed rc=$rc"
    cat "$TMP/out2.log"
    fail=$((fail+1))
fi

# ---- R08: parked path dropped ----
# Create a minimal plan with integrated:true for unit 'parkedmod' should succeed, but a parked-like TRACE entry
# should NOT authorize release after the drop (must refuse)
TMP_REPO="$TMP/repo_r08"
mkdir -p "$TMP_REPO/port/claims" "$TMP_REPO/port"
git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" config user.email "t@e.st"
git -C "$TMP_REPO" config user.name "T"
cat > "$TMP_REPO/port/phase1-plan.yaml" <<'EOF'
units:
  - id: goodmod
    integrated: true
  - id: parkedmod
    integrated: false
EOF
cat > "$TMP_REPO/port/TRACE.yaml" <<'EOF'
files:
  - id: parkedmod
    source: src/parkedmod.F90
    status: in-progress
    validation: transitive
    review: docs/evidence/2026-01-02-review-parkedmod/report.md
EOF
mkdir -p "$TMP_REPO/docs/evidence/2026-01-02-review-parkedmod"
printf 'verdict: clean\n' > "$TMP_REPO/docs/evidence/2026-01-02-review-parkedmod/report.md"
mkdir -p "$TMP_REPO/port/claims"
printf 'id: parkedmod\nstate: active\n' > "$TMP_REPO/port/claims/parkedmod.yaml"
# Also create a goodmod claim that should succeed
printf 'id: goodmod\nstate: active\n' > "$TMP_REPO/port/claims/goodmod.yaml"
# Need dashboard.py etc for release_claim to run - copy from workbench
cp -r "$SRC_ROOT/tools" "$TMP_REPO/tools" 2>/dev/null || true
cp -r "$SRC_ROOT/tools/coordination" "$TMP_REPO/tools/coordination" 2>/dev/null || true
# Actually tools already there via git? We are in a fresh repo, need the release_claim script and dashboard
# Use the workbench's script directly with --dry-run
RC_SCRIPT="$SRC_ROOT/tools/coordination/release_claim.sh"
set +e
# goodmod should be releasable (integrated true) -> exit 0 dry-run (run from inside TMP_REPO)
( cd "$TMP_REPO" && bash "$RC_SCRIPT" goodmod --dry-run 2>"$TMP/out_good.log" 1>"$TMP/out_good1.log"; echo $? > "$TMP/rc_good" )
rc_good=$(cat "$TMP/rc_good")
# parkedmod should now be refused (exit 2) after dropping parked path
# Need to run from inside TMP_REPO
( cd "$TMP_REPO" && bash "$RC_SCRIPT" parkedmod --dry-run 2>"$TMP/out_park.log" 1>"$TMP/out_park1.log"; echo $? > "$TMP/rc_park" )
rc_park=$(cat "$TMP/rc_park")
set -e
if [ "$rc_good" -eq 0 ]; then
    echo "[PASS] R08 goodmod integrated still releasable"
    pass=$((pass+1))
else
    echo "[FAIL] R08 goodmod should be releasable rc=$rc_good"
    cat "$TMP/out_good.log" "$TMP/out_good1.log"
    fail=$((fail+1))
fi
if [ "$rc_park" -eq 2 ]; then
    echo "[PASS] R08 parkedmod correctly refused after parked path drop (exit 2)"
    pass=$((pass+1))
else
    echo "[FAIL] R08 parkedmod should be refused exit 2 got $rc_park"
    cat "$TMP/out_park.log" "$TMP/out_park1.log"
    fail=$((fail+1))
fi

echo
echo "=== summary: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ]
