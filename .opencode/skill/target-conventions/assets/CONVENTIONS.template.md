# TARGET CONVENTIONS - <project name>

> Instantiated from the target-conventions skill at Phase 1, BEFORE translation
> starts. Frozen charter-style: changes require human sign-off and a dated entry in
> the change log below. Every sprint that writes TARGET code reads this file first
> and keeps the semantic trap table open during translation.
> Enforcement rule: every convention names its enforcement mechanism (formatter
> rule, linter rule, or tools/conformance/ script). A convention without one is a
> wish; keep wishes near zero.

## 1. Language pinning
- TARGET standard: <e.g., C17>   Compiler(s): <exact versions>
- Flags (correctness-critical, from charter): <fp-contract, fast-math off, ...>
- Warning set treated as errors: <flags>   Enforced by: <CI build>

## 2. Naming map (deterministic; default: preserve SOURCE names)
- Case rule: <e.g., all lowercase>
- Sanitization rule for illegal characters: <rule>
- Module/namespace prefix rule: <rule>
- Collision resolution rule: <fixed suffix rule>
- Enforced by: <script in tools/, name it>

## 3. File mapping
- Rule: <e.g., one SOURCE file to one .c + one .h, same stem>
- Mirrored in: port/TRACE.yaml
- Enforced by: <TRACE completeness check>

## 4. Comment policy
- Routine anchor format: /* src: <path>:<line> */
- Constant anchor format: /* src: <path>:<line> = <literal-as-read> */ - mandatory on every
  comparable constant (an object of numbers - every leaf a number or bool, a pointer only as
  an aggregate member - with an initializer at file scope, or at block scope `const` or
  `static` with a numeric literal in it; an enumerator with an explicit value; an
  object-like macro holding a numeric literal or a brace list, or one clang evaluates to a
  constant number or bool). The
  literal-as-read is one literal of the cited line, whole - with its exponent and kind
  suffix (`0.1_WP`, never `0.1`) - or the whole right-hand side of the cited statement. The
  anchor sits on a line of the declaration or alone on the line directly below it; on a
  comment line above the declaration it anchors nothing.
- Module header anchor: /* src: <path>:<line> (module <NAME>) */, citing the MODULE
  statement; on a constant, only on `<NAME>_CTX_INIT`.
- Runtime-helper anchor: /* runtime-helper: <TRAP> - <language contract> */, citing a trap
  row of section 7, only in the helper files listed in port/declared-helpers.yaml (a YAML
  list of basenames), where it stands for the constant anchor of the declaration it binds
  to: every comparable constant of a helper file carries one.
- Anchor verifier: tools/conformance/verify-anchors.sh (shipped by the methodology) -
  compares every anchored constant with the SOURCE constant it cites BY VALUE (gfortran
  and clang, bit for bit: type, kind, shape and value) in every precision build, and
  requires an anchor on every comparable constant. Its configuration is
  port/conventions/anchors.yaml (from the skill's assets/anchors.template.yaml): the
  precision builds (`regimes`, the flags each compiler adds), the TARGET include
  directories, and `names`, the TARGET names the naming map does not give. No
  literal-equivalence table is needed: the compilers decide whether two spellings are the
  same value. It reads the pinned ref from port/TRACE.yaml meta source_commit (override
  SOURCE_PIN_REF / --ref). Run it in CI and at every commit that adds anchored TARGET code.
  CI-enforced.
- Anchors stay on ONE physical line: an anchor that an auto-formatter reflows across two
  lines no longer closes on its line, which the verifier reports RED, and the constant it
  anchored is then unanchored. When a literal + its anchor would exceed the formatter's
  column limit, KEEP the anchor on one line and accept the formatter finding on that line
  (provenance beats format compliance). Never break the anchor to satisfy the formatter,
  and never `// fmt:off` it (that silences a detector); the one-line anchor is the
  load-bearing choice.
- Inherited-comment marker: <e.g., /* [SOURCE COMMENT, UNVERIFIED] ... */>
- Contradiction marker (upgrade on discovery + LESSONS entry):
  <e.g., /* [SOURCE COMMENT, CONTRADICTS CODE - see L-00NN] ... */>
- New explanatory comments paraphrasing SOURCE intent: forbidden.
- Structural markers are allowed: the include-guard close `#endif /* GUARD */`, an
  `#else`/`#endif` label echoing its directive, and equivalent target-language structure
  labels. They paraphrase no SOURCE intent and carry no process-meta, so they are not the
  forbidden class.
- Policy SCOPE (state it explicitly - leaving it implicit makes independent reviewers
  diverge on strictness, and every file churns through avoidable re-reviews): this policy
  governs EVERY file under the TARGET tree. Translation files carry only anchors +
  inherited/contradiction markers + structural markers. Test and build files carry no
  process-meta and no SOURCE-intent paraphrase, but structural markers and terse
  build-mechanics labels are permitted.
- Phase-boundary comment audit: <who runs it, where the mismatch report lands,
  e.g., docs/evidence/ - report flags provable mismatches only, never certifies
  comments as true>.

## 5. Types and precision
| SOURCE kind | TARGET type | Literal suffix | Notes |
|---|---|---|---|
| <e.g., default real> | <float> | <f> | <see trap T1> |
| <double precision> | <double> | <none> | |
| <default integer> | <int32_t> | | |

## 6. Mechanical-surface idioms (one per charter transform, with example)
- Context struct pattern: <definition site, naming, init discipline>
- Index helpers: <header, names, signature> - no ad-hoc index arithmetic
  (enforced by: tools/conformance/check-index-helpers.sh, run in CI and at every
  commit that adds translated array access; seed-bug demonstrate before first real use;
  if the names differ from the check's default set, list them in
  tools/conformance/project/index-helper-names.txt; each listed name must be defined in
  the central helper header/source, which the check finds by the names idx.h / idx.c; each must
  parse cleanly with only the other central file's directory on the include path, so it may not
  include a generated header)
- Allocation idiom: <pattern>
- Error handling idiom: <pattern>

## 7. Semantic trap table in force
- Language-pair table: <skill reference, e.g., target-conventions/references/pairs/fortran-to-c.md>
- Project-specific additions:
| ID | SOURCE construct | Trap | Mandatory rendering | Origin (LESSONS) |
|---|---|---|---|---|

## 8. Tooling baseline (versions pinned; each CI job seeded-bug-demonstrated)
- Formatter: <tool + pinned version + config file, e.g., .clang-format>
  Enforced by: <CI dry-run check>
- Linter: <tool + pinned version + allowlisted checks; modernize/rewrite checks off>
  Naming-map check: <e.g., readability-identifier-naming rules>   Enforced by: <CI>
- Sanitizer jobs (diagnostic builds, fast rig, never acceptance builds):
  | Job | Build flags | Mechanizes | Demonstrated (evidence) |
  |---|---|---|---|
  | <ASan> | | <L4, sizing> | |
  | <UBSan> | | <T13> | |
  | <memcheck/MSan> | | <T8> | |
- Coverage: <tool, SOURCE and TARGET sides; used for live-subset and review vacuity
  checks; where reports land>
- compile_commands.json: <how generated>
- Build contract: `port/conventions/build-contract.yaml` (<standard, warning floor, allowed
  `-Wno-` with reasons>); checked by `tools/build-checks/` from <proof script>, after a fresh
  build, in CI (`references/langs/<target>.md`, "Build checks")

## Change log
| Date | Change | Authorized by |
|---|---|---|
