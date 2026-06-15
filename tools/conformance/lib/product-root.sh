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

_pr_repo_root() {
    # The MAIN workbench root, stable across linked worktrees: the sibling product checkout
    # and port/product.yaml belong to the main workbench, so a relative checkout (../product)
    # must resolve against MAIN even when a worker runs from a .worktrees/<id> worktree
    # (--show-toplevel would return the worktree - the wrong anchor for the sibling product).
    local gd
    gd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
        && [ -n "$gd" ] && { dirname "$gd"; return 0; }
    git rev-parse --show-toplevel 2>/dev/null
}

# Echo the `checkout:` scalar from $1/port/product.yaml, stripped of an inline comment,
# surrounding quotes, and surrounding whitespace. Empty if the file or key is absent.
_pr_checkout() {
    local root="$1" co
    [[ -f "$root/port/product.yaml" ]] || { printf ''; return 0; }
    co="$(sed -nE 's/^[[:space:]]*checkout:[[:space:]]*(.*)$/\1/p' "$root/port/product.yaml" | head -1)"
    co="${co%%#*}"
    co="${co#"${co%%[![:space:]]*}"}"
    co="${co%"${co##*[![:space:]]}"}"
    co="${co#\"}"; co="${co%\"}"
    co="${co#\'}"; co="${co%\'}"
    printf '%s' "$co"
}

# resolve_product_root [EXPLICIT] - return an absolute path: an EXPLICIT override (a check's
# --flag/env), else the product checkout, else target/. Always succeeds (prints a path); the
# caller decides whether it exists. For the fail-closed DEFAULT path use default_product_root.
resolve_product_root() {
    local explicit="${1:-}" root co
    root="$(_pr_repo_root)" || { printf '%s\n' "${explicit:-target}"; return 0; }
    if [[ -n "$explicit" ]]; then
        case "$explicit" in /*) printf '%s\n' "$explicit" ;; *) printf '%s\n' "$root/$explicit" ;; esac
        return 0
    fi
    co="$(_pr_checkout "$root")"
    if [[ -n "$co" && "$co" != "<"* ]]; then
        case "$co" in /*) printf '%s\n' "$co" ;; *) printf '%s\n' "$root/$co" ;; esac
        return 0
    fi
    printf '%s\n' "$root/target"
}

# default_product_root - resolve the product tree for a check's DEFAULT scan (no explicit
# override) and report, via the RETURN CODE, how the caller must treat a missing tree:
#   0  a product IS wired (port/product.yaml + a concrete checkout); the printed path MUST be
#      scanned - a missing checkout is UNRELIABLE for the caller, never a skip.
#   10 no product is wired (no port/product.yaml); the printed path is the target/ fallback -
#      a missing tree is a clean skip (base repo / not-yet-set-up instance).
#   2  a product IS wired but its checkout is unset/placeholder - UNRELIABLE.
default_product_root() {
    local root co
    root="$(_pr_repo_root)" || { printf '%s\n' "target"; return 10; }
    if [[ -f "$root/port/product.yaml" ]]; then
        co="$(_pr_checkout "$root")"
        if [[ -z "$co" || "$co" == "<"* ]]; then printf '%s\n' ""; return 2; fi
        case "$co" in /*) printf '%s\n' "$co" ;; *) printf '%s\n' "$root/$co" ;; esac
        return 0
    fi
    printf '%s\n' "$root/target"; return 10
}
