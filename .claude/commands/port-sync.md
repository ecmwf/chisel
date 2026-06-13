---
description: Sync this instance from the base repo (merge policy + layer rule, mechanized)
---

Bring base-repo improvements into this instance. Run BETWEEN sessions only (one
writer per worktree); this command is its own mini session and ends with a push.

0. Bootstrap check: if this instance predates the sync machinery (no
   `tools/base-repo.txt`, or the `merge.ours.driver` config is unset and
   `.gitattributes` lacks the project-layer rules), the instance cannot self-sync
   yet. Tell the human to do ONE manual pull first
   (`git pull --no-rebase --no-edit upstream main`, resolving any project-layer
   conflicts by keeping the instance side), then `git config merge.ours.driver
   true`. That pull brings this command and its machinery; afterwards /port-sync
   works hands-off. Instances created by tools/new-instance.sh skip this.
1. Preconditions, stop and tell the human if any fail:
   - clean worktree (uncommitted work belongs to a session; finish it first)
   - the `upstream` remote: this instance records its base in
     `tools/base-repo.txt`. If `upstream` is missing, add it from that file
     (the instance knows its own way home - no need to ask the human for a URL).
     If `upstream` exists but differs from the recorded base, do NOT silently
     change it - warn the human (it may be a deliberate custom base).
   - the layer driver is active: `git config merge.ours.driver true` (set it if
     missing; it activates the .gitattributes project-layer rule)
2. Pull: `git pull --no-rebase --no-edit upstream main` (merge, never rebase:
   instance commits are published and merges preserve cherry-pick lineage).
3. Conflicts surviving the driver are rare. Resolve by layer:
   - methodology-layer path (.claude/, AGENTS.md, README.md, tools/, .github/,
     .gitattributes): `git checkout --theirs <path>` - the base owns it. If the
     instance had deliberately edited it, that improvement belongs upstream:
     flag it for /port-upstream instead of keeping local divergence.
   - project-layer path (port/, source/, target/, reference/, docs/evidence/):
     `git checkout --ours <path>` - the instance owns it.
   - anything else: ask the human, then `git add`.
4. Post-merge checks:
   - run every script in tools/conformance/
   - scan project-layer state files for placeholder markers (`<instance`,
     `<TBD`) that an auto-merge may have imported into files this instance had
     already filled; restore the instance's content where so
5. Report to the human: the incoming methodology commits (subjects in the merged
   range touching methodology paths), what the driver resolved, anything that
   needed a judgment call.
6. Commit the merge if not auto-committed; push to origin.
