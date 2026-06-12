# KNOWN DIVERGENCES - <project name>

> The accepted-divergence registry: differences between port and reference that are
> CORRECT behavior and must not be chased (failure mode B4). Consulted FIRST in every
> debugging workflow; every gate report subtracts these. Entries are added only with
> human sign-off and the evidence that the difference is benign.

## Accepted nondeterminism in the SOURCE itself
| ID | What | Where it shows | Why it is benign | Signed off |
|---|---|---|---|---|
| D-001 | <e.g., reduction order depends on partition> | <e.g., solver diagnostics across rank counts> | <evidence> | <who/date> |

## Recorded floating-point floors (accelerator/threaded backends)
| ID | Backend | Field/quantity | Floor magnitude | Behavior over steps | Recorded at |
|---|---|---|---|---|---|
| F-001 | <e.g., device> | <field> | <value> | <steady / bounded> | <run ref, date> |

A real regression is identified by saturating ORDERS OF MAGNITUDE above these floors,
or by a floor that grows over steps instead of staying steady.

## Cross-language statistical residuals (Phase 2 acceptance evidence)
| ID | Quantity | Magnitude | Structure | Evidence | Signed off |
|---|---|---|---|---|---|
