#!/usr/bin/env bash
# finalize.sh - the sign-off-GATED, deterministic post-sign-off git finalize.
#
# After a phase/milestone acceptance (a human accept-SIGNOFF.md, or --auto in L2/L3 auto-mode), this performs the mechanical git the human used to type by hand:
# tag the accepted commit, fast-forward-land a pending methodology sync, push, and tear down the sync
# worktree. It is the ONE sanctioned way an agent touches tag/land/push - and the human DECISION
# still gates it: the default (signed) path REFUSES unless a committed human accept-SIGNOFF.md is at
# HEAD; only the keystrokes are removed (charter auto-land). The gate is enforced HERE, in code.
#
# Two paths:
#   finalize.sh <tag> --signoff <path> [--sync <branch>]   signed milestone: gated tag (+ optional sync land) + push
#   finalize.sh --land-only --sync <branch>                methodology sync only: NO tag, NO sign-off, but the sync
#                                                          must PROVE it is a real base sync (a sync/<id> --no-ff merge
#                                                          of upstream/main onto HEAD, touching no project-owned file).
#
# Trust model: the recorded accept (a committed SIGNOFF.md) authorizes the signed path. --land-only
# carries no sign-off but is shape-verified so it cannot push arbitrary work. Residual (honest): a
# fully autonomous agent could forge+commit a SIGNOFF.md; the gate prevents an UNGATED finalize, not a
# forged decision - the committed signoff and the audit trail are the record. Ad-hoc push/merge/tag
# outside this script stay denied.
#
# Exit: 0 finalized; 2 refused (a guard tripped) - on refusal nothing is tagged, landed, or pushed.
set -euo pipefail

fail() { echo "finalize: $*" >&2; exit 2; }
say()  { echo "finalize: $*"; }
run()  { echo "  + $*"; [ "$DRY" = 1 ] || "$@"; }

TAG=""; SIGNOFF=""; SYNC=""; REMOTE="origin"; PUSH=1; DRY=0; LAND_ONLY=0; AUTO=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--signoff)   SIGNOFF="${2:-}"; shift 2 ;;
		--auto)      AUTO=1; shift ;;
		--sync)      SYNC="${2:-}"; shift 2 ;;
		--remote)    REMOTE="${2:-}"; shift 2 ;;
		--no-push)   PUSH=0; shift ;;
		--dry-run)   DRY=1; shift ;;
		--land-only) LAND_ONLY=1; shift ;;
		-*)          fail "unknown flag: $1" ;;
		*)           [ -z "$TAG" ] || fail "unexpected extra argument: $1"; TAG="$1"; shift ;;
	esac
done
[ "$AUTO" = 0 ] || [ -z "$SIGNOFF" ] || fail "--auto and --signoff are mutually exclusive (auto-finalize is gated by the run, not a human SIGNOFF)"
# REMOTE is a configured remote NAME, never a URL/path/dash (no pushing to an arbitrary remote).
case "$REMOTE" in ""|-*|*:*|*/*|*" "*) fail "remote '$REMOTE' must be a configured remote name, not a URL/path" ;; esac
if [ "$LAND_ONLY" = 1 ]; then
	[ -z "$TAG" ] || fail "--land-only takes no tag (it lands a methodology sync; it does not seal a milestone)"
	[ -n "$SYNC" ] || fail "--land-only requires --sync <branch>"
	case "$SYNC" in sync/*) : ;; *) fail "--land-only --sync must name a sync/<id> branch (got '$SYNC')" ;; esac
else
	[ -n "$TAG" ] || fail "usage: finalize.sh <tag> --signoff <path> [--sync <branch>]   (or: --land-only --sync <branch>)"
	case "$TAG" in -*|*" "*|*"/"*) fail "tag '$TAG' is not a simple tag name" ;; esac
fi

top="$(git rev-parse --show-toplevel 2>/dev/null)" || fail "not inside a git repository"
cd "$top"
branch="$(git rev-parse --abbrev-ref HEAD)"
[ "$branch" != "HEAD" ] || fail "detached HEAD - finalize from the branch you are landing onto"
head="$(git rev-parse HEAD)"

# ---- THE GATE ----
# Auto-finalize (--auto): autodrive milestone seal with NO human keystroke. The authority is the GATES
# plus an INDEPENDENT auto-run review - enabling autodrive at L2/L3 is the authorization, and the §7
# acceptance standard the run was checked against was set ONCE in the charter. Otherwise: a committed
# human accept-SIGNOFF.md, recorded AT HEAD.
if [ "$LAND_ONLY" = 0 ] && [ "$AUTO" = 1 ]; then
	cfg="port/autodrive.yaml"
	[ -f "$cfg" ] || fail "--auto requires port/autodrive.yaml (auto-mode must be enabled)"
	lvl="$(sed -nE 's/^[[:space:]]*level:[[:space:]]*([A-Za-z0-9]+).*/\1/p' "$cfg" | head -1)"
	case "$lvl" in L2|L3) : ;; *) fail "--auto requires autodrive level L2 or L3 (got '$lvl') - auto-finalize is not authorized below it" ;; esac
	# Gate A: the FULL conformance suite green at HEAD (the machine fidelity floor - per-unit R1 via
	# check-trace-evidence, completeness, the differential gates, the lot). Never seal over a red gate.
	_ff=0; for s in tools/conformance/*.sh; do bash "$s" >/dev/null 2>&1 || _ff=$((_ff+1)); done
	[ "$_ff" -eq 0 ] || fail "$_ff conformance check(s) RED at HEAD - auto-finalize never seals a milestone over a red gate"
	# Gate B: a clean INDEPENDENT auto-run review committed at HEAD (a different-model reviewer via
	# /port-review-autorun), bound to THIS commit (no commits added after the review = no unreviewed state).
	rev=""
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		[ "$(git log -1 --format=%H -- "$r")" = "$head" ] && { rev="$r"; break; }
	done < <(git ls-tree -r --name-only HEAD | grep -E '^docs/evidence/autodrive/[^/]+/review\.md$' || true)
	[ -n "$rev" ] || fail "--auto requires a committed independent auto-run review (docs/evidence/autodrive/<run>/review.md) recorded AT HEAD - run /port-review-autorun on the current state first"
	# Bind the review to the exact REVIEWED TREE: the commit that recorded the review (HEAD) must add
	# ONLY review/evidence (under docs/evidence/), NOTHING else - so the product/source state sealed here
	# is EXACTLY what the independent reviewer reviewed. Commit code/state BEFORE the review, never in the
	# same commit (else unreviewed bytes ride in under a clean verdict).
	if git rev-parse -q --verify "HEAD~1" >/dev/null 2>&1; then
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			case "$p" in docs/evidence/*) : ;;
				*) fail "the auto-run review commit (HEAD) also changed '$p' outside docs/evidence/ - the review commit must add ONLY the review evidence, so the sealed state is exactly what was reviewed; commit product/state changes BEFORE running /port-review-autorun" ;;
			esac
		done < <(git diff --name-only "HEAD~1" "HEAD")
	fi
	rcontent="$(git show "HEAD:$rev")"
	# Anchored, machine-readable verdict: EXACTLY ONE `verdict:` line, and its value is exactly `clean`
	# (so a prose mention like "expected: verdict: clean" or "not a verdict: clean" can never satisfy it).
	mapfile -t _v < <(printf '%s\n' "$rcontent" | grep -iE '^[[:space:]>*-]*verdict:' || true)
	[ "${#_v[@]}" -eq 1 ] || fail "$rev must have exactly one verdict: line (found ${#_v[@]}) - the auto-run review verdict must be an unambiguous machine line"
	vval="$(printf '%s' "${_v[0]}" | tr '[:upper:]' '[:lower:]' | sed -E 's/\r$//; s/^[[:space:]>*-]*verdict:[[:space:]]*//; s/[[:space:]]*$//')"
	[ "$vval" = "clean" ] || fail "$rev verdict is '$vval', not a plain 'clean' - auto-finalize never seals over a non-clean (violations / conditional) auto-run review"
	decision="auto-finalize"; signed="autodrive ($lvl); review=$rev"
	say "auto-finalize gate OK: level $lvl, full conformance green, clean independent auto-run review at HEAD ($rev)."
elif [ "$LAND_ONLY" = 0 ]; then
	if [ -z "$SIGNOFF" ]; then
		mapfile -t _sf < <(git ls-tree -r --name-only HEAD | grep -E '(^|/)SIGNOFF\.md$' || true)
		[ "${#_sf[@]}" -eq 1 ] || fail "found ${#_sf[@]} SIGNOFF.md at HEAD - pass --signoff <path> to disambiguate"
		SIGNOFF="${_sf[0]}"
	fi
	case "$SIGNOFF" in docs/evidence/*) : ;; *) fail "--signoff must be under docs/evidence/ (got '$SIGNOFF')" ;; esac
	case "$SIGNOFF" in */SIGNOFF.md) : ;; *) fail "--signoff must name a SIGNOFF.md (got '$SIGNOFF')" ;; esac
	git cat-file -e "HEAD:$SIGNOFF" 2>/dev/null || fail "$SIGNOFF is not committed at HEAD (sign off and commit it first)"
	# Stale-signoff guard: HEAD must BE the commit that recorded this signoff (no unsigned commits on top).
	[ "$(git log -1 --format=%H -- "$SIGNOFF")" = "$head" ] \
		|| fail "HEAD is not the commit that recorded $SIGNOFF - commits were added after sign-off; re-sign the current state"
	content="$(git show "HEAD:$SIGNOFF")"
	# Exactly one Decision: and one Signed: line, parsed from the COMMITTED blob.
	mapfile -t _dec < <(printf '%s\n' "$content" | grep -iE '^[[:space:]>*-]*Decision:' || true)
	mapfile -t _sig < <(printf '%s\n' "$content" | grep -iE '^[[:space:]>*-]*Signed:' || true)
	[ "${#_dec[@]}" -eq 1 ] || fail "$SIGNOFF must have exactly one Decision: line (found ${#_dec[@]})"
	[ "${#_sig[@]}" -eq 1 ] || fail "$SIGNOFF must have exactly one Signed: line (found ${#_sig[@]})"
	decision="$(printf '%s' "${_dec[0]}" | sed -E 's/\r$//; s/^[[:space:]>*-]*[Dd]ecision:[[:space:]]*//; s/[[:space:]]*$//')"
	signed="$(printf '%s' "${_sig[0]}" | sed -E 's/\r$//; s/[[:space:]]*[Dd]ate:.*$//; s/^[[:space:]>*-]*[Ss]igned:[[:space:]]*//; s/[[:space:]]*$//')"
	# Decision must be an EXACT accept token (conditions go in Notes, never in the decision value).
	case "$(printf '%s' "$decision" | tr '[:upper:]' '[:lower:]')" in
		yes|accept-in-full|accept-with-conditions|accept-with-conditions:*) : ;;
		*) fail "$SIGNOFF Decision '$decision' is not a recognized accept (use accept-in-full / accept-with-conditions / yes; put conditions in Notes)" ;;
	esac
	# Signer must be a real name (not a placeholder, not blank/punctuation-only); registry-bound if one exists.
	case "$signed" in *"<"*) fail "$SIGNOFF Signed is an unfilled placeholder" ;; esac
	printf '%s' "$signed" | grep -qE '[[:alnum:]]' || fail "$SIGNOFF Signed has no name (blank or punctuation-only)"
	say "gate OK: $SIGNOFF committed at HEAD; Decision='$decision', Signed='$signed'"
fi

# Working tree must be clean (both paths), so what we tag/land is exactly the reviewed bytes.
# For a sync land (--land-only) STASH, do not commit: committing onto the land branch moves it
# off the recorded tip, so the ff-land below then refuses. (The signed path commits state first.)
if [ -n "$(git status --porcelain)" ]; then
	if [ "$LAND_ONLY" = 1 ]; then
		fail "working tree is dirty - stash it before landing (do NOT commit onto $branch: that moves it off the recorded tip and the ff-land refuses)"
	else
		fail "working tree is dirty - commit or stash before finalizing"
	fi
fi

# Tag handling (signed path): idempotent if the tag already points at the signed commit (retry-safe);
# otherwise refuse to move a milestone tag.
TAG_EXISTS=0
if [ "$LAND_ONLY" = 0 ] && git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
	if [ "$(git rev-parse "refs/tags/$TAG^{commit}")" = "$head" ]; then
		TAG_EXISTS=1; say "tag '$TAG' already points at the signed commit - reusing it (retry-safe)"
	else
		fail "tag '$TAG' already exists and points elsewhere - refusing to move a milestone tag"
	fi
fi

# A pending sync must fast-forward onto HEAD; validate BEFORE any mutation.
if [ -n "$SYNC" ]; then
	git rev-parse -q --verify "refs/heads/$SYNC" >/dev/null 2>&1 || fail "sync branch '$SYNC' not found"
	[ "$(git merge-base "$head" "$SYNC")" = "$head" ] \
		|| fail "'$SYNC' does not fast-forward onto $branch (main moved since the sync was built) - re-resolve; nothing done"
fi
# --land-only is UNGATED, so the sync must PROVE it is a real base sync, not arbitrary pushed work:
# a 2-parent --no-ff merge whose first parent is HEAD and second parent is the base tip (upstream/main),
# changing no project-owned (merge=ours) file.
if [ "$LAND_ONLY" = 1 ]; then
	read -r _c p1 p2 p3 < <(git rev-list --parents -n1 "$SYNC")
	{ [ -n "${p2:-}" ] && [ -z "${p3:-}" ]; } || fail "--land-only: '$SYNC' is not a 2-parent merge (a base sync is a --no-ff merge of upstream/main)"
	[ "$p1" = "$head" ] || fail "--land-only: '$SYNC' first parent is not HEAD (not built on the current main)"
	git rev-parse -q --verify refs/remotes/upstream/main >/dev/null 2>&1 || fail "--land-only: no upstream/main ref to verify against - fetch the base first"
	[ "$p2" = "$(git rev-parse refs/remotes/upstream/main)" ] || fail "--land-only: '$SYNC' second parent is not upstream/main (not a base sync)"
	upmain="$(git rev-parse refs/remotes/upstream/main)"
	# Verify the sync's tree per LAYER over the UNION of paths the sync OR the base changed vs HEAD, by
	# full tree entry (mode+type+blob, via git diff --quiet). A base sync must land every base-owned
	# change VERBATIM from upstream/main and leave every project-owned file at HEAD. Walking only the
	# sync's own changes (head..SYNC) is insufficient: an agent could silently DROP a base change by
	# restoring a file to HEAD, so it never appears there - hence we also walk head..upstream/main.
	# Path transport is NUL-delimited (-z, sort -zu, read -d '') with a :(literal) pathspec and
	# check-attr -z, so a crafted filename (newline, pathspec magic) cannot dodge the check; --no-renames
	# validates both the delete and add side of a rename.
	while IFS= read -r -d '' f; do
		[ -n "$f" ] || continue
		merge_attr="$(git check-attr -z merge -- "$f" | { IFS= read -r -d '' _p; IFS= read -r -d '' _a; IFS= read -r -d '' _v; printf '%s' "$_v"; })"
		if [ "$merge_attr" = "ours" ]; then
			expected="$head"; layer="project (must equal HEAD)"
		else
			expected="$upmain"; layer="methodology (must equal upstream/main)"
		fi
		git diff --quiet "$expected" "$SYNC" -- ":(literal)$f" \
			|| fail "--land-only: '$f' in '$SYNC' does not match its $layer - a base sync lands the methodology layer verbatim and leaves the project layer at HEAD (tampered or dropped change?)"
	done < <( { git diff -z --name-only --no-renames "$head" "$SYNC"; git diff -z --name-only --no-renames "$head" "$upmain"; } | sort -zu )
fi

# Remote preflight (before any mutation): the remote must be configured.
if [ "$PUSH" = 1 ]; then
	git remote get-url "$REMOTE" >/dev/null 2>&1 || fail "remote '$REMOTE' is not configured - add it or pass --remote <name>"
fi

pushmsg=""; [ "$PUSH" = 1 ] && pushmsg=" push to $REMOTE"
drymsg="";  [ "$DRY" = 1 ] && drymsg=" [dry-run]"
say "finalizing:${TAG:+ tag '$TAG' on $(git rev-parse --short "$head"),}${SYNC:+ ff-land '$SYNC',}${pushmsg}${drymsg}"
if [ "$LAND_ONLY" = 0 ] && [ "$TAG_EXISTS" = 0 ]; then run git tag "$TAG"; fi
[ -n "$SYNC" ] && run git merge --ff-only "$SYNC"
if [ "$PUSH" = 1 ]; then
	if [ "$LAND_ONLY" = 0 ]; then
		run git push --atomic "$REMOTE" "$branch" "refs/tags/$TAG"   # branch + tag together: no half-push
	else
		run git push "$REMOTE" "$branch"
	fi
fi

# Tear down the sync worktree + branch (best effort; the branch is now reachable from HEAD, so -D is safe).
if [ -n "$SYNC" ]; then
	wt="$(git worktree list --porcelain | awk -v b="refs/heads/$SYNC" '/^worktree /{p=substr($0,10)} /^branch /{if($2==b) print p}')"
	if [ -n "$wt" ]; then
		run git worktree remove "$wt" || run git worktree remove --force "$wt" || say "WARNING: could not remove worktree $wt - remove it by hand"
	fi
	run git branch -D "$SYNC" || say "WARNING: could not delete branch $SYNC"
	run git worktree prune
fi
say "done - $([ "$LAND_ONLY" = 1 ] && echo 'methodology sync landed' || echo 'phase finalized')${pushmsg:+ +$pushmsg}${drymsg}. Nothing else to run."
