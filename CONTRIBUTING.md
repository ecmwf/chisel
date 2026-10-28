<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Contributing to Chisel

Thank you for helping. Chisel follows ECMWF's
[External Contributions](https://github.com/ecmwf/codex/blob/main/Guidelines/External-Contributions.md)
guidelines.

## How a change gets in

1. Fork the repository and make your change on a branch of your fork.
2. Open a pull request to `main`. Its template carries the
   [Contributor License Agreement](https://github.com/ecmwf/codex/blob/main/Legal/Contributor-License-Agreement.md):
   by opening the pull request, you affirm that all its authors agree to it.
3. The maintainers in [CODEOWNERS](.github/CODEOWNERS) review it. For a first-time contributor, a
   maintainer also approves the CI run.
4. It merges once CI passes and a maintainer agrees.

A port improves the base with `/port-contribute-to-base`: it proposes the port's methodology changes,
made generic, as a pull request the human approves first.

To report a security vulnerability, do not open an issue or a pull request: follow
[SECURITY.md](SECURITY.md).

## What a change needs

- **Green tests and checks.** uv is the only Python setup (README, "Quick start"):

  ```bash
  uv run --locked bash tools/tests/run.sh         # the tool tests
  uv run --locked bash tools/run-conformance.sh   # the conformance checks
  uvx reuse lint                                  # the licensing of every file
  ```

  A change to a tool comes with a test that fails without it, registered in `tools/tests/run.sh`.
- **Licensing.** A new file carries the SPDX header its neighbours carry, or an entry in
  `REUSE.toml`.
- **Commits.** [Conventional Commits](https://www.conventionalcommits.org/), one concern per
  commit, and every commit leaves the tests green (AGENTS.md, "Commit conventions").
- **The rules in AGENTS.md hold for people too.** The base names no ported program, repository or
  scientific domain, and holds no home-directory path, in its files, commit messages or pull
  requests. Commits and pull requests carry no AI attribution. Methodology-layer files only
  (AGENTS.md, "The two layers").
- **AI agents are welcome.** The person who opens the pull request answers for its content and has
  checked its tests, as ECMWF's
  [guideline on AI-assisted code](https://github.com/ecmwf/codex/blob/main/Guidelines/Ai-Contributions-To-Software.md)
  asks.
