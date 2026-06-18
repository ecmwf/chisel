# CONTRIBUTIONS - <instance name>

> Append-only ledger of what THIS instance has fed back to the base methodology via
> `/port-contribute-to-base`. Instance-owned (PROJECT layer): every instance has its own
> contribution history and it is NEVER upstreamed. It exists so that an infrequently-run
> contribute pass is INCREMENTAL, not from-scratch - the command reads the last entry as a
> WATERMARK (what was already sent, and from when) so it focuses the harvest on what is NEW and
> never re-proposes what is already upstreamed.
>
> HOW THE COMMAND USES IT (so it works in any instance, even one that got the methodology by sync
> rather than by init - this file lives in the project layer, which a sync does not carry):
> - It is CREATED from `.opencode/skill/code-port/assets/CONTRIBUTIONS.template.md` on the first
>   contribute pass if absent.
> - The last entry's `Instance <commit>` / date is the watermark: the harvest LEADS with lessons,
>   tool mechanizations, and trap-table additions changed SINCE it, and SKIPS any ID a prior entry
>   records as `Covered`. Older-but-now-general lessons may still be surfaced deliberately - the
>   watermark FOCUSES the harvest, it does not hard-exclude.
> - When the PR opens, a `proposed` entry is appended; once the base merges and this instance syncs
>   the result back, the entry is updated to `synced-back` with the merged base commit.

## LEDGER (append-only; C-numbers permanent, never reused)

- (none yet - the first `/port-contribute-to-base` pass harvests from scratch and records C-0001)
