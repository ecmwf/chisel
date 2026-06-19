# AGENTS.md - normative instructions for all agents and humans

This repository hosts the **port of a numerical codebase from a SOURCE language to a
TARGET language**, executed with agentic coding assistants under human domain-expert
direction. The current instantiation (languages, program, acceptance criteria) is
defined in `port/plan/00-charter.md`. A pilot port of a small program runs first to
validate the full workflow; the large port follows in the same structure.

The complete methodology lives in two skills: **code-port** (what is translated and
how it is validated) and **target-conventions** (how the translation is rendered:
naming, comments, types, semantic trap tables), both under `.opencode/skill/`. This
file is the entry point and the contract. On any conflict the precedence is:
**charter (port/plan/00-charter.md) > this file > the skills > their references** -
the more project-specific document wins, and a charter exception beats any general
rule.

## Prime directives (non-negotiable; restate at every sprint start)

1. **The SOURCE is the specification.** Any divergence of the port from SOURCE
   behavior is a port bug by definition. Never debate the science.
2. **Literal translation.** Never improve, simplify, approximate, or modernize. Only
   the mechanical transformations listed in the charter are permitted; deliberate
   departures require human authorization as named exceptions.
3. **Cite file:line for every claim about the SOURCE** - especially constants. Quote
   the literal text read this sprint. Never trust comments or memory.
4. **Pin the configuration first.** Only the charter's pinned configuration is being
   ported; record provenance for every effective value.
5. **One change of dimension per stage.** Language and execution model never change
   together.
6. **Runnable and verifiable at every commit.** Milestone passed = git tag.
7. **Focused sprints, durable files.** A sprint covers one coherent unit of work
   (a module and its checks, not a single function), ended when the unit is done
   or the context grows heavy - whichever comes first. State lives in `port/`,
   not in conversation.
8. **Never self-certify a gate.** Present evidence (`docs/evidence/`), RECOMMEND a
   verdict with reasoning, and hand the human a concrete verification runbook for
   anything needing their judgment (exact steps + good-vs-bad signature). You
   recommend; the human decides yes or no, and the decision line is theirs alone -
   exercised either per unit (a disposition the review command applies for them) or
   once, up front, as a charter-recorded auto-gate policy for clean independent
   reviews - never an author certifying their own work. To keep sign-off zero-keystroke you
   MAY transcribe the human's EXPLICIT answer into `SIGNOFF.md` and (with auto-land on, the
   charter default) commit it for them, but never invent a decision, never read a vague reply
   as acceptance, and never transcribe anything but their verbatim outcome - what signs off is
   the human's explicit DECISION, not the keystroke that records it.

## Sprint protocol (mandatory)

- **Start:** run `/port-sprint-start` (or follow `.opencode/command/port-sprint-start.md`
  manually): handoff → standing rules → plan section → known divergences → restate
  directives → confirm scope.
- **During:** work the coherent unit named in the handoff - it may span several
  related steps (port a module, wire it in, run its checks); do not fragment it
  into micro-sprints, and do not let it sprawl across unrelated modules. Record a
  genuine lesson the moment it happens - auto-run capture-only `/port-lesson`, then report
   it - rather than asking the human to. Run gates via `/port-gate`.
- **Recommend, don't enumerate.** Whenever you offer the human a next move or a choice, LEAD with ONE
  recommended action and WHY (the rationale that makes it the right next step); list any alternatives
  after, briefly. Never hand back a flat menu ("tell me which") without a recommendation - the human
  can always override, but should never have to supply judgment you already have.
- **Languages are CHOSEN, not inferred - but propose and PROCEED, don't stall.** The SOURCE
  language/standard is OBSERVED from the imported tree (cite file:line). The TARGET language/standard,
  its compilers + flags, and the execution model are the HUMAN's decision: lead with a recommended
  default + rationale, RECORD it in charter section 1, and carry on with the (TARGET-agnostic) scoping
  - the human confirms or redirects at the next checkpoint (`/port-digest`). Never SILENTLY infer the
  TARGET from the repo/instance/product name or the source tree (a product repo named `<x>-c` is not a
  decision to port to C), but never block the sprint on a bare question either.
- **Command reflexes (suggesting is a duty).** Every command has a trigger (README,
  "when to use which"). The moment you observe one - a surprise, a finished
  deliverable, a freshly built detector, a ballooning task - surface the command
  with its one-line reason instead of waiting to be asked. Over-suggesting is
  cheap to wave off; a missed trigger loses what the moment knew.
- **Capture lessons autonomically; suggest everything else.** The moment a GENUINE lesson
  surfaces (a bug, a failed gate, a broken assumption, a killed optimization), RECORD it
  yourself via the capture-only `/port-lesson` procedure - do not stop to ask, and do not defer
  it to a human keystroke. Self-running it is safe: it only appends to `port/LESSONS.md`
  (instance-owned, append-only, editable, uncommitted until the human commits) and breaks no
  invariant. Report what you wrote so the human can refine it, and only PROPOSE the promotion to
  STANDING RULES or to a mechanized check (those the human decides). Do not record a non-lesson
  (an expected result) or one already in LESSONS.md.
  Most other commands you SUGGEST; the human runs. The one mechanical exception is AUTO-LAND
  (the charter default): once a human accept-`SIGNOFF.md` is COMMITTED, the post-sign-off git - the
  milestone tag, the methodology-sync LAND, the push, the worktree teardown - is run for the human by
  `tools/coordination/finalize.sh`, which REFUSES without that committed accept-signoff. The recorded
   sign-off gates it, not the keystrokes; finalize.sh, `tools/coordination/contribute.sh`, `tools/coordination/release_claim.sh` (the narrow, fail-closed `push --delete` of an integrated, unbound claim ref), and `tools/coordination/integrate_land.sh` (the gated fast-forward land of a planner-ready, independently-reviewed Phase-1 piece - re-verifying full conformance at HEAD AND on the merge result, clean FF, then pushing; in autodrive the integrator runs it so the land happens with no keystroke, the gates being the authority) are the only sanctioned push paths - ad-hoc
  `git push`/`git merge`/`git tag` outside them stays off-limits, INCLUDING an agent-authored script or
  runbook that performs a merge/push/tag (a human running an agent's merge script is the agent merging
  BY PROXY, not the human being the actor - it is the same forbidden ad-hoc path; use the sanctioned
  scripts or stop). (AUTO-CONTRIBUTE:
  `/port-contribute-to-base` opens its PR via `contribute.sh`, which REFUSES unless the branch is a
  `contribute/<id>` built on `upstream/main` touching ONLY methodology-layer files - no project
  content leaks upstream - and which pushes + opens the PR but NEVER merges.) Still human, or a separate session,
  never self-driven: `/port-review` (independence needs a SEPARATE session), the sync RESOLUTION (one
  writer per ephemeral `.worktrees/` worktree), the MERGE of a contribution onto the
  shared base (its PR is auto-opened above; you review and merge it), gate ACCEPTANCE, and the SIGNOFF decision itself - a bot writes `BOT_ATTESTATION.md`,
  never `SIGNOFF.md`, so finalize.sh refuses in auto-mode and the milestone tag waits for a human
  countersign.
- **Auto-gate is a recorded, narrow exception.** The human may record `auto-gate: clean-only`
  in the charter (default off; with the authorizer, date, scope, and how to revoke): the
  independent reviewer (a separate session, never the author) may then set `status: gated`
  itself on a FULLY clean review whose unit passes the gate-evidence audit (R1+, current,
  passing, seeded-bug-proven, non-vacuous - defined in `.opencode/command/port-review.md`). This
  is not self-certification (the reviewer is independent and the human authorized the policy) and
  changes only WHO records `gated`, never its conditions; any finding blocks it, and milestone
  tag/acceptance/SIGNOFF stay human and never auto-driven. Off unless the charter turns it on.
  (`/port-review` itself still runs only in a separate session - independence is unchanged.)
- **One writer per worktree.** A sprint or review assumes a quiet worktree: concurrent
  mutation of the files under it means stale agent context, swept-in merge state, and mixed
  commits. So a **branch- or ref-changing maintenance operation** - `/port-sync-with-base`,
  `/port-contribute-to-base`, a tag push, a base-update, anything that checks out or merges
  another branch or moves a shared ref - does NOT commandeer the active worktree. It runs in its **own ephemeral worktree
  under `.worktrees/<op>-<id>`** (gitignored), on its own branch, and is torn down when done
  (`git worktree remove`; `git worktree prune` for any straggler), even on failure. Each
  worktree still has exactly ONE writer - the invariant holds - while the active sprint/review
  keeps running untouched. Operate on your own branch, never the shared ref: two worktrees must
  not both write the same branch (git refuses to update a branch checked out elsewhere anyway).
  The one synchronization point that remains is **landing** the result on the shared working
  branch (`main`): the slow resolution already happened off to the side, so landing is a quick
  fast-forward, done in the worktree that owns `main` at a quiet moment (a sprint boundary) -
  or, under the team/integrator model, through the merge queue. Agents: if the active worktree
  changes unexpectedly mid-sprint, stop and say so; never absorb or revert changes you did not
  make.
- **End:** run `/port-sprint-end`: update plan + TRACE, append lessons, rewrite handoff,
  commit state with code.
- **When to end** (any one of these means now): the handoff's task is done; the
  task ballooned (split it: update the plan, end, fresh sprint - propose this
  yourself when you notice); the conversation has grown long; the human is
  stepping away. Ending early is never wrong - /port-sprint-start rebuilds context
  from files in a minute. Not ending is always wrong - what the conversation
  learned dies with it. An interrupted task still ends with /port-sprint-end: the
  handoff records the in-flight state and the next sprint resumes it.

## Repository map

| Path | What it is |
|---|---|
| `source/` | SOURCE code at the pinned commit. **Read-only by convention** - never edit; instrumentation goes through the charter. |
| _(the product)_ | The ported code is its OWN clean repo (chisel-invisible), not a workbench dir; linked via `port/product.yaml`, builds/runs at every commit, attested from the workbench. |
| `port/conventions/<source>-to-<target>.md` | Frozen rendering conventions (naming, comments, types, trap table). Read before writing any TARGET code; instantiated at Phase 1 from the target-conventions skill. |
| `reference/` | Canonical reference run definitions + checksums (`runs.md`). Artifacts live outside git; this dir holds the immutable descriptions. |
| `tools/diff/` | Differential tools (six classes - see skill references). |
| `tools/gates/` | Validation-ladder gate scripts (R0–R5), CI-callable. |
| `tools/conformance/` | Purity/convention checks (index helpers only, sizing rules, …). |
| `tools/scoping/` | Live-subset determination tooling. |
| `port/plan/00-charter.md` | **The constitution**: pinned config, acceptance criteria, named exceptions, mechanical transforms, placeholders. |
| `port/plan/` | Phase plans and `modules/` cards; milestones mirrored as git tags. |
| `port/TRACE.yaml` | Source→target traceability matrix; CI completeness check is a Phase 1 deliverable. Enforcement status table: `tools/README.md`. |
| `port/LESSONS.md` | Global append-only lessons ledger + STANDING RULES. Searched by Class tags, never read linearly. |
| `port/lessons-archive/` | Closed ledger entries, moved here at phase retrospectives. L-numbers permanent. |
| `port/KNOWN-DIVERGENCES.md` | Accepted differences - consult FIRST when debugging; do not chase. |
| `port/CONTRIBUTIONS.md` | Append-only ledger of what this instance upstreamed to the base via `/port-contribute-to-base` (the contribute watermark); instance-owned, never upstreamed. |
| `port/handoffs/` | One handoff per workstream (single stream: `main.md`). |
| `port/COORDINATION.md` | Workstream locks, interface contracts, merge order. |
| `port/retrospectives/` | Phase-boundary retrospectives. |
| `docs/evidence/` | Gate evidence packs for human sign-off. |

## Tooling note (opencode)

This repo targets opencode.
- Skills, slash commands, and agents are canonical under `.opencode/` (`skill/`,
  `command/`, `agents/`) - there is no second assistant to keep in sync. Command files
  need a `description` frontmatter key and a non-empty body (the body is the template;
  $ARGUMENTS is supported).
- `CLAUDE.md` is a courtesy symlink to `AGENTS.md` so a Claude-based reader finds the same
  governance file; this is NOT Claude Code support - there is no legacy assistant-specific
  skills, commands, or agents tree, and the methodology is opencode-only.
- Commands: `/port-sprint-start`, `/port-sprint-end`, `/port-lesson`, `/port-gate`, `/port-review`,
  `/port-seed`, `/port-digest`, `/port-contribute-to-base`, `/port-sync-with-base`.
- **Worker**: `.opencode/agents/kha-worker.md` - **Kha-Worker**, the standard sprint agent that
  ports one claimed piece on its own branch + `.worktrees/` worktree. Many run in parallel; each
  authors and gates its own piece and requests an independent review, but never reviews its own
  work, never merges, and never pushes (publishing the branch and the claim are human-gated).
  chisel-init sets its model in the instance-local, gitignored `opencode.json` (never committed
  or synced - your own model choices; default latest Sonnet, a capable lower-cost model for the
  most numerous role); it executes the normal sprint loop + the
  code-port skill - the procedure is NOT restated in the agent file (the one-source-of-truth rule).
- Independent review runs as a model-pinned subagent named `port-review` - the same name as
  the command because it IS the command's review executed in a separate agent whose model is
  pinned per instance in `opencode.json` (by chisel-init, not the base-owned agent file);
  spawn it via the task/subagent mechanism, never by re-running the command. It is
  `.opencode/agents/port-review.md`; the review PROCEDURE is edited only in the command
  (`.opencode/command/port-review.md`), never copied into the agent (the one-source-of-truth
  rule). Prefer a reviewer model DIFFERENT from the author's: a different model is a stronger
  independence control than a different session alone.
- The auto-run audit runs as a second model-pinned subagent, `port-review-autorun` - the auto-run
  analogue of `port-review` whose subject is the RUN, not a module (it replays the deterministic
  planner against the ledger and audits independence + the fail-closed invariants); used only when
  auto-mode is on. It is `.opencode/agents/port-review-autorun.md`; the procedure lives only in its
  command (`.opencode/command/port-review-autorun.md`), never copied into the agent. Its model is
  pinned per instance in `opencode.json` (default the same `gpt-5.5` as `port-review`), distinct from
  the orchestrator it audits - the session that drove the run never reviews it.
- **Coordination agents** (parallel work): `.opencode/agents/ptah-orchestrator.md` -
  **Ptah-Orchestrator**, the orchestrator and human front door (derives the ready-set, dispatches
  workers, gathers verdicts, and regularly reports DERIVED human-readable status in tables; it
  NEVER reviews, merges, or self-certifies) - and `.opencode/agents/seshat-integrator.md` -
  **Seshat-Integrator**, the single merge path
  (orders the dependency-ordered merge, rejects stale-base branches, runs the integration
  epoch, records the audit manifest; in autodrive it PERFORMS the land via the sanctioned gated
  scripts - the gates are the authority, not the keystroke - run by hand the human runs them).
  The trust core (review independence, one gated merge path,
  human sign-off) is unchanged. They execute the protocol in the code-port skill's
  `references/team-coordination.md` and `references/parallel-phase-2.md`.

## The two layers (reuse model)

This repo is a reusable workbench: every port starts from a fresh clone/fork of the
base repo, fills the project layer, and feeds improvements back to the base.

- **Methodology layer** (project-agnostic, upstreamable): `.opencode/` skills,
  commands, and agents, `AGENTS.md`, `README.md`, generic reusable scripts in `tools/`, the
  templates, `.github/`. Improvements here belong to every future port.
- **Project layer** (this port only, never upstreamed): `source/`,
  `port/`, `reference/`, `docs/evidence/`, and the project-instantiated tool
  subdirectories `tools/scoping/`, `tools/gates/`, `tools/diff/`, and `tools/conformance/project/`
  - a port fills these with program-specific tooling, and `.gitattributes` marks them
  `merge=ours` so a sync preserves them. (`tools/conformance/` is mixed: base-shipped generic
  checks are methodology; a port's OWN checks - keyed to this program, e.g. a naming map over
  this SOURCE's identifiers - and their seeded-bug records go under `tools/conformance/project/`,
  which `.gitattributes` carves out as project-layer so they are not treated as base-verbatim
  methodology and do not block a sync.)

**Commit discipline: never mix the two layers in one commit.** A methodology
improvement made mid-port must be its own commit so it can be cherry-picked to the
base repo cleanly. At phase retrospectives and at project end, run `/port-contribute-to-base` to
distill and propose what generalizes (human approves what flows up).

## Commit conventions

- Conventional Commits: `<type>(<scope>): <description>`, lowercase, imperative,
  no trailing period. Types: feat, fix, docs, refactor, perf, test, build, ci,
  chore, style, revert.
- **One concern per commit.** If the subject would naturally use "and", split.
  A commit touching more than ~15 files or ~500 added lines (renames excluded) is
  a smell: split it.
- Methodology-layer and project-layer changes never mix in one commit (see The
  two layers).
- Every commit leaves the tree green for whatever checks exist at that time.
- **No agent co-authorship or tool attribution in commits.** An agent is a tool,
  not an author: never add `Co-authored-by:` trailers, "Generated with", "🤖", or
  any similar AI/assistant attribution to commit messages (or PR descriptions). The
  commit carries the human's authorship alone. State what changed and why in the
  body; never who or what produced it (sibling of the no-process-meta rule).
- **You make the routine commits - don't ask whether to.** Committing the working state - the
  bootstrap, your branch, the state files - is yours: just do it and report what you committed. Only
  PUSH, MERGE, the milestone TAG, and SIGN-OFF are human-/charter-gated; the trust boundary is the
  shared line, never the local commit. "Git is the human's" means the human's AUTHORSHIP (no AI
  attribution), not the human's keystroke - never open a sprint by asking whether to commit.

## Hard rules for this repo

- `source/` is populated once, at Phase 0, from the pinned upstream commit. After
  that, never modify its content except charter-authorized instrumentation; never
  modify the canonical reference run definition.
- Never weaken a gate, tolerance, or floor without human sign-off recorded in the
  charter; never delete or rewrite LESSONS ledger entries (append-only).
- No TRACE entry reaches `gated` without an independent fidelity review
  (`/port-review`) by a session not listed in the entry's `author_sessions`, with
  the report recorded in `docs/evidence/`. The gate field cites tier R1 or higher,
  never R0. Who flips the status to `gated` is command-driven, not hand-written: the
  review command presents a disposition (gate / defer / send back) and applies the
  human's choice. By default the human chooses per unit; with the charter's opt-in
  `auto-gate: clean-only` standing approval, the independent reviewer may set `gated`
  itself on a FULLY clean review whose unit has present, non-vacuous R1+ gate evidence -
  ANY finding (numeric or governance) blocks it. The conditions for `gated` never change;
  only who is authorized to record it once they hold.
- No gate or probe is used for real until it has a current red-then-green
  seeded-bug record (`/port-seed`, template in the code-port skill assets).
- `gated` is a technical status. Phase/milestone acceptance is the human's
  SIGNOFF.md in the evidence pack; a milestone tag is created only after it exists.
- The methodology stays self-contained: do not cite external papers, authors, or
  other projects' numbers as provenance for rules or values. Provenance is always
  this repo's SOURCE, charter, or LESSONS.
- **The base repo names no program.** The methodology is abstract by design: no
  specific SOURCE program, repository, URL, or domain is ever named in the base
  repo's files - not in plans, handoffs, state files, or docs. A program name
  enters only a port instance's project layer, in that instance's own clone/fork.
  A concrete program appearing in the base is instantiation leaking upstream:
  scrub it or move it to the instance. (Sibling of the self-containment rule:
  that one keeps other projects out of our provenance; this one keeps our own
  ports out of the shared methodology.)
- Question instructions, including the human's: if a request would weaken a gate,
  add unenforced complexity, or conflict with the charter, say so with reasons and
  propose the alternative before complying. The human still has the final word;
  silent compliance is not loyalty.
- **No process-meta or time-bound references in the product.** The product code, its
  docs, and commit subjects describe what exists and why - never the machinery or
  schedule that produced it. Name what the thing IS or DOES, not when it arrived.
  Details, examples, and the vocabulary carve-outs: target-conventions skill,
  comment policy.
- **Never silence a detector.** No suppression annotations, pragmas, or casts to
  quiet a warning, lint, sanitizer finding, or probe; fix the root cause, or
  record a charter exception. Suppression is allowed only when it is itself the
  correct semantic choice, stated in a comment at the site. Silencing a detector
  is weakening a gate.
- **No TODO/FIXME/HACK as a substitute for doing the work.** In the product code, an
  unregistered TODO is an unregistered placeholder: the charter placeholder
  discipline applies (registered, with a closure milestone) or the work is done
  now.
- **Derived values have one source of truth.** Anything that exists in more than
  one place - a generated file, a constant echoed in a config, a floor recorded
  in the registry and compared in a gate script, the naming map and its script -
  is either generated from its canonical source or guarded by a CI drift check.
  A hand-maintained copy is a lie waiting to be told.
- **A gate never compares stale artifacts.** Gate and tool wrappers invoke the
  inner build unconditionally; freshness is never keyed on "output exists" or an
  mtime check. A gate that compares yesterday's binary against today's code
  reports a false pass, and no seeded-bug demonstration will catch it.
- **Disable-switches isolate, never hide.** Using a switch, feature gate, or
  conditional compilation to keep broken code away from a gate is forbidden: fix
  the code or register the placeholder. (Inertness-check mechanics: the code-port
  skill's validation ladder.)
- Every file status change lands in `port/TRACE.yaml` in the same sprint.
- Mechanical mass-edits are performed by scripts committed to `tools/`, not by hand.
- All state files are committed together with the code they describe.
