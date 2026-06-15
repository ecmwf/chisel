---
description: Sync this instance from the base repo (merge policy + layer rule, mechanized)
---

Bring base-repo improvements into this instance. The merge work runs in an **ephemeral
worktree** (`.worktrees/sync-<id>`, gitignored) on its own branch, so it never disturbs an
active sprint/review in the main worktree (one writer per worktree). Only the final LAND onto
`main` needs the main worktree quiet (a sprint boundary) - the slow resolution is already done
off to the side. The command ends by landing, pushing, and removing the worktree.

0. Bootstrap check: if this instance predates the sync machinery (no
   `tools/base-repo.txt`, or the merge drivers are unset and `.gitattributes`
   lacks the layer rules), the instance cannot self-sync yet. Tell the human to do
   ONE manual pull first (`git pull --no-rebase --no-edit upstream main`, keeping
   the instance side on any project-layer conflict, taking the base side on any
   methodology-layer conflict), then set both drivers (step 1). That pull brings
   this command and its machinery; afterwards /port-sync-with-base is hands-off. Instances
   created by tools/new-instance.sh skip this.
1. Preconditions, stop and tell the human if any fail:
   - record the current `main` tip (`git rev-parse main`) as the land target; the merge runs in
     a fresh worktree, so the MAIN worktree need not be idle during resolution - but the final
     land (step 8) needs `main` still at this tip (a sprint boundary)
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
     `git diff --stat upstream/main -- ':(glob).opencode/**' AGENTS.md CLAUDE.md
     README.md ':(glob).github/**' ':(glob)tools/**' ':!tools/base-repo.txt'
     ':(exclude,glob)tools/scoping/**' ':(exclude,glob)tools/gates/**'
     ':(exclude,glob)tools/diff/**'`.
     If it shows changes, this instance edited base-owned files; the sync will
     supersede them with the base version (correct). Warn the human and remind
     them a real methodology improvement belongs in /port-contribute-to-base, not as a
     local edit.
1b. Create the ephemeral worktree and run steps 2-7 INSIDE it (steps 8-9 land and tear
   down from the MAIN worktree - you cannot ff `main` or remove this worktree from within
   it): `git fetch upstream`, then
   `git worktree add .worktrees/sync-<id> -b sync/<id> <recorded-main-tip>` (a fresh branch
   off the land target; `.worktrees/` is gitignored), and `cd` into it. The "pre-merge instance
   HEAD" referenced below IS the recorded main tip. The worktree is torn down in step 9 even if
   the command aborts.
2. Merge WITHOUT committing, so the merge can be corrected before it is sealed (upstream
   was fetched in 1b): `git merge --no-ff --no-commit upstream/main` (merge, never rebase:
   instance commits are published and merges preserve cherry-pick lineage; `--no-ff` forces
   a merge commit with verifiable parents even if the branch could fast-forward). If git
   reports "Already up to date", there is nothing to sync: report that and tear down (step 9).
3. The drivers resolve both layers with no hand-work: project files keep the
   instance side, methodology files take the base side. Truly manual resolution
   should occur ONLY for a path matched by neither layer in `.gitattributes` (a
   new top-level file); for those, ask the human which layer it belongs to, add
   the path to `.gitattributes`, and resolve accordingly.
4. Enforce project-layer integrity BEFORE committing the merge. Restore the ENTIRE
   project layer to the pre-merge instance HEAD - the instance is the truth for
   project-layer files UNCONDITIONALLY:
   `git checkout <pre-merge-HEAD> -- <every project-layer path>` (every path your
   `.gitattributes` marks `merge=ours`: `port/ source/ target/ reference/
   docs/evidence/`, the project-instantiated tool subdirs `tools/scoping/ tools/gates/
   tools/diff/`, and `tools/base-repo.txt`). Derive this list from `.gitattributes`
   rather than hand-maintaining it, so a new carve-out is covered automatically. Do
   NOT trust the `merge=ours` driver to ensure
   this: it fires only on a CONFLICT (both sides changed the file), so a one-sided
   base change to a project-layer file - e.g. a base-wide refactor that sweeps a
   file the instance had not also touched - merges in CLEAN and silently clobbers
   the instance, with no conflict to warn you. Confirm the restore:
   `git diff --cached <pre-merge-HEAD> -- <project-layer paths>` must be empty.
5. Post-merge checks:
   - run every script in tools/conformance/
   - the project layer is now byte-identical to pre-merge, so no base content can
     have leaked into it; any remaining placeholder marker (`<instance`, `<TBD`)
     is pre-existing instance content, not an import.
6. Report to the human: the incoming methodology commits (subjects in the merged
   range touching methodology paths), what the driver resolved, and any judgment
   call - in particular, every project-layer file the base had changed one-sidedly
   (the clobber the restore prevented). A base that carries project-layer files at
   all is leaking instance content: flag it so it can be scrubbed via
   /port-contribute-to-base.
7. Commit the merge on the sync branch (still uncommitted from step 2): `git commit --no-edit`;
   verify the merge commit's parents are the recorded main tip and the base tip. Do NOT push or
   touch `main` from here.
8. **Land** the result onto `main`, in the MAIN worktree, when it is quiet and still at the
   recorded tip (a sprint boundary - git will not update `main` while it is checked out and
   moving elsewhere): `git merge --ff-only sync/<id>`, then push to origin. The slow
   resolution is already done; landing is only this fast-forward. If `main` has MOVED since
   the recorded tip (a sprint committed meanwhile), the `--ff-only` will refuse, and it
   CANNOT be made to fast-forward - this branch was built off the old tip. Do NOT force it.
   Redo the resolution from the new tip: discard this branch and re-run /port-sync-with-base
   (it records the new `main` tip and resolves in a fresh worktree), or rebuild on the new
   tip - branch from current `main`, merge `sync/<id>`, re-run step 4 (restore the project
   layer to current `main`) and step 5 (conformance), commit, then ff-land.
9. **Tear down:** once landed, remove the worktree and delete the sync branch
   (`git worktree remove .worktrees/sync-<id>`; `git branch -D sync/<id>`; `git worktree prune`).
   Do this even if an earlier step aborted, so no stale worktree or branch is left behind.
