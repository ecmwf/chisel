#!/usr/bin/env bash
# Check out the linked PRODUCT beside the workbench - for CI, or a fresh clone of an
# instance. No-op when no product is wired (no port/product.yaml) or its linkage is still a
# placeholder. Best-effort: a clone failure is reported but NOT fatal here, because the
# product-facing conformance checks fail closed (UNRELIABLE) when a product is wired but
# absent - so CI still goes red, with a clearer message than a clone abort would give.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "checkout-product: not in a git repo." >&2; exit 0; }
WB="$PWD"

[ -f port/product.yaml ] || { echo "checkout-product: no product wired (no port/product.yaml) - nothing to do."; exit 0; }

source tools/conformance/lib/product-root.sh
unreadable() {
  echo "checkout-product: port/product.yaml cannot be read (see above) - leaving the verdict to the checks (UNRELIABLE)."
  exit 0
}
co="$(_pr_checkout "$WB")" || unreadable
repo="$(_pr_product_field "$WB" repo)"
case $? in 0) ;; 3) repo="" ;; *) unreadable ;; esac

if [ -z "$co" ] || [ "${co#<}" != "$co" ] || [ -z "$repo" ] || [ "${repo#<}" != "$repo" ]; then
  echo "checkout-product: port/product.yaml present but repo/checkout is unset or a placeholder - leaving the verdict to the checks (UNRELIABLE)."
  exit 0
fi

case "$co" in /*) dest="$co" ;; *) dest="$WB/$co" ;; esac
if [ -e "$dest" ]; then echo "checkout-product: product checkout '$co' already present."; exit 0; fi

echo "checkout-product: cloning product $repo -> $co"
# Full clone (NOT --depth=1): check-product-invisibility scans the product's WHOLE commit
# history for methodology vocabulary; a shallow clone would make it pass on history it cannot see.
# GIT_TERMINAL_PROMPT=0: a private product without credentials fails fast instead of waiting on a
# password prompt (chisel-init runs this while joining a port).
GIT_TERMINAL_PROMPT=0 git clone "$repo" "$dest" \
  || echo "checkout-product: product clone failed - product-facing checks will be UNRELIABLE (set CI credentials for the product repo)."
