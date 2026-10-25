#!/usr/bin/env bash
# Test tools/coordination/stamp_author_id.py.
#
# The orchestrator records a worker's session twice: the resume thread in the claim and the committed
# identity in the status fragment. stamp_author_id.py derives the second from the first. The cases prove
# that a template-shaped fragment the fragment check rejects (placeholder author_id, inline empty
# author_sessions) is stamped into one it accepts, with comments kept; that a trailing-comment placeholder
# (failure mode B16) is stamped too; that a second run changes nothing; that a fresh rework session is
# appended without replacing the first author; and that it refuses - leaving the fragment byte-identical -
# a fabricated author_id, a worker thread that is the reviewer, a claim with no worker thread, a fragment
# of another piece, a session reused across pieces, and (UNRELIABLE) a malformed fragment. Without the
# tool every case goes RED.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STAMP="$ROOT/tools/coordination/stamp_author_id.py"
CHECK="$ROOT/tools/conformance/check-status-fragments.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass() { printf 'ok - %s\n' "$1"; }
failt() { printf 'not ok - %s\n' "$1" >&2; [ -f "$TMP/out" ] && sed 's/^/    /' "$TMP/out" >&2; exit 1; }

REPO="$TMP/repo"
mkdir -p "$REPO/port/status" "$REPO/port/claims"
git -C "$REPO" init -q -b main

# fragment <id> <author_id line> <author_sessions line> [reviewer] : a proven fragment shaped like the template.
fragment() {
	local rev="${4:-ses_Rev1}"
	cat >"$REPO/port/status/$1.yaml" <<EOF
# Status fragment - fixture.
id: $1
source: src/$1.f90
target: [$1.c]
status: proven
ownership:
  kind: leaf
  workstream: null
  owned_surface: null
depends_on: []
provides_contract: null
consumes_contracts: []
$2
author_team: null
$3
reviewer_id: $rev
reviewer_team: null
reviewer_session: $rev
claim:
  ref: port/claims/$1.yaml
  claimant: tester
  state: active
proof:
  tier: R1
  validation: null
  commit: abc1234
  evidence: evidence/$1/proof.log
review:
  evidence: evidence/$1/report.md
  targets: []
integration:
  state: null
  epoch_certificate: null
notes: []
EOF
}

# claim <id> [worker-ses] : a local claim, with the worker thread when given.
claim() {
	{
		printf 'id: %s\nclaimant: tester\nstate: active\n' "$1"
		[ -z "${2:-}" ] || printf 'threads:\n  worker: %s\n' "$2"
	} >"$REPO/port/claims/$1.yaml"
}

stamp() {
	local rc
	set +e
	(cd "$REPO" && python3 "$STAMP" "$@") >"$TMP/out" 2>&1
	rc=$?
	set -e
	printf '%s' "$rc"
}
check_rc() {
	local rc
	set +e
	(cd "$REPO" && bash "$CHECK" "port/status/$1.yaml") >"$TMP/check-out" 2>&1
	rc=$?
	set -e
	printf '%s' "$rc"
}
field() { sed -n "s/^$2: *//p" "$REPO/port/status/$1.yaml"; }
items() { sed -n '/^author_sessions:/,/^[a-z_]*:/{/^  - /s/^  - //p}' "$REPO/port/status/$1.yaml" | paste -sd, -; }

# 1. Template-shaped fragment: placeholder author_id, inline empty author_sessions with a comment.
claim alpha ses_Work1
fragment alpha "author_id: <the worker's ses_ id - the orchestrator records it from the Task result>" \
	"author_sessions: []            # block list; orchestrator-recorded"
[ "$(check_rc alpha)" = 1 ] || failt "fixture: the fragment check should reject the unstamped fragment"
[ "$(stamp alpha)" = 0 ] || failt "stamping a template-shaped fragment refused"
[ "$(field alpha author_id)" = "ses_Work1" ] || failt "author_id not stamped (got '$(field alpha author_id)')"
[ "$(items alpha)" = "ses_Work1" ] || failt "author_sessions block not written (got '$(items alpha)')"
grep -q '^author_sessions: *# block list; orchestrator-recorded$' "$REPO/port/status/alpha.yaml" \
	|| failt "the author_sessions comment was not kept"
grep -q '^# Status fragment - fixture.$' "$REPO/port/status/alpha.yaml" || failt "the file comment was not kept"
[ "$(check_rc alpha)" = 0 ] || { cp "$TMP/check-out" "$TMP/out"; failt "the fragment check rejects the stamped fragment"; }
pass "a template-shaped fragment is stamped into one the fragment check accepts, comments kept"

# 2. Idempotent.
cp "$REPO/port/status/alpha.yaml" "$TMP/alpha.before"
[ "$(stamp alpha)" = 0 ] || failt "a second stamp refused"
cmp -s "$TMP/alpha.before" "$REPO/port/status/alpha.yaml" || failt "a second stamp changed the fragment"
grep -q 'already current' "$TMP/out" || failt "a second stamp did not report 'already current'"
pass "a second run changes nothing"

# 3. The B16 shape: a placeholder carrying a trailing comment, no author_sessions key at all.
claim beta ses_Work2
fragment beta "author_id: null  # the orchestrator records this" ""
[ "$(stamp beta)" = 0 ] || failt "a trailing-comment placeholder was refused"
grep -q '^author_id: ses_Work2  # the orchestrator records this$' "$REPO/port/status/beta.yaml" \
	|| failt "a trailing-comment placeholder was not stamped in place"
[ "$(items beta)" = "ses_Work2" ] || failt "a missing author_sessions was not added (got '$(items beta)')"
[ "$(check_rc beta)" = 0 ] || { cp "$TMP/check-out" "$TMP/out"; failt "the fragment check rejects the stamped fragment"; }
pass "a placeholder with a trailing comment is stamped; a missing author_sessions is added"

# 4. A fresh rework session: the first author stays, the new session is appended.
claim alpha ses_Work3
[ "$(stamp alpha)" = 0 ] || failt "a fresh rework session was refused"
[ "$(field alpha author_id)" = "ses_Work1" ] || failt "the first author was replaced (got '$(field alpha author_id)')"
[ "$(items alpha)" = "ses_Work1,ses_Work3" ] || failt "the rework session was not appended (got '$(items alpha)')"
pass "a fresh rework session is appended to author_sessions; author_id keeps the first worker"

# Refusals leave the fragment byte-identical.
refuses() {   # <label> <expected-rc> <id>
	cp "$REPO/port/status/$3.yaml" "$TMP/frag.before"
	local rc
	rc="$(stamp "$3")"
	[ "$rc" = "$2" ] || failt "$1: exit $rc, expected $2"
	cmp -s "$TMP/frag.before" "$REPO/port/status/$3.yaml" || failt "$1: the fragment was modified"
	pass "$1"
}

claim gamma ses_Work4
fragment gamma "author_id: worker" "author_sessions: []"
refuses "a fabricated (non-session) author_id is refused, never overwritten" 1 gamma

claim delta ses_Rev2
fragment delta "author_id: null" "author_sessions: []" ses_Rev2
refuses "a worker thread that is the piece's reviewer is refused" 1 delta

claim epsilon
fragment epsilon "author_id: null" "author_sessions: []"
refuses "a claim with no worker thread is refused" 1 epsilon

claim zeta ses_Work5
fragment zeta "author_id: null" "author_sessions: []"
sed 's/^id: zeta$/id: other/' "$REPO/port/status/zeta.yaml" >"$TMP/zeta" && mv "$TMP/zeta" "$REPO/port/status/zeta.yaml"
refuses "a fragment whose id is another piece's is refused" 1 zeta

claim eta ses_Work5
fragment eta "author_id: null" "author_sessions: []"
refuses "a session recorded under two pieces is refused (thread-ledger invariant)" 1 eta
rm -f "$REPO/port/claims/eta.yaml" "$REPO/port/claims/zeta.yaml"

claim theta ses_Work6
fragment theta "author_id: null" "author_sessions: []"
printf 'status: proven\n' >>"$REPO/port/status/theta.yaml"
refuses "a malformed (duplicate-key) fragment is UNRELIABLE" 2 theta

echo "stamp-author-id: all cases passed"
