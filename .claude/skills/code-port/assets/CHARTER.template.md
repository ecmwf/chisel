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

## 2. Canonical reference run (immutable once set)
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
  - <field>: <metric> ≤ <tolerance> over <duration> at full-scale settings
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
### Phase 5 - Portability + handover: platforms <list>  [sign-off]

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
