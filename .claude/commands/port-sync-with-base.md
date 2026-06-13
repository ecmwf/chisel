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
2. Pull WITHOUT committing, so the merge can be corrected before it is sealed:
   first record the pre-merge instance HEAD (`git rev-parse HEAD`), then
   `git pull --no-commit --no-rebase upstream main` (merge, never rebase: instance
   commits are published and merges preserve cherry-pick lineage).
3. The drivers resolve both layers with no hand-work: project files keep the
   instance side, methodology files take the base side. Truly manual resolution
   should occur ONLY for a path matched by neither layer in `.gitattributes` (a
   new top-level file); for those, ask the human which layer it belongs to, add
   the path to `.gitattributes`, and resolve accordingly.
4. Enforce project-layer integrity BEFORE committing the merge. Restore the ENTIRE
   project layer to the pre-merge instance HEAD - the instance is the truth for
   project-layer files UNCONDITIONALLY:
   `git checkout <pre-merge-HEAD> -- <every project-layer path>` (the paths your
   `.gitattributes` marks `merge=ours`; conventionally `port/ source/ target/
   reference/ docs/evidence/`). Do NOT trust the `merge=ours` driver to ensure
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
7. Commit the merge (still uncommitted from step 2): `git commit --no-edit`; verify
   the merge commit's parents are the pre-merge HEAD and the base tip. Push to origin.
