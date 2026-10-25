---
name: target-conventions
description: >
  TARGET-language conventions for fidelity-preserving ports: naming, comments, file
  layout, types, and the semantic trap table for the language pair. Use this skill
  whenever writing or reviewing TARGET code in a port, when instantiating the
  project's conventions file (port/conventions/<source>-to-<target>.md), when a rendering question
  arises ("how do we write this SOURCE construct in the TARGET language?"), or when
  adding support for a new TARGET language. Companion to the code-port skill: where
  code-port governs WHAT is translated and how it is validated, this skill governs
  HOW the translation is rendered, deterministically, so every sprint and every
  workstream renders the same SOURCE construct the same way.
---

# Target Conventions - deterministic rendering for ports

In a literal-translation port, a style guide is not "write idiomatic, beautiful
TARGET code." It exists to solve two problems specific to ports:

1. **Style drift across sprints and workstreams.** One sprint writes `mesh_ctx`,
   another writes `MeshContext`, and after fifty sprints the codebase is
   unreviewable. Every rendering decision must be made once, recorded, and applied
   mechanically forever after.
2. **Style as a disguise for improvement.** Idiomatic instincts (renaming things
   "properly", restructuring loops, modernizing patterns) are failure mode B1
   wearing a style costume. Conventions must channel the rendering, never license a
   change of structure or arithmetic.

## The governing principle: traceability beats beauty

During the port, the TARGET code must stay line-by-line mappable to the SOURCE. A
reviewer or a debugging sprint must be able to put `path/to/source_file:412` and
its TARGET rendering side by side and walk them in lockstep. Renderings that improve
readability at the cost of that mapping are wrong *during the port*. Idiomatic
modernization is a legitimate, separate project that runs after acceptance, under
the regression proof the port leaves behind.

## The enforcement rule

Every convention is enforced by a formatter, a linter, or a script in
`tools/conformance/` - or it is not a convention, it is a wish. Keep wishes near
zero. When a convention is violated repeatedly despite being written down, that is a
mechanization signal (see the code-port skill's self-improvement loop), not a
training signal.

## What every project must decide (the categories)

The project's decisions are instantiated into `port/conventions/<source>-to-<target>.md` (template in
`assets/CONVENTIONS.template.md`) during Phase 1, before translation starts, and are
frozen charter-style: changes require human sign-off.

### 1. Deterministic naming map
A *function* from SOURCE names to TARGET names - not taste. Define: case mapping,
module/namespace prefixing, sanitization of characters illegal in the TARGET,
collision resolution (e.g., a case-insensitive SOURCE colliding in a case-sensitive
TARGET). Default policy: **preserve SOURCE names** (sanitized, prefixed where
needed) for everything ported. Renaming is deferred to post-port modernization.

### 2. File mapping
How SOURCE files map to TARGET files (default: one-to-one, mirrored in
`port/TRACE.yaml`), directory structure, header/interface file policy.

### 3. Comment policy
Two kinds, never mixed:
- **Provenance comments**: every routine and every nontrivial constant carries its
  SOURCE anchor (file:line). This mechanizes the file:line citation directive into
  the code itself and is what makes side-by-side review possible.
- **Inherited comments**: SOURCE comments are ported but marked as inherited,
  untrusted text (comments lie - failure mode B2). Never write new comments that
  paraphrase what the SOURCE "means"; if the SOURCE needs explaining, that
  explanation belongs in the plan or the lessons file, with a citation.
- **No process-meta in TARGET comments**: no phase numbers, session IDs, agent or
  review references, no "temporary" or "added later" markers. Comments state
  intent and invariants of what exists, never authorship or edit history. The
  anchors and the inherited/contradiction markers are project vocabulary and are
  exempt; everything else about the process belongs in `port/`.

**Comments are verified, not trusted.** Comments lie, and a lying comment near a
constant has hidden a full-scale instability before. Three defenses, by
decreasing strength:
1. **Machine-checked anchors.** Constant anchors embed the literal as read
   (`= <literal>`), making the anchor the checkable middle term: a conformance
   script verifies the cited SOURCE line really contains that literal AND the
   TARGET line carries its agreed rendering. Both directions, every commit, in CI.
   This works because the SOURCE is pinned read-only: line numbers never drift.
2. **Contradiction marking.** When translation or debugging notices an inherited
   comment contradicting the code it annotates, the marker is upgraded to a
   contradiction marker on the spot and a LESSONS entry records it. The wrong
   comment is preserved (it is SOURCE text) but visibly defused for every later
   reader, human or agent.
3. **Phase-boundary comment audit.** At phase retrospectives, an agent pass reads
   each inherited comment against its code and classifies it: consistent,
   contradicts-code, or unverifiable. The output is a mismatch report for the
   human; the audit never certifies a comment as true (that would be failure mode
   B2 wearing a reviewer costume), it only flags provable mismatches.

### 4. The semantic trap table
The highest-value artifact: a per-language-pair list of constructs that compile
fine and silently mean something else. Each entry: SOURCE construct, the trap, the
mandatory TARGET rendering, and the failure it prevents. The trap table is
consulted during translation and enforced where scriptable. The trap table belongs
to the language *pair*: it lives in `references/pairs/<source>-to-<target>.md` (see
`references/pairs/fortran-to-c.md` for Fortran into C), separate from the per-language
files in `references/langs/`.

### 5. Types and precision
Explicit-width and explicit-precision types only; the literal-suffix policy; how
SOURCE precision kinds map to TARGET types. Precision is physics in numerical code:
a literal that changes width changes the answer.

### 6. Mechanical surface
The formatter configuration (zero-debate layout, applied in CI), the warning set
treated as errors, and the idioms for the charter's mechanical transformations:
the context-struct pattern for de-globalized state, the central index helpers,
allocation and error-handling patterns. One idiom per transformation, recorded with
an example, used everywhere.

## Instantiation workflow (Phase 1)

1. Copy `assets/CONVENTIONS.template.md` to `port/conventions/<source>-to-<target>.md`.
2. Decide every category with the human; record decisions and their enforcement
   mechanism (formatter rule, linter rule, or conformance script - name it).
3. Land the formatter config and the conformance scripts in the same change.
4. Human sign-off; thereafter changes follow the charter's exception discipline.
5. Every sprint that writes TARGET code reads `port/conventions/<source>-to-<target>.md` first; the
   trap table is open during translation, not consulted after the bug.
   **Before writing any TARGET code, also read the pair reference that file puts in force
   (`references/pairs/<source>-to-<target>.md`) in full** - the trap table AND its prose rules
   (mechanical-surface idioms, cross-unit calls and seams). The independent review checks every
   applicable trap row at every site, so a row the author never read becomes a review finding.

## How the references are organized: pairs and langs

References split by what depends on the language *pair* versus what depends on a
*single* language:

- `references/pairs/<source>-to-<target>.md` - the **pair rulebook**: everything about
  translating SOURCE into TARGET. The semantic trap table, the kind/precision mapping,
  the SOURCE-anchored comment policy and its verifier, "preserve SOURCE names", and the
  mechanical-surface idioms that exist because of the pair (de-globalization,
  storage-order/index helpers). If a rule mentions both languages, it is a pair rule.
- `references/langs/<language>.md` - **per-language** guidance for one language alone.
  For a TARGET language: standard pinning, the warning floor, formatter/linter,
  sanitizers, build-flag contract - how to write that language well and
  deterministically, independent of the SOURCE. For a SOURCE language: the reading
  gotchas and what never to trust when it is the specification.

The placement test: **a `langs/` file says nothing about translation.** Anything that
references the other language of the pair belongs in `pairs/`.

### Add a new pair (e.g. Fortran into Rust)

Create `references/pairs/<source>-to-<target>.md` following the structure of
`references/pairs/fortran-to-c.md`: naming, comment/anchor policy, kind/precision
mapping, mechanical-surface idioms, and above all the semantic trap table for that
pair (constructs that compile cleanly in the TARGET and silently mean something else).
A pair reference without a trap table is not ready to be used. Keep trap IDs stable
once published - conformance scripts, reviews, and LESSONS cite them.

Trap IDs are **pair-scoped**: each pair table numbers its own traps from T1, so a bare
`T6` is unambiguous only while a single pair exists. Once a second pair is added, a
citation from outside a pair file must name the pair (e.g. "fortran-to-c T6"), and
`check-references.sh` must be tightened to resolve an ID against the cited pair rather
than against any pair table.

### Add a new language (e.g. Rust as a TARGET)

Create `references/langs/<language>.md`: standard/edition pinning, the lint/format
toolchain, the deterministic build-flag contract, and the deliberately-skipped tools -
nothing about any SOURCE. Then the pair file references it for the language-only
baseline.

Every file-path and trap-ID citation across the skills, commands, conformance scripts,
and templates must resolve; `tools/conformance/check-references.sh` enforces this, so
update citations in the same change that moves or adds a reference.
