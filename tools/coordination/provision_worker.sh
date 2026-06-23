#!/usr/bin/env bash
# provision_worker.sh - the orchestrator-owned worktree provisioner that makes
# one-writer-per-worktree STRUCTURAL instead of a worker promise.
#
# opencode Task subagents share the caller's checkout (there is no per-subagent cwd), so many
# parallel Kha-Workers would otherwise contend on one working tree - and, in the two-repo layout,
# on one shared PRODUCT checkout (tools/conformance/lib/product-root.sh resolves every linked
# worktree back to the single sibling product). This tool gives each piece its own isolated
# worktree(s) up front, on its own branch, writes the LOCAL claim port/claims/<id>.yaml (the
# worktree IS the lock), and prints the exact dispatch contract the worker runs against.
# Ptah-Orchestrator owns this lifecycle; workers NEVER run git worktree/gc themselves.
#
# It is the ONLY actor that mutates worktree metadata, and it serializes every add/remove/prune
# behind a repo-local lock, so concurrent dispatches cannot race on .git/worktrees/.
#
#   provision_worker.sh add <id> [--base <ref>] [--product-base <ref>] [--claimant <id>]  provision worktree(s) + local claim; print the contract
#   provision_worker.sh remove <id>               tear the worker's worktree(s) + branch(es) down (claim is NOT freed - see release_claim.sh)
#   provision_worker.sh print <id>                re-print the dispatch contract for an existing provision
#
# Isolation model (printed as the contract):
#   - WORKBENCH_ROOT = <wb>/.worktrees/<id>      a workbench worktree on branch work/<id> (state, fragment, evidence)
#   - single-repo (no port/product.yaml): PRODUCT_ROOT = WORKBENCH_ROOT/target  (TARGET code rides inside that worktree)
#   - two-repo (product.yaml wired):      PRODUCT_ROOT = <wb>/.worktrees/product-<id>  a SEPARATE product-repo worktree
# The worker runs `git -C "$WORKBENCH_ROOT"` for state and `git -C "$PRODUCT_ROOT"` (+ PRODUCT_ROOT exported
# for gates) for TARGET code. It pushes nothing: the claim is the local file written here, and the eventual merge goes through the sanctioned land path, never an ad-hoc keystroke.
#
# Exit: 0 done; 2 refused (bad usage / UNRELIABLE product wiring) - on refusal nothing is created.
set -euo pipefail

fail() { echo "provision_worker: $*" >&2; exit 2; }
note() { echo "provision_worker: $*" >&2; }

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../conformance/lib/product-root.sh"

CMD="${1:-}"; [ -n "$CMD" ] || fail "usage: provision_worker.sh {add|remove|print} <id> [--base <ref>] [--product-base <ref>] [--claimant <id>]"
shift || true
ID="${1:-}"; [ -n "$ID" ] || fail "missing <id>: provision_worker.sh $CMD <id>"
shift || true
BASE="HEAD"
PRODUCT_BASE=""   # two-repo only: override the product worktree base (default: product default_branch).
CLAIMANT=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--base) BASE="${2:-}"; shift 2 ;;
		--product-base) PRODUCT_BASE="${2:-}"; shift 2 ;;
		--claimant) CLAIMANT="${2:-}"; shift 2 ;;
		*) fail "unexpected argument: $1" ;;
	esac
done
# <id> becomes a branch (work/<id>) and a path (.worktrees/<id>); keep it a single safe component.
case "$ID" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "id '$ID' must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes)" ;; esac

WB="$(_pr_repo_root)" || fail "not inside a git repository"
cd "$WB"
BR="work/$ID"
WB_WT="$WB/.worktrees/$ID"
PROD_WT="$WB/.worktrees/product-$ID"

# Resolve the canonical product checkout and the execution MODE. default_product_root: 0 wired,
# 10 single-repo fallback (target/), 2 placeholder. A wired-but-missing checkout is UNRELIABLE -
# we cannot give the worker an isolated product, so we refuse rather than silently share the tree.
# default_product_root SIGNALS via return code (0 wired / 10 single-repo / 2 placeholder); it is a
# product-root.sh helper written for `set -uo pipefail` (no -e), so capture it with -e suspended.
set +e; PROD_CANON="$(default_product_root)"; PRC=$?; set -e
MODE="single-repo"; PROD_REPO_ROOT=""; PROD_DEFAULT=""
if [ "$PRC" -eq 2 ]; then
	fail "port/product.yaml is wired but its checkout is unset/placeholder - set it before provisioning (UNRELIABLE)"
elif [ "$PRC" -eq 0 ]; then
	[ -d "$PROD_CANON" ] || fail "product is wired but its checkout '$PROD_CANON' is absent - clone/checkout it first (UNRELIABLE)"
	PROD_REPO_ROOT="$(git -C "$PROD_CANON" rev-parse --show-toplevel 2>/dev/null)" || fail "product checkout '$PROD_CANON' is not a git repo"
	MODE="two-repo"
	PROD_DEFAULT="$(sed -nE 's/^[[:space:]]*default_branch:[[:space:]]*(.*)$/\1/p' port/product.yaml | head -1 | sed -E 's/[[:space:]]*#.*$//; s/^["'\'']//; s/["'\'']$//; s/[[:space:]]*$//')"
	[ -n "$PROD_DEFAULT" ] || PROD_DEFAULT="main"
fi

# Serialize all worktree metadata mutation: the provisioner is the single writer of .git/worktrees/.
LOCK="$(git rev-parse --path-format=absolute --git-common-dir)/chisel-provision.lock"
exec 9>"$LOCK"; flock 9

# ensure_worktree <repo_root> <abs_wt_path> <branch> <base> : idempotent (reuse if already present).
ensure_worktree() {
	local repo="$1" wt="$2" br="$3" base="$4"
	if git -C "$repo" worktree list --porcelain | grep -qxF "worktree $wt"; then return 0; fi
	if git -C "$repo" show-ref --verify --quiet "refs/heads/$br"; then
		git -C "$repo" worktree add "$wt" "$br" >&2
	else
		git -C "$repo" worktree add "$wt" -b "$br" "$base" >&2
	fi
}
remove_worktree() {  # <repo_root> <abs_wt_path> <branch>
	local repo="$1" wt="$2" br="$3"
	if git -C "$repo" worktree list --porcelain | grep -qxF "worktree $wt"; then
		git -C "$repo" worktree remove "$wt" 2>/dev/null || git -C "$repo" worktree remove --force "$wt" \
			|| note "WARNING: could not remove worktree $wt - remove it by hand"
	fi
	git -C "$repo" worktree prune
	git -C "$repo" branch -D "$br" 2>/dev/null || true   # best effort; only after the branch is merged
}

print_contract() {
	local base_wb base_prod prod_root prod_branch
	base_wb="$(git -C "$WB_WT" rev-parse HEAD 2>/dev/null || echo unknown)"
	if [ "$MODE" = "two-repo" ]; then
		prod_root="$PROD_WT"; prod_branch="$BR"
		base_prod="$(git -C "$PROD_WT" rev-parse HEAD 2>/dev/null || echo unknown)"
	else
		prod_root="$WB_WT/target"; prod_branch="$BR (single-repo: TARGET rides in the workbench worktree)"
		base_prod="$base_wb"
	fi
	cat <<CONTRACT
# Worker dispatch contract for '$ID' - pass these to Kha-Worker; it operates ONLY within these roots.
MODE=$MODE
CLAIM_ID=$ID
WORKBENCH_ROOT=$WB_WT
WORKBENCH_BRANCH=$BR
PRODUCT_ROOT=$prod_root
PRODUCT_BRANCH=$prod_branch
BASE_WORKBENCH=$base_wb
BASE_PRODUCT=$base_prod
EVIDENCE_PREFIX=docs/evidence/$ID/
CONTRACT
}

# write_local_claim: the worktree IS the write lock; this records what the claim covers as the
# LOCAL claim port/claims/<id>.yaml (the default store the planner/dashboard/check-claims read).
# Idempotent: an existing claim is left untouched. `source` is best-effort from the dependency-map
# node (enables duplicate-source detection); `paths` is the worker's write surface on the workbench
# branch (status + evidence, plus target/ in single-repo where TARGET code rides in this worktree).
# Local claims are ungitignored ephemeral coordination state; the advanced pushed-ref path is separate.
write_local_claim() {
	local claimant="$1"
	[ -n "$claimant" ] || claimant="$(git config user.name 2>/dev/null || true)"
	[ -n "$claimant" ] || claimant="worker"
	local cfile="$WB/port/claims/$ID.yaml"
	if [ -e "$cfile" ]; then note "claim port/claims/$ID.yaml already exists - left as is (idempotent)."; return 0; fi
	mkdir -p "$WB/port/claims"
	PW_ID="$ID" PW_CLAIMANT="$claimant" PW_MODE="$MODE" python3 - "$WB" "$cfile" <<'PY'
import os, sys, datetime
wb, cfile = sys.argv[1], sys.argv[2]
uid, claimant, mode = os.environ["PW_ID"], os.environ["PW_CLAIMANT"], os.environ["PW_MODE"]
created = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
source = None
try:
    import yaml
    sys.path.insert(0, os.path.join(wb, "tools", "coordination"))
    from dashboard import _strict_loader
    d = yaml.load(open(os.path.join(wb, "tools", "scoping", "dependency-map.yaml"), encoding="utf-8"),
                  Loader=_strict_loader(yaml)) or {}
    for n in (d.get("nodes") or []):
        if isinstance(n, dict) and str(n.get("id")) == uid and n.get("source"):
            source = str(n.get("source")); break
except Exception:
    source = None
paths = (["target/"] if mode == "single-repo" else []) + ["port/status/%s.yaml" % uid, "docs/evidence/%s/" % uid]
def q(s): return '"%s"' % str(s).replace('\\', '\\\\').replace('"', '\\"')
out = ["# Local claim (worktree-lock model) - the provisioned worktree is the write lock; this file",
       "# records what the claim covers. Default store: port/claims/ (local). See release_claim.sh.",
       "id: %s" % uid, "claimant: %s" % q(claimant), "created: %s" % created, "state: active"]
if source:
    out += ["source:", "  - %s" % source]
out += ["paths:"] + ["  - %s" % p for p in paths]
open(cfile, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
	note "wrote local claim port/claims/$ID.yaml (claimant '$claimant')."
}

case "$CMD" in
	add)
		ensure_worktree "$WB" "$WB_WT" "$BR" "$BASE"
		if [ "$MODE" = "two-repo" ]; then
			# Default the product worktree base to the product default_branch (main). An override
			# (--product-base) bases it on a different ref - used during bring-up so a worker's product
			# work/<id> branch CARRIES the accumulating closure from the bring-up preview (the skeleton +
			# already-reviewed peer pieces), letting it compile/test against them before any piece reaches
			# the gated mainline (the assembly-gating bring-up flow; references/two-repo-architecture.md).
			if [ -n "$PRODUCT_BASE" ]; then
				local_base="$PRODUCT_BASE"
			else
				local_base="$(git -C "$PROD_REPO_ROOT" rev-parse --verify -q "$PROD_DEFAULT" || git -C "$PROD_REPO_ROOT" rev-parse HEAD)"
			fi
			ensure_worktree "$PROD_REPO_ROOT" "$PROD_WT" "$BR" "$local_base"
		fi
		write_local_claim "$CLAIMANT"
		note "provisioned '$ID' ($MODE)."
		print_contract
		;;
	remove)
		[ "$MODE" != "two-repo" ] || remove_worktree "$PROD_REPO_ROOT" "$PROD_WT" "$BR"
		remove_worktree "$WB" "$WB_WT" "$BR"
		note "removed worktrees for '$ID'."
		;;
	print)
		git -C "$WB" worktree list --porcelain | grep -qxF "worktree $WB_WT" \
			|| fail "no provisioned worktree for '$ID' (run: provision_worker.sh add $ID)"
		print_contract
		;;
	*) fail "unknown command '$CMD' (use add|remove|print)" ;;
esac
