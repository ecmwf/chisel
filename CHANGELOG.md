<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Changelog

Notable changes to Chisel. Versions follow [Semantic Versioning](https://semver.org/) and are tagged
`x.y.z`.

## 0.6.0 - 2026-10-28

The first public release.

**Setting up a port**
- `uv run tools/chisel-init.py` sets up a port in one step: the workbench, the imported original
  code, the product repository, and each agent's model from opencode 2's catalog. `--dry-run`
  previews it, and uv pins the tools' Python packages (`uv.lock`).
- Chisel uses opencode 2's names and terms. The agents are Ptah-Orchestrator, Kha-Worker,
  port-review and Seshat-Integrator.

**How a port runs**
- AGENTS.md states each rule once, with requirement levels. The human's decisions - the TARGET
  language, compilers, flags and math library, the scope, the tolerance bands - are asked once and
  park only the work that needs them.
- Kha-Workers and reviews run as background agents, and each result is handled as it arrives; lands
  stay one at a time. A reviewer can fix a small finding with an exact patch that the worker
  applies verbatim.
- The build is planned from the dependency graph the compiler reports: waves, cycles and the
  critical path.
- Units are proven by proofs; the tools still read the older names. The numerical failure classes
  are N1-N11.
- Each agent's permissions enforce its limits, and autodrive can leave every land to a person.

**Checks**
- The anchor verifier compares constants by value, through the SOURCE and TARGET compilers, and
  binds them by name; comments and anchors never block.
- Build checks read the build's own compilation database: the C build contract, the sanitizer runs
  (AddressSanitizer, UndefinedBehaviorSanitizer and MemorySanitizer, now required in every R1
  proof), cross-file declarations and a clang-tidy allowlist.
- A Phase-1 tool lands only as it was reviewed, and a Phase-2 unit only as it was proven.
- The Fortran-to-C pair table gained traps T31-T37, among them vector math without fast-math (T37).

**The repository**
- REUSE-compliant licensing, a security policy, a contributing guide, code owners, and a pull
  request template with the contributor licence agreement.
- CI pins its actions, gives each token to one step, checks licensing and home-directory paths, and
  runs every tool test - the slow ones when a change touches what they check.

Earlier versions: see the [tags](https://github.com/ecmwf/chisel/tags).
