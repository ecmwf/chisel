#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

# The permissions in each agent file (.opencode/agents/*.md) mean what AGENTS.md says the role may
# do. Each agent's rules follow opencode's base policy (allow everything) and are evaluated as
# opencode documents it: whole-value wildcards (* any characters, ? one), a shell pattern ending in
# " *" also matching the bare command, and the last matching rule winning. No agent merges, tags or
# merges a pull request by hand; only Ptah-Orchestrator pushes, never by force or to the base;
# Kha-Worker opens no pull request; no subagent starts another agent (a worker could otherwise start a
# review of its own work); port-review writes only its report and its scratch worktree; and
# Seshat-Integrator writes only port state and evidence. The guarded scripts, which run their own
# git, stay allowed for every agent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT/.opencode/agents" <<'PY'
import os, re, sys
import yaml

BASE = [{"action": "*", "resource": "*", "effect": "allow"}]


def wildcard(pattern, value):
    rx = "".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in pattern)
    return re.fullmatch(rx, value, re.S) is not None


def matches(pattern, value, action):
    if wildcard(pattern, value):
        return True
    return action == "shell" and pattern.endswith(" *") and wildcard(pattern[:-2], value)


def effect(rules, action, resource):
    result = "ask"
    for r in BASE + rules:
        if matches(r["action"], action, "") and matches(r["resource"], resource, action):
            result = r["effect"]
    return result


SCRIPT = "bash tools/coordination/integrate_product.sh u1"
COMMON = [
    ("shell", "git merge feature", "deny"),
    ("shell", "git merge", "deny"),
    ("shell", "git -C ../product merge --ff-only work/u1", "deny"),
    ("shell", "git merge-base HEAD origin/main", "allow"),
    ("shell", "gh pr merge 12", "deny"),
    ("shell", "git tag 1.0.0", "deny"),
    ("shell", "git -C ../product tag -a m1 -m m1", "deny"),
    ("shell", "git tag", "allow"),
    ("shell", "git tag -l phase0-signed", "allow"),
    ("shell", "git -C ../product tag --list", "allow"),
    ("shell", "git status --short", "allow"),
    ("shell", SCRIPT, "allow"),
    ("shell", "bash tools/coordination/finalize.sh --auto", "allow"),
]
CASES = {
    "ptah-orchestrator": COMMON + [
        ("shell", "git push origin main", "allow"),
        ("shell", "git push", "allow"),
        ("shell", "git push --force origin main", "deny"),
        ("shell", "git push origin main --force-with-lease", "deny"),
        ("shell", "git push origin main -f", "deny"),
        ("shell", "git push origin +main", "deny"),
        ("shell", "git push origin --delete old", "deny"),
        ("shell", "git push upstream contribute/x", "deny"),
        ("shell", "git -C ../product push --force origin main", "deny"),
        ("subagent", "kha-worker", "allow"),
        ("subagent", "port-review", "allow"),
        ("edit", "port/handoffs/main.md", "allow"),
    ],
    "kha-worker": COMMON + [
        ("shell", "git push origin work/u1", "deny"),
        ("shell", "git -C .worktrees/u1 push", "deny"),
        ("shell", "gh pr create --fill", "deny"),
        ("shell", "git commit -m 'feat: port u1'", "allow"),
        ("shell", "git rebase origin/main", "allow"),
        ("subagent", "port-review", "deny"),
        ("edit", "src/u1.c", "allow"),
    ],
    "port-review": COMMON + [
        ("shell", "git push", "deny"),
        ("shell", "git -C .worktrees/u1 commit -m 'docs: review u1'", "allow"),
        ("subagent", "kha-worker", "deny"),
        ("edit", ".worktrees/u1/docs/evidence/2026-01-01-review-u1/report.md", "allow"),
        ("edit", "/tmp/scratch-review-u1/src/u1.c", "allow"),
        ("edit", "src/u1.c", "deny"),
        ("edit", ".worktrees/u1/port/status/u1.yaml", "deny"),
    ],
    "seshat-integrator": COMMON + [
        ("shell", "git push origin main", "deny"),
        ("subagent", "kha-worker", "deny"),
        ("edit", "port/status/u1.yaml", "allow"),
        ("edit", "docs/evidence/epoch-1/summary.md", "allow"),
        ("edit", "src/u1.c", "deny"),
    ],
}

failures = 0
agents_dir = sys.argv[1]
found = sorted(f[:-3] for f in os.listdir(agents_dir) if f.endswith(".md"))
if found != sorted(CASES):
    print("not ok - every agent file has cases here (files: %s)" % ", ".join(found))
    failures += 1
for name, cases in sorted(CASES.items()):
    text = open(os.path.join(agents_dir, name + ".md"), encoding="utf-8").read()
    front = yaml.safe_load(text.split("---\n", 2)[1])
    rules = front.get("permissions") or []
    bad = [(a, r, want, effect(rules, a, r)) for a, r, want in cases if effect(rules, a, r) != want]
    if bad:
        failures += 1
        print("not ok - %s's permissions mean what its role allows" % name)
        for a, r, want, got in bad:
            print("    %s %r: expected %s, got %s" % (a, r, want, got))
    else:
        print("ok - %s's permissions mean what its role allows (%d cases)" % (name, len(cases)))
if failures:
    print("# test-agent-permissions: %d failure(s)" % failures, file=sys.stderr)
    sys.exit(1)
print("# test-agent-permissions: all assertions passed")
PY
