# Product README - documenting what the port produces

The product README is the one document a *consumer* of the ported software reads. A
consumer wants to build it, run it, and know what it does - they neither know nor care
that it began life as a port. This guide is how to write that README well; it is not a
generic README tutorial, because a fidelity port has documentation traps a normal
project does not. Read it when you first seed the README (Phase 1) and again when you
finalize it (at the product milestone / handover). Template:
`assets/PRODUCT-README.template.md`. Mechanical backstop:
`tools/conformance/check-product-readme.sh`.

## Audience and voice

Write for someone who will *use or build* the artifact, never for someone reading about
the project that made it. Consequences:

- **Describe the artifact, in the present tense.** "<product> computes the model's output
  fields for a given input." Not "we ported <original project> from <source language> to
  <target language>."
- **No first-person project narrative.** The README is about the software, not about how
  it was produced.
- **Copy-pasteable, not aspirational.** Every command in Build/Run/Test is one a fresh
  clone can actually execute today. If it cannot yet, the README is still a stub (see
  Lifecycle).

## The methodology-leak trap

The single failure specific to porting: leaking the *process* into a document that
should only describe the *product*. The consumer does not care that there was a SOURCE,
a charter, a TRACE, sprints, proofs, anchors, or reference runs - that vocabulary is
internal and its appearance is a leak.

- Keep all porting-process content out: charter, TRACE, reference/dump runs, proofs,
  probes, anchors, sprints, phases, fidelity, conformance, SOURCE/TARGET as roles.
- `check-product-readme.sh` (default mode, continuous) is the *mechanical* backstop for
  the known leak vocabulary. It is a denylist, not a judge of prose - treat a green run
  as "no known leak word", not "well written". Writing for the consumer is your job; the
  script only catches the obvious slips.

## Provenance is not a leak - credit the original, honestly

There is a subtle line. Crediting the upstream project is **required** (attribution and,
often, license obligation); describing the porting *process* is forbidden. They are not
the same thing.

- **Do** state what this is a reimplementation of, with a link: "<product> is a <target
  language> implementation of <original project> (link)." This is provenance and it
  belongs in the opening and the License section.
- **Do** honor the original project's license and any required notice.
- **Do not** describe *how* the reimplementation was produced - no protocol, phases,
  fidelity claims, or validation machinery. "A <target language> implementation of
  <original project> (link)" is provenance; "ported via a five-phase fidelity-preserving
  protocol with seeded-bug proofs" is a leak.

A useful test: provenance answers "what is this and where did it come from?"; a leak
answers "how was the porting project run?". The consumer asked the first question only.

## Tell the truth about what works

A port reaches usefulness incrementally, so the README must state, in consumer terms,
*what subset works today*.

- Derive the honest status from the internal `KNOWN-DIVERGENCES` file, but **translate
  it**: the consumer gets "supports configuration A (the common case); configuration B is
  not yet implemented", never an internal divergence ID, trap ID, or sprint reference.
- An honest, narrow "Status" beats an aspirational one. A consumer who hits an
  unsupported path because the README oversold it is worse off than one who was told the
  boundary up front.

## Section by section

The template (`assets/PRODUCT-README.template.md`) fixes the structure; fill it as
follows.

- **Name + one-liner.** What it does and who it is for, in one or two sentences.
- **Opening provenance line.** "A <target> implementation of <original> (link)."
- **Status.** The honest supported-subset, in consumer terms (above).
- **Build.** Exact, copy-pasteable commands a fresh clone runs, plus the toolchain and
  library requirements (versions). This is what `--require-filled` checks for.
- **Run.** An exact command on an example input, with a one-line description of inputs
  and outputs.
- **Test.** The self-testing-clone command; the suite ships with the code.
- **License.** This implementation's license, plus any notice the original project
  requires (the provenance duty, above).

## Lifecycle - a deliverable, not a one-time stub

The README is a reviewed deliverable that matures with the product, not a
fire-and-forget file:

- **At init (Phase 1):** seed it from the template and write what is already true - what
  it does, the provenance line. Leave Build/Run as honest placeholders; the product is
  not buildable yet.
- **As the product becomes buildable/usable:** finalize the exact Build/Run/Test
  commands and the Status, and keep them true at every product milestone.
- **Ownership:** it is owned and reviewed like the product's code. The integrator never
  hand-authors it at land time (an unreviewed author is a trap); it is written and
  reviewed as a deliverable. At the product-milestone / handover sign-off, `/port-digest`
  runs `check-product-readme.sh --require-filled`, which fails if the README is still an
  unwritten placeholder - so a milestone never seals with a README a consumer cannot use.

## Good and bad, side by side

Opening line:
- Good: "<product> is a <target language> implementation of <original project> (link). It
  computes the model's output fields from a given input profile."
- Bad: "This is the TARGET-side port of the <original project> SOURCE, produced over five
  phases with per-commit conformance proofs." (leak: TARGET/SOURCE/port/phases/conformance)

Status:
- Good: "Supports configuration A (the common case). Configuration B and feature C are
  not yet implemented."
- Bad: "All units pass R0-R4; KD-7 and KD-12 remain open." (leak: ladder tiers, internal
  divergence IDs)
