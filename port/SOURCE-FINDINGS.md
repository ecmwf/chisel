# Source findings - <instance name>

> Probable bugs in the ORIGINAL code, spotted while porting, to report to its owners later.
> We do NOT fix them: the port reproduces the SOURCE behavior FAITHFULLY (the differential gate
> still runs against the original and must still pass). This file is intelligence for upstream,
> never a licence to deviate - a deliberate deviation is a separate, human-ratified
> KNOWN-DIVERGENCES decision.
>
> Append-only. One line per finding:
>   - **[severity]** `<source path>:<line>` - the problem, in plain terms.
>
> SEVERITY is a judgment call (a model picks it from the finding), NOT a mechanical rule:
>   - **low** - cosmetic or unreachable (a wrong comment; a bug in dead/unused code)
>   - **medium** - wrong only in an edge case the pinned configuration rarely hits
>   - **high** - wrong in a path the pinned configuration actually exercises
>   - **severe** - data loss, crash, or silently wrong results in normal use
>
> (git history already dates each entry - no date field.)

## Findings

- (none yet)
