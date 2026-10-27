# CONTRIBUTIONS - <project name>

> Append-only ledger of what THIS instance has fed back to the base methodology via
> `/port-contribute-to-base`. Instance-owned (PROJECT layer): every instance has its own
> contribution history and it is NEVER upstreamed. It exists so that an infrequently-run
> contribute pass is INCREMENTAL, not from-scratch - the command reads the last entry as a
> WATERMARK (what was already sent, and from when) so it focuses the harvest on what is NEW and
> never re-proposes what is already upstreamed.
>
> HOW THE COMMAND USES IT (so it works in any instance, even one that got the methodology by sync
> rather than by init - this file lives in the project layer, which a sync does not carry):
> - It is CREATED from this template on the first contribute pass if absent.
> - The last entry's `Instance <commit>` / date is the watermark: the harvest LEADS with lessons,
>   tool mechanizations, and trap-table additions changed SINCE it, and SKIPS any ID a prior entry
>   records as `Covered`. Older-but-now-general lessons may still be surfaced deliberately - the
>   watermark FOCUSES the harvest, it does not hard-exclude.
> - When the PR opens, a `proposed` entry is appended; once the base merges and this instance syncs
>   the result back, the entry is updated to `synced-back` with the merged base commit. An empty
>   ledger (first ever pass) has no watermark - harvest from scratch and let the human's PR review
>   catch any earlier duplicate.

## LEDGER (append-only; C-numbers permanent, never reused)

### C-0001  <date>  PR <url-or-number>  Base <merged-base-commit>  Instance <instance-commit-at-contribution>
- **Covered:** <the IDs actually upstreamed this pass - lesson IDs (L-0007, ...), trap IDs (T6), tool
  paths (tools/...), or command/skill edits>
- **Summary:** <one genericized line - the pattern proposed; no project names, paths, or numbers>
- **Status:** <proposed | synced-back>

### C-0002 ...
