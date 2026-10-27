# Source findings - <instance name>

> Probable bugs in the original code, spotted while porting, to report to its owners later.
> The port does not fix them: it reproduces the SOURCE behavior faithfully, and the differential
> proof still runs against the original and must still pass. This file is information for the
> upstream owners, never a licence to deviate; a deliberate deviation is a charter named
> exception (section 4) that the human authorizes.
>
> Append-only. One line per finding:
>   - **[severity]** `<source path>:<line>` - the problem, in plain terms.
>
> The severity is a judgment the agent makes from the finding, not a mechanical rule:
>   - **low** - cosmetic or unreachable (a wrong comment; a bug in dead/unused code)
>   - **medium** - wrong only in an edge case the pinned configuration rarely hits
>   - **high** - wrong in a path the pinned configuration actually exercises
>   - **severe** - data loss, crash, or silently wrong results in normal use
>
> (git history already dates each entry - no date field.)

## Findings

- (none yet)
