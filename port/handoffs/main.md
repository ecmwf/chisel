# HANDOFF - Chisel / main

> Rewritten at the END of every sprint. The next sprint starts by reading this file,
> then LESSONS.md (STANDING RULES at minimum), then the relevant charter section, then
> KNOWN-DIVERGENCES.md - before doing anything else.

## Written by: repo bootstrap (no work sprints yet)

### Current state
- This is Chisel itself, not a port: nothing is ported here.

### NEXT TASK
Set up a port: from a fresh clone of Chisel, run `uv run tools/chisel-init.py` (a new port, or join
one). It turns the clone into the port's workbench, imports the original code, creates and links the
product repo, and replaces this file with the first sprint's handoff. Then run `uv run opencode` there
and type /port-sprint-start.

If /port-sprint-start runs in Chisel itself, stop and tell the human to run chisel-init first.
