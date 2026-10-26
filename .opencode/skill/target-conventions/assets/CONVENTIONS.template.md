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
- Routine anchor format: <e.g., /* src: <path>:<line> */>
- Constant anchor format (embeds the literal as read):
  <e.g., /* src: <path>:<line> = <literal> */> - mandatory on every nontrivial
  constant
- Literal-equivalence table for the verifier (SOURCE notation -> TARGET notation):
  | SOURCE form | TARGET form |
  |---|---|
  | <e.g., 1.d-2> | <1.0e-2> |
- Anchor verifier: tools/conformance/verify-anchors.sh (shipped by the methodology) -
  checks anchor against the pinned SOURCE line (literal present) AND against the TARGET
  line (agreed rendering), plus anchor coverage of all nontrivial constants. It reads the
  pinned ref from port/TRACE.yaml meta source_commit (override SOURCE_PIN_REF / --ref).
  Run it in CI and at every commit that adds anchored TARGET code. CI-enforced.
- Literal-embedding anchors stay on ONE physical line: the verifier matches a constant
  anchor as a single line (`/* src: <path>:<line> = <literal> */`); an auto-formatter
  that reflows a long literal + anchor across two lines is SILENTLY DROPPED with no
  coverage gap (the verifier sees no anchor and no constant to flag). When a literal +
  its anchor would exceed the formatter's column limit, KEEP the anchor on one line and
  accept the formatter finding on that line (provenance beats format compliance). Never
  break the anchor to satisfy the formatter, and never `// fmt:off` it (that silences a
  detector); the one-line anchor is the load-bearing choice.
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

## Change log
| Date | Change | Authorized by |
|---|---|---|
