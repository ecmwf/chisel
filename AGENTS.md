<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md - the rules for every agent and human in this repository

This repository ports a numerical codebase from a SOURCE language to a TARGET language, with AI
coding agents working under the direction of a human domain expert. What is ported, into what, and
how it is accepted is defined in the charter, `port/plan/00-charter.md`.

The method lives in two skills under `.opencode/skills/`: **code-port** (what is translated and how
it is checked) and **target-conventions** (how the translation is written: naming, comments, types,
trap tables). The procedures live in the commands under `.opencode/commands/`. This file is the
contract they carry out. When two documents conflict, the more project-specific one wins:
**charter > this file > the skills > their references**, and a charter exception beats any general
rule.

**How to read the rules.** A rule written as an imperative ("cite", "never ...") or as a plain
statement of what is done here ("every commit leaves the tree green") is a requirement: MUST, or
MUST NOT when it forbids. SHOULD marks a default you may depart from only for a reason you state.
MAY marks a permission. "The human" is the domain expert who directs the port.

## Prime directives (non-negotiable; restate them at every sprint start)

1. **The SOURCE is the specification.** Any divergence from SOURCE behavior is a port bug by
   definition. Never debate the science.
2. **Literal translation.** Never improve, simplify, approximate, or modernize. Only the charter's
   mechanical transformations are permitted; any other departure needs human authorization as a
   named exception.
3. **Cite file:line for every claim about the SOURCE**, constants above all. Quote the literal text
   read this sprint; never trust comments or memory. The citation goes in your plans, evidence and
   reviews, never in the product's comments, where line numbers go stale.
4. **Pin the configuration first.** Port only the charter's pinned configuration, and record the
   provenance of every effective value.
5. **One change of dimension per stage.** Language and execution model never change together.
6. **Runnable and verifiable at every commit.** An accepted milestone is a git tag.
7. **Focused sprints, durable files.** A sprint covers one unit of dispatch; its state lives in
   `port/`, never only in the conversation.
8. **Never self-certify a proof.** Present the evidence and recommend; the human decides.
9. **Always parallelize a ready-set wider than one.** Dispatch one Kha-Worker per ready unit in one
   turn; never do them one at a time, and never write the wave yourself.

## Sprint protocol

- **Start** every sprint with `/port-sprint-start`.
- **Scope.** A sprint works the coherent unit its handoff names: one unit when one is ready, or the
  whole parallel wave when several are. It MAY span related steps (port a module, wire it in, run
  its checks). Do not fragment it into micro-sprints or let it sprawl into unrelated modules.
- **Proofs** run through `/port-prove`.
- **Lessons.** Record a genuine lesson (a bug, a failed proof, a broken assumption, a killed
  optimization) the moment it happens, with `/port-lesson`, and report what you wrote. Do not ask
  first: it only appends to `port/LESSONS.md`. Skip expected results and lessons already in the
  ledger. Promoting a lesson to a standing rule or a check is a proposal; the human decides.
- **End** with `/port-sprint-end`: it updates the plan and TRACE, appends lessons, rewrites the
  handoff, commits the state with the code, and lands every proven unit with `/port-land <id>`,
  never in a later "integration sprint".
- **When to end** a hand-driven sprint - any one of these means now: the task is done; it ballooned
  (split it: update the plan, end, start fresh, and propose that yourself); the conversation has
  grown heavy; the human is stepping away. Ending early is never wrong; not ending is. An
  interrupted task still ends with `/port-sprint-end`, the handoff recording the in-flight state.
- **Autodrive does not use those triggers.** An L2 or L3 run drives on until DONE, a budget
  (`max_waves`, `max_wall_clock`, `max_cost`), or a halt listed in `references/auto-mode.md` ("Stop
  conditions"; a red check is one). A large next unit is no reason to pause: its Kha-Worker carries
  that context, not Ptah-Orchestrator.
- **Recommend, don't enumerate.** When you offer a next move or a choice, lead with one recommended
  action and why; list alternatives briefly after. Never hand back a menu without one.
- **Run a command when its trigger occurs** (README, "The commands") - a surprise, a finished unit,
  a new detector, a ballooning task - and say why in one line. The human starts sprints and turns
  autodrive on; you run the rest. The one exception: the review of work this session wrote runs in
  another session.

### The human's decisions

- These are the human's: the TARGET language and standard, its compilers and flags, and the
  execution model (charter section 1); the scope - the pinned configuration and the live subset
  (section 3); the tolerance bands of section 7; named exceptions and accepted divergences;
  acceptance and sign-off; and a contribution to the base.
- For each, recommend one answer with its reason and ask once, up front where you can. Never record
  a default yourself, and never infer the TARGET from a repository, instance or product name or from
  the source tree (a product repo named `<x>-c` is not a decision to port to C). The SOURCE language
  and standard are observed from the imported tree (cite file:line).
- Never block the human or the run. A missing decision parks only the work that depends on it (a
  unit whose tolerance band is unset waits); everything else goes on, under autodrive too. Every
  other choice is yours: propose and proceed, never stop on a bare question.

### Parallel dispatch (directive 9)

- A unit is ready when its dependencies are integrated, it has no structural guard, and nobody has
  claimed it. The moment more than one is ready, dispatch them all.
- The width is the fan-out, never your own throughput: "N units is a lot, I'll take a subset" is a
  category error. You write none of the wave; N Kha-Workers do.
- Provision one worktree per unit first (`provision_worker.sh add <id>`), in a message that
  dispatches nothing; then start one Kha-Worker per unit with `subagent` calls in a single message.
  A subagent cannot start another, so Ptah-Orchestrator also starts the reviews, in parallel too.
- Work serially only when (a) exactly one unit is ready; (b) a foundation must integrate first - the
  moment it lands, re-derive the ready-set and launch its independent dependents together; or (c) no
  unit of a kind of construct is proven yet - prove one first, so a systematic trap is caught once,
  then launch the rest of that kind at once.
- The build schedule (`tools/coordination/schedule.py`) shows which units can be built at the same
  time (waves), which depend on each other (cycles, each ported and proven as one assembly) and the
  critical path. The planner orders the ready-set by it, so when `max_in_flight` caps a wave, the
  critical path goes first.
- This holds hand-driven and in autodrive alike; `max_in_flight` caps autodrive only. Full protocol:
  the code-port skill's `references/parallel-phase-1.md` (tooling) and
  `references/parallel-phase-2.md` (translation).

### One writer per worktree

- Each worktree has exactly one writer, on its own branch; two worktrees never write the same
  branch.
- Anything that checks out or merges another branch - a base sync, a contribution - runs in its
  own worktree under `.worktrees/<op>-<id>` (gitignored), on its own branch, and is torn down when
  done, even on failure (`git worktree remove`, then `git worktree prune`). Only the final
  fast-forward or tag runs in the main worktree, at a sprint boundary.
- A sprint or a review expects a quiet worktree. If yours changes unexpectedly, stop and say so.
  Never absorb or revert changes you did not make.

## Git: what you do, and what only the guarded scripts do

- **Routine commits and pushes are yours.** Commit the working state - the bootstrap, the project
  state files, your branch - and push the workbench's own `main` to its origin without asking, then
  report it. Such a push carries project-layer state only: no product code, no tag, nothing
  upstream. Never open a sprint by asking whether to commit, and never hold a routine commit back
  for a milestone. A Kha-Worker commits only on its own branch and never pushes.
- **Never force-push.** It rewrites shared history.
- **These go only through their scripts** (`tools/coordination/`): every land on the workbench or
  the product, a milestone tag, a base sync, a contribution push, and a pushed claim ref. An
  ad-hoc `git push`, `git merge` or `git tag` for any of them is forbidden, and so is a script or
  runbook you write to do one: a human running it is you acting by proxy. If a script refuses, fix
  the cause, or stop and say so.

| Script | What it does |
|---|---|
| `integrate_land.sh` | Fast-forwards an accepted, independently reviewed Phase-1 tooling unit onto the workbench |
| `integrate_product.sh` | Squashes a proven Phase-2 unit onto the product mainline: only the commit that was proven (`proof.commit`), on a current base |
| `integrate_assembly.sh` | Lands units proven together as one assembly, with their build glue, under one independent review of the assembled commit; each member is proven, or validated by the assembly's proof with its own clean review |
| `integrate_assets.sh` | Lands product files that are not code (README, docs, example inputs, configs); refuses source and build files |
| `integrate_bringup.sh` | Puts a unit's work branch on the product's `bring-up` preview branch, never the mainline; no proof needed |
| `finalize.sh` | Tags and pushes an accepted milestone (see "Hard rules"); `--land-only` lands a base sync |
| `sync_merge.sh` | Merges the base into a `sync/<id>` branch, keeping the project layer as it was |
| `contribute.sh` | Pushes a methodology-only `contribute/<id>` branch to the base and opens its pull request, once the human agrees; never merges |
| `push_claim.sh` | Pushes a unit's claim as `refs/claims/<id>` when several operators share a port; refuses if another operator holds the unit |
| `release_claim.sh` | Removes an integrated Phase-1 unit's claim, and its pushed claim ref if there is one |

Every `integrate_*` script reruns the full conformance suite on the merged result before it pushes,
and rolls back on red; the product scripts also require it green beforehand, across the workbench
and the product checkout. Each script's header and `tools/README.md` have the details.

- **Never yours:** the review of your own work (`/port-review` needs a session that did not write
  it) and the merge of a contribution into the base (a person reviews and merges the pull request).

## The agents

| Agent (`.opencode/agents/`) | Role |
|---|---|
| **Ptah-Orchestrator** (`ptah-orchestrator`) | The human's front door; opencode opens on it. Runs the sprint, finds the ready units, starts Kha-Workers and port-review, gathers results, lands proven units, reports status. Never reviews or certifies. |
| **Kha-Worker** (`kha-worker`) | Ports one claimed unit in its own worktree and branch, proves it, and hands it on for review. Many run at once. Never reviews, merges or pushes. |
| **port-review** (`port-review`) | Reviews one unit against the SOURCE in its own session, as `/port-review` describes. Writes its report; never edits code. |
| **Seshat-Integrator** (`seshat-integrator`) | Lands proven units through the scripts above, in dependency order, and regenerates TRACE; in autodrive Ptah-Orchestrator hands it each land. Never reviews or writes code. |

- An agent file binds a role to its limits; the procedures live once, in the commands and the
  code-port skill, and the agent files point to them.
- `chisel-init` writes each agent's model, and Ptah-Orchestrator as the agent opencode opens on, in
  the gitignored `opencode.json`. A base agent file never names a model.
- A claim is the local `port/claims/<id>.yaml` that `provision_worker.sh` writes; a pushed claim ref
  is the advanced path for several operators (`references/team-coordination.md`).

## The two layers (reuse model)

Every port starts from a clone of the base repository (not a fork: GitHub allows one per account),
fills the project layer, and feeds improvements back to the base.

- **Methodology layer** (project-agnostic, upstreamable): `.opencode/`, `AGENTS.md`, `README.md`,
  `methodology.md`, `docs/assets/`, `.github/` and the generic scripts in `tools/`. Improvements
  here belong to every future port.
- **Project layer** (this port only, never upstreamed): `source/`, `port/`, `reference/`,
  `docs/evidence/`, and the tool folders a port fills: `tools/scoping/`, `tools/proofs/`,
  `tools/diff/` and `tools/conformance/project/`. `.gitattributes` marks them `merge=ours`, so a
  sync keeps them. A port's own checks (keyed to its program, such as a naming map over its SOURCE
  identifiers) and their seeded-bug records go in `tools/conformance/project/`, never beside the
  base's generic checks.
- **Never mix the two layers in one commit.** A methodology improvement made mid-port is its own
  commit, so it can be taken to the base cleanly.
- At phase retrospectives and at project end, run `/port-contribute-to-base` to propose what
  generalizes; the human approves what goes up.

## Commit conventions

- Conventional Commits: `<type>(<scope>): <description>`, lowercase, imperative, no trailing
  period. Types: feat, fix, docs, refactor, perf, test, build, ci, chore, style, revert.
- **One concern per commit.** If the subject would naturally use "and", split it. A commit touching
  more than ~15 files or ~500 added lines (renames excluded) SHOULD be split.
- Every commit leaves the tree green for whatever checks exist at that time.
- **No agent co-authorship or tool attribution** in commits or PR descriptions: no
  `Co-authored-by:` trailers, "Generated with", a 🤖, or any similar AI attribution. An agent is a
  tool, not an author; the commit carries the human's authorship alone. State what changed and why,
  never who or what produced it.
- Every methodology-layer file carries an SPDX licence header, or an entry in `REUSE.toml`.

## Hard rules for this repo

**Proof, review and sign-off**

- **Never self-certify (directive 8).** Present the evidence (`docs/evidence/`), recommend a
  verdict with your reasoning, and give the human a runbook for anything that needs their
  judgment: the exact steps, and what good and bad look like.
- **What `proven` requires.** A green proof at tier R1 or higher (never R0) of the unit's current
  code, and a clean independent fidelity review with its report in `docs/evidence/`. The review runs
  in a session that did not write the unit (its id is not in the entry's `author_sessions`); a
  different model from the author's is recommended. Only `/port-review` records `proven`, as the
  disposition that applies the human's choice; never by hand. `/port-land` only integrates a unit
  that is already proven.
- **Auto-prove is a recorded, narrow exception.** The human MAY record `auto-prove: clean-only` in
  the charter (off by default; with who authorized it, the date, the scope, and how to revoke it).
  `/port-review` then records `proven` without asking for a fully clean review whose unit passes
  the proof-evidence audit defined there. Any finding, numeric or governance, blocks it. It changes
  only who decides, never the conditions.
- **A rebased unit is always re-proven.** It owes a fresh independent review only when its own
  target files changed; `tools/coordination/review_revalidate.sh <id>` decides, failing closed.
- **Recording the human's decision.** You MAY write the human's explicit answer into `SIGNOFF.md`
  and commit it. Never invent a decision, never read a vague reply as acceptance, and never record
  anything but their verbatim outcome: what signs off is the human's decision, not the keystroke.
- **Milestones are sealed only by `finalize.sh`.** `proven` is the status of a unit; a phase or
  milestone is accepted, and tagged, only through `tools/coordination/finalize.sh`. Hand-driven, it
  refuses without the human's accept-`SIGNOFF.md` committed at HEAD; then it tags, lands a pending
  base sync, pushes and tears down the sync worktree, so the human types no git. At L2 and L3,
  `finalize.sh --auto` seals the milestone once full conformance is green at HEAD: the acceptance is
  then the independent review every proven unit carries and the section 7 standard the human set
  once in the charter.
- No proof or probe is used for real until it has a current red-then-green seeded-bug record
  (`/port-seed`).
- Never weaken a proof, tolerance, or floor without human sign-off recorded in the charter.

**Source, state and code**

- `source/` is populated once, at Phase 0, from the pinned upstream commit. After that only
  charter-authorized instrumentation changes it. Never modify the canonical reference run
  definition.
- Never delete or rewrite a LESSONS ledger entry (append-only).
- Every status change reaches `port/TRACE.yaml` in the same sprint (through the unit's status
  fragment, where TRACE is generated), and state files are committed together with the code they
  describe.
- Mechanical mass-edits are performed by scripts committed to `tools/`, not by hand.
- **The methodology stays self-contained.** Do not cite external papers, authors, or other
  projects' numbers as provenance for rules or values. Provenance is always this repo's SOURCE,
  charter, or LESSONS.
- **The base repo names no program.** No specific SOURCE program, repository, URL or scientific
  domain appears in the base's files, commit messages or pull requests; they describe the change to
  the base, never a port's name, state, or how a change was tried on it. A program's name lives only
  in its own workbench's project layer; one found in the base is scrubbed or moved there.
- **Question instructions, including the human's.** If a request would weaken a proof, add
  unenforced complexity, or conflict with the charter, say so with your reasons and propose the
  alternative before complying. The human has the final word; silent compliance is not loyalty.
- **No process-meta or time-bound references in the product.** The product's code, docs and commit
  subjects say what exists and why, never the machinery or schedule that produced it, nor when it
  arrived. Details and carve-outs: the target-conventions skill, comment policy.
- **Never silence a detector.** No suppression annotations, pragmas, or casts to quiet a warning,
  lint, sanitizer finding, or probe; fix the root cause, or record a charter exception. Suppression
  is allowed only when it is itself the correct semantic choice, stated in a comment at the site.
  Such a suppression is a charter named exception (section 4, by its ID), registered in
  `port/conventions/allowed-suppressions.yaml`; the comment states the reason in plain words.
  Silencing a detector is weakening a check.
- **No TODO/FIXME/HACK as a substitute for doing the work.** In the product code, an unregistered
  TODO is an unregistered placeholder: the charter placeholder discipline applies (registered, with
  a closure milestone), or the work is done now.
- **Derived values have one source of truth.** Anything kept in more than one place - a generated
  file, a constant echoed in a config, a floor in the registry and in a proof script, the naming map
  and its script - is generated from its canonical source or guarded by a CI drift check. A
  hand-kept copy is a lie waiting to be told.
- **A proof never compares stale artifacts.** Proof and tool wrappers always run the inner build;
  freshness is never judged by "the output exists" or an mtime. A proof that compares yesterday's
  binary with today's code reports a false pass, and no seeded-bug demonstration catches it.
- **Disable-switches isolate, never hide.** Using a switch, feature flag, or conditional
  compilation to keep broken code away from a proof is forbidden: fix the code or register the
  placeholder. (Inertness-check mechanics: the code-port skill's validation ladder.)

## Repository map

| Path | What it is |
|---|---|
| `port/plan/00-charter.md` | The charter: languages, pinned configuration, named exceptions, mechanical transforms, placeholders, acceptance, autodrive |
| `port/plan/` | Phase plans and `modules/` cards; milestones mirrored as git tags |
| `port/TRACE.yaml` | The status of every unit, generated from `port/status/` fragments in a parallel port; `check-completeness.sh` checks it against the SOURCE |
| `port/LESSONS.md` | The append-only lessons ledger and STANDING RULES; search it by class tag. Closed entries move to `port/lessons-archive/`; L-numbers are permanent |
| `port/KNOWN-DIVERGENCES.md` | Accepted differences: consult it first when debugging; do not chase them |
| `port/SOURCE-FINDINGS.md` | Probable bugs in the SOURCE, recorded for its owners, never fixed |
| `port/conventions/` | The frozen conventions for writing this language pair, with its trap table; made at Phase 1 from target-conventions. Read them before writing TARGET code |
| `port/handoffs/`, `port/COORDINATION.md` | One handoff per workstream (`main.md` for one stream); workstream locks and merge order (the interface contracts live in the status fragments) |
| `port/CONTRIBUTIONS.md` | What this workbench has sent to the base |
| `port/retrospectives/` | Phase retrospectives |
| `source/` | The SOURCE at the pinned commit; read-only |
| `reference/` | Reference run definitions and checksums (`runs.md`); the artifacts live outside git |
| `tools/` | Conformance checks (`tools/run-conformance.sh`), coordination scripts, and the port's own proofs (`tools/proofs/`), diff tools (`tools/diff/`) and scoping tools (`tools/scoping/`); what is enforced: `tools/README.md` |
| `docs/evidence/` | Evidence packs for review and sign-off |
| _the product_ | The translated code, in its own repo with no trace of Chisel, linked from `port/product.yaml` |

## Running tools

- The human starts opencode with `uv run opencode` in the workbench, so every tool finds the Python
  packages pinned in `uv.lock`. A tool reporting a missing package (PyYAML, libclang, fparser) means
  opencode was started another way: ask the human to restart it that way; never install packages
  yourself.
- `CLAUDE.md` is a symlink to this file, for tools that look for that name.
