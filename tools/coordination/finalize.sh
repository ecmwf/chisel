#!/usr/bin/env bash
# finalize.sh - the sign-off-GUARDED, deterministic post-sign-off git finalize.
#
# After a phase/milestone acceptance (a human accept-SIGNOFF.md, or --auto in L2/L3 auto-mode), this performs the mechanical git the human used to type by hand:
# tag the accepted commit, fast-forward-land a pending methodology sync, push, and tear down the sync
# worktree. It is the ONE sanctioned way an agent touches tag/land/push - and the human DECISION
# still proofs it: the default (signed) path REFUSES unless a committed human accept-SIGNOFF.md is at
# HEAD; only the keystrokes are removed (charter auto-land). The proof is enforced HERE, in code.
#
# Two paths:
#   finalize.sh <tag> --signoff <path> [--sync <branch>]   signed milestone: guarded tag (+ optional sync land) + push
#   finalize.sh --land-only --sync <branch>                methodology sync only: NO tag, NO sign-off, but the sync
#                                                          must PROVE it is a real base sync (a sync/<id> --no-ff merge
#                                                          of upstream/main onto HEAD, touching no project-owned file).
#
# Trust model: the recorded accept (a committed SIGNOFF.md) authorizes the signed path. --land-only
# carries no sign-off but is shape-verified so it cannot push arbitrary work. Residual (honest): a
# fully autonomous agent could forge+commit a SIGNOFF.md; the proof prevents an UNGATED finalize, not a
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
[ "$AUTO" = 0 ] || [ -z "$SIGNOFF" ] || fail "--auto and --signoff are mutually exclusive (auto-finalize is proven by the run, not a human SIGNOFF)"
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

# ---- THE PROOF ----
# Auto-finalize (--auto): autodrive milestone seal with NO human keystroke. The authority is the CHECKS
# (full conformance green at HEAD, plus the per-piece independent review check-trace-evidence binds to
# every proven commit) - enabling autodrive at L2/L3 is the authorization, and the §7 acceptance standard
# the run was checked against was set ONCE in the charter. Otherwise: a committed human accept-SIGNOFF.md,
# recorded AT HEAD.
if [ "$LAND_ONLY" = 0 ] && [ "$AUTO" = 1 ]; then
	cfg="port/autodrive.yaml"
	[ -f "$cfg" ] || fail "--auto requires port/autodrive.yaml (auto-mode must be enabled)"
	lvl="$(sed -nE 's/^[[:space:]]*level:[[:space:]]*([A-Za-z0-9]+).*/\1/p' "$cfg" | head -1)"
	case "$lvl" in L2|L3) : ;; *) fail "--auto requires autodrive level L2 or L3 (got '$lvl') - auto-finalize is not authorized below it" ;; esac
	# Proof A: the FULL conformance suite green at HEAD (the machine fidelity floor - per-unit R1 via
	# check-trace-evidence, completeness, the differential proofs, the lot). Never seal over a red proof.
	# Run in parallel; any non-green check makes the runner exit non-zero.
	bash tools/run-conformance.sh >/dev/null 2>&1 \
		|| fail "conformance check(s) RED at HEAD - auto-finalize never seals a milestone over a red proof (see: bash tools/run-conformance.sh)"
	# The acceptance authority is the CHECKS plus the §7 whole-program standard the human set ONCE in the
	# charter, and the per-piece INDEPENDENT review each landed unit already cleared (check-trace-evidence
	# binds a clean different-model review to every proven commit). Enabling autodrive at L2/L3 is the
	# operator's authorization; the machine floor (Proof A above) is full conformance green at HEAD.
	decision="auto-finalize"; signed="autodrive ($lvl)"
	say "auto-finalize proof OK: level $lvl, full conformance green at HEAD."
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
	say "proof OK: $SIGNOFF committed at HEAD; Decision='$decision', Signed='$signed'"
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
	# full tree entry (mode+type+blob, via git diff --quiet). A base sync must land every change the
	# BASE made since the last sync - the range mergebase..upstream/main, where mergebase is the previous
	# synced base point - VERBATIM from upstream/main, and PRESERVE at HEAD everything the base did NOT
	# change: project-owned files AND this instance's OWN local methodology (methodology it has modified
	# or added but not yet contributed - a deferred contribution, or a local-only tool that legitimately
	# survives a sync). The merge drivers keep that local methodology, so the land must not now reject it.
	# Keying methodology on "equals upstream/main" UNCONDITIONALLY was too strong: it rejected local
	# methodology the merge had correctly kept, so a sync could not land while the instance carried any
	# uncontributed methodology at all. The base-changed test below keeps every safety property - a base
	# change still lands verbatim; a silently DROPPED base change (reverted to HEAD so it never shows in
	# head..SYNC) still appears in the head..upstream/main walk and fails; TAMPERING still fails - while
	# preserving local methodology. Walking only head..SYNC is insufficient (the drop hides there), hence
	# we also walk head..upstream/main. Path transport is NUL-delimited (-z, sort -zu, read -d '') with a
	# :(literal) pathspec and check-attr -z, so a crafted filename (newline, pathspec magic) cannot dodge
	# the check; --no-renames validates both the delete and add side of a rename.
	mergebase="$(git merge-base "$head" "$upmain")"
	while IFS= read -r -d '' f; do
		[ -n "$f" ] || continue
		merge_attr="$(git check-attr -z merge -- "$f" | { IFS= read -r -d '' _p; IFS= read -r -d '' _a; IFS= read -r -d '' _v; printf '%s' "$_v"; })"
		if [ "$merge_attr" = "ours" ]; then
			expected="$head"; layer="project (must equal HEAD)"
		elif ! git diff --quiet "$mergebase" "$upmain" -- ":(literal)$f"; then
			# methodology the base CHANGED since the last sync -> must land verbatim from upstream/main
			expected="$upmain"; layer="methodology the base changed (must land verbatim from upstream/main)"
		else
			# methodology the base did NOT change -> preserve at HEAD (this instance's local methodology)
			expected="$head"; layer="methodology the base did not change (must be preserved at HEAD)"
		fi
		git diff --quiet "$expected" "$SYNC" -- ":(literal)$f" \
			|| fail "--land-only: '$f' in '$SYNC' does not match its $layer - a base sync lands base-changed methodology verbatim from upstream/main and preserves everything the base did not change at HEAD (tampered or dropped change?)"
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
