# COORDINATION - workstreams

> Used once more than one workstream exists. Claims and status fragments do the mechanical
> coordination (`.opencode/skills/code-port/references/team-coordination.md`); this file records
> what they do not: the streams, the locks the human sets, and the merge order.

## Active workstreams
| Workstream | Scope | Handoff | Status |
|---|---|---|---|
| main | everything | port/handoffs/main.md | active |

## Interface contracts between streams
A shared seam is a versioned contract in the status fragments (`provides_contract`,
`consumes_contracts`), checked by `tools/conformance/check-contracts.sh`. List here only a contract
the streams agreed on before it has a fragment.
(none - single stream)

## Do-not-touch locks
| Path / area | Locked by | Reason | Until |
|---|---|---|---|
| (none) | | | |

## Merge order / dependencies
A stream depends on another stream's output only once that output is `proven` in TRACE.
(none - single stream)

## Shared state files
- TRACE: once status fragments exist it is generated from them and nobody edits it by hand;
  before that, a row is edited only by the workstream it names.
- LESSONS: append at the end; on a merge conflict, the later merge renumbers only its own new
  entries, so L-numbers stay unique.
- Charter, conventions, KNOWN-DIVERGENCES: one writer at a time, paced by milestones and signed by
  the human; never edited concurrently.
- Handoffs: one per workstream, never shared.
