# Failure Modes in LLM-Assisted Numerical Porting

A taxonomy of recurring failure classes, each paired with its characteristic symptom and
the detector that catches it cheaply. Derived from full-scale porting experience
and intended to grow: when a project ends, fold its distilled LESSONS.md back into this
file (with the human's approval).

Read this file at Phase 1 - its detector column is the requirements list for your
differential tooling - and again whenever debugging.

## Agent-behavioral failure modes (about *you*)

**B1 - The urge to improve.** A standing tendency to simplify, modernize, or
"clean up" during translation. Each improvement produces *plausible* output and an
unbounded debugging search; whole port attempts have failed through accumulated
improvements alone (a linearized coefficient, a lookup table replaced by a closed form,
a volume ratio swapped for an area ratio, a history length mismatched to a scheme's
order - each individually defensible, each wrong). *Detector:* the
literal-translation rule itself, plus human diff review. If you notice yourself
rationalizing a deviation as harmless, stop and record it as a proposed exception in the
charter instead.

**B2 - Plausible paraphrase instead of the actual line.** Stating what the SOURCE does
from memory, from pattern-completion, or from a code comment rather than from the line
itself. Comments can be confidently wrong; a wrong comment about a constant has hidden
an instability for several working sprints. *Detector:* the file:line citation rule -
every claim about SOURCE behavior quotes path, line number,
and literal text read this sprint. *Mechanization:* machine-checked provenance
anchors - constant anchors embed the literal as read, and a conformance script
verifies the anchor against the pinned SOURCE line and the TARGET rendering, both
directions, in CI (see the target-conventions skill). Inherited comments are marked
untrusted; one found contradicting its code is upgraded to a contradiction marker and
logged, so a lying comment is defused once instead of re-trusted by every later
sprint.

**B3 - Following the inactive branch.** Porting a plausible code path that the pinned
configuration never executes, or adopting an in-source default that the run's parameter
file overrides. (Typical instance: a scheme existing in two implementations selected by
one parameter, where the obvious one is the wrong one.) *Detector:* the
pinned-configuration contract in the charter; provenance recorded for every effective
parameter value (parameter file > source default); the multi-run statistical comparison
catches survivors as systematic regional bias.

**B4 - Chasing an accepted divergence.** Spending sprints investigating a difference
that is correct SOURCE behavior (partition-dependent reductions, documented
nondeterminism, the recorded accelerator floor). *Detector:* the accepted-divergence
registry (`port/KNOWN-DIVERGENCES.md`) - consulted first in every debugging workflow,
appended only with human sign-off.

**B5 - Stale sprint state over a moving repo.** A sprint persists state -
whole-file rewrites of handoffs or plans, commits - based on what it read at sprint
start, while the repo moved underneath: a concurrent edit is silently overwritten by
a stale write, or a plain commit silently concludes an in-progress merge and sweeps
foreign staged content in under the sprint's commit; no conflict fires in either
case. *Detectors:* re-read or blob-compare every state file immediately before
rewriting it; before any commit, verify no merge is pending and the staged set
contains exactly the announced paths; after any commit, verify the parent hash
equals the HEAD reconciled against. *Prevention:* one writer per worktree - human
git operations happen between sprints, never during one; an agent finding the
worktree unexpectedly changed stops and reports rather than absorbing or reverting.

**B6 - Coverage read as liveness.** Excluding a compilation unit from the port because
coverage shows it never executed - but a declarations-only unit (constants, type
aliases, shared data; no executable statements) emits zero coverage at any run length
while being essential, referenced by live code. Dropping it removes constants or types
the port needs, forcing a build failure or, worse, a hand-re-derivation (a
literal-translation violation, B1). *Detector:* determine the live subset from THREE
signals, not coverage alone - executed = live; not-executed AND declarations-only AND
referenced by live code = live; not-executed AND (contains procedures OR unreferenced)
= REVIEW (human decides, never auto-exclude). *Prevention:* exclude a unit only with
proof of deadness (not compiled, or code-read unreachability), never on coverage
absence. Corollary: once every non-executing unit is shown declarations-only, the
executed set is provably complete, so a short coverage run suffices - no long run is
needed to "be sure". *Corollary (build-graph liveness):* the link-map / build graph is
the authoritative inclusion signal but is necessary-not-sufficient when the build
GENERATES sources - generated-source templates (configure-time inputs) and headers are
not link inputs. A template is live iff its generated output feeds a live unit; a header's
liveness comes from the COMPILER DEPFILES (the real post-preprocessor include graph),
never text-grep (which false-positives on disabled `#ifdef` blocks and misses
include-path variants). A live-tree header included by no live unit is REVIEW, never an
auto-exclude.

**B7 - Assembly-proven deliverable landed per-id.** Landing a multi-module deliverable one member at a
time when its PROOF is assembly-level - one differential links several modules, so no single member passes
the proof in isolation - and its parallel-port work branches are independent full-closure trees (each
carries its whole dependency closure and defines the same build target). The first member's land moves the
product mainline and STALES every sibling branch; the members' build files collide on landing; and an
intermediate mainline holding only some members cannot pass the assembly-level proof, so the two-root
merge-result check goes red on each step. *Detector:* before landing, ask whether the proof differential
links more than one module, OR whether the work branches each carry the full closure / share a build target
- either means the deliverable is assembly-proven, not a set of independent pieces. *Prevention:* land the
whole member group as ONE reviewed **assembly piece** - an assembled `work/<assembly-id>` branch (the proven
members + their build glue) with one INTEGRATION-LEVEL review of the assembled commit (bound by
check-trace-evidence, no manifest) - via `tools/coordination/integrate_assembly.sh <assembly-id> --members
"<id> ..."`; never land a member of an assembly-proven deliverable alone. (See references/two-repo-architecture.md.)

**B8 - Unratified seam departure.** A rendering choice that departs from literal
translation to handle a SOURCE-language construct with no direct TARGET analog (a
foreign-library bridge that vanishes at the language boundary, a generic interface
that does not collapse to a single dispatch, an execution-model branch deferred to a
later phase, a support-library symbol rendered as a no-op seam) - each individually
defensible, each a judgment call the author must NOT make unilaterally. *Symptom:*
the code is numerically clean (the twin is bit-identical) but the independent review
flags it as a governance finding because the departure was neither authorized by the
human nor recorded in the divergence registry. *Detector:* the independent review
assesses each seam rendering against the charter's mechanical-transform list; any
departure not on the list is a finding until the human ratifies it in
`port/KNOWN-DIVERGENCES.md`. *Prevention:* surface every seam rendering for the human
BEFORE marking proven, as a governance DECISION, not a code-fix send-back. When the code is
faithful and UNCHANGED, the resolution is the human's charter ratification of a
`KNOWN-DIVERGENCES.md` row - not a code edit and not a second review: registering the
human-authorized row is what clears the finding, after which the reviewer records the
verdict `clean` (citing the proof, the review, and the ratified row) and the unit is proven.
The existing twin still passes and the existing review still describes the same bytes, so
nothing is re-proven or re-reviewed. Re-review is owed only when the fix touches code
(then it is B9, below).

**B9 - Editing a proven file without re-proving.** Modifying a file whose TRACE status
is `proven` (the independent review passed, the proof is green) and presenting it as
still proven. The prior review covered the OLD code; the edit invalidates it.
*Symptom:* a small cosmetic or consolidation edit (moving a static helper to a shared
module, stripping a comment) lands on a proven file; the proof re-runs green, but the
independent review has not seen the new code. *Detector:* the TRACE status field -
editing a proven file reverts it to `in-progress` and OWES a fresh independent
re-review in a separate session. The old review pointer is kept but noted as
pre-edit; the editing session is appended to `author_sessions`. Re-run the module's
numerical twin to show the change is behavior-neutral before claiming it.
*Prevention:* the proof is a property of (code, review, evidence) triple; any leg
changed invalidates the triple. A cosmetic edit is not a reason to skip re-review -
it is a reason to do one quickly. The triple's "code" leg is the piece's OWN target-file
BYTES, not the commit SHA: a rebase (a moved foundation underneath) changes the SHA but may
leave the piece's files byte-identical. That still owes a re-prove (a moved foundation can
change the numerical behaviour - only the twin catches that), but it owes a fresh independent
re-review ONLY if it changed the piece's own target files. Decide it mechanically and
fail-closed with `tools/coordination/review_revalidate.sh <id>` (byte-identity of the
`target:` files between the reviewed `proof.commit` and the rebased tip): VALID -> reuse the
review (advance `proof.commit` on re-prove); STALE or UNRELIABLE -> a fresh re-review is owed.
Same principle as B8/B10: review validity tracks the piece's code, not the commit.

**B10 - Behaviour-neutral departure presented as done.** A rendering choice that is
faithful and numerically neutral but departs from the charter's mechanical-transform
list, presented as complete without being recorded in the divergence registry.
*Symptom:* the independent review returns VIOLATIONS on code whose twin is
bit-identical, purely because a rendering departure (e.g., dividing a live range
differently, clamping a subtraction-derived allocation to non-negative) was not in
the registry. The author believed "faithful + neutral = done"; the reviewer requires
"ratified = proven." *Detector:* the divergence registry - every behaviour-neutral
departure from the mechanical-transform list is a governance finding until it carries
a registry row marked delegate-ratified / human-authorized. *Prevention:* register the
departure BEFORE presenting for review, not after. When the code is already correct,
the resolution is a registry row + the human's ratification - not a code edit and not a
second review: registering the human-authorized row clears the finding, the reviewer
then records the verdict `clean` (citing the proof, review, and row), and the unit is proven.
The existing proof and review describe the same bytes, so nothing is re-proven or
re-reviewed. (A fix that touches code is B9 - that owes a fresh review.)

**B11 - Pre-writing the review disposition.** Authoring the evidence README with the
review outcome ("Independent review (clean first-pass) -> PROVEN") BEFORE the
independent review runs. *Symptom:* the evidence pack asserts an outcome that has not
happened, and a reviewer who reads it can be anchored by it. *Detector:* the evidence
README's review section - if it states a verdict before the reviewer session exists,
it is premature. The conformance suite is the real backstop: a `proven` entry requires a
recorded review report with an explicit clean verdict (`check-trace-evidence.sh`),
produced by a reviewer distinct from the author (`check-status-fragments.sh`:
`reviewer_id != author_id`, and `reviewer_session` not in `author_sessions`). A premature
prose line can never actually make the piece proven - the binding control is the recorded,
independent, clean review, not the prose. *Prevention:* author the evidence with the
review section as PENDING (or stating only the facts that exist - the proof result, the
seeded-bug, the bring-ups); fill in the review outcome + the PROVEN disposition ONLY
after the verdict returns. Correcting a premature disposition is a PROSE fix; it does
not by itself owe a fresh review, because the conformance suite already proves whether a
real, independent review ran.

**B12 - Churning faithful code to satisfy an over-strict tool.** A conformance check or proof
CHECKER that is stricter than its own documented intent (or the convention it cites) flags
faithful, already-proven code, and the reflex is to EDIT the code until the tool falls silent.
*Symptom:* a mechanical/style checker reports violations on code whose numerical twin is
bit-identical and whose cited convention actually PERMITS the construct - the checker's pattern
over-matches, or it asserts about a context it cannot see (a default-precision regime, a
native-base index, a multi-line statement, a format string). The author begins rewriting faithful
code - or, worse, churns already-ATTESTED code - to turn the tool green. *Detector:* the proof
versus the checker - when a piece's proof (the numerical twin) is green but a mechanical checker is
red, the CODE is proven faithful and the TOOL is the suspect; read the checker's own
docstring/intent and confirm whether it is over-firing before touching a line of code.
*Prevention:* fix the TOOL, not the faithful code. Calibrate the checker to its documented scope
and RE-DEMONSTRATE its seeded-bug - the change must keep the genuine defect RED while clearing the
false positive (a detector unseen to fail is unproven). A checker change is a METHODOLOGY change:
contribute it upstream, never fork it locally. Where a construct genuinely departs from the
convention but the proof shows it correct and policy declines to disturb it (e.g. attested code),
record a justified, durable per-site WAIVER - a recorded convention-exception tied to a divergence
row, never a silent bypass - rather than editing the code. The two legitimate moves are
calibrate-and-reseed or waive-with-a-recorded-reason; never weaken or silence the check (the
never-silence-a-detector rule) and never churn a proven/attested file to satisfy a tool (B9).

**B13 - Deadlocking the sanctioned land by hardening a fail-closed check over a pre-existing
violation.** A methodology sync HARDENS a checker to FAIL CLOSED on a construct it can no longer
verify (and therefore can no longer waive), but the already-attested TARGET ALREADY contains that
construct - and now the sanctioned land of the very FIX deadlocks. The guarded land path requires the
full conformance suite GREEN at the pre-land HEAD; but the fix's own not-yet-landed state IS the
red, so the land refuses on the piece whose landing REMOVES the red. *Symptom:* an integrate/land
script reports "conformance RED at HEAD - never land over a red check" on a piece that is itself the
fix for that exact red; the post-merge RESULT check would be green; the hardened checker cannot be
waived (that is the point of fail-closed); and the pre-sync methodology cannot land the piece either
(its machinery was simplified away by the same sync). *Detector:* land-check SCOPE - a HEAD-only
"green before landing" check mis-fires when the landing piece is the fix for the pre-existing red,
because it judges the OLD target, not the result; the merge-RESULT check is the honest one for that
piece (and it is green). *Prevention:* never silence the hardened checker in the committed tree,
never hand-edit the TARGET outside the guarded path, never land a NON-fix over the red. Land the fix
under the PRE-hardening checker TRANSIENTLY: restore the prior (still-correct, less-strict) checker
UNCOMMITTED, drive the actual fix through the sanctioned guarded path (the fix is correct - only the
HEAD-vs-result check mis-fired), then restore the hardened checker; the result is green and nothing
false was committed. The durable METHODOLOGY fix (contribute it): the land check should judge the
merge RESULT for the landing piece, not only the pre-land HEAD, so a piece that REMOVES a
pre-existing violation is never blocked by it. Two siblings of the same sync: (a) a `--land-only`
methodology sync REFUSES if any methodology file differs from the base verbatim - a local checker
CALIBRATION the base has not adopted blocks the land (the layer driver only fires on a true
conflict); restore the methodology layer to the base, land, then re-apply or contribute the
calibration separately. (b) A SUBSTRATE-SCHEMA migration the sync's new tools require (regenerating
a leaner dependency map / trace, converting status fragments to a new schema, retiring rows the new
 model no longer tracks) is PROJECT-layer work - a SEPARATE post-sync commit, never bundled into the
methodology-only land (which forbids project changes).

**B14 - Hand-improvised integration that masks a failed merge and attests a non-landed piece.** When
the sanctioned land (`integrate_land.sh`) seems blocked, the reflex is to hand-roll the merge as a chained
one-liner - `git merge --ff-only work/<id> && <attest> && release_claim && teardown && push` - instead of
STOPPING and fixing the blocker. This is doubly wrong: it is the forbidden copy-paste merge sequence, AND
it loses every fail-closed property of the script. *Symptom:* the merge is piped (`git merge ... 2>&1 |
tail -1`), so the pipeline returns `tail`'s exit 0 and MASKS git's failure (no `pipefail` in an interactive
shell); the `&&` chain then runs the attest/release/teardown even though `git merge` printed `fatal: Not
possible to fast-forward, aborting` (the base moved under the branch). Result: `integration.state:
integrated` is committed for a piece whose CODE never landed, the claim is released, and the work branch is
torn down (recoverable only from dangling commits). *Detector:* the self-validating planner is the backstop
- it reports `triage: <id> marked integrated but not acceptance-ready (missing evidence ...)` because the
attest flag is not backed by landed evidence; treat ANY such triage as "a land was faked or half-done",
not as a plan typo. *Prevention:* NEVER hand-run the merge - `integrate_land.sh` is `set -euo pipefail`,
re-verifies readiness + conformance ON THE LANDED RESULT, and rolls back fail-closed (it would have refused
this exact case, not attested it). NEVER pipe a GUARDING command through `tail`/`head`/`| true` (it discards
the exit code that is the guard). If the sanctioned land refuses, FIX THE BLOCKER (e.g. rebase the branch;
or `/port-sync-with-base` to pick up an `integrate_land.sh` fix) - do not improvise around it. Recovery
from a faked attest: restore the work branch from its dangling commit (`git branch work/<id> <sha>`), set
`integration.state` back to un-integrated on the line (a forward commit, never a force-push), then land it
properly through `integrate_land.sh`.

**B15 - A dispatched subagent hunting for its OWN session id (and stalling on it).** A worker or
reviewer is asked - by a stale dispatch prompt or doctrine - to report its own `reviewer_session` /
`author_id`, but a dispatched opencode Task subagent has NO access to its own `ses_` id (it is surfaced
only in the Task RESULT, which the DISPATCHER reads). *Symptom:* the subagent burns turns probing for an
id it cannot reach - dumping `SESSION`/`OPENCODE` env vars, then escalating to `opencode --help`,
`opencode session --help`, and finally **`opencode session list`** (a subagent shelling into the opencode
CLI from inside an opencode session), which lists every session but cannot tell the agent WHICH one is
itself; the loop stalls the session / wedges the queue. *Detector:* identity is the orchestrator's to
record, captured from the Task result - so any agent prompt that asks a subagent to RETURN its own session
id is the bug, not the agent's effort. *Prevention:* a subagent NEVER hunts for, guesses, or returns its
own session id, and NEVER runs `opencode session ...` or any opencode CLI to find it (it cannot identify
the running session and can hang it). The orchestrator captures the worker's/reviewer's `ses_` from its
Task result and records `author_id` / `reviewer_id` (and the resume thread) - the worker/reviewer returns
only its work product (a worker: ready-for-review; a reviewer: verdict + report path + findings). A null
`author_id`/`reviewer_session` from the subagent is EXPECTED, not an omission (the same rule as B-series
identity recording; `kha-worker.md`, `agents/port-review.md`, `command/port-review.md`).

**B16 - A hand-rolled gather edit that silently MISSES and reports false success.** Consolidating a
parallel wave by hand - recording each piece's `author_id`/`reviewer_id`, flipping a flag in N
fragments - with a brittle EXACT-STRING replace (`s.replace("author_id: null\n", ...)`) that no-ops the
moment the line differs by a TRAILING COMMENT or whitespace (a worker had annotated the placeholder
`author_id: null  # the orchestrator records this`), so the field is left null on some pieces. *Symptom:*
the gather script prints a reassuring `fragments_updated=15` - but that counts loop ITERATIONS, not actual
replacements, so a silent miss reads as success. A null `author_id` then survives into review/mark-proven, where
the independence check `reviewer_id != author_id` passes VACUOUSLY against `null` (independence not truly
verified). The same class also bit a `git merge ... | tail` (B14, the pipe masked the exit code) and a
`${!arr[@]}` bash-ism under zsh (a bad-substitution that no-ops a loop). *Detector:* never trust a
hand-gather's own count; after it runs, VERIFY the postcondition directly - e.g. assert every gathered
fragment has a non-null `author_id` consistent with its `author_sessions`. A field that should be set but
is still `null` (or `[]`) on any wave piece is the tell. *Prevention:* edit fragments ROBUSTLY - replace
the WHOLE `author_id:`/`reviewer_id:` line (a `^author_id:.*$` line replace, immune to a trailing comment),
never an exact-string match on a value+newline; keep gather steps shell-agnostic (Python/POSIX, not bash
associative arrays) and never pipe a guarding command through `tail`/`head`; and ALWAYS re-verify the
postcondition rather than the script's self-reported tally. (Recovery: read the captured ses from the
fragment's own `author_sessions` and set `author_id` to it on the missed pieces.)

**B17 - An EPHEMERAL warning trusted as a durable guard (and the main-tree/worktree split that
hides it).** A setup step detects a real problem and prints a warning - but the warning is one line
of output to ONE session, while the condition it warns about persists in the repository forever.
The session that acts on the warning is frequently a LATER one that never saw it, and every session
after that inspects a state whose defect has become invisible. *Concrete instance:* importing a
SOURCE tree strips its nested `.git`, which demotes every imported file to untracked - and at that
moment the SOURCE's own `.gitignore`, inert upstream because tracked files are immune to it, starts
excluding real source. A pattern as ordinary as `build*` drops a routine named
`build<something>.f90`; the subsequent `git add -A` exits 0 having silently omitted it, and the
SOURCE - the specification - is incomplete. The importer DID warn at import time; nothing re-checked
afterwards. *Second, nastier symptom:* the defect is invisible where you would look. The main
working tree still HOLDS the untracked file, so every check passes there, while every fresh clone
and every worker WORKTREE lacks it and fails. **Green in the main tree, red in every worktree, is
the signature of an untracked-but-present file** - and if parallel workers report a failure the
orchestrator cannot reproduce, believe the workers. *Detector:* ask whether the EVIDENCE needed to
re-derive the check is committed and permanent. Here it was - the provenance records the upstream
tracked-file count forever - so the comparison could be re-run on every conformance pass instead of
once. *Mechanization:* a conformance check comparing the tracked count under each imported SOURCE
against its recorded provenance count, failing with the offending paths AND the ignore rule
responsible. *Prevention:* a setup step's exit code is not a completeness proof. When a step has a
checkable postcondition and a durable record of the expectation, make it a standing check, not a
printed hint - "the tool warned about it" is not a control if nothing reads the warning twice.

**B18 - Re-deriving an answer some tool already knows.** Hand-rolling a scanner for a
question that a real parser, an index, or a loader answers exactly. Text matching to decide
what is a declarator, which preprocessor branch is live, whether an identifier is a call or
an array reference, which files a build actually contains, or whether a generated JSON is
valid. *Symptom:* a patch streak. Each round fixes the spelling the last round missed - a
line continuation, a nested parenthesis, an unusual indent - and the check is greener without
being more correct. The tell is that every finding has the same shape: "the form I did not
anticipate." *Detector:* ask what the authority for this question IS. Grammar questions have
a front end (libclang, fparser2, the compiler's own AST). "What files are in this project"
has git's index. "Is this file well-formed" has the loader that will consume it. If an
authority exists and you are pattern-matching instead, that is the defect. *Mechanization:*
call the authority; pin it as a dependency; make its absence UNRELIABLE, never a skip.
*Prevention:* one patch to a scanner is maintenance; three in a row is a design error. Stop
and ask what would answer this exactly, rather than what would make this case pass. The
rewrite is usually smaller than the accumulated patches, and it ends the streak instead of
extending it.

**B19 - A verdict that depends on where it ran.** Accepting a result established in one
environment as though it held in every environment - and, conversely, discovering only in CI
that a check needed a tool the runner lacked. *Symptom:* green locally, red in CI, with
nothing in the diff to explain it; or green in the main working tree and red in every fresh
worktree. Either way the verdict changed without the code changing, which means it was never
a property of the code. *Detector:* for any verdict that will license later work, ask what it
is BOUND to - which compiler identity, which flags, which library contents, which tree state -
and whether that binding is recorded alongside the verdict rather than assumed. A bar
established under one toolchain and applied under another is a stale bar, and nothing will
say so. *Mechanization:* record the identity with the verdict (compiler version string, flag
set, content hashes of the runtime libraries), and have the consuming proof compare identities
before honouring it. Install every parser the checks need in CI, so a missing tool is a red
build rather than a silent local-only pass. *Prevention:* treat "it passed on my machine" as
an UNRELIABLE result until the binding is written down. And check CI before landing, not
after the wave - a suite that is green only where you happen to be standing is not green.

**B20 - Unbounded adversary in a review brief.** Reviewing a detector against an attacker who
already has write access to the tree - PATH shadowing, symlink farms, races between check and
use - and treating each new such finding as blocking. *Symptom:* review rounds that never
converge. Every round produces a real-sounding hole, each fix is correct in isolation, and the
unit does not land; the findings drift steadily further from anything the project's own
history contains. *Detector:* for each finding ask whether it is reachable by HONEST ERROR - a
tired author, a broken detector, an ordinary environmental accident like a system upgrade - or
whether it requires someone who could equally well edit the check itself. The second class has
no fixed point: any control you add is writable by the same adversary. *Mechanization:* ratify
a THREAT MODEL in the charter before the first review, naming what is in scope (honest worker
error, vacuous or broken detectors, ordinary accidents) and what is out (an adversary with
commit access, configurations the port does not use). Out-of-scope findings are recorded as
non-blocking notes, not send-backs. Fail-closed is unchanged: "could not determine" still
blocks. *Prevention:* cap review rounds - a third round on one unit means narrow the unit's
claim or escalate to the human for a scoping decision, not grind. And scope the brief when you
dispatch it: an unbounded question yields an unbounded answer, indefinitely.

*Refinement - review scope drifting from the deliverable to the checker's checker.* The same non-convergence symptom can arise without an unbounded adversary: round after round reviews not the ported artifact but the tooling that validates it, then the tooling that validates that. Two pieces ran four rounds this way while code-level findings were already confirmed closed. The honest-error test alone returns "blocking" here - every tooling defect IS reachable by honest error - so it is insufficient as a discriminator. Ask the refined question: what is under review, and can this auxiliary-tool defect make the DELIVERABLE'S OWN PROOF report green while the property is false? If it cannot, it is a note, not a send-back. Credit independently-verified DEFENCE IN DEPTH: where two layers guard one property - a textual check and an outcome check derived from the built artifact - a defect in the weaker layer is mitigated, not open, provided the stronger layer is verified independently of it. State in every review brief which artifact is under review and which properties already have independent outcome-based confirmation; the existing round cap then bites for the right reason, and a finding the bar cannot express is by construction not a landing blocker. Guard the counter-risk by requiring DIRECT measurement independently of the artifact under suspicion, not the artifact's own report.


**B26 - Parallel fan-out that collides on surfaces nobody owns.** Launching every
dependency-ready piece at once, and discovering afterwards that several of them each had to
INVENT the same shared target-side artifact. *Symptom:* pieces at the same dependency depth
land conflicting versions of infrastructure that is nobody's deliverable - an index or layout
helper, a precision/type contract, an intrinsic wrapper the language pair requires. Each
version passes its own tests, all of them conflict at integration, and the review effort
multiplies by the number of pieces that guessed. Worst case, one piece's ad-hoc version of a
subtle helper becomes the de facto standard for the whole port because it happened to be
first. *Detector:* the ready-set is computed from DEPENDENCY readiness, which cannot see this -
the collision is not an edge in the graph, it is a shared requirement of the TRANSLATION. So
ask, before dispatching a wave: what will each of these pieces have to CONSTRUCT that is not a
translation of its own source? The language pair's trap table is the vocabulary for that
question; a construct required by MORE THAN ONE piece is a shared surface, not a per-piece
detail. *Mechanization:* derive each ready piece's target-side construct requirements from the
source (ask a parser, not a pattern), intersect them across the wave, and HOIST anything needed
by more than one into an owned prerequisite built BEFORE any consumer is dispatched. Cap the
wave on collision-freedom as well as on width. A construct you cannot determine makes that
piece ineligible for a parallel wave - schedule it alone rather than guess. *Prevention:*
first-use-wins is the failure, so make the shared surface someone's deliverable before it is
anyone's problem. When a worker reports "I wanted to factor a helper shared with another
piece", that is the signal working - it means the hoist was missed, and the answer is to
provision it, not to let them create it.


**B24 - A dependency map that follows branches the build compiles out.** Deriving the
dependency graph from the TEXT of import statements, without the preprocessor state the pinned
configuration fixes. *Symptom:* live units sit permanently blocked on dependencies that are
themselves excluded from the port. An excluded node never integrates, so the planner can never
make those consumers ready, and the wave stops widening for no reason visible in any single
file. *Detector:* cross-check the map against the excluded set - any live unit depending on an
excluded node is either a scoping error or a phantom edge, and both need explaining. Then read
the offending import: it will be inside a guard the configuration turns off. *Mechanization:*
give the extractor the configuration's macro state and have it recognize guarded regions with a
real directive scanner (which handles line continuations by construction). Apply the three-state
contract: provably-off drops the edge, provably-on keeps it, undeterminable is UNRELIABLE naming
the file and the macro. Note the asymmetry - dropping an edge WRONGLY is the dangerous direction,
because it lets a consumer be ported before its producer, so undeterminable must never silently
drop. Keep the macro state in PROJECT-layer data the extractor reads, not compiled into the tool.
*Prevention:* a dependency edge is a property of the CONFIGURED build, not of the text. An
extractor not given the configuration is guessing, and it guesses toward MORE edges - which reads
as conservative and is not, because the stall it produces looks like a planning deadlock rather
than a tooling defect.

**B25 - Shared mutable state that every piece must append to.** A registry, build file, or
manifest that each parallel piece edits in its own worktree, with no owner and no derivation.
*Symptom:* a piece goes non-green for a reason invisible in its own diff, because a merge or
rebase silently arbitrated between versions and dropped an entry. Or a build file lists a target
it cannot build, because one merge kept the target and lost its rule. Or literal conflict markers
reach a shipped file, because a conflicted tree was staged wholesale. *Detector:* for any file
many pieces must modify, ask who OWNS it, or what DERIVES it. If the answer is "everyone appends",
expect silent loss at every integration - and note the loss is not benign when absence means
permission: a dropped registry entry can turn a passing check into an unexplained failure.
*Mechanization:* prefer DERIVING the list from ground truth (the version-control index, the
tracked file set) over asking each piece to remember to add itself; a short regeneration step
repairs a bad merge mechanically. Where derivation is impossible, give the file a single owner and
have others report rather than edit. Retire redundant duplicates outright - two build systems
describing the same product will disagree, and the stale one becomes a silently-winning fallback.
*Prevention:* never stage a conflicted tree wholesale; and after any merge that touches shared
lists, re-derive and diff rather than trusting the result.

*Sharpening - the fully silent case, which the methodology itself introduces.* The symptoms above
(arbitration, a lost rule, literal markers) all imply a visible event. A per-path MERGE ATTRIBUTE
produces none: where the layering convention marks a path so that one side always wins, every
modification made on the other side is discarded with no conflict, no marker, and no diagnostic.
The asymmetry that hides it is that the attribute acts on MODIFICATIONS to files present on both
sides - a file that exists on only one side has nothing to arbitrate and passes through untouched.
So brand-new evidence files arrive normally while every edit to a long-lived shared ledger
evaporates, and the layer looks like it is working. Observed with a majority of already-landed
pieces carrying a ledger row that still read "not started", undetected because the completeness
check counted whether a ROW EXISTED rather than whether it was true. *Additional consequence:* a
registry that allocates STABLE IDENTIFIERS must never be written from a piece's branch under such
an attribute - when two pieces allocate concurrently, the discarded one frees its identifier and a
later piece reuses it for something entirely different, so the record does not merely vanish, it is
replaced by a contradictory one. Write identifier-allocating registries on the integration branch
only; have pieces report the content and let the integrator allocate the number. Where the
ledger is already GENERATED from per-piece fragments, that generation IS the derivation and
the repair belongs upstream of it: ensure the merge preserves each piece's fragment, then
regenerate and diff. Resist adding a second writer to the generated artifact - two
authorities over one file reproduce the very class this entry is about.

**B21 - An acceptance bar nobody checked against the reference.** Adopting a criterion
because it sounds rigorous, without asking whether the SOURCE meets it. *Symptom:* work
stops being translation and becomes an effort to LICENSE the bar - measuring the same
compiler behaviour repeatedly, probing whether the inputs where two renderings differ are
even reachable, binding toolchain identity so a stale verdict cannot be honoured. Each task
is real and each review of it is correct, and the pile grows. The tell is that a growing
share of the work would disappear if the bar changed, and none of it would disappear if the
translation improved. *Detector:* ask what the reference implementation achieves AGAINST
ITSELF. Mature numerical codebases ship their own acceptance values with a declared
tolerance; run the reference twice, or against its own shipped values, and see which it
reproduces - the tolerances, the bit patterns, or both. If the reference does not reproduce
itself to your bar, the bar is wrong. *Mechanization:* derive the acceptance criterion FROM
the source's own validation data - read the tolerance rather than choosing one - and make the
proof read it at run time so a change there propagates. *Prevention:* look up prior art BEFORE
building. Someone has done this class of port and published what they held it to; an hour of
reading is cheaper than a week of licensing. And note this is a failure reviews structurally
cannot catch: a reviewer checks the piece against its stated bar, not the bar against reality.
A chain of locally-correct decisions can be globally wrong, and only the orchestrator is
positioned to notice.

**B22 - Reshaping the product to satisfy a broken detector.** A conformance check flags a
legitimate construct the port had not used before, and the porter changes the TRANSLATION to
make the check pass. *Symptom:* a rendering that diverges from the source for no reason
visible in the source - a declared array turned into scalars, an automatic turned into a heap
allocation - with tests that pass, because the change was numerically equivalent. It reads as
a style choice and is actually an unauthorized departure. *Detector:* for any deviation from
the literal rendering, ask what REQUIRED it. If the answer is "a checker complained", that is
the bug: the checker is correct for the constructs it was built against, and a port keeps
introducing new ones. The porter cannot distinguish "my rendering is wrong" from "the checker
has not seen this form", and will default to trusting the tool. *Mechanization:* state the
precedence in the dispatch brief every time - the SOURCE decides the rendering; the tool must
be able to verify what the source dictates - and require that a check flagging a faithful
rendering be FIXED in the same piece, as a separate methodology-layer commit. *Prevention:*
treat "I changed the rendering so the check would pass" as a finding regardless of whether the
result is numerically identical. Seen twice in one phase, from two different porters and two
different checkers; neither porter was careless.

**B23 - A test that exercises the path but not the DISTINCTION.** Choosing correctly between
two plausible renderings, and writing a test that passes under either. *Symptom:* a unit
correctly picks one of two near-identical library functions - the pair that differ only on
negative operands, or only on a tie, or only on a special value - and its test uses inputs
outside the divergent region. The test exercises the code and proves nothing about the choice.
*Detector:* for every rendering chosen between alternatives, ask whether the test would FAIL
with the other one. If nobody has tried, the coverage is nominal. *Mechanization:* require a
SWAP-AND-FAIL in the evidence: substitute the rejected alternative, show the test go red,
restore, show it green. That artifact is the proof; the assertion "I used the right one" is
not. *Prevention:* the trap table's job is to name these choices, so make naming a choice
carry an obligation to demonstrate the rejected one fails.

*Refinement - the artifact proves a MOMENT, not a property.* A swap-and-fail can be produced
against a state that is then discarded: mutate the product, capture the red run, restore, and
commit a test that discriminates nothing. The evidence is genuine and the coverage is still
nominal, so requiring the artifact alone does not close this. Observed in a majority of the units
in a single wave, every one of them supplying a valid red log. Require instead that the
DISCRIMINATING ASSERTION IS COMMITTED to the product test suite and that the swap demonstrates
THAT COMMITTED assertion going red; a reviewer verifies durability by reversing the behaviour and
re-running the committed suite, never by reading the log. *Corollary hazard, created by this very
rule:* once deliberate mutation is a routine step for every piece, a mutation eventually gets
COMMITTED - a neutralised condition (`if (false && ...)`, `while (true || ...)`, an `#if 0` guard)
left behind because the restore was forgotten, silently disabling the policy the piece existed to
establish while its author reports a passing suite. A short-circuit literal in a condition is
cheaply SUSPICIOUS: scan the TARGET for conditions neutralised by a short-circuit literal and
for unconditionally dead guards. Be precise about what such a hit means. It is NOT proof of
residue - faithful SOURCE sometimes contains deliberately-dead code, and the literal
rendering of that source legitimately contains the same shape. So the finding is an
OBLIGATION TO JUSTIFY against the SOURCE line, not a verdict: either the SOURCE has the
corresponding dead construct, or this is residue. Mechanizing it needs care in three places,
each learned the hard way: exclude any build tree (generated build files legitimately
contain such shapes); be comment- and string-aware or it false-reds on prose; and resolve
the product root fail-closed or it reports green having examined nothing. Give a detector
for this the same adversarial review as any other - a bypassable one is worse than none.

**B27 - A non-normative presentational preference treated as a blocking review criterion.**
Independent review sends a FAITHFUL unit back, round after round, for findings that bear on NEITHER
the acceptance bar NOR any binding rule - a reviewer's own preference about phrasing, layout, or word
choice that the charter and the base do not make normative. *Symptom:* a run of units each take one
or more EXTRA review->rework cycles whose only findings are presentational - no change to fidelity,
slower delivery, zero accuracy gained. A tell-tale ESCALATION: the coordinator, seeing the class
recur, starts BUILDING A CHECK for the preference - which does not remove the friction, it
institutionalizes it (a manufactured B12) and escalates the wrong axis. *Detector:* for every
finding, ask whether it bears on either (a) the charter's ACCEPTANCE CRITERIA (literal rendering;
correct kinds, extents, and constants; the whole-run band) or (b) a BINDING rule or check. If
NEITHER, it is at most an advisory NOTE - never a `violations` verdict and never grounds to send a
unit back. *NOT a licence to wave through binding conventions:* provenance/anchor correctness and
the constant rule, accurate representation of the SOURCE in comments (B2), the no-process-meta-in-
product rule, and any conformance check are NORMATIVE - a finding there still blocks. The failure is a
reviewer INVENTING a criterion beyond what is normative, not relaxing one that is. Which conventions
are normative is fixed by the charter and the base's binding rules; a port MAY, as a recorded local
decision, reclassify one of ITS OWN conventions as advisory (precedence: charter > rules), but that
is the charter's call, not a reviewer's, and never the base default. *Bound:* do NOT propose a new check for a non-normative preference - if a class of finding is not worth blocking on, it is not worth
a detector either; the fix is to stop scoping it as blocking, not to automate the block. *Distinct
from:* B12 / B22, where a broken or over-strict TOOL flags faithful code - here the SCOPE of human
(or coordinator) judgment is the defect, with or without a tool; and from B20 and its refinement (the
unbounded adversary and the checker's-checker) - those run away along the adversary and artifact
axes, this one along the PRESENTATIONAL axis. *Prevention:* the acceptance bar is the charter's, set
once; the review's whole attention goes to whether the TARGET faithfully renders the SOURCE, and the
review brief names any genuinely non-normative preferences as explicitly OUT of scope so a reviewer
does not invent them.


## Numerical failure modes (about the *code*)

**L1 - The latent bug (most expensive class).** A genuinely-used term or constant,
mis-ported such that its effect is negligible at smoke-test settings but significant at
full-scale settings. Canonical instance: a stabilization constant mis-ported many orders
of magnitude too small - the resulting marginally-unstable scheme blows up only deep
into a full-length run, and only at the full timestep. *Detectors:* validate
at the full-scale configuration over a full-length run (not just smoke
tests); the file:line constant rule; per-kernel twin checks (the twin keeps its own copy
of every coefficient, so a mistyped constant fails the proof immediately).

**L2 - Stale exchange region (distributed-memory specialist).** A write loop ported
over owned points only where the SOURCE wrote owned-plus-halo. Diverges *silently*, and
only at some process counts; the damage can be indirect (a stale coefficient at the halo
breaking a cancellation several subsystems downstream) and can scale with the timestep,
so it passes at a short step and kills the full timestep. *Detectors:* the boundary
probe (copy, exchange, compare) run over all candidate fields at once; byte-identity
across rank counts where achievable. *Prevention:* size every field any downstream
routine might read at the exchange region at owned-plus-halo - the memory cost is
trivial and the failure severe.

**L3 - Allocated but never computed.** A field allocated and exchanged but never
assigned; it sits at zero and passes differential comparison (the reference is also
untouched at that phase), failing only when a later phase consumes it. *Detector:*
always-on physical-range probes. *Prevention (planning rule):* producer before
consumer - when a phase or workstream introduces a *reader* of a field, first verify
the *writer* is ported and proven; if none exists, port the producer first.

**L4 - Wrong stride / wrong extent.** Indexing with a loop bound where the allocated
extent belongs (or vice versa), classically when converting array storage order or
index base. Effect is typically violent (gradients inflated by orders of magnitude,
solver failure within steps). *Detector:* per-kernel twin check, which saturates far above the noise
floor at the first invocation. *Prevention:* take the stride from the allocation shape,
never from the iteration range; fixed, centrally-defined index helpers (macros, inline
functions, or accessor methods) - never ad-hoc index arithmetic at call sites; enforce
with a conformance script in `tools/conformance/`.

**L5 - Staggering / centering / location-class confusion.** In any code with
discretized fields on a grid or mesh: data stored at one location class
(vertices/cells/edges/faces, or staggered grid positions) used as if at another,
corrupting geometry-derived quantities. Especially likely on unstructured or staggered
discretizations, which are under-represented in training data relative to regular
grids. *Detector:* staged reference dump localizes the substep; identical-input diff
confirms the operator.

**L6 - Configuration drift.** A parameter whose effective value comes from the run's
parameter file, ported from the source-code default instead. Produces a *correct-looking*
model with a systematic bias. *Detectors:* pinned configuration with provenance (B3);
long-run statistical comparison.

**L7 - Vendor/platform-conditional code silently skipped.** A feature guarded by a
platform-specific compile flag is silently inert on a new platform - correct but slow,
or subtly different. (Typical instance: a device-residency layer behind a
vendor-specific guard, silently falling back to host staging on the other vendor.)
*Detector:* bring-up on a second, materially different platform early (a Phase-5 smoke
test can run as soon as Phase 3 yields a portable build); audit all conditional guards
to use neutral *capability* flags rather than vendor-specific ones.

**L8 - Stale authoritative copy (multi-memory-space specialist).** Two copies of a
field exist (host/device, cache/store, primary/mirror); one is updated, the other is
read. Invisible on the fast rig for many commits; surfaces only in configurations where
the stale reader is actually exercised, and grows orders of magnitude above the
floating-point floor. Naive debugging (toggling synchronizations) is confounded on
chaotic systems because it also changes execution order. *Detectors:* the executable
memory-authority contract (tool class 6) - a build that aborts when the non-authoritative
copy is read; the poison discriminator for localization; the mandatory short
all-subsystems-active proof (R4) before any commit touching data movement.

**L9 - Storage-order transform broken by buffer reinterpretation.** When the port
converts array storage order (the classic column-major to row-major), the per-array index
transform is sound only while each array owns its bytes. It becomes UNSOUND when one
buffer is reinterpreted under multiple shapes - aliased as several differently-shaped
arrays within a routine (EQUIVALENCE/overlay style), or reused and RESHAPED between
routines by a driver (one pass's output becomes the next pass's differently-shaped input
through the same scratch buffer). Transforming each view independently leaves every view
internally consistent, but the views disagree on byte layout: elements that coincide in
the SOURCE storage order no longer coincide. Because each routine is locally correct it
PASSES ITS OWN isolated proof, and the corruption surfaces only once the routines are
composed through the shared buffer - a suite of green per-unit proofs sitting over a broken
composition. *Detector:* an end-to-end proof over the composed pipeline, with inputs sized
to FORCE multi-unit composition (not the single-unit paths that dodge the seam); a green
per-unit proof is necessary but NOT sufficient here (see `validation-ladder.md`, rules of
thumb). *Prevention:* storage order is a WHOLE-SUBSYSTEM property, not a per-array one - if
any buffer is reinterpreted across views or routines, every routine touching it must share
ONE storage order: either preserve the SOURCE storage order for those buffers (a
charter-listed carve-out in the central index helpers) or route all views through a single
shared flat-index scheme. Decide it before porting the first aliased routine.

**L10 - Validating a stochastic code by comparing full runs (a cross-language false proof).**
An RNG-driven code (optimizer, Monte-Carlo, sampler) cannot be validated by running SOURCE and
TARGET to completion and comparing the outputs. Two independent reasons: (1) the languages' PRNGs
are different algorithms (the compiler intrinsic vs the TARGET library generator), so identical
seeds produce different random streams from the first draw - the trajectories diverge by
construction (see the language-pair trap table); (2) even with an identical stream, finite-precision
FP chaos amplifies tiny rounding differences over a long iterative trajectory. A whole-run
comparison therefore conflates "is the port faithful" with "the dice landed differently," and over
few samples it has almost no statistical power. A sibling pitfall: calibrating the whole-program
(trajectory or distribution) tolerance from the per-KERNEL precision floor - a dimensional
mismatch, because the trajectory / seed-to-seed variance dominates the kernel floor by orders of
magnitude, so a floor-derived bound is unachievable even by a perfect port. *Detector:* DETERMINISTIC
fixed-input differentials - feed fixed inputs, and substitute a FIXED value where the source draws
randomness, to the kernels AND to each update step of the stochastic logic, comparing against
SOURCE-computed references at the per-kernel tolerance; this isolates the arithmetic from both RNG
divergence and long-run chaos. *Prevention:* make the deterministic fixed-input differential the
acceptance proof for stochastic units; keep the full stochastic run only as a COARSE plausibility
check (sane output range, completes), never a numeric bar; and calibrate any whole-program tolerance
from the MEASURED distribution spread, not the kernel floor (the calibration brief, `/port-calibrate`).

**L11 - Rematerialized temporaries become per-call heap churn (a performance class).** The
SOURCE language manages working arrays implicitly - stack-allocated automatics, compiler-managed
temporaries, pooled scratch - so creating them is effectively free and invisible in a profile. A
literal port renders each as an explicit allocate-and-free in the TARGET. When those allocations
recur on the hot path (once per step, per column, per call) and each exceeds the allocator's
large-block threshold, a general-purpose allocator maps every one from the OS and returns it on
free, so each call re-faults a fresh run of zeroed pages. Runtime is then dominated by the kernel
page-fault / mapping path rather than the computation, and the port looks far slower than the
SOURCE for no algorithmic reason - while the SOURCE shows nothing, its temporaries living on the
stack or being reused. The same churn serializes threads on the allocator and kernel memory locks,
so it MASQUERADES as "memory-bandwidth bound" and as poor parallel scaling - a misdiagnosis that
sends the campaign after the wrong lever (e.g. reduced precision, which a fault-bound kernel barely
feels). *Symptom:* an unattributed or kernel symbol high in the profile; a page-fault count that
scales with the number of calls; measured runtime far above any compute estimate; the deficit
small at tiny per-call work and growing with it. *Detector:* read the page-fault counter beside
the profile; or toggle the allocator's OS-return policy once (raise its map threshold, disable
heap trimming through its tunables) - if runtime drops sharply with no code change, the limiter is
allocation churn, not compute. *Prevention:* reuse a persistent scratch buffer across calls
(allocate once, grow-only; thread-local under shared-memory parallelism) so the hot path allocates
nothing - equivalently, hoist the allocation out of the per-call loop. Where the process owner (not
a library) controls allocator policy, configuring it to recycle freed large blocks instead of
unmapping them is a bit-identical, zero-code recovery. This lever helps the SOURCE binary equally
if it shares the pattern - a floor both languages should stand on, not a TARGET-vs-SOURCE
advantage (see the fair-field rule in the performance campaign).

## The meta-lesson

Every class above breaks an unguarded port and is caught *cheaply* by one specific
guard. None is reliably caught by manual inspection. Therefore: build the guard set
before the port (Phase 1), and when a new failure class appears, mechanize its detector
and add it here.

One asymmetry deserves naming, because several classes above are instances of it. Every other
participant is audited by someone: a worker's output is read by an independent reviewer, a
reviewer's verdict is read by the orchestrator. The ORCHESTRATOR is audited by no one. So a control
that depends on the orchestrator remembering to do something is not a control - it is an intention,
and it fails silently and repeatedly under load, precisely when many pieces are in flight. The tell
is a step that appears in no checklist because "obviously you would do that": re-reading a commit
hash instead of recalling it, resolving a session handle instead of remembering it, checking a
worktree is current instead of assuming it, committing a report the moment a review returns,
re-deriving a shared ledger after a merge instead of trusting it, naming what is OUT of scope
before dispatching a review. Each was documented before it was mechanized, and documenting it did
not prevent a single recurrence. When the orchestrator is the failure point, the remedy is never
more diligence: build the tool at the point of use, make it fail closed, and put it in the path
that already runs.
