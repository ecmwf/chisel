# PORT CHARTER - <project name>

> The constitution of the port. Instantiated from the code-port skill. Read at the start
> of every sprint (the relevant section, at minimum) and updated whenever scope,
> milestones, or rules change. Human sign-off is recorded per phase. Detailed phase
> plans live in sibling files (`NN-phase-*.md`); per-module cards in `modules/`.

## 1. Languages and frameworks
- SOURCE: <language, version/standard, compiler+flags of the reference build>
- INTERMEDIATE (if any): <language> - rationale: <e.g., high-resource for the model;
  serial; close to TARGET family>
- TARGET: <language>
- EXECUTION MODEL: <framework/backends, e.g., serial → threads → device backends>

> Licensing and the right to port the SOURCE are human responsibilities; this
> methodology and its gates do not check them.

## 2. Canonical reference run (each run immutable once set; the set may be augmented additively)
Run definitions are SINGLE-SOURCED in `reference/runs.md`; this section only pins
which ones are canonical (no duplicated definitions - the single-source rule):
- SOURCE program + pinned commit: <hash - also mirrored in port/TRACE.yaml meta;
  consistency between the two is a TRACE conformance-script check>
- Canonical reference run: <run ID from reference/runs.md - must include a
  full-scale, real setting, not only a short smoke run (L1 defense)>
- Fast rig run: <run ID from reference/runs.md - iteration only, never acceptance>
- NOTE: every comparison in this project is against the canonical run unless a
  gate says otherwise.

## 3. Pinned configuration (the contract - Prime Directive 4)
Only this configuration is being ported. For every option: the effective value and its
provenance (parameter file vs in-source default vs compile flag), with file:line.

| Option | Effective value | Provenance (file:line) |
|---|---|---|
| ... | ... | ... |

Live subset: <N files, M lines> of <total> - authoritative list in `port/TRACE.yaml`.
Excluded subsystems (NOT ported): <list>.
How the live subset was determined: <coverage/build-log/link-map/expert + tool used>.

## 4. Named exceptions to literal translation (human-authorized only)
| Exception | Rationale | Authorized by | Date |
|---|---|---|---|
| (e.g., I/O subsystem redesigned) | ... | ... | ... |

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

## 7. Stages and acceptance criteria
### Phase 0 - Scoping  [sign-off: ____ date ____]
### Phase 1 - Tooling: gates G-*, tools T-* demonstrated on SOURCE alone  [sign-off]
### Phase 2 - Language translation. Acceptance metrics (statistical):
  Comparison is approximate equality (|a-b| <= atol + rtol*|b|); set atol and rtol
  per field (agent recommends, human confirms).
  - <field>: <metric> within (atol <abs bound>, rtol <rel bound>) over <duration>
    at full-scale settings
  - differential drift of <quantities>: statistically zero
  - conserved quantities: <criteria>
  [sign-off]
### Phase 3 - Execution model. Ladder instance:
  - R1 per-kernel twin: max|Δ| = 0 (deterministic backend)
  - R2 whole-run byte-identity: <run definition, fixed process count = N>
  - R3 threaded floor: <value, calibration evidence>
  - R4 accelerator gate: <steps, per-field ceilings, recorded fp floor>
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
outer safety check for autonomy; it never weakens a gate (independence, the conformance checks, and
the bindings all still fail closed, and every decision is recorded in the autodrive ledger). Leave
it at L0 until the L1 plans look right on this codebase.

- `autodrive.level`: **L0** off / suggest-only (default) | **L1** plan-and-stop (dry run) | **L2**
  auto within a phase, stop at every phase boundary | **L3** full auto across phases - the
  charter-bot records a `BOT_ATTESTATION.md` at each boundary, but the milestone git-tag and final
  phase acceptance STILL require a human countersign (a bot never writes `SIGNOFF.md` - the human
  sign-off that the physics is preserved is the one authority auto-mode cannot assume).
- `autodrive.scope`: which actions the bot may perform (e.g. `claim, work, review`); any action NOT
  listed is surfaced as a recommendation and pauses the loop even at L3 (e.g. withhold `integrate`).
- `autodrive.budgets`: `max_waves: <N>`, `max_wall_clock: <duration>`, `max_cost: <amount>`,
  `max_rework: <N>` (a piece that churns review more than N times HALTS). Any budget exceeded HALTS.
- `autodrive.charter_bot`: <the registered contributor id the bot signs as at L3; MUST be distinct
  from every worker/reviewer identity - it signs, it does not author or review>.

The MACHINE-READABLE source of these is `port/autodrive.yaml` (template
`assets/autodrive.template.yaml`), which `check-autodrive-integrity` enforces and `/port-autodrive`
reads; this section is the human-facing explanation. Until you create that file, auto-mode is off
(L0). Start it at L1 and raise the level only once the plans look right on this codebase.
