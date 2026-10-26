#!/usr/bin/env bash
# Test the identity and claim rules of check-status-fragments.sh.
#
# A dispatched worker cannot see its own session id: the orchestrator records author_id from the
# worker's Task result, in the same step that records the resume thread threads.worker in the local
# claim port/claims/<id>.yaml. So:
#   - an in-progress fragment with author_id: null is the expected state, not a defect. Requiring it
#     there pushed workers to invent an identity to get the check green. A proven fragment still
#     requires author_id.
#   - the claim a fragment cites must be its own (port/claims/<id>.yaml or refs/claims/<id>); a ref
#     to another unit's claim is a fragment copied from a sibling.
#   - when the local claim is present and records threads.worker, a non-null author_id must equal it:
#     the two are copies of one session id, and a mismatch is an identity that did not come from the
#     dispatch. The claim is local and gitignored - absent in CI and once released - so an absent claim,
#     or one with no recorded worker, is not a finding. A claim that cannot be read is RED.
#   - reviewer_id and author_id are compared as the data the TRACE generator reads, so a reviewer_id
#     that is an alias of the author_id (`&w` / `*w`) is the same identity; an identity field holds
#     one value, so a list in its place (block or inline) is refused, never compared as text.
#   - without PyYAML no fragment can be read, which is UNRELIABLE, never a pass.
# Revert the rules and the null-author, wrong-unit-claim, mismatch, stray-key, unreadable-claim,
# alias and no-PyYAML cases go RED; the absent-claim, no-worker and own-claim cases stay green either way.
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
mkdir -p "$W/port/status" "$W/port/claims"
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

claim() { # claim <id> [extra YAML appended verbatim]; the only claim in port/claims/, so each case
	# meets a ledger of its own (the reader validates the whole claims dir)
	rm -f "$W/port/claims/"*.yaml
	printf 'id: %s\nclaimant: operator\ncreated: 2026-01-01T00:00:00Z\nstate: active\n%s' "$1" "${2:-}" \
		>"$W/port/claims/$1.yaml"
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

# ---- author_id agrees with the worker session the claim records ----------------------------------------
claim u7 $'threads:\n  worker: ses_workerA1\n  reviewer: ses_reviewerB2\n'
frag u7 proven ses_workerA1
expect 0 "author_id equal to the claim's threads.worker passes" u7
claim u8 $'threads:\n  worker: ses_workerA1\n'
frag u8 in-progress ses_typedByHand
EXPECT_OUT="does not match the worker session" expect 1 "author_id differing from the claim's threads.worker is refused" u8
frag u10 proven ses_workerA1
expect 0 "an absent claim (CI, or released) is not a finding" u10
claim u11 $'paths:\n  - port/status/u11.yaml\n'
frag u11 in-progress ses_workerA1
expect 0 "a claim with no recorded threads is not a finding" u11
claim u12 $'threads:\n  reviewer: ses_reviewerB2\n'
frag u12 in-progress ses_workerA1
expect 0 "a claim with no recorded worker is not a finding" u12
claim u13 $'threads:\n  worker: ses_workerA1\n'
frag u13 in-progress null
expect 0 "a null author_id beside a recorded worker is not a finding" u13
claim u14 $'threads: {worker: ses_workerA1}\n'
frag u14 in-progress ses_workerA1
expect 0 "the claim is read as YAML (flow-style threads match)" u14
claim u15 $'worker: ses_typedByHand\nthreads:\n  worker: ses_workerA1\n'
frag u15 in-progress ses_typedByHand
EXPECT_OUT="does not match the worker session" expect 1 "only threads.worker counts, not a stray top-level worker key" u15
claim u16 $'threads:\n  worker: ses_workerA1\nthreads:\n  worker: ses_typedByHand\n'
frag u16 in-progress ses_typedByHand
EXPECT_OUT="cannot vouch for author_id" expect 1 "a claim with a duplicate key cannot vouch for author_id" u16
claim u17 $'threads: [ses_workerA1]\n'
frag u17 in-progress ses_workerA1
EXPECT_OUT="cannot vouch for author_id" expect 1 "a claim whose threads is not a mapping cannot vouch for author_id" u17
claim u18 $'threads:\n  worker: kha-worker-u18\n'
frag u18 in-progress kha-worker-u18
EXPECT_OUT="cannot vouch for author_id" expect 1 "a worker thread that is no session id cannot vouch, even when author_id equals it" u18
claim u19 $'threads:\n  worker: ses_shared1\n'
printf 'id: u20\nclaimant: operator\ncreated: 2026-01-01T00:00:00Z\nstate: active\nthreads:\n  worker: ses_shared1\n' \
	>"$W/port/claims/u20.yaml"
frag u19 in-progress ses_shared1
EXPECT_OUT="cannot vouch for author_id" expect 1 "a session recorded as the worker of two pieces cannot vouch for author_id" u19

# ---- reviewer_id is compared as data: an alias of author_id is the same identity -----------------------
rm -f "$W/port/claims/"*.yaml
edit() { sed "$2" "$1" >"$1.tmp" && mv "$1.tmp" "$1"; } # edit <file> <sed script>
frag u21 proven ses_workerA1
edit "$W/port/status/u21.yaml" 's/^author_id: ses_workerA1$/author_id: \&w ses_workerA1/; s/^reviewer_id: ses_reviewerB2$/reviewer_id: *w/'
EXPECT_OUT="reviewer_id == author_id ('ses_workerA1') - independence violated" \
	expect 1 "a reviewer_id that is an alias of author_id is refused" u21
frag u22 proven ses_workerA1
edit "$W/port/status/u22.yaml" 's/^reviewer_id: ses_reviewerB2$/reviewer_id: \&r ses_reviewerB2/; s/^reviewer_session: ses_reviewerB2$/reviewer_session: *r/'
expect 0 "an alias of a distinct reviewer passes (control)" u22

# ---- an identity field holds one value: a list, block or inline, is refused -------------------------------
# Compared as the text of a list, `reviewer_session: [<an author session>]` never equals that session,
# so the independence rules passed it.
idlist=0
for field in author_id reviewer_id reviewer_session; do
	for form in block inline; do
		idlist=$((idlist + 1))
		frag "l$idlist" proven ses_workerA1
		if [ "$form" = block ]; then value='\n  - ses_workerA1' a=a; else value=' [ses_workerA1]' a=an; fi
		edit "$W/port/status/l$idlist.yaml" "s/^$field: .*\$/$field:$value/"
		EXPECT_OUT="'$field' must be a single value, not a list" \
			expect 1 "$field as $a $form list naming the author session is refused" "l$idlist"
	done
done

# ---- no PyYAML: no fragment can be read, which is never a pass ----------------------------------------
mkdir -p "$TMP/noyaml"
printf 'raise ImportError("PyYAML hidden by the test")\n' >"$TMP/noyaml/yaml.py"
claim u7 $'threads:\n  worker: ses_workerA1\n  reviewer: ses_reviewerB2\n'
EXPECT_OUT="UNRELIABLE" expect 2 "without PyYAML a present claim makes the check UNRELIABLE" u7 PYTHONPATH="$TMP/noyaml"
EXPECT_OUT="UNRELIABLE" expect 2 "without PyYAML a fragment with no claim beside it is UNRELIABLE too" u10 PYTHONPATH="$TMP/noyaml"

[ "$failed" -eq 0 ] || { printf '# test-status-fragment-identity: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-status-fragment-identity: all assertions passed\n'
