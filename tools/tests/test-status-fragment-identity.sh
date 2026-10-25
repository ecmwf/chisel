#!/usr/bin/env bash
# Test the identity and claim rules of check-status-fragments.sh.
#
# A dispatched worker cannot see its own session id: the orchestrator records author_id from the
# worker's Task result. So:
#   - an in-progress fragment with author_id: null is the expected state, not a defect. Requiring it
#     there pushed workers to invent an identity to get the check green. A proven fragment still
#     requires author_id.
#   - the claim a fragment cites must be its own (port/claims/<id>.yaml or refs/claims/<id>); a ref
#     to another unit's claim is a fragment copied from a sibling.
# Revert the rules and the null-author and wrong-unit-claim cases go RED; the own-claim cases stay
# green either way.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/conformance/check-status-fragments.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1

# KEEP_GOING=1 reports every failing case instead of stopping at the first (for a red demonstration).
failed=0
pass() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; [ -n "${KEEP_GOING:-}" ] || exit 1; failed=$((failed + 1)); }

W="$TMP/wb"
mkdir -p "$W/port/status"
git -C "$W" init -q

frag() { # frag <id> <status> <author_id> [claim-ref]
	local id="$1" st="$2" aid="$3" ref="${4:-port/claims/$1.yaml}"
	{
		printf 'id: %s\nsource: %s.f90\ntarget: [%s.c]\nstatus: %s\n' "$id" "$id" "$id" "$st"
		printf 'ownership:\n  kind: leaf\n'
		printf 'author_id: %s\nauthor_sessions:\n  - ses_workerA1\n' "$aid"
		printf 'claim:\n  ref: %s\n  claimant: operator\n  state: active\n' "$ref"
		if [ "$st" = proven ]; then
			printf 'reviewer_id: ses_reviewerB2\nreviewer_session: ses_reviewerB2\n'
			printf 'proof:\n  tier: R1\n  commit: c0ffee\n  evidence: evidence/%s/proof.md\n' "$id"
			printf 'review:\n  evidence: evidence/%s/review.md\n' "$id"
		fi
	} >"$W/port/status/$id.yaml"
}

expect() { # expect <exit-code> <label> <id> [env assignments...]; EXPECT_OUT, if set, must appear
	local want="$1" label="$2" id="$3" out rc
	shift 3
	set +e; out="$(cd "$W" && env "$@" bash "$CHECK" "port/status/$id.yaml" 2>&1)"; rc=$?; set -e
	if [ "$rc" != "$want" ]; then
		bad "$label (expected exit $want, got $rc)"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	elif [ -n "${EXPECT_OUT:-}" ] && ! grep -qF -- "$EXPECT_OUT" <<<"$out"; then
		bad "$label (exit $rc as expected, but the output lacks '$EXPECT_OUT')"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	else
		pass "$label"
	fi
}

# ---- author_id may be null until the piece is proven ------------------------------------------------
frag u1 in-progress null
expect 0 "an in-progress fragment may leave author_id null" u1
frag u2 proven null
EXPECT_OUT="requires 'author_id'" expect 1 "a proven fragment still requires author_id" u2

# ---- the cited claim is the unit's own -----------------------------------------------------------------
frag u3 in-progress ses_workerA1 port/claims/u9.yaml
EXPECT_OUT="is not this unit's claim" expect 1 "a claim.ref naming another unit's claim is refused" u3
frag u4 in-progress null port/claims/u9.yaml
EXPECT_OUT="is not this unit's claim" expect 1 "a claim.ref naming another unit is refused with a null author_id too" u4
frag u5 in-progress ses_workerA1 refs/claims/u5
expect 0 "the pushed-ref form of the unit's own claim is accepted" u5
frag u6 in-progress ses_workerA1 refs/claims/u9
EXPECT_OUT="is not this unit's claim" expect 1 "a pushed ref naming another unit is refused" u6

[ "$failed" -eq 0 ] || { printf '# test-status-fragment-identity: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-status-fragment-identity: all assertions passed\n'
