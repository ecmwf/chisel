# docs/evidence/

Evidence packs for proofs, reviews, seeded-bug demonstrations, digests, and
sign-offs. This directory stores REPORTS, MANIFESTS, CHECKSUMS, and small logs -
never large artifacts.

Large artifacts (reference outputs, dumps, profiles) live outside git. Every
external artifact referenced from an evidence pack must have: an immutable
ID/path, a checksum recorded in the pack's manifest, and the command that
re-verifies it. An evidence pack whose external artifacts cannot be re-verified is
rotten and cannot support a sign-off.

Layout: `<date>-<kind>-<subject>/`. Kinds and their primary file: `proof`,
`review`, and `digest` packs carry `report.md`; `seeded` packs carry
`SEEDED-BUG.md` (from the code-port skill template). `SIGNOFF.md` is added
wherever acceptance is recorded.
