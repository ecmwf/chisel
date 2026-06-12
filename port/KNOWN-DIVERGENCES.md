# KNOWN DIVERGENCES - Fortran → C port

> The accepted-divergence registry: differences between port and reference that are
> CORRECT behavior and must not be chased (failure mode B4). Consulted FIRST in every
> debugging workflow; every gate report subtracts these. Entries are added only with
> human sign-off and the evidence that the difference is benign.

## Accepted nondeterminism in the SOURCE itself
| ID | What | Where it shows | Why it is benign | Signed off |
|---|---|---|---|---|
| (none yet) | | | | |

## Recorded floating-point floors (threaded/accelerator backends - large port)
| ID | Backend | Field/quantity | Floor magnitude | Behavior over steps | Recorded at |
|---|---|---|---|---|---|
| (n/a for serial pilot) | | | | | |

A real regression is identified by saturating ORDERS OF MAGNITUDE above these floors,
or by a floor that grows over steps instead of staying steady.

## Cross-language statistical residuals (Phase 2 acceptance evidence)
| ID | Quantity | Magnitude | Structure | Evidence | Signed off |
|---|---|---|---|---|---|
| (none yet) | | | | | |
