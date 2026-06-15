# product-root.sh - resolve where the PRODUCT tree lives, for the product-facing checks.
#
# Sourced (never executed) by the conformance checks that scan the product, so they
# share ONE definition of "where is the product" and cannot drift. In the two-repo
# architecture (references/two-repo-architecture.md) the product is its own repo,
# checked out beside the workbench and recorded in port/product.yaml; before a product
# is wired (e.g. the base repo itself, or a brand-new instance) it falls back to target/.
#
# resolve_product_root [EXPLICIT]
#   Resolution, first hit wins:
#     1. EXPLICIT          - a value the caller already has (its --flag/env); honored as-is
#                            (absolute kept; relative made absolute against the repo root).
#     2. port/product.yaml - the `checkout:` path (the workbench->product linkage),
#                            resolved against the repo root; ignored if still the template
#                            placeholder (`<...>`).
#     3. target/           - the single-repo fallback (repo root/target).
#   Always prints an absolute path and returns 0; whether that path EXISTS is the
#   caller's decision (the checks skip a missing product tree).

_pr_repo_root() { git rev-parse --show-toplevel 2>/dev/null; }

resolve_product_root() {
    local explicit="${1:-}" root co
    root="$(_pr_repo_root)" || { printf '%s\n' "${explicit:-target}"; return 0; }

    if [[ -n "$explicit" ]]; then
        case "$explicit" in
            /*) printf '%s\n' "$explicit" ;;
            *)  printf '%s\n' "$root/$explicit" ;;
        esac
        return 0
    fi

    if [[ -f "$root/port/product.yaml" ]]; then
        # First `checkout:` scalar; strip inline comment, surrounding quotes, and whitespace.
        co="$(sed -nE 's/^[[:space:]]*checkout:[[:space:]]*(.*)$/\1/p' "$root/port/product.yaml" | head -1)"
        co="${co%%#*}"
        co="${co#"${co%%[![:space:]]*}"}"   # ltrim
        co="${co%"${co##*[![:space:]]}"}"   # rtrim
        co="${co#\"}"; co="${co%\"}"
        co="${co#\'}"; co="${co%\'}"
        if [[ -n "$co" && "$co" != "<"* ]]; then
            case "$co" in
                /*) printf '%s\n' "$co" ;;
                *)  printf '%s\n' "$root/$co" ;;
            esac
            return 0
        fi
    fi

    printf '%s\n' "$root/target"
}
