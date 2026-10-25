#!/usr/bin/env bash
# The unit vocabulary moved from 'gate / gated' (legacy-vocab) to 'proof / proven'. Ports that have
# not migrated still hold the old names, so this proves, against the real checks and tools:
#   1. the methodology rewrite is a fixed point - re-running it changes nothing (reader aliases are
#      marked and kept);
#   2. every check that reads unit state accepts the OLD names (green), still FIRES on a broken entry
#      written in them (red), and rejects a field recorded under BOTH names (red) - the red-then-green
#      demonstration the changed comparison logic owes;
#   3. the drift check agrees across vocabularies, so an unmigrated port does not go red;
#   4. the data migration changes vocabulary and nothing else: a dry run writes nothing, --apply
#      converts the state, a second run is a no-op, the ledger is untouched, and a file where a text
#      rewrite would alter data is refused.
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
expect() { # expect <exit-code> <label> <command...>; EXPECT_OUT, if set, must also appear in the output
	local want="$1" label="$2" out rc
	shift 2
	set +e; out="$("$@" 2>&1)"; rc=$?; set -e
	if [ "$rc" != "$want" ]; then
		bad "$label (expected exit $want, got $rc)"; [ -n "${KEEP_GOING:-}" ] || printf '%s\n' "$out" >&2
	elif [ -n "${EXPECT_OUT:-}" ] && ! grep -qF -- "$EXPECT_OUT" <<<"$out"; then
		bad "$label (exit $rc as expected, but the output lacks '$EXPECT_OUT')"
	else
		pass "$label"
	fi
}

# ---- 1. the rewrite is a fixed point ----------------------------------------------------------------
out="$(cd "$ROOT" && python3 tools/migrate-proof-vocabulary.py --methodology --base)"
if grep -q 'would rewrite 0 file(s)' <<<"$out"; then pass "re-running the methodology rewrite changes nothing"; else bad "re-running the methodology rewrite changes nothing"; fi

# ---- 2a. check-trace-evidence ---------------------------------------------------------------------------
printf 'VERDICT: clean\n' >"$TMP/review.md"
printf 'R1 differential: bit-identical\n' >"$TMP/proof.md"
trace() { # trace <file> <status> <evidence-key> <tier-key> <commit-key> <tier> [extra line]
	{
		printf 'meta:\n  source_commit: abc\nfiles:\n  - source: a.f90\n    target: [a.c]\n'
		printf '    status: %s\n    %s: %s\n    %s: %s\n    %s: c0ffee\n    review: %s\n' \
			"$2" "$3" "$TMP/proof.md" "$4" "$6" "$5" "$TMP/review.md"
		[ -z "${7:-}" ] || printf '    %s\n' "$7"
	} >"$1"
}
EVID="$ROOT/tools/conformance/check-trace-evidence.sh"
trace "$TMP/t-old.yaml" gated gate gate_tier gate_commit R1                       # legacy-vocab
trace "$TMP/t-new.yaml" proven proof proof_tier proof_commit R1
trace "$TMP/t-old-r0.yaml" gated gate gate_tier gate_commit R0                    # legacy-vocab
trace "$TMP/t-both.yaml" proven proof proof_tier proof_commit R1 "gate_tier: R1"  # legacy-vocab
# "Read" means counted as proven and checked - an entry the check does not recognise would also exit
# 0, having checked nothing.
EXPECT_OUT="1 proven" expect 0 "trace-evidence: a TRACE in the old names is read as proven" env TRACE_FILE="$TMP/t-old.yaml" bash "$EVID"
EXPECT_OUT="1 proven" expect 0 "trace-evidence: a TRACE in the new names is read as proven" env TRACE_FILE="$TMP/t-new.yaml" bash "$EVID"
expect 1 "trace-evidence: an R0 proof in the old names is still refused" env TRACE_FILE="$TMP/t-old-r0.yaml" bash "$EVID"
expect 1 "trace-evidence: a field under both names is refused" env TRACE_FILE="$TMP/t-both.yaml" bash "$EVID"

# ---- 2b. check-status-fragments ----------------------------------------------------------------------
frag() { # frag <file> <status> <block> <tier> [integration-state] [extra block]
	cat >"$1" <<EOF
id: a
source: a.f90
target: [a.c]
status: $2
ownership:
  kind: leaf
claim:
  ref: port/claims/a.yaml
  claimant: w1
  state: active
author_id: w1
author_sessions:
  - ses_author
reviewer_id: r1
reviewer_session: ses_reviewer
$3:
  tier: $4
  commit: c0ffee
  evidence: docs/evidence/a/r1.md
review:
  evidence: docs/evidence/a/review.md
integration:
  state: ${5:-null}
${6:-}
EOF
}
FRAGS="$ROOT/tools/conformance/check-status-fragments.sh"
frag "$TMP/f-old.yaml" gated gate R1 gated                                         # legacy-vocab
frag "$TMP/f-new.yaml" proven proof R1 proven
frag "$TMP/f-old-r0.yaml" gated gate R0                                            # legacy-vocab
frag "$TMP/f-both.yaml" proven proof R1 "" "$(printf 'gate:\n  tier: R1')"         # legacy-vocab
expect 0 "status-fragments: a fragment in the old names is read" bash "$FRAGS" "$TMP/f-old.yaml"
expect 0 "status-fragments: a fragment in the new names is read" bash "$FRAGS" "$TMP/f-new.yaml"
expect 1 "status-fragments: an R0 proof in the old names is still refused" bash "$FRAGS" "$TMP/f-old-r0.yaml"
expect 1 "status-fragments: a block under both names is refused" bash "$FRAGS" "$TMP/f-both.yaml"

# ---- 3. the drift check agrees across vocabularies ----------------------------------------------------
GEN="$ROOT/tools/coordination/generate_trace.py"
mkdir -p "$TMP/status"
cp "$TMP/f-old.yaml" "$TMP/status/a.yaml"
printf 'source_root: source\ntarget_root: target\nsource_commit: abc\n' >"$TMP/status/_meta.yaml"
python3 "$GEN" --status-dir "$TMP/status" --meta "$TMP/status/_meta.yaml" >"$TMP/trace-gen.yaml"
if grep -q '^  status: proven$\|^  *status: proven$' "$TMP/trace-gen.yaml"; then pass "the TRACE generator writes the new names from an old fragment"; else bad "the TRACE generator writes the new names from an old fragment"; fi
OLD_NAMES='s/^\( *\)status: proven$/\1status: gated/; s/^\( *\)proof\(_tier\|_commit\)\?:/\1gate\2:/; s/^\( *\)integration: proven$/\1integration: gated/'  # legacy-vocab
sed -e "$OLD_NAMES" "$TMP/trace-gen.yaml" >"$TMP/trace-old.yaml"
grep -q 'gate_tier' "$TMP/trace-old.yaml" || bad "building the old-names TRACE"  # legacy-vocab
drift() { python3 "$GEN" --check --status-dir "$TMP/status" --meta "$TMP/status/_meta.yaml" --trace "$1"; }
expect 0 "drift: old fragments against a TRACE in the new names agree" drift "$TMP/trace-gen.yaml"
expect 0 "drift: old fragments against a TRACE in the old names agree" drift "$TMP/trace-old.yaml"
sed 's/c0ffee/deadbeef/' "$TMP/trace-old.yaml" >"$TMP/trace-drifted.yaml"
expect 1 "drift: a real difference is still reported across vocabularies" drift "$TMP/trace-drifted.yaml"

# ---- 4. the data migration ------------------------------------------------------------------------------
MIG="$ROOT/tools/migrate-proof-vocabulary.py"
P="$TMP/port"
mkdir -p "$P/port/status" "$P/port/plan"
git -C "$P" init -q
cp "$TMP/trace-old.yaml" "$P/port/TRACE.yaml"
cp "$TMP/f-old.yaml" "$P/port/status/a.yaml"
printf 'level: L2\nscope: [claim, work, review, rework, mark-gated, integrate]\n' >"$P/port/autodrive.yaml"   # legacy-vocab
printf '# Charter\n- auto-gate: clean-only (authorized by H, 2026-01-01)\n' >"$P/port/plan/00-charter.md"   # legacy-vocab
printf '# LESSONS\n### L-0001  the R1 gate caught a gated unit\n' >"$P/port/LESSONS.md"                       # legacy-vocab
printf '# bring-up\n' >"$P/port/bring-up-gate.md"                                                            # legacy-vocab
git -C "$P" add -A && git -C "$P" commit -q -m old
snapshot() { (cd "$P" && find port -type f | sort | xargs sha1sum); }
before="$(snapshot)"
expect 0 "migration: a dry run succeeds" bash -c "cd '$P' && python3 '$MIG'"
if [ "$(snapshot)" = "$before" ]; then pass "migration: a dry run writes nothing"; else bad "migration: a dry run writes nothing"; fi
expect 0 "migration: --apply succeeds" bash -c "cd '$P' && python3 '$MIG' --apply"
if grep -q 'status: proven' "$P/port/TRACE.yaml" && grep -q 'proof_tier' "$P/port/TRACE.yaml" \
	&& grep -q '^proof:' "$P/port/status/a.yaml" && grep -q 'mark-proven' "$P/port/autodrive.yaml" \
	&& grep -q 'auto-prove: clean-only' "$P/port/plan/00-charter.md" && [ -f "$P/port/bring-up-harness.md" ]; then pass "migration: TRACE, fragments, autodrive scope, charter key and bring-up file are converted"; else bad "migration: TRACE, fragments, autodrive scope, charter key and bring-up file are converted"; fi
if [ "$(sed -n 2p "$P/port/LESSONS.md")" = "### L-0001  the R1 gate caught a gated unit" ]; then pass "migration: the append-only ledger is untouched"; else bad "migration: the append-only ledger is untouched"; fi  # legacy-vocab
expect 0 "migration: the converted fragment passes check-status-fragments" bash "$FRAGS" "$P/port/status/a.yaml"
out="$(cd "$P" && python3 "$MIG" --apply)"
if grep -q 'nothing to migrate' <<<"$out"; then pass "migration: a second run is a no-op"; else bad "migration: a second run is a no-op"; fi
# A block-scalar note whose text looks like an old key: a text rewrite would alter the note, so the
# round-trip guard must refuse the file and write nothing.
printf 'id: b\nstatus: in-progress\nnotes: |\n  status: gated was the old word\n' >"$P/port/status/b.yaml"   # legacy-vocab
cp "$P/port/status/b.yaml" "$TMP/b.before"
expect 1 "migration: a rewrite that would change data is refused" bash -c "cd '$P' && python3 '$MIG' --apply"
if cmp -s "$P/port/status/b.yaml" "$TMP/b.before"; then pass "migration: the refused file is left unchanged"; else bad "migration: the refused file is left unchanged"; fi

[ "$failed" -eq 0 ] || { printf '# test-proof-vocabulary: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-proof-vocabulary: all assertions passed\n'
