<p align="center">
  <img src="logo.png" alt="Chisel" width="320">
</p>

<p align="center">
  <a href="https://github.com/ecmwf/chisel/actions/workflows/ci.yml"><img src="https://github.com/ecmwf/chisel/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/ecmwf/chisel/tags"><img src="https://img.shields.io/github/v/tag/ecmwf/chisel?label=version&sort=semver" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg" alt="License: Apache 2.0"></a>
  <a href="https://opencode.ai"><img src="https://img.shields.io/badge/built_for-opencode-111111" alt="Built for opencode"></a>
  <a href="https://github.com/ecmwf/codex/tree/main/ESEE"><img src="https://github.com/ecmwf/codex/raw/refs/heads/main/ESEE/foundation_badge.svg" alt="ESEE Foundation"></a>
  <a href="https://github.com/ecmwf/codex/raw/refs/heads/main/Project%20Maturity#emerging"><img src="https://github.com/ecmwf/codex/raw/refs/heads/main/Project%20Maturity/emerging_badge.svg" alt="Maturity: Emerging"></a>
</p>

> [!IMPORTANT]
> This software is **Emerging** and subject to ECMWF's guidelines on [Software Maturity](https://github.com/ecmwf/codex/raw/refs/heads/main/Project%20Maturity).

Chisel is a method and toolkit for porting numerical and scientific code from one language to
another - for example Fortran to C - with AI coding agents, while keeping the results the same.

Rewriting numerical code is risky: the worst bugs don't crash. They compile, run, and produce
numbers that look right but aren't. Chisel is built to catch them:

- **The original code is the specification.** The port has to match it, and every match is shown
  by an automatic check, not by reading the code.
- **Checks come first.** The tools that compare the port with the original are built before
  anything is translated, so a mistake fails early, in one place.
- **Nothing is lost between sessions.** Plans, decisions and lessons are kept as files in the repo,
  so any agent or person can pick up where the last one stopped.

Chisel works for any pair of languages: each port records its choices (languages, program, what
counts as done) in one file, `port/plan/00-charter.md`. The tooling it ships is tuned for Fortran
to C. New here? Start with [the short tour](methodology.md).

## Quick start

You need git, Python 3 with PyYAML, and [opencode](https://opencode.ai). The GitHub CLI (`gh`) is
optional but makes setup smoother.

```bash
git clone https://github.com/ecmwf/chisel.git port-foo && cd port-foo
python3 tools/chisel-init.py        # add --dry-run to preview without changing anything
```

`chisel-init` asks whether you are **starting a new port** or **joining one** that someone else
started, and it asks before anything that writes, clones or pushes. For a new port it:

- turns this clone into your port's own repo, the *workbench*, where the work and its records live;
- creates a separate *product* repo for the translated code;
- can import the original code at a fixed commit;
- chooses an AI model for each agent.

Then open opencode and run `/port-sprint-start`. It reads where things stand and gives you the next
task.

## How a port flows

<p align="center">
  <img src="docs/assets/flow.svg" width="100%" alt="How a port flows: setup, then Phase 0 scoping and Phase 1 tooling. In Phase 2, Ptah hands three units to Kha-Workers working in parallel; each unit must pass its R1 proof and an independent review. One unit fails its proof, its lesson is recorded, and it is reworked until it passes. Seshat then lands the units in the product repo and the milestone is tagged.">
</p>

1. **Setup** - `chisel-init` creates the workbench and the product repo.
2. **Phase 0: Scoping** - pin the exact version and settings of the original code, write the
   charter, and record a reference run to compare against.
3. **Phase 1: Tooling** - build the *proofs* (automatic pass/fail checks) and the tools that compare
   the port with the original. Each proof must first be seen to catch a planted bug.
4. **Phase 2: Translation** - translate unit by unit, many units at once. A unit is done only when
   it passes its proof (R1: the same numbers as the original, bit for bit where possible) *and* an
   independent review. Failures go back for rework, and the lesson is written down.
5. **Finish** - done units land in the product repo; each phase ends with a sign-off and a git tag.

Work happens in **sprints**: one task in one fresh conversation. Each sprint ends by writing a
handoff note, so the next one starts from the files, not from memory.

## The agents

Four agents with separate powers, so that no agent can approve its own work:

| Agent | Role |
|---|---|
| **Ptah-Orchestrator** | **The one you talk to.** Plans the work, hands it out, reports progress. Never reviews or merges. |
| **Kha-Worker** | Translates one unit on its own branch and runs its proof. Many run at once. Never reviews, merges or pushes. |
| **port-review** | Checks a translation against the original in a separate session, ideally on a different model. Never edits the code. |
| **Seshat-Integrator** | Lands reviewed units in the product repo, in dependency order, through guarded scripts. Never reviews. |

`chisel-init` saves the model choices in `opencode.json`, which stays on your machine: a stronger
model for Ptah and Seshat, a cheaper one for the many workers, and a different one for the reviewer.

## The commands

You mostly need two: `/port-sprint-start` and `/port-sprint-end`. The agent suggests the others
when they are due.

| Command | Use it to |
|---|---|
| `/port-sprint-start` | Begin a session: read the handoff and get the task |
| `/port-sprint-end` | End a session: save state and write the next task |
| `/port-lesson` | Record something surprising (the agent does this on its own) |
| `/port-prove` | Run a proof on finished work and save the evidence |
| `/port-calibrate` | Set a tolerance where an exact match is impossible |
| `/port-seed` | Show that a new proof or check catches a planted bug before trusting it |
| `/port-review` | Get an independent review of a unit that passed its proof |
| `/port-land` | Mark a reviewed unit proven and land it in the product repo |
| `/port-digest` | Gather a finished phase's evidence for sign-off |
| `/port-autodrive` | Let Ptah run the loop for you (see [Auto-mode](#auto-mode)) |
| `/port-sync-with-base` | Pull in the latest Chisel improvements |
| `/port-contribute-to-base` | Send a general improvement back to Chisel |

The checks never depend on the agent being checked: reviews run in their own session, and a phase is
sealed by `finalize.sh` only after your sign-off (or, in auto-mode, after every check passes).
`/port-contribute-to-base` may open a pull request on its own, but only a person merges it. The full
rules for agents are in [AGENTS.md](AGENTS.md).

## Auto-mode

Ptah can also run the loop for you: hand out work, get it reviewed, run the proofs and land the
results. It removes the waiting, not the checks: reviews still run separately, and any failed check
stops the run. Turn it on with `/port-autodrive enable L1`.

| Level | What happens |
|---|---|
| L0 | Off (the default). Ptah only suggests. |
| L1 | Dry run: Ptah shows the plan and does nothing. Start here. |
| L2 | Ptah runs the current phase on its own, seals it, and stops. |
| L3 | Ptah runs every phase on its own. You set the bar for done once, in the charter. |

The full design is in `.opencode/skill/code-port/references/auto-mode.md`.

## What's in the repo

| Path | Contents |
|---|---|
| `port/` | The port's state: charter, progress (`TRACE.yaml`), lessons, handoffs |
| `source/` | The original code, at a fixed commit, never edited |
| `reference/` | The reference runs the port is compared against |
| `tools/` | Proofs, comparison tools, checks and helper scripts |
| `docs/evidence/` | The proof behind each sign-off |
| `.opencode/` | The agents, commands and skills |
| `VERSION` | Chisel's own version |

The translated code is not here: it lives in the product repo, linked from `port/product.yaml`.

## One Chisel, many ports

This repo is the **base**. Each port is its own repo, an *instance*, made by cloning the base - not
by forking (GitHub allows one fork per account) or by GitHub's template feature (it drops the shared
history that syncing needs). An instance keeps its own files (`port/`, `source/`, ...) and shares
Chisel's (agents, commands, tools). `/port-sync-with-base` pulls in Chisel updates without touching
the port's own files, and `/port-contribute-to-base` sends general improvements back, so each new
port starts a little further ahead.

## Learn more

- [The short tour](methodology.md) - how Chisel works, in plain words
- [AGENTS.md](AGENTS.md) - the rules every agent follows
- `.opencode/skill/` - the full method: `code-port` (what to translate and how to check it) and
  `target-conventions` (how to write the translated code)

## Licence

Copyright 2026- ECMWF.

This software is licensed under the terms of the Apache Licence Version 2.0 which can be obtained
at http://www.apache.org/licenses/LICENSE-2.0 (see [`LICENSE`](LICENSE)). In applying this
licence, ECMWF does not waive the privileges and immunities granted to it by virtue of its status
as an intergovernmental organisation nor does it submit to any jurisdiction.
