#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# push_claim.sh - publish a unit's claim as the pushed ref refs/claims/<id>, for a port that several
# operators share (references/team-coordination.md, "Claims"). provision_worker.sh writes the local
# claim port/claims/<id>.yaml; run this right after it, before the unit is dispatched. The claim goes
# to the remote as a ref to its content, and is never forced: git creates a ref that does not exist
# and refuses to replace one that does, so a second operator claiming the same unit is refused.
# Pushing the same claim again changes nothing. release_claim.sh deletes the ref once the unit is
# integrated; the tools read pushed claims with --from-refs.
#
#   push_claim.sh <trace-id> [--remote origin] [--dry-run]
#
# Exit: 0 pushed, or already on the remote with the same content; 1 another operator holds the unit
# (the remote ref has other content); 2 refused (no local claim, a claim for another id, no remote).
set -euo pipefail

fail() { echo "push-claim: $*" >&2; exit 2; }
say()  { echo "push-claim: $*"; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

ID=""; REMOTE="origin"; DRY=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--remote)  [ "$#" -ge 2 ] || fail "--remote needs a remote name"; REMOTE="$2"; shift 2 ;;
		--dry-run) DRY=1; shift ;;
		--*)       fail "unknown option: $1" ;;
		*)         [ -z "$ID" ] || fail "only one <trace-id> allowed (got '$ID' and '$1')"; ID="$1"; shift ;;
	esac
done
[ -n "$ID" ] || fail "usage: push_claim.sh <trace-id> [--remote origin] [--dry-run]"
case "$ID" in *..*) fail "id '$ID' is not a valid trace-id" ;; esac
printf '%s' "$ID" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || fail "id '$ID' is not a valid trace-id"
case "$REMOTE" in ""|-*|*:*|*/*|*" "*) fail "remote '$REMOTE' must be a configured remote name" ;; esac

top="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git repository"
cd "$top"
cfile="port/claims/$ID.yaml"
[ -f "$cfile" ] || fail "no $cfile - provision the unit first (provision_worker.sh add $ID)"
cid="$(python3 "$HERE/yaml_get.py" "$cfile" id 2>/dev/null)" || fail "$cfile cannot be read, or has no id"
[ "$cid" = "$ID" ] || fail "$cfile is the claim for '$cid', not '$ID'"
git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "remote '$REMOTE' is not configured"

ref="refs/claims/$ID"
blob="$(git hash-object -w "$cfile")"
held="$(git ls-remote "$REMOTE" "$ref" | awk '{print $1}')" || fail "cannot read the refs of '$REMOTE'"
if [ "$held" = "$blob" ]; then
	git update-ref "$ref" "$blob"
	say "$ref is already on '$REMOTE' with this claim - nothing to push"
	exit 0
fi
taken() {
	echo "push-claim: another operator holds '$ID': $ref on '$REMOTE' has another claim. Remove your" \
		"provisioning (provision_worker.sh remove $ID) and take another unit." >&2
	exit 1
}
[ -z "$held" ] || taken

say "pushing $ref to '$REMOTE'$([ "$DRY" = 1 ] && echo ' [dry-run]')"
[ "$DRY" = 0 ] || exit 0
git push -q "$REMOTE" "$blob:$ref" 2>/dev/null || taken   # never forced: a claim made meanwhile wins
git update-ref "$ref" "$blob"   # the local copy release_claim.sh looks for
say "claimed '$ID' on '$REMOTE'"
