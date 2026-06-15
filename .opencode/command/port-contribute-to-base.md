---
description: Distill project learnings and propose them to the base methodology repo
---

Prepare the feed-forward contribution to the base repo. Run at phase retrospectives
(recommended) and at project end (mandatory). This proposes; the human approves what
flows up.

Scope hint (phase, or "project-end"): $ARGUMENTS

1. Confirm the upstream remote exists (`git remote -v`; conventionally `upstream`
   pointing at the base repo). If absent, ask the human for it.
2. Harvest candidates, newest first:
   - LESSONS.md and `port/lessons-archive/`: entries marked as candidates for the
     skill's failure-modes reference, plus standing rules that proved general
   - built mechanizations in `tools/` whose pattern is project-agnostic
   - trap-table additions made in `target/CONVENTIONS.md` §7 that belong in the
     language reference
   - template/command/skill friction noted during sprints
   - NEGATIVE RESULTS that generalize (a campaign rule, not a number)
3. For each candidate, decide: generalizes (propose) | project-specific (leave) |
   unclear (ask the human). Bias against upstreaming one-off incidents; a pattern
   needs at least a clear class, symptom, and detector to earn a place.
4. **Genericize ruthlessly.** Strip project names, paths, domain quantities, and
   specific numbers (the base repo's self-containment rule applies: anecdotes
   survive as anonymous experience, never as cited provenance). Rewrite in the
   voice and structure of the target reference file.
5. **No dead capabilities - wire each to its trigger.** A contribution that adds a
   capability MUST add the instruction that fires it. For every new runnable or
   enforceable artifact in the contribution - a script, gate, probe, conformance
   check, command, or standing rule - confirm an agent is actually DIRECTED to it
   at its point of use: named imperatively ("run X") in the relevant phase plan
   AND the handoff/charter step where it applies, or invoked by a command, or run
   by CI. A descriptive mention is not a trigger - a tool named only in passing
   gets hand-rolled around and its checks bypassed. If a capability has no
   actionable trigger, the contribution is INCOMPLETE: add the trigger (same PR)
   before proposing. (Origin: a Phase-0 import helper once landed referenced only
   in passing, so the actionable instructions routed around its safety checks.)
6. Prepare the contribution in an **ephemeral worktree off the base**, so it never touches the
   instance's active worktree: `git fetch upstream`, then
   `git worktree add .worktrees/contribute-<id> -b contribute/<id> upstream/main` (a branch off
   the BASE's main, in `.worktrees/`, gitignored) - the instance's object store already holds
   upstream, so no separate clone is needed. Build the contribution there: methodology-layer
   commits are cherry-pickable by the commit-separation rule; new distillations become fresh
   commits touching ONLY methodology-layer files, one logical change per commit. Push
   `contribute/<id>` to the base remote (or your fork of it) and open the PR against the base
   repo (gh). Then **tear down the worktree**: `git worktree remove .worktrees/contribute-<id>`
   (`git worktree prune` for any straggler); do this even if a step aborted. Unlike sync's
   throwaway branch, KEEP the local `contribute/<id>` branch - it backs the open PR, so PR
   revisions re-add a worktree from it (`git worktree add .worktrees/contribute-<id> contribute/<id>`);
   delete it only once the PR is merged or closed.
7. Record in the retrospective what was proposed, what was deliberately not
   upstreamed, and why.
8. Close the loop: once the base merges the proposal, run /port-sync-with-base in this instance
   (and tell the human to /port-sync-with-base any other active instances) so everyone receives
   the accepted, possibly amended form. A contribution is not landed for an
   instance until that instance has synced it back - the base's merged version,
   not the local draft, is the canonical one.
