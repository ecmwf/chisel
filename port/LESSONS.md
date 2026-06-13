# LESSONS - <instance name>

> Append-only ledger, GLOBAL across all workstreams. Every session that finds a bug,
> fails a gate, exposes a wrong assumption, or abandons an approach MUST append an entry
> before it ends - capture in the same session the lesson is paid for.
> Read the STANDING RULES block at the start of EVERY session.
>
> SIZE POLICY (so this file never becomes required linear reading):
> - The ledger is SEARCHED, never read end-to-end. Every entry carries Class tags
>   (failure-mode IDs like L2, B1, trap IDs like T6, or `-` if none) so debugging
>   consults it by grep.
> - At each phase retrospective, closed entries (mechanized, or specific to finished
>   modules) move to `port/lessons-archive/phase-<n>.md`. L-numbers are permanent and
>   never reused, so references survive archival. The active ledger stays lean.

## STANDING RULES (restate these every session)
> Keep ≤ ~20 rules. Promote here when a lesson is general or recurs; merge/retire at
> retrospectives. If a rule's class keeps recurring, MECHANIZE it (probe/gate/script)
> and note the tool ID. Rules 1–6 are seeded from the methodology this project adopts;
> they are retired or amended only with human sign-off.

1. Any claim about a SOURCE constant cites file:line and the literal text read this
   session - never a comment, never memory. (Seed. Mechanized as: none - behavioral.)
2. Take every array stride from the allocation shape, never from the iteration range;
   index only through the central helpers. (Seed. Mechanize: tools/conformance/.)
3. Size every field that any downstream routine might read at its exchange region at
   owned-plus-exchange size. (Seed; applies from the distributed phase onward.)
4. Producer before consumer: when introducing a reader of a field, verify its writer is
   ported and gated first. (Seed.)
5. To test whether a copy is actually read, poison it - never toggle synchronizations
   on a chaotic system. (Seed.)
6. Measure before optimizing; an optimization that doesn't measure as a win is deleted
   and recorded under NEGATIVE RESULTS. (Seed.)
7. A gate or probe is trusted only after it has been seen to fail: demonstrate it
   fires on a seeded bug before first real use, and re-demonstrate after any change
   to its comparison logic. (Seed.)

## MECHANIZATION CANDIDATES (recorded any session; triaged at retrospectives)
> One line each: the invariant, and the failure class / trap / charter rule it
> would guard (no citation, no candidate). Triage outcomes: build | reject (keep
> the line, note why) | defer (revisit point). Acceptance criteria in the skill's
> self-improvement loop, step 3.
- Gate wrappers capture SOURCE and TARGET wall-clock into the evidence pack and
  flag parity-band violations automatically - guards the charter's Phase 2 parity
  rule; cheap (gates already run both binaries). (Build at Phase 1 with the gate
  scripts.)

## NEGATIVE RESULTS (do not retry without new evidence)
- (none yet)

## LEDGER (append-only)

### L-0001  2026-06-12  Phase bootstrap  Session repo-review  Workstream main  Class -
- **Symptom:** The no-emdash conformance script reported OK on a tree that
  contained a seeded em-dash. CI had been green on it since bootstrap.
- **Root cause:** tools/conformance/no-emdash.sh used `grep ... -- PATTERN .
  --exclude-dir=.git`; the `--` ended option parsing, making `--exclude-dir=.git`
  a nonexistent file operand. grep exited 2 (error), and `if hits=$(grep ...)`
  treated any nonzero exit as "no match", printing OK regardless of matches. The
  detector had never detected anything.
- **Fix:** Explicit exit-code contract (0 found=FAIL, 1 clean=OK, 2 error=detector
  unreliable), options before pattern, byte-sequence pattern, source/ and
  node_modules excluded. Red/scope/green demonstration recorded in
  docs/evidence/2026-06-12-seeded-no-emdash/.
- **Prevention:** The seeded-bug rule - which existed but was adopted AFTER this
  script was written and was never applied retroactively. A detector that has
  never failed is unproven, no matter how simple it looks.
- **Action:** Promoted: every detector predating its seeded-bug record must be
  red-tested before its next real use (the CI commit-message check was red-tested
  in the same sweep). Mechanized as: the SEEDED-BUG record requirement already
  covers all future detectors.
