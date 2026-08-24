#!/usr/bin/env python3
"""verify_anchors_ast.py - libclang-backed structural helper for verify-anchors.sh.

Two structural questions in the anchor verifier kept failing when answered by a
hand-rolled text tokenizer (review rounds 1-2, findings F-01/F-02/F-04/F-05/F-06):
"what declarations in this TARGET file provide a constant value" (coverage), and
"does this TARGET expression have the SAME operator/sign STRUCTURE as the SOURCE
literal-as-read text" (rendering fidelity). Both are genuinely structural questions
about C syntax - not textual ones - and every hand-rolled attempt to answer them with
regex/character scanning left an enumerable class of real C forms unhandled (unspaced
initializers, repeated unary operators, `==` in an initializer, multiline enums). This
script answers them with a real parser (libclang / clang.cindex) instead of extending
the same brittle approach a third time.

What stays textual, deliberately, in the caller (verify-anchors.sh) and is NOT
reimplemented here: the `/* src: ... */` anchor comment grammar (our own invented
convention, not C - a parser has no special knowledge of it), check1 (SOURCE path:line
existence, git-based), check2 (the SOURCE line contains the literal-as-read - Prime
Directive 3 is about the literal AS READ, so a raw textual substring check IS the
correct check, not an approximation of one), the RCONST dual-precision wrap-CORRECTNESS
verdict (kind classification from the project's DOUBLE_KINDS/SINGLE_KINDS/RCONST_KINDS
config - a project-specific policy table, not a C-syntax fact), and logical (.TRUE./
.FALSE.) rendering (a plain keyword substitution, not a structural question).

Review round 3 (reviewer commit 1e0ae98) approved the design (one C parser, textual
check1/check2, structural check3/check4) but found the IMPLEMENTATION unsound in three
ways that all trace back to the SAME root cause - trusting libclang's semantic AST
(node extents, direct-children-only traversal) for questions it does not reliably
answer once real project headers and real macros are involved:

  F-08: `RCONST(x)` is a PREPROCESSOR MACRO (defined by the project's conventions),
  not a function. Once its real definition is resolvable (as it always will be for
  real TARGET code, never in this tool's own prior test fixtures - the actual bug),
  libclang EXPANDS it before building the AST: the expanded literal's `cursor.extent`
  collapses to a ZERO-WIDTH point at the invocation site (verified empirically this
  round), not a span covering its expanded text, and the surrounding declaration's own
  extent stops short of the value entirely. Reading leaf/operator text from those
  extents (the round-3 design) is unsound the moment a real macro resolves. FIX: the
  structural walk never trusts a REAL file's post-macro-expansion extents. It extracts
  the value expression as RAW TEXT (via the declaration's NAME anchoring a `NAME\\s*=`
  search on its own source line - never through the semantic AST for this part) and
  re-parses THAT TEXT in total isolation (no `#include`, exactly like the SOURCE side
  already did) - so `RCONST(...)` is GUARANTEED to still be an unresolved, structurally
  visible call in the fragment this tool actually walks, regardless of what the real
  file's own includes resolve to.

  F-09: `cmd_decls` walked only `tu.cursor.get_children()` - DIRECT translation-unit
  children - so a function-LOCAL `static const` (nested inside a FunctionDecl's
  CompoundStmt; target-conventions T6 requires exactly this rendering for an
  initialized local) was invisible. Separately, no diagnostic on the REAL file's parse
  was ever inspected, so a genuine syntax error that swallows later declarations (an
  unterminated block comment, demonstrated this round) produced a confidently-empty,
  exit-0 "GREEN" - indistinguishable from a file that truly declares nothing. FIX: a
  recursive walk visits every descendant, and every diagnostic is classified - ONLY a
  `file not found`-shaped preprocessor diagnostic (this tool's own, disclosed,
  unavoidable limitation: it never resolves a project's own headers) is tolerated;
  anything else is UNRELIABLE, verified against a real hole this round (the
  unterminated-comment reproduction) that the OLD "tolerate everything" policy missed
  and the NEW policy catches.

  F-10: coverage/anchor-grammar state was keyed by LINE NUMBER alone
  (`DECL_KIND_AT[lineno]`), so a second declaration sharing a line silently OVERWROTE
  the first's tracking, and one valid anchor on that line certified BOTH - a citation
  for one constant standing in for an unrelated one (a direct B2 instance). FIX:
  `decls` now reports, and the driver now tracks, whether MULTIPLE constant-providing
  declarations share one physical line, and treats that as its own explicit,
  always-a-violation state (the anchor grammar embeds exactly ONE literal-as-read; it
  cannot soundly cover two) - never silently resolved by whichever anchor happens to
  be present. `structcmp` independently refuses (Unsupported) the same ambiguity if it
  is ever reached anyway, defense in depth.

Review round 4 (reviewer commit aa55f760) judged this "directionally correct, but the
boundary remains unsound": moving VALUE extraction off the semantic AST (F-08) was
right, but the round-4 IMPLEMENTATION of that idea - a `NAME` + regex search on one
physical line - was itself unsound, and isolating the RE-PARSE (deliberately never
resolving the real macro) answered a narrower question than the ENFORCEMENT row
claimed. Three findings, one per unsound edge:

  F-11: `_has_raw_assignment`/`_raw_value_text` (round 4's fix) matched only `NAME`
  immediately followed by (only whitespace, then) `=` on its OWN physical line - a
  comment, an `__attribute__(...)`, or a line break between the name and `=` all defeat
  it, and a macro-GENERATED declaration's own physical line does not contain `NAME =`
  as text AT ALL (it contains the macro INVOCATION). An unanchored declaration in any
  of these shapes was invisible to coverage - a direct false GREEN, reproduced and
  confirmed this round. FIX: existence ("has an initializer") reverts to the semantic
  AST's own child list (`_has_initializer`) - safe again once F-12 (below) guarantees a
  clean parse; VALUE extraction (still never through a real file's post-macro-expansion
  extents - F-08's principle stands) becomes a TOKEN-STREAM walk
  (`_extract_initializer_tokens`) anchored at the declarator's own NAME location,
  tracking paren/bracket nesting so a comment or attribute in between is walked
  straight through - comments and attributes no longer defeat it, and a macro-generated
  declaration (whose invocation tokens contain no visible `=`) is now Unsupported for
  its OWN structural check specifically, rather than invisible to coverage entirely.

  F-12: `_diagnostics_are_tolerable` (round 4's fix) blanket-tolerated ANY diagnostic
  whose spelling contained "file not found" - but round 4's `_parse_tu` never passed
  `-resource-dir`/`-I` at all, so even a REAL, present, resolvable system header
  (`<stdbool.h>`, confirmed empirically THIS round to exist and work once told where to
  look) reported "file not found" for no reason but that omission. Tolerating it meant
  a genuinely missing header - which could contain any number of its own constant-
  providing declarations this tool would then have no way to see - was ALSO silently
  waved through: "tolerated" was never "proven harmless". FIX: `_parse_tu` now resolves
  the compiler's own resource directory (`_resource_dir`, `clang -print-resource-dir`,
  a genuinely new but disclosed dependency - `cmd_resource_dir` is a startup preflight,
  checked once, exit 2 if undiscoverable) and real project `-I` directories
  (`_include_dirs`, from `VERIFY_ANCHORS_INCLUDE_DIRS`) - so a file whose OWN headers
  are ALL genuinely present parses with ZERO diagnostics. `_diagnostics_are_clean`
  (renamed) then tolerates NOTHING: ANY diagnostic, of any shape, makes the declaration
  scan untrusted. Coverage is not "verifiable only given a complete SCAN" - it is
  verifiable FILE BY FILE, and UNRELIABLE (never a silent zero) for any one file whose
  OWN parse is not completely clean, exactly the existing three-state discipline
  applied consistently rather than exempted for one diagnostic shape.

  F-13: isolated re-parsing (F-08) deliberately treats `macro_name(...)` as an OPAQUE,
  never-expanded call, by design - proven sound for INVOCATION structure (does the
  TARGET spell the call correctly), but SILENT on whether the REAL macro (wherever it
  is actually defined) implements the pinned dual-precision contract at all. A
  deliberately wrong real definition (confirmed this round: a mutated `real_precision.h`
  whose dp branch adds `1.0`) still produced GREEN under the round-4 architecture - the
  isolated check has no way to notice, by construction. FIX: a SEPARATE, NEW check
  (`cmd_rconst_contract`) parses the REAL file's own text (not isolated - the opposite
  concern from F-08) with a `_Static_assert`/`_Generic` probe appended, asking the C
  COMPILER's own constant-expression evaluator to confirm both the exact result TYPE
  (`double` in the dp regime, `float` in the sp regime - `VERIFY_ANCHORS_RCONST_DP_DEFINE`
  names the switch) and VALUE-preservation, in BOTH regimes independently - never
  libclang's own Cursor extent/token reading, which is unsound for this the same way
  F-08 already showed it unsound for VALUE text. Wired in once per file, memoized, the
  first time `structcmp` confirms a wrapped leaf for it.

Review round 5 (reviewer commit `f93928bbc10cb92567ef974379d3baa38b808409`,
`docs/evidence/phase1/anchor-verifier/review.md`) confirmed F-08/F-09/F-10/F-11/F-12
resolved and the TARGET-side denominator decision correct, but found the round-5
implementation of F-12/F-13 still incomplete in two ways - not new instance-fixes,
but genuine remaining scope:

  F-14: `decls`/`structcmp` parse a TARGET file under exactly ONE preprocessor regime
  (no `-D<dp-define>` at all). A declaration that exists ONLY under the OTHER pinned
  regime (`#ifdef <dp-define>` / `#ifndef <dp-define>` / `#if defined(<dp-define>)`)
  is textually ABSENT from what the preprocessor hands this tool's one parse - not
  merely unresolved, invisible - so an unanchored constant guarded that way returned
  a confidently-complete GREEN. Exhaustive dual-regime coverage (parsing both
  regimes, unioning declarations by stable location) is real, tractable work, but it
  is work this unit cannot PROVE sound yet: no real translated C exists to
  demonstrate it against, so building it now means hardening against a guessed
  shape of Phase 2's own output - the exact unfalsifiable-guessing pattern five
  review rounds kept reproducing.

  F-15: `cmd_rconst_contract`'s `_Static_assert`/`_Generic` probe samples the real
  macro's behavior at exactly ONE argument (`2.0`). A macro that special-cases that
  value, or ignores its argument entirely and always returns the expected constant,
  passes the sample while corrupting every OTHER invocation. PROVING the contract
  (comparing/generating the macro's actual token-paste/identity DEFINITION directly
  - a finite, syntactic fact, the reviewer's own recommended remediation) is more
  thorough than sampling semantics, but is likewise deferred: there is exactly one
  real macro definition in this repository today (this unit's own test fixtures),
  and a general "compare against the canonical definition" check needs a canonical
  definition to compare against - Phase 2 territory.

**Human decision (charter `port/plan/00-charter.md` section 6, placeholder P-002,
2026-08-24): both are EXPLICITLY DEFERRED to Phase 2, not attempted further this
round.** Five review rounds converged on a genuine, structural insight: this unit was
verifying a property of TARGET C code that does not exist yet, so every round
hardened against constructs nobody had written. What ships now is the SOURCE-proven
scope - proven against real artifacts, not guesses: the SOURCE-side literal-as-read
comparison, the git/anchor-existence checks, the `-resource-dir` parse fix and
zero-diagnostics-tolerated posture, the fail-closed subprocess discipline, and the
`rconst-contract` probe honestly labelled as a probe (never a proof). **Narrowing the
CLAIM must never widen the SILENCE**: a declaration form outside the shipped scope
(a dp/sp-regime conditional - F-14) is refused (UNRELIABLE, `_dp_conditional_
directive`), never silently treated as fully covered by the one regime this tool
actually parses - the reviewer's own exact falsifier now returns UNRELIABLE, not
GREEN. See `docs/evidence/phase1/anchor-verifier/non_vacuity.md` section 15 and
`source_demo.md` section 0.3 for the full scope statement and reasoning.

Independent re-review after the P-002 narrowing (reviewer commit
`2484a322110fcf58b5605a25083e0fe670bcb880`) accepted the narrowed design itself ("the
narrowed design is acceptable") but found the F-14 non-silence guard's OWN boundary
incomplete:

  F-16: `_dp_conditional_directive`'s original implementation matched the dp-define
  token against ONE PHYSICAL LINE at a time (`^[ \\t]*#[ \\t]*(if|ifdef|ifndef|elif)
  \\b.*\\b<dp-define>\\b`, applied per raw source line). Real C does not work that
  way: translation phase 2 (backslash-newline splicing) applies to EVERY physical
  line BEFORE phase 3 tokenization, including before the `#` that makes a line a
  directive at all - so `#if defined` followed by a line-continuation backslash, a
  newline, and `(USE_DOUBLE)` is, to any real
  compiler, the SAME single logical directive as `#if defined(USE_DOUBLE)`, but was
  INVISIBLE to a scan that only ever looked at one physical line - the exact
  falsifier the reviewer demonstrated, GREEN where it must have been UNRELIABLE.
  This is the SAME class of hole the SIBLING `conformance-c-rendering` unit hit and
  was sent back THREE consecutive independent-review rounds on (a mid-keyword
  splice, then leading whitespace/comments before the `#`, each a "spelling I did
  not anticipate" the previous hand-rolled fix missed) before it stopped patching
  and delegated to clang's own raw lexer entirely. FIX: this round REUSES that
  already-proven solution rather than re-deriving or hand-patching a fourth
  splice/comment/whitespace shape - `scan_guarded_macros.py` (vendored verbatim,
  see its own module docstring for the full provenance and hardening history) is
  imported directly and `_dp_conditional_directive` now delegates to its `scan()`:
  clang's `-Xclang -dump-raw-tokens` raw lexer performs backslash-newline splicing
  as part of ordinary tokenization (phase 2, before this tool ever sees a token),
  and `scan_guarded_macros.py`'s own logical-line grouping (`_spans()`, keyed off
  clang's own `StartOfLine` flag) asks the C standard's own question of each
  logical line - is its first non-blank, non-comment token a `#`? - rather than
  approximating it with a per-physical-line regex. A scan that cannot even RUN
  (`RuntimeError` from `scan_guarded_macros.scan`) is ALSO treated as a guard
  trigger (UNRELIABLE), never silently treated as "no conditional present" -
  the bar's own explicit requirement: "if the scan itself cannot run, that is
  UNRELIABLE, never green".

Subcommands (each is a single, checked entry point - see verify-anchors.sh's `_run_ast`
wrapper, which captures stdout/stderr and checks the exit code for EVERY invocation,
closing review round 2's F-07 - there is exactly ONE python invocation point to check):

  decls <c-file>
      Emit one TSV row per constant-PROVIDING declaration found ANYWHERE in the file
      (a real, RECURSIVE parse - top-level, function-local, nested in any scope):
        DECL\t<line>\t<KIND>\t<name>\t<ambiguous:0-or-1>
      KIND is VAR (a const-or-static-qualified variable with an initializer, at ANY
      scope), ENUM (an enumerator with an explicit value), or DEFINE (an object-like
      macro carrying a value - a function-like macro is excluded, it is code, not a
      constant). `ambiguous` is 1 when two or more constant-providing declarations
      share this declaration's physical line (F-10) - the caller must treat every row
      with `ambiguous=1` as its own violation, never as ordinary coverage. Exit 0 on
      success (including zero rows - a file with no constant-providing declarations,
      confirmed by a complete parse, is a legitimate, fully-determined answer). Exit 2
      when the tool itself could not run, OR when the parse is not COMPLETELY clean
      (round 5, F-12 - real headers are now actually resolved, `-resource-dir`/`-I`,
      so no diagnostic shape is tolerated any more): never a confident zero over a
      parse that may have silently dropped declarations.

  structcmp <c-file> <line> <literal-text> <macro-name>
      Structurally compare <literal-text> (the anchor's SOURCE literal-as-read, kind
      suffixes such as `_JWRB` stripped before parsing - textual notation cleanup, not
      a structural decision) against the TARGET value expression at <line> in
      <c-file> - independently RE-FOUND (never trusting a caller-supplied kind; a
      missing or AMBIGUOUS (F-10) declaration at <line> is itself a reported
      Unsupported) and extracted as RAW TEXT via a TOKEN-STREAM walk anchored at the
      declaration's own NAME location (F-08/F-11 - never via the real file's own
      post-macro-expansion AST extents, and never a name+`=` regex on one physical
      line either), then re-parsed in the SAME total isolation the SOURCE side already
      used. <macro-name> calls in the TARGET fragment (e.g. `RCONST(x)`) are
      transparently unwrapped to their single argument - the macro's own value-
      preservation is a project rendering DECISION verified separately by the caller
      (see `rconst-contract` below for the real macro's own CONTRACT, a different
      question), not a structural fact this comparison should trip on. On a clean
      structural match (same operator at each tree position, same arity, same nesting)
      prints one TSV row per LEAF numeral, in left-to-right order:
        LEAF\t<source-leaf-text>\t<target-leaf-text>\t<0-or-1: was inside macro-name(...)>
      and exits 0 - the caller applies its OWN numeric-equivalence and RCONST-wrap-
      correctness rules per leaf (project policy, not a C-syntax fact). On a clean
      structural MISMATCH (both sides parsed, genuinely differ) prints exactly one row
      `MISMATCH\t<reason>` and exits 0 (a deterministic finding - the caller reports
      RED). On anything this tool cannot confidently parse or resolve (a construct
      outside the supported subset, an unresolvable or ambiguous declaration at
      <line>, a parse diagnostic on either fragment) exits 2 with the reason on
      stderr and NOTHING on stdout - the caller reports UNRELIABLE, never silently
      falls back to a weaker check.

  rconst-contract <c-file> <macro-name> <dp-define>
      Round 5, F-13 (scope corrected round 6, charter P-002/F-15): SAMPLE - never
      "verify", never "prove" - whether <macro-name> as REALLY defined and reachable
      from <c-file> (never isolated - the opposite concern from `structcmp` above)
      implements the pinned dual-precision contract AT ONE representative argument
      (`2.0`), in BOTH regimes (identity/`double` result with <dp-define> defined,
      `x##f`-style/`float` result without it), via a `_Static_assert`/`_Generic`
      probe appended to the file's own real text and evaluated by the C compiler's
      own constant-expression evaluator - never libclang's own Cursor extent/token
      reading, unsound for this the same way F-08 showed it unsound for VALUE text.
      This is a SAMPLE: a macro that special-cases the sampled value, or ignores its
      argument entirely and always returns the expected constant, passes while
      corrupting every OTHER invocation - proving the contract for every argument is
      DEFERRED to Phase 2 (`_rconst_probe_diagnostics`'s own docstring has the full
      reasoning). Prints `CONTRACT-SAMPLE-OK\t<macro-name>` and exits 0 if the sample
      holds in both regimes; exits 2 with the reason (the compiler's own diagnostic,
      e.g. a failed `_Static_assert`, or the macro simply not being reachable/
      defined from this file at all) on stderr and nothing on stdout otherwise - the
      caller reports UNRELIABLE, never GREEN on an unsampled or failed contract.

  resource-dir
      Startup preflight (verify-anchors.sh calls this ONCE, before trusting any
      per-file result): prints the discovered C compiler resource directory and
      exits 0, or exits 2 if it could not be discovered (round 5, F-12's own
      dependency - a broken/absent compiler toolchain is a whole-run failure, never
      a silent per-file degradation).

Exit-code contract for all FOUR subcommands: 0 success (including a data-carrying
MISMATCH row for structcmp - still 0, the TOOL did not fail), 2 the tool could not
answer the question (bad arguments, libclang unavailable, unsupported construct,
an uncertain/incomplete parse, declaration not found or ambiguous) - never any other
code, so the caller's check is a single `$? -eq 0` test.
"""
import os
import re
import subprocess
import sys

# Vendored sibling library (review round 6, F-16 - see this module's own "Review round 6"
# section above for the full reasoning): `scan_guarded_macros.py` lives beside this file
# (both under `tools/conformance/lib/`), so Python's own "the directory of the script being
# run is sys.path[0]" behavior resolves this import with no extra path manipulation, exactly
# like `verify_anchors_ast.py` itself is always invoked (an absolute path, `_run_ast` in
# verify-anchors.sh) - confirmed empirically this round.
import scan_guarded_macros

try:
    import clang.cindex as ci
except Exception as exc:  # pragma: no cover - exercised by the "no libclang" probe
    sys.stderr.write(f"verify_anchors_ast: clang.cindex is not importable: {exc}\n")
    sys.exit(2)

_KIND_SUFFIX_RE = re.compile(r"(?<=[0-9])_[A-Za-z][A-Za-z0-9]*")
_DEFINE_VALUE_RE = re.compile(
    r"^[ \t]*#[ \t]*define[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+(?P<val>\S.*)$"
)
_DEFINE_FUNCLIKE_RE = re.compile(r"^[ \t]*#[ \t]*define[ \t]+[A-Za-z_][A-Za-z0-9_]*\(")

# Node kinds this tool understands as "structural" (operators) vs. leaves (numerals).
# Deliberately narrow (review's own endorsed floor: "acceptable ... if every expression
# outside the parser's proven subset became UNRELIABLE" - restated here for the AST
# path). Anything else met while walking is reported as UNRELIABLE, never guessed at.
_BINARY_KINDS = (ci.CursorKind.BINARY_OPERATOR,)
_UNARY_KINDS = (ci.CursorKind.UNARY_OPERATOR,)
_LITERAL_KINDS = (ci.CursorKind.FLOATING_LITERAL, ci.CursorKind.INTEGER_LITERAL)
_TRANSPARENT_KINDS = (
    ci.CursorKind.UNEXPOSED_EXPR,
    ci.CursorKind.PAREN_EXPR,
)


def _strip_kind_suffixes(text):
    """Remove a Fortran kind suffix (`_JWRB`, `_JWRU`, ...) immediately following a
    digit - narrow textual notation cleanup (never a structural decision) so the
    residual arithmetic (numbers, `+ - * /`, parens) parses as the C it already is."""
    return _KIND_SUFFIX_RE.sub("", text)


def _read_text(path):
    with open(path, "rb") as f:
        return f.read()


def _extent_text(source_bytes, cursor):
    return source_bytes[cursor.extent.start.offset : cursor.extent.end.offset].decode(
        "utf-8", "replace"
    )


def _make_index():
    return ci.Index.create()


_RESOURCE_DIR = None
_RESOURCE_DIR_PROBED = False


def _resource_dir():
    """The C compiler's OWN resource directory (where `stdbool.h`/`stddef.h`/... -
    the "freestanding" headers a hosted C toolchain ships alongside itself, distinct
    from the OS's libc headers - actually live), memoized per PROCESS. libclang's
    `Index.parse` does NOT add this path automatically (confirmed empirically this
    round: a real `#include <stdbool.h>`/`<stdint.h>` reports "file not found"
    without it, on a system that genuinely HAS a working `stdbool.h` sitting right
    there, unused, only because this tool never told the parser where to look) - so
    without it, EVERY real TARGET file using an ordinary standard header would
    misreport a missing dependency as a content problem.

    Checks `VERIFY_ANCHORS_RESOURCE_DIR` FIRST: verify-anchors.sh's own startup
    preflight already runs `cmd_resource_dir` once (via a dedicated `python3`
    invocation) and exports its result for every SUBSEQUENT `decls`/`structcmp`/
    `rconst-contract` call to reuse - each of those is its OWN fresh process (no
    module-level memoization survives across CLI invocations), so without this,
    `clang -print-resource-dir` would otherwise re-run as an extra subprocess spawn
    on EVERY single call. Falls back to discovering it directly (`clang
    -print-resource-dir`) when the env var is unset - e.g. when this module is used
    standalone/interactively, as every seeded-bug/source-demo probe this round did.
    Returns None if neither source succeeds - the caller (the startup preflight,
    `cmd_resource_dir`, or a `_parse_tu` call proceeding without it) treats that as
    a hard, disclosed dependency failure, never a silent per-file degradation."""
    global _RESOURCE_DIR, _RESOURCE_DIR_PROBED
    if _RESOURCE_DIR_PROBED:
        return _RESOURCE_DIR
    _RESOURCE_DIR_PROBED = True
    from_env = os.environ.get("VERIFY_ANCHORS_RESOURCE_DIR", "")
    if from_env and os.path.isdir(from_env):
        _RESOURCE_DIR = from_env
        return _RESOURCE_DIR
    try:
        out = subprocess.run(
            ["clang", "-print-resource-dir"],
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
        candidate = out.stdout.strip()
        if candidate and os.path.isdir(candidate):
            _RESOURCE_DIR = candidate
    except Exception:
        _RESOURCE_DIR = None
    return _RESOURCE_DIR


def _include_dirs():
    """Extra `-I` directories a real TARGET file's own project-internal headers may
    need beyond the quote-include-relative-to-the-file default (e.g. a header
    referenced by a project-root-relative path from a nested file). Sourced from
    `VERIFY_ANCHORS_INCLUDE_DIRS` (colon-separated), set per invocation by
    verify-anchors.sh - never hardcoded here, since this is a base/methodology-layer
    file with no knowledge of any one project's directory layout."""
    raw = os.environ.get("VERIFY_ANCHORS_INCLUDE_DIRS", "")
    return [d for d in raw.split(os.pathsep) if d]


def _parse_tu(index, path, extra_args=()):
    """Parse PATH for real: resolves the compiler's OWN standard headers
    (`_resource_dir`) and any project `-I` directories (`_include_dirs`) - F-12's
    fix. A real, complete parse environment is the PRECONDITION for trusting
    anything about this file's declarations at all; see `_diagnostics_are_clean`,
    which no longer tolerates ANY diagnostic once given this fair a chance to
    resolve everything real."""
    args = ["-std=c17"]
    rd = _resource_dir()
    if rd:
        args.append(f"-resource-dir={rd}")
    for d in _include_dirs():
        args.append(f"-I{d}")
    args.extend(extra_args)
    return index.parse(
        path,
        args=args,
        options=ci.TranslationUnit.PARSE_DETAILED_PROCESSING_RECORD,
    )


def cmd_resource_dir():
    """Startup preflight subcommand (verify-anchors.sh calls this ONCE, alongside
    the `import clang.cindex` probe, before trusting any per-file result): prints
    the discovered resource directory and exits 0, or prints nothing and exits 2 if
    `clang -print-resource-dir` is unavailable/fails - a genuinely broken/absent
    compiler toolchain is a whole-run dependency failure, not something any
    individual file's diagnostics-clean check should have to rediscover and
    silently degrade around one file at a time."""
    rd = _resource_dir()
    if rd is None:
        sys.stderr.write(
            "verify_anchors_ast: could not discover the C compiler's resource "
            "directory ('clang -print-resource-dir' failed or clang is not on "
            "PATH) - standard headers (<stdbool.h>, <stdint.h>, ...) would not "
            "resolve, making every real TARGET file's structural/coverage checks "
            "UNRELIABLE; refusing to proceed file-by-file with a degraded parse\n"
        )
        return 2
    print(rd)
    return 0


# ---- diagnostics classification (F-09; tightened round 5, F-12) ------------------
def _diagnostics_are_clean(tu):
    """Classify every diagnostic on a REAL file's parse. Review round 4 (F-12) found
    the round-4 policy here - tolerate any diagnostic whose spelling contains "file
    not found" - unsound for a COVERAGE claim: a missing header could itself contain
    any number of constant-providing declarations this tool then has no way to see,
    so "tolerated" was never actually "proven harmless", just "not looked at
    closely". That policy existed because this tool never gave the real parser a
    fair chance to resolve real headers in the first place (`_parse_tu` passed no
    `-resource-dir`/`-I` at all) - confirmed empirically this round: a real,
    unmodified `<stdbool.h>`/`<stdint.h>` that GENUINELY exists on this system
    reported "file not found" purely because this tool never told the parser where
    to look, not because the header was truly unresolvable. Now that `_parse_tu`
    resolves the compiler's own resource directory AND real project `-I` paths, a
    file whose OWN headers are ALL genuinely present resolves with ZERO diagnostics
    - so there is no longer any diagnostic shape this tool has a principled reason
    to special-case: ANY diagnostic at Error severity or above - a genuinely missing
    header (project-internal or external), a real parse error, an unterminated
    comment - now means the declaration scan cannot be trusted, full stop. Returns
    (True, None) if the parse is completely clean, else (False, <first intolerable
    diagnostic's spelling>)."""
    for d in tu.diagnostics:
        if d.severity < ci.Diagnostic.Error:
            continue
        return False, d.spelling
    return True, None


# ---- decls --------------------------------------------------------------------
def _has_initializer(node):
    """Whether NODE (a VarDecl or EnumConstantDecl) has an initializer/explicit-value
    child - decided from the semantic AST's OWN child list (any child that is not a
    bare TYPE_REF). Round 4 decided this from RAW TEXT instead (a `NAME` followed by
    `=` on its own physical line), specifically because a missing `#include` used to
    leave a real initializer's AST children EMPTY while the file's only diagnostic
    (the missing-include one) was blanket-tolerated - trusting "the AST shows no
    child" was unsound while ANY diagnostic could be silently waved through. Review
    round 4 (F-12) closed that at its ROOT instead: `_parse_tu` now resolves real
    headers and `_diagnostics_are_clean` tolerates NOTHING, so by the time this
    function runs, the file's parse is GUARANTEED complete - the AST's own child
    list is trustworthy again, and it is also the semantically CORRECT test (unlike
    a name+`=` regex, it does not care whether a comment, an `__attribute__(...)`,
    or a line break sits between the name and the value - review round 4's F-11)."""
    return any(c.kind != ci.CursorKind.TYPE_REF for c in node.get_children())


def _collect_declarations(cursor, path, out):
    """Recursively visit EVERY descendant (F-09 - not just direct translation-unit
    children) so a function-LOCAL `static const` (nested inside a FunctionDecl's
    CompoundStmt - target-conventions T6's rendering for an initialized local) is
    found exactly like a file-scope one. Appends (line, column, KIND, name, cursor)
    tuples to OUT; column is carried so the caller can order/disambiguate multiple
    declarations that land on the same physical line (F-10); cursor (the VAR_DECL/
    ENUM_CONSTANT_DECL itself, or None for DEFINE) is carried so a caller that needs
    this declaration's VALUE (`_extract_initializer_tokens`, round 5's F-11 fix) can
    anchor a token-stream search at the declarator's own NAME location without a
    second parse."""
    for node in cursor.get_children():
        if node.location.file and node.location.file.name == path:
            if node.kind == ci.CursorKind.VAR_DECL:
                is_const = node.type.is_const_qualified()
                is_static = node.storage_class == ci.StorageClass.STATIC
                if (is_const or is_static) and _has_initializer(node):
                    out.append((node.location.line, node.location.column, "VAR", node.spelling, node))
            elif node.kind == ci.CursorKind.ENUM_DECL:
                for enumerator in node.get_children():
                    if enumerator.kind != ci.CursorKind.ENUM_CONSTANT_DECL:
                        continue
                    # Only an enumerator with an EXPLICIT value carries a literal worth
                    # anchoring; an implicit (`A, B, C`) enumerator has no SOURCE
                    # literal to check provenance against and is out of this check's
                    # scope.
                    if _has_initializer(enumerator):
                        out.append((enumerator.location.line, enumerator.location.column, "ENUM", enumerator.spelling, enumerator))
            elif node.kind == ci.CursorKind.MACRO_DEFINITION:
                line_text = _line_text(path, node.location.line)
                if line_text is not None and not _DEFINE_FUNCLIKE_RE.match(line_text) and _DEFINE_VALUE_RE.match(line_text):
                    out.append((node.location.line, node.location.column, "DEFINE", node.spelling, None))
        # Recurse regardless of whether this node itself matched: a FUNCTION_DECL's
        # CompoundStmt is exactly where a function-local declaration lives, and this
        # is a bounded AST walk, never a risk of runaway recursion.
        _collect_declarations(node, path, out)


def _dp_conditional_directive(path):
    """Charter P-002 (human decision, 2026-08-24 - NARROW; review round 5, F-14): this
    tool parses a TARGET file under exactly ONE preprocessor regime (no `-D<dp-define>`
    at all - the "sp" side of the pinned build matrix). A declaration that exists ONLY
    under the OTHER pinned regime (guarded by `#ifdef <dp-define>` / `#ifndef
    <dp-define>` / `#if defined(<dp-define>)` / an `#elif` naming it) is INVISIBLE to
    this parse - not merely unresolved, textually absent from what the preprocessor
    even hands the parser - so `decls` cannot enumerate it, cannot flag it missing an
    anchor, and would otherwise report a confident, silently-INCOMPLETE zero (the
    review's own exact reproduction: an `#ifdef USE_DOUBLE`-guarded unanchored constant
    returned GREEN). Exhaustive dual-regime coverage is EXPLICITLY DEFERRED to Phase 2
    (charter `port/plan/00-charter.md` section 6, P-002) - real translated C does not
    exist yet to prove it against, so building it now would be hardening against a
    guess, not a demonstrated construct (the exact unfalsifiable-guessing pattern this
    unit's prior five review rounds kept reproducing). What is NOT deferred is silence:
    a file containing such a conditional must never be silently treated as fully
    covered by the one regime this tool actually sees.

    Review round 6, F-16: this used to be a per-PHYSICAL-LINE regex - unsound, because
    C's own translation phase 2 (backslash-newline splicing) runs on every physical
    line BEFORE phase 3 tokenization, including before the `#` that makes a line a
    directive at all, so `#if defined` followed by a line-continuation backslash, a
    newline, and `(USE_DOUBLE)` is ONE logical directive to any real compiler but was
    invisible to a scan that only ever looked at one physical line at a time - proven
    by the reviewer's own falsifier,
    GREEN where it needed to be UNRELIABLE. FIX: delegate entirely to
    `scan_guarded_macros.scan` (vendored from the sibling `conformance-c-rendering`
    unit, which was sent back three consecutive review rounds on hand-rolled splice
    handling before adopting this - see that module's own docstring for the full
    history) - clang's OWN raw lexer performs the splicing as ordinary tokenization,
    so no line-oriented reasoning of any kind remains in this function.

    Returns a description of the FIRST offending directive/reason found, or None if
    the DP-define is not configured (RCONST-awareness off) or no such conditional is
    present AND the scan itself completed cleanly. A scan that cannot even run (a
    `RuntimeError` from `scan_guarded_macros.scan` - clang unavailable, or its raw-
    token output does not match the expected shape) is ALSO treated as a trigger
    (returns a description, never None) - the bar's own requirement: if the scan
    itself cannot run, that is UNRELIABLE, never green."""
    dp_define = os.environ.get("VERIFY_ANCHORS_RCONST_DP_DEFINE", "")
    if not dp_define:
        return None
    try:
        _total, records = scan_guarded_macros.scan(path, [dp_define])
    except RuntimeError as exc:
        return (
            f"the dp/sp-regime conditional scan itself could not run ({exc}) - "
            f"cannot confirm this file has no conditional on the configured dp-define"
        )
    for tag, line, msg in records:
        if tag == "FAIL":
            return f"line {line}: {msg}"
        if tag == "UNRESOLVED":
            return (
                f"line {line}: a preprocessor directive could not be classified "
                f"({msg}) - cannot confirm this file has no conditional on the "
                f"configured dp-define"
            )
    return None


def cmd_decls(path):
    dp_line = _dp_conditional_directive(path)
    if dp_line is not None:
        sys.stderr.write(
            f"verify_anchors_ast: decls: '{path}' contains a preprocessor conditional "
            f"on the dp/sp regime switch ({dp_line!r}) - this tool parses only ONE "
            f"pinned regime (F-14), so a declaration guarded the OTHER way would be "
            f"invisible here; exhaustive dual-regime coverage is DEFERRED to Phase 2 "
            f"(charter P-002) - this file's declaration coverage is out of the shipped "
            f"scope, never silently assumed complete\n"
        )
        return 2

    index = _make_index()
    try:
        tu = _parse_tu(index, path)
    except Exception as exc:
        sys.stderr.write(f"verify_anchors_ast: decls: could not parse '{path}': {exc}\n")
        return 2

    ok, reason = _diagnostics_are_clean(tu)
    if not ok:
        sys.stderr.write(
            f"verify_anchors_ast: decls: '{path}' did not parse completely cleanly "
            f"({reason!r}) even with real headers resolved (F-12: a missing or "
            f"broken header - project-internal or external - could itself contain "
            f"any number of constant-providing declarations this tool would then "
            f"have no way to see) - the declaration scan cannot be trusted\n"
        )
        return 2

    rows = []
    _collect_declarations(tu.cursor, path, rows)
    rows.sort(key=lambda r: (r[0], r[1]))

    count_at_line = {}
    for line, _col, _kind, _name, _cursor in rows:
        count_at_line[line] = count_at_line.get(line, 0) + 1

    for line, _col, kind, name, _cursor in rows:
        ambiguous = 1 if count_at_line[line] > 1 else 0
        print(f"DECL\t{line}\t{kind}\t{name}\t{ambiguous}")
    return 0


_LINE_CACHE = {}


def _line_text(path, lineno):
    """The raw text of physical line LINENO (1-indexed) of PATH, cached per path.
    Used both for the `#define` value regex (unchanged from round 3) and, per F-08,
    for extracting a VAR/ENUM declaration's value expression as RAW TEXT rather than
    through the real file's own (macro-expansion-collapsed) semantic AST extents."""
    lines = _LINE_CACHE.get(path)
    if lines is None:
        try:
            lines = _read_text(path).decode("utf-8", "replace").split("\n")
        except OSError:
            return None
        _LINE_CACHE[path] = lines
    if 1 <= lineno <= len(lines):
        return lines[lineno - 1]
    return None


# ---- structural walk ------------------------------------------------------------
class Unsupported(Exception):
    pass


def _unwrap_transparent(cursor):
    while True:
        children = list(cursor.get_children())
        if cursor.kind in _TRANSPARENT_KINDS and len(children) == 1:
            cursor = children[0]
            continue
        return cursor


def _operator_spelling(cursor, source_bytes):
    """The operator token of a Unary/BinaryOperator cursor - clang.cindex does not
    expose it directly, so read it from source: for a unary op it is the text
    immediately before its single operand's extent; for a binary op it is the text
    strictly between the left and right operand extents. Uses the RAW (NOT
    transparently-unwrapped) child extents deliberately: a parenthesized operand's
    OWN extent already includes its enclosing parens (`(-3.0)` spans the `(` and `)`),
    so the textual gap up to/between the RAW child extents is exactly the operator -
    unwrapping first (as the recursive structural walk does) would skip past those
    parens and swallow them into the "operator" text (e.g. read '-(' as the operator
    of `-(-3.0)`, corrupting the very double-negation case this tool exists to catch
    correctly - caught by this tool's own seeded probe, see seeded.md)."""
    children = [c for c in cursor.get_children()]
    if cursor.kind in _UNARY_KINDS:
        operand = children[0]
        pre = source_bytes[cursor.extent.start.offset : operand.extent.start.offset]
        return pre.decode("utf-8", "replace").strip()
    if cursor.kind in _BINARY_KINDS:
        left = children[0]
        right = children[1]
        mid = source_bytes[left.extent.end.offset : right.extent.start.offset]
        return mid.decode("utf-8", "replace").strip()
    raise Unsupported(f"not an operator cursor: {cursor.kind}")


def _walk(cursor, source_bytes, macro_name, wrapped=False):
    """Reduce a clang expression cursor to a canonical structural tuple:
      ('bin', op, left, right) | ('un', op, operand) | ('lit', text, wrapped_bool)
    Transparently unwraps parens/UNEXPOSED_EXPR and macro_name(...) calls (the
    macro's OWN correctness is the caller's job, applied per leaf via the wrapped
    flag). Anything else (a call to something else, a ternary, a comparison, a
    declaration reference, a cast) raises Unsupported - fails closed, never guessed.
    """
    cursor = _unwrap_transparent(cursor)
    if cursor.kind == ci.CursorKind.CALL_EXPR:
        children = list(cursor.get_children())
        callee_name = cursor.spelling
        args = [
            c
            for c in children
            if c.kind not in (ci.CursorKind.UNEXPOSED_EXPR,) or True
        ]
        # First child is the callee reference (DeclRefExpr, possibly wrapped in an
        # UNEXPOSED_EXPR); remaining children are the call arguments.
        call_args = children[1:] if children else []
        if callee_name == macro_name and len(call_args) == 1:
            return _walk(call_args[0], source_bytes, macro_name, wrapped=True)
        raise Unsupported(f"unsupported call to '{callee_name}' (only {macro_name}(x) is understood)")
    if cursor.kind in _LITERAL_KINDS:
        text = _extent_text(source_bytes, cursor)
        return ("lit", text, wrapped)
    if cursor.kind in _UNARY_KINDS:
        children = list(cursor.get_children())
        if len(children) != 1:
            raise Unsupported(f"unary operator with {len(children)} operands")
        op = _operator_spelling(cursor, source_bytes)
        if op not in ("+", "-"):
            raise Unsupported(f"unsupported unary operator '{op}'")
        return ("un", op, _walk(children[0], source_bytes, macro_name))
    if cursor.kind in _BINARY_KINDS:
        children = list(cursor.get_children())
        if len(children) != 2:
            raise Unsupported(f"binary operator with {len(children)} operands")
        op = _operator_spelling(cursor, source_bytes)
        if op not in ("+", "-", "*", "/"):
            raise Unsupported(f"unsupported binary operator '{op}' (comparison/logical/assignment operators are not a value expression)")
        return (
            "bin",
            op,
            _walk(children[0], source_bytes, macro_name),
            _walk(children[1], source_bytes, macro_name),
        )
    raise Unsupported(f"unsupported expression form: {cursor.kind}")


def _leaves(tree):
    if tree[0] == "lit":
        yield tree
    elif tree[0] == "un":
        yield from _leaves(tree[2])
    elif tree[0] == "bin":
        yield from _leaves(tree[2])
        yield from _leaves(tree[3])


def _shape(tree):
    """Structure only (operators + nesting), no leaf text - for the match/mismatch
    test; leaf text is compared separately (by the caller) with numeric tolerance."""
    if tree[0] == "lit":
        return ("lit",)
    if tree[0] == "un":
        return ("un", tree[1], _shape(tree[2]))
    return ("bin", tree[1], _shape(tree[2]), _shape(tree[3]))


def _find_named_descendant(cursor, kind, name):
    """The first descendant (any depth) of CURSOR matching KIND and NAME, depth
    first. A small, purpose-built recursive search - NOT `_collect_declarations`,
    whose const/static inclusion policy is deliberately narrower than "any variable
    declaration", so it would silently miss the plain (non-const, non-static) local
    `_parse_standalone_expr` declares to hold its synthetic expression."""
    for node in cursor.get_children():
        if node.kind == kind and node.spelling == name:
            return node
        found = _find_named_descendant(node, kind, name)
        if found is not None:
            return found
    return None


def _parse_standalone_expr(text, macro_name):
    """Parse TEXT as a standalone C expression and return its canonical structural
    tree. The synthetic fragment is:
        double <macro_name>(double __verify_anchors_a__);
        static void __verify_anchors_fn__(void) { int __verify_anchors_x__ = TEXT; }
    Two deliberate choices, both load-bearing (both found empirically this round):
      - MACRO_NAME is declared as a bare function PROTOTYPE, never a `#define`: TEXT
        (the SOURCE literal-as-read, or - per F-08 - a TARGET declaration's raw value
        text) can legitimately contain `macro_name(...)`, and with NO declaration of
        it at all, modern Clang raises a HARD ERROR for an implicit function call
        (ISO C99+, severity Error, not a mere warning) rather than leaving a plain
        unresolved CALL_EXPR - which would make every RCONST-wrapped anchor
        spuriously UNRELIABLE. A prototype (never a definition) resolves the call
        just enough to avoid that error while keeping `macro_name` UN-expanded (no
        macro definition exists here), so it stays the plain, structurally visible
        CALL_EXPR `_walk` has always needed to transparently unwrap.
      - The declaration holding TEXT lives inside a FUNCTION body, never at file
        scope: a file-scope initializer must be a C compile-time constant, and a
        call to a (necessarily non-constexpr, prototype-only) function is not one -
        "initializer element is not a compile-time constant" is a real diagnostic
        from real C rules, not a false positive, and it would misfire on every
        RCONST-wrapped value if left at file scope.
    Raises Unsupported on any diagnostic (this exact synthetic shape should never
    legitimately produce one) or an unsupported node shape."""
    synthetic = (
        f"double {macro_name}(double __verify_anchors_a__);\n"
        f"static void __verify_anchors_fn__(void) {{\n"
        f"  int __verify_anchors_x__ = {text};\n"
        f"}}\n"
    )
    index = _make_index()
    tu = index.parse(
        "__verify_anchors_expr__.c",
        args=["-std=c17"],
        unsaved_files=[("__verify_anchors_expr__.c", synthetic)],
    )
    errors = [d for d in tu.diagnostics if d.severity >= ci.Diagnostic.Error]
    if errors:
        raise Unsupported("; ".join(d.spelling for d in errors))
    decl = _find_named_descendant(tu.cursor, ci.CursorKind.VAR_DECL, "__verify_anchors_x__")
    if decl is None:
        raise Unsupported("no expression found")
    init = next(iter(decl.get_children()), None)
    if init is None:
        raise Unsupported("no initializer found")
    source_bytes = synthetic.encode("utf-8")
    return _walk(init, source_bytes, macro_name)


def _strip_trailing_comment(text):
    """Trim TEXT at the first `/*` (this project's own anchor-comment marker -
    port/conventions - a parser has no special knowledge of it) or `//`, whichever
    occurs first - never sequentially (a naive "cut at /* then cut at //" can cut at
    the WRONG one if `//` occurs before `/*` in the remaining text)."""
    positions = [p for p in (text.find("/*"), text.find("//")) if p != -1]
    if positions:
        text = text[: min(positions)]
    return text


_OPEN_TOKEN_SPELLINGS = ("(", "[")
_CLOSE_TOKEN_SPELLINGS = (")", "]")
_VALUE_TERMINATOR_SPELLINGS = (";", ",", "{", "}")


def _tu_tokens(tu):
    """The FULL token stream of the whole translation unit, in source order - never
    an individual cursor's OWN token range. A cursor's `.extent` can collapse to
    zero-width the moment a real macro (F-08) expands during that file's own parse
    (confirmed empirically this round: even the SURROUNDING DECLARATION's own
    extent can stop short of its value, not just the initializer sub-expression's),
    which would silently truncate `cursor.get_tokens()` too - but the WHOLE-
    TRANSLATION-UNIT cursor's own extent does not collapse (confirmed empirically:
    it always spans the whole file, offset 0 to file length), so tokenizing THAT
    range once and then filtering by offset is robust where tokenizing any single
    (possibly-collapsed) declaration cursor's own extent would not be."""
    return list(tu.get_tokens(extent=tu.cursor.extent))


def _extract_initializer_tokens(tokens, name_offset, name):
    """From the WHOLE-FILE token stream, starting at NAME_OFFSET (a declarator's own
    NAME location - reliable even when the declaration's or its initializer's OWN
    cursor extent collapses, per `_tu_tokens`), find the initializer's `=` token and
    return the RAW TEXT of its value (COMMENT tokens excluded, reconstructed from
    token spellings so original spacing/line breaks never matter), stopping at the
    first `;`, `,`, `{`, or `}` at (paren/bracket) depth 0. `,` and `}` are BOTH
    real ENUM-constant terminators - the LAST enumerator in a body has no trailing
    `,` before the enum's own closing `}` (found empirically this round: treating
    `}` as an ordinary depth-decrementing close token, symmetric with `)`/`]`,
    walked straight past the enum's own end and into garbage, corrupting the value -
    a regression caught by this unit's OWN full regression sweep before commit).
    Only `(`/`[` affect depth (a supported value never legitimately contains a
    brace at all, so `{`/`}` are unconditionally terminators, never nesting).
    Tracks `(`/`[` nesting while SEARCHING for `=` too, so a comment or an
    `__attribute__((...))` between the name and `=` (review round 4's F-11) is
    walked straight through - only TOKEN ORDER matters, never physical layout,
    never a name+`=` regex on one physical line. Raises Unsupported if no `=` is
    found before the declaration's own top-level terminator - the declarator's name
    turned out not to be followed by a directly-spelled initializer at this
    location at all, e.g. a macro-GENERATED declaration (`FOO(name, value)`
    expanding to `static const int name = value;` - the macro's own INVOCATION
    tokens, `FOO ( name , value )`, contain no `=` to find here; the value lives in
    the macro's OWN definition elsewhere, a form this tool does not attempt to
    resolve - reported Unsupported/UNRELIABLE for THIS declaration's structural
    check specifically, never silently guessed at, and never silently dropped from
    coverage either, since existence (`_has_initializer`) does not depend on this
    function at all) - or if the value found is empty."""
    relevant = [t for t in tokens if t.extent.start.offset >= name_offset]
    if not relevant:
        raise Unsupported(f"no tokens found at or after '{name}'s own declarator location")
    depth = 0
    eq_index = None
    for i, tok in enumerate(relevant):
        sp = tok.spelling
        if sp in _OPEN_TOKEN_SPELLINGS:
            depth += 1
        elif sp in _CLOSE_TOKEN_SPELLINGS:
            depth -= 1
        elif sp == "=" and depth == 0:
            eq_index = i
            break
        elif sp in _VALUE_TERMINATOR_SPELLINGS and depth <= 0:
            break
    if eq_index is None:
        raise Unsupported(
            f"no '=' found for '{name}' starting at its own declarator location - "
            f"not a directly-spelled initializer this tool can extract (e.g. a "
            f"macro-generated declaration)"
        )
    depth = 0
    value_tokens = []
    for tok in relevant[eq_index + 1 :]:
        if tok.kind == ci.TokenKind.COMMENT:
            continue
        sp = tok.spelling
        if sp in _OPEN_TOKEN_SPELLINGS:
            depth += 1
        elif sp in _CLOSE_TOKEN_SPELLINGS:
            depth -= 1
        elif sp in _VALUE_TERMINATOR_SPELLINGS and depth <= 0:
            break
        value_tokens.append(sp)
    if not value_tokens:
        raise Unsupported(f"'{name}' has an empty value after '='")
    return " ".join(value_tokens)


def _target_expr_tree(path, line, macro_name):
    """Find WHATEVER constant-providing declaration is actually at LINE in PATH (never
    trust a caller-supplied kind - re-derive it here via the SAME recursive walk
    `decls` uses) and return its value expression's canonical structural tree. Per
    F-08, the value is extracted as RAW TEXT (`_extract_initializer_tokens` / the
    `#define` value regex) and re-parsed in TOTAL ISOLATION (`_parse_standalone_expr`,
    no `#include`) - exactly the technique the SOURCE side already used - so
    `macro_name(...)` is GUARANTEED to still be an unresolved, structurally visible
    call regardless of whether the real file's own includes resolve it. No
    declaration at LINE, or MORE THAN ONE constant-providing declaration sharing LINE
    (F-10 - the anchor grammar embeds exactly one literal-as-read per physical line
    and cannot unambiguously cover two), is itself a reported Unsupported, never a
    silent guess. A dp/sp-regime conditional (`_dp_conditional_directive`, F-14,
    charter P-002) is ALSO refused here, defense in depth - `decls` already refuses
    the whole file first in the normal driver flow, but a direct `structcmp` call
    must not depend on that ordering to stay safe."""
    dp_line = _dp_conditional_directive(path)
    if dp_line is not None:
        raise Unsupported(
            f"'{path}' contains a preprocessor conditional on the dp/sp regime switch "
            f"({dp_line!r}) - this tool parses only one pinned regime (F-14); "
            f"exhaustive dual-regime coverage is deferred to Phase 2 (charter P-002)"
        )

    index = _make_index()
    tu = _parse_tu(index, path)

    ok, reason = _diagnostics_are_clean(tu)
    if not ok:
        raise Unsupported(
            f"'{path}' did not parse completely cleanly ({reason!r}) even with real "
            f"headers resolved (F-12) - cannot trust the declaration scan enough to "
            f"locate line {line}"
        )

    rows = []
    _collect_declarations(tu.cursor, path, rows)
    at_line = [(kind, name, cursor) for (l, _col, kind, name, cursor) in rows if l == line]
    if not at_line:
        raise Unsupported(
            f"no VAR/ENUM/DEFINE constant-providing declaration found at line {line} "
            f"in '{path}' (re-parse did not confirm a declaration at this exact line)"
        )
    if len(at_line) > 1:
        found = ", ".join(f"{kind}:{name}" for kind, name, _cursor in at_line)
        raise Unsupported(
            f"line {line} of '{path}' carries MORE THAN ONE constant-providing "
            f"declaration ({found}) - the anchor grammar embeds exactly one "
            f"literal-as-read per physical line and cannot unambiguously cover this "
            f"line (F-10); split the declarations onto separate lines"
        )
    kind, name, cursor = at_line[0]
    if kind == "DEFINE":
        line_text = _line_text(path, line)
        m = _DEFINE_VALUE_RE.match(line_text) if line_text is not None else None
        if m is None:
            raise Unsupported(f"'#define {name}' at line {line} of '{path}' did not re-match the value form")
        value_text = _strip_trailing_comment(m.group("val")).strip()
    else:
        tokens = _tu_tokens(tu)
        value_text = _extract_initializer_tokens(tokens, cursor.location.offset, name)
    return _parse_standalone_expr(value_text, macro_name)


def cmd_structcmp(path, line, literal_text, macro_name):
    try:
        line = int(line)
    except ValueError:
        sys.stderr.write(f"verify_anchors_ast: structcmp: line '{line}' is not an integer\n")
        return 2

    stripped = _strip_kind_suffixes(literal_text)
    if "**" in stripped:
        sys.stderr.write(
            "verify_anchors_ast: structcmp: literal contains Fortran '**' (exponentiation) - "
            "not a supported C-parseable form; extend and seed-test before relying on it\n"
        )
        return 2

    try:
        src_tree = _parse_standalone_expr(stripped, macro_name)
    except Unsupported as exc:
        sys.stderr.write(f"verify_anchors_ast: structcmp: SOURCE literal-as-read '{literal_text}' (stripped: '{stripped}') did not parse as a supported expression: {exc}\n")
        return 2

    try:
        tgt_tree = _target_expr_tree(path, line, macro_name)
    except Unsupported as exc:
        sys.stderr.write(f"verify_anchors_ast: structcmp: TARGET at {path}:{line}: {exc}\n")
        return 2

    if _shape(src_tree) != _shape(tgt_tree):
        print(f"MISMATCH\tstructure differs: SOURCE shape {_shape(src_tree)} vs TARGET shape {_shape(tgt_tree)}")
        return 0

    src_leaves = list(_leaves(src_tree))
    tgt_leaves = list(_leaves(tgt_tree))
    if len(src_leaves) != len(tgt_leaves):
        # Shapes matched but leaf counts differ - should not happen if _shape is a
        # faithful projection, but never assume: fail closed rather than zip() silently
        # truncating to the shorter list.
        print(f"MISMATCH\tleaf count differs: SOURCE {len(src_leaves)} vs TARGET {len(tgt_leaves)}")
        return 0

    for (_, s_text, _), (_, t_text, t_wrapped) in zip(src_leaves, tgt_leaves):
        print(f"LEAF\t{s_text}\t{t_text}\t{1 if t_wrapped else 0}")
    return 0


def _rconst_probe_diagnostics(path, macro_name, extra_args, expect_type):
    """Parse PATH with an in-memory `_Static_assert`/`_Generic` PROBE appended to
    its OWN real text (so the probe sees the SAME real headers/macros the file
    itself does - never a separate, isolated re-parse; F-13 is specifically about
    the REAL macro definition, the opposite concern from F-08) and return its
    diagnostics. The probe asks the C COMPILER's own semantic/constant-expression
    evaluator to SAMPLE both facts the pinned contract requires
    (as the project's conventions define it) AT ONE representative argument
    (`2.0`) - never libclang's own Cursor extent/token reading, which F-08 already
    showed is unsound the moment a real macro expands (identity-shaped expansions
    collapse extents; this equally affects any attempt to read the macro's OWN
    definition tokens back out):
      - `_Generic(MACRO(2.0), <expect_type>: 1, default: 0) == 1` - the EXPANSION's
        own semantic TYPE at THIS ONE sample is exactly EXPECT_TYPE (`double` in the
        dp regime, `float` in the sp regime) - catches a macro that does not
        token-paste an `f` suffix where required, or does (wrongly) where it must
        not, AT the sampled argument.
      - `MACRO(2.0) == 2.0` - the expansion is VALUE-PRESERVING AT THIS ONE SAMPLE
        (catches a macro that transforms its argument, e.g. adds an offset, or
        ignores it entirely and substitutes a constant, PROVIDED that mutation
        happens to affect the value `2.0`) - 2.0 is exactly representable in
        `float`, so this equality is exact in EITHER regime, never a false failure
        from ordinary float/double rounding.

    **Round 6 scope correction (charter P-002; review round 5, F-15): this is a
    SAMPLE, not a proof.** Independent review demonstrated a macro that special-
    cases the SAMPLED value (`(x) == 2.0 ? (x) : ((x) + 1.0)`, or a macro that
    simply ignores its argument and always returns `2.0`/`2.0f`) passes this probe
    while corrupting every OTHER invocation, including the real `RCONST(0.000001)`
    this check exists to protect. PROVING the contract for every possible argument
    (the reviewer's own recommended remediation: compare/generate the macro's
    actual token-paste/identity DEFINITION directly, a finite syntactic fact, rather
    than sampling its runtime semantics) is EXPLICITLY DEFERRED to Phase 2 (charter
    P-002) - not because it is hard, but because building and seed-testing it now
    would be guessing at a check for a defect class (a conditional macro rewritten
    around one specific literal) that has not been observed in any real translated
    C, since none exists yet. What ships now is HONEST about being a sample: it
    catches ordinary mutations (a wrong branch, a dropped token-paste, an added
    offset) with no dependence on the sampled value, and it is disclosed - in this
    docstring, in the caller's own output, and in the evidence - as exactly that,
    never advertised as proof.

    A clean parse (no diagnostic) means the compiler's own evaluator confirmed both
    `_Static_assert`s AT THE SAMPLED VALUE; a failed assert - or ANY other
    diagnostic, e.g. the macro not being reachable/defined at all from this file -
    is a real, disclosed reason this tool could not even confirm the sample, never
    silently assumed to hold. Returns a plain list of SPELLING STRINGS, deliberately
    never the `Diagnostic` objects themselves: a `Diagnostic` is only valid while
    its parent `TranslationUnit` is alive, and `tu` here is a local that goes out of
    scope (and can be garbage collected) the moment this function returns -
    returning the live objects crashed (a real, reproduced segfault, not a
    hypothetical) the moment the caller touched `.spelling` after this function had
    already returned."""
    real_text = _read_text(path).decode("utf-8", "replace")
    probe = (
        f"\n"
        f'_Static_assert(_Generic({macro_name}(2.0), {expect_type}: 1, default: 0) == 1, '
        f'"{macro_name} must produce a {expect_type} result in this regime");\n'
        f'_Static_assert({macro_name}(2.0) == 2.0, "{macro_name} must preserve its argument value");\n'
    )
    index = _make_index()
    tu = index.parse(
        path,
        args=["-std=c17", *extra_args],
        unsaved_files=[(path, real_text + probe)],
        options=ci.TranslationUnit.PARSE_DETAILED_PROCESSING_RECORD,
    )
    return [d.spelling for d in tu.diagnostics if d.severity >= ci.Diagnostic.Error]


def cmd_rconst_contract(path, macro_name, dp_define):
    """SAMPLE (never "verify", never "prove") whether PATH's REAL, actually-reachable
    `<macro_name>` macro (wherever it is really defined - never assumed to be any
    particular filename) implements the pinned dual-precision contract - identity
    (`double` result) when DP_DEFINE is defined, `x##f`-style (`float` result) when
    it is not - AT ONE REPRESENTATIVE ARGUMENT (`2.0`), in BOTH regimes - review
    round 4's F-13, scope corrected round 6 per charter P-002/review round 5's F-15:
    a macro that special-cases the sampled value (or ignores its argument entirely
    and always returns the expected constant) passes this probe while corrupting
    every OTHER invocation - PROVING the contract for every argument is deferred to
    Phase 2 (`_rconst_probe_diagnostics`'s own docstring has the full reasoning).
    `structcmp`'s own isolated re-parse (F-08) deliberately treats `macro_name` as an
    opaque, never-expanded call for STRUCTURAL comparison - by design, that proves
    invocation SPELLING, never the real macro's own behavior at all; this SAMPLE is
    the separate, complementary, but DELIBERATELY PARTIAL check the reviewer's own
    round-4 ruling asked for ("isolated reparse is sound only as one half of a
    two-part proof") - round 5 built the other half as a sample, not (yet) a proof.
    Exit 0 if the sample holds in both regimes; exit 2 (reason on stderr) if it does
    not, or could not even be sampled (the macro is not reachable/defined from this
    file at all, or the file has some other real problem) - never a silent pass."""
    rd = _resource_dir()
    base_args = [f"-resource-dir={rd}"] if rd else []
    for d in _include_dirs():
        base_args.append(f"-I{d}")

    for regime, extra, expect_type in (
        ("dp", [f"-D{dp_define}", *base_args], "double"),
        ("sp", list(base_args), "float"),
    ):
        try:
            errors = _rconst_probe_diagnostics(path, macro_name, extra, expect_type)
        except Exception as exc:
            sys.stderr.write(
                f"verify_anchors_ast: rconst-contract: could not sample '{path}' "
                f"({regime} regime): {exc}\n"
            )
            return 2
        if errors:
            sys.stderr.write(
                f"verify_anchors_ast: rconst-contract: '{path}': the real "
                f"'{macro_name}' macro does not confirm the pinned {regime} "
                f"contract AT THE SAMPLED VALUE (expected a bare {expect_type} "
                f"result, value-preserving): {'; '.join(errors)}\n"
            )
            return 2
    print(f"CONTRACT-SAMPLE-OK\t{macro_name}")
    return 0


def _dispatch(argv):
    if len(argv) < 2:
        sys.stderr.write(
            "usage: verify_anchors_ast.py decls <file> | structcmp <file> <line> <literal> <macro> "
            "| rconst-contract <file> <macro> <dp-define> | resource-dir\n"
        )
        return 2
    sub = argv[1]
    if sub == "decls":
        if len(argv) != 3:
            sys.stderr.write("usage: verify_anchors_ast.py decls <file>\n")
            return 2
        return cmd_decls(argv[2])
    if sub == "structcmp":
        if len(argv) != 6:
            sys.stderr.write("usage: verify_anchors_ast.py structcmp <file> <line> <literal> <macro>\n")
            return 2
        return cmd_structcmp(argv[2], argv[3], argv[4], argv[5])
    if sub == "rconst-contract":
        if len(argv) != 5:
            sys.stderr.write("usage: verify_anchors_ast.py rconst-contract <file> <macro> <dp-define>\n")
            return 2
        return cmd_rconst_contract(argv[2], argv[3], argv[4])
    if sub == "resource-dir":
        if len(argv) != 2:
            sys.stderr.write("usage: verify_anchors_ast.py resource-dir\n")
            return 2
        return cmd_resource_dir()
    sys.stderr.write(f"verify_anchors_ast: unknown subcommand '{sub}'\n")
    return 2


def main(argv):
    # A safety net, not a substitute for the specific Unsupported/try-except paths
    # above: ANY uncaught exception (a libclang binding surprise, an unanticipated
    # AST shape) must still fail closed with a clean message and exit 2 - never a
    # bare Python traceback mistaken for "ran successfully" by a caller that only
    # checks $? (a traceback DOES exit nonzero already, so this is a diagnostics-
    # quality improvement, not a correctness fix - but a diagnostic that names the
    # cause is what lets a human tell "unsupported construct" from "the tool broke").
    try:
        return _dispatch(argv)
    except Exception as exc:  # noqa: BLE001 - deliberately broad, see above
        sys.stderr.write(f"verify_anchors_ast: internal failure: {type(exc).__name__}: {exc}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
