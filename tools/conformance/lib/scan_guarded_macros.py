#!/usr/bin/env python3
"""scan_guarded_macros.py - lexer-level scan for preprocessor conditionals referencing a
pinned-off macro, using clang's OWN raw tokenizer instead of a hand-rolled line-splicer.

REUSED, NOT RE-DERIVED: this scanner was first hardened for a C-rendering conformance check,
which was sent back THREE consecutive independent-review rounds on hand-rolled
backslash-continuation/comment/whitespace splicing before it delegated to clang's own raw lexer
(see the round-3/round-4 notes immediately below). The anchor verifier's `_dp_conditional_
directive` (review round 6, F-16) hit the EXACT same class of hole - `#if defined` followed by a
line-continuation backslash then a newline then `(USE_DOUBLE)` evaded a hand-rolled,
single-physical-line regex - so it reuses the ALREADY-PROVEN fix instead of re-hardening a
hand-rolled scanner a fourth time. `verify_anchors_ast.py` imports this module directly (both
live in `tools/conformance/lib/`, the methodology layer); this file's own logic is fully
project-agnostic, parameterized entirely by the `macros` argument.

REWORK ROUND 3 (independent re-review, F-02 "remains open"): round 1/2 fixed
two concrete splicing bugs by hand (a mid-token macro-name split; a dangling continuation/comment
at EOF) but the underlying method - recognize "is this physical line a directive" FIRST, then
splice continuations WITHIN an already-recognized directive - is backwards relative to real C,
where phase-2 (backslash-newline splicing) applies unconditionally to EVERY physical line BEFORE
phase-3 tokenization ever runs, including before the `#` + keyword that makes a line a directive AT
ALL. The reviewer's fresh probe spliced INSIDE the keyword itself ("#i" + backslash + newline +
"f defined(WITH_FEATURE)") - a real compiler assembles this into `#if defined(WITH_FEATURE)` and takes the
guarded branch, but this checker's line-first recognizer never even saw a directive to splice
within, and returned a false GREEN with zero directives inspected. Each hand-fix revealed the next
unanticipated spelling - exactly the "spelling I did not anticipate" pattern named in the dispatch.
FIX: stop hand-implementing phase-2. Use `clang -Xclang -dump-raw-tokens`, clang's own RAW lexer
(phase 1-3 only - no preprocessing, no macro expansion, no conditional evaluation - so BOTH
branches of every `#if`/`#ifdef` remain visible as ordinary tokens, which is exactly what this
TEXT-PRESENCE check needs: it must catch a guarded region regardless of which branch the pinned
build would compile). Backslash-newline splicing is handled internally by clang's lexer - a token
split mid-keyword is reported as ONE token with an `UnClean='...'` note, verified empirically this
session; no line-oriented reasoning of any kind remains in this script.

WHY THE RAW (undocumented `-Xclang`) MODE, NOT A NORMAL PARSE: a normal preprocessing parse (gcc
-E, or a plain libclang TranslationUnit) resolves every conditional - the INACTIVE branch is
discarded before it ever becomes a token, and (since the pinned-off feature macros are undefined)
the very regions this check exists to find would never be visible in a normally-preprocessed
stream at all. This is a genuinely different tool from an ordinary libclang parse -
different question (does a guarded directive's TEXT survive translation, not what does the
compiled program do), different libclang facility. `-Xclang -dump-raw-tokens` is an internal clang
debugging flag, not a documented stable API - this script's `_parse_raw_tokens()` therefore fails
CLOSED (raises, caller reports UNRELIABLE) the moment its expected text shape stops matching,
rather than silently degrading; it does not shell out to any OTHER undocumented behavior beyond
this one, verified-this-session flag.

REWORK ROUND 4 (independent re-review, F-02 "remains open" on a narrower form): round 3 adopted
clang's raw lexer for SPLICING but the DIRECTIVE RECOGNIZER it fed still hand-implemented its own
notion of "is this a directive line" - it required the `hash` TOKEN ITSELF to carry clang's
`StartOfLine` flag, then skipped only BLANK tokens before the keyword. Verified empirically this
session (see below): clang attaches `StartOfLine` to whichever token is lexically first after
crossing a newline - LEADING WHITESPACE before `#`, or a leading COMMENT - never to the `#` that
follows one, and a comment BETWEEN `#` and the keyword (`#/**/ifdef ...`) was never skipped at all
(only blank tokens were). Both `  #ifdef WITH_FEATURE` (ordinary indentation) and `#/**/ifdef
WITH_FEATURE` are compiler-recognized ACTIVE directives - ordinary C, not adversarial - that this
scanner false-greened with zero directives inspected, an even more common shape than the round-3
split-keyword finding.

FIX: stop testing individual tokens; group the token stream into C's own unit of directive
recognition - the LOGICAL LINE - and ask the C STANDARD's OWN QUESTION of that whole line: is the
FIRST token that is neither blank whitespace nor a comment a `#` (or its digraph spelling, `%:`,
which clang's raw lexer already reports as an ordinary `hash`-type token - verified this session)?
`_spans()` below computes these logical-line groups directly from clang's `StartOfLine` flag
(a new span begins at EVERY token that carries it, wherever the lexer chose to place it - this
does not require knowing WHICH specific token gets the flag, only that it correctly marks each
line boundary, which was verified against every shape below, including a `//` line comment whose
trailing newline token merges with the NEXT line's leading indentation into one blank token that
itself carries no flag at all - the token AFTER it still correctly starts the next span). Within a
span, blanks AND comments are transparent (skipped) both before the `#` and between `#` and the
keyword - matching translation phase 3, where a comment becomes indistinguishable from whitespace.

TRIGRAPHS AND DIGRAPHS: the reviewer's recommendation also named the trigraph spelling of `#`
(`??=`). Verified empirically this session against the pinned C dialect (`-std=c17`):
`gcc -std=c17` (strict ISO, not `-std=gnu17`) silently trigraph-
translates `??=ifdef WITH_FEATURE` into a real, active `#ifdef WITH_FEATURE` (confirmed via `gcc -E`
that the guarded body is elided); `clang -std=c17` (no separate `-trigraphs` flag needed) does the
same, folding the trigraph into an ordinary `hash`-type token with an `UnClean='??='` marker before
this script ever sees it. FIX: invoke clang with `-std=c17` (matching the pinned dialect, not
clang's own unrelated default) instead of an unstated default - this is not a special case in this
script's own logic, it is asking the SAME compiler dialect the real pinned build uses, so trigraph
and digraph spellings are handled by construction, not by a per-spelling branch here.

A SELF-FOUND BONUS FIX (not dispatched, found while re-deriving this function from scratch):
round 1-3's "dangling directive" UNRESOLVED path fired whenever the directive
being scanned was the LAST thing in the token stream, treating "properly terminated by a real
trailing newline, but happens to be the file's last line" identically to "the file was genuinely
truncated mid backslash-continuation splice with nothing to splice onto". Demonstrated false
UNRESOLVED on an ordinary `#ifdef WITH_FEATURE\\n` as a file's only content. Distinguishing the two
by inspecting individual whitespace-token spellings turned out to be unreliable (a trailing `//`
comment merges the directive's closing newline into a LATER multi-line token that does not itself
end in one - verified this session), so this is now checked once, directly against the source
BYTES: a directive is dangling only when it is the file's LAST span AND the source (stripped of at
most one trailing newline) ends in a bare backslash - exactly the round-1 "dangling backslash-
continued directive" shape, and nothing broader.

Usage: scan_guarded_macros.py <file> <macro1> [macro2 ...]

Output protocol (stdout, tab-separated - the bash caller parses this exactly as it parsed the
awk-emitted records in rounds 1-2):
  TOTAL\t<n>                              number of if/ifdef/ifndef/elif directives inspected
  FAIL\t<line>\t<macro> (directive: ...)   a directive references a pinned-off macro
  UNRESOLVED\t<line>\t<reason>             a directive/comment could not be classified (malformed)

Exit codes:
  0  ran to completion (records printed, TOTAL always last)
  3  could not run clang / could not parse its raw-token output AT ALL (environment-level
     failure before any record could be produced) - caller treats this as UNRELIABLE, exactly
     like a missing `clang.cindex` import in a libclang-based check
"""
import re
import subprocess
import sys

DIRECTIVE_KEYWORDS = {"if", "ifdef", "ifndef", "elif"}

# One raw-token entry: TYPE 'SPELLING'\t[ FLAGS]...\tLoc=<file:line:col> - SPELLING may itself
# contain literal embedded newlines (an unterminated comment swallows the rest of the file into
# ONE token), so this is matched with DOTALL over the whole text, anchored on the trailing
# Loc=<...> marker that terminates every entry. FLAGS is not always a single bracket group - a
# continuation-spliced token carries TWO, e.g. "[LeadingSpace] [UnClean='...']" (verified this
# session: a seeded multi-line fixture's second `defined(...)`, split across the backslash-newline, was
# SILENTLY DROPPED by an earlier version of this regex that only matched one bracket group - found
# by re-deriving every seeded probe against this parser, not assumed correct). The flags group
# below captures the WHOLE "[...] [...] ..." run as one string; callers only ever test substring
# membership within it (e.g. "StartOfLine in flags"), so capturing it as one blob is sufficient
# and does not need to separate the individual bracketed items. A comment/identifier containing a
# literal "'<TAB>" sequence could in principle confuse this (a documented heuristic, not a general
# parser - the same posture every other script in this project states), but is not a realistic C
# source shape.
_TOKEN_RE = re.compile(
	r"^(?P<type>[A-Za-z_]+) '(?P<spelling>.*?)'\t(?P<flags>(?: ?\[[^\]]*\])*)\t?"
	r"Loc=<(?P<file>[^:]*):(?P<line>\d+):(?P<col>\d+)>$",
	re.MULTILINE | re.DOTALL,
)


def _parse_raw_tokens(path):
	"""Returns a list of token dicts for `path`, using clang's raw (pre-preprocessing) lexer,
	invoked with the pinned C dialect (-std=c17) so trigraph
	and digraph spellings of `#` are folded exactly as the real pinned GCC build folds them (round
	4 - see module docstring), not by a guessed or unstated default. Raises RuntimeError on ANY
	environment/parse failure - never returns a partial/guessed result."""
	try:
		r = subprocess.run(
			["clang", "-std=c17", "-Xclang", "-dump-raw-tokens", "-fsyntax-only", "-xc", path],
			capture_output=True, text=True, timeout=30,
		)
	except (OSError, subprocess.SubprocessError) as e:
		raise RuntimeError(f"could not run clang: {e}") from e
	text = r.stderr
	tokens = [m.groupdict() for m in _TOKEN_RE.finditer(text)]
	if not tokens:
		try:
			import os
			non_empty = os.path.getsize(path) > 0
		except OSError as e:
			raise RuntimeError(f"could not stat {path}: {e}") from e
		if non_empty:
			raise RuntimeError(
				f"clang raw-token output did not match the expected shape for a non-empty file "
				f"(0 tokens parsed from {len(text)} byte(s) of clang output) - refusing to guess"
			)
	return tokens


def _is_blank(tok):
	return tok["type"] == "unknown" and tok["spelling"].strip() == ""


def _spans(tokens):
	"""Split `tokens` into logical-line spans: a new span begins at EVERY token carrying clang's
	`StartOfLine` flag (index 0 always begins the first span, regardless of its own flags - it is
	the start of the file), and each span runs up to (not including) the next such token. This is
	the C standard's own unit of directive recognition (phase 4: "the first token ... follows white
	space containing at least one new-line character") expressed directly in terms of what clang's
	lexer already computes - round 4 (see module docstring) replaced a per-token "is THIS the hash
	AND does it carry StartOfLine" test with this grouping precisely because the flag is not always
	on the hash itself (round-3's bug) and is not always on the very first physical byte of the
	span either (a `//` comment can merge a line's trailing newline with the NEXT line's leading
	indentation into one flag-less token - verified this session - so spans, not individual token
	positions, are the reliable unit)."""
	n = len(tokens)
	if n == 0:
		return []
	starts = [0]
	for idx in range(1, n):
		flags = tokens[idx].get("flags") or ""
		if "StartOfLine" in flags:
			starts.append(idx)
	starts.append(n)
	return [(starts[k], starts[k + 1]) for k in range(len(starts) - 1)]


def _first_significant(tokens, start, end):
	"""Index of the first token in tokens[start:end] that is neither blank whitespace nor a
	comment - both are transparent to directive recognition, exactly as phase 3 makes a comment
	indistinguishable from a single space - or None if the whole range is blank/comments."""
	idx = start
	while idx < end:
		t = tokens[idx]
		if not (_is_blank(t) or t["type"] == "comment"):
			return idx
		idx += 1
	return None


def _ends_mid_splice(path):
	"""True if the file's own bytes end in a bare backslash (after stripping at most one trailing
	newline) - the ONLY shape round 4 still treats as a genuinely dangling directive (see module
	docstring's "self-found bonus fix"): phase-2 attempted a continuation splice that had nothing
	left to splice onto. Checked once, directly against the source, never inferred from individual
	whitespace-token spellings (unreliable - see docstring)."""
	try:
		with open(path, "r", encoding="utf-8", errors="surrogateescape") as fh:
			text = fh.read()
	except OSError as e:
		raise RuntimeError(f"could not read {path}: {e}") from e
	return bool(text) and text.rstrip("\n").endswith("\\")


def scan(path, macros):
	tokens = _parse_raw_tokens(path)
	records = []
	total = 0

	for t in tokens:
		if t["type"] == "unknown" and t["spelling"].startswith("/*") and "*/" not in t["spelling"]:
			records.append(("UNRESOLVED", t["line"], "unterminated block comment (/* opened, never closed) - file is malformed, cannot verify"))

	dangling_eof = _ends_mid_splice(path)
	n = len(tokens)
	for start, end in _spans(tokens):
		idx = _first_significant(tokens, start, end)
		if idx is None or tokens[idx]["type"] != "hash":
			continue  # this logical line is not a directive at all (round 4: correctly permits
			# leading whitespace/comments before the '#' - see module docstring)
		k = _first_significant(tokens, idx + 1, end)
		if k is None or tokens[k]["type"] != "raw_identifier" or tokens[k]["spelling"] not in DIRECTIVE_KEYWORDS:
			continue  # a '#' introduces some OTHER directive (#define/#include/#pragma/#endif/...,
			# or is malformed) - not of interest to this scan, same scope as rounds 1-3
		keyword = tokens[k]["spelling"]
		directive_line = tokens[idx]["line"]
		parts = [f"#{keyword}"]
		found_macro = None
		for m in range(k + 1, end):
			tk = tokens[m]
			if tk["type"] == "raw_identifier":
				parts.append(tk["spelling"])
				if found_macro is None and tk["spelling"] in macros:
					found_macro = tk["spelling"]
			elif tk["type"] not in ("unknown", "comment"):
				parts.append(tk["spelling"])
		total += 1
		directive_text = " ".join(parts)
		# closed: every span is a properly terminated directive line UNLESS it is the file's very
		# LAST span AND the file's own bytes end mid backslash-continuation splice (round 4's
		# self-found fix - see module docstring; round 1-3 treated EVERY last-span directive as
		# dangling, a false UNRESOLVED on the extremely common "directive is simply the last line
		# of an otherwise complete file" shape).
		closed = not (end == n and dangling_eof)
		if not closed:
			records.append(("UNRESOLVED", directive_line, f"dangling #{keyword} directive never terminated before EOF: {directive_text}"))
		elif found_macro is not None:
			records.append(("FAIL", directive_line, f"{found_macro} (directive: {directive_text})"))
	return total, records


def main():
	if len(sys.argv) < 3:
		print("usage: scan_guarded_macros.py <file> <macro1> [macro2 ...]", file=sys.stderr)
		return 3
	path, macros = sys.argv[1], sys.argv[2:]
	try:
		total, records = scan(path, macros)
	except RuntimeError as e:
		print(f"scan_guarded_macros: {path}: {e}", file=sys.stderr)
		return 3
	for tag, line, msg in records:
		print(f"{tag}\t{line}\t{msg}")
	print(f"TOTAL\t{total}")
	return 0


if __name__ == "__main__":
	sys.exit(main())
