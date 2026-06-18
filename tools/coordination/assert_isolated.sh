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

if [ "$EXPORT" -eq 1 ]; then
	# --export: ONLY shell-evalable assignments on stdout (human note to stderr), so a worker can load
	# the verified roots - out="$(assert_isolated.sh $ID --export)" || stop; eval "$out". %q quotes safely.
	printf 'export WORKBENCH_ROOT=%q\n' "$wb_real"
	printf 'export PRODUCT_ROOT=%q\n'   "$pr_real"
	echo "assert-isolated: OK - confined to .worktrees/$ID (workbench on work/$ID) and this piece's isolated product tree; roots exported." >&2
else
	echo "assert-isolated: OK - confined to .worktrees/$ID (workbench on work/$ID) and this piece's isolated product tree; safe to work."
fi
