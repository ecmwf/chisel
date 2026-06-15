# source/ - the SOURCE (Fortran)

The verified original at the pinned commit recorded in `port/plan/00-charter.md` §2.

**Read-only by convention.** Never edit the SOURCE. The only permitted additions are
the Phase-1 instrumentation modules (reference dumps, probes), each behind an
environment switch and compiled out when unset - and even those land via the
charter, not ad hoc. Two guards keep instrumentation honest:
- the SOURCE inertness gate (charter Phase 1): the instrumented build with all
  switches unset is hash-identical to the pristine pinned build;
- provenance anchors always cite the pinned commit, and the anchor verifier reads
  lines from that commit (not the working tree), so instrumentation can never
  shift line numbers under existing anchors.

Empty until Phase 0 places the pilot program here (plain copy, submodule, or
subtree - record the pin either way).
