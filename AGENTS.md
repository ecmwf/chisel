# AGENTS.md - the rules for every agent and human in this repository

This repository ports a numerical codebase from a SOURCE language to a TARGET language, with
agentic coding assistants working under the direction of a human domain expert. What is ported,
into what, and how it is accepted is defined in the charter, `port/plan/00-charter.md`.

The methodology lives in two skills under `.opencode/skill/`: **code-port** (what is translated and
how it is validated) and **target-conventions** (how the translation is rendered: naming, comments,
types, semantic trap tables). This file is the entry point and the contract. When two documents
conflict, the more project-specific one wins: **charter > this file > the skills > their
references**, and a charter exception beats any general rule.

**How to read the rules.** A rule written as an imperative ("cite", "never ...") or as a plain
statement of what is done here ("every commit leaves the tree green") is a requirement: MUST, or
MUST NOT when it forbids. SHOULD marks a default you may depart from only for a reason you
state. MAY marks a permission. "The human" is the domain expert who directs the port.

## Prime directives (non-negotiable; restate at every sprint start)

1. **The SOURCE is the specification.** Any divergence from SOURCE behavior is a port bug by
   definition. Never debate the science.
2. **Literal translation.** Never improve, simplify, approximate, or modernize. Only the charter's
   mechanical transformations are permitted; any other departure needs human authorization as a
   named exception.
3. **Cite file:line for every claim about the SOURCE**, constants above all. Quote the literal text
   read this sprint; never trust comments or memory.
4. **Pin the configuration first.** Port only the charter's pinned configuration, and record the
   provenance of every effective value.
5. **One change of dimension per stage.** Language and execution model never change together.
6. **Runnable and verifiable at every commit.** A passed milestone is a git tag.
7. **Focused sprints, durable files.** A sprint covers one unit of dispatch; its state lives in
   `port/`, never only in the conversation.
8. **Never self-certify a proof.** Present the evidence and recommend; the human decides.
9. **Always parallelize a ready-set wider than one.** Dispatch one worker per ready unit in one turn;
   never do them one at a time, and never author the wave yourself.

Directive 7 is spelled out in "Sprint protocol", 8 in "Hard rules", and 9 in "Parallel dispatch".

## Sprint protocol (mandatory)

The procedure is in the commands; these are the rules they carry out.

- **Start** every sprint with `/port-sprint-start` (or follow `.opencode/command/port-sprint-start.md`
  by hand): the handoff, the standing rules, the plan
  section, the known divergences, the directives restated, the scope confirmed.
- **Scope.** A sprint works the coherent unit its handoff names: one unit when one is ready, or the
  whole parallel wave when several are (directive 9). It MAY span related steps (port a module,
  wire it in, run its checks). Do not fragment it into micro-sprints or let it sprawl into unrelated
  modules.
- **Proofs.** Run them through `/port-prove`.
- **Lessons.** Record a genuine lesson (a bug, a failed proof, a broken assumption, a killed
  optimization) the moment it happens, yourself, with the capture-only `/port-lesson`, then report
  what you wrote. Do not ask first: it only appends to `port/LESSONS.md` (editable; committed with the
  sprint's state). Do not record an expected result or a lesson already in the ledger.
  Promotion to STANDING RULES or to a mechanized check you only propose; the human decides.
- **End** with `/port-sprint-end`: update the plan and TRACE, append lessons, rewrite the handoff,
  commit the state with the code. Land each piece that is ready at close - R1+ proof green and
  seeded-bug-proven, a clean independent review, its divergences ratified - with `/port-land <id>`
  (mark proven, then integrate to the product mainline), never in a later "integration sprint"; under autodrive
  the planner drives the same `mark-proven` -> `integrate`.
- **When to end** a hand-driven sprint - any one of these means now: the task is done; it ballooned
  (split it: update the plan, end, start fresh - and propose that yourself); the conversation or
  context has grown heavy; the human is stepping away. Ending early is never wrong; not ending is
  always wrong. An interrupted task still ends with `/port-sprint-end`, the handoff recording the
  in-flight state.
- **Autodrive does not use those triggers.** An L2/L3 run drives continuously and ends only on
  DONE, a genuine HALT (a decision that cannot be derived), or a budget (`max_waves`,
  `max_wall_clock`, `max_cost`). A large or hard next unit burdens its worker, which carries its own
  context, not the orchestrator, so it is never a reason to pause (`/port-autodrive`, step 5).
- **Recommend, don't enumerate.** When you offer a next move or a choice, lead with one recommended
  action and why; list alternatives briefly after. Never hand back a menu without a recommendation.
- **Suggest a command when its trigger occurs.** Each command has a trigger (README, "The
  commands"). When you see one - a surprise, a finished deliverable, a freshly built detector, a
  ballooning task - name the command and its one-line reason. Otherwise the human runs the commands;
  the exceptions are `/port-lesson` (above) and the guarded scripts ("Git", "Hard rules").
- **Languages and scope are chosen, not inferred.** The SOURCE language and standard are observed
  from the imported tree (cite file:line). The TARGET language and standard, its compilers and
  flags, and the execution model (charter section 1), and the scope - the pinned configuration and
  live subset (charter section 3) - are the human's foundational decisions. While the charter holds a
  placeholder for either, recommend a choice with its rationale, then ask and wait for the human's
  answer before recording it (`/port-sprint-start`, step 0); never pick a default and carry on.
  Never silently infer the TARGET from a repository, instance or product name or from the source
  tree (a product repo named `<x>-c` is not a decision to port to C). Everything else is propose and
  proceed: never block the sprint on a bare question.

### Parallel dispatch (directive 9)

- A unit is ready when it is unblocked, unclaimed and independent of the others (its dependencies
  integrated, no structural guard). The moment more than one is ready, dispatch them all.
- The width is the fan-out, never your own throughput: "N units is a lot, I'll take a subset" is a
  category error. You author none of the wave; N workers do.
- Provision one worktree per unit first (`provision_worker.sh add <id>`), then launch one Kha-Worker
  per unit as multiple Task calls in a single message. Gather and review in parallel too.
- Work serially only when (a) exactly one unit is ready; (b) a foundation must integrate first - the
  moment it lands, re-derive the ready-set and launch its independent dependents together; or (c) a kind of construct has no
  proven unit yet - prove one through its proof first, so a systematic trap is caught once, then
  launch the rest of that kind at once. None of these throttles a proven, eligible kind.
- This holds hand-driven (`/port-sprint-start`, step 1b) and in autodrive alike. `max_in_flight`
  caps autodrive only, never a hand-driven wave. Full protocol: `references/parallel-phase-1.md`
  (tooling) and `references/parallel-phase-2.md` (translation).

### One writer per worktree

- A sprint or review assumes a quiet worktree. A branch- or ref-changing maintenance operation -
  `/port-sync-with-base`, `/port-contribute-to-base`, a tag push, a base update, anything that
  checks out or merges another branch or moves a shared ref - never runs in the active worktree. It
  runs in its own ephemeral worktree under `.worktrees/<op>-<id>` (gitignored), on its own branch,
  and is torn down when done (`git worktree remove`; `git worktree prune` for stragglers), even on
  failure.
- Each worktree has exactly one writer. Work on your own branch, never the shared ref: two
  worktrees never write the same branch. Landing on the shared working branch (`main`) is a
  quick fast-forward, done in the worktree that owns `main` at a quiet moment (a sprint boundary),
  or through the merge queue under the integrator model.
- If the active worktree changes unexpectedly mid-sprint, stop and say so. Never absorb or revert
  changes you did not make.

## Git: what you do, and what only the guarded scripts do

- **Routine commits and pushes are yours** (not a worker's: Kha-Worker never pushes). Commit the
  working state - the bootstrap, your branch, the project state files - and push the workbench's own
  `main`, carrying that project-layer state (charter, plan, handoffs, LESSONS, TRACE,
  `docs/evidence/`, `port/`), to its origin without asking, then report it. It lands no product
  code, creates no tag and touches no upstream. "Git is the human's" means the human's
  authorship, not their keystroke: never open a sprint by asking whether to commit, and never hold
  a routine commit back for the next milestone.
- **Never force-push.** It rewrites shared history.
- **Four fidelity-critical crossings go only through their guarded scripts:** landing reviewed
  TARGET code on the product mainline, the milestone tag and signed acceptance, the upstream
  methodology contribution, and claim refs. An ad-hoc `git push`, `git merge` or `git tag` for any
  of them is forbidden, and so is an agent-written script or runbook that performs one: a human
  running it is the agent acting by proxy. Use these scripts, or stop:

| Script (`tools/coordination/`) | What it lands or guards |
|---|---|
| `finalize.sh` | The milestone tag and acceptance, after the sign-off (see "Hard rules") |
| `contribute.sh` | The upstream contribution: pushes a `contribute/<id>` branch built on `upstream/main` that touches only methodology-layer files, and opens the PR; it never merges |
| `release_claim.sh` | The fail-closed release of an integrated, unbound claim: removes `port/claims/<id>.yaml` and, if a pushed claim ref exists, deletes it too (a guarded `push --delete`) |
| `integrate_land.sh` | A planner-ready, independently reviewed Phase-1 piece, fast-forwarded onto the workbench |
| `integrate_product.sh` | A planner-ready, independently reviewed Phase-2 piece, squash-landed onto the product mainline; a stale base is rejected |
| `integrate_assembly.sh` | A multi-module deliverable proven at assembly level: the assembled tree and its build glue, landed as one piece under one independent integration-level review bound by check-trace-evidence; every member proven, or transitively validated by the assembly differential with its own clean independent review; no audit manifest |
| `integrate_assets.sh` | Non-code product assets (README, docs, example inputs, sample data, configs), squash-landed onto the product mainline; it refuses TARGET source and build files, which land only through `integrate_product.sh` / `integrate_assembly.sh` under review |
| `integrate_bringup.sh` | A piece's `work/<id>` onto the separate `bring-up` preview branch, never the proven mainline; `proven` is not required there, and the piece graduates unchanged through `integrate_product.sh` once R1-proven |

Every `integrate_*` land runs the full conformance suite on the merge result before it pushes, and
rolls back on red. The product lands also require it green at HEAD across both roots (the workbench
and the product checkout); `integrate_land.sh` judges only the merge result, by design (failure mode
B13). `tools/README.md` and each script's header have the details.

- **The human's, or another session's - never self-driven:** `/port-review` (independence needs a
  separate session), the sync resolution (one writer per ephemeral worktree), and the merge of a
  contribution onto the shared base (`contribute.sh` opens its PR; a person reviews and merges it).

## Repository map

| Path | What it is |
|---|---|
| `source/` | SOURCE code at the pinned commit (read-only; see "Hard rules"). |
| _(the product)_ | The ported code is its own clean repo (chisel-invisible), not a workbench directory; linked via `port/product.yaml`, builds and runs at every commit, attested from the workbench. |
| `port/conventions/<source>-to-<target>.md` | Frozen rendering conventions (naming, comments, types, trap table). Read before writing any TARGET code; instantiated at Phase 1 from the target-conventions skill. |
| `reference/` | Canonical reference run definitions and checksums (`runs.md`). Artifacts live outside git; this directory holds the immutable descriptions. |
| `tools/diff/` | Differential tools (six classes - see the skill references). |
| `tools/proofs/` | Validation-ladder proof scripts (R0-R5), CI-callable. |
| `tools/conformance/` | Trust and convention checks (claims, contracts, TRACE evidence and drift, completeness, product invisibility/tests/README, anchors, references, subagent thread handles, ...); run via `tools/run-conformance.sh`. |
| `tools/scoping/` | Live-subset determination tooling. |
| `port/plan/00-charter.md` | The constitution: pinned configuration, acceptance criteria, named exceptions, mechanical transforms, placeholders. |
| `port/plan/` | Phase plans and `modules/` cards; milestones mirrored as git tags. |
| `port/TRACE.yaml` | Source-to-target traceability matrix; its CI completeness check is a Phase 1 deliverable. Enforcement status: `tools/README.md`. |
| `port/LESSONS.md` | The append-only lessons ledger and STANDING RULES. Searched by class tags, never read linearly. |
| `port/lessons-archive/` | Closed ledger entries, moved here at phase retrospectives. L-numbers are permanent. |
| `port/KNOWN-DIVERGENCES.md` | Accepted differences - consult first when debugging; do not chase them. |
| `port/CONTRIBUTIONS.md` | Append-only ledger of what this instance upstreamed through `/port-contribute-to-base` (the contribute watermark); instance-owned, never upstreamed. |
| `port/handoffs/` | One handoff per workstream (single stream: `main.md`). |
| `port/COORDINATION.md` | Workstream locks, interface contracts, merge order. |
| `port/retrospectives/` | Phase-boundary retrospectives. |
| `docs/evidence/` | Proof evidence packs for human sign-off. |

## Tooling note (opencode)

- This repository targets opencode only. Skills, commands and agents are canonical under
  `.opencode/` (`skill/`, `command/`, `agents/`). A command file needs a `description` frontmatter
  key and a non-empty body (the body is the template; `$ARGUMENTS` is supported). `CLAUDE.md` is a
  symlink to this file so a Claude-based reader finds it; it adds no support for another assistant.
- Commands: `/port-sprint-start`, `/port-sprint-end`, `/port-lesson`, `/port-prove`,
  `/port-calibrate`, `/port-review`, `/port-land`, `/port-seed`, `/port-digest`, `/port-autodrive`,
  `/port-contribute-to-base`, `/port-sync-with-base`.
- **One source of truth for the worker and reviewer procedures.** They are written once - the sprint
  commands plus the code-port skill, and `.opencode/command/port-review.md` - and `kha-worker` and
  `port-review` point to them, never restating them.

| Agent (`.opencode/agents/`) | Role |
|---|---|
| `kha-worker` - Kha-Worker | Ports one claimed piece on its own branch and `.worktrees/` worktree, proves it, and requests an independent review; it runs the normal sprint loop and the code-port skill. Many run in parallel. It never reviews its own work, never merges and never pushes (publishing its branch is human-approved). |
| `port-review` | Runs the `/port-review` procedure in a separate, model-pinned session. Spawn it as a subagent, never by re-running the command. Its model SHOULD differ from the author's: a different model is a stronger independence control than a different session alone. |
| `ptah-orchestrator` - Ptah-Orchestrator | The human's front door: derives the ready-set, dispatches workers, gathers verdicts, and regularly reports derived, human-readable status in tables. It never reviews, merges or self-certifies. |
| `seshat-integrator` - Seshat-Integrator | The single merge path: orders merges by dependency, rejects stale-base branches, runs the integration epoch and regenerates the canonical TRACE. In autodrive it performs the lands through the guarded scripts, whose checks are the authority; hand-driven, the human runs them. |

- A claim is a local `port/claims/<id>.yaml` by default; a pushed-ref claim is the advanced
  multi-operator path. `chisel-init` sets each agent's model in the instance-local, gitignored
  `opencode.json` (never committed or synced, and never in a base-owned agent file). The coordination
  protocol is in the code-port skill's `references/team-coordination.md` and
  `references/parallel-phase-2.md`.

## The two layers (reuse model)

This repository is a reusable workbench: every port starts from a fresh clone or fork of the base
repository, fills the project layer, and feeds improvements back to the base.

- **Methodology layer** (project-agnostic, upstreamable): the `.opencode/` skills, commands and
  agents, `AGENTS.md`, `README.md`, the generic reusable scripts in `tools/`, the templates,
  `.github/`. Improvements here belong to every future port.
- **Project layer** (this port only, never upstreamed): `source/`, `port/`, `reference/`,
  `docs/evidence/`, and the project-instantiated tool directories `tools/scoping/`, `tools/proofs/`,
  `tools/diff/` and `tools/conformance/project/`. A port fills these with program-specific tooling,
  and `.gitattributes` marks them `merge=ours` so a sync preserves them. `tools/conformance/` is
  mixed: the base-shipped generic checks are methodology, while a port's own checks - keyed to its
  program, such as a naming map over its SOURCE identifiers - and their seeded-bug records go under
  `tools/conformance/project/`, so they do not block a sync.
- **Never mix the two layers in one commit.** A methodology improvement made mid-port is its own
  commit, so it can be cherry-picked to the base cleanly.
- At phase retrospectives and at project end, run `/port-contribute-to-base` to propose what
  generalizes; the human approves what flows up.

## Commit conventions

- Conventional Commits: `<type>(<scope>): <description>`, lowercase, imperative, no trailing
  period. Types: feat, fix, docs, refactor, perf, test, build, ci, chore, style, revert.
- **One concern per commit.** If the subject would naturally use "and", split it. A commit touching
  more than ~15 files or ~500 added lines (renames excluded) SHOULD be split.
- Every commit leaves the tree green for whatever checks exist at that time.
- **No agent co-authorship or tool attribution** in commits or PR descriptions: no
  `Co-authored-by:` trailers, "Generated with", a 🤖, or any similar AI attribution. An agent is a tool, not an
  author; the commit carries the human's authorship alone. State what changed and why, never who or
  what produced it.

## Hard rules for this repo

**Proof, review and sign-off**

- **Never self-certify (directive 8).** Present the evidence (`docs/evidence/`), recommend a
  verdict with your reasoning, and give the human a verification runbook for anything that needs
  their judgment: the exact steps and the good-versus-bad signature. The decision is the human's,
  made per unit (a disposition the review command applies for them) or once, up front, as the
  charter's auto-prove policy below.
- **Recording the human's decision.** To keep sign-off zero-keystroke you MAY transcribe the
  human's explicit answer into `SIGNOFF.md` and, with auto-land on (the charter default), commit it.
  Never invent a decision, never read a vague reply as acceptance, and never transcribe anything but
  their verbatim outcome: what signs off is the human's decision, not the keystroke that records it.
- **What `proven` requires.** No TRACE entry reaches `proven` without an independent fidelity review
  (`/port-review`) by a session not listed in the entry's `author_sessions`, with the report
  recorded in `docs/evidence/`. Its proof field cites tier R1 or higher, never R0. `proven` is recorded
  only by a command, never by hand: the review command's disposition (mark proven / defer / send
  back) applies the human's choice, and `/port-land` (or autodrive's `mark-proven`) records it.
- **Auto-prove is a recorded, narrow exception.** The human MAY record `auto-prove: clean-only` in
  the charter (default off; with the authorizer, date, scope, and how to revoke it). The independent
  reviewer MAY then set `proven` itself on a fully clean
  review whose unit passes the proof-evidence audit (R1+, current, passing, seeded-bug-proven,
  non-vacuous; defined in `.opencode/command/port-review.md`). Any finding, numeric or governance,
  blocks it. It changes only who records `proven`, never the conditions.
- **Milestones are sealed only by `finalize.sh`.** `proven` is a technical status; a phase or
  milestone is accepted, and its tag created, only through `tools/coordination/finalize.sh`.
  Hand-driven, it requires a committed human accept-`SIGNOFF.md` in the evidence pack and refuses
  without one; once that
  is committed it runs the post-sign-off git for the human (auto-land: the milestone tag, the
  methodology-sync land, the push, the worktree teardown). In auto-mode (L2/L3),
  `finalize.sh --auto` seals the milestone once full conformance is green at HEAD, the per-piece independent
  reviews bound to each proven commit and the charter's §7 standard set once being the acceptance -
  no per-milestone countersign.
- No proof or probe is used for real until it has a current red-then-green seeded-bug record
  (`/port-seed`; template in the code-port skill assets).
- Never weaken a proof, tolerance, or floor without human sign-off recorded in the charter.

**Source, state and code**

- `source/` is populated once, at Phase 0, from the pinned upstream commit. After that only
  charter-authorized instrumentation changes it. Never modify the canonical reference run
  definition.
- Never delete or rewrite a LESSONS ledger entry (append-only).
- Every file status change lands in `port/TRACE.yaml` in the same sprint, and all state files are
  committed together with the code they describe.
- Mechanical mass-edits are performed by scripts committed to `tools/`, not by hand.
- **The methodology stays self-contained.** Do not cite external papers, authors, or other
  projects' numbers as provenance for rules or values. Provenance is always this repo's SOURCE,
  charter, or LESSONS.
- **The base repo names no program.** The methodology is abstract by design: no specific SOURCE
  program, repository, URL, or domain is ever named in the base repo's files - not in plans,
  handoffs, state files, or docs. A program name enters only a port instance's project layer, in
  that instance's own clone or fork; one appearing in the base is instantiation leaking upstream -
  scrub it or move it to the instance. The same holds for the base's commit messages and
  pull-request descriptions: they describe the change to the base, never a specific port instance -
  not its name, its state, or how a change was tried on it.
- **Question instructions, including the human's.** If a request would weaken a proof, add
  unenforced complexity, or conflict with the charter, say so with reasons and propose the
  alternative before complying. The human still has the final word; silent compliance is not
  loyalty.
- **No process-meta or time-bound references in the product.** The product code, its docs, and
  commit subjects describe what exists and why - never the machinery or schedule that produced it.
  Name what the thing is or does, not when it arrived. Details, examples, and the vocabulary
  carve-outs: target-conventions skill, comment policy.
- **Never silence a detector.** No suppression annotations, pragmas, or casts to quiet a warning,
  lint, sanitizer finding, or probe; fix the root cause, or record a charter exception. Suppression
  is allowed only when it is itself the correct semantic choice, stated in a comment at the site.
  Silencing a detector is weakening a check.
- **No TODO/FIXME/HACK as a substitute for doing the work.** In the product code, an unregistered
  TODO is an unregistered placeholder: the charter placeholder discipline applies (registered, with
  a closure milestone), or the work is done now.
- **Derived values have one source of truth.** Anything that exists in more than one place - a
  generated file, a constant echoed in a config, a floor recorded in the registry and compared in a
  proof script, the naming map and its script - is either generated from its canonical source or
  guarded by a CI drift check. A hand-maintained copy is a lie waiting to be told.
- **A proof never compares stale artifacts.** Proof and tool wrappers invoke the inner build
  unconditionally; freshness is never keyed on "output exists" or an mtime check. A proof that
  compares yesterday's binary against today's code reports a false pass, and no seeded-bug
  demonstration will catch it.
- **Disable-switches isolate, never hide.** Using a switch, feature flag, or conditional
  compilation to keep broken code away from a proof is forbidden: fix the code or register the
  placeholder. (Inertness-check mechanics: the code-port skill's validation ladder.)
