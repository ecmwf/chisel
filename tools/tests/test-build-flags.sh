#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# tools/build-checks/check-build-flags.py against a two-file C project built here: the flags each
# translation unit really received (from a compilation database, read through the compiler's own
# -### job) and, with --objects, the fused multiply-adds in its object. Every RED and UNRELIABLE case
# below is a contract break or a missing fact the check must report; the GREEN ones are builds it
# must accept. Needs gcc (or cc) and clang; a missing one fails the test, it never skips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/tools/build-checks/check-build-flags.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CC="$(command -v gcc || command -v cc)"
CLANG="$(command -v clang || true)"

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n' "$1"; printf '%s\n' "${2:-}" | sed 's/^/    /'; failures=$((failures + 1)); }
[ -n "$CLANG" ] || { not_ok "clang is installed"; exit 1; }
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

# db FILE "FLAGS for a.c" "FLAGS for b.c" [COMPILER]: a compilation database in the "arguments" form,
# and the objects built with exactly those flags (when the compiler accepts them).
db() {
	python3 - "$1" "$P" "${4:-$CC}" "$2" "$3" <<'PY'
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
    subprocess.run(e["arguments"], cwd=e["directory"], stderr=subprocess.DEVNULL)
PY
}

# ---- flags --------------------------------------------------------------------------------------
db "$TMP/ok.json" "$FLOOR -ffp-contract=off -O2" "$FLOOR -ffp-contract=off -O2"
expect 0 "RESULT: GREEN" "a build on the contract is GREEN" --compile-commands "$TMP/ok.json"
db "$TMP/ok-clang.json" "$FLOOR -ffp-contract=off -O2" "$FLOOR -ffp-contract=off -O2" "$CLANG"
expect 0 "RESULT: GREEN" "a clang build on the contract is GREEN" --compile-commands "$TMP/ok-clang.json"

db "$TMP/no-contract.json" "$FLOOR -O2" "$FLOOR -ffp-contract=off -O2"
expect 1 "a.c: -ffp-contract=off is missing" "a TU without -ffp-contract=off is RED" --compile-commands "$TMP/no-contract.json"
db "$TMP/clang-default.json" "$FLOOR -O2" "$FLOOR -ffp-contract=off -O2" "$CLANG"
expect 1 "the compiler runs -ffp-contract=on" "clang's default contraction (on) is RED" --compile-commands "$TMP/clang-default.json"

db "$TMP/fast.json" "$FLOOR -ffp-contract=off -O2 -ffast-math" "$FLOOR -ffp-contract=off -O2"
expect 1 "-ffast-math is forbidden" "-ffast-math in one TU is RED" --compile-commands "$TMP/fast.json"

db "$TMP/later.json" "$FLOOR -ffp-contract=off -O2 -ffp-contract=fast" "$FLOOR -ffp-contract=off -O2"
expect 1 "the compiler runs -ffp-contract=fast: contraction must be off" "a later -ffp-contract=fast overrides off and is RED" --compile-commands "$TMP/later.json"

db "$TMP/fpmodel.json" "$FLOOR -ffp-contract=off -O2 -ffp-model=fast" "$FLOOR -ffp-contract=off -O2" "$CLANG"
expect 1 "the compiler runs with -mreassociate" "clang's -ffp-model=fast after -ffp-contract=off is RED, by what it expands into" --compile-commands "$TMP/fpmodel.json"
expect 1 "the compiler runs -ffp-contract=fast" "clang's -ffp-model=fast turns contraction back on" --compile-commands "$TMP/fpmodel.json"
db "$TMP/fpmodel-gcc.json" "$FLOOR -ffp-contract=off -ffp-model=fast" "$FLOOR -ffp-contract=off"
expect 2 "the compiler refuses the command" "a flag the compiler refuses is UNRELIABLE" --compile-commands "$TMP/fpmodel-gcc.json"

printf -- '-ffast-math\n' >"$P/fast.rsp"
db "$TMP/rsp.json" "$FLOOR -ffp-contract=off @fast.rsp" "$FLOOR -ffp-contract=off"
expect 1 "-ffast-math is forbidden" "-ffast-math inside a response file is RED" --compile-commands "$TMP/rsp.json"

db "$TMP/negated.json" "$FLOOR -ffp-contract=off -Wno-conversion" "$FLOOR -ffp-contract=off"
expect 1 "-Wno-conversion takes a warning back" "a -Wno- of a floor warning is RED" --compile-commands "$TMP/negated.json"
db "$TMP/longform.json" "$FLOOR -ffp-contract=off --warn-no-conversion" "$FLOOR -ffp-contract=off --no-warnings"
expect 1 "-Wno-conversion takes a warning back" "--warn-no-conversion is read as -Wno-conversion" --compile-commands "$TMP/longform.json"
expect 1 "-w is forbidden" "--no-warnings is read as -w" --compile-commands "$TMP/longform.json"

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
expect 1 "a.c: no -std= reaches the compiler" "a TU without a pinned standard is RED" --compile-commands "$TMP/nostd.json"
db "$TMP/ansi.json" "$FLOOR -ffp-contract=off -ansi" "$FLOOR -ffp-contract=off --std=gnu17"
expect 1 "a.c: the compiler runs -std=c90" "a later -ansi overrides -std=c17 and is RED" --compile-commands "$TMP/ansi.json"
expect 1 "b.c: the compiler runs -std=gnu17" "a later --std=gnu17 overrides -std=c17 and is RED" --compile-commands "$TMP/ansi.json"

# Product headers made system headers: every warning in them is silenced.
mkdir -p "$P/include" "$TMP/ext"
db "$TMP/isystem.json" "$FLOOR -ffp-contract=off -isystem include" "$FLOOR -ffp-contract=off -idirafter $P/include"
expect 1 "a.c: -isystem include makes product headers system headers" "-isystem naming a product directory is RED" --compile-commands "$TMP/isystem.json"
expect 1 "b.c: -idirafter $P/include makes product headers system headers" "-idirafter naming a product directory is RED" --compile-commands "$TMP/isystem.json"
db "$TMP/isystem-ext.json" "$FLOOR -ffp-contract=off -isystem $TMP/ext" "$FLOOR -ffp-contract=off -isystem$TMP/ext"
expect 0 "RESULT: GREEN" "-isystem naming a directory outside the product is GREEN" --compile-commands "$TMP/isystem-ext.json"
expect 1 "makes product headers system headers" "--product-root decides what is inside the product" --compile-commands "$TMP/isystem-ext.json" --product-root "$TMP"
db "$TMP/prefix.json" "$FLOOR -ffp-contract=off --system-header-prefix=include/" "$FLOOR -ffp-contract=off" "$CLANG"
expect 1 "--system-header-prefix=include/ treats headers as system headers" "clang's --system-header-prefix is RED" --compile-commands "$TMP/prefix.json"
expect 2 "is not a directory" "a --product-root that does not exist is UNRELIABLE" --compile-commands "$TMP/ok.json" --product-root "$TMP/absent"

# The "command" (single string) form of an entry is read too.
python3 - "$TMP/ok.json" "$TMP/command.json" <<'PY'
import json, shlex, sys
db = json.load(open(sys.argv[1]))
for e in db:
    e["command"] = " ".join(shlex.quote(a) for a in e.pop("arguments"))
json.dump(db, open(sys.argv[2], "w"))
PY
expect 0 "RESULT: GREEN" "the command-string form of an entry is read" --compile-commands "$TMP/command.json"

# A port's contract adds to the defaults and never removes them.
db "$TMP/c11.json" "-std=c11 -Wall -Wextra -Wconversion -Wshadow -Wdouble-promotion -Werror -ffp-contract=off" \
	"-std=c11 -Wall -Wextra -Wconversion -Wshadow -Wdouble-promotion -Werror -ffp-contract=off"
printf 'std: [c11]\n' >"$TMP/c11.yaml"
expect 0 "RESULT: GREEN" "a contract's std replaces the pinned standards" --compile-commands "$TMP/c11.json" --contract "$TMP/c11.yaml"
printf 'std: [c17]\n' >"$TMP/c17.yaml"
expect 1 "the compiler runs -std=c11, not the pinned standard (c17)" "the same build against std: [c17] is RED" --compile-commands "$TMP/c11.json" --contract "$TMP/c17.yaml"
printf 'forbidden: [-fno-strict-aliasing]\nrequired: [-Wmissing-prototypes]\n' >"$TMP/adds.yaml"
expect 1 "-ffast-math is forbidden" "a contract's forbidden list adds to the defaults" --compile-commands "$TMP/fast.json" --contract "$TMP/adds.yaml"
expect 1 "a.c: -Wmissing-prototypes is missing" "a contract's required list adds to the floor" --compile-commands "$TMP/ok.json" --contract "$TMP/adds.yaml"
db "$TMP/noshadow.json" "-std=c17 -Wall -Wextra -Wconversion -Wdouble-promotion -Werror -ffp-contract=off -Wno-shadow" \
	"-std=c17 -Wall -Wextra -Wconversion -Wdouble-promotion -Werror -ffp-contract=off -Wno-shadow"
printf 'allowed: {-Wno-shadow: the reason}\n' >"$TMP/noshadow.yaml"
expect 0 "RESULT: GREEN" "an allowed -Wno-shadow stands in for the required -Wshadow" --compile-commands "$TMP/noshadow.json" --contract "$TMP/noshadow.yaml"

# Spellings only the command as written shows (gcc's driver replaces -march=native with the CPU),
# and what clang hands its compiler for a math mode, judged on the unit directly.
out="$(python3 - "$ROOT/tools/build-checks" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cbf", sys.argv[1] + "/check-build-flags.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c = m.load_contract(None)
floor = ["-std=c17", "-Wall", "-Wextra", "-Wconversion", "-Wshadow", "-Wdouble-promotion", "-Werror", "-ffp-contract=off"]
for written, cc1 in ((["-mcpu=native"], ["-mcpu=neoverse-n1"]), (["-march=native"], ["-march=znver3"]),
                     ([], ["-menable-no-nans"])):
    probs, _ = m.check_unit("u.c", floor + written, floor + cc1, c)
    print(" | ".join(p for _, p in probs))
PY
)"
if grep -q -- '-mcpu=native is forbidden' <<<"$out" && grep -q -- '-march=native is forbidden' <<<"$out" &&
	grep -q -- 'runs with -menable-no-nans' <<<"$out"; then
	ok "-mcpu=native and -march=native as written, and clang's -menable-no-nans, are RED"
else
	not_ok "-mcpu=native and -march=native as written, and clang's -menable-no-nans, are RED" "$out"
fi

# ---- objects: fused multiply-adds -----------------------------------------------------------------
arch="$(uname -m)"
if [ "$arch" = x86_64 ] || [ "$arch" = aarch64 ]; then
	TGT=$([ "$arch" = x86_64 ] && echo "-march=haswell" || echo "")
	db "$TMP/obj-off.json" "$FLOOR -ffp-contract=off -O2 $TGT" "$FLOOR -ffp-contract=off -O2 $TGT"
	expect 0 "RESULT: GREEN" "objects built with contraction off hold no fused multiply-add" --compile-commands "$TMP/obj-off.json" --objects
	db "$TMP/obj-fast.json" "$FLOOR -O2 $TGT -ffp-contract=fast" "$FLOOR -ffp-contract=off -O2 $TGT"
	expect 1 "fused multiply-add instruction(s) in fma_candidate" "an object that contracted a*b + c is RED" --compile-commands "$TMP/obj-fast.json" --objects
	# The object is the evidence even when the database's flags look right: rebuild a.o with
	# contraction on, under a database that claims it is off.
	(cd "$P" && "$CC" $FLOOR -O2 $TGT -ffp-contract=fast -c a.c -o a.o)
	expect 1 "fused multiply-add" "an object that contradicts its database entry is RED" --compile-commands "$TMP/obj-off.json" --objects
	(cd "$P" && "$CC" $FLOOR -O2 $TGT -ffp-contract=fast -flto -c a.c -o a.o)
	expect 2 "is an LTO object" "an LTO object, whose code is generated at link time, is UNRELIABLE" --compile-commands "$TMP/obj-off.json" --objects
	(cd "$P" && "$CC" $FLOOR -O2 -ffp-contract=off -c a.c -o a.o)
else
	not_ok "object cases need x86_64 or aarch64 (this is $arch)"
fi

# The mnemonic patterns on canned disassembly, so each architecture is tested on any machine.
out="$(python3 - "$ROOT/tools/build-checks" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("cbf", sys.argv[1] + "/check-build-flags.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fma = {
    "x86": ["vfmadd231sd %xmm2,%xmm1,%xmm0", "vfnmsub132pd (%rax),%ymm1,%ymm0", "vfmaddsd %xmm3,%xmm2,%xmm1,%xmm0",
            "{evex} vfmadd213ps %zmm2,%zmm1,%zmm0", "vfmadd132sh %xmm2,%xmm1,%xmm0", "vfcmaddcph %zmm2,%zmm1,%zmm0"],
    "aarch64": ["fmadd d0, d1, d2, d3", "fnmsub s0, s1, s2, s3", "fmla v0.2d, v1.2d, v2.2d", "fmls v0.4s, v1.4s, v2.4s",
                "fmad z0.d, p1/m, z1.d, z2.d", "fmsb z0.s, p0/m, z1.s, z2.s", "fnmad z0.d, p1/m, z1.d, z2.d",
                "fnmla z0.d, p1/m, z1.d, z2.d", "fnmls z0.d, p1/m, z1.d, z2.d", "fmlal v0.4s, v1.4h, v2.4h",
                "fmlsl2 v0.4s, v1.4h, v2.4h", "bfmlalb z0.s, z1.h, z2.h", "fcmla v0.2d, v1.2d, v2.2d, #90"],
}
clean = {
    "x86": ["call 1130 <vfmadd_ref>", "vmulsd %xmm1,%xmm0,%xmm0", "vaddsd %xmm1,%xmm0,%xmm0", "ret"],
    "aarch64": ["fmul d0, d1, d2", "fadd d0, d0, d3", "fmov d0, #1.0", "bl 0 <fmadd_ref>", "fmax d0, d1, d2"],
}
bad = []
for arch in fma:
    text = "0000000000000000 <f>:\n" + "".join(f"  {i:x}:\t{ins}\n" for i, ins in enumerate(fma[arch] + clean[arch]))
    hits = [h[1] for h in m.fma_hits(arch, text)]
    bad += [f"{arch}: missed {x}" for x in fma[arch] if x not in hits]
    bad += [f"{arch}: false hit {x}" for x in clean[arch] if x in hits]
print("\n".join(bad) or "none")
PY
)"
if [ "$out" = none ]; then
	ok "the x86 and AArch64 (scalar, SIMD, SVE) fused multiply-add mnemonics are matched, and only they"
else
	not_ok "the x86 and AArch64 fused multiply-add mnemonics are matched, and only they" "$out"
fi

# ---- the database: every C unit, and malformed entries fail closed --------------------------------
cp "$P/b.c" "$P/c.inc"
printf '[{"directory": "%s", "file": "c.inc", "arguments": ["%s", "-x", "c", "-c", "c.inc", "-o", "c.o"]}]\n' "$P" "$CC" >"$TMP/xc.json"
expect 1 "c.inc: -Werror is missing" "a file compiled with -x c is a C unit whatever its suffix" --compile-commands "$TMP/xc.json"
printf '[{"directory": "%s", "file": "a.c", "arguments": "%s -c a.c"}]\n' "$P" "$CC" >"$TMP/argstr.json"
expect 2 "is not a list of strings" "\"arguments\" given as a string is UNRELIABLE" --compile-commands "$TMP/argstr.json"
printf '[{"directory": "%s", "file": "a.c", "command": "%s -c \\"a.c"}]\n' "$P" "$CC" >"$TMP/quote.json"
expect 2 "cannot be split" "an unbalanced quote in a command is UNRELIABLE" --compile-commands "$TMP/quote.json"
printf '[{"directory": "%s", "file": null, "command": "cc -c a.c"}]\n' "$P" >"$TMP/null.json"
expect 2 "without a \"file\" and a \"directory\" string" "a null file is UNRELIABLE" --compile-commands "$TMP/null.json"
printf '[{"directory": "proj", "file": "a.c", "command": "cc -c a.c"}]\n' >"$TMP/reldir.json"
expect 2 "has a relative \"directory\"" "a relative directory is UNRELIABLE" --compile-commands "$TMP/reldir.json"
printf '[{"directory": "%s", "file": "a.c", "arguments": ["%s", "-c", "a.c", "@missing.rsp"]}]\n' "$P" "$CC" >"$TMP/norsp.json"
expect 2 "cannot read the response file" "a missing response file is UNRELIABLE" --compile-commands "$TMP/norsp.json"

rm -f "$P/b.o"
expect 2 "does not exist: build before checking" "a missing object is UNRELIABLE" --compile-commands "$TMP/ok.json" --objects
expect 2 "cannot read the compilation database" "a missing database is UNRELIABLE" --compile-commands "$TMP/absent.json"
printf '[]\n' >"$TMP/empty.json"
expect 2 "lists no C translation unit" "an empty database is UNRELIABLE" --compile-commands "$TMP/empty.json"
printf '[{"directory": "%s", "file": "m.f90", "arguments": ["gfortran", "-c", "m.f90"]}]\n' "$P" >"$TMP/fortran.json"
expect 2 "lists no C translation unit" "a database with no C file is UNRELIABLE" --compile-commands "$TMP/fortran.json"
printf 'std: c17\n' >"$TMP/bad-contract.yaml"
expect 2 "must be a non-empty list of strings" "a malformed contract is UNRELIABLE" --compile-commands "$TMP/c11.json" --contract "$TMP/bad-contract.yaml"

# ---- one source of truth: the defaults are the floor written in references/langs/c.md ---------------
# Each flag in the right role: the standards bullet gives `std`, the warnings bullet `required` before
# "Nothing takes a warning back" and `forbidden` after it, the floating-point bullet the contraction
# rule (-ffp-contract=off) and `forbidden` for every other flag.
drift="$(python3 - "$CHECK" "$ROOT/.opencode/skills/target-conventions/references/langs/c.md" <<'PY'
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("check_build_flags", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
doc = open(sys.argv[2], encoding="utf-8").read()
section = doc.split("## Language pinning", 1)[1].split("\n## ", 1)[0]
bullets = [" ".join(b.split()) for b in re.split(r"\n- ", "\n" + section)]
flags = lambda t: [f for f in re.findall(r"`(-[^`\s]+)`", t) if f != "-Wno-<warning>"]
doc_std, doc_req, doc_forb, contraction = set(), set(), set(), False
for b in bullets:
    if b.startswith("Pin the standard"):
        doc_std |= {f.split("=", 1)[1] for f in flags(b) if f.startswith("-std=")}
    elif b.startswith("Warnings are errors"):
        before, _, after = b.partition("Nothing takes a warning back")
        doc_req |= set(flags(before))
        doc_forb |= set(flags(after))
    elif b.startswith("Floating-point determinism"):
        for f in flags(b):
            if f == "-ffp-contract=off":
                contraction = True
            else:
                doc_forb.add(f)
problems = []
for role, doc_set, code in (("std", doc_std, set(m.DEFAULT["std"])), ("required", doc_req, set(m.DEFAULT["required"])),
                            ("forbidden", doc_forb, set(m.DEFAULT["forbidden"]))):
    problems += [f"{role}: the check has {f}, langs/c.md does not" for f in sorted(code - doc_set)]
    problems += [f"{role}: langs/c.md has {f}, the check does not" for f in sorted(doc_set - code)]
if not contraction:
    problems.append("langs/c.md does not state -ffp-contract=off")
print("\n".join(problems))
PY
)"
if [ -z "$drift" ]; then
	ok "the check's default contract is the floor langs/c.md writes down, each flag in its role"
else
	not_ok "the check's default contract and langs/c.md drifted apart" "$drift"
fi

if [ "$failures" -ne 0 ]; then
	echo "# test-build-flags: $failures failure(s)" >&2
	exit 1
fi
echo "# test-build-flags: all assertions passed"
