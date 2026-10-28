---
# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

description: Propose what this port learned that applies to every port, as a pull request to the base
---

Propose this port's general improvements to the base repository. Run it at phase retrospectives, at
project end, and when local methodology blocks a sync. You prepare the branch and the pull request,
show them to the human and ask once before opening it; people on the base review and merge it.
Nothing here merges.

Scope (a phase, or "project-end"): $ARGUMENTS

1. **Remote.** The base is the `upstream` remote. If it is missing, add it from
   `tools/base-repo.txt`, as `/port-sync-with-base` does.
2. **Ledger.** Open `port/CONTRIBUTIONS.md`; if it is missing (a port that got the methodology by
   sync has none), create it from the code-port skill's `assets/CONTRIBUTIONS.template.md`. Its last
   entry is the watermark: harvest what changed since its `Instance` commit, and skip the IDs entries
   list as `Covered`. With no entries, harvest everything.
3. **Harvest** candidates:
   - lessons in `port/LESSONS.md` and `port/lessons-archive/` whose Action says "upstream
     candidate", and standing rules that proved general;
   - checks and tools in `tools/` whose pattern is not tied to this program;
   - trap-table additions in `port/conventions/<source>-to-<target>.md` (section 7) that belong in the
     language pair's reference;
   - friction with templates, commands or skills noted during sprints;
   - negative results that generalize (the rule, not the number).

   For each, decide: propose it, leave it (specific to this port), or ask the human. A pattern needs
   at least a clear class, symptom and detector; leave one-off incidents out.
4. **Make it generic.** Remove program names, paths, domain quantities and specific numbers: the
   experience stays, anonymous, never as cited provenance. Write in the voice and structure of the
   file it goes into.
5. **Give each new capability its trigger.** Every new script, proof, check, command or standing rule
   must be invoked where it applies: named as an imperative in the phase plan and in the handoff or
   charter step, or run by a command or by CI. A tool only mentioned in passing gets bypassed. If one
   has no trigger, add it in the same pull request.
6. **Build the branch** in its own worktree off the base, never the active one: `git fetch upstream`,
   then `git worktree add .worktrees/contribute-<id> -b contribute/<id> upstream/main`. New text goes
   in fresh commits that touch only methodology files, one change each. To carry over existing
   commits, mind the layer merge drivers: under them a cherry-pick, rebase or `git am -3` replaces a
   methodology file wholesale and silently drops an earlier commit's edit to it. Apply patches
   instead (`git format-patch <range> --stdout | git am`, without `-3`), or make both drivers do a
   normal three-way merge for that one command: `git -c merge.theirs.driver='git merge-file -L ours -L base -L theirs %A %O %B'
   -c merge.ours.driver='git merge-file -L ours -L base -L theirs %A %O %B' cherry-pick <commits>`.
   Then check that every line each source commit added is in the result.
7. **Show it and ask.** Write the pull request's body to a file: generic, naming no program or port.
   Check the branch with `bash tools/coordination/contribute.sh --branch contribute/<id> --title
   "<title>" --body-file <path> --dry-run`; it refuses a branch not built on `upstream/main` or one
   that touches a project-layer file, and prints the body with the base's pull request template
   added (it carries the contributor licence agreement, which a pull request opened from the
   command line would otherwise skip). Show the human the commits, the changed files and that body,
   and ask once: "Open this pull request on the base?" On yes, run the same command without
   `--dry-run`: it pushes the branch, opens the pull request and prints its URL. Otherwise open
   nothing, and keep the branch for a revision.
8. **Record.** On the workbench `main`, never on the contribute branch (the ledger is project layer),
   add a `proposed` entry to `port/CONTRIBUTIONS.md` - a new C-number, the date, the pull request's
   URL, this port's commit, the `Covered` IDs and a one-line summary - then commit and push. Note in
   the retrospective what was proposed, what was left out, and why.
9. **Clean up.** Remove the worktree (`git worktree remove .worktrees/contribute-<id>`, then `git
   worktree prune`), even after a failed step. Keep the `contribute/<id>` branch while the pull
   request is open: a revision re-adds a worktree from it (`git worktree add
   .worktrees/contribute-<id> contribute/<id>`). Delete it once the pull request is merged or closed.

Once the base merges it, `/port-sync-with-base` brings back the merged form - the canonical one - and
marks the entry `synced-back`. Remind the human to sync their other ports too.
