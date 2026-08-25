# Seeded-bug record - `check-swap-residue.sh`

A detector is trusted only once it has been SEEN to fail. This is the red-then-green
demonstration for `tools/conformance/check-swap-residue.sh`, covering residue forms
that the previous raw grep missed and the comment false-positive it produced.

## The failure class

`check-swap-residue.sh` catches an unrestored swap-and-fail mutation left in TARGET code:
a neutralised condition (`if (false && ...)`, `while (true || ...)`) or a dead
preprocessor guard (`#if 0`). The previous implementation was raw `grep -nE` on the
file text, so it both false-greened and false-redded.

## The defects this record documents

1. **False-green on parenthesized literal:** `if ((false) && x)` - extra parens around
   the literal hid it from `\(false &&`.
2. **False-green on RHS literal:** `if (x && false)` - literal on the right side of `&&`
   was not matched.
3. **False-green on multiline condition:** a condition split after `if (` onto the next
   line was not matched (grep sees one line at a time).
4. **False-green on `#if (0)`:** the dead-guard regex required `#if 0` without parens.
5. **False-red inside comments:** `/* example: if (false && x) */` produced RED because
   grep scanned comments and string literals.

## The fix

Replace raw line grep with a Python detector that:

- strips block comments (`/* */`), line comments (`//`), and string/char literals
  before scanning, preserving newlines so line numbers remain correct (so comment
  residue no longer false-REDs);
- extracts `if`/`while` conditions via balanced-paren scan (so multiline and
  parenthesized forms are seen);
- checks both operand orders for the short-circuit literal (`false &&` / `&& false`,
  `true ||` / `|| true`) allowing optional parentheses around the literal;
- matches dead guards as `^#if (0)` with optional parentheses and whitespace, after
  comment stripping.

Build trees (`*/build/*`) remain excluded.

## Demonstration

Each fixture under `fixtures/swap-residue/` exercises one form:

| Fixture | Content | Before (grep) | After (python) |
|---|---|---|---|
| `parenthesized.c` | `if ((false) && x)` | GREEN (missed) | RED |
| `rhs.c` | `if (x && false)` | GREEN (missed) | RED |
| `multiline.c` | `if (\n false && x)` | GREEN (missed) | RED |
| `if0_paren.c` | `#if (0)` | GREEN (missed) | RED |
| `comment.c` | `/* if (false && x) */` | RED (false positive) | GREEN |
| `clean.c` | `if (x && x)` | GREEN | GREEN |

Run:

```
# RED cases (each alone should be RED)
for f in fixtures/swap-residue/parenthesized.c fixtures/swap-residue/rhs.c fixtures/swap-residue/multiline.c fixtures/swap-residue/if0_paren.c; do
  tmp=$(mktemp -d); mkdir -p "$tmp/src"; cp "$f" "$tmp/src/a.c"
  PRODUCT_ROOT="$tmp" bash tools/conformance/check-swap-residue.sh; echo "$f: exit $?"
  rm -rf "$tmp"
done
# GREEN cases
tmp=$(mktemp -d); mkdir -p "$tmp/src"; cp fixtures/swap-residue/comment.c "$tmp/src/a.c"; cp fixtures/swap-residue/clean.c "$tmp/src/b.c"
PRODUCT_ROOT="$tmp" bash tools/conformance/check-swap-residue.sh; echo "comment+clean: exit $?"
rm -rf "$tmp"
```

Expected: the four residue fixtures each exit 1 RED, the comment+clean pair exits 0 GREEN.

Also verify the four headline outcomes still hold:

| Case | Expected |
|---|---|
| `if (false && x)` | RED 1 |
| ordinary clean C | GREEN 0 |
| no `.c`/`.h` | NOT APPLICABLE GREEN 0 |
| missing product root | UNRELIABLE 2 |
