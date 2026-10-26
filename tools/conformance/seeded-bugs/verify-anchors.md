# SEEDED-BUG DEMONSTRATION - conformance/verify-anchors

- Date: 2026-10-26 - a new detector. The value-comparing verifier replaces the text-based one,
  whose checks (a literal present on the cited line, an f-suffix rendering table, kind-alias
  lists, the dual-precision macro tables) no longer exist; their earlier demonstrations are
  history and are not repeated here.
- Detector: `tools/conformance/verify-anchors.sh` (product root, TARGET file scan, exit codes) over
  `tools/conformance/lib/anchor_driver.py`; the anchor rules in `lib/anchor_binding.py`, the value
  comparison in `lib/anchor_values.py`.
- Detector logic version: 8d6ddea (the driver), with f51693c..c3f7560 (the probe and anchor-rule
  changes it relies on); 86f0e0f (a constant citing another constant's statement), 642af23
  (temporaries), 6bd6f61 (the closure compile).
- Failure class targeted: a TARGET constant whose value is not the SOURCE constant it renders (a
  wrong value; a precision slip, trap T1; a wrong type; a missing or extra element or field), a
  provenance anchor that does not hold (a wrong line, a cut literal, a wrong grammar, an anchor
  bound to nothing, a runtime-helper anchor citing no trap row), and a comparable TARGET constant
  without an anchor.
- Exit-code contract: 0 GREEN (every anchor holds, every comparable constant is anchored, every
  anchored constant equals its SOURCE value; run-time values reported UNVERIFIED); 1 RED (a
  mismatch, a broken anchor rule, a missing anchor); 2 UNRELIABLE (anything not judged: a missing
  tool or parser, an unresolved pin, an incomplete file scan, an unreadable file, a SOURCE file
  that does not parse or compile, a USEd module no file defines, a malformed `anchors.yaml`, a
  pairing the naming rule cannot decide). With no TARGET code yet it skips (exit 0).

## Comparison logic

The rules - anchor grammar, binding rules 1-3, verdicts and their precedence - are those of the
case corpus, `seeded-bugs/verify-anchors/README.md`.

1. Configuration (workbench): `port/conventions/anchors.yaml` - `regimes` (the flags gfortran and
   clang add per precision build; absent file: one regime `default`), `include` (TARGET include
   directories; default every product directory), `names` (TARGET name -> SOURCE name);
   `port/declared-helpers.yaml`; the trap rows of the pair table and the project conventions.
   PyYAML `safe_load`; a malformed file is UNRELIABLE.
2. SOURCE: the subtree `source_root` at the import commit `source_commit` (port/TRACE.yaml meta;
   `--ref`, `SOURCE_PIN_REF`, `SOURCE_SUBDIR` override), extracted with `git archive` - never the
   working tree. Per regime, every cited file is preprocessed (`gfortran -cpp -E`, its line
   markers mapped back to SOURCE lines) and parsed with fparser in its own process: the modules
   it defines, the modules it USEs, its derived types, and the statement at each cited line. The
   files defining the USEd modules are found the same way (a `MODULE <name>` line proposes them,
   fparser confirms), transitively. The USE closure is compiled once per regime in dependency
   order (`gfortran -c -J`) into a module directory and an archive given to the probes.
   Intrinsic modules need no file; a USEd module no file defines is UNRELIABLE.
3. TARGET, per regime and file: libclang's declarations; each `src:` anchor bound by rules 1-3.
   An anchored declaration is paired with the SOURCE entity of its cited statement(s) whose name
   matches by the naming rule - the SOURCE name, or `<module>_<name>`; a component line pairs
   its TYPE (`<TYPE>_INIT`), a module variable line or the MODULE line its module
   (`<MODULE>_CTX_INIT`, or the module's name for a struct object), case-insensitive; `names`
   overrides it. When the name maps - by the rule or by `names` - to an entity a cited file
   declares in another statement, the anchor is RED invalid-anchor ("cites line N, which declares
   NB; NA is declared at line M"); a name mapping to no entity at all is UNRELIABLE, and so is one
   mapping to more than one. A constant mapping to no entity that the initializer of a paired
   constant reaches (references, transitively, in the same file), citing that constant's
   statement, is a temporary of it: its anchor is held to the rules, it is covered, and it takes
   that constant's verdict. Then the anchor rules against the paired statement, TYPE or MODULE
   (`bound_problems`); then the value, `judge_many`, one call per regime and SOURCE file,
   parallel. A pair whose cited statement is an assignment or allocation is UNVERIFIED (run-time).
4. Anchors bound to no constant: a constant anchor on a statement in a function is UNVERIFIED (a
   run-time value) once its literal holds; one bound to no declaration in any regime is RED; a
   routine anchor must cite an existing line, a module header anchor a MODULE statement of that
   name. A runtime-helper anchor is valid only in a declared helper file and must cite a trap row.
5. Coverage: every comparable TARGET constant - a file-scope object with an initializer, a
   block-scope `const`/`static` object whose initializer holds a numeric literal, an enumerator
   with an explicit value, an object-like macro whose body holds a numeric literal or is a brace
   list (reserved identifiers such as feature-test macros aside) - carries a constant anchor, or
   for a context initializer its module header anchor. Declared helper files are exempt.
6. Output: one line per finding, `<RED|UNRELIABLE|UNVERIFIED> <file>:<line> <name> [<regimes>]:
   <verdict> - <detail>`, then `SUMMARY [<regime>]: N verified, N unverified, N red, N
   unreliable`. Exit 1 on any RED, else 2 on any UNRELIABLE, else 0.

Probes link without the routines they never reach: every function and object in its own section
(`-ffunction-sections -fdata-sections`), linked with `--gc-sections`, so a module procedure that
calls an external routine outside the closure, or a TARGET `.c` file calling functions defined
elsewhere, still links. Measured with gfortran 16 and clang 23, each linker forced through a
regime's flags (`-fuse-ld=bfd`, `gold`, `lld` in both `source_flags` and `target_flags`), on the
test's module whose procedure calls an external routine and a TARGET function calling an undefined
one: with `--gc-sections` both pairs pass under all three linkers; without it every probe fails to
link (`undefined reference to ext_routine_`) and both pairs are UNRELIABLE under all three.
`-Wl,--unresolved-symbols=ignore-all` was rejected: with GNU ld the probe links but does not start
("unexpected PLT reloc type 0x00"). A TARGET file defining `main` is included with `main` renamed.

## Seeded defects and verdicts

`tools/tests/test-verify-anchors.sh` builds a throwaway workbench git repo (the SOURCE imported in
a commit recorded as `meta.source_commit`) and one product tree per case:

| Defect (seeded in the faithful product) | Verdict | Finding line |
|---|---|---|
| `mod_a_g = 9.80` for `G = 9.81_DP` | RED, exit 1 | `RED src/mod_a.c:2 mod_a_g [default]: mismatch value - SOURCE src/mod_a.F90:5 G` |
| `9.81f` for a double | RED, exit 1 | `... mismatch kind - SOURCE src/mod_a.F90:5 G` |
| `{1.0, 2.5}` for a 3-element array | RED, exit 1 | `... mod_a_tab [default]: mismatch shape at [2] - ...` |
| the anchor cites the next line (`:6 = 9.81_DP`) | RED, exit 1 | `... invalid-anchor - ...: the literal-as-read is not on src/mod_a.F90:6` |
| an unanchored `#define MOD_A_NLEV 60` | RED, exit 1 | `... MOD_A_NLEV [default]: coverage - no anchor binds to MOD_A_NLEV ...` |
| `real_t a = 0.1f` for `0.1_WP`, regimes dp and sp | RED in dp only, exit 1 | `RED src/mod_a.c:2 mod_a_a [dp]: mismatch kind - ...`; `SUMMARY [sp]: 1 verified ...` |
| a `names` entry pairing a constant with an entity another statement declares | RED, exit 1 | `... invalid-anchor - src/mod_a.c:1: /* src: src/mod_a.F90:5 = 9.81_DP */ cites line 5, which declares G; NLEV is declared at line 6` |
| an anchor citing a neighbour's line that holds the same literal (`mod_b_nq` citing NB's) | RED, exit 1 | `... mod_b_nq [default]: invalid-anchor - ... cites line 3, which declares NB; NQ is declared at line 5` |
| a wrong temporary of a statement split over three constants | RED, exit 1 | `RED src/mod_b.c:1 mod_b_r [default]: temporary of mod_b_r4 (line 3): mismatch value - SOURCE src/mod_b.F90:6 R4` |
| a temporary whose anchor quotes a literal not on its line | RED, exit 1 | `... mod_b_r2 [default]: invalid-anchor - ...: the literal-as-read is not on src/mod_b.F90:6` |
| a `names` entry naming an entity no SOURCE file declares | UNRELIABLE, exit 2 | `... port/conventions/anchors.yaml pairs mod_a_gravity with GRAVITY, which no cited SOURCE file declares ...` |
| a constant citing a statement, not reached from the constant that pairs with it | UNRELIABLE, exit 2 | `... mod_b_half [default]: no SOURCE entity of the cited statement(s) is named mod_b_half ...` |
| a runtime-helper anchor citing an invented trap row | RED, exit 1 | `RED src/f_runtime.h:1: invalid-anchor - the runtime-helper anchor cites trap T99, ...` |
| a runtime-helper anchor outside a declared helper file | RED, exit 1 | `... a runtime-helper anchor is valid only in a file listed in port/declared-helpers.yaml ...` |
| an anchor on a run-time assignment in a function | UNVERIFIED, exit 0 | `UNVERIFIED src/mod_a.c:5 [default]: not-comparable - the anchor is on a statement, ...` |
| an anchor citing a SOURCE file fparser cannot parse | UNRELIABLE, exit 2 | `... SOURCE src/broken.F90 cannot be read in regime default: fparser cannot parse ...` |
| an anchor citing a module that USEs a module no file defines | UNRELIABLE, exit 2 | `... module MOD_MISSING, USEd by src/lonely.F90, is defined by no SOURCE file` |
| `regimes: [dp, sp]` in anchors.yaml | UNRELIABLE, exit 2 | `... anchors.yaml is malformed: regimes is not a non-empty mapping` |
| a TARGET name the naming rule does not give | UNRELIABLE, exit 2 | `... mod_a_gravity [default]: no SOURCE entity of the cited statement(s) is named mod_a_gravity ...` |
| a pin that does not resolve | UNRELIABLE, exit 2 | `SOURCE pin ref 'no-such-ref' does not resolve ...` |
| a wired product root that does not exist | UNRELIABLE, exit 2 | `... is not present beside the workbench ...` |

and these must stay GREEN: the faithful product (a scalar, an enumerator, an array quoted by its
whole right-hand side, a brace-list macro of a derived type defined in another SOURCE file, a
working-precision constant, a module variable of a module whose procedure calls an external
routine, a declared helper file with an unanchored constant: `7 verified`); the derived-type
constant alone (`1 verified`: the USE closure compiled); a module variable of the module calling
an external routine next to a TARGET function calling an undefined one (`1 verified`: both link);
the same names case once `names` pairs it; a statement split over three constants
(`3 verified`: two temporaries through the third); the faithful product with the working-tree
SOURCE shifted by a line after the import (anchors read at the pin); no TARGET code yet (skip).

## Red proof (the test fails against broken drivers)

Each mutation applied to a copy of the tools, then `bash tools/tests/test-verify-anchors.sh`:

| Mutation | Assertions failing |
|---|---|
| pairing disabled (`pair_entity` returns UNRELIABLE) | 19: every value verdict, the closure, linking, regime, names, same-literal and temporaries cases become UNRELIABLE |
| `--gc-sections` dropped from the probes | 12: every case reaching a module whose procedure calls an external routine, and the TARGET function calling one, become UNRELIABLE |
| the USE closure not compiled | 9: every pair of a module USEing another becomes UNRELIABLE |
| coverage disabled | 1: the unanchored constant is GREEN |
| only the first regime judged | 1: no `SUMMARY [sp]` |
| the SOURCE read from the working tree | 1: the shifted SOURCE makes the faithful product RED |
| temporaries never found | 2: the split statement's temporaries are UNRELIABLE |
| a name mapping to an entity of another statement left UNRELIABLE | 2: the same-literal neighbour and the `names` entry are UNRELIABLE, not RED |

Before 86f0e0f and 642af23 the test as it stands now failed 3 and 2 assertions against the then
driver: the same-literal neighbour and both `names` cases, then the two temporaries cases.

## Green proof

`bash tools/tests/test-verify-anchors.sh`: all 32 assertions ok, exit 0 - with libclang 23 and
with the CI's pip libclang 18.1.1. `bash tools/tests/test-anchor-values.sh` (the corpus, judged
pair by pair) and `bash tools/tests/test-verify-anchors-cases.sh` (the corpus validator) stay green.

## The corpus at product level

`tools/tests/test-verify-anchors-corpus.sh` runs every corpus case through the driver: each case's
target file under a directory of its own in a throwaway product, citing its source.F90 imported
into a workbench at a recorded import commit, one driver run per set of regimes, each case's
pairing supplied as anchors.yaml `names` (so the naming rule is not what is tested). The named
target's finding must be the case's verdict in every listed regime - `pass` verified, `mismatch`
RED with its kind and `at`, `not-comparable` UNVERIFIED, `invalid-anchor` RED invalid-anchor, or
RED coverage when no anchor binds to the target (the corpus's own "no anchor binds" rule). All 275
cases, 484 case-regime judgments, match, with libclang 23 and 18.1.1. Against broken drivers: 86f0e0f
undone, 5 judgments differ (`anchors/11`, `computed/14`, `layout/16`); a `kind` reported
as `value`, 10; the `names` table ignored, 13 (the names the naming rule does not give). Run time:
22.7 s on 4 CPUs, 13.3 s on 20; one driver run per case took 63-70 s on 4 CPUs, almost all of it
process start-up, which batching the cases removed.

## Performance

A generated product of 300 anchored constants over 10 modules (each USEing a kinds module and the
module before it; scalars, enumerators, arrays, derived-type constants, working-precision
constants), two regimes: 1.6-1.8 s wall on 20 cores, 3.3 s on 4, 11.8 s on 1.

## Reproduce

```
bash tools/tests/test-verify-anchors.sh                    # every assertion ok, exit 0
bash tools/tests/test-verify-anchors-corpus.sh             # all 275 cases match, exit 0
sed -i 's/^    cands, empty = {}, \[\]$/    return None, UNRELIABLE, "disabled", False/' \
    tools/conformance/lib/anchor_driver.py                 # pairing disabled
bash tools/tests/test-verify-anchors.sh                    # 19 assertions fail, exit 1
git checkout -- tools/conformance/lib/anchor_driver.py
```

- Re-run after any change to the driver, the anchor rules (`lib/anchor_binding.py`) or the value
  comparison (`lib/anchor_values.py`) - standing seeded-bug rule.
