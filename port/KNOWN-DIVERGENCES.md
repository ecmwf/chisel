# KNOWN DIVERGENCES - <instance name>

> The accepted-divergence registry: differences between the port and the reference that are
> correct behavior and must not be chased (failure mode B4). Debugging consults it first, and
> every proof report subtracts these entries. An entry is added only with the human's sign-off and
> the evidence that the difference is benign.

## Accepted nondeterminism in the SOURCE itself
| ID | What | Where it shows | Why it is benign | Signed off |
|---|---|---|---|---|
| (none yet) | | | | |

## Recorded floating-point floors (threaded/accelerator backends)
| ID | Backend | Field/quantity | Floor magnitude | Behavior over steps | Recorded at |
|---|---|---|---|---|---|
| (n/a for a serial port) | | | | | |

A real regression shows as orders of magnitude above these floors, or as a floor that grows over
steps instead of staying steady.

## Cross-language statistical residuals (Phase 2 acceptance evidence)
| ID | Quantity | Magnitude | Structure | Evidence | Signed off |
|---|---|---|---|---|---|
| (none yet) | | | | | |

## Ratified rendering departures
A faithful rendering that departs from the charter's mechanical transformations (failure modes B8,
B10). The human authorizes it as a charter named exception (section 4); its row here lets a
reviewer find it.

| Charter exception | Site (TARGET file:line) | Departure | Ratified (who, date) |
|---|---|---|---|
| (none yet) | | | |
