# tools/

All instrumentation, gates, and automation. Design rules (full detail in the skill's
`references/differential-tooling.md`):

- Every diff/probe tool sits behind an environment variable and is **compiled out**
  when unset - instrumentation off ⇒ reference build byte-for-byte unchanged.
- Dump formats are raw and exactly specified (endianness, record layout, tags:
  step/substep/location/field) and read back exactly by the other side.
- One small module per tool; resist merging them.
- Gates have exit-code semantics and are CI-callable. Evidence goes to `docs/evidence/`.

| Dir | Contents |
|---|---|
| `diff/` | The six tool classes: staged reference dump, identical-input/replay operator diff, range probes, boundary/communication probe, subsystem disable-switches, executable contracts. Plus the poison-discriminator helper. |
| `gates/` | Validation-ladder tiers (R0–R5) as scripts, one per tier/kernel-group. |
| `conformance/` | Convention enforcement: central index helpers only, sizing rules, no raw vendor API in portable code, TRACE completeness check, provenance-anchor verifier (anchors vs pinned SOURCE lines vs TARGET renderings, plus coverage). |
| `scoping/` | Live-subset determination (build-log/coverage/link-map analysis). |

Mechanical mass-transforms (charter §5) also live here as reviewed, committed scripts.
