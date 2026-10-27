# Phase-2 bring-up harness - <FIRST-MODULE>

> Copy to `port/bring-up-harness.md` when the first translated module is R0-clean and reviewed but
> cannot be proven: proving needs an R1 differential against the SOURCE, and the cross-language
> harness does not exist yet. This one sprint builds that harness against `<FIRST-MODULE>`; every
> later module is proven against it. Its parts are Phase-1 tooling units, so at autodrive L2 or L3
> `phase1_drive.py` drives them (claim, work with its seeded-bug demonstration, independent review,
> integrate); at L1 or by hand, run it as a normal sprint (`/port-sprint-start`, or dispatch a
> Kha-Worker). Each part is trusted only after its seeded-bug demonstration and its independent
> review.
>
> R0 shows the TARGET builds and keeps its own invariants, and the review shows it is structurally
> faithful; only the R1 differential shows it reproduces the SOURCE's numbers on real inputs
> (`references/validation-ladder.md`, R0 and R1; `references/bring-up-strategy.md`).

Done when `<FIRST-MODULE>` is proven at R1 against this harness (proof evidence and a clean
independent review recorded), and running `/port-autodrive` again advances it to integrated and
widens the ready-set. Each part lands through its guarded script, as a reviewed deliverable.

## 1. The R1 capture-replay harness (the binding deliverable)
The cross-language R1 twin (`references/validation-ladder.md`, "A canonical ladder", R1):
- [ ] Fixture generator (workbench, e.g. `tools/diff/`): instrument the SOURCE on the reference run
      and record `<FIRST-MODULE>`'s inputs and outputs as committed vectors, floating-point values
      as exact bit patterns, never as formatted text.
- [ ] Replay driver (product, under `tests/`): build `<FIRST-MODULE>` with the pinned acceptance
      flags of the build contract and run it on the recorded inputs, writing its outputs in the
      same format.
- [ ] Differential comparator (the R1 proof): compare SOURCE and TARGET outputs against the R1 bar
      of `references/validation-ladder.md`, with the tolerances the human set in charter section 7;
      exit non-zero on a miss, and record the evidence under `docs/evidence/`.
- [ ] Seeded-bug demonstration (`/port-seed`): a wrong value planted in the TARGET turns the
      comparator red, and removing it turns it green.
- [ ] Independent review of the harness itself (`/port-review`, in a separate session): it is
      fidelity-critical tooling, reviewed like a piece.

## 2. The TARGET-side conformance checks
- [ ] The naming-map check, run on the TARGET identifiers (`port/conventions/<source>-to-<target>.md`,
      section 2).
- [ ] The provenance-anchor verifier, run on the TARGET: every comparable constant cites its SOURCE
      `file:line` with the literal embedded, and its value is compared with the SOURCE constant's
      (target-conventions `references/pairs/<source>-to-<target>.md`, "Comment policy").
- [ ] Each seeded-bug-demonstrated where it is a detector, and run in CI on the product checkout
      (the two-root contract, `references/two-repo-architecture.md`).

## 3. The TARGET build baseline
- [ ] The formatter and the linter, the warning floor as errors, the sanitizer build, the
      compilation database and the pinned build-flag contract, each checked after a fresh build as
      the TARGET's language file says (target-conventions `references/langs/<target>.md`).
