# target/ - the port

The translation under construction. `CONVENTIONS.md` (instantiated here at Phase 1
from the target-conventions skill) governs all rendering: naming, comments, types,
formatter, and the semantic trap table. Read it before writing any code here.

Invariants:

- Builds and runs at every commit (Prime Directive 6).
- Only mechanical transformations from charter §5 distinguish it structurally from the
  SOURCE; everything else is literal.
- Compiler and flags are pinned in the charter; deterministic settings (e.g., FMA
  behavior) are explicit, not compiler defaults.
- Status of every file is mirrored in `port/TRACE.yaml`.
