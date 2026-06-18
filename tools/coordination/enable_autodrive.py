#!/usr/bin/env python3
"""enable_autodrive - the auto-mode toggle: scaffold port/autodrive.yaml at a chosen level.

Orchestrator auto-mode (Ptah-Orchestrator driving the wave loop) is OFF until port/autodrive.yaml
exists with a level above L0. Hand-writing that file is the friction this removes: pick a level and
this writes a valid, commented config - one the auto-run integrity gate
(conformance/check-autodrive-integrity.sh) accepts BY CONSTRUCTION - then runs that gate so you see
the result immediately.

  L0  off / suggest-only          L1  plan-and-stop (the safe default: prints the plan, runs nothing)
  L2  auto within one phase       L3  full auto across phases (uses a default charter-bot identity)

Raising the level is necessary but NOT sufficient. L2/L3 also need the coordination SUBSTRATE:
port/contributors.yaml, port/status/ fragments, and the dependency map. To keep auto-mode hands-off,
at L2/L3 this ALSO scaffolds a READY port/contributors.yaml when absent: in auto-mode the contributors
are the distinct agents (worker, the independent reviewer on a different model, integrator, signing
bot) plus the operator's GitHub handle, so the registry is green as written - no form to fill. It then
tells you what else the substrate still needs (Phase 0/1 artifacts, status fragments, the map).

Usage:
  tools/coordination/enable_autodrive.py                       # enable L1 (plan-and-stop)
  tools/coordination/enable_autodrive.py --level L2 --max-waves 6 --max-wall-clock 4h
  tools/coordination/enable_autodrive.py --level L3            # charter-bot id + budgets all default
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
# The charter-bot's default id. It is a LABEL (the registered identity that signs attestations), not a
# decision the human should have to invent - so L3 defaults to it rather than demanding --charter-bot.
# Override only if you have a specific CI identity. It must stay distinct from every real contributor;
# the scaffolded registry registers it, and the integrity gate enforces the distinctness.
DEFAULT_CHARTER_BOT = "charter-bot"
SCOPE_ACTIONS = ["claim", "work", "review", "rework", "mark-gated", "integrate"]
# `integrate` IS in the default scope: auto-mode lands clean, independently-reviewed pieces
# hands-off. This is safe by construction rather than by withholding the action - the planner only
# ever recommends `integrate` for a piece that is gated, clean-reviewed, and has ALL proven deps
# integrated (autodrive.py); a piece with any unresolved or shared coupling is sent to triage, never
# auto-integrated. Integration stays SERIAL through the single integrator, conformance-gated, with a
# re-plan between, and the milestone tag + final acceptance still need the human's SIGNOFF (a bot
# never writes it). To keep the merge keystroke human-gated, drop `integrate` (--scope claim,work,review,rework,mark-gated).
DEFAULT_SCOPE = ["claim", "work", "review", "rework", "mark-gated", "integrate"]


def _rank(lv):
    return LEVELS.index(lv) if lv in LEVELS else -1


def _repo_root():
    # Anchor on THIS script's location, not the ambient cwd: the tool may be invoked from anywhere
    # (an agent shell often sits in the user's home), and a cwd-based `git rev-parse` would then resolve
    # to whatever repo encloses the cwd - e.g. a stray `.git` in ~ - making us write to ~/port. The
    # script lives at <root>/tools/coordination/, so `git -C <here>` finds the right repo (worktree
    # aware), and the fallback is the path math, never os.getcwd().
    here = os.path.dirname(os.path.abspath(__file__))
    try:
        return subprocess.check_output(["git", "-C", here, "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.path.dirname(os.path.dirname(here))


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


def render(level, scope, max_waves, wall, cost, in_flight, rework, charter_bot):
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
# L3). Valid: claim, work, review, rework, mark-gated, integrate. (`integrate` is included by default
# for hands-off landing of clean, reviewed pieces; drop it to keep the merge keystroke human-gated.)
scope:
%(scope_block)s

budgets:
  max_waves: %(max_waves)d        # 0 = do not auto-run; L2/L3 require > 0
  max_wall_clock: %(wall)s   # e.g. "24h"; L2/L3 require this or max_cost
  max_cost: %(cost)s         # e.g. "50usd"
  max_in_flight: %(in_flight)s      # CEILING on concurrent workers/reviewers per wave; null = no cap (fan out the ready-set, automatic); a number caps the ramp width
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
        "in_flight": "null" if in_flight is None else str(in_flight),
        "rework": rework,
        "charter_bot": _qstr(charter_bot),
    }


def _operator_handle():
    """The human operator's id for the registry: the GitHub handle (gh) if available, else git's
    configured user.name. None if neither is set."""
    for cmd in (["gh", "api", "user", "--jq", ".login"], ["git", "config", "user.name"]):
        try:
            out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, timeout=10).decode().strip()
            if out:
                return out
        except Exception:
            continue
    return None


def _yaml_id(v):
    """Emit an identity as a bare YAML scalar when it is a simple token, else a properly-escaped
    double-quoted scalar (backslash and quote escaped, so an odd name like DOMAIN\\user stays valid)."""
    s = str(v or "")
    if re.match(r"^[A-Za-z0-9._-]+$", s):
        return s
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def render_registry(charter_bot):
    """Ready-to-run contributor registry, scaffolded when port/contributors.yaml is absent at L2/L3.
    In auto-mode the contributors ARE distinct agents - a worker, an INDEPENDENT reviewer (a different
    model is the independence control), an integrator, and the charter-bot that signs - so it registers
    them as the distinct identities they already are, plus the operator's GitHub handle as the human
    who countersigns. No placeholders, no form to fill: the integrity gate is GREEN as written. Edit
    only to name real per-person handles for a multi-human team. Template + rules:
    .opencode/skill/code-port/assets/contributors.template.yaml."""
    bot = charter_bot or DEFAULT_CHARTER_BOT
    rows = [
        ("the charter-bot: signs attestations, never authors or reviews", bot),
        ("the porting worker agent (Kha-Worker)", "kha-worker"),
        ("the INDEPENDENT reviewer agent - a different model (port-review)", "port-review"),
        ("the integrator agent that lands reviewed pieces (Seshat)", "seshat-integrator"),
    ]
    human = _operator_handle()
    if human:
        rows.append(("you - the human operator who countersigns the milestone sign-off", human))
    blocks = "\n\n".join(
        "  # %s\n  - id: %s\n    human: %s\n    team: null\n    sessions: []"
        % (comment, _yaml_id(name), _yaml_id(name)) for comment, name in rows)
    return """\
# port/contributors.yaml - the contributor registry (project-layer): contributor ids/sessions mapped
# to DISTINCT identities, so author != reviewer != charter-bot is provable. SCAFFOLDED READY by
# enable_autodrive.py - in auto-mode the contributors are the distinct AGENTS (worker, independent
# reviewer on a different model, integrator, signing bot) plus your GitHub handle; the integrity gate
# is green as written. Edit only to name real per-person handles for a multi-human team. Template +
# rules: .opencode/skill/code-port/assets/contributors.template.yaml.

schema_version: 1

contributors:
%s
""" % blocks


def main():
    ap = argparse.ArgumentParser(add_help=True, description="Enable auto-mode by scaffolding port/autodrive.yaml.")
    ap.add_argument("--level", choices=LEVELS, default="L1", help="autonomy level (default L1: plan-and-stop)")
    ap.add_argument("--scope", default=None, help="comma-separated actions (default: %s)" % ",".join(DEFAULT_SCOPE))
    ap.add_argument("--charter-bot", default=None, help="contributor id that signs attestations at L3 (default: %s; override only for a specific CI identity)" % DEFAULT_CHARTER_BOT)
    ap.add_argument("--max-waves", type=int, default=None, help="wave-count ceiling (L2/L3 require > 0; default 30 there, 0 below)")
    ap.add_argument("--max-wall-clock", default=None, help='wall-clock budget, e.g. "24h" (L2/L3 need this or --max-cost; default 24h)')
    ap.add_argument("--max-cost", default=None, help='cost budget, e.g. "50usd"')
    ap.add_argument("--max-in-flight", type=int, default=None, help="cap on workers/reviewers dispatched concurrently per wave; default null = no cap (fan out the ready-set); a number caps the ramp width")
    ap.add_argument("--max-rework", type=int, default=10, help="rework-churn ceiling before HALT (default 10)")
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
    max_waves = args.max_waves if args.max_waves is not None else (30 if is_auto else 0)
    if max_waves < 0 or args.max_rework < 0:
        sys.stderr.write("enable-autodrive: budgets must be non-negative\n")
        sys.exit(1)
    if args.max_in_flight is not None and args.max_in_flight < 1:
        sys.stderr.write("enable-autodrive: --max-in-flight must be >= 1 (a concurrency cap); omit it for no cap\n")
        sys.exit(1)
    wall, cost = args.max_wall_clock, args.max_cost
    if is_auto:
        if max_waves <= 0:
            sys.stderr.write("enable-autodrive: level %s needs --max-waves > 0 (it cannot auto-run otherwise)\n" % args.level)
            sys.exit(1)
        if not (wall or cost):
            wall = "24h"  # a bounded budget is mandatory at L2/L3; pick a safe default if none given
    charter_bot = args.charter_bot
    charter_bot_defaulted = False
    if args.level == "L3" and not charter_bot:
        # A bot id is a label, not a human decision: default it and PROCEED (the human only has to
        # fill the distinct identities, which separation of powers genuinely requires).
        charter_bot = DEFAULT_CHARTER_BOT
        charter_bot_defaulted = True

    text = render(args.level, scope, max_waves, wall, cost, args.max_in_flight, args.max_rework, charter_bot)

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
    if charter_bot_defaulted:
        print("  charter-bot id defaulted to '%s' (a label, not a decision; override with "
              "--charter-bot <id> only for a specific CI identity)." % charter_bot)

    # Tell the human what auto-mode still needs beyond this config.
    if args.level == "L0":
        print("  level L0 - auto-mode stays OFF (the orchestrator only suggests).")
    else:
        print("  next, for /port-autodrive to actually drive (not just HALT):")
        print("    - Phase 0/1 done: charter instantiated, port/TRACE.yaml populated, the dependency map built")
        print("    - port/status/ fragments per work item; refs/claims/* for live claims")
        print("  then run /port-autodrive (or `/port-autodrive status` for a plan-only dry run).")

    # At L2/L3, also scaffold a READY contributor registry (the substrate the integrity gate needs)
    # when absent: in auto-mode the contributors are the distinct agents plus the operator's handle, so
    # it is green as written - no form to fill. NEVER clobber an existing registry.
    if is_auto:
        reg_path = os.path.join(root, "port", "contributors.yaml")
        reg_rel = os.path.relpath(reg_path, os.getcwd())
        if os.path.exists(reg_path):
            print("  port/contributors.yaml exists - left as is.")
        else:
            os.makedirs(os.path.dirname(reg_path), exist_ok=True)
            with open(reg_path, "w", encoding="utf-8") as fh:
                fh.write(render_registry(charter_bot))
            print("  scaffolded %s with the distinct agent identities (+ your handle) - the integrity "
                  "gate is green as written; edit only to name real per-person handles for a team." % reg_rel)

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
