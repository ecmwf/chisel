# LESSONS - <instance name>

> The append-only lessons ledger, shared by every workstream. A bug found, a proof failed, a wrong
> assumption exposed or an approach abandoned is recorded the moment it is paid for
> (`/port-lesson`). Read the STANDING RULES at the start of every sprint.
>
> The ledger is searched, never read end to end: every entry carries class tags (failure-mode IDs
> such as N2 or B1, trap IDs such as T6, or `-`). At each phase retrospective, closed entries
> (mechanized, or specific to finished modules) move to `port/lessons-archive/phase-<n>.md`.
> L-numbers are permanent and never reused, so references survive the move.

## STANDING RULES (restate these every sprint)
> At most about 20 rules. Promote a lesson here when it is general or recurs; merge or retire
> rules at retrospectives. If a rule's class keeps recurring, mechanize it (a probe, proof or
> script) and note the tool. Rules 1-7 come with the methodology; they are retired or amended only
> with the human's sign-off.

1. Any claim about a SOURCE constant cites file:line and the literal text read this
   sprint - never a comment, never memory. (Seed. Mechanized as: none - behavioral.)
2. Take every array stride from the allocation shape, never from the iteration range;
   index only through the central helpers. (Seed. Mechanized as:
   tools/conformance/check-index-helpers.sh.)
3. Allocate every field that a downstream routine may read in its exchange region at
   owned-plus-exchange size. (Seed; applies from the distributed phase onward.)
4. Producer before consumer: when introducing a reader of a field, verify its writer is
   ported and proven first. (Seed.)
5. To test whether a copy is actually read, poison it - never toggle synchronizations
   on a chaotic system. (Seed.)
6. Measure before optimizing; an optimization that doesn't measure as a win is deleted
   and recorded under NEGATIVE RESULTS. (Seed.)
7. A proof or probe is trusted only after it has been seen to fail: demonstrate it
   fires on a seeded bug before first real use, and re-demonstrate after any change
   to its comparison logic. (Seed.)

## MECHANIZATION CANDIDATES (recorded any sprint; triaged at retrospectives)
> One line each: the invariant, and the failure class / trap / charter rule it
> would guard (no citation, no candidate). Triage outcomes: build | reject (keep
> the line, note why) | defer (revisit point). Acceptance criteria in the skill's
> self-improvement loop, step 3.
- Proof wrappers capture SOURCE and TARGET wall-clock into the evidence pack and
  flag parity-band violations automatically - guards the charter's Phase 2 parity
  rule; cheap (proofs already run both binaries). (Build at Phase 1 with the proof
  scripts.)

## NEGATIVE RESULTS (do not retry without new evidence)
- (none yet)

## LEDGER (append-only)
> Entry format (the first lesson this port pays for is L-0001):
>
> ### L-0001  <date>  Phase <n>  Session <id>  Workstream <ws>  Class <N2,T6 | ->
> - **Symptom:** <what was observed; which proof/tier fired, or how it surfaced>
> - **Root cause:** <actual cause, with file:line>
> - **Fix:** <what changed; commit hash>
> - **Prevention:** <the rule or detector that would have caught it earlier>
> - **Action:** <none | promoted to STANDING RULE #k | mechanized as tool/port-prove <id>>

- (none yet)
