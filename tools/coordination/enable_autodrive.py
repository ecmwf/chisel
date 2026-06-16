#!/usr/bin/env python3
"""enable_autodrive - the auto-mode toggle: scaffold port/autodrive.yaml at a chosen level.

Orchestrator auto-mode (Ptah-Orchestrator driving the wave loop) is OFF until port/autodrive.yaml
exists with a level above L0. Hand-writing that file is the friction this removes: pick a level and
this writes a valid, commented config - one the auto-run integrity gate
(conformance/check-autodrive-integrity.sh) accepts BY CONSTRUCTION - then runs that gate so you see
the result immediately.

  L0  off / suggest-only          L1  plan-and-stop (the safe default: prints the plan, runs nothing)
  L2  auto within one phase       L3  full auto across phases (requires a charter-bot identity)

Raising the level is necessary but NOT sufficient. L2/L3 also need the coordination SUBSTRATE:
port/contributors.yaml (distinct worker/reviewer/bot identities), port/status/ fragments, and the
dependency map. This command writes ONLY the config; it then tells you exactly what else must exist
(and the integrity gate it runs will stay RED until it does - which is correct, not a bug here).

Usage:
  tools/coordination/enable_autodrive.py                       # enable L1 (plan-and-stop)
  tools/coordination/enable_autodrive.py --level L2 --max-waves 6 --max-wall-clock 4h
  tools/coordination/enable_autodrive.py --level L3 --charter-bot ci-bot --max-waves 8 --max-cost 50usd
  tools/coordination/enable_autodrive.py --level L1 --force    # overwrite an existing config
  tools/coordination/enable_autodrive.py --dry-run             # print what would be written

Exit: 0 written and (when checkable) integrity GREEN; 1 refused / invalid input; 2 written but
integrity not yet GREEN (e.g. L2/L3 before the substrate exists, or PyYAML missing to verify).
"""
import argparse
import os
import re
import subprocess
import sys

LEVELS = ("L0", "L1", "L2", "L3")
SCOPE_ACTIONS = ["claim", "work", "review", "rework", "mark-gated", "integrate"]
# `integrate` is deliberately left out of the default scope: it is the most consequential action
# (it lands code), so opt into hands-off integration explicitly. The merge keystroke stays
# human-/charter-gated regardless of scope.
DEFAULT_SCOPE = ["claim", "work", "review", "rework", "mark-gated"]


def _rank(lv):
    return LEVELS.index(lv) if lv in LEVELS else -1


def _repo_root():
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()


def _existing_level(path):
    """Cheap regex peek at an existing config's level (avoids a PyYAML dependency for the writer)."""
    try:
        with open(path, encoding="utf-8") as fh:
            for ln in fh:
                m = re.match(r"\s*level\s*:\s*([A-Za-z0-9]+)", ln)
                if m:
                    return m.group(1)
    except Exception:
        pass
    return "?"


def _qstr(v):
    return "null" if v in (None, "") else '"%s"' % v


def render(level, scope, max_waves, wall, cost, rework, charter_bot):
    scope_block = "\n".join("  - %s" % a for a in scope) if scope else "  []"
    return """\
# port/autodrive.yaml - the MACHINE-READABLE autonomy config for orchestrator auto-mode.
# Written by tools/coordination/enable_autodrive.py. The charter (port/plan/00-charter.md, the
# auto-mode section) explains it in prose; the auto-run integrity gate
# (conformance/check-autodrive-integrity.sh) checks THIS file. Raise the level only once the
# substrate exists (contributors.yaml with distinct identities, port/status/ fragments, the map).

schema_version: 1

# L0 off / suggest-only | L1 plan-and-stop | L2 auto within a phase | L3 full auto across phases.
level: %(level)s

# Actions the orchestrator may auto-perform; anything else is surfaced and pauses the loop (even at
# L3). Valid: claim, work, review, rework, mark-gated, integrate. (Add `integrate` for hands-off
# landing; the merge keystroke stays human-/charter-gated regardless.)
scope:
%(scope_block)s

budgets:
  max_waves: %(max_waves)d        # 0 = do not auto-run; L2/L3 require > 0
  max_wall_clock: %(wall)s   # e.g. "4h"; L2/L3 require this or max_cost
  max_cost: %(cost)s         # e.g. "50usd"
  max_rework: %(rework)d        # a piece that churns review more than this many times HALTS

# The registered contributor id the charter-bot signs its BOT_ATTESTATION.md as, at L3. MUST be
# distinct from every worker/reviewer/integrator identity (it signs; it never authors or reviews)
# and registered in port/contributors.yaml. Required at L3; null otherwise. A bot NEVER writes the
# human's SIGNOFF.md - the milestone tag still needs a human countersign.
charter_bot: %(charter_bot)s
""" % {
        "level": level,
        "scope_block": scope_block,
        "max_waves": max_waves,
        "wall": _qstr(wall),
        "cost": _qstr(cost),
        "rework": rework,
        "charter_bot": _qstr(charter_bot),
    }


def main():
    ap = argparse.ArgumentParser(add_help=True, description="Enable auto-mode by scaffolding port/autodrive.yaml.")
    ap.add_argument("--level", choices=LEVELS, default="L1", help="autonomy level (default L1: plan-and-stop)")
    ap.add_argument("--scope", default=None, help="comma-separated actions (default: %s)" % ",".join(DEFAULT_SCOPE))
    ap.add_argument("--charter-bot", default=None, help="registered contributor id that signs attestations (required at L3)")
    ap.add_argument("--max-waves", type=int, default=None, help="wave-count ceiling (L2/L3 require > 0; default 4 there, 0 below)")
    ap.add_argument("--max-wall-clock", default=None, help='wall-clock budget, e.g. "4h" (L2/L3 need this or --max-cost)')
    ap.add_argument("--max-cost", default=None, help='cost budget, e.g. "50usd"')
    ap.add_argument("--max-rework", type=int, default=2, help="rework-churn ceiling before HALT (default 2)")
    ap.add_argument("--force", action="store_true", help="overwrite an existing port/autodrive.yaml")
    ap.add_argument("--dry-run", action="store_true", help="print what would be written; change nothing")
    ap.add_argument("--no-verify", action="store_true", help="do not run check-autodrive-integrity after writing")
    args = ap.parse_args()

    root = _repo_root()
    target = os.path.join(root, "port", "autodrive.yaml")
    here = os.path.dirname(os.path.abspath(__file__))

    # Scope.
    if args.scope is not None:
        scope = [a.strip() for a in args.scope.split(",") if a.strip()]
    else:
        scope = list(DEFAULT_SCOPE)
    bad = [a for a in scope if a not in SCOPE_ACTIONS]
    if bad:
        sys.stderr.write("enable-autodrive: invalid scope action(s) %s - valid: %s\n"
                         % (", ".join(bad), ", ".join(SCOPE_ACTIONS)))
        sys.exit(1)

    # Budgets, defaulted so the integrity gate's config rules pass for the level.
    is_auto = _rank(args.level) >= _rank("L2")
    max_waves = args.max_waves if args.max_waves is not None else (4 if is_auto else 0)
    if max_waves < 0 or args.max_rework < 0:
        sys.stderr.write("enable-autodrive: budgets must be non-negative\n")
        sys.exit(1)
    wall, cost = args.max_wall_clock, args.max_cost
    if is_auto:
        if max_waves <= 0:
            sys.stderr.write("enable-autodrive: level %s needs --max-waves > 0 (it cannot auto-run otherwise)\n" % args.level)
            sys.exit(1)
        if not (wall or cost):
            wall = "4h"  # a bounded budget is mandatory at L2/L3; pick a safe default if none given
    charter_bot = args.charter_bot
    if args.level == "L3" and not charter_bot:
        sys.stderr.write("enable-autodrive: level L3 requires --charter-bot <id> (a registered contributor, "
                         "distinct from every author/reviewer, that signs attestations)\n")
        sys.exit(1)

    text = render(args.level, scope, max_waves, wall, cost, args.max_rework, charter_bot)

    rel = os.path.relpath(target, os.getcwd())
    if args.dry_run:
        print("[dry-run] would write %s:\n" % rel)
        print(text)
        return
    if os.path.isfile(target) and not args.force:
        sys.stderr.write("enable-autodrive: %s already exists (level %s). Edit it by hand, or re-run "
                         "with --force to overwrite.\n" % (rel, _existing_level(target)))
        sys.exit(1)

    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("enable-autodrive: wrote %s (level %s, scope=%s)" % (rel, args.level, ",".join(scope) or "[]"))

    # Tell the human what auto-mode still needs beyond this config.
    if args.level == "L0":
        print("  level L0 - auto-mode stays OFF (the orchestrator only suggests).")
    else:
        print("  next, for /port-autodrive to actually drive (not just HALT):")
        print("    - Phase 0/1 done: charter instantiated, port/TRACE.yaml populated, the dependency map built")
        print("    - port/status/ fragments per work item; refs/claims/* for live claims")
        if is_auto:
            print("    - port/contributors.yaml registering DISTINCT worker/reviewer%s identities (L2/L3 require it)"
                  % ("/charter-bot" if args.level == "L3" else ""))
        print("  then run /port-autodrive (or `/port-autodrive status` for a plan-only dry run).")

    if args.no_verify:
        return
    # Run the integrity gate so the result is visible now. A RED here for L2/L3 before the substrate
    # exists is EXPECTED (the config is valid; the registry/identity simply is not there yet).
    checker = os.path.join(here, "check_autodrive_integrity.py")
    if not os.path.isfile(checker):
        return
    print("\n  verifying with check-autodrive-integrity:")
    res = subprocess.run([sys.executable, checker], cwd=root)
    if res.returncode == 0:
        print("  -> integrity GREEN: the config verifies.")
        sys.exit(0)
    print("  -> integrity not GREEN yet (exit %d). For L1 this should be green; for L2/L3 it stays red "
          "until port/contributors.yaml and the substrate exist (expected)." % res.returncode)
    sys.exit(2)


if __name__ == "__main__":
    main()
