# PORT CHARTER - <instance role: pilot | full port>

> The constitution of the port. Read at the start of every sprint; updated only when
> scope, milestones, or rules change, with human sign-off per phase.
>
> The base copy stays abstract - program names and language choices enter only an
> instance's project layer (reuse model in AGENTS.md). Validate the workflow as you
> scale: exercise every mechanism (tools, gates, state files, sprint protocol) at least
> once on a small, representative slice before the full breadth, and treat a process
> shortcut as a failure even when the code comes out right. Honest scope limit: this
> charter exercises only what it names - distributed-memory machinery (boundary probes,
> rank-count identity) and execution-model tiers R3-R5 are designed in the skill now and
> built when a distributed port's Phase 1 (probes) or a real execution-model change
> (R3-R5) calls for them.

## 1. Languages and frameworks (an INSTANCE decision - the agent asks, the human
   answers; nothing here is inherited silently or inferred from naming)
- SOURCE: <language + standard, compiler + flags of the reference build> (OBSERVED from the
  imported tree - cite file:line)
- INTERMEDIATE: <none | language + rationale>
- TARGET: <language + standard, compiler + flags - pin both> (the human's CHOICE: the agent
  proposes a default with rationale and ASKS; never inferred from the repo/instance/product
  name or the tree)
- EXECUTION MODEL: <e.g., serial; execution-model stages and when they apply>

> Licensing and the right to port the SOURCE are human responsibilities; this
> methodology and its gates do not check them.

## 2. Canonical reference run (immutable once set)
Run definitions are SINGLE-SOURCED in `reference/runs.md`; this section only pins
which ones are canonical (no duplicated definitions - the single-source rule):
- SOURCE program + pinned commit: <TBD - also mirrored in port/TRACE.yaml meta;
  consistency between the two is a TRACE conformance-script check>
- Canonical reference run: <run ID from reference/runs.md - must include a
  full-scale, real setting, not only a short smoke run (L1 defense)>
- Fast rig run: <run ID from reference/runs.md - iteration only, never acceptance>
- NOTE: every comparison in this project is against the canonical run unless a
  gate says otherwise.

## 3. Pinned configuration (the contract - Prime Directive 4)
| Option | Effective value | Provenance (file:line) |
|---|---|---|
| <TBD when pilot program chosen> | | |

Live subset: <TBD> - authoritative list in `port/TRACE.yaml`.
Excluded: <TBD>.  How determined: <TBD - use tools/scoping/, record the method>.

## 4. Named exceptions to literal translation (human-authorized only)
| Exception | Rationale | Authorized by | Date |
|---|---|---|---|
| (none yet) | | | |

## 5. Permitted mechanical transformations
Each entry names the transformation AND the script that performs/checks it.
Typical entries for a language pair (instantiate per the pair chosen in §1):
- Index base conversion, if the bases differ - <script TBD, tools/>
- Storage-order conversion via central index helpers, if the orders differ -
  helpers in <TBD>, conformance check in tools/conformance/ (no ad-hoc index
  arithmetic at call sites)
- Module/global state → explicit context struct passed as argument
Nothing outside this list is permitted without entering table 4.

## 6. Interim placeholders
| ID | Placeholder | Stands in for | Introduced | Closure milestone | Closed (tag) |
|---|---|---|---|---|---|
| (none) | | | | | |

## 7. Stages and acceptance criteria
### Phase 0 - Scoping: choose pilot program, pin config, archive reference run
  [sign-off: ____]
### Phase 1 - Tooling + conventions (scope: REPRESENTATIVE, not exhaustive -
  each mechanism demonstrated once; full breadth comes as the port scales):
  - one staged dump point, one identical-input operator diff, one always-on range
    probe - built and demonstrated on the SOURCE alone (dump/restore round-trip;
    probe silent on the reference run); gate scripts in tools/gates/ runnable by CI
  - capture-replay harness exercised on AT LEAST ONE wide-footprint routine
    (read-set recording, fixture capture, replay) - the full per-procedure policy
    and friction study run as the port scales to full breadth
  - port/conventions/<source>-to-<target>.md instantiated from the target-conventions skill (naming
    map, comment policy, type/precision table, formatter config, the language-pair trap
    table in force) with enforcement scripts landed in tools/conformance/
  - the provenance-anchor verifier built and CI-wired: constant anchors embed the
    literal as read; verifier checks anchor vs pinned SOURCE line and vs TARGET
    rendering, plus anchor coverage of all nontrivial constants
  - seeded-bug demonstrations: every gate and probe shown to fire on an injected
    error before first real use, recorded per SEEDED-BUG template
  - SOURCE inertness gate: with every instrumentation switch unset, the instrumented
    SOURCE build reproduces the pristine pinned reference run's outputs byte-for-byte
    (results, not a hash-identical binary; prefer compile-time gating so the
    instrumentation is absent from the build entirely)
  - tooling baseline: pinned formatter + allowlisted linter in CI, ONE sanitizer
    job (ASan) on the fast rig, compile_commands.json; the full sanitizer matrix
    and coverage wiring may be deferred to a later phase with human sign-off
  [sign-off: ____]
### Phase 2 - Translation (SOURCE → TARGET-serial), dependency order, R0 intrinsic checks
  during bring-up. Per-procedure verification per the policy in the skill's
  references/validation-ladder.md:
  - every routine classified by state footprint at translation time (pure /
    wide-footprint / seam), recorded per routine in the TRACE entry's symbols block
  - pure routines: unit tests in CI
  - wide-footprint routines: capture-replay fixtures with recorded read-sets and
    calibrated per-routine tolerances
  - friction metrics recorded per routine class (harness cost, read-set extraction
    effort, tolerance calibration effort) - input to the large-port policy decision
  - every module reaches `gated` in TRACE only with an independent fidelity review
    (/port-review, by a session that did not write the translation; report in
    docs/evidence/, path recorded in the TRACE entry)
  - coordination rehearsal: deferred to a later, wider phase, where at least
    one module is ported by a second workstream (own handoff, plan card, TRACE
    ownership, COORDINATION locks). Deferral accepted at Phase 0 sign-off.
  - performance parity tracked from the first milestone: SOURCE vs TARGET
    wall-clock on the same run/machine/flags recorded in every milestone evidence
    pack; parity band: <TBD - agree with human; literal ports sit within a few
    percent once builds match>; deviations outside the band are investigated as
    findings (build flags, debug artifacts, rendering bugs), never optimized away
    during translation
  Whole-program acceptance (statistical, cross-compiler - test design per metric,
  defined with the human BEFORE translation):
  | Quantity | Statistic | Window/duration | Tolerance (+ calibration evidence) | Failure rule |
  |---|---|---|---|---|
  | <TBD> | | | | |
  - differential drift: statistically zero (define the test and window)
  - conserved quantities (if applicable): <criteria>
  [sign-off: ____]
### Phases 3–5 - deferred to the large port (pilot is serial-only; retrospective
  instead: what must change in this workflow before the large port?)  [sign-off: ____]

## 8. Milestones (git-tag each when passed)
A tag is created ONLY after the milestone's human SIGNOFF.md exists in its
evidence pack (prepare with /port-digest).
- [ ] tag `phase0-signed` - config pinned, reference archived, TRACE populated
- [ ] tag `tooling-green-on-source`
- [ ] (per-module milestones added at Phase 0 exit, mirrored in TRACE)
- [ ] tag `phase2-accepted` - Phase 2 evidence pack signed off
- [ ] tag `retro-done` - retrospective written, /port-contribute-to-base run

## 9. Workstreams
| Workstream | Scope | Handoff file | Depends on |
|---|---|---|---|
| main | everything (pilot is single-stream) | port/handoffs/main.md | - |

## 10. Risks
| Risk | Mitigation |
|---|---|
| Pilot too trivial to exercise the workflow (no config superset, no latent-bug surface) | Choose a program with at least: a parameter file, a multi-step iteration, one lookup table or nontrivial constant set, and a mix of pure and wide-footprint routines (so the per-procedure verification policy is actually tested) |
| Workflow overhead feels heavy at pilot scale and gets skipped | That is the point of the pilot - record friction in LESSONS instead of skipping |

## 11. Phase retrospectives
(linked from `port/retrospectives/` as they are written)
