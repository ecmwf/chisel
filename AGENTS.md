# AGENTS.md - normative instructions for all agents and humans

This repository hosts the **port of a numerical codebase from a SOURCE language to a
TARGET language**, executed with agentic coding assistants under human domain-expert
direction. The current instantiation (languages, program, acceptance criteria) is
defined in `port/plan/00-charter.md`. A pilot port of a small program runs first to
validate the full workflow; the large port follows in the same structure.

The complete methodology lives in two skills: **code-port** (what is translated and
how it is validated) and **target-conventions** (how the translation is rendered:
naming, comments, types, semantic trap tables), both under `.claude/skills/`. This
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
   recommend; the human decides yes or no, and the decision line is theirs alone.

## Sprint protocol (mandatory)

- **Start:** run `/port-sprint-start` (or follow `.claude/commands/port-sprint-start.md`
  manually): handoff → standing rules → plan section → known divergences → restate
  directives → confirm scope.
- **During:** work the coherent unit named in the handoff - it may span several
  related steps (port a module, wire it in, run its checks); do not fragment it
  into micro-sprints, and do not let it sprawl across unrelated modules. Capture
  lessons the moment they happen (`/port-lesson`). Run gates via `/port-gate`.
- **Command reflexes (suggesting is a duty).** Every command has a trigger (README,
  "when to use which"). The moment you observe one - a surprise, a finished
  deliverable, a freshly built detector, a ballooning task - surface the command
  with its one-line reason instead of waiting to be asked. Over-suggesting is
  cheap to wave off; a missed trigger loses what the moment knew.
- **Autorun is opt-in and narrow.** By default you SUGGEST; the human runs. The
  human may enable autorun for capture-only `/port-lesson` (you record it and report
  what you wrote, so it can be refined - the ledger is append-only and editable).
  Everything else stays human-run, because self-driving it breaks an invariant:
  `/port-review` (independence needs a SEPARATE session), `/port-sync-with-base` and any git
  push/merge (one writer per worktree, between sprints only), `/port-contribute-to-base`
  (human-curated push to the shared base), and any milestone tag, gate
  acceptance, or SIGNOFF (never self-certified). Suggest these; never auto-run
  them.
- **One writer per worktree.** Human git operations (pulls, merges, checkouts,
  tag pushes) happen BETWEEN sprints, never during one: a sprint assumes a
  quiet worktree, and concurrent mutation means stale agent context, swept-in
  merge state, and mixed commits. Mid-task need to sync? /port-sprint-end, do the
  git work, fresh /port-sprint-start - the base-commit check reconciles. Agents: if
  the worktree changes unexpectedly mid-sprint, stop and say so; never absorb
  or revert changes you did not make.
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
| `target/` | The port. Must build and run at every commit. |
| `target/CONVENTIONS.md` | Frozen rendering conventions (naming, comments, types, trap table). Read before writing any TARGET code; instantiated at Phase 1 from the target-conventions skill. |
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
| `port/handoffs/` | One handoff per workstream (single stream: `main.md`). |
| `port/COORDINATION.md` | Workstream locks, interface contracts, merge order. |
| `port/retrospectives/` | Phase-boundary retrospectives. |
| `docs/evidence/` | Gate evidence packs for human sign-off. |

## Tooling note (Claude Code + opencode)

This repo is used by both Claude Code and opencode agents simultaneously.
- `CLAUDE.md` is a symlink to this file. opencode reads `AGENTS.md` natively and
  prefers it over CLAUDE.md.
- The skills and slash commands are canonical under `.claude/` and symlinked into
  `.opencode/` (`skill/`, `command/`). Edit the canonical copies only.
  Verified against opencode's implementation: its discovery follows symlinks; it
  also reads `.claude/skills/` natively (so the skill symlink is redundancy against
  that compat being disabled), but it does NOT read `.claude/commands/` - the
  command symlink is load-bearing. Command files need a `description` frontmatter
  key and a non-empty body (the body is the template; $ARGUMENTS is supported).
- Commands: `/port-sprint-start`, `/port-sprint-end`, `/port-lesson`, `/port-gate`, `/port-review`,
  `/port-seed`, `/port-digest`, `/port-contribute-to-base`, `/port-sync-with-base`.

## The two layers (reuse model)

This repo is a reusable workbench: every port starts from a fresh clone/fork of the
base repo, fills the project layer, and feeds improvements back to the base.

- **Methodology layer** (project-agnostic, upstreamable): `.claude/` skills and
  commands, `AGENTS.md`, `README.md`, generic scripts in `tools/`, the templates,
  `.github/`. Improvements here belong to every future port.
- **Project layer** (this port only, never upstreamed): `source/`, `target/`,
  `port/`, `reference/`, `docs/evidence/`.

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

## Hard rules for this repo

- `source/` is populated once, at Phase 0, from the pinned upstream commit. After
  that, never modify its content except charter-authorized instrumentation; never
  modify the canonical reference run definition.
- Never weaken a gate, tolerance, or floor without human sign-off recorded in the
  charter; never delete or rewrite LESSONS ledger entries (append-only).
- No TRACE entry reaches `gated` without an independent fidelity review
  (`/port-review`) by a session not listed in the entry's `author_sessions`, with
  the report recorded in `docs/evidence/`. The gate field cites tier R1 or higher,
  never R0.
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
- **No process-meta or time-bound references in the product.** `target/` code, its
  docs, and commit subjects describe what exists and why - never the machinery or
  schedule that produced it. Name what the thing IS or DOES, not when it arrived.
  Details, examples, and the vocabulary carve-outs: target-conventions skill,
  comment policy.
- **Never silence a detector.** No suppression annotations, pragmas, or casts to
  quiet a warning, lint, sanitizer finding, or probe; fix the root cause, or
  record a charter exception. Suppression is allowed only when it is itself the
  correct semantic choice, stated in a comment at the site. Silencing a detector
  is weakening a gate.
- **No TODO/FIXME/HACK as a substitute for doing the work.** In `target/`, an
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
- **No em-dashes anywhere we write**: not in code, comments, docs, plans, state
  files, or commit messages. Use a plain hyphen, a colon, or restructure the
  sentence. Vendored third-party text (`source/`, `node_modules/`) is exempt: it
  is read-only upstream content. Upstream text FLOWING into our files follows
  its nature: prose (inherited comments, quoted SOURCE text) is normalized to a
  hyphen, a mechanical transform; TARGET string literals are program output and
  stay byte-verbatim, allowlisted for the check with a justification per entry.
  (Enforced: files via `tools/conformance/no-emdash.sh` + its allowlist, latest
  commit message via CI.)
