#!/usr/bin/env bash
#
# check-contributors.sh - fragment/claim identities resolve to DISTINCT registered humans.
#
# The status-fragment check (check-status-fragments.sh) enforces only SYNTACTIC independence:
# reviewer_id != author_id and reviewer_session not in author_sessions. It cannot tell one
# human wearing two ids apart, nor catch a reviewer working in the author's session. The
# contributor registry (port/contributors.yaml, template assets/contributors.template.yaml)
# names, per contributor id, the underlying HUMAN and the sessions they work in; this check
# resolves every fragment (and, with --claims-dir, claim) identity against it and fails if an
# id/session is unregistered or registered to the wrong contributor, or if a reviewed
# fragment's author and reviewer resolve to the SAME human (the aliasing/collusion gap).
#
# A thin wrapper over the verifier (tools/coordination/check_contributors.py). Before a
# registry exists (single-operator pilot) there is nothing to resolve against, so it skips -
# only the syntactic fragment check applies until a registry is adopted.
#
# Exit-code contract:
#   0  GREEN       every identity resolves, every review is between distinct humans (or no registry yet)
#   1  RED         an id/session is unregistered or mis-owned, or a review was not independent
#   2  UNRELIABLE  cannot run (no python3 / PyYAML / git / unreadable inputs)

set -uo pipefail

command -v python3 >/dev/null 2>&1 || { echo "check-contributors: python3 not found" >&2; exit 2; }
command -v git     >/dev/null 2>&1 || { echo "check-contributors: git not found" >&2; exit 2; }
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { echo "check-contributors: not inside a git repository" >&2; exit 2; }

exec python3 "$ROOT/tools/coordination/check_contributors.py" "$@"
