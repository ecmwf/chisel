# LESSONS - <project name>

> Append-only ledger, GLOBAL across all workstreams. Every sprint that finds a bug,
> fails a proof, exposes a wrong assumption, or abandons an approach MUST append an entry
> before it ends - capture in the same sprint the lesson is paid for.
> Read the STANDING RULES block at the start of EVERY sprint.
>
> SIZE POLICY (so this file never becomes required linear reading):
> - The ledger is SEARCHED, never read end-to-end. Every entry carries Class tags
>   (failure-mode IDs like L2, B1, trap IDs like T6, or `-` if none) so debugging
>   consults it by grep.
> - At each phase retrospective, closed entries (mechanized, or specific to finished
>   modules) move to `port/lessons-archive/phase-<n>.md`. L-numbers are permanent and
>   never reused, so references survive archival. The active ledger stays lean.

## STANDING RULES (promoted lessons - restate these every sprint)
> Keep ≤ ~20 rules. Promote here when a lesson is general or recurs. Merge/retire stale
> ones at phase retrospectives. If a rule keeps being violated or its class keeps
> recurring, MECHANIZE it: turn it into a probe/port-prove/conformance script and note the
> tool ID here.

1. <e.g., Any claim about a SOURCE constant cites file:line and the literal text read
   this sprint. (Origin: L-0007. Mechanized as: none - behavioral.)>
2. ...

## MECHANIZATION CANDIDATES (recorded any sprint; triaged at retrospectives)
> One line each: the invariant, and the failure class / trap / charter rule it
> would guard (no citation, no candidate). Triage outcomes: build | reject (keep
> the line, note why) | defer (revisit point).
- <e.g., every context struct is initialized in exactly one place - guards T7;
  conformance-greppable>

## NEGATIVE RESULTS (do not retry without new evidence)
> Optimizations or approaches tried and removed, with the measurement that killed them.
- <e.g., comm/compute overlap on backend X: targeted time was load imbalance, not
  communication. Measured <profile ref>. (L-0021)>

## LEDGER (append-only)

### L-0001  <date>  Phase <n>  Session <id>  Workstream <ws>  Class <L2,T6 | ->
- **Symptom:** <what was observed; which proof/tier fired, or how it surfaced>
- **Root cause:** <actual cause, with file:line>
- **Fix:** <what changed; commit hash>
- **Prevention:** <the rule or detector that would have caught it earlier>
- **Action:** <none | promoted to STANDING RULE #k | mechanized as tool/port-prove <id>>

### L-0002 ...
