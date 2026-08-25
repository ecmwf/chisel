#!/usr/bin/env bash
# assert_isolated.sh - a Kha-Worker's FIRST action, before any edit or commit: a fail-closed
# isolation preflight.
#
# opencode Task subagents share the caller's checkout (there is no per-subagent cwd), so a worker
# dispatched WITHOUT a provisioned worktree edits and commits in the SHARED tree and races every
# sibling: multiple workers create the same file, edit the same CMakeLists, and commit to different
# branches that move HEAD under each other - the exact collision provision_worker.sh's isolation
# prevents. The worker guardrail ("STOP if handed no contract") is prose a worker can skip under a
# fan-out push; this is the mechanical check that refuses instead.
#
# It REFUSES (exit 2) unless the worker is confined to its OWN provisioned worktrees for THIS id:
#  - WORKBENCH_ROOT is a LINKED worktree (its git-dir is under .../worktrees/), at .../.worktrees/<id>,
#    on branch work/<id> - NOT the main checkout, NOT another piece's worktree;
#  - PRODUCT_ROOT is THIS piece's product tree: single-repo it is WORKBENCH_ROOT/target (riding inside
#    the linked workbench worktree); two-repo it is .../.worktrees/product-<id>, a linked worktree on
#    branch work/<id> - never the main (shared) product checkout, never another piece's product tree.
# On refusal the worker STOPS and asks the orchestrator to `provision_worker.sh add <id>`; it must
# never edit or commit in the shared tree.
#
# The roots need NOT be in the environment. opencode Task subagents do not inherit the orchestrator's
# shell env across the dispatch boundary, so requiring an exported WORKBENCH_ROOT/PRODUCT_ROOT made the
# contract evaporate exactly when a worker was dispatched. <id> is the one value the dispatch reliably
# carries, and provision_worker.sh writes the worktrees at a deterministic layout, so this preflight
# DERIVES the canonical roots from <id> when they are unset (an explicitly-set root still wins and is
# then cross-checked). Derivation cannot weaken isolation: a root that was never provisioned is not a
# linked .worktrees/<id> worktree on work/<id>, so every assertion below still refuses it. With --export
# the verified roots are printed as `export VAR=...` lines (and nothing else on stdout) so a worker can
# load them into its own shell - out="$(... <id> --export)" || stop; eval "$out".
#
#   assert_isolated.sh <id> [--export]
# Exit: 0 isolated (safe to work); 2 NOT isolated (refuse - stop and ask for provisioning).
set -euo pipefail

fail() { echo "assert-isolated: $*" >&2; exit 2; }

ID=""; EXPORT=0
while [ "$#" -gt 0 ]; do
	case "$1" in
		--export) EXPORT=1 ;;
		--) shift; break ;;
		-*) fail "unknown option '$1' (usage: assert_isolated.sh <id> [--export])" ;;
		*) [ -z "$ID" ] && ID="$1" || fail "unexpected argument '$1' (usage: assert_isolated.sh <id> [--export])" ;;
	esac
	shift
done
[ -n "$ID" ] || fail "usage: assert_isolated.sh <id> [--export]"
# Same id shape provision_worker.sh accepts (a single safe path/branch component) - so a legitimately
# provisioned id is never refused here, and nothing outside that set is accepted.
case "$ID" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "id '$ID' must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes)" ;; esac

# Resolve the dispatch contract. An explicitly-provided root wins (and is cross-checked by every
# assertion below); when unset, DERIVE the canonical root from <id> and the provision_worker.sh layout,
# so a subagent that did not inherit the orchestrator's env is not stranded. default_product_root picks
# the execution mode exactly as provision_worker.sh does (0 two-repo, 10 single-repo, 2 wired-placeholder).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../conformance/lib/product-root.sh"
WB_MAIN="$(_pr_repo_root)" || fail "not inside a git repository - run from the workbench checkout"
if [ -z "${WORKBENCH_ROOT:-}" ]; then
	WORKBENCH_ROOT="$WB_MAIN/.worktrees/$ID"
fi
if [ -z "${PRODUCT_ROOT:-}" ]; then
	set +e; default_product_root >/dev/null; _prc=$?; set -e
	case "$_prc" in
		0)  PRODUCT_ROOT="$WB_MAIN/.worktrees/product-$ID" ;;   # two-repo: separate product worktree
		10) PRODUCT_ROOT="$WORKBENCH_ROOT/target" ;;            # single-repo: TARGET rides in the workbench worktree
		*)  fail "port/product.yaml is wired but its checkout is unset/placeholder - cannot derive PRODUCT_ROOT; ask the orchestrator to 'provision_worker.sh add $ID' (UNRELIABLE)" ;;
	esac
fi
[ -d "$WORKBENCH_ROOT" ] || fail "no provisioned workbench worktree at '$WORKBENCH_ROOT' - STOP and ask the orchestrator to 'provision_worker.sh add $ID' (do not edit or commit in the shared tree)"
[ -d "$PRODUCT_ROOT" ]   || fail "no provisioned product worktree at '$PRODUCT_ROOT' - STOP and ask the orchestrator to 'provision_worker.sh add $ID'"
wb_real="$(cd "$WORKBENCH_ROOT" && pwd -P)" || fail "WORKBENCH_ROOT '$WORKBENCH_ROOT' is unreachable"
pr_real="$(cd "$PRODUCT_ROOT" && pwd -P)"   || fail "PRODUCT_ROOT '$PRODUCT_ROOT' is unreachable"

# WORKBENCH_ROOT must be THIS piece's linked workbench worktree on work/<id>. A LINKED worktree's
# git-dir lives under <repo>/.git/worktrees/<name>; the MAIN checkout's is the bare .git dir - so a
# git-dir path containing /worktrees/ distinguishes an isolated worktree from the shared checkout.
wb_gitdir="$(git -C "$wb_real" rev-parse --git-dir 2>/dev/null)" \
	|| fail "WORKBENCH_ROOT '$WORKBENCH_ROOT' is not inside a git repository"
case "$wb_gitdir" in
	*/worktrees/*) : ;;
	*) fail "WORKBENCH_ROOT '$WORKBENCH_ROOT' is the MAIN checkout, not a linked .worktrees/$ID worktree - editing here races every sibling worker; STOP and ask for 'provision_worker.sh add $ID'" ;;
esac
case "$wb_real" in
	*/.worktrees/"$ID") : ;;
	*) fail "WORKBENCH_ROOT '$WORKBENCH_ROOT' is not .../.worktrees/$ID - is this another piece's worktree? STOP and ask for 'provision_worker.sh add $ID'" ;;
esac
wb_branch="$(git -C "$wb_real" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
[ "$wb_branch" = "work/$ID" ] \
	|| fail "WORKBENCH_ROOT is on '$wb_branch', not branch 'work/$ID' - commit only on your own work/$ID branch"

# PRODUCT_ROOT must be THIS piece's product tree - not the shared checkout, NOR another piece's.
if [ "$pr_real" = "$wb_real/target" ]; then
	: # single-repo: the product rides inside THIS piece's workbench worktree (already proven isolated + work/<id>)
else
	# two-repo: this piece's own product worktree, a linked worktree on work/<id>.
	case "$pr_real" in
		*/.worktrees/product-"$ID") : ;;
		*) fail "PRODUCT_ROOT '$PRODUCT_ROOT' is neither this piece's '$WORKBENCH_ROOT/target' (single-repo) nor '.../.worktrees/product-$ID' (two-repo) - it may be the shared or another piece's product tree; STOP and ask for 'provision_worker.sh add $ID'" ;;
	esac
	pr_gitdir="$(git -C "$pr_real" rev-parse --git-dir 2>/dev/null)" \
		|| fail "PRODUCT_ROOT '$PRODUCT_ROOT' is not inside a git repository"
	case "$pr_gitdir" in
		*/worktrees/*) : ;;
		*) fail "PRODUCT_ROOT '$PRODUCT_ROOT' is the MAIN (shared) product checkout, not a linked per-piece worktree; STOP and ask for 'provision_worker.sh add $ID'" ;;
	esac
	pr_branch="$(git -C "$pr_real" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
	[ "$pr_branch" = "work/$ID" ] \
		|| fail "PRODUCT_ROOT is on '$pr_branch', not branch 'work/$ID' - it may be another piece's product worktree"
fi

# --- Freshness: worktree must not be behind the mainline tip --------------
# A worktree provisioned at the mainline tip at provision time becomes stale the
# instant the mainline moves: its checkers are now old, its brief may cite
# dead SHAs. Measure staleness as: merge-base(worktree HEAD, mainline tip)
# behind mainline tip. If the merge-base equals the tip, the worktree is
# fresh - even if it is AHEAD with local commits (being ahead is normal work,
# not staleness). If the merge-base is behind the tip, the worktree is N
# commits stale.
#
# Why REFUSE instead of auto-rebase: a rebase can conflict, and a tool that
# silently rewrites a worker's branch mid-flight is worse than a stop. The
# refusal names the exact one-copy-paste remedy.
# Three-state: undeterminable (no mainline ref, detached HEAD, no merge-base)
# is UNRELIABLE, never a pass - the same fail-closed contract as elsewhere.
_mainline_ref=""; _mainline_tip=""
# Preferred: the workbench's canonical mainline. Local branch is the ground truth
# (it moves on every land); remote-tracking may lag until the next fetch. Use
# only fully-qualified refs so a tag named `main` cannot masquerade as a branch
# (F-03). Try local branch refs first, then the remote HEAD pointer, then
# remote-tracking branch refs.
for _cand in refs/heads/main refs/heads/master; do
	if _tip="$(git -C "$WB_MAIN" rev-parse --verify "$_cand" 2>/dev/null)"; then
		_mainline_ref="$_cand"; _mainline_tip="$_tip"
		break
	fi
done
if [ -z "$_mainline_tip" ] && _origin_head="$(git -C "$WB_MAIN" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
	if _tip="$(git -C "$WB_MAIN" rev-parse --verify "$_origin_head" 2>/dev/null)"; then
		_mainline_ref="$_origin_head"; _mainline_tip="$_tip"
	fi
fi
if [ -z "$_mainline_tip" ]; then
	for _cand in refs/remotes/origin/main refs/remotes/origin/master; do
		if _tip="$(git -C "$WB_MAIN" rev-parse --verify "$_cand" 2>/dev/null)"; then
			_mainline_ref="$_cand"; _mainline_tip="$_tip"
			break
		fi
	done
fi
[ -n "$_mainline_tip" ] || fail "cannot determine mainline tip (no main/origin/main) - freshness UNDETERMINABLE (UNRELIABLE); ensure the mainline branch exists and is fetched"
# Worktree HEAD must be determinable and not detached.
_wt_head="$(git -C "$wb_real" rev-parse HEAD 2>/dev/null)" \
	|| fail "cannot determine worktree HEAD at '$wb_real' - freshness UNDETERMINABLE (UNRELIABLE)"
if ! git -C "$wb_real" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
	fail "worktree HEAD at '$wb_real' is detached - freshness UNDETERMINABLE (UNRELIABLE); re-attach to 'work/$ID'"
fi
_wt_mb="$(git -C "$wb_real" merge-base HEAD "$_mainline_tip" 2>/dev/null)" \
	|| fail "cannot determine merge-base of worktree HEAD '$_wt_head' with mainline '$_mainline_ref' ('$_mainline_tip') - freshness UNDETERMINABLE (UNRELIABLE)"
if [ "$_wt_mb" != "$_mainline_tip" ]; then
	_behind="$(git -C "$wb_real" rev-list --count "$_wt_mb".."$_mainline_tip" 2>/dev/null)" \
		|| fail "cannot count commits between merge-base '$_wt_mb' and mainline tip '$_mainline_tip' - freshness UNDETERMINABLE (UNRELIABLE)"
	# _behind > 0 means stale; 0 would mean equal (already handled) - but count
	# defensively: any non-zero that slipped past the equality check is stale.
	case "$_behind" in ''|*[!0-9]*) fail "cannot determine staleness count (got '$_behind') - freshness UNDETERMINABLE (UNRELIABLE)" ;; esac
	if [ "$_behind" -gt 0 ]; then
		_mb_short="$(git -C "$wb_real" rev-parse --short "$_wt_mb" 2>/dev/null || printf '%s' "$_wt_mb")"
		_tip_short="$(git -C "$WB_MAIN" rev-parse --short "$_mainline_tip" 2>/dev/null || printf '%s' "$_mainline_tip")"
		fail "worktree '$wb_real' is STALE - $_behind commit(s) behind mainline '$_mainline_ref' (merge-base $_mb_short is behind tip $_tip_short). To fix, run:  git fetch origin && git -C \"$wb_real\" rebase \"$_mainline_ref\"  # or: git -C \"$wb_real\" rebase \"$WB_MAIN\"'s mainline"
	fi
fi
# Also check product worktree freshness when two-repo (separate product repo).
# Fail closed on every undeterminable product state (F-02): no product mainline,
# detached product HEAD, or missing merge-base must be UNRELIABLE, never a pass.
if [ "$pr_real" != "$wb_real/target" ]; then
	_prod_main_ref=""; _prod_main_tip=""
	for _p_cand in refs/heads/main refs/heads/master; do
		if _p_tip="$(git -C "$pr_real" rev-parse --verify "$_p_cand" 2>/dev/null)"; then
			_prod_main_ref="$_p_cand"; _prod_main_tip="$_p_tip"
			break
		fi
	done
	if [ -z "$_prod_main_tip" ] && _p_origin_head="$(git -C "$pr_real" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
		if _p_tip="$(git -C "$pr_real" rev-parse --verify "$_p_origin_head" 2>/dev/null)"; then
			_prod_main_ref="$_p_origin_head"; _prod_main_tip="$_p_tip"
		fi
	fi
	if [ -z "$_prod_main_tip" ]; then
		for _p_cand in refs/remotes/origin/main refs/remotes/origin/master; do
			if _p_tip="$(git -C "$pr_real" rev-parse --verify "$_p_cand" 2>/dev/null)"; then
				_prod_main_ref="$_p_cand"; _prod_main_tip="$_p_tip"
				break
			fi
		done
	fi
	[ -n "$_prod_main_tip" ] || fail "cannot determine product mainline tip (no refs/heads/main or refs/remotes/origin/main) - freshness UNDETERMINABLE (UNRELIABLE); ensure the product mainline branch exists and is fetched"
	_pr_head="$(git -C "$pr_real" rev-parse HEAD 2>/dev/null)" \
		|| fail "cannot determine product worktree HEAD at '$pr_real' - freshness UNDETERMINABLE (UNRELIABLE)"
	if ! git -C "$pr_real" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
		fail "product worktree HEAD at '$pr_real' is detached - freshness UNDETERMINABLE (UNRELIABLE); re-attach to 'work/$ID'"
	fi
	_pr_mb="$(git -C "$pr_real" merge-base HEAD "$_prod_main_tip" 2>/dev/null)" \
		|| fail "cannot determine merge-base of product worktree HEAD '$_pr_head' with product mainline '$_prod_main_ref' ('$_prod_main_tip') - freshness UNDETERMINABLE (UNRELIABLE)"
	if [ "$_pr_mb" != "$_prod_main_tip" ]; then
		_pr_behind="$(git -C "$pr_real" rev-list --count "$_pr_mb".."$_prod_main_tip" 2>/dev/null)" \
			|| fail "cannot count product commits between merge-base '$_pr_mb' and product mainline tip '$_prod_main_tip' - freshness UNDETERMINABLE (UNRELIABLE)"
		case "$_pr_behind" in ''|*[!0-9]*) fail "cannot determine product staleness count (got '$_pr_behind') - freshness UNDETERMINABLE (UNRELIABLE)" ;; esac
		if [ "$_pr_behind" -gt 0 ]; then
			_pr_mb_s="$(git -C "$pr_real" rev-parse --short "$_pr_mb" 2>/dev/null || printf '%s' "$_pr_mb")"
			_pr_tip_s="$(git -C "$pr_real" rev-parse --short "$_prod_main_tip" 2>/dev/null || printf '%s' "$_prod_main_tip")"
			fail "product worktree '$pr_real' is STALE - $_pr_behind commit(s) behind product mainline '$_prod_main_ref' (merge-base $_pr_mb_s is behind tip $_pr_tip_s). To fix, run:  git fetch origin && git -C \"$pr_real\" rebase \"$_prod_main_ref\""
		fi
	fi
fi

if [ "$EXPORT" -eq 1 ]; then
	# --export: ONLY shell-evalable assignments on stdout (human note to stderr), so a worker can load
	# the verified roots - out="$(assert_isolated.sh $ID --export)" || stop; eval "$out". %q quotes safely.
	printf 'export WORKBENCH_ROOT=%q\n' "$wb_real"
	printf 'export PRODUCT_ROOT=%q\n'   "$pr_real"
	echo "assert-isolated: OK - confined to .worktrees/$ID (workbench on work/$ID) and this piece's isolated product tree; roots exported." >&2
else
	echo "assert-isolated: OK - confined to .worktrees/$ID (workbench on work/$ID) and this piece's isolated product tree; safe to work."
fi
