#!/usr/bin/env python3
"""Extract the SOURCE dependency map from a Fortran source tree - the ROBUST core only.

The map gives the planner its foundation-first ORDERING and feeds two conformance checks: the file
INVENTORY (one node per source unit) is check-completeness's independent SOURCE accounting, and the
PROVEN in-tree use/call edges are check-contracts' producer->consumer cross-check. It also marks the
STRUCTURAL surfaces a line scan resolves unambiguously: a module USEd by >=2 units is an owned
foundation; a common block shared by >=2 is a shared surface - both keep their units out of the
self-serve pool (a human/owner handles them).

It does NOT guess. A reference the line scan cannot resolve in-tree draws NO edge and NO guard - the
extractor never invents a coupling it could not prove. The conservatism that used to come from those
guesses now comes from the real net: a unit wrongly ported in isolation fails its R1 DIFFERENTIAL proof
or the INDEPENDENT review. So the map carries only what a resolved `USE foo` / `CALL bar` / `COMMON
/blk/` states unambiguously - it is deterministic and drift-checkable, with nothing fragile to clear.

The inventory is not limited to files a compiler calls Fortran. Two more node/edge classes are drawn
with the SAME no-guessing discipline:
  - INCLUDE edges: a `#include "x.h"` resolved to a real in-tree file (same directory as the
    includer) makes that header a NODE too, with an `include`-kind edge from includer to header, and
    (like a module) a header pulled in by >=2 units becomes an owned surface. An include that does not
    resolve in-tree (e.g. a build-generated `*.intfb.h` interface block that exists nowhere in the
    tree) draws nothing, same as an unresolved `USE`/`CALL`.
  - GENERATE edges: a code GENERATOR (`.fypp` template, or any future project-specific generator
    extension) is walked as a first-class node exactly like a `.F90` unit - its own
    `MODULE`/`USE`/`CALL`/`COMMON` lines resolve the ordinary way. What a line scan genuinely cannot
    resolve is a coupling stated only through a TEMPLATED identifier (e.g. a fypp
    `USE ${obj.upper()}$_TYPE_MOD`) - never guessed at; instead it is read from the optional,
    project-committed `tools/scoping/generator-edges.yaml` (parallel to source-exclude.yaml), each
    entry citing the SOURCE fact that proves it.

Together these close the class of gap where a live, build-system-indirect file (a header pulled in
only by `#include`, or a code generator whose output a configure-time step appends to the build) has
no source list naming it and so falls silently outside the inventory the completeness/contract checks
are computed from.

The map is GENERATED, never hand-maintained. The generic framework lives here (methodology,
tools/coordination/); the per-project map it produces is project data (tools/scoping/).

Usage:
  extract_dependencies.py [--source-root DIR]                     print the generated map
  extract_dependencies.py --check [--map FILE] [--source-root DIR] drift-check a committed map
  extract_dependencies.py --owned-surfaces [--source-root DIR]    list owned-surface SOURCE paths
                                                                  (for check-claims --owned-surfaces)
Exit (--check): 0 the committed map matches SOURCE (or there is none yet); 1 DRIFT/malformed; 2 UNRELIABLE.
"""
import argparse
import fnmatch
import glob
import os
import re
import subprocess
import sys
from typing import NoReturn
from _chisel_lib import strict_loader as _strict_loader, repo_root as _repo_root

# A dependency edge is a property of the CONFIGURED build, not of the
# text. `scan_guarded_macros.py` (tools/conformance/lib/) already implements the hardened,
# independently-reviewed (prior rendering-conformance work, rounds 3-4) directive/logical-line recognizer
# this needs - clang's OWN raw lexer, immune to the hand-rolled-splicer bugs that file's own
# header documents (mid-keyword continuation splits, comments between `#` and the keyword,
# trigraphs/digraphs). REUSED here, not re-derived (failure mode B18) and not vendored a third
# time (two copies already exist, `tools/conformance/lib/` and `tools/conformance/project/lib/`,
# both noting a future contribute-to-base should hoist to one) - imported directly by absolute
# path relative to this file (both directories are methodology-layer and this module is invoked
# as `python3 tools/coordination/extract_dependencies.py`, so `sys.path[0]` is this file's own
# directory, not `tools/conformance/lib/`; the explicit insert below is what makes the import
# resolve regardless of invocation cwd).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "conformance", "lib"))
import scan_guarded_macros as _sgm  # noqa: E402

FORT_EXTS = (".f90", ".f95", ".f03", ".f08", ".f", ".for", ".ftn")
# fypp CODE GENERATORS: templates whose configure-time-expanded output is appended to the build's
# source list (e.g. a cmake generator that expands a template into a derived source list). Walked as a first-class node
# extension alongside FORT_EXTS - the template IS the SOURCE content to account for; the file it
# expands to at build time does not exist anywhere in the tree to walk.
GENERATOR_EXTS = (".fypp",)
# Auxiliary headers pulled in by a resolved `#include` from an already-known node
# (e.g., an inline-function header). Never walked directly - only ever
# added as a node when a real #include resolves to a real in-tree file of one of these extensions,
# so an unrelated same-extension file elsewhere in the tree is never guessed into the inventory.
INCLUDE_NODE_EXTS = (".h", ".inc")
RE_END = re.compile(r"^\s*end\b", re.I)
RE_MODULE = re.compile(r"^\s*module\s+(\w+)", re.I)
RE_SUB = re.compile(r"\bsubroutine\s+(\w+)", re.I)
RE_FUNC = re.compile(r"\bfunction\s+(\w+)", re.I)
RE_PROG = re.compile(r"^\s*program\s+(\w+)", re.I)
RE_COMMON = re.compile(r"\bcommon\s*/\s*(\w+)\s*/", re.I)
# use NAME | use :: NAME | use, intrinsic :: NAME | use NAME, only: ...
RE_USE = re.compile(r"^\s*use\b(?:\s*,[^:]*::|\s*::)?\s*(\w+)", re.I)
RE_USE_INTRINSIC = re.compile(r"^\s*use\b\s*,\s*intrinsic\b", re.I)
RE_CALL = re.compile(r"\bcall\s+(\w+)", re.I)
RE_INC = re.compile(r"""^\s*#?\s*include\s+['"]([^'"]+)['"]""", re.I)
# A FUNCTION invocation in Fortran carries NO syntactic marker - `F(I)` is indistinguishable from
# array indexing or a statement function by shape alone. So a call graph built only from `CALL`
# sites is a SUBROUTINE-ONLY graph that silently drops every function-call edge. These two resolve
# the ambiguity the only way a line scan honestly can (see _function_call_targets).
RE_INVOKE = re.compile(r"\b(\w+)\s*\(")
# Names bound locally in this file: dummy arguments, and entities on the RHS of a `::` declaration.
# A local binding SHADOWS any same-named global FUNCTION, so it must suppress the edge.
RE_DUMMY_ARGS = re.compile(r"\b(?:subroutine|function)\s+\w+\s*\(([^)]*)\)", re.I)
RE_DECL_RHS = re.compile(r"::\s*([^!]*)")
RE_NAME = re.compile(r"\b[A-Za-z_]\w*")

# Intrinsic subroutines/modules - calls/uses of these are NOT dependencies, so no edge.
INTRINSIC_SUBS = frozenset((
    "cpu_time", "random_number", "random_seed", "date_and_time", "system_clock",
    "get_command", "get_command_argument", "get_environment_variable", "move_alloc",
    "mvbits", "execute_command_line", "abort", "backtrace", "flush", "exit", "getarg", "getenv",
))
INTRINSIC_MODS = frozenset((
    "iso_fortran_env", "iso_c_binding", "ieee_arithmetic", "ieee_features",
    "ieee_exceptions", "omp_lib", "omp_lib_kinds",
))
ALLOWED_TOP = {"schema_version", "source_root", "nodes", "owned_surfaces", "edges"}

# --- Pinned macro state (project coupling externalized) ------------------------------
#
# A dependency edge is a property of the CONFIGURED build, not of the raw text.
# A `USE`/`CALL`/`#include` inside an `#ifdef HAVE_FEATURE` the pinned
# configuration leaves undefined does not exist in the compiled program, but a
# plain text scan would assert the edge anyway. An edge into an excluded node
# then blocks its consumer forever (a small but non-zero set of live units in
# the originating port were permanently blocked this way), because an excluded
# node never integrates.
#
# The pinned table lives in tools/scoping/macro-state.yaml (project layer,
# merge=ours, alongside dependency-map.yaml and generator-edges.yaml). The
# methodology-layer extractor reads it; an absent or unreadable file leaves
# every guarded edge UNRELIABLE (never silently kept, never silently dropped),
# preserving the three-state contract: OFF drops the edge, ON keeps it,
# UNKNOWN refuses to guess either way. Anecdote survives; provenance does not
# leak into the methodology file.
#
# Verified once in the originating port (not assumed): Fortran sources are
# preprocessed with ordinary cpp-style directives before compilation, so the
# same directive/conditional model the C-side scanner uses applies, and the raw
# lexer tokenizes Fortran text without complaint (including generator templates
# that mix their own directives with genuine cpp guards - the raw lexer leaves
# those alone since their first token after `#` is never a directive keyword).
# A trailing `!` Fortran comment on a directive line is tolerated as "extra
# tokens" for the single-identifier #ifdef forms; a `!` inside a genuine #if
# expression is the C NOT operator. No directive line a real build compiles
# has an ambiguous trailing `!` in the tree that originated this mechanism,
# and the parser fails closed (UNKNOWN) on anything it cannot parse.
#
# Each entry's `reason` cites the charter/CMake logic that pins it, or an
# exhaustive confirmation that no build file ever defines it. A macro is
# deliberately absent when its state is genuinely per-target/ambiguous (e.g., a
# precision flag defined for one library target and undefined for another -
# both are live in a dual-build) or simply unproven (a numeric compiler macro
# or external switch) - querying an absent name is UNKNOWN, not a guess, exactly
# the fail-closed contract: OFF drops, ON keeps, UNDETERMINED refuses to guess.
MACRO_STATE_REL = os.path.join("tools", "scoping", "macro-state.yaml")


def _load_pinned_macro_state(repo_root, yaml):
    """Read the pinned macro table (tools/scoping/macro-state.yaml, project layer).

    Returns NAME -> (bool ON/OFF, provenance). An absent or unreadable file
    returns an empty dict - every subsequent guarded-edge query then becomes
    UNKNOWN via _macro_tristate, so _check_live fails closed (UNRELIABLE)
    naming the file/line/macro rather than silently keeping or dropping the
    edge. A malformed file (not a mapping, not the expected shape, a non-bool
    value) also returns empty rather than silently falling back to a stale
    hard-coded table: provenance-preserved data stays in the project layer
    where it belongs. The methodology file carries no project macro names.

    The shape mirrors _load_macro_state_override: {macro_state: {NAME: {value,
    reason}}}, with `value` deliberately not named `on` (YAML 1.1 parses an
    unquoted `on` as bool True)."""
    path = os.path.join(repo_root, MACRO_STATE_REL)
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.load(fh, Loader=_strict_loader(yaml))
    except (OSError, yaml.YAMLError):
        return {}
    if data is None:
        return {}
    if not isinstance(data, dict) or (set(data) - {"macro_state"}):
        return {}
    entries = data.get("macro_state") or {}
    if not isinstance(entries, dict):
        return {}
    out = {}
    for name, spec in entries.items():
        if not isinstance(spec, dict) or not isinstance(spec.get("value"), bool):
            return {}
        if not str(spec.get("reason") or "").strip():
            return {}
        out[str(name)] = (bool(spec["value"]), str(spec["reason"]))
    return out

# Tri-state (Kleene) logic over (value, reason): value is True (definitely live/ON), False
# (definitely dead/OFF), or None (cannot be determined - `reason` explains why, carried through
# every combination so a final UNKNOWN always cites the macro that caused it). DEAD dominates
# (an outer OFF makes an inner region dead no matter what the inner condition is - e.g.
# a per-precision flag nested inside an already-OFF feature flag), then UNKNOWN,
# then LIVE - the "fail closed only when it actually matters" ordering the task
# requires: a macro this tool cannot resolve never even needs resolving if an
# enclosing guard has already proven the region dead.


def _tri_and(a, b):
    av, ar = a
    bv, br = b
    if av is False:
        return (False, ar)
    if bv is False:
        return (False, br)
    if av is None:
        return (None, ar)
    if bv is None:
        return (None, br)
    return (True, None)


def _tri_or(a, b):
    av, ar = a
    bv, br = b
    if av is True:
        return (True, ar)
    if bv is True:
        return (True, br)
    if av is None:
        return (None, ar)
    if bv is None:
        return (None, br)
    return (False, None)


def _tri_not(a):
    av, ar = a
    if av is True:
        return (False, ar)
    if av is False:
        return (True, ar)
    return (None, ar)


def _macro_tristate(name, macro_state):
    """The pinned tri-state of one macro NAME: (True, "...=ON (...)") / (False, "...=OFF (...)")
    from the pinned table's provenance (tools/scoping/macro-state.yaml), or
    (None, "...") - fail closed, never guessed - if this session never
    established NAME's state."""
    if name not in macro_state:
        return (None,
                "macro '%s' is not in the pinned macro-state table "
                "(tools/scoping/macro-state.yaml) - its state was never "
                "established for this configuration" % name)
    val, prov = macro_state[name]
    return (bool(val), "%s=%s (%s)" % (name, "ON" if val else "OFF", prov))


def _cond_significant(tokens, start, end):
    """The tokens of tokens[start:end] that carry real preprocessor-expression meaning: blank
    whitespace and comments are transparent, exactly as scan_guarded_macros.py's own directive
    recognition treats them (phase 3 makes a comment indistinguishable from a space)."""
    return [t for t in tokens[start:end] if not (_sgm._is_blank(t) or t["type"] == "comment")]


class _CondEval:
    """A minimal recursive-descent evaluator for a `#if`/`#elif` boolean expression:
    `defined(NAME)` / `defined NAME` / `!expr` / `expr && expr` / `expr || expr` / `(expr)` /
    a bare NAME (treated the same as `defined(NAME)` - pinned macros in the
    originating port are plain feature flags, never given a numeric value that
    would make the distinction matter; documented simplification, not a general
    C preprocessor) / a numeric literal (`0` is FALSE, anything else TRUE).
    Anything it does not recognize (a comparison operator, an unmatched paren,
    leftover tokens after a complete expression - the shape a trailing Fortran
    `!` comment would produce, verified empirically to not occur in the
    originating tree - see the pinned-macro provenance section above) makes
    `.parse()` return UNKNOWN rather than raise: a condition this tool cannot
    parse is exactly as untrustworthy as a macro it cannot look up, and the
    caller's fail-closed policy is identical either way."""

    def __init__(self, toks, macro_state):
        self.toks = toks
        self.i = 0
        self.macro_state = macro_state
        self.malformed = False

    def _peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else None

    def _eat(self):
        t = self.toks[self.i]
        self.i += 1
        return t

    def parse(self):
        v = self._or()
        if self.malformed or self.i != len(self.toks):
            return (None, "preprocessor condition could not be parsed in full (unsupported "
                          "syntax or leftover tokens)")
        return v

    def _or(self):
        v = self._and()
        while True:
            t = self._peek()
            if t is not None and t["type"] == "pipepipe":
                self._eat()
                v = _tri_or(v, self._and())
            else:
                return v

    def _and(self):
        v = self._not()
        while True:
            t = self._peek()
            if t is not None and t["type"] == "ampamp":
                self._eat()
                v = _tri_and(v, self._not())
            else:
                return v

    def _not(self):
        t = self._peek()
        if t is not None and t["type"] == "exclaim":
            self._eat()
            return _tri_not(self._not())
        return self._primary()

    def _primary(self):
        t = self._peek()
        if t is None:
            self.malformed = True
            return (None, "empty preprocessor condition")
        if t["type"] == "l_paren":
            self._eat()
            v = self._or()
            t2 = self._peek()
            if t2 is not None and t2["type"] == "r_paren":
                self._eat()
            else:
                self.malformed = True
            return v
        if t["type"] == "raw_identifier" and t["spelling"] == "defined":
            self._eat()
            paren = False
            nt = self._peek()
            if nt is not None and nt["type"] == "l_paren":
                self._eat()
                paren = True
            name_tok = self._peek()
            if name_tok is None or name_tok["type"] != "raw_identifier":
                self.malformed = True
                return (None, "malformed defined(...)")
            self._eat()
            if paren:
                nt2 = self._peek()
                if nt2 is not None and nt2["type"] == "r_paren":
                    self._eat()
                else:
                    self.malformed = True
            return _macro_tristate(name_tok["spelling"], self.macro_state)
        if t["type"] == "raw_identifier":
            self._eat()
            return _macro_tristate(t["spelling"], self.macro_state)
        if t["type"] == "numeric_constant":
            self._eat()
            return (t["spelling"].strip() != "0", "numeric literal '%s'" % t["spelling"])
        self.malformed = True
        return (None, "unsupported token '%s' in preprocessor condition" % t["spelling"])


_DIRECTIVE_COND_KEYWORDS = {"if", "ifdef", "ifndef"}
_DIRECTIVE_CHAIN_KEYWORDS = {"if", "ifdef", "ifndef", "elif", "else", "endif"}


def _line_liveness(path, macro_state):
    """The tri-state LIVENESS of every physical line of `path` under `macro_state`: a dict
    {lineno: (value, reason)}, 1-indexed, covering every line in the file (a line outside any
    `#if`/`#ifdef`/`#ifndef` is unconditionally (True, None)). Built by walking clang's own
    logical-line spans (`_sgm._spans`/`_sgm._parse_raw_tokens`/`_sgm._first_significant` -
    REUSED, not re-derived) and folding each `#if`/`#ifdef`/`#ifndef`/`#elif`/`#else`/`#endif`
    through the Kleene combinators above: a branch is live only if EVERY enclosing condition
    holds (`_tri_and` with the parent state) AND no earlier sibling in its own `#if`/`#elif`
    chain already matched (`_tri_and` with the rolling `no_match_yet`, itself narrowed by
    `_tri_not` after each sibling) - the standard C conditional-inclusion semantics, computed in
    three-valued logic so an unresolvable macro propagates as UNKNOWN instead of ON or OFF.

    Raises RuntimeError - the caller maps this to a hard, fail-closed failure, never a silent
    "treat as fully live" - on a clang/parse failure (`_sgm._parse_raw_tokens`) or on unbalanced
    `#elif`/`#else`/`#endif` nesting (a `#elif`/`#else`/`#endif` with no open `#if`, or a `#if`
    left open at EOF): a file whose directive STRUCTURE this tool cannot follow must never be
    silently treated as ordinary code.
    """
    tokens = _sgm._parse_raw_tokens(path)
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            n_lines = sum(1 for _ in fh)
    except OSError as exc:
        raise RuntimeError("cannot read %s (%s)" % (path, exc)) from exc

    states = {}
    last_filled = 0

    def _fill(upto, value):
        nonlocal last_filled
        ln = last_filled + 1
        while ln <= upto:
            states[ln] = value
            ln += 1
        if upto > last_filled:
            last_filled = upto

    cur = (True, None)  # top of file: unconditionally live
    stack = []           # frames: {"parent": tri, "no_match_yet": tri}

    for start, end in _sgm._spans(tokens):
        idx = _sgm._first_significant(tokens, start, end)
        if idx is None or tokens[idx]["type"] != "hash":
            continue  # not a directive line at all
        k = _sgm._first_significant(tokens, idx + 1, end)
        if (k is None or tokens[k]["type"] != "raw_identifier"
                or tokens[k]["spelling"] not in _DIRECTIVE_CHAIN_KEYWORDS):
            continue  # '#include' / '#define' / fypp's '#:...' / malformed - not conditional
        keyword = tokens[k]["spelling"]
        line_no = int(tokens[idx]["line"])  # _TOKEN_RE captures "line" as a string group
        _fill(line_no - 1, cur)
        cond_toks = _cond_significant(tokens, k + 1, end)

        if keyword in _DIRECTIVE_COND_KEYWORDS:
            if keyword == "if":
                cond = _CondEval(cond_toks, macro_state).parse()
            else:
                # #ifdef/#ifndef: real cpp only looks at the FIRST identifier and merely WARNS
                # on anything trailing (verified empirically this session) - so this tool does
                # the same, rather than (wrongly) treating lenient extra tokens as malformed.
                if cond_toks and cond_toks[0]["type"] == "raw_identifier":
                    base = _macro_tristate(cond_toks[0]["spelling"], macro_state)
                else:
                    base = (None, "malformed #%s (no macro name found)" % keyword)
                cond = _tri_not(base) if keyword == "ifndef" else base
            parent = cur
            stack.append({"parent": parent, "no_match_yet": _tri_not(cond)})
            cur = _tri_and(parent, cond)
        elif keyword == "elif":
            if not stack:
                raise RuntimeError("%s:%d: #elif with no matching #if" % (path, line_no))
            frame = stack[-1]
            cond = _CondEval(cond_toks, macro_state).parse()
            selected = _tri_and(frame["no_match_yet"], cond)
            frame["no_match_yet"] = _tri_and(frame["no_match_yet"], _tri_not(cond))
            cur = _tri_and(frame["parent"], selected)
        elif keyword == "else":
            if not stack:
                raise RuntimeError("%s:%d: #else with no matching #if" % (path, line_no))
            frame = stack[-1]
            cur = _tri_and(frame["parent"], frame["no_match_yet"])
            frame["no_match_yet"] = (False, "past this chain's #else")
        else:  # "endif"
            if not stack:
                raise RuntimeError("%s:%d: #endif with no matching #if" % (path, line_no))
            cur = stack.pop()["parent"]
        states[line_no] = cur  # the directive line's own text is never scanned as code either way
        last_filled = line_no

    if stack:
        raise RuntimeError(
            "%s: %d unterminated #if/#ifdef/#ifndef directive(s) at end of file" % (path, len(stack)))
    _fill(n_lines, cur)
    return states


def _check_live(liveness, lineno, source_rel, what):
    """True iff the candidate edge/coupling found at (source_rel, lineno) should be kept, per
    that line's guarded-region tri-state LIVENESS (`_line_liveness`): DEAD -> False, silently
    dropped (a `USE`/`CALL`/`#include` inside an `#ifdef` the pinned
    configuration compiles out draws no edge). LIVE, or outside any `#if`/`#ifdef`/`#ifndef`
    entirely -> True, unchanged from before this fix. UNKNOWN -> fails closed (`_fail`, exit 2)
    naming the file, line, and the macro that could not be resolved - never silently kept and
    never silently dropped, exactly the task's three-state contract."""
    val, reason = liveness.get(lineno, (True, None))
    if val is False:
        return False
    if val is None:
        _fail(
            "%s:%d: cannot determine whether this %s is compiled in the pinned configuration - "
            "%s - refusing to guess" % (source_rel, lineno, what, reason))
    return True


def _locally_declared(code):
    """Names BOUND LOCALLY in this file: dummy arguments, plus entities declared after a `::`.

    Fortran resolves `W1(I)` against local scope first, so a local array or dummy named `W1`
    shadows any global FUNCTION of the same name. Without this, a bare-invocation scan pulls in
    whole unrelated modules through what is really an array subscript.

    This is a FILE-granularity heuristic, not a symbol table: a name declared in ANY scoping unit
    of the file suppresses the edge everywhere in that file. It is deliberately biased toward the
    FALSE NEGATIVE (a missed edge), because this extractor's contract is to emit only what it can
    prove - and a missed edge costs ordering conservatism, while a fabricated edge would corrupt
    the ready-set with coupling that does not exist.
    """
    names = set()
    for ln in code:
        for m in RE_DUMMY_ARGS.finditer(ln):
            names.update(a.strip().lower() for a in m.group(1).split(",") if a.strip())
        md = RE_DECL_RHS.search(ln)
        if md:
            names.update(n.group(0).lower() for n in RE_NAME.finditer(md.group(1)))
    return names


def _function_call_targets(ln, def_func, declared):
    """Names on this line that are BARE FUNCTION INVOCATIONS of an in-tree FUNCTION.

    Emits a name only when all of the following hold, so no edge is ever guessed:
      - it is followed by `(`                       (an invocation or a subscript)
      - it is a FUNCTION defined somewhere in-tree  (resolvable, per the no-guessing rule)
      - it is not bound locally in this file        (not shadowed by an array/dummy)
      - it is not the target of `CALL` on this line (that edge is already drawn as a call)
    """
    if not def_func:
        return ()
    called = {m.group(1).lower() for m in RE_CALL.finditer(ln)}
    out = []
    for m in RE_INVOKE.finditer(ln):
        name = m.group(1).lower()
        if name in def_func and name not in declared and name not in called:
            out.append(name)
    return out
ALLOWED_CONF = {"proven"}
ALLOWED_ROLE = {"owned", "unowned"}

# Coarse out-of-scope SOURCE paths (project-layer). A real SOURCE often ships MULTIPLE build
# variants that share file stems (e.g. a src_fortran/ vs a src_fortran_variant/, both defining the
# same kernel.F90). Only the LIVE subset is ported; the dependency map and TRACE cover that
# subset. Rather than list every dead-variant file as `status: excluded` (and collide on the shared
# stems), the dead variants are excluded COARSELY here - a few source_root-relative path prefixes or
# globs, each with a reason. The extractor never walks into them, so the map is the LIVE source tree
# (still an INDEPENDENT inventory, so check-completeness's map-vs-TRACE cross-check stays meaningful).
EXCLUDE_REL = os.path.join("tools", "scoping", "source-exclude.yaml")


def _fail(msg) -> "NoReturn":
    sys.stderr.write("extract-dependencies: " + msg + "\n")
    sys.exit(2)


def _strip_comment(line):
    """Strip a trailing free-form comment at the first '!' OUTSIDE a string. A naive cut at the
    first '!' would truncate `print *, "a!b"; call c()` inside the string literal and hide the
    `; call c()` after it - so track single/double-quote state and honor only an unquoted '!'."""
    q = None
    for i, ch in enumerate(line):
        if q is not None:
            if ch == q:
                q = None
        elif ch in ("'", '"'):
            q = ch
        elif ch == "!":
            return line[:i]
    return line


def _as_list(x):
    return x if isinstance(x, list) else []


def _load_excludes(root, yaml):
    """Read the committed coarse-exclusion list (tools/scoping/source-exclude.yaml) into a list of
    source_root-relative path prefixes/globs. Absent file -> [] (no exclusions). Malformed -> fail
    closed (an unreadable scoping policy must never silently widen the walk)."""
    path = os.path.join(root, EXCLUDE_REL)
    if not os.path.isfile(path):
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.load(fh, Loader=_strict_loader(yaml))
    except (OSError, yaml.YAMLError) as exc:
        _fail("cannot read source-exclude '%s' (%s)" % (EXCLUDE_REL, exc))
    if data is None:
        return []
    if not isinstance(data, dict) or (set(data) - {"exclude"}):
        _fail("source-exclude '%s' must be a mapping with only an 'exclude:' list" % EXCLUDE_REL)
    items = data.get("exclude") or []
    if not isinstance(items, list):
        _fail("source-exclude 'exclude' must be a list")
    pats = []
    for it in items:
        if not isinstance(it, dict) or "path" not in it:
            _fail("each source-exclude entry must be a mapping with a 'path' and a 'reason'")
        if not str(it.get("reason") or "").strip():
            _fail("source-exclude entry '%s' needs a non-empty 'reason'" % (it.get("path"),))
        p = str(it.get("path") or "").strip().strip("/")
        if p:
            pats.append(p)
    return pats


GENERATOR_EDGES_REL = os.path.join("tools", "scoping", "generator-edges.yaml")


def _load_generator_edges(path, yaml):
    """Read an OPTIONAL generator-coupling table (default tools/scoping/generator-edges.yaml,
    parallel to source-exclude.yaml; overridable with --generator-edges so a fixture/test tree
    unrelated to this project's own generators is never checked against it): explicit
    generator-to-generator dependencies a pure text scan cannot resolve because the coupling is
    stated only through a fypp-TEMPLATED identifier (not a literal name `RE_USE`/`RE_CALL` can
    match). Each entry is (from, to, reason) - a `generates`-kind proven edge from the consuming
    generator to the one whose output it depends on, same direction as a `use` edge. Absent file ->
    [] (no generator edges declared, the common case for a SOURCE with no fypp templates at all).
    Malformed -> fail closed (this is a human-authored assertion, not a heuristic best-effort, so a
    broken entry is a bug in the data file, not something to silently ignore)."""
    if not os.path.isfile(path):
        return []
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.load(fh, Loader=_strict_loader(yaml))
    except (OSError, yaml.YAMLError) as exc:
        _fail("cannot read generator-edges '%s' (%s)" % (path, exc))
    if data is None:
        return []
    if not isinstance(data, dict) or (set(data) - {"generator_edges"}):
        _fail("generator-edges '%s' must be a mapping with only a 'generator_edges:' list" % path)
    items = data.get("generator_edges") or []
    if not isinstance(items, list):
        _fail("generator-edges 'generator_edges' must be a list")
    out = []
    for it in items:
        if not isinstance(it, dict) or "from" not in it or "to" not in it:
            _fail("each generator-edges entry must be a mapping with 'from', 'to' and a 'reason'")
        if not str(it.get("reason") or "").strip():
            _fail("generator-edges entry '%s -> %s' needs a non-empty 'reason'"
                  % (it.get("from"), it.get("to")))
        f, t = str(it.get("from") or "").strip(), str(it.get("to") or "").strip()
        if not f or not t:
            _fail("generator-edges entry has an empty 'from'/'to'")
        out.append((f, t))
    return out


def _load_macro_state_override(path, yaml):
    """Read an OPTIONAL macro-state override (`--macro-state FILE`): entries MERGED on top of the
    pinned table (tools/scoping/macro-state.yaml). Test/fixture use only - no real
    invocation against the originating SOURCE passes this flag, since every macro
    that actually guards a resolvable edge there is already pinned, with
    provenance, in the pinned file itself. A fixture typically names its OWN
    macro (e.g. a seeded-bug demo's `DEMO_FEATURE`, never colliding with a real
    project name); overriding a REAL name is also accepted, for a controlled
    what-if probe. Malformed -> fail closed (this is a human-authored assertion,
    not a heuristic best-effort, so a broken entry is a bug in the data, not
    something to silently ignore).

    `path` carries the THREE-STATE distinction the caller must make (review round 1, F-01): `None`
    means the flag was never given at all - the ordinary, default-every-real-run case - and returns
    {} (no override). A NON-None path that does not resolve to a real file means the CALLER
    explicitly asked for an override and named a path that cannot be honored (missing, deleted,
    permission-denied, a directory, a typo) - collapsing that into the same {} as "no flag" would
    make an explicitly requested configuration input silently vacuous (section 7b: broken/vacuous
    detector plus an ordinary environmental accident - a typo'd path would look identical to "the
    override worked and just had nothing to say"). So this fails closed instead, naming the exact
    path and why it could not be used - never silently falling back to the pinned table when the
    caller asked, specifically, not to rely on it alone."""
    if path is None:
        return {}
    if not os.path.isfile(path):
        _fail("--macro-state '%s' is not a file (explicitly requested override could not be "
              "loaded - refusing to silently fall back to the pinned table)" % path)
    try:
        with open(path, encoding="utf-8") as fh:
            data = yaml.load(fh, Loader=_strict_loader(yaml))
    except (OSError, yaml.YAMLError) as exc:
        _fail("cannot read macro-state override '%s' (%s)" % (path, exc))
    if data is None:
        return {}
    if not isinstance(data, dict) or (set(data) - {"macro_state"}):
        _fail("macro-state override '%s' must be a mapping with only a 'macro_state:' mapping" % path)
    entries = data.get("macro_state") or {}
    if not isinstance(entries, dict):
        _fail("macro-state override 'macro_state' must be a mapping of NAME -> {value, reason}")
    out = {}
    for name, spec in entries.items():
        # NOTE: the field is named `value`, deliberately NOT `on`/`off` - YAML 1.1 (PyYAML's
        # default resolver) parses an UNQUOTED `on`/`off`/`yes`/`no` KEY as the boolean itself
        # (`{on: false}` parses as `{True: False}`, not `{"on": False}` - verified empirically
        # this session), which would silently make every entry fail this very check.
        if not isinstance(spec, dict) or not isinstance(spec.get("value"), bool):
            _fail("macro-state override entry '%s' needs a boolean 'value'" % name)
        if not str(spec.get("reason") or "").strip():
            _fail("macro-state override entry '%s' needs a non-empty 'reason'" % name)
        out[str(name)] = (bool(spec["value"]), str(spec["reason"]))
    return out


def _excluded(rel, pats):
    """True if the source_root-relative path `rel` is out of scope: an exact match, under an excluded
    subtree prefix, or matching an excluded glob."""
    for p in pats:
        if rel == p or rel.startswith(p + "/") or fnmatch.fnmatch(rel, p):
            return True
    return False


def _source_files(root, excludes=(), exts=FORT_EXTS):
    out = []
    for dirpath, dirs, files in os.walk(root):
        dirs.sort()
        # Prune excluded directories so we never descend into a dead build variant.
        dirs[:] = [d for d in dirs
                   if not _excluded(os.path.relpath(os.path.join(dirpath, d), root).replace(os.sep, "/"), excludes)]
        for name in sorted(files):
            if os.path.splitext(name)[1].lower() in exts:
                rel = os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/")
                if not _excluded(rel, excludes):
                    out.append(os.path.join(dirpath, name))
    return out


class _GitUnusable(Exception):
    """The git binary itself could not be run - a TOOLING failure, never silently treated as 'this
    tree has no git history to check' (which is a different, legitimate state - see
    _git_tracked_recognized)."""


def _git_tracked_recognized(source_root, excludes, exts):
    """The set of RECOGNIZED-extension files (source_root-relative, '/'-separated) that GIT TRACKS
    under source_root - an independent, always-on ground truth for "what SOURCE exists at this
    commit" that needs no separately-maintained golden map (the same technique
    check_live_tracked.py already uses to catch a live file silently missing from git; this is its
    mirror image - a file git KNOWS about that the WORKING TREE is missing, i.e. a truncated
    checkout). `os.walk` alone cannot distinguish "this SOURCE genuinely has few files" from "this
    checkout lost most of them"; git's index can, because it does not depend on what happens to be
    present on disk right now.

    Returns the tracked set - a plain FACT about git's index, which may be empty (e.g. a
    freshly-imported, not-yet-`git add`ed SOURCE has zero tracked files here). This function does
    NOT decide whether an empty set is acceptable; the caller does (see extract()'s three-state
    policy: verified-complete / verified-incomplete / could-not-determine - an empty tracked set is
    "could not determine", not "nothing to compare against, so assume complete"). Returns None if
    source_root is not inside a git working tree at all. Raises _GitUnusable if the git binary
    itself cannot be run (a tooling problem, not a data one)."""
    try:
        probe = subprocess.run(["git", "rev-parse", "--is-inside-work-tree"], cwd=source_root,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError as exc:
        raise _GitUnusable(str(exc))
    if probe.returncode != 0:
        return None
    try:
        out = subprocess.run(["git", "ls-files", "-z"], cwd=source_root,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as exc:
        raise _GitUnusable(str(exc))
    if out.returncode != 0:
        raise _GitUnusable(out.stderr.decode(errors="replace").strip())
    tracked = set()
    for rel in out.stdout.decode("utf-8", errors="replace").split("\0"):
        if not rel:
            continue
        rel = rel.replace("\\", "/")
        if os.path.splitext(rel)[1].lower() in exts and not _excluded(rel, excludes):
            tracked.add(rel)
    return tracked


def _register_definitions(nid, code, def_module, def_proc, def_func, node_modules, commons):
    """Scan one node's stripped-comment lines for MODULE/SUBROUTINE/FUNCTION/PROGRAM definitions and
    COMMON block membership. Used identically for a primary Fortran/fypp unit and for a header
    discovered through a resolved #include - a header that happens to declare its own module/common
    (not the case for any header in this SOURCE today, but not assumed) is not special-cased."""
    node_modules[nid] = []
    for ln in code:
        if RE_END.match(ln):
            continue
        m = RE_MODULE.match(ln)
        if m and m.group(1).lower() != "procedure":
            def_module[m.group(1).lower()] = nid
            node_modules[nid].append("module:" + m.group(1).lower())
            continue
        ms = RE_SUB.search(ln)
        if ms:
            def_proc[ms.group(1).lower()] = nid
        mf = RE_FUNC.search(ln)
        if mf:
            def_proc[mf.group(1).lower()] = nid
            def_func.add(mf.group(1).lower())
        mp = RE_PROG.match(ln)
        if mp:
            def_proc[mp.group(1).lower()] = nid
    for ln in code:
        mc = RE_COMMON.search(ln)
        if mc:
            commons.setdefault(mc.group(1).lower(), set()).add(nid)


def extract(source_root, excludes=(), generator_edges=(), macro_state=None):
    """Build the deterministic map data model from a Fortran tree under source_root. `excludes` are
    coarse out-of-scope path prefixes/globs (dead build variants) the walk skips, so the map is the
    LIVE source tree. `generator_edges` are explicit (dependent, generator) node-id pairs read from
    the project's tools/scoping/generator-edges.yaml (see _load_generator_edges) - couplings a line
    scan cannot resolve because they are stated only through a fypp-templated identifier.
    `macro_state` is the NAME -> (bool ON/OFF, provenance) table a
    `USE`/`CALL`/`#include` inside a guarded-dead region is checked against,
    read from the pinned file tools/scoping/macro-state.yaml (project layer; an
    absent or unreadable file yields UNKNOWN for every guarded edge, never
    silently kept or dropped) and optionally merged with an override via
    `--macro-state` (see _load_macro_state_override) for fixture/test trees.

    Emits the file INVENTORY (one node per source unit - a `.F90`-family unit, a `.fypp` code
    GENERATOR walked the same way, or a `.h`/`.inc` header discovered through a resolved #include),
    the PROVEN in-tree use/call/include/generates edges, and the STRUCTURAL owned/shared surfaces (a
    module or header USEd/#included by >=2 units is an owned foundation; a common block shared by
    >=2 is a shared surface). It does NOT guess: a reference the line scan cannot resolve in-tree
    draws no edge and no guard.

    Raises ValueError on a structural problem that must fail closed: a duplicate file stem among the
    LIVE files, a generator-edges entry naming a node the SOURCE does not have, a source_root that
    exists but yields ZERO recognized source files, or - once the full inventory (primary units PLUS
    include-discovered headers) is known - a git-verified completeness failure: source_root is not
    inside a git working tree, git tracks NO recognized-extension file there at all (an unverifiable
    baseline, not evidence of completeness), or git tracks a recognized file this scan did not
    discover (a TRUNCATED tree, not a genuinely smaller SOURCE). Exits (via _fail) if the git binary
    cannot be run at all - a tooling failure, never silently read as "nothing to verify against"."""
    files = _source_files(source_root, excludes, FORT_EXTS + GENERATOR_EXTS)
    if not files:
        raise ValueError(
            "source root '%s' exists but contains no recognized source file (%s, after exclusions) - "
            "refusing to emit a possibly-empty/truncated inventory as though it were complete"
            % (source_root, ", ".join(sorted(FORT_EXTS + GENERATOR_EXTS))))
    macro_state = {} if macro_state is None else macro_state
    def_module, def_proc, commons = {}, {}, {}
    nodes, node_modules, raw_by_node = {}, {}, {}
    def_func, declared_by_node = set(), {}
    liveness_by_node = {}

    def _add_node(path, rel):
        """Register one file as a node (idempotent: re-discovering the same path through a second
        #include is a no-op). Fails closed on a genuine stem collision against a DIFFERENT path."""
        nid = os.path.splitext(os.path.basename(path))[0]
        if nid in nodes and nodes[nid] != rel:
            raise ValueError("duplicate file stem '%s' (%s and %s) - node ids must be unique. If these "
                             "are sibling BUILD VARIANTS of one SOURCE (only one is ported), exclude the "
                             "dead variant(s) coarsely in tools/scoping/source-exclude.yaml so only the "
                             "LIVE subset is mapped" % (nid, nodes.get(nid), rel))
        if nid in nodes:
            return nid
        nodes[nid] = rel
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                rawlines = fh.readlines()
        except OSError as exc:
            _fail("cannot read source '%s' (%s)" % (path, exc))
        code = [_strip_comment(ln) for ln in rawlines]
        raw_by_node[nid] = code
        _register_definitions(nid, code, def_module, def_proc, def_func, node_modules, commons)
        declared_by_node[nid] = _locally_declared(code)
        # This node's guarded-region liveness, from the CONFIGURED build's pinned
        # table (tools/scoping/macro-state.yaml), not the raw text - computed once
        # per node and consulted below wherever a USE/CALL/invoke/#include line
        # would otherwise become an edge.
        try:
            liveness_by_node[nid] = _line_liveness(path, macro_state)
        except RuntimeError as exc:
            _fail("cannot determine guarded-region liveness for '%s': %s" % (rel, exc))
        return nid

    for path in files:
        _add_node(path, os.path.relpath(path, source_root).replace(os.sep, "/"))

    # --- A header #include'd by an already-known unit is itself LIVE SOURCE (charter
    # section 6) - proven only by a RESOLVED #include (same directory as
    # the includer, the file genuinely exists, a recognized header extension), never guessed. A
    # fixed-point worklist so a newly-discovered header's own #includes are followed too, though no
    # header in this SOURCE nests today. An unresolved include (e.g. a build-generated *.intfb.h
    # interface block present nowhere in the tree) draws no edge, same as an unresolved USE/CALL. ---
    edges = set()
    worklist = list(nodes)
    i = 0
    while i < len(worklist):
        nid = worklist[i]
        i += 1
        src_dir = os.path.dirname(os.path.join(source_root, nodes[nid]))
        for lineno, ln in enumerate(raw_by_node[nid], start=1):
            mi = RE_INC.match(ln)
            if not mi:
                continue
            candidate = os.path.normpath(os.path.join(src_dir, mi.group(1)))
            if (not os.path.isfile(candidate)
                    or os.path.splitext(candidate)[1].lower() not in INCLUDE_NODE_EXTS):
                continue
            hrel = os.path.relpath(candidate, source_root).replace(os.sep, "/")
            if _excluded(hrel, excludes):
                continue
            # An #include inside a guarded-dead region (the pinned config compiles it
            # out) draws no edge - checked BEFORE _add_node so a header only reachable through a
            # dead #include is never pulled into the inventory by this include site either (a
            # live #include elsewhere, if one exists, still discovers it normally).
            if not _check_live(liveness_by_node[nid], lineno, nodes[nid], "#include \"%s\"" % mi.group(1)):
                continue
            hid = _add_node(candidate, hrel)
            if hid not in worklist:
                worklist.append(hid)
            edges.add((nid, hid, "include", "proven"))

    # --- Completeness, verified against git AFTER the full discovery above (primary units PLUS
    # include-discovered headers), so the comparison domain matches what this extractor actually
    # claims to inventory - not just the primary walk. A recognized-extension file (now including
    # INCLUDE_NODE_EXTS: a header only becomes a NODE when a live #include resolves it, but it is
    # still part of the accepted inventory class, so a git-tracked one this scan could not discover
    # - e.g. because the include site is here but the header itself vanished from disk, exactly the
    # P-001 file class - is truncation, not a smaller SOURCE) is checked with SET EQUALITY, not
    # one-way containment - both directions matter, and each fails closed with its own diagnostic:
    #   verified-complete:   tracked == discovered (both directions empty)
    #   verified-incomplete: EITHER git tracks a recognized file this scan did not discover (a
    #                        TRUNCATED working tree - the file exists in git but not on disk) OR
    #                        this scan discovered a recognized file git does NOT track (the untracked-file
    #                        shape - an extra source file existed on disk, was walked, and was absent
    #                        from git; a fresh clone/worktree would not have it, so a map built from
    #                        it would describe SOURCE outside the repository) -> ValueError, either
    #                        way, naming which direction and which files
    #   could-not-determine: not a git work tree, OR git tracks NOTHING recognized here at all (an
    #                        empty baseline is NOT proof of completeness - an untracked-but-complete
    #                        import and an untracked-and-truncated import are indistinguishable to
    #                        git, so neither may pass) -> ValueError
    all_recognized_exts = FORT_EXTS + GENERATOR_EXTS + INCLUDE_NODE_EXTS
    try:
        tracked = _git_tracked_recognized(source_root, excludes, all_recognized_exts)
    except _GitUnusable as exc:
        _fail("cannot run git to independently verify SOURCE completeness under '%s' (%s)"
             % (source_root, exc))
    if tracked is None:
        raise ValueError(
            "source root '%s' is not inside a git working tree - completeness cannot be "
            "independently verified, so a truncated checkout could look identical to a complete "
            "one; refusing to emit a claim this extractor cannot back" % source_root)
    if not tracked:
        raise ValueError(
            "source root '%s' is inside a git working tree, but git tracks ZERO recognized source "
            "file(s) (%s) there - an empty baseline cannot distinguish a complete import from a "
            "truncated one, so completeness cannot be established; git add the SOURCE first"
            % (source_root, ", ".join(sorted(all_recognized_exts))))
    discovered_rel = set(nodes.values())

    def _shown(paths):
        s = ", ".join(paths[:8])
        more = " ... (+%d more)" % (len(paths) - 8) if len(paths) > 8 else ""
        return s + more

    missing_from_disk = sorted(tracked - discovered_rel)
    untracked_on_disk = sorted(discovered_rel - tracked)
    if missing_from_disk:
        raise ValueError(
            "source root '%s' is missing %d git-tracked recognized source file(s) that this scan "
            "did not discover - refusing to emit a silently PARTIAL inventory (this is a TRUNCATED "
            "checkout/working tree, not a genuinely smaller SOURCE): %s"
            % (source_root, len(missing_from_disk), _shown(missing_from_disk)))
    if untracked_on_disk:
        raise ValueError(
            "source root '%s' has %d recognized source file(s) this scan discovered that git does "
            "NOT track (untracked-file: SOURCE present in this working tree but absent from the repository -"
            " a fresh clone/worktree checked out at the same commit would not have %s) - refusing to "
            "build a map that describes SOURCE outside the repository; git add -f it, or if it is "
            "genuinely out of scope, exclude it in tools/scoping/source-exclude.yaml: %s"
            % (source_root, len(untracked_on_disk),
               "it" if len(untracked_on_disk) == 1 else "them", _shown(untracked_on_disk)))

    # --- P-001: GENERATOR edges a line scan cannot resolve (a templated USE), asserted explicitly
    # by the project (tools/scoping/generator-edges.yaml) and cited there - never guessed here. A
    # named node that does not exist is a stale/broken assertion and must fail closed, not silently
    # vanish. ---
    for dependent, generator in generator_edges:
        if dependent not in nodes or generator not in nodes:
            raise ValueError(
                "generator-edges entry '%s -> %s' names a node the SOURCE inventory does not have "
                "(tools/scoping/generator-edges.yaml is stale - update it or the SOURCE tree)"
                % (dependent, generator))
        edges.add((dependent, generator, "generates", "proven"))

    module_dependents, include_dependents = {}, {}
    for nid in sorted(nodes):
        liveness = liveness_by_node[nid]
        for lineno, ln in enumerate(raw_by_node[nid], start=1):
            # A preprocessor directive line (`#define`, `#ifdef`, generator's own
            # `#:...`, ...) is NEVER Fortran statement text - a real compiler never sees
            # it as code. Scanning it anyway was a latent bug (surfaced while
            # building the guarded-edge fix): a `#define` whose replacement text
            # contains `call foo(...)` textually matches RE_CALL, asserting an edge
            # from a macro DEFINITION's replacement text, never an actual call site.
            # Skipped here, uniformly, for every directive line - `#include` is
            # unaffected (RE_INC is matched separately, further down, only for lines
            # it recognizes).
            if ln.lstrip().startswith("#"):
                continue
            mu = RE_USE.match(ln)
            if mu:
                tgt = mu.group(1).lower()
                if not (RE_USE_INTRINSIC.match(ln) or tgt in INTRINSIC_MODS):
                    owner = def_module.get(tgt)
                    if owner and owner != nid and _check_live(
                            liveness, lineno, nodes[nid], "USE %s" % tgt.upper()):
                        edges.add((nid, owner, "use", "proven"))
                        module_dependents.setdefault(tgt, set()).add(nid)
            mcall = RE_CALL.search(ln)
            if mcall:
                tgt = mcall.group(1).lower()
                if tgt not in INTRINSIC_SUBS:
                    owner = def_proc.get(tgt)
                    if owner and owner != nid and _check_live(
                            liveness, lineno, nodes[nid], "CALL %s" % tgt.upper()):
                        edges.add((nid, owner, "call", "proven"))
            # Bare FUNCTION invocations carry no `CALL`, so they are invisible to the scan above.
            for tgt in _function_call_targets(ln, def_func, declared_by_node.get(nid, ())):
                if tgt not in INTRINSIC_SUBS:
                    owner = def_proc.get(tgt)
                    if owner and owner != nid and _check_live(
                            liveness, lineno, nodes[nid], "%s(...)" % tgt.upper()):
                        edges.add((nid, owner, "call", "proven"))
    for a, b, kind, _conf in edges:
        if kind == "include":
            include_dependents.setdefault(b, set()).add(a)

    owned_surfaces, owned_nodes, shared_participants = [], set(), {}
    for mod, deps in sorted(module_dependents.items()):
        if len(deps) >= 2:
            owner = def_module.get(mod)
            owned_surfaces.append({"name": "module:" + mod, "owner": owner,
                                   "dependents": sorted(deps)})
            if owner:
                owned_nodes.add(owner)
    for hid, deps in sorted(include_dependents.items()):
        if len(deps) >= 2:
            owned_surfaces.append({"name": "include:" + nodes[hid], "owner": hid,
                                   "dependents": sorted(deps)})
            owned_nodes.add(hid)
    for blk, parts in sorted(commons.items()):
        if len(parts) >= 2:
            owned_surfaces.append({"name": "common:/%s/" % blk, "owner": None,
                                   "dependents": sorted(parts)})
            for nid in parts:
                shared_participants.setdefault(nid, []).append("common:/%s/" % blk)

    node_list = []
    for nid in sorted(nodes):
        role = "owned" if nid in owned_nodes else "unowned"
        reasons = set()
        if role == "owned":
            reasons.add("owned-foundation")
        for surf in shared_participants.get(nid, []):
            reasons.add("shared-surface:" + surf)
        node_list.append({"id": nid, "source": nodes[nid], "role": role,
                          "self_serve_eligible": len(reasons) == 0,
                          "guarded_reasons": sorted(reasons),
                          "coverage": "full",
                          "provides": sorted(node_modules.get(nid, []))})
    edge_list = [{"from": a, "to": b, "confidence": conf, "kind": kind}
                 for (a, b, kind, conf) in sorted(edges)]
    return {"schema_version": 1, "source_root": source_root,
            "nodes": node_list, "owned_surfaces": owned_surfaces, "edges": edge_list}


def _dump(model, yaml):
    class IndentDumper(yaml.Dumper):
        def increase_indent(self, flow=False, indentless=False):
            return super(IndentDumper, self).increase_indent(flow, False)
    return yaml.dump(model, Dumper=IndentDumper, sort_keys=False,
                     default_flow_style=False, indent=2, allow_unicode=True)


def _norm(m):
    """A comparison view (schema_version, nodes, owned_surfaces, edges), str-coerced and sorted
    so ordering and source_root spelling do not matter and a malformed value cannot crash it."""
    def node(n):
        return (str(n.get("id")), str(n.get("source")), str(n.get("role")),
                bool(n.get("self_serve_eligible")),
                tuple(sorted(str(r) for r in _as_list(n.get("guarded_reasons")))),
                str(n.get("coverage")),
                tuple(sorted(str(p) for p in _as_list(n.get("provides")))))
    def surf(s):
        return (str(s.get("name")), str(s.get("owner")),
                tuple(sorted(str(d) for d in _as_list(s.get("dependents")))))
    def edge(e):
        return (str(e.get("from")), str(e.get("to")), str(e.get("kind")), str(e.get("confidence")))
    return (m.get("schema_version"),
            sorted(node(n) for n in _as_list(m.get("nodes"))),
            sorted(surf(s) for s in _as_list(m.get("owned_surfaces"))),
            sorted(edge(e) for e in _as_list(m.get("edges"))))


def _validate_committed(m):
    """Schema violations of a committed map (beyond drift): unknown keys, bad enums, duplicate
    node ids, dangling edge targets. A generated map always passes; a hand-corrupted one is RED."""
    v = []
    for k in m:
        if k not in ALLOWED_TOP:
            v.append("unknown top-level key '%s'" % k)
    for req in ("schema_version", "source_root", "nodes", "edges"):
        if m.get(req) is None:
            v.append("missing required top-level key '%s'" % req)
    for key in ("nodes", "owned_surfaces", "edges"):
        val = m.get(key)
        if val is not None and (not isinstance(val, list) or any(not isinstance(x, dict) for x in val)):
            v.append("'%s' must be a list of mappings" % key)
    if v:
        return v
    ids = [str(n.get("id")) for n in _as_list(m.get("nodes"))]
    for d in sorted({x for x in ids if ids.count(x) > 1}):
        v.append("duplicate node id '%s'" % d)
    for n in _as_list(m.get("nodes")):
        if n.get("role") not in ALLOWED_ROLE:
            v.append("node '%s' has invalid role %r" % (n.get("id"), n.get("role")))
    idset = set(ids)
    for e in _as_list(m.get("edges")):
        if e.get("confidence") not in ALLOWED_CONF:
            v.append("edge %s->%s has invalid confidence %r"
                     % (e.get("from"), e.get("to"), e.get("confidence")))
        to = str(e.get("to"))
        if to not in idset:
            v.append("edge target '%s' is not a node (every edge resolves to an in-tree node)" % to)
    return v


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--source-root", default=None)
    ap.add_argument("--map", default=None)
    ap.add_argument("--generator-edges", default=None,
                    help="override tools/scoping/generator-edges.yaml (e.g. to check a fixture/test "
                         "tree that has no generator couplings of its own)")
    ap.add_argument("--macro-state", default=None,
                    help="YAML file of NAME -> {value: bool, reason: str} entries MERGED on top "
                         "of the pinned table (tools/scoping/macro-state.yaml) - test/fixture "
                         "use only; no real run against the pinned SOURCE needs this")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--owned-surfaces", action="store_true", dest="owned")
    args = ap.parse_args()

    orig = os.getcwd()
    root = _repo_root()
    try:
        os.chdir(root)
    except OSError:
        _fail("cannot enter repo root '%s'" % root)

    def resolve(p, default_rel):
        if p is None:
            return default_rel
        return p if os.path.isabs(p) else os.path.join(orig, p)

    map_path = resolve(args.map, os.path.join("tools", "scoping", "dependency-map.yaml"))
    generator_edges_path = resolve(args.generator_edges, GENERATOR_EDGES_REL)
    macro_state_path = resolve(args.macro_state, None)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot emit/parse the map (install pyyaml)")

    pinned = _load_pinned_macro_state(root, yaml)
    macro_state = dict(pinned)
    macro_state.update(_load_macro_state_override(macro_state_path, yaml))

    if args.check:
        if not os.path.isfile(map_path):
            if args.map is not None:
                _fail("--map '%s' is not a file" % args.map)
            print("check-depmap: no committed map at tools/scoping/dependency-map.yaml - "
                  "nothing to check (skipping).")
            sys.exit(0)
        try:
            with open(map_path, encoding="utf-8") as fh:
                committed = yaml.load(fh, Loader=_strict_loader(yaml))
        except (OSError, yaml.YAMLError) as exc:
            _fail("cannot read committed map '%s' (%s)" % (map_path, exc))
        if not isinstance(committed, dict):
            print("check-depmap: committed map '%s' is not a mapping." % map_path, file=sys.stderr)
            print("RESULT: RED (exit 1) - the committed map is malformed; regenerate it.", file=sys.stderr)
            sys.exit(1)
        schema_v = _validate_committed(committed)
        if schema_v:
            for msg in schema_v:
                print("  [FAIL] %s" % msg, file=sys.stderr)
            print("RESULT: RED (exit 1) - the committed map is malformed; regenerate it.", file=sys.stderr)
            sys.exit(1)
        # The source root to extract from: --source-root wins; else the committed map's. If both
        # are known and disagree, that is itself drift (a map pointing at the wrong tree).
        committed_src = committed.get("source_root")
        src = args.source_root if args.source_root is not None else committed_src
        if not src:
            _fail("committed map has no source_root and --source-root was not given")
        src_abs = src if os.path.isabs(src) else os.path.join(orig if args.source_root else root, src)
        if not os.path.isdir(src_abs):
            _fail("source root '%s' is not a directory" % src)
        if args.source_root is not None and committed_src and \
                os.path.normpath(str(committed_src)) != os.path.normpath(os.path.relpath(src_abs, root)):
            print("check-depmap: committed source_root '%s' does not match the checked tree '%s'."
                  % (committed_src, os.path.relpath(src_abs, root)), file=sys.stderr)
            print("RESULT: RED (exit 1) - the map was generated against a different source root.", file=sys.stderr)
            sys.exit(1)
        try:
            generated = extract(src_abs, _load_excludes(root, yaml),
                               _load_generator_edges(generator_edges_path, yaml), macro_state)
        except ValueError as exc:
            print("  [FAIL] %s" % exc, file=sys.stderr)
            print("RESULT: RED (exit 1) - regenerate the map from SOURCE.", file=sys.stderr)
            sys.exit(1)
        gen_sv, gen_nodes, gen_surf, gen_edges = _norm(generated)
        com_sv, com_nodes, com_surf, com_edges = _norm(committed)
        if (gen_sv, gen_nodes, gen_surf, gen_edges) == (com_sv, com_nodes, com_surf, com_edges):
            print("check-depmap: committed map matches SOURCE (%d node(s), %d edge(s)). RESULT: GREEN"
                  % (len(gen_nodes), len(gen_edges)))
            sys.exit(0)
        print("check-depmap: committed map DRIFTS from what SOURCE generates.", file=sys.stderr)
        if gen_nodes != com_nodes:
            gids = {n[0] for n in gen_nodes}
            cids = {n[0] for n in com_nodes}
            for x in sorted(gids - cids):
                print("  node '%s' is in SOURCE but not the committed map." % x, file=sys.stderr)
            for x in sorted(cids - gids):
                print("  committed node '%s' has no SOURCE file." % x, file=sys.stderr)
            if gids == cids:
                print("  a node's role/eligibility/coverage/provides differs from SOURCE.", file=sys.stderr)
        if gen_edges != com_edges:
            for e in sorted(set(gen_edges) - set(com_edges)):
                print("  edge %s is in SOURCE but not the committed map." % (e,), file=sys.stderr)
            for e in sorted(set(com_edges) - set(gen_edges)):
                print("  committed edge %s is not in SOURCE." % (e,), file=sys.stderr)
        if gen_surf != com_surf:
            print("  the owned-surface set differs from SOURCE.", file=sys.stderr)
        print("RESULT: RED (exit 1) - regenerate the map from SOURCE.", file=sys.stderr)
        sys.exit(1)

    src = resolve(args.source_root, "source")
    if not os.path.isdir(src):
        if args.source_root is not None:
            _fail("--source-root '%s' is not a directory" % args.source_root)
        print("extract-dependencies: no source tree at 'source/' - nothing to extract.", file=sys.stderr)
        sys.exit(0)
    try:
        model = extract(src, _load_excludes(root, yaml),
                        _load_generator_edges(generator_edges_path, yaml), macro_state)
    except ValueError as exc:
        _fail(str(exc))
    src_rel = os.path.relpath(src, root)
    model["source_root"] = src_rel
    if args.owned:
        # Owned-surface SOURCE paths (repo-relative), for check-claims --owned-surfaces. For a
        # shared common block (owner null) every participant path is emitted (no single owner).
        by_id = {str(n.get("id")): n.get("source") for n in _as_list(model["nodes"])}

        def relp(nid):
            s = by_id.get(nid)
            return None if s is None else (str(s) if src_rel == "." else src_rel + "/" + str(s))
        paths = set()
        for s in _as_list(model["owned_surfaces"]):
            if s.get("owner"):
                p = relp(str(s.get("owner")))
                if p:
                    paths.add(p)
            else:
                for d in _as_list(s.get("dependents")):
                    p = relp(str(d))
                    if p:
                        paths.add(p)
        for p in sorted(paths):
            print(p)
        sys.exit(0)
    sys.stdout.write(_dump(model, yaml))


if __name__ == "__main__":
    main()
