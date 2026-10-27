#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# Background agents run while Ptah-Orchestrator goes on, so the claim records which agent of a unit is
# running, and the planners never offer a running unit as work to start. thread_ledger.py `start`
# records the session and marks it running, `done` clears the mark, `--check` refuses a mark without a
# recorded thread. autodrive.py and phase1_drive.py report a running unit as `running`; when nothing
# else can start they say WAITING and exit 0, never STUCK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LEDGER="$ROOT/tools/coordination/thread_ledger.py"
PLAN="$ROOT/tools/coordination/autodrive.py"
P1="$ROOT/tools/coordination/phase1_drive.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failures=0
check() {
	local name="$1"; shift
	if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name" >&2; failures=$((failures + 1)); fi
}

# Phase 2: a is integrated; b and c use a and are claimed; d uses b.
W="$TMP/wb"
C="$W/port/claims"
mkdir -p "$C" "$W/tools/scoping" "$W/source"
git init -q "$W"
for u in a b c d; do printf '      x = 1\n' >"$W/source/$u.f90"; done
{
	echo "files:"
	echo "  - {id: a, source: source/a.f90, status: proven, integration: integrated}"
	for u in b c d; do echo "  - {id: $u, source: source/$u.f90, status: pending}"; done
} >"$W/port/TRACE.yaml"
{
	echo "schema_version: 1"
	echo "source_root: source/"
	echo "nodes:"
	for u in a b c d; do
		echo "  - {id: $u, source: $u.f90, role: unowned, self_serve_eligible: true, guarded_reasons: [], coverage: full, provides: []}"
	done
	echo "owned_surfaces: []"
	echo "edges:"
	for e in b:a c:a d:b; do echo "  - {from: ${e%%:*}, to: ${e#*:}, kind: call, confidence: proven}"; done
} >"$W/tools/scoping/dependency-map.yaml"
for u in b c; do printf 'id: %s\nclaimant: test\nstate: active\n' "$u" >"$C/$u.yaml"; done

ledger() { (cd "$W" && python3 "$LEDGER" "$@" --claims-dir "$C"); }
plan() { local rc=0; (cd "$W" && python3 "$PLAN" --claims-dir "$C") >"$TMP/plan.out" 2>&1 || rc=$?; echo "$rc"; }
action() { awk -v id="$1" '$2 == id {print $1}' "$TMP/plan.out" | head -1; }

ledger start b --role worker --session-id ses_workerb >/dev/null
check "start records the thread and marks it running" \
	python3 -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if c["running"] == "worker" and c["threads"]["worker"] == "ses_workerb" else 1)' "$C/b.yaml"
rc="$(plan)"
check "a running unit is reported running, not offered as work" [ "$(action b)" = running ]
check "a claimed unit with no running agent is work to start" [ "$(action c)" = work ]

ledger start c --role worker --session-id ses_workerc >/dev/null
rc="$(plan)"
check "with only running and blocked units, the planner waits (exit 0)" [ "$rc" = 0 ]
check "and says it is waiting, not stuck" grep -q '^WAITING: 2 agent(s) running' "$TMP/plan.out"

ledger done b >/dev/null
rc="$(plan)"
check "done clears the mark, so the unit is offered again" [ "$(action b)" = work ]
check "the thread stays recorded after done" \
	python3 -c 'import sys,yaml; c=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if "running" not in c and c["threads"]["worker"] == "ses_workerb" else 1)' "$C/b.yaml"

printf 'id: d\nclaimant: test\nstate: active\nrunning: reviewer\n' >"$C/d.yaml"
rc=0; ledger --check >/dev/null 2>&1 || rc=$?
check "a running mark without a recorded thread is refused" [ "$rc" = 1 ]
rm "$C/d.yaml"
check "the ledger is otherwise consistent" ledger --check

# Phase 1: the harness unit, claimed, with its worker running.
P="$TMP/p1"
mkdir -p "$P/port/claims"
git init -q "$P"
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
	git -C "$P" commit -q --allow-empty -m "phase 0" && git -C "$P" tag phase0-signed
printf 'schema_version: 1\nsource_signed: true\nunits:\n  - {id: harness, layer: 0, kind: harness}\n' >"$P/port/phase1-plan.yaml"
printf 'id: harness\nclaimant: test\nstate: active\nrunning: worker\nthreads: {worker: ses_harness}\n' >"$P/port/claims/harness.yaml"
rc=0; (cd "$P" && python3 "$P1" --claims-dir "$P/port/claims") >"$TMP/p1.out" 2>&1 || rc=$?
check "the Phase-1 planner reports a running unit as running" grep -q '^  running  harness' "$TMP/p1.out"
check "and waits for it (exit 0)" [ "$rc" = 0 ]

[ "$failures" -eq 0 ] || { echo "# test-running-agents: $failures failure(s)" >&2; exit 1; }
echo "# test-running-agents: all assertions passed"
