#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# chisel-init turns a browser link to the original code into a clone URL and a ref. A branch or tag
# may hold a '/', and a file path may follow it, so a link with more than one part after /tree, /blob,
# /src, /raw or /commits does not say where the ref ends: init stops and asks for --source-ref. A
# one-part link gives its ref; a commit link the commit, a tag or release link the whole tag. The
# parsing is checked on its own, then end to end in --dry-run (no network).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$ROOT/tools/chisel-init.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("chisel_init", sys.argv[1])
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)

GH = "https://github.com/org/repo"
cases = [  # (link, clone URL, the parts that name the ref)
    (GH + "/tree/main", GH + ".git", ["main"]),
    (GH + "/tree/feature/x", GH + ".git", ["feature", "x"]),
    (GH + "/tree/feature/x/src/sub", GH + ".git", ["feature", "x", "src", "sub"]),
    (GH + "/blob/release/1.2/README.md#L3", GH + ".git", ["release", "1.2", "README.md"]),
    (GH + "/commits/feature/x", GH + ".git", ["feature", "x"]),
    (GH + "/releases/tag/release/2024.1", GH + ".git", ["release/2024.1"]),
    (GH + "/tree/refs/heads/main", GH + ".git", ["main"]),
    (GH + "/tree/refs/tags/v1/src", GH + ".git", ["v1", "src"]),
    (GH + "/tree/feature%2Fx", GH + ".git", ["feature/x"]),
    (GH + "/commit/0123abc", GH + ".git", ["0123abc"]),
    ("https://github.com/org/src/tree/main", "https://github.com/org/src.git", ["main"]),
    ("https://gitlab.example.org/group/sub/repo/-/tree/feature/x?ref_type=heads",
     "https://gitlab.example.org/group/sub/repo.git", ["feature", "x"]),
    ("https://gitlab.example.org/group/repo/-/tags/release/2024.1",
     "https://gitlab.example.org/group/repo.git", ["release/2024.1"]),
    ("https://bitbucket.example.org/org/repo/src/feature%2Fx/doc/a.md",
     "https://bitbucket.example.org/org/repo.git", ["feature/x", "doc", "a.md"]),
]
bad = 0
for link, url, segs in cases:
    got = ci.normalize_source_url(link)
    if got != (url, segs):
        print("not ok - %s: got %r, want %r" % (link, got, (url, segs)), file=sys.stderr)
        bad += 1
for plain in (GH, GH + ".git", "git@github.com:org/repo.git", "/srv/code/repo", "../repo"):
    if ci.normalize_source_url(plain) != (plain, None):
        print("not ok - %s is not a browser link: got %r" % (plain, ci.normalize_source_url(plain)), file=sys.stderr)
        bad += 1
sys.exit(1 if bad else 0)
PY
echo "ok - a browser link splits into a clone URL and the parts that name its ref"

# git's url.<base>.insteadOf points the made-up web host at local paths, so nothing goes out.
cat >"$TMP/gitconfig" <<EOF
[user]
	name = Test
	email = test@example.org
[init]
	defaultBranch = main
[protocol "file"]
	allow = always
[url "file://$TMP/forge/"]
	insteadOf = https://forge.example.org/
EOF
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1 NO_COLOR=1

# A port's workbench, in --dry-run: the original code is the only step left.
W="$TMP/w"
mkdir -p "$W/tools" "$W/.opencode/skills/code-port"
cp "$ROOT/tools/chisel-init.py" "$W/tools/"
: >"$W/.opencode/skills/code-port/SKILL.md"
printf '%s\n' https://forge.example.org/acme/chisel.git >"$W/tools/base-repo.txt"
git -C "$W" init -q
git -C "$W" remote add origin https://forge.example.org/me/port-foo.git
git -C "$W" remote add upstream https://forge.example.org/acme/chisel.git
n=0
# expect <0|fail> <label> <link> <text the output must hold> [init flags...]
expect() {
	local want_rc="$1" label="$2" link="$3" want="$4" out rc
	shift 4
	n=$((n + 1))
	set +e
	out="$(cd "$W" && python3 tools/chisel-init.py --mode new --dry-run --non-interactive --yes --skip-models \
		--skip-product --source-repo "$link" "$@" 2>&1)"
	rc=$?
	set -e
	if { [ "$want_rc" = 0 ] && [ "$rc" -ne 0 ]; } || { [ "$want_rc" = fail ] && [ "$rc" -eq 0 ]; } ||
		! grep -qF -- "$want" <<<"$out"; then
		printf 'not ok - %s (exit %s; wanted "%s")\n%s\n' "$label" "$rc" "$want" "$out" >&2
		exit 1
	fi
	printf 'ok - %s\n' "$label"
}
expect 0 "a one-part link gives its ref, and the dry run shows it" \
	https://forge.example.org/org/repo/tree/main "using https://forge.example.org/org/repo.git at 'main'"
expect 0 "a release link pins the whole tag" \
	https://forge.example.org/org/repo/releases/tag/release/2024.1 "checkout -q release/2024.1"
expect fail "a link that does not say where its ref ends stops and asks for --source-ref" \
	https://forge.example.org/org/repo/tree/feature/x/src "give it with --source-ref, for example --source-ref feature"
expect 0 "--source-ref settles such a link" \
	https://forge.example.org/org/repo/blob/feature/x/a.txt "checkout -q feature/x" --source-ref feature/x

printf '# test-chisel-init-link: all %d end-to-end cases passed\n' "$n"
