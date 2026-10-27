# SEEDED-BUG DEMONSTRATION - conformance/verify-anchors

- Date: 2026-10-27 - constants bound by name, anchor problems as notes. 2026-10-26 - a new
  detector: the value-comparing verifier replaced the text-based one, whose checks (a literal
  present on the cited line, an f-suffix rendering table, kind-alias lists, the dual-precision
  macro tables) no longer exist; their earlier demonstrations are history and are not repeated
  here.
- Detector: `tools/conformance/verify-anchors.sh` (product root, TARGET file scan, exit codes) over
  `tools/conformance/lib/anchor_driver.py`; the anchor rules in `lib/anchor_binding.py`, the value
  comparison in `lib/anchor_values.py`.
- Detector logic version: b5580a5 (the driver), with 2b9d64b..f802d5d (the probe and anchor-rule
  changes it relies on), 8543882..0c637eb (misdeclared anchors, temporaries, the closure compile),
  ab408a3..caeb204, 713a256..76c6ce3, ba0a48f..3282ccc and e07b67f (the review fixes below), with
  426c454, c4a3dac and c9e4cce..96a7f00 (constants of procedures and of INCLUDE files, and their
  review fixes), 6ac4794 and c3de805 (constants bound by name; anchor problems as notes).
- Failure class targeted: a TARGET constant whose value is not the SOURCE constant it renders (a
  wrong value; a precision slip, trap T1; a wrong type; a missing or extra element or field),
  whether a valid anchor binds it to that constant or its name does. An anchor that does not hold
  (a wrong line, a cut literal, a wrong grammar, an anchor bound to nothing, a runtime-helper anchor
  citing no trap row) and a constant no SOURCE name matches are reported as notes, never failures.
- Exit-code contract: 0 GREEN (every constant bound to a SOURCE constant - by a valid anchor or by
  name - equals its SOURCE value; run-time values reported UNVERIFIED); 1 RED (a value mismatch);
  2 UNRELIABLE (anything not judged: a missing tool or parser, an unresolved pin, an incomplete file
  scan, an unreadable file, a SOURCE file that does not parse or compile - one a constant is bound
  in by name included - a USEd module no file defines, a malformed `anchors.yaml`). Notes follow
  the result and never change the exit. With no TARGET code yet it skips (exit 0).

## Comparison logic

The rules - anchor grammar, binding rules 1-3, verdicts and their precedence - are those of the
case corpus, `seeded-bugs/verify-anchors/README.md`.

1. Configuration (workbench): `port/conventions/anchors.yaml` - `regimes` (the flags gfortran and
   clang add per precision build; absent file: one regime `default`; include directories made
   absolute, relative to the pinned SOURCE root in source_flags and to the product root in
   target_flags, an absolute one into the working SOURCE tree refused), `include` (TARGET include
   directories; default every product directory), `names` (TARGET name -> SOURCE name);
   `port/declared-helpers.yaml`; the trap rows of the pair table and the project conventions.
   Each is read as YAML data through the strict loader the tools share
   (`tools/coordination/_chisel_lib.py`, `text_loader`): a repeated key is an error, an alias
   reads as the value it names, every scalar is text; a file that cannot be read, or is not the
   expected shape, is UNRELIABLE, never an empty default.
2. SOURCE: the subtree `source_root` at the import commit `source_commit` (port/TRACE.yaml meta;
   `--ref`, `SOURCE_PIN_REF`, `SOURCE_SUBDIR` override), extracted with `git archive` - never the
   working tree; a link out of the tree is refused, never followed. Per regime, every cited file is
   preprocessed (`gfortran -cpp -E`, its line markers mapped back to SOURCE lines) and parsed with
   fparser in its own process: the modules it defines, the modules it USEs, its derived types, its
   declarations, its program units, and the statement at each cited line. A `MODULE <name>` line
   proposes the files that may define a USEd module and fparser confirms them, transitively; one of
   them that fparser cannot read makes that USE UNRELIABLE with its parse error, and so do two files
   defining one module in a regime or none. The modules some cited file USEs are compiled once per
   regime in dependency order (`gfortran -c -J`, `main` weakened) into a module directory and an
   archive given to the probes; a file that does not compile is reported once, its dependents name
   it. Each SOURCE file is read with its Fortran INCLUDE statements spliced in (the file looked up
   as gfortran looks it up: in the directory of the file compiled - for an INCLUDE line of an
   INCLUDE file too, never beside that file - then in the regime's -I directories, in order, never
   in the working directory; measured on gfortran 16; read as gfortran reads it, not preprocessed),
   each line keeping its own file and line. A cited file with no program unit (or none fparser reads
   alone) that SOURCE files INCLUDE - an INCLUDE line proposes them - directly, or through INCLUDE
   files of any suffix that INCLUDE it in turn - their parse confirms it - is read inside each
   scoping unit of them that INCLUDEs it - several in one file each apart: the cited constant is
   analysed in the including scope (a module's, or a procedure's as above) and probed by compiling
   the includer; includers whose including scope - its host module and its specification part as the
   parse spells it - is alike share one judgement, and a finding names its includer (`SOURCE
   params.h:2 N2 (in b.f, SB)`). A reading in which the TARGET constant does not pair is UNRELIABLE
   with the reason, unless the naming rule names its entity otherwise (the INCLUDE file read in
   another module: another constant's). One no SOURCE file INCLUDEs is UNRELIABLE.
3. TARGET, per regime and file: libclang's declarations - a .c file parsed on its own, a header
   inside the files that include it (on its own where none does, which then must be self-contained).
   Anchors are read only in comments - libclang's comment tokens of the whole file, every
   preprocessor branch included (the lexer reads the text, not the preprocessed unit), so anchor
   text in a string literal is none. Each `src:` anchor is bound by rules 1-3, of several names on
   its line to the one its cited statement pairs with (of several, the one whose SOURCE entity's own
   value holds the quote), else the nearest before it. An anchored declaration is paired with the
   SOURCE entity of its cited statement(s) whose name matches by the naming rule - the SOURCE name,
   or `<module>_<name>`; a component line pairs its TYPE (`<TYPE>_INIT`), a module variable line or
   the MODULE line its module (`<MODULE>_CTX_INIT`, or the module's name for a struct object),
   case-insensitive; `names` overrides it. When the name maps - by the rule or by `names` - to an
   entity a cited file declares in another statement, the anchor is a NOTE, invalid-anchor ("cites
   line N, which declares NB; NA is declared at line M"), and so is a name mapping to no entity or
   to more than one; the constant is then bound by name (6). A constant mapping to no entity that the
   initializer of a paired constant reaches (references, transitively, in the same file), citing
   that constant's statement, is a temporary of it when the constant's value depends on it - its
   initializer changed (to 2*(E)+1, then 2*(E)+3), the constant evaluated again by clang differs; a
   reference in an arm a constant condition never takes, or under sizeof, does not count: its anchor
   is held to the rules, and it takes that constant's verdict. A temporary whose one
   anchor quotes one literal and whose initializer is one literal (macros expanded) is also compared
   with that literal as the SOURCE compiles it, in the scope of the statement's module, its kind the
   SOURCE's (a mismatch is RED); any other temporary's own value is checked only through its
   constant's - a limit: a wrong expression the constant's value hides goes unseen. Then the anchor
   rules against the paired statement, TYPE or MODULE (`bound_problems` - a broken one a NOTE, the
   constant bound by name instead - fixed-form statements read
   over their column-6 continuations, and to column 72 - or the column a regime's
   `-ffixed-line-length-N` / `-none` gives - as fparser and the module scan read them, and as
   gfortran compiles them: card sequence numbers past it are not code); then the value,
   `judge_many`, one call per regime and SOURCE file, parallel. The pair carries the cited line: the
   SOURCE entity is the one that statement declares (or, for a DATA or PARAMETER statement, the
   declaration in its scope - or, with none, the constant the PARAMETER statement names, typed
   implicitly as gfortran types it: I-N integer, else real, an IMPLICIT statement's type, an array
   when a DIMENSION statement shapes it; under IMPLICIT NONE it does not compile, UNRELIABLE), never
   a namesake of another scope. A constant of a module procedure, an external procedure or a main
   program is compared through a probe procedure that repeats the procedure's USE and IMPLICIT
   statements and, in their order, the declarations the constant depends on (named constants, their
   kinds and bounds, local derived types), inside a probe module standing for its host: it USEs the
   host module (the copy without access specifiers, so a PRIVATE host constant is visible) and
   repeats the host's IMPLICIT statements, so the local declarations hide host names as in the
   procedure. A constant of an interface body, of an internal procedure (its host procedure's
   declarations are not reproduced), declared inside a BLOCK construct (nor are the BLOCK's), or
   depending on an argument or the result of its procedure (`KIND(dummy)`) is UNRELIABLE. A cited
   assignment or allocation is UNVERIFIED (run-time). On the TARGET side a block-scope constant is
   read by clang's evaluator; one it does not evaluate (an array, a struct) is printed by the probe,
   which repeats it after the declarations of its function it depends on (constant objects - const,
   with an initializer clang evaluates, so no statement changed them - enumerations, types) in their
   order; one depending on any other object, of its function or of the file (a mutable global),
   which a statement may have changed, is UNRELIABLE - for a scalar clang does not evaluate too; one
   computed from a parameter of its function, for a SOURCE compile-time constant, is UNRELIABLE -
   UNVERIFIED is only for values the SOURCE sets at run time. The SOURCE probe compiles a copy of
   the cited file without the access specifiers of the probed module (found in the parse tree), so
   PRIVATE constants are compared, the units after that module left out and the other modules
   untouched, so no name the copy makes public can clash; it USEs only the names it needs; a
   statement the copy rebuilds is wrapped within its form's limits (fixed form filled to column 72,
   free form continued with `&` at both ends of a break), so the copy compiles with the file's own
   flags - no long-line flag is given to any SOURCE compile. A type renamed by a USE is resolved.
4. Anchors bound to no constant: a constant anchor on a statement in a function is UNVERIFIED (a
   run-time value) once its literal holds, but a NOTE when it cites a value the SOURCE gives at
   compile time (a PARAMETER, an initializer, DATA, a component default: a SOURCE constant renders
   as a declared TARGET constant); one bound to no declaration in any regime is a NOTE, saying so
   when no regime builds its branch (one under `#if 0` is never built: no regime to add); a routine
   anchor citing a missing line, or a module header anchor not on a MODULE statement of that name,
   is a NOTE. A runtime-helper anchor outside a declared helper file, or citing no trap row, is a
   NOTE.
5. Comparable constants: every comparable TARGET constant - an object of numbers (every leaf a
   number or bool, a pointer only as an aggregate member) with an initializer at file scope, or at
   block scope `const`/`static` with a numeric literal in it; an enumerator with an explicit value;
   an object-like macro whose body holds a numeric literal or is a brace list, or which clang
   evaluates to a constant number or bool the product defines - its body names `true`, `false`, a
   product enumerator or object, or a product macro holding a literal, a brace list or
   (transitively) one of these, not only C-library macros, keywords or sizeof (reserved identifiers
   such as feature-test macros aside) - is bound to a SOURCE constant: by its anchor when one holds,
   else by name (6); a constant of a declared helper file carrying its own runtime-helper anchor is
   not bound. The TARGET files are every file or link to a file named *.c or *.h, any case,
   `tests/` and `.git` pruned
   (`anchor_binding.target_files`, shared with the migration script); a link to a directory is
   followed when the directory is inside the product tree, each directory read once by its real
   path, and one leading out of the tree makes the scan incomplete - UNRELIABLE, since it could
   reach any tree. A product file a TARGET file includes outside that set (a `.inc` fragment, a
   header under `tests/`) is read inside each TARGET file that includes it, in each regime it does,
   and so is a TARGET header: one instance per rendering - the including files giving the file the
   same fingerprint (what the compiler sees: its lines macro-expanded by `clang -E`, the canonical
   types of its declarations, its macros with every definition they reach, and the same of each
   product file its constants refer to; none, and no sharing, when a constant refers to a value
   from outside the product) share one, so an ordinary header included by many files is judged once,
   and one stamped into a double and a float unit as both: its declarations from that file's parse,
   so it need not be self-contained, its constants bound by the same rules, its values probed
   through that file. One a TARGET file includes that the verifier still does not read is
   UNRELIABLE.
6. Binding by name: a comparable constant with no anchor, or whose anchor breaks a rule, is bound to
   the one SOURCE entity the naming rule (or `names`) gives it in the SOURCE files its file maps to -
   those its anchors name (a `/* src:` comment of no anchor form by its first word), and those a
   `port/TRACE.yaml` row lists with it (`files`, `source` under each `target`; a Fortran file, or one
   a SOURCE file INCLUDEs) - each indexed like a cited file, its USE closure compiled. The candidates
   are the entities of those files' declarations, PARAMETER, TYPE and MODULE statements, one per
   name and scope (a declaration and its PARAMETER statement are one entity, at the statement giving
   the value): types, modules, named constants and initialized variables, and module variables -
   never a declaration of an interface body, nor a procedure's variable without a value. Of several,
   the one every hint names - the file of a failed anchor, and the file, module or literal of an
   anchor without a line number (`/* src: <path> */`, `= <literal>`, `(module <NAME>)`) bound to the
   constant - is taken. Exactly one: an anchor citing the statement giving it its value is written
   for it and the pair judged like any anchored one, its SOURCE shown `(by name)`; none or several:
   a NOTE, "not checked: no unique SOURCE constant named X"; a file it maps to that cannot be read:
   UNRELIABLE. A hint the bound entity does not fit is a NOTE, and so is a TRACE row or an anchor
   without a line number naming a file the pin does not hold.
7. Output: one line per finding, `<RED|UNRELIABLE|UNVERIFIED> <file>:<line> <name> [<regimes>]:
   <verdict> - <detail>` (`<file>:<line> (in <unit>)` for a fragment, naming the file it was read
   inside), then `SUMMARY [<regime>]: N verified, N unverified, N red, N unreliable`, the `RESULT`,
   and `NOTES: N - ...` with one `NOTE` line each, in the same form. Exit 1 on any RED, else 2 on any
   UNRELIABLE, else 0 - notes never change it; a SIGTERM stops it UNRELIABLE
   at once - each worker leads a process group with the compilers it runs, sent TERM on the stop
   and KILL a second later, and the work not yet started is cancelled - and removes its scratch
   directory, which is the compilers' TMPDIR: nothing is left in the caller's.

Probes link without the routines they never reach: every function and object in its own section
(`-ffunction-sections -fdata-sections`), linked with `--gc-sections`, so a module procedure that
calls an external routine outside the closure, or a TARGET `.c` file calling functions defined
elsewhere, still links. Measured with gfortran 16 and clang 23, each linker forced through a
regime's flags (`-fuse-ld=bfd`, `gold`, `lld` in both `source_flags` and `target_flags`), on the
test's module whose procedure calls an external routine and a TARGET function calling an undefined
one: with `--gc-sections` both pairs pass under all three linkers; without it every probe fails to
link (`undefined reference to ext_routine_`) and both pairs are UNRELIABLE under all three.
`-Wl,--unresolved-symbols=ignore-all` was rejected: with GNU ld the probe links but does not start
("unexpected PLT reloc type 0x00"). A TARGET file defining `main` is included with `main` renamed;
a SOURCE file holding a PROGRAM beside its modules is compiled to an object whose `main` and
`MAIN__` objcopy weakens, so the probe's own PROGRAM runs (GNU ld, gold and lld alike).

## Seeded defects and verdicts

`tools/tests/test-verify-anchors.sh` builds a throwaway workbench git repo (the SOURCE imported in
a commit recorded as `meta.source_commit`) and one product tree per case:

| Defect (seeded in the faithful product) | Verdict | Finding line |
|---|---|---|
| `mod_a_g = 9.80` for `G = 9.81_DP` | RED, exit 1 | `RED src/mod_a.c:2 mod_a_g [default]: mismatch value - SOURCE src/mod_a.F90:5 G` |
| `9.81f` for a double | RED, exit 1 | `... mismatch kind - SOURCE src/mod_a.F90:5 G` |
| `{1.0, 2.5}` for a 3-element array | RED, exit 1 | `... mod_a_tab [default]: mismatch shape at [2] - ...` |
| the anchor cites the next line (`:6 = 9.81_DP`) | NOTE, the constant passes by name: exit 0 | `NOTE src/mod_a.c:2 mod_a_g [default]: invalid-anchor - ...: the literal-as-read is not on src/mod_a.F90:6` |
| ... with `mod_a_g = 9.80` | RED by name, exit 1 | `RED src/mod_a.c:2 mod_a_g [default]: mismatch value - SOURCE src/mod_a.F90:5 G (by name)` |
| an unanchored `#define MOD_A_NLEV 61` for `NLEV = 60` (with 60: verified, no note) | RED by name, exit 1 | `RED src/mod_a.c:3 MOD_A_NLEV [default]: mismatch value - SOURCE src/mod_a.F90:6 NLEV (by name)` |
| `enum { mod_a_nlev = 61 }; /* src: src/mod_a.F90 */`, an anchor without a line number | RED by name, exit 1 | `... mod_a_nlev [default]: mismatch value - SOURCE src/mod_a.F90:6 NLEV (by name)` |
| `enum { mod_b_nq = 5 };` in a file a TRACE row lists with `src/mod_b.F90` | RED by name, exit 1 | `... mod_b_nq [default]: mismatch value - SOURCE src/mod_b.F90:5 NQ (by name)` |
| `enum { nb = 4 };` in a file two TRACE rows list, both SOURCE files declaring NB | NOTE, exit 0 | `NOTE src/both.c:1 nb [default]: not checked: no unique SOURCE constant named nb - several: ...`; with `/* src: src/pairs.F90 (module PAIRS) */` it passes |
| an unanchored constant in a file a TRACE row lists with a SOURCE file fparser cannot parse | UNRELIABLE, exit 2 | `... SOURCE src/broken.F90 cannot be read in regime default: ... - mod_broken_k is bound by name, ...` |
| an unanchored aggregate in a file that maps to no SOURCE file | NOTE, exit 0 | `NOTE src/log.c:1 log_ctx [default]: not checked: no unique SOURCE constant named log_ctx - src/log.c maps to no SOURCE file ...` |
| `real_t a = 0.1f` for `0.1_WP`, regimes dp and sp | RED in dp only, exit 1 | `RED src/mod_a.c:2 mod_a_a [dp]: mismatch kind - ...`; `SUMMARY [sp]: 1 verified ...` |
| a `names` entry pairing a constant with an entity another statement declares | NOTE, then RED by name, exit 1 | `NOTE ... invalid-anchor - src/mod_a.c:1: /* src: src/mod_a.F90:5 = 9.81_DP */ cites line 5, which declares G; NLEV is declared at line 6` and `RED ... mismatch type - SOURCE src/mod_a.F90:6 NLEV (by name)` |
| an anchor citing a neighbour's line that holds the same literal (`mod_b_nq` citing NB's) | NOTE, the constant passes by name: exit 0 | `NOTE ... mod_b_nq [default]: invalid-anchor - ... cites line 3, which declares NB; NQ is declared at line 5` |
| ... with `mod_b_nq = 5` | RED by name, exit 1 | `RED src/mod_b.c:1 mod_b_nq [default]: mismatch value - SOURCE src/mod_b.F90:5 NQ (by name)` |
| a wrong temporary of a statement split over three constants | RED, exit 1 | `RED src/mod_b.c:1 mod_b_r [default]: temporary of mod_b_r4 (line 3): mismatch value - SOURCE src/mod_b.F90:6 R4` |
| a temporary whose anchor quotes a literal not on its line | NOTE, exit 0 | `NOTE ... mod_b_r2 [default]: invalid-anchor - ...: the literal-as-read is not on src/mod_b.F90:6` |
| a `names` entry naming an entity no SOURCE file declares | NOTE, exit 0 | `NOTE ... port/conventions/anchors.yaml pairs mod_a_gravity with GRAVITY, which no cited SOURCE file declares ...` |
| a constant citing a statement, not reached from the constant that pairs with it | NOTE, exit 0 | `NOTE ... mod_b_half [default]: no SOURCE entity of the cited statement(s) is named mod_b_half ...` |
| a runtime-helper anchor citing an invented trap row | NOTE, exit 0 | `NOTE src/f_runtime.h:1: invalid-anchor - the runtime-helper anchor cites trap T99, ...` |
| a runtime-helper anchor outside a declared helper file | NOTE, exit 0 | `NOTE ... a runtime-helper anchor is valid only in a file listed in port/declared-helpers.yaml ...` |
| an anchor on a run-time assignment in a function | UNVERIFIED, exit 0 | `UNVERIFIED src/mod_a.c:5 [default]: not-comparable - the anchor is on a statement, ...` |
| an anchor citing a SOURCE file fparser cannot parse | UNRELIABLE, exit 2 | `... SOURCE src/broken.F90 cannot be read in regime default: fparser cannot parse ...` |
| an anchor citing a module that USEs a module no file defines | UNRELIABLE, exit 2 | `... module MOD_MISSING, USEd by src/lonely.F90, is defined by no SOURCE file` |
| `regimes: [dp, sp]` in anchors.yaml | UNRELIABLE, exit 2 | `... anchors.yaml is malformed: regimes is not a non-empty mapping` |
| a TARGET name the naming rule does not give | NOTE, exit 0 | `NOTE ... mod_a_gravity [default]: no SOURCE entity of the cited statement(s) is named mod_a_gravity ...`, then `not checked` |
| a pin that does not resolve | UNRELIABLE, exit 2 | `SOURCE pin ref 'no-such-ref' does not resolve ...` |
| a wired product root that does not exist | UNRELIABLE, exit 2 | `... is not present beside the workbench ...` |
| a port/product.yaml the strict reader refuses (`checkout:` repeated) | UNRELIABLE, exit 2 | `port/product.yaml cannot be read (the reason is above), so the product checkout is unknown` |

and these must stay GREEN: the faithful product (a scalar, an enumerator, an array quoted by its
whole right-hand side, a brace-list macro of a derived type defined in another SOURCE file, a
working-precision constant, a module variable of a module whose procedure calls an external
routine, a declared helper file whose constants carry runtime-helper anchors: `7 verified`); the derived-type
constant alone (`1 verified`: the USE closure compiled); a module variable of the module calling
an external routine next to a TARGET function calling an undefined one (`1 verified`: both link);
the same names case once `names` pairs it; a statement split over three constants
(`3 verified`: two temporaries through the third); the faithful product with the working-tree
SOURCE shifted by a line after the import (anchors read at the pin); constants bound by name with
no anchor, an anchor without a line number, or a TRACE row (verified, no note); every anchor
problem above with a right value (notes only); no TARGET code yet (skip).

### Binding by name and anchor notes (6ac4794, c3de805)

Each assertion's red run: the test as it stands (162 assertions), against the driver before the
change (4030926), and against the driver with one part of the change undone.

| Driver | Assertions failing | What goes unseen or wrong |
|---|---|---|
| before the change (4030926) | 49 | every anchor problem is RED or UNRELIABLE; an unanchored constant is RED coverage, never compared - `#define MOD_A_NLEV 61` is RED for its missing comment, not for its value, and with 60 it is RED too |
| binding by name disabled (`bind_by_name` notes every constant) | 29 | the name-bound mismatches go GREEN: `MOD_A_NLEV 61`, `mod_a_g = 9.80` under a wrong line, `mod_b_nq = 5` under a neighbour's line, the TRACE-listed `mod_b_nq = 5`, the line-less `mod_a_nlev = 61`; the `names` entry for NLEV is no longer RED |
| anchor problems RED again (`note` emits RED) | 14 | a comment blocks the port again: every anchor problem, the wrong-grammar and line-less file notes included |
| no fallback after an anchor problem | 7 | a wrong value under a wrong line, or under a neighbour's line, goes GREEN |
| anchors without a line number not read | 8 | their constants are never bound; a hint naming one of two namesakes is lost |
| TRACE rows ignored | 7 | a file whose only map is TRACE binds nothing; its wrong value goes GREEN |

The corpus at product level against the same drivers: before the change, binding by name disabled,
anchor problems RED again and no fallback make 45, 45, 35 and 35 of its 484 judgments differ - each
time the invalid-anchor cases, whose target must be bound by name instead of failing.

The tables below record earlier fixes, each against the test of its time; an anchor problem they
show RED or UNRELIABLE is a NOTE since c3de805, and a "RED coverage" there is a constant bound by
name since 6ac4794.

### Seeded defects of the independent review (each fix's red run: the test as it stands, against
the driver before the fix)

| Defect | Before the fix | After | Assertions red before |
|---|---|---|---|
| an interface body's dummy N before the module's PARAMETER N; `scopes_n = 5` | UNVERIFIED (then the value passed unseen) | the cited N: pass, and RED value at 5 | 2 |
| a procedure's own PARAMETER C (2.0) anchored, a module C (1.0) beside it | pass (compared with the module's C) | UNRELIABLE: a procedure-local constant | 1 |
| a USEd module's current file fparser cannot parse, a stale copy under legacy/ | GREEN (the stale copy compiled) | UNRELIABLE with the parse error | 2 |
| a fixed-form declaration continued in column 6, anchored on its second line | RED (outside the statement) | pass | 1 |
| PRIVATE constants (a PRIVATE default with a PUBLIC exception, a PRIVATE attribute) | UNRELIABLE (the probe cannot USE them) | compared: pass, RED value when wrong | 2 |
| a constant of a type renamed by a USE (`POINT => PT`) | UNRELIABLE | pass | 1 |
| a module and a PROGRAM in one file, cited and USEd | UNRELIABLE (two mains) | pass | 1 |
| `return m * 9.81;` anchored to the PARAMETER G | UNVERIFIED | RED invalid-anchor | 1 |
| a helper file with one runtime-helper anchor and an unanchored constant | GREEN | RED coverage | 1 |
| a format string, a FILE pointer, a function table, unanchored | RED coverage | not constants: GREEN | 1 |
| `#define DEBUG false`, `#define TWICE (nlev + nlev)`, `#define PI M_PI`, unanchored | GREEN | RED coverage | 3 |
| a `.H` header, a link to a `.c` file, an included `.inc` fragment | GREEN (none read) | read; the fragment refused, UNRELIABLE | 3 |
| a relative `-I` in source_flags; an absolute one into the working SOURCE tree | UNRELIABLE; RED (the working tree's header) | the pin's header: pass; refused, UNRELIABLE | 2 |
| `enum { nb = 4, /* src */ nq = 4 /* src */ };` | RED (both anchors to nb) | pass | 1 |
| an anchor in an `#ifdef` branch no regime builds | RED (binds to nothing) | UNRELIABLE: no regime builds this branch | 1 |
| an anchor citing a Fortran INCLUDE file | UNRELIABLE, "no entity is named" | UNRELIABLE, "holds no program unit (an INCLUDE file?)" | 1 |
| a USE chain whose first module does not compile | the compiler's error in every pair's message | named once, its dependents point at it | 2 |
| a pin that does not resolve; a link to an absolute path in the SOURCE | git's reason hidden; a traceback | quoted; UNRELIABLE, the path named | 2 |
| SIGTERM to the wrapper during a run | exit 143, scratch left behind | UNRELIABLE (exit 2), scratch removed | 1 |
| anchor text in a string literal, at file scope and in a statement | UNRELIABLE (the string's pointer paired) and RED (a statement anchor citing a constant) | no anchor: GREEN | 1 |
| an included `.inc` fragment with a wrong value; one that is not self-contained; with an unanchored constant | UNRELIABLE (refused) | RED value; pass; RED coverage | 3 |
| a fragment included after `#define REAL double` in one unit and `#define REAL float` in another | GREEN (judged in the first unit only) | RED kind in the float unit, pass in the double one | 2 |
| a fixed-form file with card sequence numbers in columns 73-80, on every line and on one | UNRELIABLE (fparser reads them) and RED (`1.5D0` read as `1.5D000000040`) | pass | 1 |
| a link to a directory inside the product (to one reached only through it), a link back up, a link to a directory outside | GREEN (no directory link followed) | the linked file read once: RED coverage; the outside link UNRELIABLE | 3 |
| one file: a PRIVATE module, a later module USEing it with a namesake of its private N, a third with its own PRIVATE | UNRELIABLE (the copy stripped every module: N clashes) | each module's constants compared: pass | 1 |
| `PARAMETER (NMAX = 100, PI = 3.14159)` with no type declaration; under `IMPLICIT DOUBLE PRECISION (A-H, O-Z)` with a DIMENSION array; PI rendered double | UNRELIABLE, "the cited statement declares no NMAX" | pass; pass; RED kind | 2 |
| `enum { nb = 4, nq = 4 }; /* src: ...:3 */ /* src: ...:5 */`, both anchors after both names | RED (both bound to nq) | each bound to the name its cited statement pairs with: pass | 1 |
| an anchor under `#if 0` | UNRELIABLE, "add the regime that builds it" | UNRELIABLE, "this branch is never built (#if 0)": remove the dead code or its anchor | 1 |
| `t = 123.0` cited as part of a statement whose constant `g = 1 ? 81.0 : t` renders it | t verified through g (GREEN) | UNRELIABLE: g's value does not change when t's does | 1 |
| unanchored macros aliasing the C library: `EXIT_SUCCESS`, `sizeof(double)`, `DBL_EPSILON`, `HUGE_VAL`, `CHAR_BIT`, `M_PI` | RED coverage | not constants of the product: GREEN (a macro naming a product macro, or `true`, still RED) | 1 |
| SIGTERM one second into a run of 200 files | UNRELIABLE after 9.7 s (the running judge task, and every queued one, finished first) | UNRELIABLE within 0.1 s, no scratch left | 1 |
| unanchored `#define NC (NB + NLEV)` and `#define NLEV_ALIAS NLEV` over anchored literal macros | GREEN (38caec9 stopped counting them) | RED coverage | 2 |
| a fixed-form constant past column 72 in a project built with `-ffixed-line-length-132` or `-none` | RED invalid-anchor (the line cut at 72) | pass | 2 |
| `= 1.0/3.0` quoting ONE3's value in `PARAMETER (NB = 4, ONE3 = 1.0/3.0)` | RED invalid-anchor (no right-hand side found in a PARAMETER statement) | the entity's own value: pass | 1 |
| `enum { nb = 4, nlev = 60 };` with two anchors quoting `4` and `60` of `INTEGER, PARAMETER :: NB = 4, NLEV = 60` | RED (both bound to nlev) | each bound to the name whose value it quotes: pass | 1 |
| a template header (`#ifndef REAL` / `#define REAL double`) included by a file defining `REAL float` first | GREEN (a header read on its own only) | RED kind in the float unit, pass in the other; a header three files compile alike judged once | 1 |
| temporary `t = 6` quoting `4` of `N = MOD(4, 2) + 4`, its constant `t % 2 + 4` | GREEN (t verified through its constant, whose value is right) | RED: its own value is not the literal it quotes | 1 |
| SIGTERM while a compiler holds a temporary file | `cc*.fii`, `cc*.s` left in TMPDIR | nothing left | 1 |
| a header with `{.x = CONST(0.1), .n = 3}` and `CONST(0.1) + 1.0 * I`, included after `#define CONST(x) x` and `x##f` | GREEN (one instance: the fingerprint held evaluated values, None for both) | RED kind at .x and RED kind in the float unit | 2 |

The migration script reads the verifier's file set (a hidden directory too): its test failed 2
assertions before. It finds anchors only in comments too, so anchor text in a string literal is not
rewritten: its test failed 3 assertions before (the extra rewrite, the changed string, the verifier
UNRELIABLE afterwards). A file read for its derived types is parsed once per worker process, not once
per judge_many call: `test-anchor-values.sh` counted 2 parses over two calls before, 1 after.

### Workbench files read as YAML data

`port/TRACE.yaml` (its `meta.source_commit` and `meta.source_root`, the pin defaults),
`port/declared-helpers.yaml` (a bare list of basenames, the form ports hold, or a mapping whose
`helpers:` key lists them) and `port/conventions/anchors.yaml` are read through the shared strict
loader, as `tools/coordination/yaml_get.py` reads them for the shell tools; `meta` must be a
mapping and each of its two values a single-line scalar without a control character, as
`yaml_get` reads one. The verifier reads no other part of TRACE (no translated stems: a helper is
declared only by `declared-helpers.yaml`). Fixtures in `tools/tests/test-verify-anchors.sh` ("the
workbench files, read as YAML data"):

| Input | Before (PyYAML `safe_load`) | Strict loader |
|---|---|---|
| `source_commit: "<pin>"   # comment` | the pin: GREEN | the pin: GREEN |
| a `source_commit: deadbeef` under another key before `meta:` | meta's pin: GREEN | meta's pin: GREEN |
| `source_commit: *p`, an alias of the pin | the pin: GREEN | the pin: GREEN |
| `source_commit: 0042`, a tag of digits | read as the number 34: UNRELIABLE | the tag: GREEN |
| `meta.source_commit` repeated | the last copy used: GREEN | UNRELIABLE, duplicate key |
| `meta` a list | read as no meta: UNRELIABLE, "no SOURCE pin" | UNRELIABLE, meta is not a mapping |
| `meta.source_commit` a list | its Python text as the ref: UNRELIABLE | UNRELIABLE, not a single-line scalar |
| a TRACE that is not YAML | UNRELIABLE | UNRELIABLE |
| `- "f_runtime.h"` (quoted), a bare list | declared: GREEN | declared: GREEN |
| `helpers:` repeated | the last list read: RED | UNRELIABLE, duplicate key |
| a bare list holding `- name: other.h` | UNRELIABLE, malformed | UNRELIABLE, malformed |
| `- "old f_runtime.h"`, a name holding a space | one name, `f_runtime.h` undeclared: RED | the same |
| `regimes:` repeated in anchors.yaml | the last mapping used: GREEN | UNRELIABLE, duplicate key |

Six of these assertions fail against the `safe_load` driver and pass against the strict loader;
the others hold both ways and guard the reader.

### Constants of procedures and INCLUDE files

Each assertion's red run: the test as it stands, against the driver before the change.

| Defect | Before | After | Assertions red before |
|---|---|---|---|
| a procedure's own PARAMETER C (2.0D0) beside a module C (1.0D0), rendered 2.0 and 1.0 | UNRELIABLE, both | pass; RED value - compared with the procedure's C, never the module's | 2 |
| a module procedure's PARAMETERs - one built from a PRIVATE host constant and the local namesake - an external subroutine's implicitly typed ones, a main program's | UNRELIABLE | pass | 1 |
| the module procedure's constant rendered float, or 2.4 for 2.5 | UNRELIABLE | RED kind; RED value | 2 |
| `KIND(K)` of an argument K; an internal procedure's constant; an interface body's | UNRELIABLE, "a procedure-local constant" | UNRELIABLE, each saying why | 3 |
| a constant of an INCLUDE file a module INCLUDEs | UNRELIABLE, "holds no program unit" | pass | 1 |
| F77 INCLUDE files in external subroutines: one two subroutines read alike; `N2 = 2*N` with N 4 in two includers and 5 in a third, rendered 8 | UNRELIABLE | judged once: pass; RED value in the third (`(in src/incc.f)`), pass in the others | 3 |
| an INCLUDE file no SOURCE file INCLUDEs | UNRELIABLE, "holds no program unit (an INCLUDE file?)" | UNRELIABLE, "holds no program unit, and no SOURCE file INCLUDEs it" | 1 |
| `INTEGER, PARAMETER :: K = 2` inside a BLOCK, a module K = 1, rendered 1 | pass (compared with the module's K) | UNRELIABLE, "declared inside a BLOCK construct" | 1 |
| `static const ivec sq = {1, 4, 9}` and `static const lt l0 = {5}` in a function (local typedefs), for SQ = [(I*I, I = 1, 3)] and L0 = LT(5); `{1, 4, 8}`, `{6}`; `{1, 4, nine}` from a parameter | UNVERIFIED, exit 0 | pass; RED value at [2] and at .m; UNRELIABLE | 4 |
| `int nine = 9; nine = nine + 1;` (sq gets 10) and `int nine; nine = 9;` before `const int sq[3] = {1, 4, nine}`; `const int nine = k9;` | GREEN (the declaration 9 copied); RED (the copy uninitialised) | UNRELIABLE, both: "depends on nine, which is not a constant"; the const chain compared | 2 |
| `int blocks_k = 1;` a function sets, and `const int sq[3] = {1, 4, 8 + blocks_k}`, `const int np = 6 + blocks_k` in another; at file scope `static const int sq[3] = {1, 4, 8 + blocks_k}` | GREEN, both (the global's initial value read through the #include) | UNRELIABLE, both: "depends on blocks_k, which is not a constant"; at file scope C does not compile it: UNRELIABLE | 2 |
| `PARAMETER (XK = 2.5)` INCLUDEd by one subroutine of a file and two of another, rendered 2.5f | GREEN (the other file, where XK does not pair, skipped) | UNRELIABLE, with the reason, `(in src/ckb.f)` | 1 |
| one file whose two subroutines INCLUDE one file (`PARAMETER (NMAX = 100)`, `GRAV = 9.81D0`) | UNRELIABLE, "holds more than one statement" | each subroutine a reading: judged once, pass; XK read INTEGER in two subroutines of a file RED there `(in src/ckb.f, SKB1)` | 2 |
| a constant of an INCLUDE file a module reaches through another INCLUDE file | UNRELIABLE, "no SOURCE file INCLUDEs it" (program files searched for direct INCLUDE lines only) | pass | 1 |
| `ninner.inc` beside the module's file (NIN = 22) and beside the INCLUDE file holding its INCLUDE line (NIN = 11) | 22 UNRELIABLE; the copy beside the INCLUDE file analysed, RED against the compiled 22 | 22: pass; the other copy: UNRELIABLE, no SOURCE file INCLUDEs it | 2 |

## Red proof (the test fails against broken drivers)

Each mutation applied to a copy of the tools, then `bash tools/tests/test-verify-anchors.sh` as it
stands (162 assertions). The mutations of binding by name and of anchor notes are in "Binding by
name and anchor notes" above.

| Mutation | Assertions failing |
|---|---|
| pairing disabled (`pair_entity` returns UNRELIABLE) | 112: every anchored pair and every constant bound by name becomes UNRELIABLE, their pass and RED cases alike |
| `--gc-sections` dropped from the probes | 52: every pair whose SOURCE probe links a module with a procedure calling an external routine - MOD_B's, and MOD_A's through its USE of MOD_B, anchored or bound by name - and the TARGET function calling an undefined one, become UNRELIABLE |
| the USE closure not compiled | 41: every pair of a module USEing another - MOD_A's, anchored or bound by name, a derived type of another file, the USE chain - becomes UNRELIABLE, and the module that does not compile is never named |
| only the first regime judged | 1: no `SUMMARY [sp]` |
| the SOURCE read from the working tree | 3: the working tree's header decides (RED), a link out of the SOURCE tree is followed, and the line-shifted SOURCE turns valid anchors into notes |
| temporaries never found | 4: the split statement's temporaries are notes, not checked, and a temporary whose wrong literal its constant's value hides goes GREEN |
| the SOURCE entity found by name, not by the cited line | 5: a procedure's, an interface body's and a BLOCK's constants are compared with their module's namesakes - the procedure's 2.0 is RED against the module's 1.0, the BLOCK's K passes |
| the access specifiers kept in the probe's copy | 5: the PRIVATE constants, a module's and a host module's, are UNRELIABLE |
| `main` not weakened | 2: the modules and procedures beside a PROGRAM are UNRELIABLE |
| included files not read inside their includers | 9: the `.inc` fragments are UNRELIABLE, their wrong value and stamped float copy unseen; the template header's float rendering goes GREEN, and the header two units compile differently is UNRELIABLE |
| anchors read in the whole text, not only in comments | 1: anchor text in a string literal is read as an anchor, and noted |
| constants of procedures not probed (`_local_context` refuses) | 22: every procedure's constant is UNRELIABLE, its pass and RED cases alike - a module procedure's, an external subroutine's, a main program's, a function's arrays and structs, the subroutines' INCLUDE files - and the reasons an argument, an internal procedure, an interface body or a BLOCK give are lost |
| INCLUDE files not read inside their includers | 9: the INCLUDE files' constants are UNRELIABLE, the includer-dependent RED unseen |
| block-scope arrays and structs not repeated in the probe | 9: they are UNRELIABLE, their pass and RED cases alike, and the reasons a dependency on a parameter, a changed variable or a mutable global gives are lost |
| unanchored objects and enumerators not bound by name (coverage, which this replaces, no longer exists) | 18: they are never compared - the TRACE-listed and line-less mismatches go GREEN, the SOURCE file that cannot be read goes unreported, and their not-checked notes vanish |
| `declared_elsewhere` finds nothing (a name mapping to another statement's entity; no longer UNRELIABLE, so it cannot be "left UNRELIABLE") | 2: the same-literal neighbour and the `names` entry are noted as naming no entity, not as citing another statement; their verdicts by name are unchanged |

Before 8543882 and 296b2f5 the test failed 3 and 2 assertions against the then driver: the
same-literal neighbour and both `names` cases, then the two temporaries cases.

## Green proof

`bash tools/tests/test-verify-anchors.sh`: all 162 assertions ok, exit 0, with the pip libclang
18.1.1 of `uv.lock` (the CI's), clang 23.1.3 and GNU Fortran 16.2.1. `bash
tools/tests/test-anchor-values.sh` (the corpus, judged pair by pair), `bash
tools/tests/test-verify-anchors-cases.sh` (the corpus validator) and `bash
tools/tests/test-migrate-anchor-grammar.sh` stay green.

## The corpus at product level

`tools/tests/test-verify-anchors-corpus.sh` runs every corpus case through the driver: each case's
target file under a directory of its own in a throwaway product, citing its source.F90 imported
into a workbench at a recorded import commit, one driver run per set of regimes, each case's
pairing supplied as anchors.yaml `names` (so the naming rule is not what is tested). The named
target's findings must be the case's verdict in every listed regime - `pass` verified through its
anchor, with no note on it; `mismatch` RED through its anchor, with its kind and `at`;
`not-comparable` UNVERIFIED; `invalid-anchor` a NOTE invalid-anchor on its anchor (none when no
anchor binds to the target, the corpus's own "no anchor binds" rule) and the target bound by name
instead: one verdict `(by name)`, or a `not checked` note when its file maps to no SOURCE file. All
275 cases, 484 case-regime judgments, match. Of the 24 `invalid-anchor` cases, 21 pass by name
(their values agree), `context/06` is RED by name (`mismatch shape at .nb`: its context struct has a
field of another module, which the anchor hid), `intrinsics/26` is not checked (its only anchor
cites a file the SOURCE lacks), and `anchors/15`, whose anchor a formatter wrapped, passes by the
file its broken anchor names. Against broken drivers: 8543882 undone (`declared_elsewhere` finds
nothing), 5 judgments differ (`anchors/11`, `computed/14`, `layout/16`: their anchor noted as naming
no entity, not as citing another statement); every `kind` reported as `value`, 20; the `names`
table ignored, 13 (the names the naming rule does not give); and the four drivers of "Binding by
name and anchor notes", 45, 45, 35 and 35. Run time: 15.4 s on 20 CPUs
(22.7 s on 4 before 6ac4794); one driver run per case took 63-70 s on 4 CPUs, almost all of it
process start-up, which batching the cases removed.

## Performance

A generated product of 300 anchored constants over 10 modules (each USEing a kinds module and the
module before it; scalars, enumerators, arrays, derived-type constants, working-precision
constants), two regimes: 1.6-1.8 s wall on 20 cores, 3.3 s on 4, 11.8 s on 1.

A product of 1000 anchored constants over 40 files, a header all of them include, two regimes: 9.0
s wall on 20 cores and 14.0 s on 4 with the constants of procedures and INCLUDE files judged (8.4 s
and 13.8 s before). Reading a SOURCE file with its INCLUDE files spliced in parses it only when its
text has an INCLUDE line; parsing every file for them took 11.1 s and 15.9 s.

## Reproduce

```
bash tools/tests/test-verify-anchors.sh                    # every assertion ok, exit 0
bash tools/tests/test-verify-anchors-corpus.sh             # all 275 cases match, exit 0
sed -i 's/^    cands, empty = {}, \[\]$/    return None, UNRELIABLE, "disabled", False/' \
    tools/conformance/lib/anchor_driver.py                 # pairing disabled
bash tools/tests/test-verify-anchors.sh                    # 112 assertions fail, exit 1
git checkout -- tools/conformance/lib/anchor_driver.py
sed -i "s/^    called = f'{want}.*/    return None, NOTE, 'not checked: binding by name disabled'/" \
    tools/conformance/lib/anchor_driver.py                 # binding by name disabled
bash tools/tests/test-verify-anchors.sh                    # 29 fail: the name-bound mismatches GREEN
git checkout -- tools/conformance/lib/anchor_driver.py
```

- Re-run after any change to the driver, the anchor rules (`lib/anchor_binding.py`) or the value
  comparison (`lib/anchor_values.py`) - standing seeded-bug rule.
