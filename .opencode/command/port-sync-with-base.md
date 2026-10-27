---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

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
   - no stray local methodology edits: `git fetch upstream`, then list what THIS instance changed
     since its last sync outside the project layer:
     `git diff --name-only "$(git merge-base HEAD upstream/main)" HEAD | git check-attr --stdin merge | grep -v ': merge: ours$'`.
     The layer comes from `.gitattributes` itself, never a hand-kept path list (a copy drifts - it
     misses a new carve-out or a new methodology file), and diffing from the merge-base shows only
     the instance's own changes, not the incoming base ones. If it lists files, this instance edited
     or added base-owned files: where the base also changed one, the sync takes the base version
     (correct); the rest survive as local methodology. Warn the human and remind them a real
     methodology improvement belongs in /port-contribute-to-base, not as a local edit. A path listed
     as `unspecified` is in NEITHER layer - ask the human which it belongs to and record it in
     `.gitattributes` (as in step 3), or remove it if it is stray output.
1b. Create the ephemeral worktree and run steps 2-7 INSIDE it (steps 8-9 run from the
   MAIN worktree - you cannot ff `main` or remove this worktree from within it): `git fetch upstream`, then
   `git worktree add .worktrees/sync-<id> -b sync/<id> <recorded-main-tip>` (a fresh branch
   off the land target; `.worktrees/` is gitignored), and `cd` into it. The "pre-merge instance
   HEAD" referenced below IS the recorded main tip. The worktree is torn down in step 8 even if
   the command aborts.
2. Merge WITHOUT committing: from the sync worktree run
   `bash tools/coordination/sync_merge.sh upstream/main`. It runs `git merge --no-ff --no-commit
   upstream/main` (merge, never rebase - instance commits are published and merges preserve
   cherry-pick lineage; `--no-ff` keeps a merge commit with verifiable parents), only ever into this
   ephemeral `sync/<id>` branch, never `main`, then restores the project layer (step 4). It reports
   **MERGED** (staged - go to step 5), **ALREADY UP TO DATE** (nothing to sync - tear down, step 8),
   or exits 1 on a **conflict** outside the project layer, naming the paths (step 3).
3. Only a path outside the project layer can still conflict: most often a path in NEITHER layer of
   `.gitattributes` (a new top-level file), or a rename/delete/binary edge in the methodology layer.
   For a path with no layer rule, ask the human which layer it belongs to, add it to
   `.gitattributes`, and resolve it to that layer (project: keep the instance side; methodology: take
   the base side). For a methodology edge, take the base side.
4. The project layer is the instance's, unconditionally, and `sync_merge.sh` has already restored
   it: every path the merge touched whose `.gitattributes` rule is `merge=ours` is checked out from
   the pre-merge HEAD without overlay, so a file the base added there is removed and one it deleted
   comes back. The `merge=ours` driver alone is not enough: it acts only on a conflict, so a base
   change to a project file the instance left alone would merge in clean and silently overwrite it.
   The script lists the files it restored, and refuses if the project layer still differs from HEAD.
5. Post-merge checks:
   - run the conformance suite (`bash tools/run-conformance.sh`)
   - the project layer is now byte-identical to pre-merge, so no base content can
     have leaked into it; any remaining placeholder marker (`<instance`, `<TBD`)
     is pre-existing instance content, not an import.
6. Report to the human: the incoming methodology commits (subjects in the merged
   range touching methodology paths), what the driver resolved, and any judgment
   call - in particular, every project-layer file `sync_merge.sh` restored (a base change it
   kept out). A base that carries project-layer files at
   all is leaking instance content: flag it so it can be scrubbed via
   /port-contribute-to-base.
7. Commit the merge on the sync branch (still uncommitted from step 2): `git commit --no-edit`;
   verify the merge commit's parents are the recorded main tip and the base tip. Do NOT push or
   touch `main` from here.
8. **Land + tear down (auto - no keystrokes for the human).** From the MAIN worktree, when it is
   quiet and still at the recorded tip (a sprint boundary - git will not update `main` while it is
   checked out and moving elsewhere), run `tools/coordination/finalize.sh --land-only --sync
   sync/<id>`: it ff-lands the sync onto `main`, pushes origin, and tears the worktree + branch down.
   finalize.sh requires the MAIN worktree CLEAN; if you have uncommitted work there, `git stash` it
   first (do NOT commit it onto `main` - that moves `main` off the recorded tip and the ff-land then
   refuses), land, then `git stash pop`.
   Landing is only a fast-forward (the slow resolution is already done); `--land-only` carries no
   milestone tag and needs no sign-off (a methodology sync is not a phase acceptance). If `main` has
   MOVED since the recorded tip (a sprint committed meanwhile), finalize.sh REFUSES the non-ff land
   and changes nothing - it CANNOT be forced (this branch was built off the old tip). Redo the
   resolution from the new tip: discard this branch and re-run /port-sync-with-base (it records the
   new `main` tip and resolves in a fresh worktree). If an earlier step aborted before any land, still tear the worktree
   down (`git worktree remove .worktrees/sync-<id>`; `git branch -D sync/<id>`; `git worktree prune`).
9. **Post-sync maintenance (auto - leave the instance ready, no manual follow-up).** After the land,
   on `main`, run the idempotent housekeeping so the human need not remember it:
   - **Migrate the unit vocabulary (one-time):** ladder checks are now proofs and a passed unit is
     `proven` (older ports wrote gate / gated - every tool still reads those). Run <!-- legacy-vocab -->
     `python3 tools/migrate-proof-vocabulary.py`; if it lists changes, re-run with `--apply` and commit
     them (`chore(port): migrate to the proof / proven vocabulary`). It rewrites only machine-read keys
     and values in `port/` and never touches LESSONS, handoffs or evidence; a no-op once migrated. Act
     on any note it prints (e.g. take the base's `tools/scoping/port-progress.py`).
   - **Untrack instance-local config (one-time):** if `git ls-files opencode.json` is non-empty (a
     pre-gitignore instance still tracks it), `git rm --cached opencode.json` and commit it
     (`chore(port): stop tracking instance-local opencode.json`). It is now gitignored; this is a
     routine commit and pushes on the next land. A no-op once migrated.
   - **Reload reminder (the one thing a sync cannot do for you):** if the landed diff touched any
     `.opencode/agents/*.md` (e.g. an agent's mode), tell the human to RESTART opencode / open a fresh
     session so the new agent definitions take effect.
