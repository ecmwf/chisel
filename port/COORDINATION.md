# COORDINATION - workstreams

> Activates when more than one workstream exists. With a single stream there is
> nothing to coordinate; kept so the structure is exercised.

## Active workstreams
| Workstream | Scope | Handoff | Status |
|---|---|---|---|
| main | everything | port/handoffs/main.md | active |

## Interface contracts between streams
(none - single stream)

## Do-not-touch locks
| Path / area | Locked by | Reason | Until |
|---|---|---|---|
| (none) | | | |

## Merge order / dependencies
A stream may only depend on another stream's output once it is `gated` in TRACE.
(none - single stream)

## State-file edit protocol (activates with the second workstream)
Global state files are shared; collisions are prevented by ownership, not luck:
- TRACE: a row is edited only by the workstream named in it; cross-stream changes
  go through this file as a request.
- LESSONS: append-only at the end; on merge conflict, the later merge renumbers its
  own new entries (L-numbers must stay unique; renumber only entries added in the
  conflicting change, never existing ones).
- Charter / conventions / KNOWN-DIVERGENCES: single-writer, milestone-paced,
  human-signed; never edited concurrently.
- Handoffs are per-workstream by construction and never shared.
