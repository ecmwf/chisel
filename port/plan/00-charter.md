# PORT CHARTER - Pilot: Fortran → C

> The constitution of the port. Read at the start of every session; updated only when
> scope, milestones, or rules change, with human sign-off per phase.
>
> **Pilot framing:** this charter governs the pilot port of a small Fortran program.
> The pilot's deliverable is not just the ported program - it is a **validated
> workflow for the serial language-port stage**: its tools, gates, state files, and
> session protocol exercised end-to-end at small scale. Treat process shortcuts as
> pilot failures even if the code comes out right. Honest scope limit: the pilot
> does NOT exercise the distributed-memory machinery (boundary probes, rank-count
> identity, execution-model ladder tiers R3-R5) - those become Phase 1 deliverables
> of the large port. The multi-workstream coordination machinery IS rehearsed here
> (see §7 Phase 2). The large port runs in a FRESH clone of the base repo (reuse
> model in AGENTS.md), seeded by the pilot's learnings flowing through /upstream
> into the base; its Phase 0 additionally delivers script-generated TRACE and
> dependency-graph-based workstream partitioning (tools/scoping/).

## 1. Languages and frameworks
- SOURCE: Fortran <TBD: standard, compiler + flags of the reference build>
- INTERMEDIATE: none (the pilot is single-stage Fortran → C-serial)
- TARGET: C <TBD: standard, compiler + flags - pin both>
- EXECUTION MODEL: serial (execution-model stages deferred to the large port)

## 2. Canonical reference run (immutable once set)
Run definitions are SINGLE-SOURCED in `reference/runs.md`; this section only pins
which ones are canonical (no duplicated definitions - the single-source rule):
- SOURCE program + pinned commit: <TBD - also mirrored in port/TRACE.yaml meta;
  consistency between the two is a TRACE conformance-script check>
- Canonical reference run: <run ID from reference/runs.md - must include a
  production-representative setting, not only a short smoke run (L1 defense)>
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
- Index base 1→0 - <script TBD, tools/>
- Column-major → row-major storage via central index helpers - helpers in <TBD>,
  conformance check in tools/conformance/ (no ad-hoc index arithmetic at call sites)
- Fortran module/COMMON globals → explicit context struct passed as argument
Nothing outside this list is permitted without entering table 4.

## 6. Interim placeholders
| ID | Placeholder | Stands in for | Introduced | Closure milestone | Closed (tag) |
|---|---|---|---|---|---|
| (none) | | | | | |

## 7. Stages and acceptance criteria
### Phase 0 - Scoping: choose pilot program, pin config, archive reference run
  [sign-off: ____]
### Phase 1 - Tooling + conventions:
  - staged dump + identical-input diff + range probes + the per-procedure
    capture-replay harness (read-set recording, fixture capture, replay driver)
    built and demonstrated on the SOURCE alone (dump/restore round-trip; probes
    silent on the reference run); gate scripts in tools/gates/ runnable by CI
  - target/CONVENTIONS.md instantiated from the target-conventions skill (naming
    map, comment policy, type/precision table, formatter config, Fortran-to-C trap
    table in force) with enforcement scripts landed in tools/conformance/
  - the provenance-anchor verifier built and CI-wired: constant anchors embed the
    literal as read; verifier checks anchor vs pinned SOURCE line and vs TARGET
    rendering, plus anchor coverage of all nontrivial constants
  - seeded-bug demonstrations: every gate and probe shown to fire on an injected
    error before first real use, recorded per SEEDED-BUG template (red proof,
    removal, green proof, logic version) in docs/evidence/
  - SOURCE inertness gate: the instrumented SOURCE build with every switch unset
    produces output identical (hash-compared) to the pristine pinned build, with
    build logs proving instrumentation is compiled out
  - tooling baseline configured per target/CONVENTIONS.md §8: pinned formatter and
    allowlisted linter in CI, sanitizer jobs (ASan/UBSan/memcheck) on the fast rig,
    coverage wired on both sides, compile_commands.json generated
  [sign-off: ____]
### Phase 2 - Translation (Fortran → C-serial), dependency order, R0 intrinsic checks
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
    (/review-module, by a session that did not write the translation; report in
    docs/evidence/, path recorded in the TRACE entry)
  - coordination rehearsal: at least one module is ported by a second workstream
    (own handoff, plan card, TRACE ownership, COORDINATION locks exercised), so the
    multi-stream machinery is validated before the large port depends on it
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
evidence pack (prepare with /evidence-digest).
- [ ] tag `pilot-phase0-signed` - program chosen, config pinned, reference archived
- [ ] tag `pilot-tooling-green-on-source`
- [ ] (per-module milestones added at Phase 0 exit, mirrored in TRACE)
- [ ] tag `pilot-accepted` - Phase 2 evidence pack signed off
- [ ] tag `pilot-retro-done` - workflow retrospective written, large-port charter drafted

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
