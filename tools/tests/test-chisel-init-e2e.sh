#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# chisel-init end to end, offline: local bare repos stand in for GitHub (Chisel, the original code,
# an empty workbench and an empty product repo), a gh stub that always fails keeps it off the
# network, an opencode stub serves a small model catalog, and a git identity comes from a private
# config. A new port is set up in one command; the setup is then checked where it lands: the
# workbench pushed with Chisel as upstream, the original code imported at the pinned tag with its
# provenance, the product created beside the workbench and linked, the agents' models written, the
# handoff rewritten. Running the same command again changes nothing. A bad flag stops init before it
# changes anything; a ref the original code lacks stops the import and leaves nothing behind. Joining
# the port from another clone of Chisel works, and works again. A refused product repo leaves no clone.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n%s\n' "$1" "${2:-}" >&2; failures=$((failures + 1)); }
check() { if eval "$2"; then ok "$1"; else not_ok "$1" "${3:-}"; fi; }

mkdir -p "$TMP/bin" "$TMP/gh"
printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/gh"
cat >"$TMP/bin/opencode" <<'SH'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "api get" ] && [[ "${3:-}" == /api/model\?* ]]; then cat "$OPENCODE_STUB_CATALOG"; exit; fi
exit 1
SH
chmod +x "$TMP/bin/gh" "$TMP/bin/opencode"
python3 - "$TMP/catalog.json" <<'PY'
import json, sys
def m(provider, mid, family):
    return {"providerID": provider, "id": mid, "family": family, "time": {"released": 1}, "status": "active",
            "enabled": True, "variants": [{"id": e} for e in ("low", "medium", "high", "xhigh", "max")]}
json.dump({"data": [m("anthropic", "claude-sonnet-9", "claude-sonnet"), m("anthropic", "claude-opus-9", "claude-opus"),
                    m("openai", "gpt-9-sol", "gpt-sol")]}, open(sys.argv[1], "w"))
PY
export OPENCODE_STUB_CATALOG="$TMP/catalog.json"
cat >"$TMP/gitconfig" <<EOF
[user]
	name = Test
	email = test@example.org
[init]
	defaultBranch = main
[protocol "file"]
	allow = always
EOF
export PATH="$TMP/bin:$PATH" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1 NO_COLOR=1
G="$TMP/gh"

# Chisel as it is in this working tree, recording its own (local) home as the base.
mkdir "$TMP/seed"
(cd "$ROOT" && git ls-files -z | tar --null -T - -cf -) | tar -xf - -C "$TMP/seed"
printf '%s\n' "file://$G/chisel.git" >"$TMP/seed/tools/base-repo.txt"
git -C "$TMP/seed" init -q && git -C "$TMP/seed" add -A && git -C "$TMP/seed" commit -q -m chisel
git clone -q --bare "$TMP/seed" "$G/chisel.git"

# The original code: two commits, the first tagged v1.
mkdir "$TMP/foo" && git -C "$TMP/foo" init -q
printf 'program foo\nend program foo\n' >"$TMP/foo/foo.f90"
git -C "$TMP/foo" add -A && git -C "$TMP/foo" commit -q -m one && git -C "$TMP/foo" tag v1
printf '! later\n' >>"$TMP/foo/foo.f90" && git -C "$TMP/foo" commit -q -am two
git clone -q --bare "$TMP/foo" "$G/foo.git"
V1="$(git -C "$TMP/foo" rev-parse v1)"

git init -q --bare "$G/port-foo.git"
git init -q --bare "$G/foo-product.git"

mkdir "$TMP/work"
git clone -q "file://$G/chisel.git" "$TMP/work/port-foo"
W="$TMP/work/port-foo"
init_new() {
	(cd "$W" && python3 tools/chisel-init.py --mode new --non-interactive --yes \
		--new-repo "file://$G/port-foo.git" --source-repo "file://$G/foo.git" --source-ref v1 \
		--product-repo "file://$G/foo-product.git" --product-dir ../foo-product "$@" 2>&1)
}

set +e; out="$(init_new)"; rc=$?; set -e
check "a new port is set up in one command" '[ "$rc" -eq 0 ]' "$out"
check "its lines and the scripts' output come in order, even into a pipe" \
	'[ "$(grep -n "== Tools ==" <<<"$out" | head -1 | cut -d: -f1)" -lt "$(grep -n "new branch" <<<"$out" | head -1 | cut -d: -f1)" ]' "$out"
check "the workbench's origin is the new repo, upstream is Chisel" \
	'[ "$(git -C "$W" remote get-url origin)" = "file://$G/port-foo.git" ] && [ "$(git -C "$W" remote get-url upstream)" = "file://$G/chisel.git" ]'
check "the workbench's main is pushed" 'git -C "$G/port-foo.git" rev-parse -q --verify main >/dev/null'
check "the original code is imported, without its .git" '[ -f "$W/source/foo/foo.f90" ] && [ ! -e "$W/source/foo/.git" ]'
check "its provenance records the pinned commit" 'grep -q "$V1" "$W/port/provenance/foo.yaml"'
check "the product is cloned beside the workbench, with its first commit pushed" \
	'[ -d "$TMP/work/foo-product/.git" ] && git -C "$G/foo-product.git" rev-parse -q --verify main >/dev/null'
check "the workbench links the product" 'grep -q "foo-product.git" "$W/port/product.yaml"'
check "the agents' models are written" 'grep -q "anthropic/claude-sonnet-9#high" "$W/opencode.json" && grep -q "openai/gpt-9-sol#high" "$W/opencode.json"'
check "the handoff names the imported code" 'grep -q "source/foo/" "$W/port/handoffs/main.md"'
check "nothing is committed: the first sprint does that" \
	'[ "$(git -C "$W" rev-parse HEAD)" = "$(git -C "$G/chisel.git" rev-parse main)" ]'

before="$(cd "$W" && git status --porcelain | sort; cat port/product.yaml port/provenance/foo.yaml)"
set +e; out="$(init_new)"; rc=$?; set -e
after="$(cd "$W" && git status --porcelain | sort; cat port/product.yaml port/provenance/foo.yaml)"
check "running the same command again succeeds" '[ "$rc" -eq 0 ]' "$out"
check "and changes nothing" '[ "$before" = "$after" ]' "$out"

# Joining: the port's first sprint commits and pushes the setup, then someone joins the port from
# their own clone of Chisel - and can run the same command again.
git -C "$W" add -A && git -C "$W" commit -q -m setup && git -C "$W" push -q origin HEAD:main
mkdir "$TMP/work2"
git clone -q "file://$G/chisel.git" "$TMP/work2/chisel"
join() {
	(cd "$TMP/work2/chisel" && python3 tools/chisel-init.py --mode join --non-interactive --yes \
		--existing-repo "file://$G/port-foo.git" --dir ../port-foo 2>&1)
}
set +e; out="$(join)"; rc=$?; set -e
check "joining a port clones its workbench" '[ "$rc" -eq 0 ] && [ -f "$TMP/work2/port-foo/port/product.yaml" ]' "$out"
check "with Chisel as upstream" '[ "$(git -C "$TMP/work2/port-foo" remote get-url upstream)" = "file://$G/chisel.git" ]'
check "and its product beside it" '[ -d "$TMP/work2/foo-product/.git" ] && grep -q "product checked out" <<<"$out"' "$out"
check "without a spurious git error" '! grep -q "No such remote" <<<"$out"' "$out"
set +e; out="$(join)"; rc=$?; set -e
check "joining again continues the setup" '[ "$rc" -eq 0 ] && grep -q "continuing its setup" <<<"$out"' "$out"

# The product step refuses a repo that already has history, removing the clone it made for it, so
# running it again gives the same answer rather than "checkout path already exists".
mkdir "$TMP/used" "$TMP/work3" && git -C "$TMP/used" init -q && git -C "$TMP/used" commit -q --allow-empty -m old
git clone -q --bare "$TMP/used" "$G/used-product.git"
git clone -q "file://$G/chisel.git" "$TMP/work3/port-qux"
np() { (cd "$TMP/work3/port-qux" && bash tools/new-product.sh "file://$G/used-product.git" ../used-product 2>&1); }
set +e; out="$(np)"; rc=$?; set -e
check "a product repo with history is refused" '[ "$rc" -ne 0 ] && grep -q "already has commits" <<<"$out"' "$out"
check "and the clone made for it is removed" '[ ! -e "$TMP/work3/used-product" ]' "$out"
set +e; out="$(np)"; rc=$?; set -e
check "so running it again gives the same answer" '[ "$rc" -ne 0 ] && grep -q "already has commits" <<<"$out"' "$out"

# Without a terminal, a change needs --yes: --non-interactive alone stops before the flip.
git init -q --bare "$G/port-quux.git"
git clone -q "file://$G/chisel.git" "$TMP/work/port-quux"
set +e
out="$(cd "$TMP/work/port-quux" && python3 tools/chisel-init.py --mode new --non-interactive --skip-source \
	--skip-product --new-repo "file://$G/port-quux.git" 2>&1)"
rc=$?
set -e
check "without a terminal, a change needs --yes" '[ "$rc" -ne 0 ] && grep -q -- "--yes" <<<"$out"' "$out"
check "so nothing is pushed without it" '! git -C "$G/port-quux.git" rev-parse -q --verify main >/dev/null' "$out"

# A model the catalog does not have stops init before the flip: nothing is pushed or rewired.
git init -q --bare "$G/port-bar.git"
git clone -q "file://$G/chisel.git" "$TMP/work/port-bar"
set +e
out="$(cd "$TMP/work/port-bar" && python3 tools/chisel-init.py --mode new --non-interactive --yes --skip-source \
	--skip-product --new-repo "file://$G/port-bar.git" --model kha-worker=anthropic/no-such-model 2>&1)"
rc=$?
set -e
check "a model the catalog does not have stops init" '[ "$rc" -ne 0 ] && grep -q "no-such-model" <<<"$out"' "$out"
check "before anything changed: nothing pushed, the clone still Chisel's" \
	'! git -C "$G/port-bar.git" rev-parse -q --verify main >/dev/null && [ "$(git -C "$TMP/work/port-bar" remote get-url origin)" = "file://$G/chisel.git" ]' "$out"

# A ref the original code does not have stops the import and leaves nothing behind; the same command
# with the right ref then finishes the setup.
git init -q --bare "$G/port-baz.git"
git clone -q "file://$G/chisel.git" "$TMP/work/port-baz"
baz() {
	(cd "$TMP/work/port-baz" && python3 tools/chisel-init.py --mode new --non-interactive --yes --skip-product \
		--new-repo "file://$G/port-baz.git" --source-repo "file://$G/foo.git" --source-ref "$1" 2>&1)
}
set +e; out="$(baz no-such-ref)"; rc=$?; set -e
check "a ref the original code does not have stops the import" '[ "$rc" -ne 0 ] && grep -q "no-such-ref" <<<"$out"' "$out"
check "and leaves no clone behind" '[ ! -e "$TMP/work/port-baz/source/foo" ]' "$out"
set +e; out="$(baz v1)"; rc=$?; set -e
check "the same command with the right ref finishes the setup" \
	'[ "$rc" -eq 0 ] && [ -f "$TMP/work/port-baz/source/foo/foo.f90" ] && grep -q "$V1" "$TMP/work/port-baz/port/provenance/foo.yaml"' "$out"

[ "$failures" -eq 0 ] || { echo "# test-chisel-init-e2e: $failures failure(s)" >&2; exit 1; }
echo "# test-chisel-init-e2e: all assertions passed"
