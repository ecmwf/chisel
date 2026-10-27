#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""scan_guarded_macros.py - find preprocessor conditionals that reference given macros.

The file is read through clang's raw lexer, via libclang's token API (`clang_tokenize`, which the
Python bindings expose as `TranslationUnit.get_tokens`). Raw lexing is translation phases 1-3
only: no preprocessing, no macro expansion and no conditional evaluation, so BOTH branches of every
`#if` stay visible as tokens. That is what this text-presence check needs: a guarded region must be
found whichever branch the pinned build compiles. A normal preprocessing parse would not do, because
it resolves each conditional and drops the inactive branch before it becomes a token.

The lexer, not this script, handles backslash-newline splices (also inside a keyword:
`#i\\<newline>f`), comments, digraphs and trigraphs. The file is lexed as `-std=c17`, the dialect
that enables trigraphs. Directives are found on logical lines: a token starts a line when the
whitespace before it holds a line break that is not part of a splice, and within a line, comments
are transparent before the `#` and between the `#` and the keyword (`  #ifdef X`, `#/**/ifdef X`).

Fail closed: every byte of the file must belong to a token or be whitespace. clang leaves out only
a byte-order mark at the start, NUL bytes (it reads them as whitespace) and an unterminated block
comment at the end; the last is reported as UNRESOLVED. Any other byte outside a token raises
RuntimeError, and so does a missing libclang: the caller reports UNRELIABLE, never a clean scan.

Token dicts, shared with tools/coordination/extract_dependencies.py:
  type           'hash' (`#`, `%:`, `??=`), 'raw_identifier' (identifiers and keywords),
                 'comment', 'numeric_constant', 'literal', 'pipepipe', 'ampamp', 'exclaim',
                 'l_paren', 'r_paren', 'punct', or 'unknown' (an unterminated block comment)
  spelling       the token's text after phases 1-2 (trigraphs replaced, splices removed)
  line           the line the token starts on, as a string (clang's count: CRLF, CR and LF
                 are one line break each)
  start_of_line  True when the token is the first one on its logical line

Usage: scan_guarded_macros.py <file> <macro1> [macro2 ...]

Output protocol (stdout, tab-separated):
  TOTAL\t<n>                              number of if/ifdef/ifndef/elif directives inspected
  FAIL\t<line>\t<macro> (directive: ...)   a directive references one of the macros
  UNRESOLVED\t<line>\t<reason>             a directive or comment could not be classified

Exit codes:
  0  ran to completion (records printed, TOTAL always last)
  3  could not tokenize the file (no libclang, unreadable file, bytes outside every token) -
     the caller treats this as UNRELIABLE
"""
import re
import sys

DIRECTIVE_KEYWORDS = {"if", "ifdef", "ifndef", "elif"}

_CLANG_ARGS = ["-x", "c", "-std=c17", "-w", "-nostdinc"]
_BOM = b"\xef\xbb\xbf"
_TRIGRAPHS = {b"??=": b"#", b"??/": b"\\", b"??'": b"^", b"??(": b"[", b"??)": b"]",
              b"??!": b"|", b"??<": b"{", b"??>": b"}", b"??-": b"~"}
_TRIGRAPH_RE = re.compile(rb"\?\?[=/'()!<>-]")
_SPLICE_RE = re.compile(rb"\\[ \t\f\v]*(?:\r\n|\r|\n)")
# Whitespace between tokens: blanks, line breaks, NUL, and splices (a backslash or the `??/`
# trigraph, optional trailing blanks, then a line break - clang accepts the blanks too).
_GAP_RE = re.compile(rb"(?:[ \t\f\v\r\n\x00]|(?:\\|\?\?/)[ \t\f\v]*(?:\r\n|\r|\n))*")
_PUNCT_TYPES = {"#": "hash", "%:": "hash", "||": "pipepipe", "&&": "ampamp", "!": "exclaim",
                "(": "l_paren", ")": "r_paren"}
_index = None


def _phases_1_2(raw):
	"""Trigraphs replaced (phase 1), then backslash-newline splices removed (phase 2)."""
	return _SPLICE_RE.sub(b"", _TRIGRAPH_RE.sub(lambda m: _TRIGRAPHS[m.group(0)], raw))


def _token_type(kind, spelling):
	if kind == "COMMENT":
		return "comment"
	if kind in ("IDENTIFIER", "KEYWORD"):
		return "raw_identifier"
	if kind == "LITERAL":
		lead = spelling[1:2] if spelling[:1] == "." else spelling[:1]
		return "numeric_constant" if "0" <= lead <= "9" else "literal"
	return _PUNCT_TYPES.get(spelling, "punct")


def _breaks_line(gap):
	"""True when whitespace between tokens holds a line break that is not part of a splice."""
	return re.search(rb"[\r\n]", _phases_1_2(gap)) is not None


def _line_of(data, offset):
	return str(len(re.findall(rb"\r\n|\r|\n", data[:offset])) + 1)


def _parse_raw_tokens(path):
	"""The token dicts of `path` (see the module docstring). Raises RuntimeError when the file
	cannot be read or tokenized, or when a byte belongs to no token - never a partial result."""
	global _index
	try:
		import clang.cindex as ci
	except ImportError as e:
		raise RuntimeError(f"libclang's Python bindings (clang.cindex) are not importable: {e}") from e
	try:
		with open(path, "rb") as fh:
			data = fh.read()
	except OSError as e:
		raise RuntimeError(f"could not read {path}: {e}") from e
	if not data:
		return []
	try:
		if _index is None:
			_index = ci.Index.create()
		tu = _index.parse(path, args=_CLANG_ARGS)
		f = tu.get_file(path)
		extent = ci.SourceRange.from_locations(
			ci.SourceLocation.from_offset(tu, f, 0), ci.SourceLocation.from_offset(tu, f, len(data)))
		raw = [(t.kind.name, t.extent.start.offset, t.extent.end.offset, t.location.line)
		       for t in tu.get_tokens(extent=extent)]
	except Exception as e:  # a library that does not load, a failed parse, a file it cannot map
		raise RuntimeError(f"libclang could not tokenize {path}: {e}") from e

	tokens = []
	prev = len(_BOM) if data.startswith(_BOM) else 0
	for kind, start, end, line in raw:
		gap = data[prev:start]
		if start < prev or end > len(data) or _GAP_RE.fullmatch(gap) is None:
			raise RuntimeError(
				f"{path}:{_line_of(data, prev)}: bytes that belong to no token ({gap[:40]!r}) - refusing to guess")
		spelling = _phases_1_2(data[start:end]).decode("utf-8", "surrogateescape")
		tokens.append({
			"type": _token_type(kind, spelling),
			"spelling": spelling,
			"line": str(line),
			"start_of_line": not tokens or _breaks_line(gap),
		})
		prev = end
	tail = data[prev:]
	rest = tail[_GAP_RE.match(tail).end():]
	if rest:
		at = len(data) - len(rest)
		if not rest.startswith(b"/*"):
			raise RuntimeError(
				f"{path}:{_line_of(data, at)}: bytes that belong to no token ({rest[:40]!r}) - refusing to guess")
		# clang emits no token for an unterminated block comment; keep it as one, so scan() reports it
		tokens.append({"type": "unknown", "spelling": rest.decode("utf-8", "surrogateescape"),
		               "line": _line_of(data, at), "start_of_line": not tokens or _breaks_line(tail[:-len(rest)])})
	return tokens


def _is_blank(tok):
	"""True for a whitespace token. The lexer emits none; callers filter with it anyway."""
	return tok["type"] == "unknown" and tok["spelling"].strip() == ""


def _spans(tokens):
	"""Split `tokens` into logical-line spans, as (start, end) index pairs: a span begins at every
	token that starts a logical line (and at index 0) and runs up to the next one. A logical line is
	the C standard's unit of directive recognition: a directive is a line whose first token,
	comments aside, is `#`."""
	n = len(tokens)
	if n == 0:
		return []
	starts = [0] + [idx for idx in range(1, n) if tokens[idx].get("start_of_line")]
	starts.append(n)
	return [(starts[k], starts[k + 1]) for k in range(len(starts) - 1)]


def _first_significant(tokens, start, end):
	"""Index of the first token in tokens[start:end] that is neither whitespace nor a comment
	(phase 3 makes a comment one space), or None when there is none."""
	idx = start
	while idx < end:
		t = tokens[idx]
		if not (_is_blank(t) or t["type"] == "comment"):
			return idx
		idx += 1
	return None


def _ends_mid_splice(path):
	"""True when the file's bytes end in a bare backslash (trailing newlines aside): a splice with
	nothing left to splice onto, so a directive on the last line is never terminated."""
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
			continue  # not a directive line
		k = _first_significant(tokens, idx + 1, end)
		if k is None or tokens[k]["type"] != "raw_identifier" or tokens[k]["spelling"] not in DIRECTIVE_KEYWORDS:
			continue  # another directive (#define, #include, #endif, ...) or a malformed one
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
		# A directive is terminated unless it is on the last line and the file ends mid splice.
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
