#!/usr/bin/env bash
# integrate_assembly.sh - sanctioned PRODUCT land for an ASSEMBLY-GATED deliverable (the assembly analogue
# of integrate_product.sh). Some deliverables cannot land per-id: their gate is assembly-level (one
# differential links several modules, so no single module passes the gate in isolation) and their
# parallel-port work branches are independent full-closure trees, not composable per-id layers (see the
# assembly-gated failure mode B7 in references/failure-modes.md and the assembly land in
# references/two-repo-architecture.md). Such a deliverable lands as ONE reviewed tree.
#
# The unit of land is an ASSEMBLY PIECE: a `work/<assembly-id>` branch in the product carrying the
# assembled tree (the gated members' code PLUS the build glue that wires them), and a gated fragment
# `port/status/<assembly-id>.yaml` recording its assembly-level gate AND its INDEPENDENT integration-level
# review (the one review that walks the assembled commit, including the build glue). There is NO audit
# manifest and NO tree-hash ceremony: the review is bound to the assembly commit by check-trace-evidence
# exactly like any piece's review, and "the review saw the shipped bytes" is enforced the same way
# integrate_product.sh enforces it - the squash lands the reviewed branch's tip and the FULL conformance
# suite is re-run on the MERGE RESULT (rolled back on red). The keystroke is never the trust gate.
#
# It pushes from INSIDE this script (bypassing the per-agent `git push` deny) exactly as
# integrate_product.sh / integrate_land.sh / finalize.sh do - and only ever for ONE conformance-green,
# members-gated, integration-reviewed assembly.
#
# FAIL-CLOSED (refuse, exit 2, merge/push NOTHING) unless ALL hold:
#  - <assembly-id> is a valid trace-id; a two-repo product is wired (port/product.yaml + a present checkout)
#    and the product checkout is on its clean default branch.
#  - in a FRESHLY generated TRACE, <assembly-id> is `gated` (so its integration review is recorded and
#    bound by check-trace-evidence) and EVERY --members id is `gated` (no member is excluded/in-progress).
#  - a product `work/<assembly-id>` branch exists and INCLUDES the current mainline (not stale-based).
#  - the FULL conformance suite is green at HEAD (both roots), and AGAIN at the product merge RESULT.
#
#   integrate_assembly.sh <assembly-id> --members "id1 id2 ..." [--message <msg>]
#                         [--remote origin] [--no-push] [--dry-run]
# Exit: 0 landed (the assembly squash-merged onto the product mainline + pushed); 2 refused.
set -euo pipefail

fail() { echo "integrate-assembly: $*" >&2; exit 2; }
say()  { echo "integrate-assembly: $*"; }
run()  { echo "  + $*"; [ "$DRY" = 1 ] || "$@"; }

# Crash-safe rollback: from the moment we mutate the product mainline until the merge RESULT is verified
# green, ARM a rollback so ANY exit (failed git command, signal/kill) resets the mainline to its pre-land
# commit - the product is never left advanced to an unverified commit.
ROLLBACK_ARMED=0; PC=""; PRE_LAND=""
rollback_product() {
	[ "$ROLLBACK_ARMED" = 1 ] || return 0
	echo "integrate-assembly: land did not complete verified - rolling product back to $PRE_LAND" >&2
	git -C "$PC" reset --hard "$PRE_LAND" >/dev/null 2>&1 \
		|| echo "integrate-assembly: WARNING - rollback FAILED; the product mainline may sit at an UNVERIFIED commit (nothing was pushed). Reset it by hand: git -C '$PC' reset --hard $PRE_LAND" >&2
}
trap rollback_product EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

ID=""; MEMBERS=""; REMOTE="origin"; PUSH=1; DRY=0; MSG=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--members) [ "$#" -ge 2 ] || fail "--members needs a space-separated id list"; MEMBERS="$2"; shift 2 ;;
		--message) [ "$#" -ge 2 ] || fail "--message needs a commit message"; MSG="$2"; shift 2 ;;
		--remote)  [ "$#" -ge 2 ] || fail "--remote needs a remote name"; REMOTE="$2"; shift 2 ;;
		--no-push) PUSH=0; shift ;;
		--dry-run) DRY=1; shift ;;
		--*)       fail "unknown option: $1" ;;
		*)         [ -z "$ID" ] || fail "only one <assembly-id> allowed (got '$ID' and '$1')"; ID="$1"; shift ;;
	esac
done

[ -n "$ID" ] || fail "usage: integrate_assembly.sh <assembly-id> --members \"id1 id2 ...\" [--message <msg>] [--remote origin] [--no-push] [--dry-run]"
case "$ID" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "assembly-id '$ID' must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes)" ;; esac
# Member list: collapse whitespace, require at least one REAL id, each a valid trace-id (no slashes).
MEMBERS="$(printf '%s' "$MEMBERS" | tr '\t' ' ' | tr -s ' ' | sed 's/^ //; s/ $//')"
[ -n "$MEMBERS" ] || fail "--members is required and must list at least one member trace-id (space-separated)"
for m in $MEMBERS; do
	case "$m" in *[!A-Za-z0-9._-]*|.*|-*) fail "member id '$m' is not a valid trace-id ([A-Za-z0-9][A-Za-z0-9._-]*, no slashes)" ;; esac
done
case "$REMOTE" in ""|-*|*:*|*/*|*" "*) fail "remote '$REMOTE' must be a configured remote name" ;; esac

here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$here/../conformance/lib/product-root.sh"
wb="$(_pr_repo_root)" || fail "not inside a git repository"
cd "$wb"

# Gate 0 (TWO-REPO WIRED): resolve the product checkout, fail-closed on single-repo / placeholder / absent.
set +e; PC="$(default_product_root)"; PRC=$?; set -e
case "$PRC" in
	0)  : ;;
	10) fail "single-repo (no port/product.yaml) - there is no separate product to land into" ;;
	2)  fail "product is wired but its checkout is unset/placeholder - set it in port/product.yaml first" ;;
	*)  fail "cannot resolve the product checkout" ;;
esac
[ -d "$PC" ] || fail "product checkout '$PC' is absent - clone it first (tools/checkout-product.sh)"
git -C "$PC" rev-parse --show-toplevel >/dev/null 2>&1 || fail "product checkout '$PC' is not a git repo"

DB="$(sed -nE 's/^[[:space:]]*default_branch:[[:space:]]*(.*)$/\1/p' port/product.yaml | head -1 \
	| sed -E 's/[[:space:]]*#.*$//; s/^["'\'']//; s/["'\'']$//; s/[[:space:]]*$//')"
[ -n "$DB" ] || DB="main"

# Gate 1 (PRODUCT ON ITS MAINLINE, clean): land onto the real mainline, exactly the reviewed bytes.
pcur="$(git -C "$PC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
[ "$pcur" = "$DB" ] || fail "product checkout is on '$pcur', not '$DB' - check out the product mainline before landing"
[ -z "$(git -C "$PC" status --porcelain)" ] || fail "product working tree is dirty - commit/clean it first (we land exactly the reviewed bytes)"

# Gate 2 (READINESS: assembly gated + every member gated). Generate the TRACE FRESH from the status
# fragments (single source of truth) so a stale committed TRACE cannot pass an ungated piece. The assembly
# being `gated` means its INTEGRATION-LEVEL review is recorded and bound to its gated commit by
# check-trace-evidence (run in Gate 3) - that is the binding, no manifest needed.
trace="$wb/.assembly-trace.$$"
python3 "$here/generate_trace.py" > "$trace" 2>/dev/null || { rm -f "$trace"; fail "could not generate TRACE to check gating"; }
_status() { python3 - "$trace" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1])) or {}
print(next((f.get("status") for f in (d.get("files") or []) if f.get("id") == sys.argv[2]), ""))
PY
}
ast="$(_status "$ID")"
[ "$ast" = "gated" ] || { rm -f "$trace"; fail "assembly '$ID' is status '${ast:-absent}', not 'gated' - the assembly piece (its assembly-level gate + integration-level review) must be gated first"; }
# A member is acceptable if it is `gated` (carries its OWN R1 differential + review) OR it is a
# TRANSITIVE member: a unit that genuinely CANNOT be exercised in isolation, validated by THIS
# assembly's whole-program differential, carrying `gate.validation: transitive` AND its own
# INDEPENDENT, CLEAN faithfulness review on disk. The transitive path drops ONLY the impossible
# per-member runtime differential - the independent review (the anti-self-approval control) stays
# MANDATORY, and the assembly itself still carries the R1 whole-program differential + the
# integration-level review (the assembly-`gated` check above). A member that COULD be gated at R1 in
# isolation must be - transitive is the fallback for the untestable-alone, not a shortcut. See
# references/two-repo-architecture.md "Assembly-gated acceptance".
for m in $MEMBERS; do
	st="$(_status "$m")"
	[ "$st" = "gated" ] && continue
	frag="port/status/$m.yaml"
	[ -f "$frag" ] || { rm -f "$trace"; fail "member '$m' is '${st:-absent}', not gated, and has no fragment '$frag'"; }
	# A non-gated member must be TRANSITIVE and clear the SAME review bar a gated member does - the
	# INDEPENDENCE controls of check-status-fragments (reviewer_id set + != author_id; reviewer_session
	# set + not in author_sessions; author_sessions non-empty) - differing ONLY in that the per-member
	# R1 differential is replaced by the assembly's whole-program differential. Field checks here; the
	# review's durability + clean-verdict are checked below with check-trace-evidence's exact semantics.
	mrev="$(python3 - "$frag" "$m" "$st" 2>&1 <<'PY'
import sys, yaml
frag, m, st = sys.argv[1], sys.argv[2], sys.argv[3]
d = yaml.safe_load(open(frag, encoding="utf-8")) or {}
g = d.get("gate") or {}; r = d.get("review") or {}
def s(x): return str(x).strip() if x is not None else ""
val = s(g.get("validation")); rev = s(r.get("evidence"))
aid = s(d.get("author_id")); rid = s(d.get("reviewer_id")); rsess = s(d.get("reviewer_session"))
asess = [s(x) for x in (d.get("author_sessions") or []) if s(x)]
def die(msg):
    sys.stderr.write("member '%s' (%s): %s\n" % (m, st or "absent", msg)); sys.exit(1)
if val != "transitive":
    die("not gated and gate.validation is '%s', not 'transitive' - a non-gated member must be a genuinely-untestable-alone unit validated by the assembly differential (mark gate.validation: transitive), else gate it at R1" % (val or "null"))
if not aid: die("transitive but author_id is empty")
if not asess: die("transitive but author_sessions is empty")
if not rid: die("transitive but has no reviewer_id - a transitive member STILL needs an INDEPENDENT review")
if rid == aid: die("transitive but reviewer_id == author_id - independence violated")
if not rsess: die("transitive but has no reviewer_session")
if rsess in asess: die("transitive but reviewer_session is in author_sessions - independence violated")
if not rev: die("transitive but review.evidence is empty - record the independent faithfulness review")
if not rev.startswith("docs/evidence/"): die("transitive review.evidence '%s' must be a workbench-relative path under docs/evidence/ (durable committed evidence, not /tmp or an absolute path)" % rev)
if ".." in rev: die("transitive review.evidence '%s' must not contain '..'" % rev)
print(rev)
PY
)" || { rm -f "$trace"; fail "$mrev"; }
	# durability + clean verdict, matching check-trace-evidence (violations FIRST, then require clean).
	[ -e "$mrev" ] || { rm -f "$trace"; fail "transitive member '$m': review.evidence '$mrev' does not exist on disk"; }
	git ls-files --error-unmatch -- "$mrev" >/dev/null 2>&1 || { rm -f "$trace"; fail "transitive member '$m': review '$mrev' is not git-tracked (committed evidence required, not a working-tree-only file)"; }
	if grep -qiE 'verdict[: ].*(violation|not clean)' "$mrev"; then rm -f "$trace"; fail "transitive member '$m': review records a VIOLATIONS verdict - a clean independent review is required: $mrev"; fi
	grep -qiE 'verdict[: ]+clean\b' "$mrev" || { rm -f "$trace"; fail "transitive member '$m': review records no explicit clean verdict (e.g. 'verdict: clean'): $mrev"; }
done
rm -f "$trace"

# Gate 3 (TRUST FLOOR, both roots): full conformance green at HEAD. This runs check-trace-evidence (binds
# the assembly's + members' reviews to their gated commits) and the product-facing checks against the
# product checkout (the two-root contract C6).
bash tools/run-conformance.sh >/dev/null 2>&1 \
	|| fail "conformance check(s) RED at HEAD - never land over a red gate; fix them first (bash tools/run-conformance.sh)"

# Gate 4 (BRANCH EXISTS, NOT STALE): the product work/<assembly-id> branch INCLUDES the current mainline,
# so the squash result tree == the gated/reviewed branch tip tree (a stale base would land an ungated mix).
br="work/$ID"
git -C "$PC" rev-parse -q --verify "refs/heads/$br" >/dev/null 2>&1 || fail "branch '$br' (the assembled tree) not found in the product repo ('$PC')"
pmain="$(git -C "$PC" rev-parse "$DB")"
brtip="$(git -C "$PC" rev-parse "$br")"
[ "$brtip" != "$pmain" ] || fail "'$br' is already at '$DB' - nothing to integrate"
git -C "$PC" merge-base --is-ancestor "$pmain" "$br" \
	|| fail "'$br' does not include the current '$DB' (the base moved) - rebase '$br' onto '$DB', re-gate the assembly AND get a fresh INDEPENDENT integration re-review, then retry; nothing landed (stale-base rule)"

# Gate 4b (LANDED COMMIT == REVIEWED COMMIT): the manifest-free binding. The assembly fragment records
# the product commit its assembly-level gate ran against and its integration review was bound to
# (gate.commit); the branch tip we are about to land MUST equal it, else the branch advanced past its
# gate/review and we would ship unreviewed bytes. This is what #110's manifest tree-hash did, done with
# the existing fragment field - so the reviewed commit, not just "some gated branch", is what lands.
gcommit="$(python3 - "port/status/$ID.yaml" <<'PY'
import sys
try:
    import yaml
    d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
except Exception:
    sys.exit(0)
print(((d.get("gate") or {}).get("commit")) or "")
PY
)"
[ -n "$gcommit" ] || fail "assembly '$ID' fragment (port/status/$ID.yaml) has no gate.commit - cannot bind the landed bytes to the gated+reviewed commit (record the reviewed product commit there)"
gfull="$(git -C "$PC" rev-parse -q --verify "${gcommit}^{commit}" 2>/dev/null)" || fail "assembly gate.commit '$gcommit' does not resolve in the product repo"
[ "$gfull" = "$brtip" ] || fail "work/$ID tip ($brtip) != the assembly's gated+reviewed commit gate.commit ($gfull) - the branch advanced past its gate+review; re-gate AND get a fresh INDEPENDENT integration re-review of the new tip, then retry (nothing landed)"

if [ "$PUSH" = 1 ]; then
	git -C "$PC" remote get-url "$REMOTE" >/dev/null 2>&1 || fail "product remote '$REMOTE' is not configured (in '$PC')"
fi

# Land: the assembled tree as ONE squashed product commit (clean product history C5). ARM the crash-safe
# rollback first: from here until Gate 5 passes, any exit resets the mainline to PRE_LAND.
PRE_LAND="$pmain"
[ -n "$MSG" ] || MSG="feat: land reviewed assembly $ID"
say "landing assembly '$br' (members: $MEMBERS) onto product '$DB' as one squashed commit (assembly + members gated, conformance green, non-stale)$([ "$DRY" = 1 ] && echo ' [dry-run]')"
[ "$DRY" = 1 ] || ROLLBACK_ARMED=1
run git -C "$PC" merge --squash "$br"          # apply the assembled tree onto the mainline working tree
run git -C "$PC" commit -m "$MSG"              # the one gated act, inside this sanctioned script

# Gate 5 (LANDED BYTES, two-root merge RESULT): the product checkout now holds the merge result; re-run the
# FULL suite against it. A commit added to work/<assembly-id> after its gate/review must not ride in
# unverified - the armed rollback resets the mainline and we refuse (push NOTHING) if the LANDED state is red.
if [ "$DRY" != 1 ]; then
	if ! bash tools/run-conformance.sh >/dev/null 2>&1; then
		fail "conformance check(s) RED at the product merge result - rolling product '$DB' back to $pmain, nothing pushed. Re-gate the assembly '$br' (bash tools/run-conformance.sh)."
	fi
fi
# Merge RESULT verified green (or dry-run): the squashed commit is good - DISARM the rollback and KEEP it.
ROLLBACK_ARMED=0

[ "$PUSH" = 1 ] && run git -C "$PC" push "$REMOTE" "$DB"

newmain="$(git -C "$PC" rev-parse "$DB" 2>/dev/null || echo "$pmain")"
say "done - assembly '$ID' landed on product '$DB'$([ "$PUSH" = 1 ] && echo " (pushed to $REMOTE)")$([ "$DRY" = 1 ] && echo ' [dry-run]')."
say "product.main_commit=$newmain - record this + integration.state: integrated in port/status/$ID.yaml AND each member's port/status/<id>.yaml, set port/product.yaml attested_commit, regenerate TRACE, then tear down the member + assembly worktrees."
