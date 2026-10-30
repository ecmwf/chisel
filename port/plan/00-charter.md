# PORT CHARTER - <instance name>

> The constitution of the port: what is ported, into what, and how it is accepted. Read the
> relevant section at the start of every sprint. It changes only when scope, milestones or rules
> change, with the human's sign-off. Phase plans live beside it (`NN-phase-*.md`), module cards in
> `modules/`.
>
> Chisel's own copy stays abstract: program names and language choices enter only a port's copy
> (AGENTS.md, "The two layers"). Exercise every mechanism (tools, proofs, state files, the sprint
> protocol) once on a small, representative slice before the full breadth, and treat a process
> shortcut as a failure even when the code comes out right. This charter covers what it names:
> distributed-memory machinery (boundary probes, rank-count identity) and the execution-model
> tiers R3-R5 are built when a port's Phase 1 or a real execution-model change calls for them.

## 1. Languages and frameworks
The SOURCE is observed from the imported tree (cite file:line). The TARGET and the execution model
are the human's decision: the agent recommends one with its rationale, asks, and waits. It never
infers them from a repository, instance or product name, or from the tree.
- SOURCE: <language + standard, compiler + flags of the reference build, and its floating-point
  environment (flush-to-zero on or off)>
- INTERMEDIATE: <none | language + rationale>
- TARGET: <language + standard, compiler + flags, math library (the reference build's, or which one
  and from which phase)>
- EXECUTION MODEL: <e.g. serial; the later stages and when they apply>

> Licensing and the right to port the SOURCE are the human's responsibility; the methodology and
> its proofs do not check them.

## 2. Canonical reference run
Runs are defined once, in `reference/runs.md`; this section names the canonical ones. A run is
immutable once set; new runs may be added.
- SOURCE program + upstream commit: <TBD - the `commit` in port/provenance/<name>.yaml;
  port/TRACE.yaml meta.upstream_commit holds the same value>
- Canonical reference run: <run ID - a full-scale, real setting, not only a short smoke run
  (N1 defense)>
- Decompositions: <run IDs at two or more decompositions, the canonical run itself multi-chunk
  (partition size below the points per rank): one chunk on one rank hides index-base and stride
  errors (N4 defense). n/a only if the program never partitions its arrays>
- Fast rig run: <run ID - for iteration only, never acceptance>

Every comparison is against the canonical run unless a proof says otherwise.

## 3. Pinned configuration (the contract - Prime Directive 4)
Only this configuration is ported. Each option has its effective value and where that value comes
from (parameter file, in-source default or compile flag), with file:line.

| Option | Effective value | Provenance (file:line) |
|---|---|---|
| <TBD when the program is chosen> | | |

Live subset: <TBD> - the authoritative list is `port/TRACE.yaml`.
Excluded subsystems: <TBD>. How the live subset was determined: <TBD - coverage, build log, link
map or expert, and the tool in tools/scoping/>.
Preprocessor macro state: the pinned value of every macro that guards a dependency edge, with the
file that fixes it, is in `tools/scoping/macro-state.yaml`
(`.opencode/skills/code-port/assets/macro-state.template.yaml`).

## 4. Named exceptions to literal translation (human-authorized only)
Each exception has an ID (`X-01`, `X-02`, ... - never reused), so plans, reviews and registries cite
it by ID. A detector suppression that is itself the correct semantic choice (a pragma, attribute or
lint directive, AGENTS.md "Never silence a detector") is one kind of named exception: give it a row
here and register the site in `port/conventions/allowed-suppressions.yaml` (template:
`.opencode/skills/target-conventions/assets/allowed-suppressions.template.yaml`).
A faithful rendering that departs from section 5 (failure modes B8, B10) is authorized the same
way; its row in `port/KNOWN-DIVERGENCES.md` names the ID.

| ID | Exception | Rationale | Authorized by | Date |
|---|---|---|---|---|
| (none yet) | | | | |

## 5. Permitted mechanical transformations
Each entry names the transformation and the script that performs or checks it. Typical entries,
when the languages of section 1 differ in these respects:
- Index base conversion - <script, tools/>
- Storage-order conversion through the central index helpers - helpers in <file>, conformance
  check in tools/conformance/ (no ad-hoc index arithmetic at call sites)
- Module or global state turned into an explicit context struct passed as an argument

Nothing outside this list is permitted without a row in section 4.

## 6. Interim placeholders
Bring-up scaffolding (`.opencode/skills/code-port/references/bring-up-strategy.md`). A phase cannot
reach its final sign-off with an open placeholder that affects its physics.

| ID | Placeholder | Stands in for | Introduced | Closure milestone | Closed (tag) |
|---|---|---|---|---|---|
| (none) | | | | | |

## 6a. Review threat model (ratify with the human before the first review)
What a reviewer treats as blocking when it audits a detector, a proof or a check. Without it,
detector reviews do not converge: against an adversary who can already write to the tree, every
control you add is writable too (failure mode B20). Amend the defaults to fit the port.
Ratified by: <name, date>.

| Class | Example | Disposition |
|---|---|---|
| Honest worker error | a wrong assumption, a missed case, a plausible paraphrase | blocking |
| Broken or vacuous detector | a check that reports green having established nothing | blocking |
| Ordinary environmental accident | a system upgrade changing a library under a recorded bar | blocking |
| Adversary with commit access | PATH shadowing, symlink farms, races on the checkout | non-blocking note |
| Configurations this port does not use | a code path the pinned configuration excludes | non-blocking note |

Fail-closed applies whatever the model: "could not determine" is never a pass. A non-blocking
finding is recorded, not discarded.

Review round cap: <N> rounds per unit (2 is a reasonable default) when driven by hand; under
autodrive the `max_rework` budget (section 12) plays this role. Reaching the cap means narrowing
the unit's claim or asking the human for a scoping decision, not another round. A finding outside
this model at the cap becomes a recorded note, or a placeholder (section 6) with a closure milestone.

auto-prove: off
Set it to `clean-only` to let port-review record `proven` itself on a fully clean review that
passes the proof-evidence audit (`/port-review`); any finding still goes to the human. Record who
authorized it, the date, its scope and how to revoke it: <name, date, scope, how to revoke>.

## 7. Stages and acceptance criteria
### Phase 0 - Scoping: pin the program, the configuration and the reference run  [sign-off: ____]
### Phase 1 - Tooling and conventions  [sign-off: ____]
  Representative, not exhaustive: each mechanism demonstrated once; full breadth comes as the
  port scales.
  - one staged dump point, one identical-input operator diff, one always-on range probe - built
    and demonstrated on the SOURCE alone (dump/restore round-trip; probe silent on the reference
    run); proof scripts in tools/proofs/, runnable by CI
  - the capture-replay harness exercised on at least one wide-footprint routine (read-set
    recording, fixture capture, replay); the full per-procedure policy and friction study come as
    the port scales
  - port/conventions/<source>-to-<target>.md instantiated from the target-conventions skill
    (naming map, comment policy, type/precision table, formatter config, the language-pair trap
    table in force), with its enforcement scripts landed in tools/conformance/
  - the provenance-anchor verifier built and wired into CI: constant anchors embed the literal as
    read; the verifier checks each anchor against the pinned SOURCE line and the TARGET rendering,
    and that every nontrivial constant has one
  - seeded-bug demonstrations: every proof and probe shown to fire on an injected error before
    its first real use (`/port-seed`)
  - SOURCE hygiene probe, where the SOURCE language's langs file describes one: the SOURCE built
    with its compiler's runtime checks and run on the fast-rig cases; each report is a SOURCE
    finding (`port/SOURCE-FINDINGS.md`) or a value the reference relies on without setting it,
    decided here
  - SOURCE inertness proof: with every instrumentation switch unset, the instrumented SOURCE
    build reproduces the pristine reference run's outputs byte for byte (the results, not a
    hash-identical binary; prefer compile-time switches, so the instrumentation is absent from
    the build)
  - tooling baseline: a pinned formatter and an allowlisted linter in CI, a compilation database,
    and every runtime check the TARGET's langs file requires (e.g. for C, an ASan + UBSan build and
    an MSan build), each seeded-bug-demonstrated and run in CI on the fast rig, since every R1 proof
    needs them; coverage wiring may wait for a later phase, with the human's sign-off
### Phase 2 - Translation (SOURCE to serial TARGET), in dependency order  [sign-off: ____]
  R0 intrinsic checks during bring-up; per-procedure verification as in
  `.opencode/skills/code-port/references/validation-ladder.md`:
  - every routine classified by state footprint when it is translated (pure, wide-footprint or
    seam), recorded in its TRACE entry's `symbols` block
  - pure routines: unit tests in CI
  - wide-footprint routines: capture-replay fixtures with recorded read-sets and calibrated
    per-routine tolerances
  - friction recorded per routine class (harness cost, read-set extraction, tolerance
    calibration), as input to the policy for the rest of the port
  - a module reaches `proven` in TRACE only with an independent fidelity review (`/port-review`,
    in a session that did not write the translation; the report in docs/evidence/, its path in
    the TRACE entry)
  - coordination rehearsal: deferred to a later, wider phase, where at least one module is
    ported by a second workstream (own handoff, plan card, TRACE ownership). Deferral accepted at
    the Phase 0 sign-off.
  - performance parity from the first milestone: SOURCE and TARGET wall-clock on the same run,
    machine and flags, in every milestone evidence pack; parity band: <TBD - a literal port sits
    within a few percent once the builds match>. A deviation outside the band is investigated as
    a finding (build flags, debug artifacts, rendering bugs), never optimized away during
    translation.
  Whole-program acceptance: statistical and cross-compiler, one test design per quantity, agreed
  with the human before translation. A field is compared by approximate equality
  (|a-b| <= atol + rtol*|b|); the human sets each band, and `/port-calibrate` prepares the
  measured evidence and records the band here.
  | Quantity | Statistic | Window/duration | Tolerance (+ calibration evidence) | Failure rule |
  |---|---|---|---|---|
  | <TBD> | | | | |
  - differential drift: statistically zero (define the test and the window)
  - conserved quantities (if any): <criteria>
### Phase 3 - Execution model  [sign-off: ____]
  The ladder instance (`.opencode/skills/code-port/references/validation-ladder.md`, "A canonical
  ladder"):
  - R1 per-kernel twin: max|Δ| = 0 on a deterministic backend
  - R2 whole-run byte-identity: <run, fixed process count N>
  - R3 threaded floor: <value, calibration evidence>
  - R4 accelerator proof: <steps, per-field ceilings, recorded floating-point floor>
  - R5 multi-run parity against the SOURCE and the intermediate reference
### Phase 4 - Performance  [sign-off: ____]
  Throughput target: <domain throughput>
### Phase 5 - Portability and handover  [sign-off: ____]
  The targets, pinned with the human like the configuration; the agent builds and runs on each
  real target, never a stand-in:
  | Target (arch / OS / compiler / accelerator / machine) | Access and build | Acceptance regime | Recorded floor |
  |---|---|---|---|
  | <e.g. same-architecture recompile> | <...> | bit-identity against the reference (R2) | n/a |
  | <e.g. another architecture or vendor> | <...> | statistical parity (R5), atol/rtol per field | <floor> |

A serial-only port ends at Phase 2, with its retrospective.

## 8. Milestones (git-tag each when passed)
Only `tools/coordination/finalize.sh` creates a milestone tag: hand-driven, once the human's accept
SIGNOFF.md is committed in the evidence pack (prepare it with `/port-digest`); at autodrive L2 or L3,
with `--auto` once the full conformance suite is green at HEAD (section 12). Auto-land is on: with
the milestone tag, `finalize.sh` also runs the git that follows a sign-off (a pending
methodology-sync land, the push, the worktree teardown), so the human types no git.
- [ ] tag `phase0-signed` - configuration pinned, reference archived, TRACE populated
- [ ] tag `tooling-green-on-source`
- [ ] (per-module milestones, added at the Phase 0 exit and mirrored in TRACE)
- [ ] tag `phase2-accepted` - the Phase 2 evidence pack signed off
- [ ] tag `retro-done` - retrospective written, `/port-contribute-to-base` run

## 9. Workstreams
| Workstream | Scope | Handoff file | Depends on |
|---|---|---|---|
| main | everything (single stream until a second workstream exists) | port/handoffs/main.md | - |

Claims: a claim untouched for <TTL> is stale and waits for the human to triage it; <who> may
release a foundation claim (`.opencode/skills/code-port/references/team-coordination.md`).

## 10. Risks
| Risk | Mitigation |
|---|---|
| First slice too trivial to exercise the workflow (no configuration superset, no latent-bug surface) | Choose a first slice with at least a parameter file, a multi-step iteration, one lookup table or nontrivial constant set, and a mix of pure and wide-footprint routines, so the per-procedure policy is really tested |
| Workflow overhead feels heavy at small scale and gets skipped | Record the friction in LESSONS instead of skipping it: the overhead is what makes the full breadth safe |

## 11. Phase retrospectives
One file per phase boundary in `port/retrospectives/`, linked here as it is written.

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
  parks a piece that fails review more often than that; `max_in_flight` caps how many workers run
  at once.

Start at L1, and raise the level once its plans look right on this codebase.
