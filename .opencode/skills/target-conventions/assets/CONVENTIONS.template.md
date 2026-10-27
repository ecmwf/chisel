# TARGET CONVENTIONS - <project name>

> Instantiated from the target-conventions skill at Phase 1, before translation starts. Frozen like
> the charter: a change needs the human's sign-off and a dated row in the change log below. Every
> sprint that writes TARGET code reads this file first and keeps the semantic trap table open while
> translating. Every convention names what enforces it (a formatter rule, a linter rule, or a
> script in tools/conformance/ or tools/build-checks/); a convention without one is a wish, and
> wishes are kept near zero. The pair rulebook in force (section 7) gives this pair's defaults
> for every section.

## 1. Language pinning
- TARGET standard: <e.g. C17>   Compiler(s): <exact versions>
- Flags (correctness-critical, from the charter): <e.g. contraction off, no value-changing math>
- Warning set treated as errors: <flags>   Enforced by: <CI build>
- Build contract: <file, e.g. port/conventions/build-contract.yaml> - <standard, warning floor, each
  warning taken back with its reason>; checked by <tool> after a fresh build, from <proof script>, in CI

## 2. Naming map (deterministic; default: preserve SOURCE names)
- Case rule: <e.g. all lowercase>
- Sanitization rule for illegal characters: <rule>
- Module/namespace prefix rule: <rule>
- Collision resolution rule: <fixed suffix rule>
- Enforced by: <script in tools/, name it>

## 3. File mapping
- Rule: <e.g. one SOURCE file to one implementation file and one interface file, same stem>
- Mirrored in: port/TRACE.yaml
- Enforced by: <TRACE completeness check>

## 4. Comment policy
- Anchor verifier: <script, e.g. tools/conformance/verify-anchors.sh>, configured by
  port/conventions/anchors.yaml (from the skill's assets/anchors.template.yaml). It binds every
  comparable constant to its SOURCE constant by name - or by an anchor - and compares their values
  in every precision build (which constants are comparable: the pair rulebook). Run in CI and at
  every commit that adds TARGET code. Only a wrong value fails it; an anchor problem is a note.
- Anchors are optional, written only where a name cannot be matched. An anchor names the SOURCE
  file and, where needed, the module or the literal as read - never a line number, which goes
  stale: <the pair's grammar, e.g. /* src: <path> */, /* src: <path> (module <NAME>) */>. A
  TARGET name the naming map does not give is paired in anchors.yaml `names`.
- Routine anchor (optional): <e.g. /* src: <path> (subroutine <NAME>) */>
- Runtime-helper anchor: <e.g. /* runtime-helper: <TRAP> - <language contract> */>, citing a trap
  row of section 7, only in the helper files listed in port/declared-helpers.yaml; a constant
  carrying one is not bound to a SOURCE constant
- An anchor stays on one physical line: configure the formatter never to reflow comments (the
  TARGET's language file says how), and never wrap an anchor in a formatter-off region. A
  reflowed anchor no longer closes on its line, and is noted rather than read.
- Inherited-comment marker (recommended): <e.g. /* [SOURCE COMMENT, UNVERIFIED] ... */>
- Contradiction marker (on discovery, with a LESSONS entry):
  <e.g. /* [SOURCE COMMENT, CONTRADICTS CODE - see L-00NN] ... */>
- New explanatory comments that paraphrase SOURCE intent: forbidden.
- Structural markers are allowed: <e.g. the include-guard close, an #else/#endif label echoing its
  directive>. They paraphrase no SOURCE intent and carry no process-meta.
- Scope, stated so that independent reviewers judge alike: this policy governs every file under the
  TARGET tree. Translation files carry only anchors, inherited and contradiction markers and
  structural markers. Test and build files carry no process-meta and no paraphrase of SOURCE
  intent, but may hold structural markers and terse build-mechanics labels.
- Phase-boundary comment audit: <who runs it, where the mismatch report lands, e.g. docs/evidence/>.
  The report flags provable mismatches only; it never certifies a comment as true.

## 5. Types and precision
| SOURCE kind | TARGET type | Literal suffix | Notes |
|---|---|---|---|
| <e.g. default real> | <float> | <f> | <see trap T1> |
| <double precision> | <double> | <none> | |
| <default integer> | <int32_t> | | |

## 6. Mechanical-surface idioms (one per charter transformation, with an example)
- Context struct pattern: <definition site, naming, init discipline>
- Index helpers: <header, names, signatures> - no ad-hoc index arithmetic. Enforced by: <the
  index-helper check the pair rulebook names>, in CI and at every commit that adds translated
  array access, seeded-bug-demonstrated before its first real use.
- Allocation idiom: <pattern>
- Error handling idiom: <pattern>

## 7. Semantic trap table in force
- Language-pair table: <.opencode/skills/target-conventions/references/pairs/<source>-to-<target>.md>
- Project-specific additions, with IDs P1, P2, ... (a trap that holds for the whole pair goes
  upstream as a new T row through `/port-contribute-to-base`):

| ID | SOURCE construct | Trap | Mandatory rendering | Origin (LESSONS) |
|---|---|---|---|---|

## 8. Tooling baseline (versions pinned; each CI job seeded-bug-demonstrated)
- Formatter: <tool + pinned version + config file>   Enforced by: <CI dry-run check>
- Linter: <tool + pinned version + allowlisted checks; modernize and rewrite checks off>
  Naming-map check: <rule set>   Enforced by: <CI>
- Runtime checks (the ones the TARGET's langs file requires; diagnostic builds on the fast rig, never
  acceptance builds; every R1 proof runs them):
  | Job | Build flags | Catches | Demonstrated (evidence) |
  |---|---|---|---|
  | <e.g. address,undefined,float-cast-overflow> | | <e.g. N4, T13, T17> | |
  | <e.g. memory> | | <e.g. T8> | |
- Coverage: <tool, SOURCE and TARGET sides; used for the live subset and review vacuity checks;
  where reports land>
- Compilation database: <how it is produced, if the TARGET has one; its language file says what
  reads it>

The TARGET's language file (`.opencode/skills/target-conventions/references/langs/<target>.md`)
names the tools, their templates and the checks that read a build.

## Change log
| Date | Change | Authorized by |
|---|---|---|
