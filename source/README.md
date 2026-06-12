# source/ - the SOURCE (Fortran)

The verified original at the pinned commit recorded in `port/plan/00-charter.md` §2.

**Read-only by convention.** Never edit the SOURCE. The only permitted additions are
the Phase-1 instrumentation modules (reference dumps, probes), each behind an
environment switch and compiled out when unset, so the uninstrumented build is
byte-for-byte unchanged - and even those land via the charter, not ad hoc.

Empty until Phase 0 places the pilot program here (vendored copy, submodule, or
subtree - record the pin either way).
