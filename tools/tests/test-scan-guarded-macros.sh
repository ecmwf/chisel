#!/usr/bin/env bash
# Regression tests for tools/conformance/lib/scan_guarded_macros.py, which the guarded-macro scan
# (and through it the anchor verifier's dp-define check) and the dependency extractor's
# guarded-region liveness both read.
#
# The scanner reads tokens from clang's raw lexer through libclang's token API. The cases run the
# real lexer: two fixtures (tools/tests/fixtures/guarded-macros/: sample.c with every directive
# spelling the scan must find, kinds.c with every token kind), the line-ending, splice, trigraph and
# end-of-file shapes the lexer must accept, and the fail-closed paths (a byte outside every token,
# an unterminated comment, a dangling splice, no libclang, an unreadable file). A missing libclang
# fails the test; it never skips.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/tools/conformance/lib"
FIX="$ROOT/tools/tests/fixtures/guarded-macros"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

failures=0
ok() { printf 'ok - %s\n' "$1"; }
not_ok() { printf 'not ok - %s\n    %s\n' "$1" "${2:-}"; failures=$((failures + 1)); }

# ---- In-process cases: verdicts, token stream, fail-closed paths --------------------------------
if ! python3 - "$LIB" "$FIX" "$TMP" <<'PY'
import os
import sys

LIB, FIX, TMP = sys.argv[1:4]
sys.path.insert(0, LIB)
import scan_guarded_macros as sgm  # noqa: E402

failures = 0


def check(label, cond, detail=""):
	global failures
	if cond:
		print(f"ok - {label}")
	else:
		failures += 1
		print(f"not ok - {label}\n    {detail}")


def verdict(path, macros=("WITH_FEATURE",)):
	"""(total, [(tag, line), ...]) of a scan, or the refusal as a string."""
	try:
		total, records = sgm.scan(path, list(macros))
	except RuntimeError as e:
		return f"refused: {e}"
	return total, [(tag, line) for tag, line, _msg in records]


def write(name, data):
	path = os.path.join(TMP, name)
	with open(path, "wb") as fh:
		fh.write(data)
	return path


try:
	import clang.cindex  # noqa: F401
except ImportError as e:
	check("libclang's Python bindings are importable", False, str(e))
	sys.exit(1)

# sample.c: plain, indented, comment-led, continued, spliced-keyword and negated directives.
EXPECTED = (6, [("FAIL", "2"), ("FAIL", "5"), ("FAIL", "7"), ("FAIL", "9"), ("FAIL", "12")])
got = verdict(os.path.join(FIX, "sample.c"))
check("sample.c: 6 directives, the 5 naming WITH_FEATURE flagged", got == EXPECTED, f"got {got}")

# kinds.c: every token kind, digraph and trigraph; only its last directive is a conditional.
got = verdict(os.path.join(FIX, "kinds.c"))
check("kinds.c: its one conditional directive is found and flagged", got == (1, [("FAIL", "16")]), f"got {got}")
try:
	toks = sgm._parse_raw_tokens(os.path.join(FIX, "kinds.c"))
except RuntimeError as e:
	check("kinds.c is tokenized", False, str(e))
	toks = []
types = {t["type"] for t in toks}
want = {"hash", "raw_identifier", "comment", "numeric_constant", "literal", "pipepipe", "ampamp",
        "exclaim", "l_paren", "r_paren", "punct"}
check("kinds.c: every token type the callers read is produced", want <= types, f"missing {sorted(want - types)}")
check("kinds.c: the trigraph and digraph spellings of # are hash tokens",
      sum(1 for t in toks if t["type"] == "hash" and t["line"] == "6") == 3,
      f"line 6 hash tokens: {[t['spelling'] for t in toks if t['line'] == '6']}")
check("every token carries type, spelling, line and start_of_line",
      bool(toks) and all(set(t) == {"type", "spelling", "line", "start_of_line"} for t in toks))

# Line-ending, splice, trigraph and end-of-file shapes: one guarded directive, on the given line.
SHAPES = {
	"CRLF line endings": (b"int a;\r\n#ifdef WITH_FEATURE\r\n#endif\r\n", "2"),
	"CR line endings": (b"int a;\r#ifdef WITH_FEATURE\r#endif\r", "2"),
	"LF then CR": (b"int a;\n\r#ifdef WITH_FEATURE\n\r#endif\n", "3"),
	"a byte-order mark": (b"\xef\xbb\xbf#ifdef WITH_FEATURE\n#endif\n", "1"),
	"a NUL byte": (b"int a\x00;\n#ifdef WITH_FEATURE\n#endif\n", "2"),
	"escaped newlines at end of file": (b"#ifdef WITH_FEATURE\n#endif\nint a; \\\n\\ \t\r\n", "1"),
	"an escaped LF-CR newline at end of file": (b"#ifdef WITH_FEATURE\n#endif\nint a; \\\n\r", "1"),
	"a trigraph and a trigraph splice": (b"??=i??/\nfdef WITH_FEATURE\n??=endif\n", "1"),
	"trigraph operators": (b"#if defined(OTHER) ??!??! defined(WITH_FEATURE)\n#endif\n", "1"),
	"a splice after trailing blanks": (b"#if defined(OTHER) || \\  \n  defined(WITH_FEATURE)\n#endif\n", "1"),
	"a CRLF splice inside a keyword": (b"#i\\\r\nfdef WITH_FEATURE\r\n#endif\r\n", "1"),
	"a line comment before an indented directive": (b"int a; // c\n  #ifdef WITH_FEATURE\n#endif\n", "2"),
	"a spliced line comment": (b"// c \\\n continued\n#ifdef WITH_FEATURE\n#endif\n", "3"),
	"a comment closed by a spliced */": (b"/* c *\\\n/ #ifdef WITH_FEATURE\n#endif\n", "2"),
	"a UTF-16 character constant": (b"#ifdef WITH_FEATURE\nint guarded;\n#endif\nint c = u'\\u2028';\n", "1"),
	"Fortran text with apostrophes and ! comments": (
		b"module m\n  ! it's a comment\n  character(len=*), parameter :: s = 'don''t'\n"
		b"#ifdef WITH_FEATURE\n  use plug, only: p\n#endif\nend module m\n", "4"),
}
for what, (data, line) in SHAPES.items():
	path = write("shape.c", data)
	got = verdict(path)
	check(f"a source with {what} is scanned: the guarded directive on line {line}",
	      got == (1, [("FAIL", line)]), f"got {got!r}")

got = verdict(write("inactive.c", b"#if 0\nint a;\n#else\n#ifdef WITH_FEATURE\n#endif\n#endif\n"))
check("a directive inside an inactive branch is scanned too", got == (2, [("FAIL", "4")]), f"got {got}")
got = verdict(write("midline.c", b"int y; # ifdef WITH_FEATURE\n"))
check("a # after other tokens on its line is not a directive", got == (0, []), f"got {got}")
got = verdict(write("empty.c", b""))
check("an empty file has no directives", got == (0, []), f"got {got}")
got = verdict(write("comment.c", b"#ifdef WITH_FEATURE\n#endif\n/* never closed\n#ifdef X\n"))
check("an unterminated block comment is UNRESOLVED, at its line",
      got == (1, [("UNRESOLVED", "3"), ("FAIL", "1")]), f"got {got}")
got = verdict(write("dangling.c", b"#ifdef WITH_FEATURE \\\n"))
check("a directive left open by a splice at end of file is UNRESOLVED", got == (1, [("UNRESOLVED", "1")]), f"got {got}")

# A byte that belongs to no token is refused: drop one token from what libclang returns.
import clang.cindex as ci  # noqa: E402
real = ci.TranslationUnit.get_tokens


def drop_second(self, *a, **kw):
	for i, t in enumerate(real(self, *a, **kw)):
		if i != 1:
			yield t


ci.TranslationUnit.get_tokens = drop_second
try:
	sgm.scan(os.path.join(FIX, "sample.c"), ["WITH_FEATURE"])
	check("a byte outside every token is refused (RuntimeError)", False, "the scan completed")
except RuntimeError as e:
	check("a byte outside every token is refused (RuntimeError)", "belong to no token" in str(e), str(e))
finally:
	ci.TranslationUnit.get_tokens = real

sys.exit(1 if failures else 0)
PY
then
	failures=$((failures + 1))
fi

# ---- Command line: output protocol and exit 3 ----------------------------------------------------
out="$(python3 "$LIB/scan_guarded_macros.py" "$FIX/sample.c" WITH_FEATURE)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | tail -1)" = "$(printf 'TOTAL\t6')" ] \
	&& [ "$(printf '%s\n' "$out" | grep -c '^FAIL	')" -eq 5 ]; then
	ok "the command line prints the FAIL records, then TOTAL, and exits 0"
else
	not_ok "the command line prints the FAIL records, then TOTAL, and exits 0" "exit $rc: $out"
fi

mkdir -p "$TMP/nolibclang/clang"
: >"$TMP/nolibclang/clang/__init__.py"
printf 'raise ImportError("libclang withheld by the test")\n' >"$TMP/nolibclang/clang/cindex.py"
PYTHONPATH="$TMP/nolibclang" python3 "$LIB/scan_guarded_macros.py" "$FIX/sample.c" WITH_FEATURE >"$TMP/out" 2>"$TMP/err" && rc=0 || rc=$?
if [ "$rc" -eq 3 ] && ! grep -q '^TOTAL' "$TMP/out"; then
	ok "without libclang the scan exits 3 (UNRELIABLE), never a clean TOTAL"
else
	not_ok "without libclang the scan exits 3 (UNRELIABLE), never a clean TOTAL" "exit $rc: $(cat "$TMP/out" "$TMP/err")"
fi

python3 "$LIB/scan_guarded_macros.py" "$TMP/does-not-exist.c" WITH_FEATURE >"$TMP/out" 2>&1 && rc=0 || rc=$?
if [ "$rc" -eq 3 ]; then
	ok "an unreadable file exits 3"
else
	not_ok "an unreadable file exits 3" "exit $rc: $(cat "$TMP/out")"
fi

if [ "$failures" -ne 0 ]; then
	echo "# test-scan-guarded-macros: $failures failure(s)" >&2
	exit 1
fi
echo "# test-scan-guarded-macros: all assertions passed"
