#!/usr/bin/env bash
# Test that check-trace-evidence.sh reads each TRACE entry's own fields as YAML data - what the TRACE
# generator, the drift check and the planner read - not lines of text. A line scanner took a
# `status:` nested anywhere below an entry for the entry's status (so a proven entry could read as
# in-progress and skip every proof rule), kept quotes as part of a path, read an alias as its `*name`
# text, skipped an entry with no `source:`, and reported "nothing to check" for a `files:` it could
# not read. Restore the scanner and the data cases go RED; the controls pass either way.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/conformance/check-trace-evidence.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid \
	GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset TRACE_FILE

# KEEP_GOING=1 reports every failing case instead of stopping at the first (for a red demonstration).
failed=0
pass() { printf 'ok - %s\n' "$1"; }
bad() { printf 'not ok - %s\n' "$1" >&2; [ -n "${KEEP_GOING:-}" ] || exit 1; failed=$((failed + 1)); }

E="$TMP/ev"
mkdir -p "$E" "$TMP/noyaml"
printf 'VERDICT: clean\n' >"$E/review.md"
printf 'R1 differential: bit-identical\n' >"$E/proof.md"
printf 'raise ImportError("PyYAML hidden by the test")\n' >"$TMP/noyaml/yaml.py"

# expect <exit-code> <label> <trace text> [env assignment]; EXPECT_OUT, if set, must appear.
n=0
expect() {
	local want="$1" label="$2" out rc
	n=$((n + 1))
	printf '%s' "$3" >"$TMP/t$n.yaml"
	set +e; out="$(env TRACE_FILE="$TMP/t$n.yaml" ${4:+"$4"} bash "$CHECK" 2>&1)"; rc=$?; set -e
	if [ "$rc" != "$want" ]; then
		bad "$label (expected exit $want, got $rc)"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	elif [ -n "${EXPECT_OUT:-}" ] && ! grep -qF -- "$EXPECT_OUT" <<<"$out"; then
		bad "$label (exit $rc as expected, but the output lacks '$EXPECT_OUT')"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	else
		pass "$label"
	fi
}

HEAD=$'meta:\n  source_commit: abc\nfiles:\n'
PROVEN="- id: a
  source: src/a.f90
  status: proven
  proof: $E/proof.md
  proof_tier: R1
  proof_commit: c0ffee
  review: $E/review.md
"

EXPECT_OUT="1 proven, 0 awaiting review, 0 integrity" \
	expect 0 "a generated-layout proven entry is read and passes (control)" "$HEAD$PROVEN"

# ---- only the entry's own fields count ------------------------------------------------------------
EXPECT_OUT="proven but proof is null" expect 1 "a status nested below a proven entry does not hide it" \
	"$HEAD- id: a
  source: src/a.f90
  status: proven
  proof: null
  review: null
  history:
    status: in-progress
"
EXPECT_OUT="0 proven" expect 0 "a status nested below an in-progress entry does not make it proven" \
	"$HEAD- id: a
  source: src/a.f90
  status: in-progress
  proof: null
  review: null
  history:
    status: proven
"

# ---- values are data ---------------------------------------------------------------------------------
EXPECT_OUT="1 proven" expect 0 "quoted paths are their values" \
	"$HEAD- source: \"src/a.f90\"
  status: \"proven\"
  proof: \"$E/proof.md\"
  proof_tier: \"R1\"
  proof_commit: \"c0ffee\"
  review: '$E/review.md'
"
EXPECT_OUT="1 proven" expect 0 "an aliased review path is the path it names" \
	"meta:
  review_report: &r $E/review.md
files:
- source: src/a.f90
  status: proven
  proof: $E/proof.md
  proof_tier: R1
  proof_commit: c0ffee
  review: *r
"

# ---- every entry is checked; an unreadable TRACE is never "nothing to check" --------------------------
EXPECT_OUT="files entry 1 (no source): proven but review is null" \
	expect 1 "a proven entry with no source is checked, not skipped" "$HEAD- id: a
  status: proven
  proof: $E/proof.md
  proof_tier: R1
  proof_commit: c0ffee
  review: null
"
EXPECT_OUT="UNRELIABLE" expect 2 "a files: that is not a list of entries is UNRELIABLE" $'files:\n  a: 1\n'
EXPECT_OUT="UNRELIABLE" expect 2 "a TRACE that is not valid YAML is UNRELIABLE" $'files:\n- source: [a\n'
EXPECT_OUT="UNRELIABLE" expect 2 "without PyYAML the TRACE cannot be read, which is UNRELIABLE" \
	"$HEAD$PROVEN" "PYTHONPATH=$TMP/noyaml"
EXPECT_OUT="more than once" expect 1 "a field repeated in an entry is RED (control)" "$HEAD$PROVEN  proof: $E/proof.md
"
EXPECT_OUT="nothing to check" expect 0 "an empty files: list has nothing to check (control)" $'files: []\n'

# ---- durable evidence on the committed TRACE (no TRACE_FILE) ------------------------------------------
wb="$TMP/wb"
git init -q -b main "$wb"
mkdir -p "$wb/tools/conformance" "$wb/tools/coordination" "$wb/port" "$wb/docs/evidence/a"
cp "$CHECK" "$wb/tools/conformance/"
cp -R "$ROOT/tools/conformance/lib" "$wb/tools/conformance/"
cp "$ROOT/tools/coordination/_chisel_lib.py" "$wb/tools/coordination/"
cp "$E/proof.md" "$E/review.md" "$wb/docs/evidence/a/"
git -C "$wb" add -A && git -C "$wb" commit -q -m evidence
durable() { # durable <exit-code> <label> <proof path> <review path>; EXPECT_OUT, if set, must appear
	local out rc
	printf '%s- source: src/a.f90\n  status: proven\n  proof: %s\n  proof_tier: R1\n  proof_commit: c0\n  review: %s\n' \
		"$HEAD" "$3" "$4" >"$wb/port/TRACE.yaml"
	set +e; out="$(bash "$wb/tools/conformance/check-trace-evidence.sh" 2>&1)"; rc=$?; set -e
	if [ "$rc" != "$1" ]; then
		bad "$2 (expected exit $1, got $rc)"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	elif [ -n "${EXPECT_OUT:-}" ] && ! grep -qF -- "$EXPECT_OUT" <<<"$out"; then
		bad "$2 (exit $rc as expected, but the output lacks '$EXPECT_OUT')"; printf '%s\n' "$out" | sed 's/^/#   /' >&2
	else
		pass "$2"
	fi
}
durable 0 "durable: committed evidence under docs/evidence/ passes (control)" \
	docs/evidence/a/proof.md docs/evidence/a/review.md
printf 'VERDICT: clean\n' >"$wb/docs/evidence/a/late.md"
EXPECT_OUT="is not git-tracked" durable 1 "durable: an uncommitted review report is RED (control)" \
	docs/evidence/a/proof.md docs/evidence/a/late.md
EXPECT_OUT="must be a workbench-relative path under docs/evidence/" \
	durable 1 "durable: evidence outside docs/evidence/ is RED (control)" "$E/proof.md" docs/evidence/a/review.md

[ "$failed" -eq 0 ] || { printf '# test-trace-evidence-data: %d assertion(s) failed\n' "$failed" >&2; exit 1; }
printf '# test-trace-evidence-data: all assertions passed\n'
