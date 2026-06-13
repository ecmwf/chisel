# Canonical reference runs

Immutable definitions of every reference run used by a gate. Artifacts (outputs, dumps)
live outside git; this file holds the authoritative description + checksums. Every
comparison in the project traces back to a run defined here.

| ID | SOURCE commit | Build (compiler, flags) | Inputs (paths, checksums) | Settings (steps/duration) | Outputs (location, checksums) | Archived |
|---|---|---|---|---|---|---|
| (defined at Phase 0) | | | | | | |

Rules:
- A row, once a gate has used it, is **never edited** - superseded runs get a new ID
  and a note, with human sign-off recorded in the charter.
- At least one run must be at full-scale, real settings (latent-bug defense).
- The fast-rig run is defined here too, marked as iteration-only (never acceptance).
