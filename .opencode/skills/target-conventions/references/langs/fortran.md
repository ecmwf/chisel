<!--
SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)

SPDX-License-Identifier: Apache-2.0
-->

# Fortran as a SOURCE language

Per-language guidance for *reading* Fortran as the SOURCE of truth: the gotchas that
make a line mean something other than it appears, and the things never to trust at
face value. This is a **language** file - it is about understanding Fortran, not about
rendering it. How a Fortran construct must be written in a given TARGET, and the trap
each gotcha below turns into, lives in that pair's rulebook (e.g. `../pairs/fortran-to-c.md`).

The rule behind every entry: a Fortran line does not carry its full meaning locally.
Type, precision, persistence, and storage are decided by defaults, declarations
elsewhere, build flags, and the parameter file - so reading one line is never enough.

## What a line does not tell you

- **Type is not local (implicit typing).** Without `IMPLICIT NONE`, an undeclared
  name is typed by its first letter (`I`-`N` integer, otherwise real). A "variable"
  may actually be an array or a statement function; a missing declaration silently
  changes a type. Build the explicit type list for any file lacking `IMPLICIT NONE`
  before trusting any line in it.
- **Precision is not local (default kinds).** A bare real literal `0.1` is default
  single precision; `0.1d0` is double. An intrinsic's result kind follows its
  argument's kind, so `log(0.99)` evaluates in single and then widens. Never read a
  literal's precision off the digits alone - read it off the context.
- **Persistence is not local (SAVE).** An initialized local (`integer :: n = 0`)
  implies `SAVE`: it is initialized once and keeps its value across calls. Module
  variables persist by nature. "It's a local, it resets each call" is false here.
- **Storage is not local (column-major, lower bounds).** Arrays are column-major,
  may have arbitrary lower bounds, and the first index varies fastest. A buffer may be
  reinterpreted at different shapes via `COMMON`/`EQUIVALENCE` or reshaped work
  arrays, so "same bytes, two names" is real and shape-dependent.
- **Mutability is a declaration, not an observation.** `parameter` means constant;
  a variable that merely *happens* not to be written in the live subset is still
  mutable state. Do not infer const-ness from observed non-mutation; the pair rulebook
  says how each case is rendered.

## What never to trust

- **Comments.** SOURCE comments lie - they drift from the code they annotate. They
  are ported as inherited, untrusted text and are never the basis for a rendering
  decision (failure mode B2). A comment that contradicts its code is defused on the
  spot and logged.
- **In-source defaults over the parameter file.** Configurable codes routinely
  override in-source initial values from a runtime parameter file (namelist). The
  effective value is the pinned configuration's value, not the literal in the
  declaration - confirm it against the charter's pinned configuration, never the
  source line.
- **The full distribution as the program.** Only the live subset of a configured
  build actually runs; large parts are dead in the pinned configuration. Liveness is
  determined by tooling (coverage, build-log, link-map), not by reading - and a
  declarations-only unit emits no coverage yet is live when referenced.
- **Compiler-independent behavior.** Zero-initialization of uninitialized variables,
  signed-integer overflow wrapping, floating-point reassociation, and the
  multiplication tree of `x**n` for a literal `n` (it follows the optimization level)
  are build/flag behaviors, not language guarantees. The
  reference build's flags are part of the specification; read them with the code.
- **Source form and continuation.** Fixed-form columns, continuation lines, and
  statement labels can make a logical statement span lines or hide in column 6.
  Read whole statements, not physical lines.

## How to read it safely

Read each unit with its declarations, the relevant module/`COMMON` definitions, the
reference build's flags, and the pinned parameter file open at the same time. When in
doubt about type, precision, persistence, or storage, resolve it from those sources
and record the resolved fact - never from the single line under translation.
