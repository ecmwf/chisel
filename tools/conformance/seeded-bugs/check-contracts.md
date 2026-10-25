# SEEDED-BUG DEMONSTRATION - conformance/check-contracts

- Date: 2026-06-16 (new detector, WS-L: interface-contract + foundation-staleness; hardened after
  independent review)
- Detector: tools/conformance/check-contracts.sh (wraps tools/coordination/check_contracts.py)
- Failure class targeted: two independently proven modules can each pass their own proof while
  encoding conflicting assumptions about a shared seam (layout, units, indexing, halos, init
  order, precision, IO schema) - a silent semantic conflict no merge conflict and no per-piece
  proof catches. The methodology's answer: VERSIONED interface contracts, enforced
  producer-before-consumer (a consumer proofs against a PROVEN producer's contract version, not a
  moving target), and because proof evidence is commit-bound, a consumer goes STALE the moment its
  producer's contract advances. This check enforces that over the per-work-item fragments, and is
  hardened so the agreement cannot be faked by a duplicate id, a version alias, or self-consumption.
- Exit-code contract: 0 GREEN (every consumed contract is provided by a proven producer at the
  current version, or no fragments), 1 RED (a contract has no producer, an ungated producer, a
  fork, a stale/nonexistent version, a self-consumption, an unconsumed depended-on contract, or a
  malformed string), 2 UNRELIABLE (no python3 / PyYAML / git / bad --status-dir).

Each fragment (port/status/<id>.yaml) declares `provides_contract: "<name>@<version>"` (or null),
`consumes_contracts: ["<name>@<version>", ...]`, and `depends_on: [<id>, ...]`. Versions are
CANONICAL dotted non-negative integers with no leading zeros (`2`, `1.2`, `1.10`); satisfaction is
EXACT version-string equality (ordering is used only to word stale-vs-ahead). The check also reads
the dependency map (`--map`, default `tools/scoping/dependency-map.yaml`) so a PROVEN SOURCE edge to
a contract producer is enforced even when the fragment omits the dependency. The shipped GOOD
fixture is `tools/coordination/fixtures/contracts/status/` (a proven producer of `grid@2` and two
consumers of `grid@2`); fixtures/tests pass `--status-dir`.

## Seeded defects and red proofs

Each defect is a small mutation of the good fixture, run from a scratch copy -> RED, exit 1:

- **Stale consumer (foundation moved):** a consumer declares `consumes_contracts: [grid@1]` while
  the producer provides `grid@2` ->
  `[FAIL] io_mod: consumes 'grid@1' but producer 'grid_mod' now provides 'grid@2' - STALE, re-prove the consumer against the current contract`
- **No producer:** a consumer declares `[layout@1]` that no fragment provides ->
  `[FAIL] io_mod: consumes 'layout@1' but no work item provides contract 'layout'`
- **Ungated producer:** the producer's `status` is `in-progress` while consumers proof against it ->
  `[FAIL] io_mod: consumes 'grid@2' but its producer 'grid_mod' is not proven (status: in-progress) - producer-before-consumer`
  (every consumer is flagged, not just one.)
- **Forked contract (two distinct providers):** a second fragment `grid_mod2` also provides `grid@3` ->
  `[FAIL] contract 'grid' is provided by multiple fragments (grid_mod, grid_mod2) - one owner per contract`
  and each consumer gets `consumes 'grid@2' but contract 'grid' is forked ... resolve the fork first`.
- **Forked contract hidden behind a DUPLICATE id:** two files both `id: grid_mod` providing `grid@2`
  and `grid@3` -> RED, exit 1 (the fork can no longer hide behind a shared id):
  - `[FAIL] duplicate work-item id 'grid_mod' across fragments`
  - `[FAIL] contract 'grid' is provided by multiple fragments (grid_mod, grid_mod) - one owner per contract`
- **Self-consumption (producer == consumer):** a fragment provides `grid@2` AND consumes `grid@2` ->
  `[FAIL] solver: consumes 'grid@2' which it also provides - a work item cannot satisfy its own contract (producer-before-consumer)`
- **Version alias:** a non-canonical version such as `grid@02` (or `grid@2.00`) ->
  `[FAIL] grid_mod: provides_contract 'grid@02' is not a valid '<name>@<version>' (canonical dotted-integer version, no leading zeros)`
  (so `02` can never silently equal `2`; a malformed `consumes_contracts` entry like `grid` with no
  `@version` is reported the same way.)
- **Depend on a contracted foundation without consuming its contract:** a consumer with
  `depends_on: [grid_mod]` (which provides `grid@2`) and no `grid` in `consumes_contracts` ->
  `[FAIL] solver: depends_on 'grid_mod' which provides contract 'grid@2', but consumes no 'grid' contract - proof against the foundation's contract`
- **Under-declare the dependency to dodge the contract (the depmap cross-check, C7):** a STARTED
  consumer (in-progress/proven) that drops BOTH `depends_on` and `consumes_contracts` while the
  dependency map still records a PROVEN edge from it to the contract producer ->
  `[FAIL] io_mod: has a proven SOURCE dependency on 'grid_mod' (per the dependency map) which provides contract 'grid@2', but does not consume it - producer-before-consumer`.
  The self-reported `depends_on` arm above cannot catch this (there is no `depends_on` to check); the
  map is ground truth, so producer-before-consumer cannot be skipped by simply omitting the edge. An
  `unmapped` consumer is exempt (it has not started declaring its contracts).

## Green proof (defect removed)

- The shipped good fixture: GREEN, exit 0 - `checked 3 fragment(s); 0 violation(s)` (the proven
  `grid_mod` provides `grid@2`; `io_mod` and `solver` consume the current `grid@2`).
- The base repo with no `port/status/` fragments: GREEN, exit 0 - `no fragments ... skipping`.

## Causal proof (the check is what catches it)

A consumed contract passes only when exactly one fragment provides that name (no fork, no duplicate
id), that producer is a DIFFERENT proven work item, and the consumed version-string exactly equals
the producer's current version; and a fragment that depends on a contracted foundation must consume
its contract. Move the producer's version, un-proof it, fork it (even under a shared id), drop it,
misspell the version, consume your own contract, or depend without consuming, and the verdict goes
GREEN -> RED naming the offender. "These modules agree on their shared seam" therefore means "the
consumer proven against the single proven producer's current contract version," never "they happened
to both pass their own proofs."

## Scope / non-defect signals confirmed

- Exact-string satisfaction over a canonical version grammar: `02`/`2.00`/`1-alpha` are malformed
  (RED), never silently aliased to `2`/`2.0`, so a real version mismatch cannot pass; ordering
  (`_ver_key`) is used only to word the stale-vs-ahead diagnostic, never to decide satisfaction.
- One owner per contract is enforced on the number of providing FRAGMENTS (and duplicate ids are
  rejected), so a fork cannot hide behind a shared id; a consumer of a forked contract is told to
  resolve the fork rather than handed an arbitrary "current" version.
- Producer-before-consumer is fail-closed: an `in-progress`/`excluded`/absent-status producer, or
  the producing fragment itself, never satisfies a consumer (a producer that is integrated keeps
  `status: proven`, so it still satisfies).
- Orthogonal to check-status-fragments (which validates a fragment in isolation): this is the
  CROSS-fragment producer/consumer/version/dependency consistency a single fragment cannot show.
- Fail-closed UNRELIABLE (exit 2), distinct from RED: PyYAML absent, not a git repo, an explicit
  `--status-dir` that is not a directory, OR a dependency map that is present but malformed (not a
  mapping, or `edges` is not a list) - the proven-edge cross-check is then refused, never silently
  disabled (so deleting/corrupting the map cannot quietly turn C7 off); malformed-YAML / non-mapping
  / non-list fragment fields are RED.

## Comparison-logic version

The logic is: reject duplicate work-item ids; parse each `provides_contract` into a producer index
(name -> version, owner, status), flag any name provided by >1 fragment as a fork; for each
`consumes_contracts` entry require a producer for the name, that the name is not forked, that the
producer is a DIFFERENT work item, that the producer is proven, and that the consumed version-string
exactly equals the producer's current version (less -> STALE, greater -> nonexistent); require a
`depends_on` of a contract-providing fragment to consume that contract; canonical-version and
`<name>@<version>` grammar are validated (non-canonical -> malformed). Empty violation list ->
GREEN, any violation -> RED, a bad environment/path -> UNRELIABLE. Re-run this demonstration after
any change to the contract parsing, the version grammar/comparison, the fork/duplicate-id rule, the
producer-proven rule, the self-consumption rule, the depends_on cross-check, or the depmap
proven-edge cross-check (a started consumer must consume the contract of any contract producer it
has a proven map edge to) (standing seeded-bug rule): every listed defect must go RED and the good
fixture stay GREEN.
