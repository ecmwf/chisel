#!/usr/bin/env bash
# Create a clean PRODUCT repository for a two-repo port and link it to this workbench.
#
# The product is its own ordinary repo with its own clean history; the ported code is
# built into it sprint by sprint. The workbench (this instance) stays the attestation
# authority and records the linkage in port/product.yaml. See the code-port skill's
# references/two-repo-architecture.md.
#
# Run from the workbench root.
#
# Usage:
#   tools/new-product.sh <product-repo> [<checkout-dir>]
#     <product-repo> = a gh target 'me/foo-product' (needs the gh CLI), OR a git URL of
#                      an EMPTY repo you already created.
#     <checkout-dir> = local working tree for the product (default ../<name>, a sibling
#                      of the workbench by convention).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
WB="$PWD"

REPO="${1:-}"
if [ -z "$REPO" ]; then
  echo "usage: tools/new-product.sh <product-repo> [<checkout-dir>]   (gh 'me/foo-product' or a git URL)" >&2
  exit 2
fi
case "$REPO" in -*) echo "new-product: <product-repo> may not start with '-'" >&2; exit 2 ;; esac

# Must run inside a workbench: it owns port/ and is where the linkage is recorded.
[ -d port ] || { echo "new-product: no port/ directory here - run this from the workbench root." >&2; exit 2; }

# One product per workbench: never clobber an existing linkage.
if [ -f port/product.yaml ]; then
  echo "new-product: port/product.yaml already exists - this workbench is already linked to a product." >&2
  exit 2
fi

NAME="$(basename "$REPO")"; NAME="${NAME%.git}"
CHECKOUT="${2:-../$NAME}"
case "$CHECKOUT" in
  /*) CHECKOUT_ABS="$CHECKOUT" ;;
  *)  CHECKOUT_ABS="$WB/$CHECKOUT" ;;
esac
[ -e "$CHECKOUT_ABS" ] && { echo "new-product: checkout path '$CHECKOUT' already exists - choose another or remove it." >&2; exit 2; }

# Create (gh) or clone (URL) the product into its sibling checkout. Auth/tooling is
# checked BEFORE any remote is created so a failure never leaves a half-made repo.
case "$REPO" in
  *://*|git@*)
    git clone "$REPO" "$CHECKOUT_ABS" ;;
  */*)
    command -v gh >/dev/null || { echo "new-product: gh CLI not found - create the repo and re-run with its git URL" >&2; exit 2; }
    gh auth status >/dev/null 2>&1 || { echo "new-product: gh is not authenticated - run 'gh auth login' first" >&2; exit 2; }
    gh repo create "$REPO" --private >/dev/null
    gh repo clone "$REPO" "$CHECKOUT_ABS" >/dev/null ;;
  *)
    echo "new-product: <product-repo> must be 'owner/name' (gh) or a git URL" >&2; exit 2 ;;
esac

# Seed the first CLEAN commit: a product-focused README only (chisel stays invisible
# here - no methodology vocabulary). The product README template lives with the product.
if [ ! -f "$CHECKOUT_ABS/README.md" ]; then
  cat > "$CHECKOUT_ABS/README.md" <<'README'
# <product name>

<One or two sentences: what this software does and who it is for.>

This is a <TARGET language> implementation of <original project name>
(<link to the original project>).

## Status

<e.g. early development / usable / feature-complete.>

## Build

```sh
<exact build commands>
```

Requirements: <compiler/toolchain versions, libraries>.

## Run

```sh
<exact command to run the program on an example input>
```

<Describe inputs and outputs briefly.>

## License

<license of this implementation, and any notice required by the original project>.
README
fi

git -C "$CHECKOUT_ABS" add -A
git -C "$CHECKOUT_ABS" commit -q -m "Initial commit"
git -C "$CHECKOUT_ABS" branch -M main
git -C "$CHECKOUT_ABS" push -u origin main

REMOTE_URL="$(git -C "$CHECKOUT_ABS" remote get-url origin)"
cat > port/product.yaml <<YAML
# port/product.yaml - workbench -> product linkage (see the code-port skill's
# references/two-repo-architecture.md). The workbench is the attestation authority;
# this records WHERE the product is and WHICH product commit is currently attested.
repo: $REMOTE_URL
checkout: $CHECKOUT
default_branch: main
attested_commit: none
YAML

echo "Product repo ready."
echo "  product : $REMOTE_URL"
echo "  checkout: $CHECKOUT  (sibling of the workbench)"
echo "  linkage : port/product.yaml  (stage and commit it in the workbench)"
echo "Next: define the charter, then build the port into the product sprint by sprint."
