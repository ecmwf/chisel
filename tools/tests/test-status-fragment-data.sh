#!/usr/bin/env bash
# Test that check-status-fragments.sh judges a fragment's YAML DATA - what the TRACE generator reads -
# not one way of writing it. A line parser accepted only block lists, read a flow list as text, read
# the lines of a block-scalar note as keys, ignored anything nested deeper than two levels and any
# unknown key left empty, and took a quoted "[a.c]" for a list. Each case below is a fragment the
# generator reads one way and the line parser read another; with the parser restored they go RED.
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

# frag <id> <sed script>: a valid proven fragment, edited by the script.
frag() {
	cat <<EOF | sed "$2" >"$W/port/status/$1.yaml"
id: $1
source: $1.f90
target: [$1.c]
status: proven
ownership:
  kind: leaf
author_id: ses_workerA1
author_sessions:
  - ses_workerA1
reviewer_id: ses_reviewerB2
reviewer_session: ses_reviewerB2
claim:
  ref: port/claims/$1.yaml
  claimant: operator
  state: active
proof:
  tier: R1
  commit: c0ffee
  evidence: evidence/$1/proof.md
review:
  evidence: evidence/$1/review.md
notes: []
EOF
}

expect() { # expect <exit-code> <label> <id>; EXPECT_OUT, if set, must appear in the output
	local want="$1" label="$2" id="$3" out rc
	set +e; out="$(cd "$W" && bash "$CHECK" "port/status/$id.yaml" 2>&1)"; rc=$?; set -e
	if [ "$rc" != "$want" ]; then
		bad "$label (expected exit $want, got $rc)"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	elif [ -n "${EXPECT_OUT:-}" ] && ! grep -qF -- "$EXPECT_OUT" <<<"$out"; then
		bad "$label (exit $rc as expected, but the output lacks '$EXPECT_OUT')"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	else
		pass "$label"
	fi
}

frag d0 ''
expect 0 "a valid fragment passes (control)" d0

# ---- lists read the same in block and flow form -----------------------------------------------------
frag d1 's/^target: \[d1.c\]$/target:\n  - d1.c/'
expect 0 "a block-form target is a list" d1
frag d2 's/^author_sessions:$/author_sessions: [ses_workerA1]/; /^  - ses_workerA1$/d'
expect 0 "a flow-form author_sessions is read" d2
frag d3 's/^author_sessions:$/author_sessions: [ses_workerA1, ses_reviewerB2]/; /^  - ses_workerA1$/d'
EXPECT_OUT="reviewer_session 'ses_reviewerB2' appears in author_sessions" \
	expect 1 "a reviewer session in a flow-form author_sessions is refused" d3

# ---- a scalar is a scalar ---------------------------------------------------------------------------
frag d4 's/^target: \[d4.c\]$/target: "[d4.c]"/'
EXPECT_OUT="target must be a list" expect 1 "a quoted \"[a.c]\" target is a string, not a list" d4
frag d5 's/^notes: \[\]$/notes: |\n  reason: kept for the record\n  status: no change/'
expect 0 "the lines of a block-scalar note are text, not keys" d5
frag d6 "s/^status: proven\$/status: 'proven'   # reviewed/"
expect 0 "a quoted value with a comment is its value (control)" d6

# ---- the schema is closed and two levels deep ---------------------------------------------------------
frag d7 's/^  evidence: evidence\/d7\/proof.md$/  evidence:\n    path: evidence\/d7\/proof.md/'
EXPECT_OUT="'proof.evidence' nests deeper than the fragment schema allows" \
	expect 1 "a mapping below a section is refused" d7
frag d11 's/^  evidence: evidence\/d11\/proof.md$/  evidence:\n    - evidence\/d11\/proof.md/'
EXPECT_OUT="'proof.evidence' must be a single value, not a list" expect 1 "a list in a single-value field is refused" d11
frag d8 's/^notes: \[\]$/notes: []\nbogus_key:/'
EXPECT_OUT="unknown key 'bogus_key'" expect 1 "an unknown key with no value is refused" d8
frag d12 's/^notes: \[\]$/notes: []\nbogus_map: {}/'
EXPECT_OUT="unknown key 'bogus_map'" expect 1 "an unknown key holding an empty mapping is refused" d12
frag d13 's/^notes: \[\]$/notes: []\nbogus_map:\n  inner: 1/'
EXPECT_OUT="unknown key 'bogus_map'" expect 1 "an unknown key holding a mapping is named itself" d13
frag d14 's/^notes: \[\]$/notes: []\ndepends_on: {}/'
EXPECT_OUT="'depends_on' must not hold a mapping" expect 1 "a known non-section key holding a mapping is refused" d14
frag d9 's/^  claimant: operator$/  claimant: operator\n  claimant: other/'
EXPECT_OUT="duplicate key 'claim.claimant'" expect 1 "a repeated key is named with its section (control)" d9
printf 'id: d10\n\tsource: d10.f90\n' >"$W/port/status/d10.yaml"
EXPECT_OUT="is not valid YAML" expect 1 "a fragment that is not valid YAML is refused as such" d10

[ "$failed" -eq 0 ] || { printf '# test-status-fragment-data: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-status-fragment-data: all assertions passed\n'
