---
description: Sync this instance from the base repo (merge policy + layer rule, mechanized)
---

Bring base-repo improvements into this instance. Run BETWEEN sprints only (one
writer per worktree); this command is its own mini sprint and ends with a push.

0. Bootstrap check: if this instance predates the sync machinery (no
   `tools/base-repo.txt`, or the merge drivers are unset and `.gitattributes`
   lacks the layer rules), the instance cannot self-sync yet. Tell the human to do
   ONE manual pull first (`git pull --no-rebase --no-edit upstream main`, keeping
   the instance side on any project-layer conflict, taking the base side on any
   methodology-layer conflict), then set both drivers (step 1). That pull brings
   this command and its machinery; afterwards /port-sync-with-base is hands-off. Instances
   created by tools/new-instance.sh skip this.
1. Preconditions, stop and tell the human if any fail:
   - clean worktree (uncommitted work belongs to a sprint; finish it first)
   - the `upstream` remote: this instance records its base in
     `tools/base-repo.txt`. If `upstream` is missing, add it from that file
     (the instance knows its own way home - no need to ask the human for a URL).
     If `upstream` exists but differs from the recorded base, do NOT silently
     change it - warn the human (it may be a deliberate custom base).
   - both layer drivers are active (set if missing):
     `git config merge.ours.driver true` and
     `git config merge.theirs.driver 'cp -f %B %A'` - together they let
     `.gitattributes` resolve BOTH layers automatically.
   - no stray local methodology edits: `git fetch upstream` then
     `git diff --stat upstream/main -- ':(glob).claude/**' AGENTS.md CLAUDE.md
     README.md ':(glob).github/**' ':(glob)tools/**' ':!tools/base-repo.txt'`.
     If it shows changes, this instance edited base-owned files; the sync will
     supersede them with the base version (correct). Warn the human and remind
     them a real methodology improvement belongs in /port-contribute-to-base, not as a
     local edit.
2. Pull: `git pull --no-rebase --no-edit upstream main` (merge, never rebase:
   instance commits are published and merges preserve cherry-pick lineage).
3. The drivers resolve both layers with no hand-work: project files keep the
   instance side, methodology files take the base side. Truly manual resolution
   should occur ONLY for a path matched by neither layer in `.gitattributes` (a
   new top-level file); for those, ask the human which layer it belongs to, add
   the path to `.gitattributes`, and resolve accordingly.
4. Post-merge checks:
   - run every script in tools/conformance/
   - scan project-layer state files for placeholder markers (`<instance`,
     `<TBD`) that an auto-merge may have imported into files this instance had
     already filled; restore the instance's content where so
5. Report to the human: the incoming methodology commits (subjects in the merged
   range touching methodology paths), what the driver resolved, anything that
   needed a judgment call.
6. Commit the merge if not auto-committed; push to origin.
