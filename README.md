<p align="center">
  <img src="logo.png" alt="Project logo" width="320">
</p>

# Numerical Code Port

Fidelity-preserving translation of numerical codebases from a SOURCE language to a
TARGET language (and, where applicable, onto a new execution model), executed with
agentic coding assistants (Claude Code and opencode) under human domain-expert
direction.

## What we are trying to achieve

Valuable numerical codebases outlive the languages and hardware they were written
for. Rewriting them is risky in a way ordinary software is not: the most dangerous
bugs are silent physics errors that compile cleanly, run plausibly, and only show up
deep into production-scale runs. This repo exists to make such a translation
**trustworthy**:

- **Preserve the science, provably.** The original code is treated as the
  specification; the port must reproduce its behavior, demonstrated by evidence at
  every stage rather than by inspection or trust.
- **Convert silent failures into loud, localized ones.** Differential tooling and a
  tiered validation ladder are built before any translation, so a mistake fails a
  cheap gate immediately instead of corrupting results months later.
- **Make a long, multi-session effort cumulative.** All project state, every lesson,
  and every accepted decision live in versioned files; any session, by any agent or
  human, can pick up the work without repeating a mistake already paid for.
- **Validate the workflow before betting on it.** A pilot port of a small program
  exercises every mechanism end to end; only then does a large port run in the same
  structure.

The methodology is language-agnostic. The languages, the program under port, and every
acceptance criterion of the **current instantiation** are defined in one place:
`port/plan/00-charter.md`.

## The doctrine

Translate literally in stages, validate each stage at the strictest criterion it can
physically meet, build the differential tooling before you need it, and persist every
lesson to disk so no session repeats a mistake another session already paid for.

## Start here

| You are | Read |
|---|---|
| An agent starting a session | `AGENTS.md`, then run `/session-start` |
| A human reviewing | `port/plan/00-charter.md` (the constitution), `docs/evidence/` |
| Anyone needing the methodology | `.claude/skills/`: `code-port` (what is translated, how it is validated) and `target-conventions` (how it is rendered: naming, comments, trap tables) |

## Layout

- `source/` - SOURCE at pinned commit (read-only by convention)
- `target/` - the port; builds and runs at every commit
- `reference/` - canonical reference-run definitions and checksums
- `tools/` - differential tools, gate scripts, conformance checks, scoping tooling
- `port/` - durable project state: charter & plans, TRACE matrix, LESSONS,
  KNOWN-DIVERGENCES, handoffs, coordination, retrospectives
- `docs/evidence/` - gate evidence packs for sign-off
- `.claude/` - canonical skills + slash commands; `.opencode/` symlinks to the same

## How to work with this repo

1. **Bring the SOURCE.** The program being ported goes into `source/` at a pinned
   commit (read-only from then on). Together with the human, pin the configuration
   and define the canonical reference run in `port/plan/00-charter.md` (Phase 0).
2. **The port grows in `target/`.** It must build and run at every commit;
   rendering rules live in `target/CONVENTIONS.md` once instantiated at Phase 1.
3. **Work in short sessions.** `/session-start` loads the state files and the one
   task for this session; do that task; `/session-end` persists everything for the
   next session.    Then open a FRESH conversation and run `/session-start` again -
   the handoff carries the baton, so no context is ever hand-copied between
   sessions. Capture lessons the moment they happen with `/lesson`. One writer
   per worktree: do your own git operations (pulls, merges) BETWEEN sessions,
   never while a session is working.
4. **Validate, never trust.** Run gates with `/gate`, prove new detectors with
   `/seeded-bug`, get ported modules independently reviewed with `/review-module`.
   All evidence lands in `docs/evidence/`.
5. **Milestones need the human.** A phase or milestone is accepted only by the
   domain expert's recorded sign-off (prepared with `/evidence-digest`), then
   git-tagged.

The binding rules live in `AGENTS.md`; the full methodology in the two skills under
`.claude/skills/`.

## The commands: when to use which

If you remember nothing else: **you only ever need `/session-start` and
`/session-end`** - the agent proposes the others at the right moments. But here
is the full map, with the trigger for each:

| Command | When | Example |
|---|---|---|
| `/session-start` | First thing in EVERY new conversation, before any work | You open the agent in the morning: `/session-start` - it loads the handoff and tells you the one task |
| `/session-end` | Task done; OR task ballooned; OR conversation grown long; OR you are stepping away. When in doubt: end | You finished pinning the configuration: `/session-end` - it saves everything and writes the next task into the handoff |
| `/lesson` | THE MOMENT something surprising happens: a bug found, a gate failed, an assumption broke, an approach abandoned. Never deferred to session end | The agent discovers a parameter file overrides an in-source default it had trusted: `/lesson` records symptom, cause, and the rule that would have caught it |
| `/gate` | A deliverable claims to be done and its acceptance criterion is a script: run the tier and record evidence | A module's translation is complete: `/gate R1 <module>` - runs the check, evidence lands in `docs/evidence/` |
| `/seeded-bug` | A NEW gate, probe, or conformance script was just built, or its comparison logic changed - before its result is trusted | You built the anchor verifier: `/seeded-bug anchor-verifier` - injects a wrong constant, proves the verifier goes red, then green |
| `/review-module` | A module passed its gate and wants the `gated` status - run in a FRESH conversation that did not write the translation | New conversation: `/review-module <module>` - independent line-by-line walk against the SOURCE; clean verdict unlocks `gated` |
| `/evidence-digest` | A phase or milestone is complete and needs the human's sign-off - run BEFORE asking | Phase 1 tooling all green: `/evidence-digest phase-1` - compiles the evidence pack and a prefilled SIGNOFF.md for the human's verdict |
| `/upstream` | At phase retrospectives and at project end, in a port instance: send what generalizes back to the base repo | Phase 2 retrospective done: `/upstream phase-2` - distills lessons into genericized base-repo proposals |

Where they fall in the lifecycle:

```text
new conversation ──> /session-start
                       ... work on the one task ...
                       surprise?            ──> /lesson  (same moment)
                       built a detector?    ──> /seeded-bug  (before trusting it)
                       deliverable done?    ──> /gate  (evidence recorded)
                     /session-end ──> close conversation

fresh conversation ─> /review-module  (independent eyes; never the author session)

phase boundary ─────> /evidence-digest ──> human writes SIGNOFF.md ──> git tag
                      /upstream  (instance only: learnings flow to base)
```

Two rules of thumb: anything that produces EVIDENCE has a command (so it lands in
`docs/evidence/` in a uniform shape), and anything you might FORGET has a command
(so the protocol remembers instead of you).

## Reuse: one clone per port, learnings flow back

This repo is a template-workbench. Each port runs in its own clone/fork (shared
history is what makes contributing back a cherry-pick) and fills the project
layer: `source/`, `target/`, `port/`, `reference/`, `docs/evidence/`. Same-account
note: you cannot fork your own repo, and a branch is the wrong tool (instances
never merge back) - clone and push to a new repo instead, keeping the base as the
`upstream` remote; that is a fork in everything but the button. Avoid
template-repo generation: it disconnects history and breaks cherry-picking.
Syncing an instance from base is mechanized: run `/sync` between sessions. It
enforces the merge policy (merge, never rebase, no hand-written message),
auto-resolves conflicts by layer (`.gitattributes` gives project-layer files the
`merge=ours` driver, so the instance's side wins where it owns the file; the
command activates the driver on first run), runs the conformance checks, scans
for placeholder leakage, and summarizes what arrived. The underlying rule, for
when judgment is needed: project layer keeps the instance's side; methodology
layer takes upstream's side, and a genuine methodology improvement made in an
instance travels via `/upstream`, not as local divergence. The
methodology layer (skills, commands, templates, generic tools) is shared property:
improvements to it are kept in their own commits and proposed back to the base repo
with `/upstream` at phase retrospectives and project end, genericized and
human-approved. A port that taught the methodology nothing was observed badly.
