# docs/evidence/

Evidence packs for gates, reviews, seeded-bug demonstrations, digests, and
sign-offs. This directory stores REPORTS, MANIFESTS, CHECKSUMS, and small logs -
never large artifacts.

Large artifacts (reference outputs, dumps, profiles) live outside git. Every
external artifact referenced from an evidence pack must have: an immutable
ID/path, a checksum recorded in the pack's manifest, and the command that
re-verifies it. An evidence pack whose external artifacts cannot be re-verified is
rotten and cannot support a sign-off.

Layout: `<date>-<kind>-<subject>/` with `report.md`, plus `SIGNOFF.md` where
acceptance is recorded. Kinds: `gate`, `review`, `seeded`, `digest`.
