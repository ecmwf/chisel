#!/usr/bin/env python3
"""Verify the integrity of orchestrator AUTO-MODE: the autonomy config is well-formed, the
charter-bot is a distinct registered identity, and every auto-run ledger obeys the fail-closed
invariant. Without this gate, auto-mode's trust properties are only PROSE instructions to an LLM
agent (references/auto-mode.md); this makes the machine-checkable ones machine-checked.

It checks (fail closed):

  CONFIG     - port/autodrive.yaml is well-formed: schema_version 1, level in L0..L3, scope a list
               of valid actions, budgets present (max_waves/max_rework non-negative ints). For L2/L3
               a positive max_waves and a wall-clock or cost budget are required; for L3 a
               charter_bot is required.
  IDENTITY   - for L2/L3 the contributor registry (port/contributors.yaml) MUST exist; the
               charter_bot id (when set) resolves there and is a DIFFERENT human from every fragment
               author and reviewer - a bot that signs attestations must never be one that authored
               or reviewed (the independence auto-mode rests on).
  LEDGER     - every docs/evidence/autodrive/<run>/ledger.yaml is structured (run_id, level,
               decisions, verdict), its level does not exceed the config level, each decision names
               a valid action and a conformance_after verdict, and the FAIL-CLOSED INVARIANT holds:
               conformance_after is `green` for every decision except possibly the LAST, which may
               be non-green only when verdict is `halt`. A non-green verdict on any earlier decision
               means the run drove past a trust violation - the one thing auto-mode must never do.

Absent port/autodrive.yaml -> auto-mode is not configured (L0); nothing to check, skip. A present
ledger with no config, or a config the ledger violates, is RED.

Usage:  check_autodrive_integrity.py [--config FILE] [--registry FILE] [--status-dir DIR] [--ledgers DIR]
Exit:   0 integrity holds (or auto-mode not configured); 1 a violation; 2 UNRELIABLE (no PyYAML/git).
"""
import argparse
import glob
import os
import subprocess
import sys
import unicodedata
from typing import NoReturn

LEVELS = ("L0", "L1", "L2", "L3")
SCOPE_ACTIONS = {"claim", "work", "review", "rework", "mark-gated", "integrate"}
LEDGER_ACTIONS = SCOPE_ACTIONS | {"advance", "halt", "done"}


def _fail(msg) -> "NoReturn":
    sys.stderr.write("check-autodrive-integrity: " + msg + "\n")
    sys.exit(2)


def _repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def _strict_loader(yaml):
    class StrictLoader(yaml.SafeLoader):
        pass

    def no_dup(loader, node, deep=False):
        mapping = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node, deep=deep)
            if key in mapping:
                raise yaml.constructor.ConstructorError(
                    None, None, "duplicate key %r" % (key,), key_node.start_mark)
            mapping[key] = loader.construct_object(value_node, deep=deep)
        return mapping

    StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, no_dup)
    return StrictLoader


def _key(v):
    return unicodedata.normalize("NFC", str(v).strip()).casefold()


def _s(v):
    return "" if v is None else str(v).strip()


def _load(path, yaml, loader):
    with open(path, encoding="utf-8") as fh:
        return yaml.load(fh, Loader=loader)


def _level_rank(lv):
    return LEVELS.index(lv) if lv in LEVELS else -1


def check_config(cfg, fails):
    v = []
    if cfg.get("schema_version") != 1:
        v.append("schema_version must be 1")
    level = _s(cfg.get("level"))
    if level not in LEVELS:
        v.append("level '%s' must be one of %s" % (level, "/".join(LEVELS)))
    scope = cfg.get("scope")
    if scope is None:
        scope = []
    if not isinstance(scope, list):
        v.append("scope must be a list")
        scope = []
    for a in scope:
        if _s(a) not in SCOPE_ACTIONS:
            v.append("scope action '%s' is not one of %s" % (a, ", ".join(sorted(SCOPE_ACTIONS))))
    budgets = cfg.get("budgets")
    if not isinstance(budgets, dict):
        v.append("budgets must be a mapping (max_waves, max_rework, ...)")
        budgets = {}
    for b in ("max_waves", "max_rework"):
        bv = budgets.get(b)
        if not (type(bv) is int and bv >= 0):
            v.append("budgets.%s must be a non-negative integer" % b)
    if _level_rank(level) >= _level_rank("L2"):
        if not (type(budgets.get("max_waves")) is int and budgets.get("max_waves") > 0):
            v.append("level %s requires budgets.max_waves > 0 (it cannot auto-run otherwise)" % level)
        if not (_s(budgets.get("max_wall_clock")) or _s(budgets.get("max_cost"))):
            v.append("level %s requires a max_wall_clock or max_cost budget" % level)
    if level == "L3" and not _s(cfg.get("charter_bot")):
        v.append("level L3 requires a charter_bot id (the distinct identity that records attestations)")
    for msg in v:
        print("  [FAIL] config: %s" % msg)
    return fails + len(v), level


def _registry_humans(registry, yaml, loader):
    """{key(id) -> key(human)} or None if unreadable. Light - the full validation is check_contributors."""
    try:
        reg = _load(registry, yaml, loader)
    except Exception:
        return None
    if not isinstance(reg, dict) or not isinstance(reg.get("contributors"), list):
        return None
    out = {}
    for c in reg["contributors"]:
        if isinstance(c, dict) and _s(c.get("id")) and _s(c.get("human")):
            out[_key(c.get("id"))] = _key(c.get("human"))
    return out


def check_identity(cfg, level, registry, status_dir, yaml, loader, fails):
    if _level_rank(level) < _level_rank("L2"):
        return fails
    if not os.path.isfile(registry):
        print("  [FAIL] identity: level %s requires a contributor registry (%s), but it is absent"
              % (level, os.path.relpath(registry, os.getcwd())))
        return fails + 1
    humans = _registry_humans(registry, yaml, loader)
    if humans is None:
        print("  [FAIL] identity: contributor registry is unreadable/malformed")
        return fails + 1
    bot = _s(cfg.get("charter_bot"))
    if not bot:
        return fails  # L2 without a bot is allowed (no attestation authority claimed)
    if _key(bot) not in humans:
        print("  [FAIL] identity: charter_bot '%s' is not a registered contributor" % bot)
        return fails + 1
    bot_human = humans[_key(bot)]
    # The bot's human must differ from every fragment author/reviewer: it signs, it never authors.
    clash = []
    for p in sorted(glob.glob(os.path.join(status_dir, "*.yaml"))):
        if os.path.basename(p) == "_meta.yaml":
            continue
        try:
            frag = _load(p, yaml, loader)
        except Exception:
            continue
        if not isinstance(frag, dict):
            continue
        for role in ("author_id", "reviewer_id"):
            rid = _s(frag.get(role))
            if rid and _key(rid) in humans and humans[_key(rid)] == bot_human:
                clash.append("%s (%s)" % (rid, os.path.basename(p)))
    if clash:
        print("  [FAIL] identity: charter_bot '%s' is the same human as an author/reviewer: %s "
              "(a bot that signs attestations must never author or review)" % (bot, ", ".join(sorted(set(clash)))))
        return fails + 1
    return fails


def check_ledgers(ledgers_glob, cfg_level, yaml, loader, fails):
    paths = sorted(glob.glob(ledgers_glob))
    for p in paths:
        rel = os.path.relpath(p, os.getcwd())
        try:
            led = _load(p, yaml, loader)
        except Exception as exc:
            print("  [FAIL] %s: not valid YAML (%s)" % (rel, exc)); fails += 1; continue
        if not isinstance(led, dict):
            print("  [FAIL] %s: ledger is not a mapping" % rel); fails += 1; continue
        for f in ("run_id", "level", "decisions", "verdict"):
            if led.get(f) is None:
                print("  [FAIL] %s: missing '%s'" % (rel, f)); fails += 1
        lvl = _s(led.get("level"))
        if lvl and lvl not in LEVELS:
            print("  [FAIL] %s: level '%s' invalid" % (rel, lvl)); fails += 1
        elif lvl and _level_rank(lvl) > _level_rank(cfg_level):
            print("  [FAIL] %s: ledger level %s exceeds the configured level %s" % (rel, lvl, cfg_level)); fails += 1
        decisions = led.get("decisions")
        if not isinstance(decisions, list):
            print("  [FAIL] %s: decisions must be a list" % rel); fails += 1; continue
        n = len(decisions)
        for i, d in enumerate(decisions):
            if not isinstance(d, dict):
                print("  [FAIL] %s: decision %d is not a mapping" % (rel, i)); fails += 1; continue
            for f in ("at", "action", "unit", "rationale", "dispatched", "result", "conformance_after"):
                if d.get(f) is None or _s(d.get(f)) == "":
                    print("  [FAIL] %s: decision %d missing '%s'" % (rel, i, f)); fails += 1
            act = _s(d.get("action"))
            if act and act not in LEDGER_ACTIONS:
                print("  [FAIL] %s: decision %d action '%s' is not valid" % (rel, i, act)); fails += 1
            ca = _s(d.get("conformance_after")).lower()
            green = ca == "green"
            # FAIL-CLOSED: a non-green verdict may appear only on the LAST decision, and only when the
            # run halts. Anywhere earlier means the run drove past a trust violation.
            if not green:
                last = (i == n - 1)
                halted = _s(led.get("verdict")).lower().startswith("halt")
                if not (last and halted):
                    print("  [FAIL] %s: decision %d has conformance_after '%s' but the run did not HALT "
                          "there - auto-mode drove past a trust violation" % (rel, i, d.get("conformance_after")))
                    fails += 1
    return fails


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--config", default=None)
    ap.add_argument("--registry", default=None)
    ap.add_argument("--status-dir", default=None)
    ap.add_argument("--ledgers", default=None)
    args = ap.parse_args()

    orig = os.getcwd()
    root = _repo_root()
    try:
        os.chdir(root)
    except OSError:
        _fail("cannot enter repo root '%s'" % root)

    def resolve(p, default_rel):
        if p is None:
            return default_rel
        return p if os.path.isabs(p) else os.path.join(orig, p)

    config = resolve(args.config, os.path.join("port", "autodrive.yaml"))
    registry = resolve(args.registry, os.path.join("port", "contributors.yaml"))
    status_dir = resolve(args.status_dir, os.path.join("port", "status"))
    ledgers_glob = resolve(args.ledgers, os.path.join("docs", "evidence", "autodrive", "*", "ledger.yaml"))

    if not os.path.isfile(config):
        print("check-autodrive-integrity: no port/autodrive.yaml - auto-mode not configured (L0); "
              "nothing to check (skipping).")
        sys.exit(0)

    try:
        import yaml
    except Exception:
        _fail("PyYAML not available - cannot parse the autodrive config (install pyyaml)")
    loader = _strict_loader(yaml)

    try:
        cfg = _load(config, yaml, loader)
    except yaml.YAMLError as exc:
        _fail("port/autodrive.yaml is not valid YAML (%s)" % exc)
    if not isinstance(cfg, dict):
        _fail("port/autodrive.yaml is not a mapping")

    fails = 0
    fails, level = check_config(cfg, fails)
    if level not in LEVELS:
        level = "L0"
    fails = check_identity(cfg, level, registry, status_dir, yaml, loader, fails)
    fails = check_ledgers(ledgers_glob, level, yaml, loader, fails)

    print("check-autodrive-integrity: level %s; %d violation(s)." % (level, fails))
    if fails:
        print("RESULT: RED (exit 1) - the auto-mode config, identity, or a run ledger does not verify.")
        sys.exit(1)
    print("RESULT: GREEN (exit 0) - auto-mode config, charter-bot identity, and every run ledger verify.")
    sys.exit(0)


if __name__ == "__main__":
    main()
