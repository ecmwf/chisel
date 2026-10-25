---
description: Distill project learnings and propose them to the base methodology repo
---

Prepare the feed-forward contribution to the base repo. The agent PREPARES and OPENS this
AUTOMATICALLY (`contribute.sh` opens the PR; it never merges) at phase retrospectives, at project
end, AND whenever local methodology blocks a sync - then the contribution is the unblocker, so do
NOT ask whether to contribute: prepare it and open the PR. This PROPOSES; the human approves what
flows up by reviewing and MERGING the PR on the base - that merge is the only human-approved step.

Scope hint (phase, or "project-end"): $ARGUMENTS

1. Confirm the upstream remote exists (`git remote -v`; conventionally `upstream`
   pointing at the base repo). If absent, ask the human for it.
1b. **Read the contribution ledger - this pass is incremental, not from-scratch.** Open
   `port/CONTRIBUTIONS.md`; if it is ABSENT (an instance that received the methodology by sync, not
   by init - the ledger is project-layer, which a sync does not carry), CREATE it first from
   `.opencode/skill/code-port/assets/CONTRIBUTIONS.template.md`. Its last entry is the WATERMARK: the
   `Instance <commit>` / date is "scan since," and the `Covered` IDs across entries are what is
   already upstreamed. An EMPTY ledger (first ever pass) has no watermark - harvest from scratch and
   rely on the human's PR review to catch any earlier duplicate.
2. Harvest candidates, LEADING with what changed since the watermark and SKIPPING anything the ledger
   already records as `Covered` (an older-but-now-general item may still be surfaced deliberately -
   the watermark focuses the harvest, it does not hard-exclude):
   - LESSONS.md and `port/lessons-archive/`: entries marked as candidates for the
     skill's failure-modes reference, plus standing rules that proved general
   - built mechanizations in `tools/` whose pattern is project-agnostic
   - trap-table additions made in `port/conventions/<source>-to-<target>.md` §7 that belong in the
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
   enforceable artifact in the contribution - a script, proof, probe, conformance
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
   commits are cherry-pickable by the commit-separation rule - but NOT under this repository's
   sync merge drivers, which resolve EVERY merge (cherry-pick, rebase, `am -3`) by replacing a
   methodology file wholesale with the picked version, erasing any edit its parent lacked (an
   earlier part's change to the same file) at exit 0. So when assembling this branch, or rebasing
   it for a PR revision, either apply by patch (`git format-patch <range> --stdout | git am`, no
   `-3`) or override both drivers for that one command:
   `git -c merge.theirs.driver='git merge-file -L ours -L base -L theirs %A %O %B' -c merge.ours.driver='git merge-file -L ours -L base -L theirs %A %O %B' cherry-pick <commits>`.
   Then VERIFY the union: every line each source commit added is present in the assembled tree
   (unless a later part deliberately changed it) - a postcondition, never an exit code. New
   distillations become fresh commits touching ONLY methodology-layer files, one logical change
   per commit. Draft the
   genericized PR body to a file. Then **auto-open the PR** (no keystrokes for the human): run
   `bash tools/coordination/contribute.sh --branch contribute/<id> --title "<title>" --body-file <path>`.
   It SHAPE-VERIFIES the branch (built on `upstream/main`, every changed file methodology-layer -
   it REFUSES if any project-layer file would leak upstream), pushes it, opens the PR against the
   base, and reports the URL. It NEVER merges: landing the proposal on the shared base stays the
   human's act - they review and merge on the PR, which is where the genericization is judged.
   With the PR open, **append a `proposed` entry to `port/CONTRIBUTIONS.md`** (a new C-number, the
   date, the PR URL, this instance's commit, the `Covered` IDs actually upstreamed this pass, and a
   one-line genericized summary), and commit it - so even before the merge the watermark reflects this
   pass and a re-run will not re-harvest the same items.
   Then **tear down the worktree**: `git worktree remove .worktrees/contribute-<id>`
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
   not the local draft, is the canonical one. Then **update this pass's `port/CONTRIBUTIONS.md` entry
   to `synced-back`** and record the merged BASE commit - that entry is the watermark the next pass
   reads.
