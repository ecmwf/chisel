#!/usr/bin/env bash
# release_claim.sh - the sanctioned claim-RELEASE path (the gated ref-delete agents cannot run).
#
# A claim RESERVES a work item while it is built (references/team-coordination.md). Once the unit is
# INTEGRATED the claim is done; a leftover claim lingers in refs/claims/* and trips a LATER phase's
# planner (autodrive.py sees a claim whose unit is absent from that phase's TRACE). Claim states are
# created|active|stale - there is NO 'released' value - so releasing a claim means it CEASES TO EXIST:
# this DELETES refs/claims/<id> and removes a tracked port/claims/<id>.yaml. It is the claim analogue
# of finalize.sh's auto-land: the one privileged step (git push --delete) runs INSIDE the script,
# shape-verified first, so it bypasses the per-agent `git push` deny exactly as finalize.sh and
# contribute.sh do - and it can only ever touch the ONE named, already-integrated, unbound claim.
#
# FAIL-CLOSED (refuse, exit 2, change NOTHING) unless ALL hold:
#  - <id> is a valid trace-id (^[A-Za-z0-9][A-Za-z0-9_.-]*$; no '/', '..', whitespace).
#  - the unit is INTEGRATED: port/phase1-plan.yaml lists a unit with this id and `integrated: true`.
#    Phase-1 tooling is the only claim safe to auto-release (see the binding guard); a claim whose
#    unit is not a recorded-integrated Phase-1 unit is refused - a human clears a genuine stray.
#  - the claim is UNBOUND: no port/status/<id>.yaml fragment binds it (a real claim.ref/claimant), and
#    if such a fragment exists it must be cleanly parseable (the SAME strict, duplicate-key-rejecting
#    loader the trust-core checks use) and confirmably unbound. A bound claim MUST persist
#    (check_bindings requires the cited ref to exist); an UNVERIFIABLE fragment (unreadable / not a
#    mapping / duplicate or malformed keys) is treated as bound - never released on a guess.
#  - refs/claims/<id> exists, the remote is configured, and a TRACKED port/claims/<id>.yaml has no
#    uncommitted changes (so the post-delete `git rm` cannot fail AFTER the ref is gone).
#
#   release_claim.sh <trace-id> [--remote origin] [--dry-run]
# Exit: 0 released (remote ref deleted, local ref + tracked port/claims file removed); 2 refused.
set -euo pipefail

fail() { echo "release-claim: $*" >&2; exit 2; }
say()  { echo "release-claim: $*"; }
run()  { echo "  + $*"; [ "$DRY" = 1 ] || "$@"; }

# This script's own directory - so the guard parsers reuse dashboard.py's strict, duplicate-key-
# rejecting loader (one source of truth for "what is a malformed coordination artifact"). Computed
# before any chdir.
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

[ -n "$ID" ] || fail "usage: release_claim.sh <trace-id> [--remote origin] [--dry-run]"
case "$ID" in *" "*|*/*|*..*) fail "id '$ID' is not a valid trace-id (no '/', '..', or whitespace)" ;; esac
printf '%s' "$ID" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || fail "id '$ID' is not a valid trace-id"
# REMOTE is a configured remote NAME, never a URL/path/dash (no pushing to an arbitrary remote).
case "$REMOTE" in ""|-*|*:*|*/*|*" "*) fail "remote '$REMOTE' must be a configured remote name" ;; esac

top="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git repository"
cd "$top"

# Guard 1 (DONE): the unit must be a recorded-INTEGRATED Phase-1 tooling unit. Never release a claim
# whose unit is not confirmed done - that would abandon live work. Exit 0 = integrated; any other
# outcome (not integrated, absent, malformed/duplicate-key plan, import/parse error) exits 1 -> refuse.
plan="port/phase1-plan.yaml"
[ -f "$plan" ] || fail "no $plan - only an integrated Phase-1 tooling claim is auto-releasable; a human clears other claims"
if ! PYTHONPATH="$HERE" python3 - "$plan" "$ID" <<'PY'
import sys
plan, uid = sys.argv[1], sys.argv[2]
try:
    import yaml
    from dashboard import _strict_loader
    d = yaml.load(open(plan, encoding="utf-8"), Loader=_strict_loader(yaml)) or {}
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
for u in (d.get("units") or []):
    if isinstance(u, dict) and str(u.get("id")) == uid:
        sys.exit(0 if u.get("integrated") is True else 1)
sys.exit(1)
PY
then
	fail "unit '$ID' is not 'integrated: true' in $plan (or the plan is malformed) - refusing (never release a claim whose unit is not confirmed integrated)"
fi

# Guard 2 (BINDING-SAFETY, fail closed): a claim a port/status fragment binds MUST persist, because
# check_bindings requires the cited claim.ref to exist. Exit 0 = "do NOT release" (the fragment binds
# the claim, OR cannot be confirmed unbound: unreadable / not a mapping / duplicate-or-malformed keys
# / import error); exit 1 = a cleanly-parsed, confirmably-UNBOUND fragment. Anything but a clean
# unbound fragment fails closed.
frag="port/status/$ID.yaml"
if [ -f "$frag" ]; then
	if PYTHONPATH="$HERE" python3 - "$frag" <<'PY'
import sys
try:
    import yaml
    from dashboard import _strict_loader
    d = yaml.load(open(sys.argv[1], encoding="utf-8"), Loader=_strict_loader(yaml))
except Exception:
    sys.exit(0)                       # unreadable / unparseable / duplicate key -> cannot confirm unbound -> refuse
if not isinstance(d, dict):
    sys.exit(0)                       # not a mapping -> cannot confirm unbound -> refuse
c = d.get("claim", {})
if c is None:
    c = {}
if not isinstance(c, dict):
    sys.exit(0)                       # malformed claim block -> cannot confirm unbound -> refuse
def real(v):
    s = "" if v is None else str(v).strip()
    return bool(s) and "<" not in s and s.lower() not in ("null", "none", "tbd")
sys.exit(0 if (real(c.get("ref")) or real(c.get("claimant"))) else 1)
PY
	then
		fail "$frag binds claim '$ID' or cannot be confirmed unbound (unreadable/malformed/duplicate keys) - refusing (a bound or unverifiable claim must persist for check_bindings)"
	fi
fi

# Guard 3 (EXISTS): the ref must exist to delete, and the remote must be configured.
ref="refs/claims/$ID"
git rev-parse -q --verify "$ref" >/dev/null 2>&1 || fail "$ref does not exist - nothing to release"
git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "remote '$REMOTE' is not configured"

# Guard 4 (CLEAN CLEANUP, preflight before any deletion): if port/claims/<id>.yaml is TRACKED it must
# have no uncommitted changes, so the post-delete `git rm` cannot fail AFTER the ref is already gone
# and leave a partial release (ref deleted, dirty claim file orphaned).
cfile="port/claims/$ID.yaml"
ctracked=0
if git ls-files --error-unmatch "$cfile" >/dev/null 2>&1; then
	ctracked=1
	{ git diff --quiet -- "$cfile" && git diff --cached --quiet -- "$cfile"; } \
		|| fail "$cfile has uncommitted changes - commit or discard them first (refusing to delete the claim ref and leave a partial release)"
fi

say "releasing claim '$ID' (unit integrated, unbound)$([ "$DRY" = 1 ] && echo ' [dry-run]')"
run git push "$REMOTE" --delete "$ref"     # the one gated step, inside this sanctioned script
run git update-ref -d "$ref"
if [ "$ctracked" = 1 ]; then
	run git rm -q "$cfile"                  # preflighted clean above, so this cannot fail post-delete
	say "staged removal of $cfile - commit it with the integration"
elif [ -f "$cfile" ]; then
	run rm -f "$cfile"
fi
say "done - claim '$ID' released$([ "$DRY" = 1 ] && echo ' [dry-run]')."
