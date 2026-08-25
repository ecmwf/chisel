#!/usr/bin/env bash
#
# check-swap-residue.sh - detect an UNRESTORED swap-and-fail mutation left in TARGET code.
#
# Sibling of check-no-silenced-detectors.sh, and a different property: that one catches
# suppression ANNOTATIONS (pragmas, NOLINT) quieting a detector; this one catches disabled
# PRODUCT LOGIC. Both are "the code is not what it appears to be", from opposite directions.
#
# Why it exists (references/failure-modes.md, B23's corollary): B23 requires a swap-and-fail -
# substitute the rejected rendering, show the test go red, restore, show it green. That obligation
# makes deliberate mutation of the product a ROUTINE step for every unit, which creates a hazard the
# rule itself introduces: eventually a mutation is committed because the restore was forgotten. It
# is not hypothetical - a product commit shipped a neutralised policy check while its author
# reported a fully passing suite; the real result at that commit was two failing tests, and the
# author's own attached log contained the contradiction.
#
# Cheaply detectable, because a short-circuit literal in a condition is never a legitimate rendering
# of any SOURCE construct: no source language's `if` idiom translates to "and false". So any
# occurrence is either mutation residue or dead code that should have been deleted outright.
#
# Detected (whitespace- and comment-aware, not raw grep):
#   - a condition neutralised by a short-circuit literal:  if (false && ...) / if (... && false)
#     / while (true || ...) in either operand order, with optional parentheses around the
#     literal, and with the condition possibly split across lines. Comments and string
#     literals are ignored, so `/* if (false && x) */` does not false-RED.
#   - an unconditionally dead preprocessor guard: #if 0, #if (0), #if ( 0 ) etc. Comments
#     after the guard are ignored.
#
# The default pattern set targets a C/C++ TARGET and scans *.c/*.h; instantiate the patterns and
# the file glob per TARGET language, the way the index-helper and naming-map checks are. On a TARGET
# with no matching files the check skips (vacuous green), so it is harmless to ship enabled.
#
# Any build tree is EXCLUDED: generated build-system files legitimately contain `if(0)`-shaped
# content and would poison the scan - the same reason other product-facing checks exclude it.
#
# Exit: 0 GREEN (no residue, or no matching files), 1 RED (residue found), 2 UNRELIABLE (cannot
# examine the product root - never silently green).
set -uo pipefail

# PRODUCT_ROOT is resolved once by the runner and EXPORTED; the flag is the explicit override.
# Reading only the flag makes this report UNRELIABLE inside the suite even when the product is
# present - a real defect found in this check's first deployment.
PRODUCT_ROOT="${PRODUCT_ROOT:-}"
while [ $# -gt 0 ]; do
    case "$1" in
        --product-root)   PRODUCT_ROOT="${2:-}"; shift 2 ;;
        --product-root=*) PRODUCT_ROOT="${1#*=}"; shift ;;
        *) shift ;;
    esac
done

if [ -z "$PRODUCT_ROOT" ]; then
    echo "check-swap-residue: PRODUCT_ROOT not resolved -> UNRELIABLE" >&2
    exit 2
fi
if [ ! -d "$PRODUCT_ROOT" ]; then
    echo "check-swap-residue: product root '$PRODUCT_ROOT' absent -> UNRELIABLE" >&2
    exit 2
fi

# Collect files (exclude build trees)
mapfile -t files < <(find "$PRODUCT_ROOT" -type d -name build -prune -o -type f \( -name '*.c' -o -name '*.h' \) -print 2>/dev/null | sort)
if [ "${#files[@]}" -eq 0 ]; then
    echo "check-swap-residue: no matching TARGET files under '$PRODUCT_ROOT' - NOT APPLICABLE -> GREEN"
    exit 0
fi

# Run the Python detector - it handles comment/string stripping, multiline conditions,
# parenthesized literals, both operand orders, and #if (0) variants.
python3 - "${files[@]}" <<'PY'
import sys, re, os

files = sys.argv[1:]
violations = 0
scanned = len(files)

# Precompile regexes for stripped content
# After stripping, we search for neutralised conditions. We find 'if' or 'while' followed by
# balanced parens containing false/true with &&/||. For simplicity, we extract the condition
# text via balanced-paren scan rather than a single regex, to handle nested parens and multiline.
def strip_comments_and_strings(text):
    """Replace block comments, line comments, and string/char literals with spaces/newlines,
       preserving line breaks so line numbers stay correct."""
    res = []
    i = 0
    n = len(text)
    in_block = False
    in_line = False
    in_dq = False
    in_sq = False
    while i < n:
        c = text[i]
        nxt = text[i+1] if i+1 < n else ''
        if in_block:
            if c == '*' and nxt == '/':
                res.append('  ')
                i += 2
                in_block = False
            else:
                # preserve newlines, otherwise space
                if c == '\n':
                    res.append('\n')
                else:
                    res.append(' ')
                i += 1
            continue
        if in_line:
            if c == '\n':
                res.append('\n')
                in_line = False
                i += 1
            else:
                res.append(' ')
                i += 1
            continue
        if in_dq:
            if c == '\\' and nxt:
                res.append('  ')
                i += 2
            elif c == '"':
                res.append(' ')
                in_dq = False
                i += 1
            elif c == '\n':
                res.append('\n')
                i += 1
            else:
                if c == '\n':
                    res.append('\n')
                else:
                    res.append(' ')
                i += 1
            continue
        if in_sq:
            if c == '\\' and nxt:
                res.append('  ')
                i += 2
            elif c == "'":
                res.append(' ')
                in_sq = False
                i += 1
            else:
                if c == '\n':
                    res.append('\n')
                else:
                    res.append(' ')
                i += 1
            continue
        # not in any
        if c == '/' and nxt == '*':
            res.append('  ')
            in_block = True
            i += 2
        elif c == '/' and nxt == '/':
            res.append('  ')
            in_line = True
            i += 2
        elif c == '"':
            res.append(' ')
            in_dq = True
            i += 1
        elif c == "'":
            res.append(' ')
            in_sq = True
            i += 1
        else:
            res.append(c)
            i += 1
    return ''.join(res)

# dead guard: #if 0, #if (0), #if ( 0 ) with optional whitespace, whole line after stripping comments
# We check original lines for preprocessor form after stripping comments per line
dead_guard_re = re.compile(r'^\s*#\s*if\s*\(?\s*0\s*\)?\s*(//.*|/\*.*\*/\s*)?$')

# For neutralised condition, we scan stripped text for if/while keywords, then extract balanced condition
keyword_re = re.compile(r'\b(if|while)\b')

for f in files:
    try:
        raw = open(f, errors='replace').read()
    except Exception as e:
        print(f"[FAIL] {f}: cannot read ({e})", file=sys.stderr)
        violations += 1
        continue
    stripped = strip_comments_and_strings(raw)
    lines_raw = raw.splitlines()
    lines_stripped = stripped.splitlines()
    # Check dead guards line by line on stripped lines (so comments ignored)
    for idx, (orig, s) in enumerate(zip(lines_raw, lines_stripped), start=1):
        # Only preprocessor lines
        if re.match(r'^\s*#\s*if\b', s):
            # stripped line: check if it's an unconditional 0 guard
            # Use stripped line for matching (comments already removed)
            if re.match(r'^\s*#\s*if\s*\(?\s*0\s*\)?\s*$', s):
                rel = os.path.relpath(f, os.environ.get("PRODUCT_ROOT", ""))
                # fallback if rel fails
                try:
                    rel = os.path.relpath(f, sys.argv[0])  # not needed
                except:
                    pass
                # Use product-root relative for display
                pr = os.environ.get("PRODUCT_ROOT", "")
                disp = f[len(pr)+1:] if pr and f.startswith(pr) else f
                print(f"[FAIL] {disp}:{idx} dead guard (swap residue):{orig}")
                violations += 1
    # Check neutralised conditions by scanning stripped text
    # Find each keyword, then find '(' and balanced ')'
    for m in keyword_re.finditer(stripped):
        kw = m.group(1)
        pos = m.end()
        # skip whitespace to '('
        while pos < len(stripped) and stripped[pos] in ' \t\r\n':
            pos += 1
        if pos >= len(stripped) or stripped[pos] != '(':
            continue
        # Find matching ')'
        depth = 0
        start = pos
        end = -1
        for i in range(start, len(stripped)):
            if stripped[i] == '(':
                depth += 1
            elif stripped[i] == ')':
                depth -= 1
                if depth == 0:
                    end = i
                    break
        if end == -1:
            continue
        cond = stripped[start+1:end]  # inside parens
        # Normalize: cond contains no comments/strings now
        # Check for neutralised patterns, allowing optional parens around literal and whitespace/newlines
        # Patterns (case-sensitive for false/true):
        # false &&   or   && false
        # true ||    or   || true
        # Allow optional surrounding parens: (\( *false *\) *&&)  or  (&& *\( *false *\))
        # Use regex with DOTALL for multiline (cond may contain newlines)
        pat_false_left = re.search(r'\(\s*false\s*\)\s*&&|(?<!\w)false\s*&&', cond)
        pat_false_right = re.search(r'&&\s*\(\s*false\s*\)|&&\s*false\b', cond)
        pat_true_left = re.search(r'\(\s*true\s*\)\s*\|\||(?<!\w)true\s*\|\|', cond)
        pat_true_right = re.search(r'\|\|\s*\(\s*true\s*\)|\|\|\s*true\b', cond)
        if pat_false_left or pat_false_right or pat_true_left or pat_true_right:
            # Find line number of the keyword
            lineno = stripped[:m.start()].count('\n') + 1
            orig_line = lines_raw[lineno-1] if 0 <= lineno-1 < len(lines_raw) else ""
            pr = os.environ.get("PRODUCT_ROOT", "")
            disp = f[len(pr)+1:] if pr and f.startswith(pr) else f
            # Show original line (trimmed)
            print(f"[FAIL] {disp}:{lineno} neutralised condition (swap residue):{orig_line}")
            violations += 1

# The detector owns the summary: it is the only side holding the real counts. Printing it again
# from the shell wrapper duplicated the line and emitted an empty count, because the wrapper does
# not have `violations` - a garbled diagnostic in the one place a reader looks first.
print(f"check-swap-residue: scanned {scanned} file(s); {violations} residue site(s) -> "
      f"{'RED' if violations else 'GREEN'}")
if violations:
    print("  A swap-and-fail mutation appears to have been committed without restoring.")
    print("  Restore the condition; if the code is genuinely dead, delete it rather than guarding it.")
sys.exit(1 if violations else 0)
PY
rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]; then
    exit "$rc"
fi
echo "check-swap-residue: detector failed (exit $rc) -> UNRELIABLE" >&2
exit 2
