#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# Test tools/coordination/stamp_author_id.py.
#
# The orchestrator records a worker's session twice: the resume thread in the claim and the committed
# identity in the status fragment. stamp_author_id.py derives the second from the first. The cases prove
# that a template-shaped fragment the fragment check rejects (placeholder author_id, inline empty
# author_sessions) is stamped into one it accepts, with comments kept; that a trailing-comment placeholder
# (failure mode B16) is stamped too; that a second run changes nothing; that after a fresh rework session
# author_id names the recorded worker while the prior author stays in author_sessions; that an existing
# block list keeps every line, item comments included, with only one item added; and that it
# refuses - leaving the fragment byte-identical - a fabricated author_id, a worker thread that is the
# reviewer, a claim with no worker thread, a fragment of another piece, a session reused across pieces,
# (UNRELIABLE) a malformed fragment, and every existing identity that is not provably this piece's author:
# another piece's worker kept as author_id or listed in author_sessions, a non-session author_sessions
# item, an author_id absent from author_sessions, and an author_id that is the piece's reviewer. Without
# the tool every case goes RED.
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
items() { sed -n '/^author_sessions:/,/^[a-z_]*:/{/^  - /{s/^  - //;s/[[:space:]]*#.*$//;p;}}' "$REPO/port/status/$1.yaml" | paste -sd, -; }

# 1. Template-shaped fragment: placeholder author_id, inline empty author_sessions with a comment.
claim alpha ses_Work1
fragment alpha "author_id: <the worker's ses_ id - the orchestrator records it from the subagent result>" \
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

# 4. A fresh rework session: author_id names the recorded worker, the prior author stays in author_sessions.
claim alpha ses_Work3
[ "$(stamp alpha)" = 0 ] || failt "a fresh rework session was refused"
[ "$(field alpha author_id)" = "ses_Work3" ] || failt "author_id is not the recorded worker (got '$(field alpha author_id)')"
[ "$(items alpha)" = "ses_Work1,ses_Work3" ] || failt "the prior author was not kept or the rework session not appended (got '$(items alpha)')"
[ "$(check_rc alpha)" = 0 ] || { cp "$TMP/check-out" "$TMP/out"; failt "the fragment check rejects the stamped fragment"; }
pass "after a fresh rework session author_id is the recorded worker; the prior author stays in author_sessions"

# 5. An existing block list keeps every line byte-for-byte, item comments included: the stamp changes the
#    author_id value and inserts one item after the last one, and nothing else.
claim pi ses_New1
fragment pi "author_id: ses_Prior2  # set at first dispatch" $'author_sessions:   # orchestrator-recorded\n  - ses_Prior1  # first worker\n  # same piece, later session\n  - ses_Prior2  # resumed'
cp "$REPO/port/status/pi.yaml" "$TMP/pi.before"
[ "$(stamp pi)" = 0 ] || failt "stamping a commented block list refused"
diff -U0 "$TMP/pi.before" "$REPO/port/status/pi.yaml" | grep -E '^[-+]' | grep -vE '^(---|\+\+\+) ' >"$TMP/pi.diff" || true
printf '%s\n' '-author_id: ses_Prior2  # set at first dispatch' '+author_id: ses_New1  # set at first dispatch' \
	'+  - ses_New1' >"$TMP/pi.expected"
cmp -s "$TMP/pi.expected" "$TMP/pi.diff" || { diff "$TMP/pi.expected" "$TMP/pi.diff" >"$TMP/out" || true; failt "the stamp changed more than the author_id value and one added item"; }
[ "$(check_rc pi)" = 0 ] || { cp "$TMP/check-out" "$TMP/out"; failt "the fragment check rejects the stamped fragment"; }
cp "$REPO/port/status/pi.yaml" "$TMP/pi.stamped"
[ "$(stamp pi)" = 0 ] && cmp -s "$TMP/pi.stamped" "$REPO/port/status/pi.yaml" || failt "a second stamp changed the commented block"
pass "an existing block list keeps its item comments; only author_id and one added item change"

claim rho ses_New2
fragment rho "author_id: null" $'author_sessions:\n  - ses_Prior3  # keep-this-comment'
[ "$(stamp rho)" = 0 ] || failt "stamping a single commented item refused"
grep -qx '  - ses_Prior3  # keep-this-comment' "$REPO/port/status/rho.yaml" || failt "an item comment was dropped"
[ "$(items rho)" = "ses_Prior3,ses_New2" ] || failt "the session was not appended after the commented item (got '$(items rho)')"
pass "a commented single item keeps its comment"

claim tau ses_Tau1
fragment tau "author_id: null" "author_sessions: [ses_Tau1]  # inline"
[ "$(stamp tau)" = 0 ] || failt "stamping an inline list that already holds the worker refused"
[ "$(items tau)" = "ses_Tau1" ] || failt "an inline list holding the worker was left inline (block items '$(items tau)')"
[ "$(check_rc tau)" = 0 ] || { cp "$TMP/check-out" "$TMP/out"; failt "the fragment check rejects the stamped fragment"; }
pass "an inline list is rewritten as a block even when it already holds the worker"

# Refusals leave the fragment byte-identical.
refuses() {   # <label> <expected-rc> <id> [expected message fragment]
	cp "$REPO/port/status/$3.yaml" "$TMP/frag.before"
	local rc
	rc="$(stamp "$3")"
	[ "$rc" = "$2" ] || failt "$1: exit $rc, expected $2"
	cmp -s "$TMP/frag.before" "$REPO/port/status/$3.yaml" || failt "$1: the fragment was modified"
	[ -z "${4:-}" ] || grep -qF -- "$4" "$TMP/out" || failt "$1: refused for another reason (expected '$4')"
	pass "$1"
}

claim gamma ses_Work4
fragment gamma "author_id: worker" "author_sessions: []"
refuses "a non-session author_id is refused, never overwritten" 1 gamma

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

# Existing identities that are not provably this piece's author.
claim iota ses_Iota1
claim kappa ses_Kappa1
fragment iota "author_id: ses_Kappa1" $'author_sessions:\n  - ses_Kappa1'
refuses "another piece's recorded worker as author_id and sole author session is refused" 1 iota "recorded worker thread of 'kappa'"

claim omicron ses_Omicron1
fragment omicron "author_id: ses_Kappa1" "author_sessions: []"
refuses "another piece's recorded worker kept as author_id is refused" 1 omicron "author_id ses_Kappa1 is the recorded worker thread of 'kappa'"

claim lambda ses_Lambda1
fragment lambda "author_id: null" $'author_sessions:\n  - ses_Kappa1'
refuses "another piece's recorded worker listed in author_sessions is refused" 1 lambda "recorded worker thread of 'kappa'"

claim mu ses_Mu1
fragment mu "author_id: null" $'author_sessions:\n  - worker'
refuses "a non-session author_sessions item is refused" 1 mu "is not a session id"

claim nu ses_Nu1
fragment nu "author_id: ses_Unlisted1" "author_sessions: []"
refuses "an author_id that is neither the recorded worker nor in author_sessions is refused" 1 nu "is not in author_sessions"

claim xi ses_Xi1
fragment xi "author_id: ses_Rev1" $'author_sessions:\n  - ses_Rev1'
refuses "an existing author identity that is the piece's reviewer is refused" 1 xi "an author can never be its reviewer"

claim sigma ses_Sigma1
fragment sigma "author_id: null" $'author_sessions: [ses_SigmaPrior1,\n    ses_SigmaPrior2]'
refuses "an inline list spread over several lines is refused, not rewritten" 1 sigma "rewrite it as a block list by hand"

claim tau2 ses_Tau2
fragment tau2 "author_id: null" $'author_sessions:\n  - "ses_Tau2 "'
refuses "an author_sessions item with surrounding whitespace is refused, by name" 1 tau2 "has surrounding whitespace"

# A Phase-1 plan unit (layer/kind/evidence, no status or claim) is not a unit status fragment.
claim phi ses_Phi1
printf 'id: phi\nlayer: tools\nkind: proof\ndepends_on: []\nauthor_id: null\nreviewer_id: null\nevidence: {}\n' \
	>"$REPO/port/status/phi.yaml"
refuses "a Phase-1 plan unit is refused, not given author_sessions" 1 phi "is not a unit status fragment"

echo "stamp-author-id: all cases passed"
