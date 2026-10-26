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
#   provision_worker.sh add <id> [--base <ref>] [--product-base <ref>] [--claimant <id>] [--claim-path <path>]...
#                                                    provision worktree(s) + local claim; print the contract
#   provision_worker.sh reconcile <id> --claim-path <path>...
#                                                    narrow an active legacy local claim
#   provision_worker.sh remove <id> [--discard-ungathered]
#                                                    tear the worker's worktree(s) + branch(es) down (claim is NOT freed - see release_claim.sh);
#                                                    REFUSES while the piece's workbench evidence is not on the trusted line (see "Teardown guard")
#   provision_worker.sh print <id>                   re-print the dispatch contract for an existing provision
#
# Isolation model (printed as the contract):
#   - WORKBENCH_ROOT = <wb>/.worktrees/<id>      a workbench worktree on branch work/<id> (state, fragment, evidence)
#   - single-repo (no port/product.yaml): PRODUCT_ROOT = WORKBENCH_ROOT/target  (TARGET code rides inside that worktree)
#   - two-repo (product.yaml wired):      PRODUCT_ROOT = <wb>/.worktrees/product-<id>  a SEPARATE product-repo worktree
# The worker runs `git -C "$WORKBENCH_ROOT"` for state and `git -C "$PRODUCT_ROOT"` (+ PRODUCT_ROOT exported
# for proofs) for TARGET code. It pushes nothing: the claim is the local file written here, and the eventual merge goes through the sanctioned land path, never an ad-hoc keystroke.
#
# Teardown guard (remove): the worker's worktree is where reviewers write their reports and the
# work/<id> branch is where the worker commits its fragment and proof evidence; a product land
# (integrate_product.sh) lands only the PRODUCT, so that workbench evidence survives only if it was
# gathered onto the trusted line (the workbench root's current HEAD). remove therefore inspects first
# and REFUSES - removing nothing - when the workbench worktree holds ANY uncommitted file, when
# work/<id> carries content the trusted line does not (see ungathered_paths), or (two-repo) when the
# product worktree holds any uncommitted file. It never falls back to --force. --discard-ungathered
# is the escape hatch for a genuinely ABANDONED piece: it lists every path it destroys, then forces.
#
# Exit: 0 done; 2 refused (bad usage / UNRELIABLE product wiring / teardown would destroy ungathered
# evidence) - on refusal nothing is created or removed; 1 remove started but a removal step failed
# (reported; nothing was forced, and the success line is not printed).
set -euo pipefail

fail() { echo "provision_worker: $*" >&2; exit 2; }
note() { echo "provision_worker: $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../conformance/lib/product-root.sh"

CMD="${1:-}"; [ -n "$CMD" ] || fail "usage: provision_worker.sh {add|reconcile|remove|print} <id> [options]"
shift || true
ID="${1:-}"; [ -n "$ID" ] || fail "missing <id>: provision_worker.sh $CMD <id>"
shift || true
BASE="HEAD"
PRODUCT_BASE=""   # two-repo only: override the product worktree base (default: product default_branch).
CLAIMANT=""
CLAIM_PATHS=()
NON_PATH_OPTION=0
DISCARD=0         # remove only: discard uncommitted + ungathered evidence of an ABANDONED piece.
while [ "$#" -gt 0 ]; do
	case "$1" in
		--discard-ungathered) DISCARD=1; NON_PATH_OPTION=1; shift ;;
		--base) [ "$#" -ge 2 ] || fail "--base needs a value"; BASE="$2"; NON_PATH_OPTION=1; shift 2 ;;
		--product-base) [ "$#" -ge 2 ] || fail "--product-base needs a value"; PRODUCT_BASE="$2"; NON_PATH_OPTION=1; shift 2 ;;
		--claimant) [ "$#" -ge 2 ] || fail "--claimant needs a value"; CLAIMANT="$2"; NON_PATH_OPTION=1; shift 2 ;;
		--claim-path) [ "$#" -ge 2 ] || fail "--claim-path needs a value"; CLAIM_PATHS+=("$2"); shift 2 ;;
		*) fail "unexpected argument: $1" ;;
	esac
done
[ "$DISCARD" -eq 0 ] || [ "$CMD" = "remove" ] || fail "--discard-ungathered is valid only with remove"
# <id> becomes a branch (work/<id>) and a path (.worktrees/<id>); keep it a single safe component.
case "$ID" in *[!A-Za-z0-9._-]*|""|.*|-*) fail "id '$ID' must match [A-Za-z0-9][A-Za-z0-9._-]* (no slashes)" ;; esac

if [ "${#CLAIM_PATHS[@]}" -gt 0 ]; then
	case "$CMD" in add|reconcile) ;; *) fail "--claim-path is valid only with add or reconcile" ;; esac
	claim_path_error=""
	if ! claim_path_error="$(python3 - "${CLAIM_PATHS[@]}" <<'PY'
import ntpath
import posixpath
import sys
import unicodedata

blanket = {"tools", "port", "docs", "source", "reference", "target"}
for path in sys.argv[1:]:
    if not path or not path.strip():
        print("--claim-path must not be empty")
        sys.exit(1)
    if path != path.strip():
        print("--claim-path must not have leading or trailing whitespace: %r" % path)
        sys.exit(1)
    if any(unicodedata.category(c) in ("Cc", "Cf") for c in path):
        print("--claim-path must not contain Unicode control or format characters")
        sys.exit(1)
    if any(c in path for c in "*?[]"):
        print("--claim-path must be concrete, not globbed: %s" % path)
        sys.exit(1)
    candidate = path.replace("\\", "/")
    drive, _tail = ntpath.splitdrive(path)
    if candidate.startswith("/") or drive:
        print("--claim-path must be repo-relative, not absolute or drive-qualified: %s" % path)
        sys.exit(1)
    if ".." in candidate.split("/"):
        print("--claim-path must not contain a '..' segment: %s" % path)
        sys.exit(1)
    clean = posixpath.normpath(candidate)
    if clean == ".":
        print("--claim-path must not name the repository root: %s" % path)
        sys.exit(1)
    if clean == ".." or clean.startswith("../"):
        print("--claim-path must not escape the repository root: %s" % path)
        sys.exit(1)
    if clean in blanket:
        print("--claim-path must not grant a blanket top-level root: %s" % path)
        sys.exit(1)
PY
)"; then
		fail "$claim_path_error"
	fi
elif [ "$CMD" = "reconcile" ]; then
	fail "reconcile requires at least one --claim-path"
fi
[ "$CMD" != "reconcile" ] || [ "$NON_PATH_OPTION" -eq 0 ] || fail "reconcile accepts only --claim-path options"

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
	PROD_DEFAULT="$(_pr_default_branch "$WB")" \
		|| fail "cannot read default_branch from port/product.yaml (see above) - refusing to guess the product base (UNRELIABLE)"
fi

# Serialize all worktree metadata mutation: the provisioner is the single writer of .git/worktrees/.
COMMON_DIR="$(_pr_common_dir)" || fail "cannot resolve the common git dir"
LOCK="$COMMON_DIR/chisel-provision.lock"
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
# worktree_uncommitted <repo_root> <abs_wt_path> : print the worktree's uncommitted paths (tracked-modified
# and untracked, porcelain). Prints nothing for an unregistered worktree or a registered one whose
# directory is already gone (nothing left on disk to lose; prune clears it). Non-zero = cannot tell.
worktree_uncommitted() {
	local repo="$1" wt="$2" list
	list="$(git -C "$repo" worktree list --porcelain)" || return 1
	grep -qxF "worktree $wt" <<<"$list" || return 0
	[ -d "$wt" ] || return 0
	git -C "$wt" -c core.quotePath=false status --porcelain --untracked-files=all --ignore-submodules=none
}

# ungathered_paths <repo_root> <branch> : print every path <branch> changed (against its merge-base with
# the trusted HEAD) whose content the trusted line does not provably carry. Nothing when the branch is
# absent or its tip is an ancestor of HEAD (fast-forward landed). A path HEAD holds exactly as the branch
# does (the same blob, or absent on both) is gathered. Otherwise:
#  - evidence (under $EVIDENCE_ROOT: review reports, proof logs, acceptance notes) is written once, so a
#    difference at HEAD means it was never gathered;
#  - a path the branch DELETED that HEAD still has was never gathered;
#  - any other path is state the trusted line may evolve after gathering it (the status fragment gains
#    the recorded ids, proof and integration state), so it is gathered iff the branch's EXACT blob was
#    committed at that path by some commit in merge-base..HEAD - a gather commit. Mere presence at HEAD,
#    or the same bytes only in history older than the merge-base, proves nothing.
# Paths travel NUL-delimited (any byte is safe); unusual ones print in escaped form. Non-zero = cannot
# tell (any git error) - the caller refuses.
EVIDENCE_ROOT="docs/evidence/"
ungathered_paths() {
	python3 - "$1" "refs/heads/$2" "$EVIDENCE_ROOT" <<'PY'
import os
import subprocess
import sys

repo, ref, evidence_root = sys.argv[1], sys.argv[2], sys.argv[3]

def git(args, ok=(0,)):
    proc = subprocess.run(["git", "-C", repo, "--literal-pathspecs"] + args,
                          stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if proc.returncode not in ok:
        sys.exit(1)
    return proc.returncode, proc.stdout

def object_id(rev):
    rc, out = git(["rev-parse", "-q", "--verify", rev], ok=(0, 1))
    return out.decode().strip() if rc == 0 else None

def nul_fields(data):
    return [os.fsdecode(item) for item in data.split(b"\0")[:-1]]

def show(path):
    text = path if path.isprintable() else ascii(path)
    sys.stdout.buffer.write(os.fsencode(text) + b"\n")

def gathered_in_history(path, blob):
    _, out = git(["log", "--format=%H", "--full-history", history, "--", path])
    return any(object_id(commit + ":" + path) == blob for commit in out.decode().split())

tip = object_id(ref + "^{commit}")
if tip is None:
    sys.exit(0)
head = object_id("HEAD^{commit}")
if head is None:
    sys.exit(1)
if git(["merge-base", "--is-ancestor", tip, head], ok=(0, 1))[0] == 0:
    sys.exit(0)
rc, out = git(["merge-base", head, tip], ok=(0, 1))
if rc == 0:
    base = out.decode().strip()
    history = base + ".." + head
else:  # unrelated histories: everything on the branch is its own; search all of HEAD's history
    base = git(["hash-object", "-t", "tree", "/dev/null"])[1].decode().strip()
    history = head

changed = set(nul_fields(git(["diff", "--no-color", "--name-only", "-z", "--no-renames", base, tip])[1]))
raw = nul_fields(git(["diff", "--no-color", "--raw", "-z", "--no-abbrev", "--no-renames", head, tip])[1])
for meta, path in zip(raw[0::2], raw[1::2]):  # meta: ":<HEAD mode> <tip mode> <HEAD blob> <tip blob> <status>"
    if path not in changed:
        continue
    _, _, head_blob, tip_blob, status = meta.split()
    if head_blob == tip_blob:
        continue
    if path.startswith(evidence_root) or status == "D":
        show(path)
    elif not gathered_in_history(path, tip_blob):
        show(path)
PY
}

# remove_worktree <repo_root> <abs_wt_path> <branch> : remove the worktree WITHOUT --force (git itself
# refuses a dirty tree - a second barrier behind the guard), unless the operator passed
# --discard-ungathered; then prune and delete the branch. Its caller has already established that
# deleting the branch loses nothing (or the operator chose to discard). Non-zero = a step failed.
remove_worktree() {
	local repo="$1" wt="$2" br="$3" list
	list="$(git -C "$repo" worktree list --porcelain)" || { note "cannot list worktrees of $repo"; return 1; }
	if grep -qxF "worktree $wt" <<<"$list"; then
		if [ "$DISCARD" -eq 1 ]; then
			git -C "$repo" worktree remove --force "$wt" >&2 || { note "could not remove worktree $wt"; return 1; }
		else
			git -C "$repo" worktree remove "$wt" >&2 \
				|| { note "could not remove worktree $wt (it was NOT forced - forcing deletes files); fix the cause and re-run remove"; return 1; }
		fi
	fi
	git -C "$repo" worktree prune
	if git -C "$repo" show-ref --verify --quiet "refs/heads/$br"; then
		git -C "$repo" branch -D "$br" >&2 || { note "could not delete branch $br in $repo"; return 1; }
	fi
}

# list_paths <header> <newline-separated paths> : report a set of at-risk paths, one per line.
list_paths() {
	local line
	[ -n "$2" ] || return 0
	note "$1"
	while IFS= read -r line; do note "    $line"; done <<<"$2"
}

print_contract() {
	local base_wb base_prod prod_root prod_branch ev_prefix
	base_wb="$(git -C "$WB_WT" rev-parse HEAD 2>/dev/null || echo unknown)"
	# The evidence root DIFFERS by phase, and a worker told the wrong one writes evidence the
	# driver can never see - the unit then never becomes acceptable, with nothing reporting why.
	# Phase-1 tooling units are validated by phase1_drive.py against docs/evidence/phase1/<id>/;
	# Phase-2 translation units use docs/evidence/<id>/. Derive it from the plan rather than
	# emitting one prefix for both: if this id is a unit in the Phase-1 plan, it is a Phase-1 unit.
	ev_prefix="docs/evidence/$ID/"
	if [ -f "$WB/port/phase1-plan.yaml" ] \
		&& grep -Eq "^[[:space:]]*-[[:space:]]*id:[[:space:]]*[\"']?${ID}[\"']?[[:space:]]*$" \
			"$WB/port/phase1-plan.yaml" 2>/dev/null; then
		ev_prefix="docs/evidence/phase1/$ID/"
	fi
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
EVIDENCE_PREFIX=$ev_prefix
CONTRACT
}

# write_local_claim: the worktree IS the write lock; this records what the claim covers as the
# LOCAL claim port/claims/<id>.yaml (the default store the planner/dashboard/check-claims read).
# Idempotent without explicit paths: an existing claim is left untouched. `source` is best-effort
# from the dependency-map node (enables duplicate-source detection); `paths` is the worker's write
# surface on the workbench branch. Explicit paths replace the shared status/evidence defaults;
# single-repo claims still include target/, where TARGET code rides in this worktree.
# Local claims are ungitignored ephemeral coordination state; the advanced pushed-ref path is separate.
write_local_claim() {
	local claimant="$1"
	[ -n "$claimant" ] || claimant="$(git config user.name 2>/dev/null || true)"
	[ -n "$claimant" ] || claimant="worker"
	local cfile="$WB/port/claims/$ID.yaml"
	if [ -e "$cfile" ]; then
		[ "${#CLAIM_PATHS[@]}" -eq 0 ] || fail "claim port/claims/$ID.yaml already exists; use reconcile to replace an exact legacy claim"
		note "claim port/claims/$ID.yaml already exists - left as is (idempotent)."; return 0
	fi
	mkdir -p "$WB/port/claims"
	PW_ID="$ID" PW_CLAIMANT="$claimant" PW_MODE="$MODE" python3 - "$WB" "$cfile" "${CLAIM_PATHS[@]}" <<'PY'
import os, re, sys, datetime
wb, cfile = sys.argv[1], sys.argv[2]
uid, claimant, mode = os.environ["PW_ID"], os.environ["PW_CLAIMANT"], os.environ["PW_MODE"]
explicit_paths = sys.argv[3:]
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
if explicit_paths:
    paths = (["target/"] if mode == "single-repo" else []) + explicit_paths
else:
    paths = (["target/"] if mode == "single-repo" else []) + ["port/status/%s.yaml" % uid, "docs/evidence/%s/" % uid]
def q(s): return '"%s"' % str(s).replace('\\', '\\\\').replace('"', '\\"')
def path_value(s): return s if re.match(r"^[A-Za-z0-9_./-]+$", s) else q(s)
out = ["# Local claim (worktree-lock model) - the provisioned worktree is the write lock; this file",
       "# records what the claim covers. Default store: port/claims/ (local). See release_claim.sh.",
       "id: %s" % uid, "claimant: %s" % q(claimant), "created: %s" % created, "state: active"]
if source:
    out += ["source:", "  - %s" % source]
out += ["paths:"] + ["  - %s" % path_value(p) for p in paths]
open(cfile, "w", encoding="utf-8").write("\n".join(out) + "\n")
PY
	note "wrote local claim port/claims/$ID.yaml (claimant '$claimant')."
}

reconcile_local_claim() {
	local cfile="$WB/port/claims/$ID.yaml" actual_branch result
	git -C "$WB" worktree list --porcelain | grep -qxF "worktree $WB_WT" \
		|| fail "cannot reconcile orphan claim: '$WB_WT' is not a registered worktree"
	[ -d "$WB_WT" ] || fail "cannot reconcile orphan claim: registered worktree '$WB_WT' is absent"
	actual_branch="$(git -C "$WB_WT" symbolic-ref --quiet HEAD 2>/dev/null)" \
		|| fail "cannot reconcile claim: '$WB_WT' is detached"
	[ "$actual_branch" = "refs/heads/$BR" ] \
		|| fail "cannot reconcile claim: '$WB_WT' is on '$actual_branch', expected 'refs/heads/$BR'"
	[ -f "$cfile" ] && [ ! -L "$cfile" ] || fail "cannot reconcile: local claim port/claims/$ID.yaml is absent or not a regular file"

	if ! result="$(PW_ID="$ID" PW_MODE="$MODE" PW_COORD_DIR="$SCRIPT_DIR" python3 - "$cfile" "${CLAIM_PATHS[@]}" <<'PY'
import datetime
import ntpath
import os
import posixpath
import re
import stat
import sys
import tempfile
import unicodedata

cfile = sys.argv[1]
explicit = sys.argv[2:]
uid = os.environ["PW_ID"]
mode = os.environ["PW_MODE"]

def refuse(message):
    print(message)
    sys.exit(1)

try:
    import yaml
    sys.path.insert(0, os.environ["PW_COORD_DIR"])
    from _chisel_lib import strict_loader
except Exception as exc:
    refuse("cannot load strict YAML support (%s)" % exc)

try:
    with open(cfile, "r", encoding="utf-8", newline="") as fh:
        text = fh.read()
    claim = yaml.load(text, Loader=strict_loader(yaml))
except Exception as exc:
    refuse("claim is not valid strict YAML (%s)" % exc)

header = ("# Local claim (worktree-lock model) - the provisioned worktree is the write lock; this file\n"
          "# records what the claim covers. Default store: port/claims/ (local). See release_claim.sh.\n")
if not isinstance(claim, dict) or str(claim.get("id")) != uid:
    refuse("claim id does not match %s" % uid)
if str(claim.get("state")) != "active":
    refuse("claim state is not active")
if "claimant" not in claim or "created" not in claim:
    refuse("claim is missing provisioner metadata")

reconcile_marker = "# Explicit claim paths set by provision_worker.sh reconcile."
if not text.startswith(header):
    allowed = {"id", "claimant", "created", "state", "source", "target", "paths", "threads"}
    unknown = set(claim) - allowed
    if unknown:
        refuse("headerless claim has unexpected top-level field(s): %s" %
               ", ".join(sorted(str(key) for key in unknown)))
    required = {"id", "claimant", "created", "state", "paths", "threads"}
    missing = required - set(claim)
    if missing:
        refuse("headerless claim is missing normalized field(s): %s" % ", ".join(sorted(missing)))
    if not isinstance(claim.get("id"), str) or claim["id"] != uid:
        refuse("headerless claim id is not the normalized provisioned id")
    claimant = claim.get("claimant")
    if not isinstance(claimant, str) or not claimant.strip():
        refuse("headerless claim claimant is not a non-empty normalized string")
    created = claim.get("created")
    if (not isinstance(created, datetime.datetime) or created.tzinfo is None or
            created.utcoffset() != datetime.timedelta(0) or created.microsecond != 0):
        refuse("headerless claim created is not a provisioner UTC timestamp")

    comments = [line.strip() for line in text.splitlines() if line.lstrip().startswith("#")]
    if any(line != reconcile_marker for line in comments) or comments.count(reconcile_marker) > 1:
        refuse("headerless claim has comments not emitted by reconciliation")

    for field in ("source", "target"):
        if field not in claim:
            continue
        values = claim[field]
        if not isinstance(values, list) or not values:
            refuse("headerless claim %s metadata is not a non-empty path list" % field)
        for value in values:
            if not isinstance(value, str) or not value or value != value.strip():
                refuse("headerless claim %s metadata has an invalid path" % field)
            candidate = value.replace("\\", "/")
            drive, _tail = ntpath.splitdrive(value)
            clean = posixpath.normpath(candidate)
            if (candidate.startswith("/") or drive or ".." in candidate.split("/") or
                    clean in (".", "..") or clean.startswith("../") or
                    any(char in value for char in "*?[]") or
                    any(unicodedata.category(char) in ("Cc", "Cf") for char in value)):
                refuse("headerless claim %s metadata has a non-concrete path" % field)

    threads = claim.get("threads")
    if not isinstance(threads, dict) or not threads:
        refuse("headerless claim threads is not a non-empty mapping")
    session_ids = []
    for role, session_id in threads.items():
        if role not in ("worker", "reviewer"):
            refuse("headerless claim threads has an unknown role")
        if not isinstance(session_id, str) or not re.fullmatch(r"ses_[A-Za-z0-9]+", session_id):
            refuse("headerless claim threads.%s is not a session id" % role)
        session_ids.append(session_id)
    if len(session_ids) != len(set(session_ids)):
        refuse("headerless claim reuses one session id across roles")

legacy = (["target/"] if mode == "single-repo" else []) + [
    "port/status/%s.yaml" % uid,
    "docs/evidence/%s/" % uid,
]
desired = (["target/"] if mode == "single-repo" else []) + explicit
current = claim.get("paths")
if current == desired:
    if current != legacy and reconcile_marker not in text.splitlines():
        refuse("claim already has the requested non-legacy paths without a reconciliation marker; refusing pre-broadened claim")
    print("claim port/claims/%s.yaml already has the explicit path set (unchanged)." % uid)
    sys.exit(0)
if current != legacy:
    refuse("claim paths are not the exact legacy default; refusing stale or pre-broadened claim")

lines = text.splitlines(keepends=True)
key_lines = [i for i, line in enumerate(lines)
             if re.match(r"^paths:[ \t]*(?:#[^\r\n]*)?(?:\r\n|\n)?$", line)]
if len(key_lines) != 1:
    refuse("claim does not have one provisioner-style paths block")
start = key_lines[0] + 1
end = len(lines)
for i in range(start, len(lines)):
    body = lines[i].rstrip("\r\n")
    if body and not body[0].isspace() and not body.startswith("#"):
        end = i
        break
item_lines = [i for i in range(start, end) if re.match(r"^[ \t]+-[ \t]+", lines[i])]
if len(item_lines) != len(legacy):
    refuse("claim paths block is not the exact provisioner list shape")

first = item_lines[0]
match = re.match(r"^([ \t]+-[ \t]+)", lines[first])
prefix = match.group(1)
newline = "\r\n" if lines[first].endswith("\r\n") else "\n"

def path_value(path):
    if re.match(r"^[A-Za-z0-9_./-]+$", path):
        return path
    return '"%s"' % path.replace("\\", "\\\\").replace('"', '\\"')

comments = []
for i in item_lines:
    body = lines[i].rstrip("\r\n")
    marker = body.find(" #")
    comments.append(body[marker:] if marker >= 0 else "")
new_items = []
for i, path in enumerate(desired):
    suffix = comments[i] if i < len(comments) else ""
    new_items.append(prefix + path_value(path) + suffix + newline)
for comment in comments[len(desired):]:
    if comment:
        new_items.append(prefix.split("-")[0] + comment.lstrip() + newline)

item_set = set(item_lines)
replacement = lines[:first] + new_items + [lines[i] for i in range(first, end) if i not in item_set] + lines[end:]
key_index = key_lines[0]
marker_newline = "\r\n" if lines[key_index].endswith("\r\n") else "\n"
replacement.insert(key_index, reconcile_marker + marker_newline)
updated = "".join(replacement)
mode_bits = stat.S_IMODE(os.stat(cfile, follow_symlinks=False).st_mode)
fd, tmp = tempfile.mkstemp(prefix=".%s." % os.path.basename(cfile), dir=os.path.dirname(cfile))
try:
    os.fchmod(fd, mode_bits)
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
        fh.write(updated)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp, cfile)
except Exception:
    try:
        os.close(fd)
    except OSError:
        pass
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print("reconciled local claim port/claims/%s.yaml to the explicit path set." % uid)
PY
)"; then
		fail "$result"
	fi
	note "$result"
}

case "$CMD" in
	add)
		ensure_worktree "$WB" "$WB_WT" "$BR" "$BASE"
		if [ "$MODE" = "two-repo" ]; then
			# Default the product worktree base to the product default_branch (main). An override
			# (--product-base) bases it on a different ref - used during bring-up so a worker's product
			# work/<id> branch CARRIES the accumulating closure from the bring-up preview (the skeleton +
			# already-reviewed peer pieces), letting it compile/test against them before any piece reaches
			# the proven mainline (the assembly-proving bring-up flow; references/two-repo-architecture.md).
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
	reconcile)
		reconcile_local_claim
		;;
	remove)
		# Inspect EVERYTHING before removing anything, so a refusal leaves every worktree, branch and file in place.
		wb_dirty="$(worktree_uncommitted "$WB" "$WB_WT")" \
			|| fail "cannot inspect the workbench worktree $WB_WT - nothing removed"
		wb_ungathered="$(ungathered_paths "$WB" "$BR")" \
			|| fail "cannot compare workbench branch $BR with the trusted line (HEAD of $WB) - nothing removed"
		prod_dirty=""
		if [ "$MODE" = "two-repo" ]; then
			prod_dirty="$(worktree_uncommitted "$PROD_REPO_ROOT" "$PROD_WT")" \
				|| fail "cannot inspect the product worktree $PROD_WT - nothing removed"
		fi
		if [ -n "$wb_dirty$wb_ungathered$prod_dirty" ]; then
			list_paths "workbench worktree $WB_WT has UNCOMMITTED changes:" "$wb_dirty"
			list_paths "workbench branch $BR carries content the trusted line (HEAD of $WB) does not - never gathered:" "$wb_ungathered"
			list_paths "product worktree $PROD_WT has UNCOMMITTED changes:" "$prod_dirty"
			if [ "$DISCARD" -eq 1 ]; then
				note "WARNING: --discard-ungathered - PERMANENTLY DISCARDING every path listed above for the ABANDONED piece '$ID'."
			else
				prod_hint=""
				[ -z "$prod_dirty" ] || prod_hint=" Commit or deliberately clean the product leftovers in $PROD_WT."
				fail "refusing to tear down '$ID': it would destroy the paths listed above. Gather the workbench evidence onto the trusted line first: in $WB take the branch's exact bytes ('git checkout $BR -- <path>...') and copy each uncommitted file in unchanged, commit THAT before recording anything on top of it, then re-run remove.$prod_hint Only for a genuinely ABANDONED piece: re-run with --discard-ungathered. Nothing was removed."
			fi
		fi
		rc=0
		# The product branch is SQUASH-landed (integrate_product.sh), so ancestry can never show it landed;
		# the land is recorded as product.main_commit in the fragment, and teardown runs only after it. So
		# the product branch is deleted once its worktree is gone; its uncommitted files were checked above.
		[ "$MODE" != "two-repo" ] || remove_worktree "$PROD_REPO_ROOT" "$PROD_WT" "$BR" || rc=1
		# The workbench branch is deleted only because ungathered_paths found nothing it alone carries (or
		# the operator chose --discard-ungathered); -D, not -d, because a gathered branch is not an ancestor.
		remove_worktree "$WB" "$WB_WT" "$BR" || rc=1
		[ "$rc" -eq 0 ] || { note "teardown of '$ID' did NOT complete - see the messages above."; exit 1; }
		note "removed worktrees for '$ID'."
		;;
	print)
		git -C "$WB" worktree list --porcelain | grep -qxF "worktree $WB_WT" \
			|| fail "no provisioned worktree for '$ID' (run: provision_worker.sh add $ID)"
		print_contract
		;;
	*) fail "unknown command '$CMD' (use add|reconcile|remove|print)" ;;
esac
