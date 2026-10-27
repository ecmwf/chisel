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

# A clean first commit needs a committer identity; check it before creating any remote.
git config user.email >/dev/null 2>&1 && git config user.name >/dev/null 2>&1 \
  || { echo "new-product: git user.name/email are not configured - set them before creating the product repo." >&2; exit 2; }

# Classify the selector: a git URL (incl. file:// for a local repo) or a strict gh
# owner/name. A local PATH with slashes is NOT a gh name - reject it (pass a file:// URL).
KIND=""
case "$REPO" in
  *://*|git@*:*) KIND=url ;;
esac
if [ -z "$KIND" ]; then
  if printf '%s' "$REPO" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    KIND=gh
  else
    echo "new-product: '$REPO' is neither a git URL nor a gh 'owner/name'. For a LOCAL repo, pass a file:// URL." >&2
    exit 2
  fi
fi

# Create (gh) or clone (URL) the product into its sibling checkout. Tooling/auth is checked
# BEFORE any remote is created so a failure never leaves a half-made repo. A gh repo an earlier
# attempt already created is reused, not created again.
case "$KIND" in
  url)
    git clone "$REPO" "$CHECKOUT_ABS" ;;
  gh)
    command -v gh >/dev/null || { echo "new-product: gh CLI not found - create the repo and re-run with its git URL" >&2; exit 2; }
    gh auth status >/dev/null 2>&1 || { echo "new-product: gh is not authenticated - run 'gh auth login' first" >&2; exit 2; }
    if gh repo view "$REPO" >/dev/null 2>&1; then
      echo "new-product: repo $REPO already exists - using it (not recreating)."
    else
      gh repo create "$REPO" --private >/dev/null
    fi
    gh repo clone "$REPO" "$CHECKOUT_ABS" >/dev/null ;;
esac
# From here on, a failed step removes the checkout made above, so a re-run starts clean instead of
# stopping at "checkout path already exists".
trap 'rc=$?; [ "$rc" -eq 0 ] || rm -rf "$CHECKOUT_ABS"' EXIT

# Greenfield expects an EMPTY product repo; refuse to seed on top of existing history.
if git -C "$CHECKOUT_ABS" rev-parse --verify -q HEAD >/dev/null 2>&1; then
  echo "new-product: '$CHECKOUT' already has commits - greenfield expects an empty product repo." >&2
  echo "  Use an empty repo, or wire an existing product by writing port/product.yaml by hand." >&2
  exit 2
fi

# The product's first commit uses the workbench operator's identity (a fresh clone may not
# inherit a local one; the preflight above guaranteed the workbench has an effective identity).
git -C "$CHECKOUT_ABS" config user.email "$(git config user.email)"
git -C "$CHECKOUT_ABS" config user.name "$(git config user.name)"

# Seed the first CLEAN commit from the canonical product-README template (the single
# source of truth; chisel stays invisible here - the template carries no methodology
# vocabulary). The product README is the product's own from its first commit.
if [ ! -f "$CHECKOUT_ABS/README.md" ]; then
  TPL=".opencode/skill/code-port/assets/PRODUCT-README.template.md"
  [ -f "$TPL" ] || { echo "new-product: product-README template '$TPL' is missing - is this a chisel workbench?" >&2; exit 2; }
  cp "$TPL" "$CHECKOUT_ABS/README.md"
fi

# Product-owned tests so the regression net ships WITH the product (references/
# two-repo-architecture.md): drivers in tests/unit/, SOURCE-derived fixtures in tests/fixtures/;
# the fixture generator stays in the workbench (tools/diff/). .gitkeep (empty) keeps the dirs
# present while leaving the product tree chisel-invisible.
for d in tests/unit tests/fixtures; do
  mkdir -p "$CHECKOUT_ABS/$d"
  [ -e "$CHECKOUT_ABS/$d/.gitkeep" ] || : > "$CHECKOUT_ABS/$d/.gitkeep"
done

git -C "$CHECKOUT_ABS" add -A
git -C "$CHECKOUT_ABS" commit -q -m "Initial commit"
git -C "$CHECKOUT_ABS" branch -M main
git -C "$CHECKOUT_ABS" push -u origin main

REMOTE_URL="$(git -C "$CHECKOUT_ABS" remote get-url origin)"
cat > port/product.yaml <<YAML
# port/product.yaml - workbench -> product linkage (see the code-port skill's
# references/two-repo-architecture.md). The workbench is the attestation authority;
# this records WHERE the product is and WHICH product commit is currently attested.
repo: "$REMOTE_URL"
checkout: "$CHECKOUT"
default_branch: main
attested_commit: none
YAML

# Run by chisel-init, which reports the result and the next step itself, it says nothing more.
if [ -z "${CHISEL_INIT:-}" ]; then
  echo "Product repo ready."
  echo "  product : $REMOTE_URL"
  echo "  checkout: $CHECKOUT  (sibling of the workbench)"
  echo "  linkage : port/product.yaml  (stage and commit it in the workbench)"
  echo "  tests   : tests/unit + tests/fixtures  (product-owned; the product runs them itself)"
  echo "  CI      : if the product repo is PRIVATE, add a read-only token for it as the workbench"
  echo "            Actions secret PRODUCT_RO_TOKEN so CI can check out and verify it (without it,"
  echo "            product-facing CI checks stay fail-closed / UNRELIABLE). See ci.yml."
  echo "Next: define the charter, then build the port into the product sprint by sprint."
fi
