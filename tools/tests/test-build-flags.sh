#!/usr/bin/env bash
# tools/build-checks/check-build-flags.py against a two-file C project built here: the flags each
# translation unit really received (from a compilation database) and, with --objects, the fused
# multiply-adds in its object. Every RED and UNRELIABLE case below is a contract break or a missing
# fact the check must report; the GREEN ones are builds it must accept.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/build-checks/check-build-flags.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CC="$(command -v cc || command -v gcc || command -v clang)"

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/    /'; failures=$((failures + 1)); }
expect() { # expect EXIT NEEDLE LABEL ARGS...
	local want="$1" needle="$2" label="$3" out rc
	shift 3
	out="$(python3 "$CHECK" "$@" 2>&1)" && rc=0 || rc=$?
	if [ "$rc" != "$want" ]; then
		not_ok "$label (expected exit $want, got $rc)" "$out"
	elif ! grep -qF -- "$needle" <<<"$out"; then
		not_ok "$label (output lacks '$needle')" "$out"
	else
		ok "$label"
	fi
}

P="$TMP/proj"
mkdir -p "$P"
printf 'double fma_candidate(double a, double b, double c) { return a * b + c; }\n' >"$P/a.c"
printf 'int next(int x) { return x + 1; }\n' >"$P/b.c"
FLOOR='-std=c17 -Wall -Wextra -Wconversion -Wshadow -Wdouble-promotion -Werror'

# db FILE "FLAGS for a.c" "FLAGS for b.c": a compilation database in the "arguments" form, and the
# objects built with exactly those flags.
db() {
	python3 - "$1" "$P" "$CC" "$2" "$3" <<'PY'
import json, shlex, sys
out, proj, cc, fa, fb = sys.argv[1:]
entries = []
for src, flags in (("a.c", fa), ("b.c", fb)):
    args = [cc] + shlex.split(flags) + ["-c", src, "-o", src[:-2] + ".o"]
    entries.append({"directory": proj, "file": src, "arguments": args})
json.dump(entries, open(out, "w"), indent=1)
PY
	python3 - "$1" <<'PY'
import json, subprocess, sys
for e in json.load(open(sys.argv[1])):
    subprocess.run(e["arguments"], cwd=e["directory"], check=True)
PY
}

# ---- flags --------------------------------------------------------------------------------------
db "$TMP/ok.json" "$FLOOR -ffp-contract=off -O2" "$FLOOR -ffp-contract=off -O2"
expect 0 "RESULT: GREEN" "a build on the contract is GREEN" --compile-commands "$TMP/ok.json"

db "$TMP/no-contract.json" "$FLOOR -O2" "$FLOOR -ffp-contract=off -O2"
expect 1 "a.c: -ffp-contract=off is missing" "a TU without -ffp-contract=off is RED" --compile-commands "$TMP/no-contract.json"

db "$TMP/fast.json" "$FLOOR -ffp-contract=off -O2 -ffast-math" "$FLOOR -ffp-contract=off -O2"
expect 1 "-ffast-math is forbidden" "-ffast-math in one TU is RED" --compile-commands "$TMP/fast.json"

db "$TMP/later.json" "$FLOOR -ffp-contract=off -O2 -ffp-contract=fast" "$FLOOR -ffp-contract=off -O2"
expect 1 "-ffp-contract=fast: contraction must be off" "a later -ffp-contract=fast overrides off and is RED" --compile-commands "$TMP/later.json"

db "$TMP/negated.json" "$FLOOR -ffp-contract=off -Wno-conversion" "$FLOOR -ffp-contract=off"
expect 1 "-Wno-conversion takes a warning back" "a -Wno- of a floor warning is RED" --compile-commands "$TMP/negated.json"

db "$TMP/sub.json" "$FLOOR -ffp-contract=off -Wno-sign-conversion" "$FLOOR -ffp-contract=off -Wno-unused-parameter"
expect 1 "-Wno-sign-conversion takes a warning back" "a -Wno- of a warning inside the floor is RED" --compile-commands "$TMP/sub.json"
expect 1 "-Wno-unused-parameter takes a warning back" "any other -Wno- is RED by default" --compile-commands "$TMP/sub.json"
printf 'allowed:\n  -Wno-sign-conversion: the reason\n  -Wno-unused-parameter: the reason\n' >"$TMP/allowed.yaml"
expect 0 "RESULT: GREEN" "a -Wno- the contract lists with its reason is GREEN" --compile-commands "$TMP/sub.json" --contract "$TMP/allowed.yaml"
printf 'allowed:\n  -Wno-unused-parameter: ""\n' >"$TMP/no-reason.yaml"
expect 2 "allowed must map each -Wno-<warning> to its reason" "an allowed warning without a reason is UNRELIABLE" --compile-commands "$TMP/sub.json" --contract "$TMP/no-reason.yaml"

db "$TMP/nowerror.json" "-std=c17 -Wall -Wextra -Wconversion -Wshadow -Wdouble-promotion -ffp-contract=off" "$FLOOR -ffp-contract=off"
expect 1 "a.c: -Werror is missing" "warnings that are not errors are RED" --compile-commands "$TMP/nowerror.json"

db "$TMP/mixed.json" "$FLOOR -ffp-contract=off" "-std=c11 -Wall -Wextra -Wconversion -Wshadow -Wdouble-promotion -Werror -ffp-contract=off"
expect 1 "the TUs use different standards" "TUs on different standards are RED" --compile-commands "$TMP/mixed.json"

db "$TMP/nostd.json" "-Wall -Wextra -Wconversion -Wshadow -Wdouble-promotion -Werror -ffp-contract=off" "$FLOOR -ffp-contract=off"
expect 1 "a.c: no -std= flag" "a TU without a pinned standard is RED" --compile-commands "$TMP/nostd.json"

# The "command" (single string) form of an entry is read too.
python3 - "$TMP/ok.json" "$TMP/command.json" <<'PY'
import json, shlex, sys
db = json.load(open(sys.argv[1]))
for e in db:
    e["command"] = " ".join(shlex.quote(a) for a in e.pop("arguments"))
json.dump(db, open(sys.argv[2], "w"))
PY
expect 0 "RESULT: GREEN" "the command-string form of an entry is read" --compile-commands "$TMP/command.json"

# A port's own contract replaces the defaults.
printf 'std: [c11]\nrequired: [-Wall, -Werror]\nforbidden: [-ffast-math]\n' >"$TMP/contract.yaml"
db "$TMP/c11.json" "-std=c11 -Wall -Werror -ffp-contract=off" "-std=c11 -Wall -Werror -ffp-contract=off"
expect 0 "RESULT: GREEN" "a port's contract file replaces the default floor" --compile-commands "$TMP/c11.json" --contract "$TMP/contract.yaml"
expect 1 "a.c: -Wextra is missing" "without that contract the same build is RED on the default floor" --compile-commands "$TMP/c11.json"

# ---- objects: fused multiply-adds -----------------------------------------------------------------
arch="$(uname -m)"
if [ "$arch" = x86_64 ] || [ "$arch" = aarch64 ]; then
	TGT=$([ "$arch" = x86_64 ] && echo "-march=haswell" || echo "")
	db "$TMP/obj-off.json" "$FLOOR -ffp-contract=off -O2 $TGT" "$FLOOR -ffp-contract=off -O2 $TGT"
	expect 0 "RESULT: GREEN" "objects built with contraction off hold no fused multiply-add" --compile-commands "$TMP/obj-off.json" --objects
	db "$TMP/obj-fast.json" "$FLOOR -O2 $TGT -ffp-contract=fast" "$FLOOR -ffp-contract=off -O2 $TGT"
	cp "$TMP/obj-fast.json" "$TMP/obj-fast-flags-hidden.json"
	expect 1 "fused multiply-add instruction(s) in fma_candidate" "an object that contracted a*b + c is RED" --compile-commands "$TMP/obj-fast.json" --objects
	# The object is the evidence even when the database's flags look right: rebuild a.o with
	# contraction on, then point the database at flags that claim it is off.
	python3 - "$TMP/obj-off.json" "$TMP/claims-off.json" <<'PY'
import json, sys
json.dump(json.load(open(sys.argv[1])), open(sys.argv[2], "w"))
PY
	( cd "$P" && "$CC" $FLOOR -O2 $TGT -ffp-contract=fast -c a.c -o a.o )
	expect 1 "fused multiply-add" "an object that contradicts its database entry is RED" --compile-commands "$TMP/claims-off.json" --objects
else
	ok "# SKIP object cases: no FMA pattern for $arch"
fi

# ---- fail closed ------------------------------------------------------------------------------------
rm -f "$P/b.o"
expect 2 "does not exist: build before checking" "a missing object is UNRELIABLE" --compile-commands "$TMP/ok.json" --objects
expect 2 "cannot read the compilation database" "a missing database is UNRELIABLE" --compile-commands "$TMP/absent.json"
printf '[]\n' >"$TMP/empty.json"
expect 2 "lists no .c translation unit" "an empty database is UNRELIABLE" --compile-commands "$TMP/empty.json"
printf '[{"directory": "%s", "file": "m.f90", "arguments": ["gfortran", "-c", "m.f90"]}]\n' "$P" >"$TMP/fortran.json"
expect 2 "lists no .c translation unit" "a database with no C file is UNRELIABLE" --compile-commands "$TMP/fortran.json"
printf 'std: c17\n' >"$TMP/bad-contract.yaml"
expect 2 "must be a list of strings" "a malformed contract is UNRELIABLE" --compile-commands "$TMP/c11.json" --contract "$TMP/bad-contract.yaml"

# ---- one source of truth: the defaults are the floor written in references/langs/c.md ---------------
drift="$(python3 - "$CHECK" "$ROOT/.opencode/skill/target-conventions/references/langs/c.md" <<'PY'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("check_build_flags", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
doc = open(sys.argv[2], encoding="utf-8").read()
section = doc.split("## Language pinning", 1)[1].split("\n## ", 1)[0]
documented = {t for t in re.findall(r"`(-[^`\s]+)`", section) if t != "-Wno-<warning>"}
code = {"-std=" + s for s in m.DEFAULT["std"]} | set(m.DEFAULT["required"]) | set(m.DEFAULT["forbidden"]) | {"-ffp-contract=off"}
for f in sorted(code - documented):
    print(f"the check enforces {f}, which langs/c.md does not list")
for f in sorted(documented - code):
    print(f"langs/c.md lists {f}, which the check does not enforce")
PY
)"
if [ -z "$drift" ]; then
	ok "the check's default contract is the floor langs/c.md writes down"
else
	not_ok "the check's default contract and langs/c.md drifted apart" "$drift"
fi

if [ "$failures" -ne 0 ]; then
	echo "# test-build-flags: $failures failure(s)" >&2
	exit 1
fi
echo "# test-build-flags: all assertions passed"
