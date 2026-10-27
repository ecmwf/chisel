# SIGN-OFF - <phase or milestone>

> Durable record of human acceptance (the HAND-DRIVEN path). A milestone tag or phase advance happens
> only after the DECISION below says accepted AND this file is committed - or, in L2/L3 auto-mode, via
> `finalize.sh --auto` (full conformance green at HEAD, no SIGNOFF.md). The agent fills everything down to and
> including its recommendation, then asks the human ONE outcome question and transcribes their
> EXPLICIT answer into the decision block - so the human never hand-edits markdown or types git.
> What signs off is the human's explicit decision; the agent may record and commit it for them, but
> transcribes only their verbatim outcome - never an inferred one.

## Prepared by the agent
- Scope: <phase / milestone, charter section>
- Criterion (verbatim from the charter): <...>
- Evidence reviewed: <paths in docs/evidence/: proof runs, review reports,
  seeded-bug records, digest report>
- Known divergences relied on: <IDs from KNOWN-DIVERGENCES.md, or none>
- Open placeholders affecting this scope: <none | list - must be none for a
  phase final sign-off>
- Prepared by session: <id>   Date: <date>

## Agent recommendation (a recommendation, NOT the decision)
- Recommended verdict: <accept | reject | accept-with-conditions>
- Why, in plain terms: <the evidence-based reasoning>
- What could make this wrong: <the honest risks; what the agent could not rule out>
- What you should check before deciding: <the steps in the digest's HUMAN
  VERIFICATION RUNBOOK that need your eyes; "nothing by hand, the proof is exact"
  when the criterion is fully mechanical>

## Human decision (yours - the agent transcribes your EXPLICIT answer and may commit it for you)
> The agent asks you ONE outcome-framed question and fills this block from your answer, so you never
> hand-edit markdown. What signs off is your explicit decision, not who types the commit: the agent
> records only your verbatim outcome (never invents one, never reads a vague reply as acceptance),
> and with auto-land on - the charter default - commits it for you and runs the post-sign-off git.
> (This SIGNOFF.md is the HAND-DRIVEN acceptance path. In auto-mode (L2/L3) no human is present during
> the run and the milestone is sealed instead by `finalize.sh --auto`, guarded by full conformance green
> at HEAD (the per-piece independent reviews bound to each proven commit being the acceptance) - there
> is no SIGNOFF.md and no countersign there.)
>
> The Decision is the OUTCOME, not "yes/no to the recommendation": one plain token on its line, no
> markdown emphasis and nothing after it (`finalize.sh` reads the exact token); conditions go in
> Notes. When the recommendation is a clean accept the agent asks "Accept in full?", so your `yes`
> means accept-in-full; when it is conditional the agent asks you to pick the outcome.
- Decision: <accept-in-full | accept-with-conditions | reject>
- What I checked: <runbook steps you ran or looked at; "confirmed, mechanical proof" is fine for an
  exact-match criterion>
- Signed: <your name - from git config (the agent confirms it, never invents it)>   Date: <date>
- Notes / conditions: <...>
