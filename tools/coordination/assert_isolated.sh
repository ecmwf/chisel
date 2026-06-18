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
#  - WORKBENCH_ROOT and PRODUCT_ROOT are set (the dispatch contract from provision_worker.sh);
#  - WORKBENCH_ROOT is a LINKED worktree (its git-dir is under .../worktrees/), at .../.worktrees/<id>,
#    on branch work/<id> - NOT the main checkout, NOT another piece's worktree;
#  - PRODUCT_ROOT is THIS piece's product tree: single-repo it is WORKBENCH_ROOT/target (riding inside
#    the linked workbench worktree); two-repo it is .../.worktrees/product-<id>, a linked worktree on
#    branch work/<id> - never the main (shared) product checkout, never another piece's product tree.
# On refusal the worker STOPS and asks the orchestrator to `provision_worker.sh add <id>`; it must
# never edit or commit in the shared tree.
#
#   assert_isolated.sh <id>
# Exit: 0 isolated (safe to work); 2 NOT isolated (refuse - stop and ask for provisioning).
set -euo pipefail

fail() { echo "assert-isolated: $*" >&2; exit 2; }

ID="${1:-}"
[ -n "$ID" ] || fail "usage: assert_isolated.sh <id>"
# Same id shape provision_worker.sh accepts (a single safe path/branch component) - so a legitimately
# provisioned id is never refused here, and nothing outside that set is accepted.
case "$ID" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "id '$ID' must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes)" ;; esac

[ -n "${WORKBENCH_ROOT:-}" ] || fail "WORKBENCH_ROOT is unset - you were dispatched with NO contract; STOP and ask the orchestrator to 'provision_worker.sh add $ID' (do not edit or commit in the shared tree)"
[ -n "${PRODUCT_ROOT:-}" ]   || fail "PRODUCT_ROOT is unset - no provisioned product worktree; STOP and ask the orchestrator to 'provision_worker.sh add $ID'"
[ -d "$WORKBENCH_ROOT" ] || fail "WORKBENCH_ROOT '$WORKBENCH_ROOT' is not a directory"
[ -d "$PRODUCT_ROOT" ]   || fail "PRODUCT_ROOT '$PRODUCT_ROOT' is not a directory"
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

echo "assert-isolated: OK - confined to .worktrees/$ID (workbench on work/$ID) and this piece's isolated product tree; safe to work."
