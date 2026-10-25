# source/ - the SOURCE program

The verified original at the pinned commit recorded in `port/plan/00-charter.md` section 2,
imported by `chisel-init` / `tools/import-source.sh` into `source/<name>/` - a plain copy with
the nested `.git` removed. Never a submodule or subtree: those entangle histories and break the
in-repo pin the anchor verifier reads (`git show <pin>:source/<name>/<path>`).

**Read-only by convention.** Never edit the SOURCE. The only permitted additions are the
Phase-1 instrumentation modules (reference dumps, probes), each behind a switch and compiled
out when unset - and even those land via the charter, not ad hoc. Two guards keep
instrumentation honest:
- the SOURCE inertness proof (charter Phase 1): with every instrumentation switch unset, the
  instrumented build reproduces the pristine pinned reference run's outputs byte-for-byte
  (results, NOT a hash-identical binary - prefer compile-time switching so the instrumentation is
  absent from the build entirely);
- provenance anchors always cite the pinned commit, and the anchor verifier reads lines from
  that commit (not the working tree), so instrumentation can never shift line numbers under
  existing anchors.

Empty until `chisel-init` (or `tools/import-source.sh`) imports the program here at its pin.
