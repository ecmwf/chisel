# PORT CHARTER - <instance name>

> The constitution of the port. Read at the start of every sprint; updated only when
> scope, milestones, or rules change, with human sign-off per phase.
>
> The base copy stays abstract - program names and language choices enter only an
> instance's project layer (reuse model in AGENTS.md). Validate the workflow as you
> scale: exercise every mechanism (tools, proofs, state files, sprint protocol) at least
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
> methodology and its proofs do not check them.

## 2. Canonical reference run (immutable once set)
Run definitions are SINGLE-SOURCED in `reference/runs.md`; this section only pins
which ones are canonical (no duplicated definitions - the single-source rule):
- SOURCE program + pinned commit: <TBD - the upstream commit, from
  port/provenance/<name>.yaml; port/TRACE.yaml meta.upstream_commit holds the same value>
- Canonical reference run: <run ID from reference/runs.md - must include a
  full-scale, real setting, not only a short smoke run (L1 defense)>
- Fast rig run: <run ID from reference/runs.md - iteration only, never acceptance>
- NOTE: every comparison in this project is against the canonical run unless a
  proof says otherwise.

## 3. Pinned configuration (the contract - Prime Directive 4)
| Option | Effective value | Provenance (file:line) |
|---|---|---|
| <TBD when the program is chosen> | | |

Live subset: <TBD> - authoritative list in `port/TRACE.yaml`.
Excluded: <TBD>.  How determined: <TBD - use tools/scoping/, record the method>.

## 4. Named exceptions to literal translation (human-authorized only)
Each exception has an ID (`X-01`, `X-02`, ... - never reused), so plans, reviews and registries cite
it by ID. A detector suppression that is itself the correct semantic choice (a pragma, attribute or
lint directive, AGENTS.md "Never silence a detector") is one kind of named exception: give it a row
here and register the site in `port/conventions/allowed-suppressions.yaml` (template:
`.opencode/skills/target-conventions/assets/allowed-suppressions.template.yaml`).

| ID | Exception | Rationale | Authorized by | Date |
|---|---|---|---|---|
| (none yet) | | | | |

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
### Phase 0 - Scoping: choose the program, pin config, archive reference run
  [sign-off: ____]
### Phase 1 - Tooling + conventions (scope: REPRESENTATIVE, not exhaustive -
  each mechanism demonstrated once; full breadth comes as the port scales):
  - one staged dump point, one identical-input operator diff, one always-on range
    probe - built and demonstrated on the SOURCE alone (dump/restore round-trip;
    probe silent on the reference run); proof scripts in tools/proofs/ runnable by CI
  - capture-replay harness exercised on AT LEAST ONE wide-footprint routine
    (read-set recording, fixture capture, replay) - the full per-procedure policy
    and friction study run as the port scales to full breadth
  - port/conventions/<source>-to-<target>.md instantiated from the target-conventions skill (naming
    map, comment policy, type/precision table, formatter config, the language-pair trap
    table in force) with enforcement scripts landed in tools/conformance/
  - the provenance-anchor verifier built and CI-wired: constant anchors embed the
    literal as read; verifier checks anchor vs pinned SOURCE line and vs TARGET
    rendering, plus anchor coverage of all nontrivial constants
  - seeded-bug demonstrations: every proof and probe shown to fire on an injected
    error before first real use, recorded per SEEDED-BUG template
  - SOURCE inertness proof: with every instrumentation switch unset, the instrumented
    SOURCE build reproduces the pristine pinned reference run's outputs byte-for-byte
    (results, not a hash-identical binary; prefer compile-time switching so the
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
    effort, tolerance calibration effort) - input to the per-procedure policy for
    the rest of the port
  - every module reaches `proven` in TRACE only with an independent fidelity review
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
### Phases 3–5 - execution model, performance, portability: instantiated from the skill
  when this port reaches them (a serial-only port ends at Phase 2 with its retrospective)
  [sign-off: ____]

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
| main | everything (single stream until a second workstream exists) | port/handoffs/main.md | - |

## 10. Risks
| Risk | Mitigation |
|---|---|
| First slice too trivial to exercise the workflow (no config superset, no latent-bug surface) | Choose a first slice with at least: a parameter file, a multi-step iteration, one lookup table or nontrivial constant set, and a mix of pure and wide-footprint routines (so the per-procedure verification policy is actually tested) |
| Workflow overhead feels heavy at small scale and gets skipped | Record the friction in LESSONS instead of skipping - the overhead is what makes the full breadth safe |

## 11. Phase retrospectives
(linked from `port/retrospectives/` as they are written)

## 12. Autodrive (see `.opencode/skills/code-port/references/auto-mode.md`)
Ptah-Orchestrator can drive the port without a keystroke from the human. It is opt-in and weakens no
safeguard: review independence, the conformance checks and the guarded scripts still fail closed,
and every action commits its evidence.

The settings live in `port/autodrive.yaml` (template:
`.opencode/skills/code-port/assets/autodrive.template.yaml`), which `/port-autodrive` reads; without
that file autodrive is off.
- `level`: L0 off (the default); L1 plan and stop; L2 drive the current phase, seal its milestone
  and stop; L3 drive every phase. At L2 and L3 `finalize.sh --auto` seals a milestone once the full
  conformance suite is green at HEAD; the acceptance is the section 7 standard set once, not a
  sign-off per milestone.
- `scope`: the actions autodrive may take (e.g. `claim, work, review`); any other is reported as a
  recommendation.
- `budgets`: `max_waves`, `max_wall_clock` and `max_cost` end the run when reached; `max_rework`
  halts a piece that fails review more often than that; `max_in_flight` caps how many workers run
  at once.

Start at L1, and raise the level once its plans look right on this codebase.
