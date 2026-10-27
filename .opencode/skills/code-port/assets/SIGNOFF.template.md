# SIGN-OFF - <phase or milestone>

> The human's acceptance of a phase or milestone when it is driven by hand: `finalize.sh` creates
> the milestone tag only once this file is committed with an accept decision. (At autodrive L2 or
> L3, `finalize.sh --auto` seals the milestone instead, and there is no SIGNOFF.md.) The agent
> fills everything down to its recommendation, asks the human one outcome question, and writes the
> answer into the decision block word for word. It never infers a decision or reads a vague reply
> as acceptance. With auto-land on (the default) it then commits the file, and `finalize.sh` runs
> the git that follows a sign-off.

## Prepared by the agent
- Scope: <phase / milestone, charter section>
- Criterion (verbatim from the charter): <...>
- Evidence reviewed: <paths in docs/evidence/: proof runs, review reports,
  seeded-bug records, digest report>
- Known divergences relied on: <IDs from KNOWN-DIVERGENCES.md, or none>
- Open placeholders affecting this scope: <none | list - must be none for a
  phase final sign-off>
- Prepared by session: <id>   Date: <date>

## Agent recommendation (a recommendation, not the decision)
- Recommended verdict: <accept | reject | accept-with-conditions>
- Why, in plain terms: <the evidence-based reasoning>
- What could make this wrong: <the honest risks; what the agent could not rule out>
- What you should check before deciding: <the steps of the digest's human verification runbook
  that need your eyes; "nothing by hand, the proof is exact" when the criterion is fully
  mechanical>

## Human decision (yours - the agent writes down your answer)
> The Decision is the outcome, not "yes or no to the recommendation": one plain token, with no
> emphasis and nothing after it, because `finalize.sh` reads the exact token. Conditions go in
> Notes. For a clean recommendation the agent asks "Accept in full?", so your `yes` means
> accept-in-full; for a conditional one it asks you to pick the outcome.
- Decision: <accept-in-full | accept-with-conditions | reject>
- What I checked: <runbook steps you ran or looked at; "confirmed, mechanical proof" is fine for an
  exact-match criterion>
- Signed: <your name - from git config (the agent confirms it, never invents it)>   Date: <date>
- Notes / conditions: <...>
