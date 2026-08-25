#!/usr/bin/env bash
# check-worktree-freshness.sh - stale worktrees are structurally visible before dispatch.
#
# provision_worker.sh creates each worktree at whatever the mainline was at
# provision time. The mainline then moves - other units land, tooling fixes
# land - and nothing checked. Consequences: checkers run many commits old and
# report false REDs on files they cannot see; or they run without a landed fix
# and report GREEN having examined nothing. The orchestrator has been rebasing
# manually and forgetting - that is the thing to remove.
#
# This check enumerates every LIVE claim (port/claims/<id>.yaml with state
# created|active) and measures whether its worktree's merge-base with the
# mainline is behind the mainline tip. Being AHEAD (local work) is not stale;
# being BEHIND by N commits is. Every live claim must end in examined-fresh,
# examined-stale, or UNRELIABLE - never disappear.
#
# Design decisions, explicitly argued:
#
#   REFUSE vs AUTO-REBASE (in assert_isolated.sh, the primary control): REFUSE.
#   A rebase can conflict, and a tool that silently rewrites a worker's branch
#   mid-flight is worse than a stop. The refusal names the exact one-line fix
#   (`git fetch origin && git -C .worktrees/<id> rebase origin/main`), so the
#   stall is one copy-paste, not a reconstruction. auto-rebase would also hide
#   a conflict behind a tool exit code the worker never asked for. This check
#   is the BEFORE-dispatch surface; assert_isolated.sh is the fail-closed gate
#   that actually stops the worker. Both share the same merge-base definition
#   so they cannot disagree.
#
#   RED vs NOTICE (here, the preflight surface): NOTICE. A stale worktree is
#   not a defect in the code being checked - it is operational drift in the
#   workbench's own worktrees. Making the full conformance suite RED would block
#   integration of unrelated, correctly-translated work while the stale worktree
#   waits for a rebase that has nothing to do with the code under review. NOTICE
#   keeps the finding determinate and visible in CI (the runner surfaces every
#   NOTICE line from an otherwise-GREEN check) without failing the aggregate.
#   The hard gate is still assert_isolated.sh: a worker on a stale tree cannot
#   proceed at all. Undeterminable state (no mainline ref, detached HEAD, no
#   merge-base, missing tooling, absent worktree for a live claim, malformed
#   claim) is UNRELIABLE, never a pass - three-state contract as elsewhere.
#
# Exit-code contract:
#   0  GREEN (no stale worktrees) OR NOTICE (stale worktrees found, but not a
#      code defect - runner surfaces NOTICE lines; suite stays GREEN)
#   2  UNRELIABLE  cannot determine freshness (no mainline, detached, no
#      merge-base, missing tooling, absent worktree for live claim, malformed
#      claim) - fail closed, never a silent pass.
#
# Never exits 1: staleness is not a RED code defect. Each stale worktree is
# reported as a `NOTICE:` line so the runner's NOTICE convention applies.
set -uo pipefail

for _tool in git find sort mktemp python3; do
	command -v "$_tool" >/dev/null 2>&1 || { echo "check-worktree-freshness: $_tool not found - freshness UNDETERMINABLE (UNRELIABLE)" >&2; exit 2; }
done
python3 -c "import yaml" 2>/dev/null || { echo "check-worktree-freshness: python3 yaml (PyYAML) not available - freshness UNDETERMINABLE (UNRELIABLE)" >&2; exit 2; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
	|| { echo "check-worktree-freshness: not inside a git repository" >&2; exit 2; }
cd "$ROOT" || { echo "check-worktree-freshness: cannot enter repo root '$ROOT'" >&2; exit 2; }

# Determine workbench mainline tip. Same resolution as assert_isolated.sh:
# local branch is ground truth (moves on every land); remote-tracking may lag.
# Use only fully-qualified refs so a tag named `main` cannot masquerade as a
# branch. Undeterminable -> UNRELIABLE.
_mainline_ref=""; _mainline_tip=""
for _cand in refs/heads/main refs/heads/master; do
	if _tip="$(git rev-parse --verify "$_cand" 2>/dev/null)"; then
		_mainline_ref="$_cand"; _mainline_tip="$_tip"
		break
	fi
done
if [ -z "$_mainline_tip" ] && _origin_head="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null)"; then
	if _tip="$(git rev-parse --verify "$_origin_head" 2>/dev/null)"; then
		_mainline_ref="$_origin_head"; _mainline_tip="$_tip"
	fi
fi
if [ -z "$_mainline_tip" ]; then
	for _cand in refs/remotes/origin/main refs/remotes/origin/master; do
		if _tip="$(git rev-parse --verify "$_cand" 2>/dev/null)"; then
			_mainline_ref="$_cand"; _mainline_tip="$_tip"
			break
		fi
	done
fi
if [ -z "$_mainline_tip" ]; then
	echo "check-worktree-freshness: cannot determine mainline tip (no refs/heads/main or refs/remotes/origin/main) - freshness UNDETERMINABLE (UNRELIABLE); ensure the mainline branch exists and is fetched" >&2
	exit 2
fi
_mainline_short="$(git rev-parse --short "$_mainline_tip" 2>/dev/null || printf '%s' "$_mainline_tip")"

# Enumerate claim files - fail closed on any enumeration problem.
# Parsing zero claims from a populated claims directory is "I could not read
# this", not "nothing to check".
claims_dir="port/claims"
if [ ! -d "$claims_dir" ]; then
	echo "check-worktree-freshness: no live claims under port/claims/ - nothing to check (skipping)."
	exit 0
fi
_tmpdir="$(mktemp -d)"
trap 'rm -rf "$_tmpdir"' EXIT
_find_out="$_tmpdir/find_out"; _find_err="$_tmpdir/find_err"
find "$claims_dir" -maxdepth 1 -type f -name '*.yaml' -print0 >"$_find_out" 2>"$_find_err"
_find_rc=$?
if [ "$_find_rc" -ne 0 ]; then
	echo "check-worktree-freshness: cannot enumerate claims in '$claims_dir' (find exit $_find_rc) - freshness UNDETERMINABLE (UNRELIABLE)" >&2
	cat "$_find_err" >&2
	exit 2
fi
if [ -s "$_find_err" ]; then
	echo "check-worktree-freshness: cannot enumerate claims cleanly in '$claims_dir' (find wrote to stderr) - freshness UNDETERMINABLE (UNRELIABLE)" >&2
	cat "$_find_err" >&2
	exit 2
fi

# Collect raw claim files
_raw_files=()
while IFS= read -r -d '' _f; do
	_raw_files+=("$_f")
done <"$_find_out"

# No *.yaml files at all -> no live claims, bounded no-active-work skip.
if [ "${#_raw_files[@]}" -eq 0 ]; then
	echo "check-worktree-freshness: no live claims under port/claims/ - nothing to check (skipping)."
	exit 0
fi

# Validate each file and collect live IDs. Any unreadable or malformed file
# is UNRELIABLE, never silently skipped. Uses a real YAML parser
# (standing rule 11) - a file that does not parse, or whose parsed `state`
# is not exactly one of created|active|stale, is UNRELIABLE. Counts are
# maintained so a live claim never disappears.
live_ids=()
unreliable=()
for _f in "${_raw_files[@]}"; do
	if [ ! -r "$_f" ]; then
		unreliable+=("cannot read claim '$_f' - freshness UNDETERMINABLE")
		continue
	fi
	_id="$(basename "$_f" .yaml)"
	case "$_id" in *[!A-Za-z0-9._-]*|""|.*|-*)
		unreliable+=("malformed claim id '$_id' in '$_f' - freshness UNDETERMINABLE")
		continue
		;;
	esac
	# Parse with real YAML loader (strict, duplicate-key rejecting). A file
	# that contains the string `state: active` inside invalid YAML, or
	# `state: activeevil` (parsed value != active), must not be treated as live.
	_state_out="$_tmpdir/state_out"; _state_err="$_tmpdir/state_err"
	: >"$_state_out"; : >"$_state_err"
	python3 - "$_f" >"$_state_out" 2>"$_state_err" <<'PY'
import sys
try:
    import yaml
except ImportError:
    print("yaml not available", file=sys.stderr)
    sys.exit(2)
class StrictLoader(yaml.SafeLoader):
    pass
def no_dup(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(None, None, f"duplicate key {key!r}", key_node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping
StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_dup)
path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as fh:
        data = yaml.load(fh, Loader=StrictLoader)
except yaml.YAMLError as e:
    print(f"yaml_error: {e}", file=sys.stderr)
    sys.exit(2)
except Exception as e:
    print(f"read_error: {e}", file=sys.stderr)
    sys.exit(2)
if not isinstance(data, dict):
    print(f"not_a_mapping: {type(data).__name__}", file=sys.stderr)
    sys.exit(3)
state = data.get("state")
if state not in ("created", "active", "stale"):
    print(f"invalid_state:{state!r}", file=sys.stderr)
    sys.exit(3)
if state in ("created", "active"):
    print("live")
else:
    print("stale")
PY
	_py_rc=$?
	if [ "$_py_rc" -eq 0 ]; then
		_state_val="$(cat "$_state_out")"
		if [ "$_state_val" = "live" ]; then
			live_ids+=("$_id")
		elif [ "$_state_val" = "stale" ]; then
			: # valid but not live -> not collected
		else
			unreliable+=("malformed claim '$_f': unexpected parser output '$_state_val' - freshness UNDETERMINABLE")
		fi
	elif [ "$_py_rc" -eq 2 ]; then
		_err_msg="$(cat "$_state_err" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
		unreliable+=("malformed claim '$_f': ${_err_msg:-yaml parse error} - freshness UNDETERMINABLE")
	elif [ "$_py_rc" -eq 3 ]; then
		_err_msg="$(cat "$_state_err" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
		unreliable+=("malformed claim '$_f': ${_err_msg:-invalid state} - freshness UNDETERMINABLE")
	else
		_err_msg="$(cat "$_state_err" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
		unreliable+=("cannot parse claim '$_f' (python exit $_py_rc) ${_err_msg} - freshness UNDETERMINABLE")
	fi
done

# If no live IDs but we have unreliable entries, fail closed.
if [ "${#live_ids[@]}" -eq 0 ]; then
	if [ "${#unreliable[@]}" -gt 0 ]; then
		echo "check-worktree-freshness: freshness UNDETERMINABLE for ${#unreliable[@]} claim(s) (UNRELIABLE):" >&2
		for _u in "${unreliable[@]}"; do echo "  - $_u" >&2; done
		exit 2
	fi
	echo "check-worktree-freshness: no live claims under port/claims/ - nothing to check (skipping)."
	exit 0
fi

# If we have live IDs but also malformed claims, those malformed are UNRELIABLE
# and must block. We will report them together with any per-worktree
# undeterminable below.

stale=()
examined=0

for _id in "${live_ids[@]}"; do
	_wt="$ROOT/.worktrees/$_id"
	if [ ! -d "$_wt" ]; then
		unreliable+=("$_id: live claim has no worktree at '$_wt' - freshness UNDETERMINABLE")
		continue
	fi
	_wt_gitdir="$(git -C "$_wt" rev-parse --git-dir 2>/dev/null)" || {
		unreliable+=("$_id: cannot determine git-dir for '$_wt' - freshness UNDETERMINABLE")
		continue
	}
	case "$_wt_gitdir" in */worktrees/*) : ;; *)
		unreliable+=("$_id: '$_wt' is not a linked worktree (git-dir '$_wt_gitdir') - freshness UNDETERMINABLE")
		continue
		;;
	esac
	_wt_branch="$(git -C "$_wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
	if [ -z "$_wt_branch" ]; then
		unreliable+=("$_id: HEAD is detached at '$_wt' - freshness UNDETERMINABLE")
		continue
	fi
	_wt_head="$(git -C "$_wt" rev-parse HEAD 2>/dev/null)" || {
		unreliable+=("$_id: cannot determine HEAD at '$_wt' - freshness UNDETERMINABLE")
		continue
	}
	if ! git -C "$_wt" symbolic-ref --quiet HEAD >/dev/null 2>&1; then
		unreliable+=("$_id: HEAD is detached at '$_wt' - freshness UNDETERMINABLE")
		continue
	fi
	_mb="$(git -C "$_wt" merge-base HEAD "$_mainline_tip" 2>/dev/null)" || {
		unreliable+=("$_id: cannot determine merge-base of '$_wt' (HEAD $_wt_head) with mainline '$_mainline_ref' ($_mainline_tip) - freshness UNDETERMINABLE")
		continue
	}
	examined=$((examined + 1))
	if [ "$_mb" != "$_mainline_tip" ]; then
		_behind="$(git -C "$_wt" rev-list --count "$_mb".."$_mainline_tip" 2>/dev/null)" || {
			unreliable+=("$_id: cannot count commits between merge-base '$_mb' and mainline tip '$_mainline_tip' - freshness UNDETERMINABLE")
			examined=$((examined - 1))
			continue
		}
		case "$_behind" in ''|*[!0-9]*)
			unreliable+=("$_id: cannot determine staleness count (got '$_behind') - freshness UNDETERMINABLE")
			examined=$((examined - 1))
			continue
			;;
		esac
		if [ "$_behind" -gt 0 ]; then
			_mb_short="$(git -C "$_wt" rev-parse --short "$_mb" 2>/dev/null || printf '%s' "$_mb")"
			stale+=("$_id: $_behind commit(s) behind '$_mainline_ref' (merge-base $_mb_short behind tip $_mainline_short) - fix: git fetch origin && git -C \"$_wt\" rebase \"$_mainline_ref\"")
		fi
	fi
done

if [ "${#unreliable[@]}" -gt 0 ]; then
	echo "check-worktree-freshness: freshness UNDETERMINABLE for ${#unreliable[@]} item(s) (UNRELIABLE):" >&2
	for _u in "${unreliable[@]}"; do echo "  - $_u" >&2; done
	exit 2
fi

if [ "${#stale[@]}" -gt 0 ]; then
	for _s in "${stale[@]}"; do
		echo "NOTICE: check-worktree-freshness: stale worktree - $_s"
	done
	echo "check-worktree-freshness: ${#stale[@]} stale worktree(s) behind '$_mainline_ref' (tip $_mainline_short); ${#live_ids[@]} live claim(s) discovered, $examined examined fresh/stale. Stale worktrees are operational drift, not a code defect - run the suggested rebase(s) before dispatch; suite stays GREEN via NOTICE." >&2
	exit 0
fi

echo "check-worktree-freshness: all $examined live worktree(s) fresh against '$_mainline_ref' (tip $_mainline_short); ${#live_ids[@]} live claim(s) discovered."
exit 0
