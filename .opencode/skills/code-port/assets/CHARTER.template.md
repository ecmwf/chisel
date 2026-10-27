# PORT CHARTER - <project name>

> The constitution of the port. Instantiated from the code-port skill. Read at the start
> of every sprint (the relevant section, at minimum) and updated whenever scope,
> milestones, or rules change. Phase acceptance is recorded per phase - the human's Phase-0 sign-off
> sets the standard (§7); later phases are sealed hand-driven by a SIGNOFF.md or in L2/L3 by
> `finalize.sh --auto`. Detailed phase plans live in sibling files (`NN-phase-*.md`); cards in `modules/`.

## 1. Languages and frameworks
> The TARGET language is a FOUNDATIONAL human decision: at Phase 0 the agent OBSERVES the SOURCE and
> PROPOSES a recommended target with rationale, then ASKS the human and waits for their decision - it
> never infers the TARGET from the repo/instance/product name and never picks a default and proceeds.
- SOURCE: <language, version/standard, compiler+flags of the reference build>
- INTERMEDIATE (if any): <language> - rationale: <e.g., high-resource for the model;
  serial; close to TARGET family>
- TARGET: <language>
- EXECUTION MODEL: <framework/backends, e.g., serial → threads → device backends>

> Licensing and the right to port the SOURCE are human responsibilities; this
> methodology and its proofs do not check them.

## 2. Canonical reference run (each run immutable once set; the set may be augmented additively)
Run definitions are SINGLE-SOURCED in `reference/runs.md`; this section only pins
which ones are canonical (no duplicated definitions - the single-source rule):
- SOURCE program + pinned commit: <hash - the upstream commit, from
  port/provenance/<name>.yaml; port/TRACE.yaml meta.upstream_commit holds the same value>
- Canonical reference run: <run ID from reference/runs.md - must include a
  full-scale, real setting, not only a short smoke run (L1 defense)>
- Decompositions: <run IDs from reference/runs.md at two or more decompositions - the
  canonical run itself MULTI-CHUNK (partition size below the points per rank), since one
  chunk on one rank masks index-base and stride errors (L4 defense); n/a only if the
  program never partitions its arrays>
- Fast rig run: <run ID from reference/runs.md - iteration only, never acceptance>
- NOTE: every comparison in this project is against the canonical run unless a
  proof says otherwise.

## 3. Pinned configuration (the contract - Prime Directive 4)
Only this configuration is being ported. For every option: the effective value and its
provenance (parameter file vs in-source default vs compile flag), with file:line.

| Option | Effective value | Provenance (file:line) |
|---|---|---|
| ... | ... | ... |

Live subset: <N files, M lines> of <total> - authoritative list in `port/TRACE.yaml`.
Excluded subsystems (NOT ported): <list>.
How the live subset was determined: <coverage/build-log/link-map/expert + tool used>.

**Preprocessor macro state:** the pinned value of every macro that guards a dependency edge, with the file that fixes it, is in `tools/scoping/macro-state.yaml` (see `.opencode/skills/code-port/assets/macro-state.template.yaml`).

## 4. Named exceptions to literal translation (human-authorized only)
Each exception has an ID (`X-01`, `X-02`, ... - never reused), so plans, reviews and registries cite
it by ID. A detector suppression that is itself the correct semantic choice (a pragma, attribute or
lint directive, AGENTS.md "Never silence a detector") is one kind of named exception: give it a row
here and register the site in `port/conventions/allowed-suppressions.yaml` (template:
`.opencode/skills/target-conventions/assets/allowed-suppressions.template.yaml`).

| ID | Exception | Rationale | Authorized by | Date |
|---|---|---|---|---|
| (e.g., X-01) | (e.g., I/O subsystem redesigned) | ... | ... | ... |

## 5. Permitted mechanical transformations
Each entry names the transformation AND the script that performs/checks it.
- <e.g., index base 1→0 - script: tools/...>
- <e.g., storage-order conversion via central index helpers in <file> - conformance:
  tools/conformance/...>
- <e.g., module/global state → explicit context struct/argument>
Nothing outside this list is permitted without entering table 4.

## 6. Interim placeholders (bring-up scaffolding - see references/bring-up-strategy.md)
| ID | Placeholder | Stands in for | Introduced | Closure milestone | Closed (tag) |
|---|---|---|---|---|---|

A phase cannot reach final sign-off with open placeholders affecting its physics.

## 6a. Review threat model (RATIFY BEFORE THE FIRST REVIEW - see references/failure-modes.md, B20)

What a reviewer treats as BLOCKING when auditing a detector, proof, or check. Without this,
detector reviews do not converge: an adversary who already has write access to the tree admits
no fixed point, because every control added is writable by that same adversary. Fill this in
with the human before dispatching the first review; leaving it empty is a decision to argue
each finding one at a time.

Default starting point - amend to fit the project, and record who ratified it and when:

| Class | Example | Disposition |
|---|---|---|
| Honest worker error | a wrong assumption, a missed case, a plausible paraphrase | **BLOCKING** |
| Broken or vacuous detector | a check that reports green having established nothing | **BLOCKING** |
| Ordinary environmental accident | a system upgrade changing a library under a recorded bar | **BLOCKING** |
| Adversary with commit access | PATH shadowing, symlink farms, TOCTOU races on the checkout | non-blocking note |
| Configurations this port does not use | a code path excluded by the pinned configuration | non-blocking note |

Unchanged regardless of the model: **fail-closed still applies.** "Could not determine" is
never a pass. A non-blocking finding is RECORDED, not discarded.

**Review round cap:** _____ rounds per unit (2 is a reasonable default). Reaching the cap is a
signal to NARROW the unit's claim or escalate to the human for a scoping decision - not to
keep grinding. Findings that fall outside this model at the cap become recorded notes or
charter placeholders with a named closure milestone.

## 7. Stages and acceptance criteria
### Phase 0 - Scoping  [sign-off: ____ date ____]
### Phase 1 - Tooling: proofs and diff tools demonstrated on SOURCE alone  [sign-off]
### Phase 2 - Language translation. Acceptance metrics (statistical):
  Comparison is approximate equality (|a-b| <= atol + rtol*|b|); set atol and rtol
  per field (agent recommends from measured evidence, human confirms - via the guided
  calibration brief `/port-calibrate`, which records the band + its evidence here).
  - <field>: <metric> within (atol <abs bound>, rtol <rel bound>) over <duration>
    at full-scale settings
  - differential drift of <quantities>: statistically zero
  - conserved quantities: <criteria>
  [sign-off]
### Phase 3 - Execution model. Ladder instance:
  - R1 per-kernel twin: max|Δ| = 0 (deterministic backend)
  - R2 whole-run byte-identity: <run definition, fixed process count = N>
  - R3 threaded floor: <value, calibration evidence>
  - R4 accelerator proof: <steps, per-field ceilings, recorded fp floor>
  - R5 multi-run parity vs SOURCE and vs intermediate reference
  [sign-off]
### Phase 4 - Performance. Throughput target: <domain throughput>  [sign-off]
### Phase 5 - Portability + handover
  Portability-target matrix (pinned by interview, like the configuration; the agent
  builds and runs on the real target, not a stand-in):
  | Target (arch / OS / compiler / accelerator / machine) | Access + build (SSH, modules, scheduler, toolchain) | Acceptance regime | Recorded floor / signature |
  |---|---|---|---|
  | <e.g. same-arch recompile> | <...> | bit-identity vs reference (R2) | n/a |
  | <e.g. ARM, or a different vendor> | <...> | statistical parity (R5): approx-eq, atol/rtol per field | <fp floor> |
  [sign-off]

## 8. Milestones (git-tag each when passed)
- [ ] tag `phase0-signed` ...
- [ ] tag `tooling-green-on-source` ...
- [ ] ... (one line per module/kernel group; keep granular; mirror status in TRACE)

## 9. Workstreams (omit while single-stream)
| Workstream | Scope (subsystems) | Handoff file | Depends on |
|---|---|---|---|
| main | everything | port/handoffs/main.md | - |

## 10. Risks
| Risk | Mitigation |
|---|---|

## 11. Phase retrospectives
One file per phase boundary in `port/retrospectives/`; link them here.

## 12. Autodrive (orchestrator autonomy - see references/auto-mode.md)
The orchestrator may auto-drive the port without a human keystroke. This OPT-IN trades the human's
outer safety check for autonomy; it never weakens a safeguard (independence, the conformance checks, and
the bindings all still fail closed, and every action commits its evidence to git as it goes). Leave
it at L0 until the L1 plans look right on this codebase.

- `autodrive.level`: **L0** off / suggest-only (default) | **L1** plan-and-stop (dry run) | **L2**
  auto through the whole current phase, hands-off, then auto-finalize its milestone and stop at the
  phase boundary | **L3** auto across ALL phases, hands-off end-to-end, auto-finalizing each milestone.
  At L2/L3 the milestone is sealed by `finalize.sh --auto` (full conformance green + the per-piece independent
  reviews already bound to each proven commit); the "physics is preserved" acceptance is the §7
  whole-program criterion you set ONCE below, not a per-milestone keystroke.
- `autodrive.scope`: which actions the bot may perform (e.g. `claim, work, review`); any action NOT
  listed is surfaced as a recommendation and pauses the loop even at L3 (e.g. withhold `integrate`).
- `autodrive.budgets`: `max_waves: <N>`, `max_wall_clock: <duration>`, `max_cost: <amount>`,
  `max_rework: <N>` (a piece that churns review more than N times HALTS). Any budget exceeded HALTS.

Review independence is the different-model reviewer, dispatched as a separate agent session and
recorded per unit (a distinct `reviewer_id`); there is no contributor registry to configure.

Auto-land: the post-acceptance git - the milestone tag, a pending methodology-sync land, the push, and
the worktree teardown - is run for you by `tools/coordination/finalize.sh`, the only sanctioned tag/push
path. Hand-driven, it REFUSES without a committed accept-`SIGNOFF.md`. In auto-mode it is sealed by
`finalize.sh --auto`, which refuses unless autodrive is L2/L3 and the full conformance suite is green at
HEAD - so the milestone auto-finalizes with no keystroke, the checks (plus the per-piece independent
reviews bound to each proven commit) and the §7 standard being the authority.

The MACHINE-READABLE source of these is `port/autodrive.yaml` (template
`assets/autodrive.template.yaml`), which `/port-autodrive` reads; this section is the human-facing
explanation. Until you create that file, auto-mode is off (L0). Start it at L1 and raise the level only
once the plans look right on this codebase.
