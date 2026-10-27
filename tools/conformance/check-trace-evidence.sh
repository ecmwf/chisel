#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# check-trace-evidence.sh - TRACE-to-evidence integrity for review/proof metadata.
#
# The hard rule: a module is `proven` only with a proof (tier R1+) AND an independent review
# report, both RECORDED in docs/evidence/. TRACE points at those reports, but nothing
# verified the pointers resolve, so recollection ("it was reviewed") could outweigh the
# absence of a durable report. This makes the desync loud:
#   - every `proven` entry MUST cite a `proof` and a `review` whose paths exist on disk, and
#     that review must be CLEAN (a proven entry whose review verdict is VIOLATIONS is proven
#     by omission of the required clean re-review);
#   - an entry with a `proof` but status not `proven` is the review queue - it still owes a
#     clean review, whether `review` is null (never reviewed) or set to a violations
#     verdict (reviewed, not clean): listed, never failed;
#   - any cited `proof`/`review` path that does not resolve is a violation.
# A review exists iff its report exists here; handoff prose and memory never count.
#
# Scope: this is the CI BACKSTOP on a solo TRACE. Reviewer-session independence and the
# clean-verdict disposition are enforced at /port-review (the step that marks a unit proven); this check re-verifies
# that a proven entry records proof_tier R1+ and a proof_commit, cites a proof AND review report
# that EXIST on disk, and that the review is not a recorded-violations verdict.
#
# Exit-code contract: 0 = clean, 1 = integrity violation, 2 = could not run (no python3 or
# PyYAML, or a TRACE that cannot be read as a list of file entries).
#
# Seeded-bug record: tools/conformance/seeded-bugs/check-trace-evidence.md (the red/green
# demonstration of this check's comparison logic). Re-run and update it after ANY change to
# the parse/comparison logic (lib/trace_evidence.py) - the standing seeded-bug rule: a detector
# unseen to fail is unproven.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

TRACE="${TRACE_FILE:-port/TRACE.yaml}"
# Evidence durability (workbench-relative, under docs/evidence/, git-tracked) is enforced only on
# the REAL committed TRACE; a TRACE_FILE fixture exercises the parsing/verdict arms with throwaway
# evidence paths, so the durability arm is off there.
DURABLE_EVIDENCE=1; [ -n "${TRACE_FILE:-}" ] && DURABLE_EVIDENCE=0

[ -f "$TRACE" ] || { echo "check-trace-evidence: $TRACE not found; nothing to check (skipping)."; exit 0; }
command -v python3 >/dev/null 2>&1 \
  || { echo "check-trace-evidence: python3 not found - cannot read $TRACE (UNRELIABLE)" >&2; exit 2; }

# The rules run on the loaded TRACE data (lib/trace_evidence.py): each `files:` entry's own fields,
# read by name with the strict loader the TRACE generator and the drift check use. A TRACE that
# cannot be read as a list of file entries is UNRELIABLE (exit 2), never "nothing to check". Per
# entry:
#   - a proof field recorded under its old and its new name -> FAIL "records <field> more than once";
#   - a set proof/review path that does not exist -> FAIL;
#   - proven: proof and review set, proof_tier R1+, proof_commit set; with DURABLE_EVIDENCE, each
#     path under docs/evidence/, without '..', and git-tracked; the review report states an explicit
#     clean verdict and no violations verdict;
#   - not proven but a proof set -> listed in the review queue, never failed.
# A key repeated anywhere in the TRACE is RED (a field recorded more than once).
exec python3 tools/conformance/lib/trace_evidence.py "$TRACE" "$DURABLE_EVIDENCE"
