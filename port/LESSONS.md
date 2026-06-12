# LESSONS - Fortran → C port (pilot + large)

> Append-only ledger, GLOBAL across all workstreams. Every session that finds a bug,
> fails a gate, exposes a wrong assumption, or abandons an approach MUST append an entry
> before it ends - capture in the same session the lesson is paid for.
> Read the STANDING RULES block at the start of EVERY session.

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

## NEGATIVE RESULTS (do not retry without new evidence)
- (none yet)

## LEDGER (append-only)

(no entries yet - first entry is L-0001)
