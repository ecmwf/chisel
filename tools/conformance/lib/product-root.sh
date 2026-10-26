# product-root.sh - resolve where the PRODUCT tree lives, for the product-facing checks.
#
# Sourced (never executed) by the conformance checks that scan the product, so they share
# ONE definition of "where is the product" and cannot drift. In the two-repo architecture
# (references/two-repo-architecture.md) the product is its own repo, checked out beside the
# workbench and recorded in port/product.yaml; before a product is wired (the base repo, or
# a brand-new instance) it falls back to target/.
#
# FAIL-CLOSED is the point: once a product is wired (port/product.yaml present), a check that
# cannot reach the product tree must NOT skip-green - the product is exactly what these checks
# exist to guard. `default_product_root` encodes that as a return code the caller acts on
# (a return code propagates through $(...); an `exit` would not, so the caller does the exit).
#
# THE WRONG-TREE DEFECT (see the originating port's product-root resolution
# work): parallel Phase-2 dispatch gives every worker its OWN isolated product
# worktree, `.worktrees/product-<id>` (provision_worker.sh), sitting ALONGSIDE its
# own workbench worktree `.worktrees/<id>`. `port/product.yaml`'s `checkout:` is a
# relative path (e.g., `../product-checkout`) that `_pr_repo_root`
# deliberately resolves against the MAIN workbench root (see that function's own comment) -
# correct for what it is FOR (the one shared/integrated product checkout beside MAIN), but a
# worker running `tools/run-conformance.sh` from INSIDE its own `.worktrees/<id>` worktree got
# that same MAIN-anchored answer regardless: every product-facing check resolved to the SHARED
# product tree (typically empty pre-integration), never the worker's OWN populated
# `.worktrees/product-<id>`, and every one of them "skipped - nothing to verify" GREEN having
# examined zero of the worker's real translated files.
#
# TWO QUESTIONS, TWO FUNCTIONS (round-1 rework fixed F-01: a single function answering both broke
# every non-check caller). `default_product_root` answers "where is the CONFIGURED product, and
# is a product wired at all" - the MODE/checkout-resolution question `assert_isolated.sh`,
# `provision_worker.sh`, and the `integrate_*.sh` land scripts need, unchanged from before this
# defect was ever found (0 wired/10 not-wired-fallback/2 placeholder - nothing else). It never
# fails on a "wrong tree" - those callers derive the WORKER's own root themselves (from <id>, not
# from this function's printed path) and would misclassify two-repo mode as single-repo, or refuse
# a perfectly clean isolated worker, if this function's contract carried a fourth, scan-only
# meaning into their MODE decision. `product_root_for_scan` answers the DIFFERENT question a
# conformance check actually asks - "what should THIS scan examine, and can I trust that it is not
# vacuous" - and is the only caller of the wrong-tree logic (return code 3): the selected root
# (explicit override OR the `default_product_root`-configured one) is CONFIRMED empty of TARGET
# files while THIS invocation's own sibling product worktree is CONFIRMED not - fails closed
# rather than silently reporting a vacuous skip. It never auto-redirects to the sibling (that
# would silently override a deliberate choice to scan the shared tree); it only refuses to call a
# provably-wrong empty scan "clean" - and, since an ordinary stale/copy-pasted explicit override is
# exactly as capable of reproducing the vacuous pass as the no-override default is, this validation
# applies EQUALLY to an explicit root, never exempting it just because it was named explicitly.

# Captured at SOURCE time - i.e. the directory the CALLING SCRIPT was actually invoked from -
# because several callers `cd` elsewhere (their own repo root, sometimes MAIN-anchored via
# _pr_repo_root itself, e.g. check-product-tests.sh's workbench-orphan arm) BEFORE ever asking
# this library to resolve the product root. `source lib/product-root.sh` is, in every current
# caller, the first substantive line (before any `cd`), so this reliably captures the TRUE
# invocation directory - the one fact _pr_sibling_product_worktree needs and a call-time `git
# rev-parse --show-toplevel` cannot recover once the caller has already navigated away from it.
#
# HONORS A PRE-SET/EXPORTED VALUE FIRST: tools/run-conformance.sh orchestrates the nine checks as
# CHILD PROCESSES, and it `cd`s to ITS OWN script location before launching them (needed so its
# relative `tools/conformance/*.sh` glob resolves regardless of the caller's cwd) - so a check
# launched that way inherits the RUNNER's post-cd cwd, not the ORIGINAL invocation directory the
# whole run started from, if this were re-derived per process. run-conformance.sh captures and
# EXPORTS its own true starting cwd as `_PR_LOAD_CWD` for exactly this reason; every check then
# sees the SAME, correct invocation identity regardless of how many process boundaries and `cd`s
# sit between the human/worker's shell and this particular check. A standalone check (no runner
# in between) has no such export and falls back to its own `pwd`, unchanged from before.
_PR_LOAD_CWD="${_PR_LOAD_CWD:-$(pwd -P 2>/dev/null || pwd)}"

# The common git dir, absolute with symlinks resolved; returns 1 when it does not resolve to a
# directory. Plain --git-common-dir, resolved here: --path-format=absolute needs git 2.31, and an
# older git echoes the unknown option back as output instead of failing.
_pr_common_dir() {
    local gd
    gd="$(git rev-parse --git-common-dir 2>/dev/null)" && [ -n "$gd" ] && [ -d "$gd" ] \
        && (CDPATH='' cd -- "$gd" 2>/dev/null && pwd -P)
}

# The MAIN workbench root: the parent of the common git dir, the same from the main checkout and
# from every linked worktree. provision_worker.sh places the claims (port/claims/) and the
# per-piece worktrees (.worktrees/<id>) here, so every reader of them resolves it the same way.
# Returns 1 when the common git dir does not resolve.
_pr_main_root() {
    local gd
    gd="$(_pr_common_dir)" && [ -n "$gd" ] && dirname -- "$gd"
}

_pr_repo_root() {
    # The MAIN workbench root, stable across linked worktrees: the sibling product checkout
    # and port/product.yaml belong to the main workbench, so a relative checkout (../product)
    # must resolve against MAIN even when a worker runs from a .worktrees/<id> worktree
    # (--show-toplevel would return the worktree - the wrong anchor for the sibling product).
    _pr_main_root || git rev-parse --show-toplevel 2>/dev/null
}

# The strict YAML reader (tools/coordination/yaml_get.py), found beside this library so every copy
# of the tools tree reads with its own copy.
_PR_YAML_GET="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../coordination" 2>/dev/null && pwd)/yaml_get.py"

# _pr_product_field ROOT KEY - print the scalar KEY of ROOT/port/product.yaml, read as YAML data
# (yaml_get.py), so a nested or repeated key and an alias are read as the Python tools read them.
# Returns 0 with the value, 3 when the key is absent or null (prints nothing), and 2 when the file
# cannot be read or KEY is not a scalar (the reason is on stderr).
_pr_product_field() {
    command -v python3 >/dev/null 2>&1 \
        || { echo "product-root: python3 not found - cannot read '$1/port/product.yaml'" >&2; return 2; }
    python3 "$_PR_YAML_GET" "$1/port/product.yaml" "$2"
}

# Echo the `checkout:` value from $1/port/product.yaml; empty if the file is absent or the key is
# absent or null. Returns 2, printing nothing, when the file cannot be read: callers report that as
# UNRELIABLE, never as an unset checkout.
_pr_checkout() {
    local root="$1" co rc
    [[ -f "$root/port/product.yaml" ]] || { printf ''; return 0; }
    co="$(_pr_product_field "$root" checkout)"; rc=$?
    case "$rc" in
        0) printf '%s' "$co" ;;
        3) printf '' ;;
        *) return 2 ;;
    esac
}

# _pr_default_branch ROOT - the product mainline: the `default_branch:` value in
# ROOT/port/product.yaml, or `main` when the key is absent, null or empty. Returns 2, printing
# nothing, when the file cannot be read: the caller refuses rather than land on a guessed branch.
_pr_default_branch() {
    local db rc
    db="$(_pr_product_field "$1" default_branch)"; rc=$?
    case "$rc" in
        0) printf '%s' "${db:-main}" ;;
        3) printf 'main' ;;
        *) return 2 ;;
    esac
}

# _pr_invocation_root - the toplevel of whatever tree THIS PROCESS was actually invoked in (a
# linked worktree's OWN path, unlike _pr_repo_root's MAIN anchor) - resolved from the directory
# captured at library-source time (_PR_LOAD_CWD), NOT the current $PWD, so a caller that `cd`s
# elsewhere before resolving the product root (several do) does not silently blind this. Empty
# if that directory is not (or is no longer) inside a git repository.
_pr_invocation_root() {
    git -C "$_PR_LOAD_CWD" rev-parse --show-toplevel 2>/dev/null
}

# _pr_sibling_product_worktree - if THIS invocation is running inside a per-piece workbench
# worktree (.worktrees/<id>, provision_worker.sh's layout - a single path component under
# .worktrees/, matching assert_isolated.sh's own derivation), echo the path of that piece's OWN
# product worktree (.worktrees/product-<id>) when it exists as a directory; otherwise echo
# nothing. Never invents a path outside that exact, already-provisioned layout - a worktree name
# that is not a bare <id> (e.g. a nested op worktree, .worktrees/sync-<id>) is deliberately not
# matched, so this only ever names a real, provisioned sibling.
_pr_sibling_product_worktree() {
    local main inv id sib
    main="$(_pr_repo_root)" || { printf ''; return 0; }
    inv="$(_pr_invocation_root)" || { printf ''; return 0; }
    main="$(cd "$main" 2>/dev/null && pwd -P)" || { printf ''; return 0; }
    inv="$(cd "$inv" 2>/dev/null && pwd -P)" || { printf ''; return 0; }
    case "$inv" in
        "$main"/.worktrees/*)
            id="${inv#"$main"/.worktrees/}"
            case "$id" in */*|"") printf ''; return 0 ;; esac
            sib="$main/.worktrees/product-$id"
            [[ -d "$sib" ]] && printf '%s' "$sib"
            return 0
            ;;
        *) printf ''; return 0 ;;
    esac
}

# _pr_has_target_files DIR - true (exit 0) iff DIR exists and contains at least one *.c/*.h file
# anywhere under it (a coarse "does this look populated at all" probe - the fine-grained,
# scope-accurate enumeration each check actually verifies against is that check's own job).
_pr_has_target_files() {
    local d="$1" hit
    [[ -d "$d" ]] || return 1
    hit="$(find "$d" -type f \( -name '*.c' -o -name '*.h' \) -print -quit 2>/dev/null)"
    [[ -n "$hit" ]]
}

# _pr_unreadable_msg ROOT - empty when ROOT does not exist (a different, separately-handled
# case: "wired but missing/never cloned") or is a readable directory; otherwise a diagnostic
# naming ROOT, for the caller to print and fail closed (UNRELIABLE) on. Guards the vacuous-pass
# a permission-denied root produces: `find`/`grep` over a directory that cannot even be opened
# silently enumerate ZERO files, which every check's existing "no TARGET files - skipping" path
# would otherwise report as a clean, confirmed-empty GREEN - indistinguishable, without this
# check, from a directory that is genuinely empty. Applies uniformly to BOTH an explicitly-passed
# root (--target-dir/--product-root/the PRODUCT_ROOT env) and the port/product.yaml-configured
# default - one predicate, every caller.
_pr_unreadable_msg() {
    local root="$1"
    [[ -e "$root" ]] || { printf ''; return 0; }
    if [[ -d "$root" && ! -r "$root" ]]; then
        printf '%s' "'${root}' exists but is not readable (permission denied) - a scan of it cannot be trusted as complete, confirmed-empty, or clean"
        return 0
    fi
    printf ''
}

# pr_confirm_find ROOT OUTARR ERRVAR [--] FIND-PREDICATE... - run `find ROOT FIND-PREDICATE...`
# and treat it as authoritative ONLY when it completes cleanly (exit 0 AND empty stderr) - the
# SAME technique verify-anchors.sh has always used for its own scan, factored out here so every
# enumerator shares it (F-03). A bare `find ... 2>/dev/null` silently drops BOTH the failure
# signal (exit code) and the diagnostic (stderr) the instant anything in the tree cannot be
# traversed - a permission-denied root, a READABLE-but-not-SEARCHABLE subdirectory anywhere in the
# tree (mode 0444: `ls` lists the names, but `find`/`stat`/`open` on any entry inside fails with
# EACCES - an ordinary chmod/archive-restore/mount-policy accident, not a contrived scenario), a
# root that vanishes mid-scan - so a TRUNCATED result and a genuinely CONFIRMED-empty one print
# nothing and exit 0 alike through that naive pipeline. Permission-BIT predicates on the root
# alone (`_pr_unreadable_msg`'s `-r` test) cannot catch this either: they see only the TOP of the
# tree, never a bad subdirectory further down, and READ is not SEARCH. The actual scan's own exit
# status and stderr are what is authoritative - this is that check, done once, shared.
#
# On a clean scan: OUTARR (a caller-supplied array NAME) is populated, one path per line, in
# find's own order (unsorted); returns 0. On ANY find failure: OUTARR is left untouched, ERRVAR (a
# caller-supplied scalar NAME) is set to a human-readable reason naming ROOT, and the function
# returns 1 - the caller must fail closed (UNRELIABLE), never report the possibly-partial OUTARR
# as though it were complete.
pr_confirm_find() {
    local root="$1" outvar="$2" errvar="$3"
    shift 3
    [[ "${1:-}" == "--" ]] && shift
    # shellcheck disable=SC2178  # namerefs, not scalars - shellcheck does not know -n here
    local -n _pf_out="$outvar" _pf_err="$errvar"
    local tmp_out tmp_err rc _pf_line
    tmp_out="$(mktemp 2>/dev/null)" || { _pf_err="cannot create a scratch file to capture the scan of '${root}'"; return 1; }
    tmp_err="$(mktemp 2>/dev/null)" || { rm -f "$tmp_out"; _pf_err="cannot create a scratch file to capture the scan of '${root}'"; return 1; }
    find "$root" "$@" >"$tmp_out" 2>"$tmp_err"
    rc=$?
    if [[ "$rc" -ne 0 || -s "$tmp_err" ]]; then
        _pf_err="scanning '${root}' did not complete cleanly (find exit ${rc}) - the result set may be TRUNCATED, refusing to report it as clean: $(tr '\n' ' ' <"$tmp_err" | sed -E 's/[[:space:]]+$//')"
        rm -f "$tmp_out" "$tmp_err"
        return 1
    fi
    _pf_out=()
    while IFS= read -r _pf_line; do _pf_out+=("$_pf_line"); done <"$tmp_out"
    rm -f "$tmp_out" "$tmp_err"
    return 0
}

# pr_confirm_target_files ROOT OUTARR ERRVAR - convenience wrapper over pr_confirm_find for the
# shape shared by several checks: every *.c/*.h under ROOT, a `tests/` subtree pruned WHOLE (a
# product `tests/` subtree is product-owned test SCAFFOLDING, not translated source - see each
# caller's own header for the per-check rationale; a `tests`-NAMED FILE is still scanned). OUTARR
# comes back SORTED (unlike the generic helper) since every current caller of this exact shape
# wants a stable order.
pr_confirm_target_files() {
    local root="$1" outvar="$2" errvar="$3"
    # shellcheck disable=SC2178
    local -n _ptf_out="$outvar"
    local -a _ptf_raw=()
    local _ptf_line
    pr_confirm_find "$root" _ptf_raw "$errvar" -- -type d -name tests -prune -o -type f \( -name '*.c' -o -name '*.h' \) -print || return 1
    _ptf_out=()
    # Guard the empty case explicitly: `printf '%s\n' "${arr[@]}"` on a TRULY EMPTY array still
    # runs its format ONCE (a null string is substituted for the missing argument - POSIX printf
    # behavior, not a bash quirk), printing ONE blank line rather than none - which the read loop
    # would then capture as a single bogus empty-string entry. git-enumerate.sh's own enumerator
    # already guards this exact case; mirrored here.
    if [[ ${#_ptf_raw[@]} -gt 0 ]]; then
        while IFS= read -r _ptf_line; do _ptf_out+=("$_ptf_line"); done < <(printf '%s\n' "${_ptf_raw[@]}" | sort)
    fi
    return 0
}

# pr_confirm_searchable ROOT ERRVAR - explicitly, POSITIVELY confirm that every directory under
# ROOT is SEARCHABLE (execute permission), rather than inferring completeness from the absence of
# an error - the residual F-03 gap `pr_confirm_find`'s rc/stderr check cannot close by
# construction (round-2 review, prior product-root review):
#
# On a filesystem that supplies `d_type` in `getdents()` (this one included - GNU findutils uses
# it when available), `find -type f` can determine a LEAF directory's own entries' NAMES and TYPES
# straight from its PARENT's directory-listing bytes, without ever `stat()`ing or `open()`ing
# INTO the leaf itself - so a directory that is READABLE but NOT SEARCHABLE (mode 0444: readdir
# succeeds, but path resolution through it does not) yields a perfectly clean `find` exit 0, empty
# stderr, and a correct-looking file list. `pr_confirm_find`/`pr_confirm_target_files` (the F-03
# fix from the prior round) are therefore satisfied - there is no error for them to observe,
# because none occurred at the ENUMERATION step. The failure surfaces LATER, silently, the moment
# a caller tries to actually READ one of those files' CONTENT (open() must resolve the full path,
# which DOES require execute on every ancestor directory, including the leaf) - and if that read's
# own error is itself discarded (`grep ... 2>/dev/null`, common and otherwise reasonable), the
# scan reports zero matches as though the content had genuinely been examined. Absence of an error
# message at the enumeration step is not evidence the scan will be complete at the read step; this
# is the exact vacuous-pass reasoning this whole unit exists to eliminate, one layer deeper.
#
# THE FIX IS POSITIVE, NOT INFERENTIAL: this function does not run `find` and hope it complains -
# it enumerates every directory (`pr_confirm_find ... -type d`, itself fail-closed on the SAME
# enumeration failures `pr_confirm_find` already guards) and then explicitly TESTS `[ -x DIR ]` on
# each one directly - a real `access()`/`faccessat()` permission check bash's own `-x` test
# performs, never a d_type-derived guess. A directory whose entries were listed via the parent's
# d_type but that is not itself searchable is caught here even though `find` itself never
# complained about it.
#
# Callers: call this ONCE, before trusting ANY content read from ROOT (not just the specific files
# a narrower enumeration happened to return) - a scan that has not confirmed every directory
# searchable cannot trust a "no match"/"0 leaks" result from grep/read over that tree, regardless
# of which specific check produced it. Returns 0 if every directory is searchable. Returns 1 and
# sets ERRVAR (a caller-supplied scalar name) to a human-readable reason naming the first
# unsearchable directory (or the enumeration failure that made the directory list itself
# untrustworthy) otherwise - the caller must fail closed (UNRELIABLE).
pr_confirm_searchable() {
    local root="$1" errvar="$2"
    # shellcheck disable=SC2178
    local -n _ps_err="$errvar"
    local -a _ps_dirs=()
    local _ps_enum_err d
    pr_confirm_find "$root" _ps_dirs _ps_enum_err -- -type d || {
        _ps_err="$_ps_enum_err"
        return 1
    }
    # `find ROOT -type d` already includes ROOT itself (it is tested against the predicate too),
    # so _ps_dirs is the complete directory set with no separate root case to add.
    for d in "${_ps_dirs[@]}"; do
        [[ -x "$d" ]] || {
            _ps_err="'${d}' is not searchable (missing execute permission) - a directory that cannot be searched may hide file CONTENT from any scan that reads through it, even one whose enumeration of file NAMES completed cleanly (e.g. via a filesystem's d_type optimization) - refusing to trust a scan through it as complete"
            return 1
        }
    done
    return 0
}

# resolve_product_root [EXPLICIT] - return an absolute path: an EXPLICIT override (a check's
# --flag/env), else the product checkout, else target/. Prints a path and returns 0, unless
# port/product.yaml cannot be read (returns 2, prints nothing); the caller decides whether the
# path exists. For the fail-closed DEFAULT path use default_product_root.
resolve_product_root() {
    local explicit="${1:-}" root co
    root="$(_pr_repo_root)" || { printf '%s\n' "${explicit:-target}"; return 0; }
    if [[ -n "$explicit" ]]; then
        case "$explicit" in /*) printf '%s\n' "$explicit" ;; *) printf '%s\n' "$root/$explicit" ;; esac
        return 0
    fi
    co="$(_pr_checkout "$root")" || return 2
    if [[ -n "$co" && "$co" != *"<"* && "$co" != *">"* ]]; then
        case "$co" in /*) printf '%s\n' "$co" ;; *) printf '%s\n' "$root/$co" ;; esac
        return 0
    fi
    printf '%s\n' "$root/target"
}

# default_product_root - resolve the CONFIGURED product tree (port/product.yaml) / execution
# MODE. UNCHANGED CONTRACT (pre-dates the wrong-tree defect; do not add a fourth meaning here -
# see the file header's "two questions, two functions"). Report, via the RETURN CODE, how the
# caller must treat a missing tree:
#   0  a product IS wired (port/product.yaml + a concrete checkout); the printed path MUST be
#      scanned - a missing checkout is UNRELIABLE for the caller, never a skip.
#   10 no product is wired (no port/product.yaml); the printed path is the target/ fallback -
#      a missing tree is a clean skip (base repo / not-yet-set-up instance).
#   2  a product IS wired but its checkout is unset/placeholder, or port/product.yaml cannot be
#      read as YAML (the reason is on stderr) - UNRELIABLE.
# Callers: assert_isolated.sh, provision_worker.sh, integrate_{product,bringup,assets,assembly}.sh
# (MODE/checkout resolution - never scan validation), and product_root_for_scan below (which
# layers the scan-only wrong-tree question on TOP of this, for the nine conformance checks only).
default_product_root() {
    local root co resolved
    root="$(_pr_repo_root)" || { printf '%s\n' "target"; return 10; }
    if [[ -f "$root/port/product.yaml" ]]; then
        co="$(_pr_checkout "$root")" || { printf '%s\n' ""; return 2; }
        if [[ -z "$co" || "$co" == *"<"* || "$co" == *">"* ]]; then printf '%s\n' ""; return 2; fi
        case "$co" in /*) resolved="$co" ;; *) resolved="$root/$co" ;; esac
        printf '%s\n' "$resolved"
        return 0
    fi
    printf '%s\n' "$root/target"; return 10
}

# product_root_for_scan [EXPLICIT] - resolve the product root FOR A CONFORMANCE CHECK'S SCAN
# (never for coordination/MODE detection - use default_product_root for that; see the file
# header). EXPLICIT, when given (a check's own --flag or env, already precedence-resolved by the
# caller), is the SELECTED root; otherwise falls through to default_product_root's own 0/10/2
# resolution. EITHER WAY - explicit or configured - the selected root is validated against THIS
# invocation's own sibling product worktree before being handed back: explicit means higher
# PRECEDENCE, never exemption from validation, because an ordinary stale/copy-pasted explicit
# override reproduces the exact same vacuous pass as the no-override default did (F-02). A
# selected root CONFIRMED empty of TARGET files while a DIFFERENT sibling product worktree is
# CONFIRMED not is the wrong-tree defect - UNRELIABLE, return 3, naming both paths (whether the
# wrong one came from a flag, an env var, or port/product.yaml).
#
# Return codes: 0 (must be scanned), 10 (not wired - target/ fallback, missing is a clean skip;
# EXPLICIT is never resolved with code 10 - an explicit override is always "must be scanned"), 2
# (wired but placeholder - only reachable via the no-EXPLICIT path), 3 (wrong tree, see above).
product_root_for_scan() {
    local explicit="${1:-}" resolved rc sib resolved_real sib_real
    if [[ -n "$explicit" ]]; then
        case "$explicit" in
            /*) resolved="$explicit" ;;
            *)  resolved="$_PR_LOAD_CWD/$explicit" ;;
        esac
        rc=0
    else
        resolved="$(default_product_root)"; rc=$?
    fi
    # The wrong-tree diagnosis only applies once RESOLVED is confirmed to exist and be readable -
    # a missing or permission-denied root is a DIFFERENT, more specific problem with its own
    # accurate message (every caller already checks -d / _pr_unreadable_msg immediately after
    # this call); conflating "does not exist" or "unreadable" into "wrong tree" here would name
    # the wrong root's problem.
    if [[ "$rc" -eq 0 && -d "$resolved" && -r "$resolved" ]] && ! _pr_has_target_files "$resolved"; then
        sib="$(_pr_sibling_product_worktree)"
        if [[ -n "$sib" ]]; then
            resolved_real="$(cd "$resolved" 2>/dev/null && pwd -P)" || resolved_real="$resolved"
            sib_real="$(cd "$sib" 2>/dev/null && pwd -P)" || sib_real="$sib"
            if [[ "$resolved_real" != "$sib_real" ]] && _pr_has_target_files "$sib"; then
                if [[ -n "$explicit" ]]; then
                    echo "product-root: explicitly-selected product root '${resolved}' has no TARGET *.c/*.h files, but this worktree's OWN product worktree '${sib}' does - an ordinary stale/copy-pasted override reproduces the same vacuous pass as no override at all, so explicit does not exempt it. Point --product-root/--target-dir (or PRODUCT_ROOT) at the tree you actually mean - most likely '${sib}'." >&2
                else
                    echo "product-root: configured product root '${resolved}' (port/product.yaml) has no TARGET *.c/*.h files, but this worktree's OWN product worktree '${sib}' does - resolving to the configured tree here would examine the WRONG tree and report a vacuous pass. Pass --product-root/--target-dir (or export PRODUCT_ROOT) naming the tree you actually mean - most likely '${sib}'." >&2
                fi
                printf '%s\n' "$resolved"
                return 3
            fi
        fi
    fi
    printf '%s\n' "$resolved"
    return "$rc"
}
