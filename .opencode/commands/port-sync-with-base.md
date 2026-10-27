---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Bring the base repository's methodology improvements into this port, keeping the port's own files
---

Bring the base's improvements into this port. The merge runs in its own worktree
(`.worktrees/sync-<id>`, gitignored) on its own branch, so it never disturbs a sprint or review in the
main worktree (one writer per worktree). Only the final land onto `main` needs the main worktree
quiet, at a sprint boundary. The command ends by landing, pushing and removing the worktree.

0. **Bootstrap.** A port that predates the sync machinery (no `tools/base-repo.txt`, no
   `tools/coordination/sync_merge.sh`, or no layer rules in `.gitattributes`) cannot sync itself yet.
   Ask the human for one manual pull first (`git pull --no-rebase --no-edit upstream main`, keeping
   the port's side of any project-layer conflict and the base's side of any methodology conflict);
   it brings this command and its tools. Ports set up by `chisel-init` skip this.
1. **Preconditions** - stop and tell the human if one fails:
   - Record the current `main` tip (`git rev-parse main`) as the land target. The main worktree may
     keep working while the merge is resolved, but the land (step 8) needs `main` still at this tip.
   - The `upstream` remote: if it is missing, add it from `tools/base-repo.txt`, without asking. If it
     exists but differs from that file, do not change it; warn the human (it may be a deliberate
     custom base).
   - No stray local methodology edits: `git fetch upstream`, then list what this port changed outside
     the project layer since its last sync:
     `git diff --name-only "$(git merge-base HEAD upstream/main)" HEAD | git check-attr --stdin merge | grep -v ': merge: ours$'`.
     The layers come from `.gitattributes`, never a hand-kept list. Files listed are base-owned files
     this port edited or added: where the base also changed one, the sync takes the base's version;
     the rest survive as local methodology. Warn the human: a real improvement belongs in
     `/port-contribute-to-base`. A path listed as `unspecified` is in neither layer: ask the human which
     one, record it in `.gitattributes` (as in step 3), or remove it if it is stray output.
1b. **The sync worktree.** Steps 2 to 7 run inside it; steps 8 and 9 run from the main worktree (you
    cannot fast-forward `main` or remove this worktree from inside it). `git fetch upstream`, then
    `git worktree add .worktrees/sync-<id> -b sync/<id> <recorded-main-tip>`, and work there. The
    "pre-merge HEAD" below is the recorded tip. Step 8 removes the worktree, even if the command
    stops early.
2. **Merge without committing:** `bash tools/coordination/sync_merge.sh upstream/main`, from the sync
   worktree. It merges (`--no-ff --no-commit`, never a rebase: the port's commits are published, and
   a merge commit keeps verifiable parents) only into a `sync/<id>` branch, never `main`, and restores
   the project layer (step 4). It reports MERGED (go to step 5), ALREADY UP TO DATE (nothing to sync:
   remove the worktree, step 8), or exits 1 with the conflicting paths outside the project layer
   (step 3).
3. **Conflicts.** Only a path outside the project layer can still conflict: most often a path in
   neither layer of `.gitattributes` (a new top-level file), or a rename, delete or binary edge in the
   methodology. For a path with no layer rule, ask the human which layer it belongs to, add it to
   `.gitattributes`, and resolve it to that layer (project: keep the port's side; methodology: take
   the base's side). For a methodology edge, take the base's side.
4. **The project layer stays the port's.** `sync_merge.sh` has already checked out every merged path
   marked `merge=ours` from the pre-merge HEAD, so a base change, addition or deletion there is undone.
   The `merge=ours` driver alone would not do it: it acts only on a conflict, so a base change to a
   project file the port left alone would merge in silently. The script lists what it restored, and
   refuses if the project layer still differs from HEAD.
5. **Check:** run `bash tools/run-conformance.sh`. The project layer is byte-identical to the
   pre-merge HEAD, so any placeholder left in it (`<instance`, `<TBD`) is the port's own, not an
   import.
6. **Report** to the human: the incoming methodology commits, what the drivers resolved, every
   project-layer file `sync_merge.sh` restored, and any judgment call. A base that carries
   project-layer files at all is leaking a port's content: flag it for `/port-contribute-to-base`.
7. **Commit** the merge on the sync branch, `git commit --no-edit`, and check that its parents are the
   recorded tip and the base's tip. Do not push or touch `main` from here.
8. **Land and remove the worktree.** From the main worktree, at a quiet moment with `main` still at
   the recorded tip, run `tools/coordination/finalize.sh --land-only --sync sync/<id>`. It
   fast-forwards `main` to the sync, pushes it, and removes the worktree and the branch; it carries no
   tag and needs no sign-off. It needs the main worktree clean: stash your own uncommitted work
   (`git stash`, then `git stash pop` after the land), never someone else's, and never commit onto
   `main` to get there, which would move it off the recorded tip. If `main` has moved since the
   recorded tip, `finalize.sh` refuses and changes nothing; discard the branch and run
   `/port-sync-with-base` again from the new tip. If the command stops before the land, still remove
   the worktree: `git worktree remove .worktrees/sync-<id>`, `git branch -D sync/<id>`, `git worktree
   prune`.
9. **After the land**, on `main`:
   - Run the one-time migrations; each is a no-op once applied. Run each without arguments first; if
     it lists changes, run it again with `--apply` and commit (`chore(port): ...`):
     `python3 tools/migrate-proof-vocabulary.py` (unit vocabulary; act on any note it prints) and
     `python3 tools/migrate-opencode-dirs.py` (opencode 2's folder names in the port's documents).
   - If `git ls-files opencode.json` lists it, run `git rm --cached opencode.json` and commit: it is
     local to each machine and gitignored.
   - If the landed range merged one of this port's contributions, mark its `port/CONTRIBUTIONS.md`
     entry `synced-back` with the base commit, and commit.
   - Push `main` if you committed anything.
   - If the landed diff changed any `.opencode/agents/*.md`, tell the human to restart opencode so the
     new agent definitions take effect.
