<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Failure modes in LLM-assisted numerical porting

The recurring ways a port goes wrong, each with its cause, its symptom and the cheap defense that
catches or prevents it. Each class has a permanent ID: B for the agent's behavior, N for the
numerics of the code. Lessons, reviews and seeded bugs cite them by ID. When a port ends, fold its
distilled lessons back into this file, with the human's approval.

Read it at Phase 1 - the defenses are the requirements list for the differential tooling - and
again whenever debugging.

## Agent behavior (B)

**B1 - The urge to improve.** *Cause:* a standing pull to simplify, modernize or clean up while
translating. *Symptom:* plausible output and an unbounded debugging search; whole ports have failed
from improvements alone (a linearized coefficient, a lookup table replaced by a closed form, a volume
ratio swapped for an area ratio, a history length no longer matching the scheme's order - each
defensible, each wrong). *Defense:* the literal-translation rule and the independent review. If you
find yourself calling a deviation harmless, stop and propose it as a charter exception.

**B2 - Paraphrase instead of the line.** *Cause:* stating what the SOURCE does from memory, pattern
completion or a comment. *Symptom:* a confident wrong value; a wrong comment about a constant once hid
an instability for several sprints. *Defense:* the file:line citation rule - quote the path, line and
literal text read this sprint. Mechanized for constants: `verify-anchors.sh` binds every TARGET
constant to its SOURCE constant, by name or by an optional anchor, and compares them by value
(target-conventions skill). Inherited comments are untrusted; one found contradicting its code
becomes a contradiction marker and is logged, so it is defused once instead of re-trusted by every
later sprint.

**B3 - Following the inactive branch.** *Cause:* porting a path the pinned configuration never runs,
or a source default the run's parameter file overrides (typically a scheme with two implementations
chosen by one parameter, where the obvious one is wrong). *Symptom:* a systematic regional bias in
the multi-run comparison. *Defense:* the pinned configuration in the charter, with provenance for
every effective value (parameter file beats source default).

**B4 - Chasing an accepted divergence.** *Cause:* investigating a difference that is correct SOURCE
behavior (partition-dependent reductions, documented nondeterminism, the recorded accelerator floor).
*Symptom:* sprints spent on a ghost. *Defense:* `port/KNOWN-DIVERGENCES.md`, consulted first in every
debugging workflow and appended only with human sign-off.

**B5 - Stale state over a moving repo.** *Cause:* a sprint writes state (a whole-file rewrite of a
handoff or plan, a commit) from what it read at the start, while the repo moved underneath.
*Symptom:* a concurrent edit silently overwritten, or a plain commit that silently concludes a pending
merge and sweeps in foreign staged content; no conflict fires. *Defense:* re-read or blob-compare a
state file just before rewriting it; before committing, check that no merge is pending and the staged
set is exactly the announced paths; afterwards, check the parent is the HEAD you reconciled against.
One writer per worktree: a session that finds its worktree changed stops and reports, and never
absorbs or reverts the change.

**B6 - Coverage read as liveness.** *Cause:* excluding a unit because coverage shows it never ran,
although a declarations-only unit (constants, type aliases, shared data) shows zero coverage at any
run length and is live when live code references it. *Symptom:* a build failure, or worse a hand
re-derivation of the dropped constants (B1). *Defense:* executed = live; not executed,
declarations-only and referenced = live; anything else not executed = REVIEW, and the human decides.
Exclude only with proof of deadness (not compiled, or unreachable by code reading); then a short
coverage run is enough. When the build generates sources, a template is live if its output feeds a
live unit, a header's liveness comes from the compiler's dependency files (never a text search), and
a header no live unit includes is REVIEW.

**B7 - An assembly-proven deliverable landed piece by piece.** *Cause:* landing the members of a
deliverable one at a time when its proof links several modules (no member passes alone) and its work
branches each carry the whole closure with the same build target. *Symptom:* the first land stales
every sibling, build files collide, and an intermediate mainline fails the assembly proof.
*Defense:* before landing, ask whether the proof links more than one module or the branches share a
build target. If so, land the group as one reviewed assembly piece with `integrate_assembly.sh`
(two-repo-architecture.md, "Assembly-proven deliverables land as ONE reviewed tree").

**B8 - Unratified seam departure.** *Cause:* the author alone choosing a non-literal rendering for a
SOURCE construct with no direct TARGET analog (a foreign-library bridge, a generic interface that
does not collapse to one dispatch, an execution-model branch deferred to a later phase, an external
symbol rendered as a no-op). *Symptom:* the proof passes, but the review raises a governance finding.
*Defense:* the review checks every seam against the charter's mechanical-transform list; an unlisted
one is a finding until the human authorizes it as a charter named exception (section 4), with its
row in `KNOWN-DIVERGENCES.md`, so surface seams for that decision before asking for `proven`. If the code is faithful and unchanged, the ratified row clears
the finding and the reviewer records `clean`, with no re-proof or re-review. A code fix is B9.

**B9 - Editing a proven file without re-proving.** *Cause:* a small edit (moving a helper, stripping
a comment) to a `proven` file, presented as still proven. *Symptom:* the proof re-runs green, but no
review has seen the new code. *Defense:* `proven` belongs to the code, the review and the evidence
together; change one and it is void. The edit returns the entry to `in-progress`, adds the editing
session to `author_sessions`, marks the old review as pre-edit, and owes a re-prove and a fresh review
in a separate session. The code is the piece's own target-file bytes, not the commit SHA: a rebase
always owes a re-prove (a moved foundation can change the numbers), but a fresh review only if the
piece's own files changed, as `review_revalidate.sh <id>` decides fail-closed (VALID: reuse the
review and advance `proof.commit`; STALE or UNRELIABLE: review again).

**B10 - Behaviour-neutral departure presented as done.** *Cause:* a faithful, numerically neutral
rendering not on the mechanical-transform list (a live range divided differently, an allocation size
clamped to non-negative), presented as done because it is "faithful and neutral". *Symptom:* a
violations verdict on code whose proof passes. *Defense:* register the departure before review; as in
B8, the ratified row clears the finding with no re-proof or re-review, and a code fix is B9.

**B11 - Pre-writing the review outcome.** *Cause:* writing "independent review clean, proven" into
the evidence before the review runs. *Symptom:* evidence asserting what has not happened, which can
anchor the reviewer. *Defense:* write the review section as pending, with only the facts that exist,
and fill in the verdict when it returns. Prose cannot make a piece proven: `check-trace-evidence`
requires a recorded clean review and `check-status-fragments` an independent reviewer. Correcting
premature prose is a prose fix, not a reason for a new review.

**B12 - Churning faithful code to satisfy an over-strict tool.** *Cause:* a checker stricter than its
stated intent (it over-matches, or judges a context it cannot see such as a precision regime or a
multi-line statement). *Symptom:* the proof is green, the checker red, and the author rewrites
faithful or proven code until the tool goes quiet. *Defense:* when the proof passes and a mechanical
checker fails, suspect the checker. Fix it and re-demonstrate its seeded bug (real defect still red,
false positive gone); a checker change is a methodology change, contributed upstream. If policy
leaves a proven construct that departs from convention, record a per-site waiver tied to a divergence
row. Never silence the check, and never churn proven code for it (B9).

**B13 - A hardened check that deadlocks the fix's own land.** *Cause:* a methodology sync makes a
check fail closed on a construct the attested TARGET already contains, while the land requires the
suite green before landing. *Symptom:* "conformance RED at HEAD" refuses the very piece that removes
the red. *Defense:* a land judges its merge result, as `integrate_land.sh` does. Where a land still
requires HEAD green, never silence the check, hand-edit the TARGET or land another piece over the red:
restore the previous checker uncommitted, land the fix through the guarded script, restore the
hardened checker, and contribute the land-scope fix. Two relatives: a `--land-only` sync refuses
while a local checker calibration differs from the base (restore the base layer, land, then re-apply
or contribute it); and a schema migration the new tools need is project-layer work, committed
separately after the sync.

**B14 - Hand-improvised integration that hides a failed merge.** *Cause:* when the guarded land
seems blocked, hand-running it as a chain (`git merge ... | tail -1 && attest && release && push`).
*Symptom:* the pipe returns `tail`'s exit code, so a refused merge is ignored and the chain records
`integrated`, releases the claim and tears down the branch for code that never landed. *Defense:*
never hand-run a land: the guarded scripts run with `pipefail`, re-check the landed result and roll
back. Never pipe a guarding command through `tail`, `head` or `| true`. If a land refuses, fix the
blocker (rebase, or `/port-sync-with-base` for a script fix). A planner triage "marked integrated but
not acceptance-ready" means a faked or half-done land: restore the branch from its dangling commit,
reset `integration.state` in a forward commit, and land properly.

**B15 - A subagent hunting for its own session id.** *Cause:* a prompt asks a worker or reviewer for
its own `author_id` or `reviewer_session`, which a subagent cannot see; only the dispatcher reads it
from the subagent result. *Symptom:* the subagent probes environment variables and the opencode CLI
(`opencode session list`) and stalls the session. *Defense:* Ptah-Orchestrator records identities
from the subagent results. A subagent never looks for or returns its own id and never runs the
opencode CLI; it returns only its work product, and a null id from it is expected.

**B16 - A hand-rolled gather that misses silently.** *Cause:* updating many fragments with an
exact-string replace (`"author_id: null\n"`) that does nothing when the line has a trailing comment,
or with shell constructs another shell reads differently. *Symptom:* a count of loop iterations
reported as replacements; a null `author_id` survives and the independence check passes vacuously.
*Defense:* replace whole lines (`^author_id:.*$`), keep gather steps in Python or POSIX shell, and
verify the postcondition (every fragment has its ids), never the script's tally. For the worker's id,
`stamp_author_id.py <id>` reads the claim's recorded worker thread and verifies what it wrote.

**B17 - A one-time warning trusted as a lasting guard.** *Cause:* a setup step detects a lasting
problem and prints one warning to one session. Example: importing the SOURCE strips its `.git`, every
file becomes untracked, and the SOURCE's own `.gitignore` starts excluding real source; `git add`
exits 0 without it. *Symptom:* green in the main tree, red in every fresh clone and worktree, since
only the main tree still holds the untracked file; when workers report a failure Ptah-Orchestrator
cannot reproduce, believe the workers. *Defense:* a checkable postcondition with a durable record
becomes a standing check: `check-source-import.sh` compares tracked counts with the provenance
record, and `check-live-tracked.sh` checks that every live file is tracked.

**B18 - Re-deriving what a tool already knows.** *Cause:* hand-rolling a text scanner for a question
a parser, index or loader answers exactly (what is a declarator, which preprocessor branch is live,
call or array reference, which files a build contains, whether a file is well-formed). *Symptom:* a
patch streak, each fix covering a form the last one missed; the check gets greener, not more correct.
*Defense:* ask what the authority is (the language front end, git's index, the loader that consumes
the file), call it, pin it as a dependency, and make its absence UNRELIABLE. One patch to a scanner is
maintenance; three in a row is a design error.

**B19 - A verdict that depends on where it ran.** *Cause:* treating a result from one environment as
true everywhere. *Symptom:* green locally and red in CI, or green in the main tree and red in
worktrees, with nothing in the diff. *Defense:* record what a verdict that licenses later work is
bound to (compiler version, flags, library content hashes, tree state) and have the consuming proof
compare before honouring it. CI installs every parser the checks need, so a missing tool is red, not a
silent local pass. After each land that pushes, confirm CI passed before the next one; fix a red CI by
installing what is missing, never by loosening the check.

**B20 - An unbounded adversary in a review brief.** *Cause:* reviewing a detector against an attacker
who already has write access (PATH shadowing, symlink farms, check-to-use races) and treating each
such finding as blocking. *Symptom:* review rounds that never converge. *Defense:* ask whether a
finding is reachable by honest error (a tired author, a broken detector, an ordinary accident such as
a system upgrade) or needs someone who could just as well edit the check; the second class has no
fixed point. Ratify a threat model in the charter before the first review (section 6a): out-of-scope
findings become notes, and "could not determine" still blocks. Cap the review rounds; at the cap,
narrow the unit or ask the human for a scoping decision. The same drift happens when rounds review the
tooling behind the deliverable, then the tooling behind that: a tooling defect blocks only if it could
make the deliverable's own proof green while the property is false, and a defect in one of two
independently verified layers is mitigated. Every review brief names the artifact under review and
what is already confirmed independently.

**B21 - An acceptance bar nobody checked against the SOURCE.** *Cause:* adopting a criterion because
it sounds rigorous, without asking whether the SOURCE meets it. *Symptom:* the work shifts to
licensing the bar (re-measuring compiler behaviour, binding toolchain identity); much of it would
vanish if the bar changed, none if the translation improved. *Defense:* ask what the SOURCE achieves
against itself (run it twice, or against its own shipped acceptance values) and derive the bar from
its own validation data, read by the proof at run time (validation-ladder.md). Reviews judge a piece
against its bar and cannot catch this; Ptah-Orchestrator must.

**B22 - Reshaping the product to satisfy a broken detector.** *Cause:* a check flags a legitimate
construct it was not built for, and the porter changes the translation instead of the check.
*Symptom:* a rendering that differs from the SOURCE for no reason found in the SOURCE (a declared
array turned into scalars, an automatic array turned into a heap allocation), with tests passing
because the change is numerically equivalent. *Defense:* for every deviation from the literal
rendering, ask what required it; "a checker complained" is the bug. Every dispatch brief says that the
SOURCE decides the rendering and the tool must verify what the SOURCE dictates; a check that flags a
faithful rendering is fixed in the same piece, as a separate methodology commit.

**B23 - A test that runs the path but not the distinction.** *Cause:* choosing correctly between two
near-identical renderings (functions that differ only on negative operands, a tie or a special value)
and testing outside the region where they differ. *Symptom:* the test passes under either choice.
*Defense:* a swap-and-fail: substitute the rejected alternative, show the test red, restore, show it
green. Refinements learned in review:
- The discriminating assertion is committed to the product suite and the swap turns that committed
  assertion red; a red log against a discarded state proves nothing durable. Reviewers check by
  reversing the behaviour and re-running the committed suite.
- Bind it to production (the function's output, its signature, a production-declared field), never
  to a test-local stand-in: two test temporaries, a type check on a test-declared entity, an expected
  value computed by the same production helper, a shadow copy or partial set of outputs, a
  precomputed boolean hiding a forbidden comparison. These shapes can be linted in the test tree.
- Make the choice observable: a comparator exactly at its boundary, an index or layout choice with
  distinct extents, a reassociation with the term isolated and magnitudes spread enough to exceed the
  tolerance (try the lower precision first). Never loosen the tolerance to get a pass.
- Where a site cannot discriminate by construction (a first guess that convergence washes out,
  bit-identical renderings), record the attempt with the measured delta in each precision and test
  what is observable. Reviewers block on "not attempted", not on "not discriminable".
- A forgotten restore can commit a condition short-circuited by a literal or a guard that is always
  false. Scan the TARGET for both, skipping build trees, comments and strings and failing closed
  without a product root; a hit must be justified against the SOURCE, which may hold the same shape.

**B24 - A dependency map that follows compiled-out branches.** *Cause:* deriving edges from the text
of imports without the preprocessor state the pinned configuration fixes. *Symptom:* live units
blocked for good on excluded units that never integrate; the wave stops widening for no visible
reason. *Defense:* cross-check the map against the excluded set: a live unit depending on an excluded
one is a scoping error or a phantom edge. Give the extractor the configuration's macro state
(`tools/scoping/macro-state.yaml`) and a real directive scanner: provably off drops the edge, provably
on keeps it, undeterminable is UNRELIABLE, naming the file and macro. Never drop an edge silently: a
wrongly dropped edge lets a consumer be ported before its producer.

**B25 - Shared mutable state that every piece appends to.** *Cause:* a registry, build file or
manifest edited by every parallel piece, with no owner and no derivation. *Symptom:* a piece goes red
for a reason not in its diff because a merge dropped an entry; conflict markers reach a shipped file.
A merge attribute that makes one side win (the layer merge drivers) loses edits with no conflict at
all: it discards changes to files present on both sides while new files pass through, so a ledger
quietly stops updating and a row-counting check never notices; two pieces allocating an id this way
can leave one id naming two things. *Defense:* derive the list from ground truth (the git index, the
tracked files) and regenerate it after every merge; otherwise give the file one owner. A generated
file gets no second writer. Retire duplicates (two build systems for one product disagree, and the
stale one wins silently). Allocate stable ids on the integration branch only, and never stage a
conflicted tree wholesale. The drivers act on every merge, cherry-pick and rebase: assemble a
multi-part methodology change by plain patch application and check every added line is present.

**B26 - Parallel fan-out colliding on surfaces nobody owns.** *Cause:* dependency readiness cannot see
shared needs of the translation, so several ready pieces each invent the same index helper, precision
contract or intrinsic wrapper. *Symptom:* conflicting versions at integration, multiplied review, and
the first ad-hoc version silently becoming the port's standard. *Defense:* before each wave, derive
what each ready piece must construct on the TARGET side and hoist anything needed by more than one
piece into an owned prerequisite built first (parallel-phase-2.md, step 1b). A worker asking to factor
out a helper shared with another piece means the hoist was missed.

**B27 - A presentational preference treated as blocking.** *Cause:* a reviewer sends a faithful unit
back over phrasing, layout or word choice that neither the charter nor a binding rule makes
normative. *Symptom:* extra review rounds with no fidelity gain; worse, a check built for the
preference. *Defense:* a finding blocks only if it bears on the charter's acceptance criteria
(literal rendering, kinds, extents, constants, the whole-run band) or a binding rule or check
(anchors and constants, faithful comments (B2), no process-meta in the product, any conformance
check); anything else is a note. Only the charter can make a port's own convention advisory. Build no
check for a preference, and name such preferences as out of scope in the review brief.

**B28 - Evidence that cites self-staling facts.** *Cause:* evidence citing facts that change for
reasons unrelated to the unit: its own workbench HEAD, product-wide totals, absolute TARGET line
numbers. *Symptom:* review rounds on the evidence alone, each refresh stale on arrival. *Defense:* ask
of every fact "does this change when I commit, or when another unit lands?" Cite the commit the proof
and review ran on (`proof.commit`), unit-scoped counts, and TARGET lines at that commit or symbols and
anchors. A stale fact is removed or replaced by its stable form, never refreshed. SOURCE file:line
citations are stable and stay mandatory (B2).

## Numerics (N)

**N1 - The latent bug (the most expensive class).** *Cause:* a live term or constant mis-ported so
that its effect is negligible at smoke-test settings and large at full scale (a stabilization
constant orders of magnitude too small, blowing up only deep into a full-length run at the full
step size). *Symptom:* clean short runs, failure late at full scale. *Defense:* validate at the
full-scale configuration over a full-length run; the file:line constant rule; per-kernel twin
checks, which keep their own copy of every coefficient.

**N2 - Stale exchange region.** *Cause:* in distributed memory, a write loop ported over owned points
where the SOURCE wrote owned-plus-halo. *Symptom:* silent divergence at some process counts only,
possibly indirect (a stale halo coefficient breaking a cancellation several subsystems downstream)
and growing with the step size. *Defense:* the boundary probe (copy, exchange, compare) over all
candidate fields at once; byte-identity across rank counts where achievable; size every field a
downstream routine might read in the exchange region at owned-plus-halo.

**N3 - Allocated but never computed.** *Cause:* a field allocated and exchanged but never assigned.
*Symptom:* it sits at zero and passes the differential comparison (the reference is also untouched at
that phase) until a later phase reads it. *Defense:* always-on range probes, and producer before
consumer (bring-up-strategy.md).

**N4 - Wrong stride or extent.** *Cause:* a loop bound used where the allocated extent belongs, or the
reverse, typically when converting storage order or index base. *Symptom:* usually violent (gradients
off by orders of magnitude, solver failure within steps). *Defense:* the per-kernel twin check;
strides from the allocation shape; central index helpers only, enforced by a conformance script. A
masked variant (an index base taken from the iteration range instead of the declared lower bound, a
partition-wide table indexed per chunk, a zero-based array read through a one-based helper) is
bit-identical to correct code whenever the chunk starts at the lower bound, so it survives unit
proofs and review. Make the canonical whole run multi-chunk at two or more decompositions; review
each subscript's base against the SOURCE declaration; start unit fixtures away from the lower bound,
with arrays at their full allocated layout.

**N5 - Location-class confusion.** *Cause:* data stored at one location class (vertices, cells,
edges, faces, staggered positions) used as if at another; likelier on unstructured or staggered
discretizations. *Symptom:* corrupted geometry-derived quantities. *Defense:* the staged dump
localizes the substep; the identical-input diff confirms the operator.

**N6 - Configuration drift.** *Cause:* a parameter ported from the source default instead of the
run's parameter file. *Symptom:* a correct-looking model with a systematic bias. *Defense:* the
pinned configuration with provenance (B3); the long-run statistical comparison.

**N7 - Platform-conditional code silently skipped.** *Cause:* a feature behind a vendor-specific
compile flag that is inert on another platform (a device-residency layer silently falling back to host
staging). *Symptom:* correct but slow, or subtly different. *Defense:* bring the port up on a second,
materially different platform early; guard with capability flags, never vendor flags.

**N8 - Stale authoritative copy.** *Cause:* two copies of a field (host and device, cache and store),
one updated and the other read. *Symptom:* invisible on the fast rig, then far above the
floating-point floor wherever the stale reader runs; toggling synchronizations confounds debugging on
a chaotic system. *Defense:* the executable memory-authority contract (tool class 6); the poison
discriminator to localize; the short all-subsystems-active proof (R4) before any commit that touches
data movement.

**N9 - Storage-order transform broken by buffer reinterpretation.** *Cause:* converting storage
order array by array is sound only while each array owns its bytes; a buffer viewed under several
shapes (aliased views in one routine, or reshaped between routines through shared scratch) ends up
with views that disagree on layout. *Symptom:* every routine passes its own proof while the
composition is wrong. *Defense:* an end-to-end proof over the composed pipeline, with inputs that
force multi-unit composition. Treat storage order as a property of the whole subsystem: every routine
touching a reinterpreted buffer shares one order (the SOURCE order kept for those buffers as a charter
carve-out, or one shared flat index), decided before the first aliased routine is ported.

**N10 - Validating a stochastic code by comparing whole runs.** *Cause:* the two languages' random
generators differ from the first draw, and finite-precision chaos amplifies tiny differences.
*Symptom:* whole-run comparisons that confound fidelity with the dice; a whole-program tolerance taken
from the per-kernel floor, which even a perfect port cannot meet. *Defense:* the acceptance proof is a
deterministic fixed-input differential - fixed inputs, and a fixed value wherever the SOURCE draws
randomness, for each kernel and update step, at the per-kernel tolerance. The full stochastic run is
only a coarse plausibility check; a whole-program tolerance comes from the measured spread
(`/port-calibrate`).

**N11 - Temporaries turned into per-call heap churn.** *Cause:* working arrays the SOURCE keeps on the
stack or reuses become an allocate and free per call in the TARGET; blocks above the allocator's
large-block threshold are mapped from the OS and returned each time. *Symptom:* runtime dominated by
page faults, passing for memory-bandwidth limits or poor scaling. *Defense:* read the page-fault
counter, or raise the allocator's map threshold once (a sharp drop with no code change confirms it).
Reuse a persistent grow-only scratch buffer (thread-local under threading), or have the process owner
make the allocator recycle large blocks, a bit-identical fix. The SOURCE build gets the same lever if
it shares the pattern (the fair-field rule, performance-campaign.md).

## The meta-lesson

Every class above breaks an unguarded port and is caught cheaply by one specific guard; none is
reliably caught by inspection. Build the guards before the port (Phase 1), and when a new class
appears, mechanize its detector and add it here.

One asymmetry sits under several classes. A worker's output is read by a reviewer, and a reviewer's
verdict by Ptah-Orchestrator, but nobody audits Ptah-Orchestrator. A control that relies on it
remembering a step is an intention, and it fails silently under load: re-reading a commit hash instead
of recalling it, resolving a session handle from the ledger, checking that a worktree is current,
committing a report as soon as a review returns, re-deriving a shared ledger after a merge, naming
what is out of scope before dispatching a review. Writing these down did not prevent a single
recurrence. The remedy is a tool at the point of use that fails closed, in a path that already runs.
For example, `provision_worker.sh remove` refuses while a worktree holds evidence not yet gathered
onto the workbench mainline, because a forced teardown once lost the record of independent reviews.
