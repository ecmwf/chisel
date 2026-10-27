#!/usr/bin/env python3

# SPDX-FileCopyrightText: 2026 European Centre for Medium-Range Weather Forecasts (ECMWF)
#
# SPDX-License-Identifier: Apache-2.0

"""chisel-init - set up a port the right way, interactively.

Two situations it handles:
  * NEW                - you are starting a port. This clone of Chisel becomes your workbench (where
                         the port's state and lessons live): Chisel becomes `upstream`, your new
                         repo `origin`, the layer merge drivers are set, and main is pushed. It
                         imports the original code into source/<name>, pinned to one commit, and
                         creates the separate product repo for the translated code, cloned beside
                         the workbench and linked from port/product.yaml.
  * JOIN               - someone already started the port (its workbench is an existing repo).
                         This clones that workbench for you and wires `upstream` -> Chisel plus
                         the merge drivers, so you can sync Chisel's improvements while you work.

In both, it reads opencode's model list (`opencode api get /api/model`, opencode 2) and sets each
agent's model and reasoning effort in the workbench's own opencode.json, as
`"agents": {"kha-worker": {"model": "provider/model#effort"}}` (the agents carry no model in their
base-owned frontmatter, so a /port-sync-with-base never overrides the choice). The defaults are the
newest available model of a family: Kha-Worker -> Claude Sonnet (capable and lower-cost, for the
many parallel workers); Ptah-Orchestrator and Seshat-Integrator -> Claude Opus; port-review -> GPT
Sol (a reviewer model distinct from the worker it reviews is a stronger independence control than a
different session alone). The effort defaults to `high` for every role and must be one the chosen
model offers (opencode rejects any other); raise it with --effort or --model ROLE=...#xhigh.

It reports each step and asks before it clones, creates or pushes anything. Running it again is
safe: it continues what is not done yet and skips what is. Nothing is committed: the first
/port-sprint-start commits and pushes the setup.

Examples:
  uv run tools/chisel-init.py                  # asks for everything, from a clone of Chisel
  uv run tools/chisel-init.py --dry-run        # shows every step, changes nothing
  uv run tools/chisel-init.py --mode new --new-repo me/port-foo --source-repo URL --source-ref TAG
  uv run tools/chisel-init.py --mode join --existing-repo URL --dir ../port-foo
"""
import argparse
import json
import os
import re
import shlex
import shutil
import string
import subprocess
import sys
import urllib.parse

# The four agents: their id, their name, and the model family each defaults to - its newest model in
# opencode's model catalog, so the defaults follow new releases with no edit here. The many parallel
# workers get a capable, lower-cost family; the reviewer a different vendor's, since a reviewer model
# distinct from the worker it reviews is a stronger independence control than a session alone.
ROLES = [  # (id, name, provider, family, the family's name)
    ("kha-worker", "Kha-Worker", "anthropic", "claude-sonnet", "Claude Sonnet"),
    ("ptah-orchestrator", "Ptah-Orchestrator", "anthropic", "claude-opus", "Claude Opus"),
    ("seshat-integrator", "Seshat-Integrator", "anthropic", "claude-opus", "Claude Opus"),
    ("port-review", "port-review", "openai", "gpt-sol", "GPT Sol"),
]
ROLE = {r[0]: r for r in ROLES}
# The default reasoning effort, written as the model's opencode variant (`provider/model#high`).
# `high` is a strong standard level, not the most expensive (`xhigh`, `max`), which --effort or
# --model ROLE=...#effort opts into. The proof ladder and the independent review remain the real
# backstop, not raw model effort.
DEFAULT_EFFORT = "high"
_model_flags = {}  # --model ROLE=provider/model[#effort], parsed in main(): {role: (model, effort or None)}
_opts = argparse.Namespace()  # the parsed args; the real value is installed in main()


def _color():
    if os.environ.get("NO_COLOR") or not sys.stdout.isatty():
        return {k: "" for k in ("g", "y", "r", "b", "d", "0")}
    return {"g": "\033[32m", "y": "\033[33m", "r": "\033[31m", "b": "\033[1m", "d": "\033[2m", "0": "\033[0m"}


C = _color()

BANNER = r"""
     ____  _   _  ___  ____   _____  _
    / ___|| | | ||_ _|/ ___| | ____|| |
   | |    | |_| | | | \___ \ |  _|  | |
   | |___ |  _  | | |  ___) || |___ | |___
    \____||_| |_||___||____/ |_____||_____|
   01  carve, validate, never trust - one proven cut  10
"""


def banner():
    print((C["b"] + BANNER.rstrip("\n") + C["0"]) if C["b"] else BANNER.rstrip("\n"))


def section(t):
    print("\n%s== %s ==%s" % (C["b"], t, C["0"]))


def ok(m):
    print("  %s+%s %s" % (C["g"], C["0"], m))


def warn(m):
    print("  %s!%s %s" % (C["y"], C["0"], m))


def info(m):
    print("  %s->%s %s" % (C["d"], C["0"], m))


def die(m):
    print("  %sx%s %s" % (C["r"], C["0"], m), file=sys.stderr)
    sys.exit(2)


def _interactive():
    return not _opts.non_interactive and sys.stdin.isatty()


def ask(prompt, default=None, required=False):
    if not _interactive():
        if default is not None:
            return default
        if required:
            die("non-interactive: missing a required value for: %s" % prompt)
        return ""
    suffix = " [%s]" % default if default not in (None, "") else ""
    while True:
        val = input("  %s?%s %s%s: " % (C["y"], C["0"], prompt, suffix)).strip()
        if val:
            return val
        if default is not None:
            return default
        if not required:
            return ""


def confirm(prompt, default=True, changes=False):
    """Ask a yes/no question. Without a terminal, --yes answers yes; a question about a change (a
    push, a clone, a new repo) then needs --yes and stops init without it, while any other takes its
    default. A dry run changes nothing, so it never stops."""
    if _opts.yes or not _interactive():
        if _opts.yes or _opts.dry_run or not changes:
            return True if _opts.yes else default
        die("%s - without a terminal, pass --yes to confirm changes" % prompt)
    d = "Y/n" if default else "y/N"
    val = input("  %s?%s %s [%s]: " % (C["y"], C["0"], prompt, d)).strip().lower()
    if not val:
        return default
    return val[0] == "y"


def resolve_valid(flagval, prompt, validate, default=None, required=False, flagname="value"):
    """Resolve a value from a CLI flag or by prompting, where validate(value) returns an error
    string or None. A flag value is checked once and DIES on failure (a bad flag in an automated run
    must fail fast, never loop); a PROMPTED value RE-PROMPTS on invalid input when interactive, and
    dies when non-interactive. flagval is None to mean 'not supplied - prompt for it'."""
    if flagval is not None:
        err = validate(flagval)
        if err is not None:
            die("%s: %s" % (flagname, err))
        return flagval
    while True:
        value = ask(prompt, default=default, required=required)
        err = validate(value)
        if err is None:
            return value
        if not _interactive():
            die(err)
        warn(err + "  Try again.")


def run(cmd, cwd=None, check=True, env=None):
    """Run a command that changes something, showing it first; in --dry-run, only show it. `env`
    (when given) is merged onto the inherited environment for this one call."""
    here = cwd is None or os.path.abspath(cwd) == os.getcwd()
    shown = shlex.join(cmd) + ("" if here else " (in %s)" % cwd)
    if _opts.dry_run:
        print("  %s[dry-run]%s would run: %s" % (C["d"], C["0"], shown))
        return subprocess.CompletedProcess(cmd, 0, "", "")
    info("run: %s" % shown)
    res = subprocess.run(cmd, cwd=cwd, text=True, env={**os.environ, **env} if env else None)
    if check and res.returncode != 0:
        die("command failed (%d): %s" % (res.returncode, shown))
    return res


def _gh_ready():
    """True if gh is installed AND authenticated - i.e. it can clone PRIVATE GitHub repos."""
    if not shutil.which("gh"):
        return False
    try:
        return subprocess.run(["gh", "auth", "status"], capture_output=True).returncode == 0
    except Exception:
        return False


def normalize_source_url(src):
    """Turn a pasted forge WEB URL into a cloneable git URL and recover any ref embedded in it.
    A browser URL like https://github.com/owner/repo/tree/main is NOT a clone URL (git wants
    https://github.com/owner/repo[.git]); the /tree/<ref>, /blob/<ref>/..., /-/tree/<ref> (GitLab),
    /src/<ref> (Bitbucket), /commit/<sha>, /releases/tag/<tag> parts are web navigation that make
    `git clone` fail and also poison the default source/<name> (it becomes the branch, e.g. 'main').
    Returns (clean_url, ref_or_None). SSH URLs (git@...), local paths, and already-clean HTTP(S)
    URLs are returned unchanged with ref None."""
    s = (src or "").strip()
    if not re.match(r"^https?://", s):
        return s, None                                  # SSH / scp-like / local path - leave alone
    body = re.split(r"[?#]", s, maxsplit=1)[0]          # drop ?query / #fragment
    m = (re.search(r"/(?:-/)?(?:tree|blob|commit|commits|raw|src)/([^/]+)", body)
         or re.search(r"/(?:-/)?(?:tags|releases/tag)/([^/]+)", body))
    if not m:
        return s, None                                  # already a clone URL (no web marker)
    base = body[:m.start()].rstrip("/")
    if not re.match(r"^https?://[^/]+/[^/]+/[^/]+", base):
        return s, None                                  # guard: only if host/owner/repo survives
    if not base.endswith(".git"):
        base += ".git"
    return base, m.group(1)


def robust_clone(url, dest, cwd=None):
    """Clone `url` without ever blocking on an interactive credential prompt. A PRIVATE GitHub repo
    over HTTPS would otherwise hang on 'Username for https://github.com'; so for an HTTPS github URL
    we prefer `gh repo clone` when gh is authenticated (it carries the token and clones private
    repos), and otherwise run `git clone` with GIT_TERMINAL_PROMPT=0 so it FAILS FAST with an
    actionable message instead of hanging. SSH URLs and local paths clone directly."""
    # Only an HTTPS GitHub URL can prompt for a password; an SSH one authenticates with the user's keys.
    slug = _github_slug(url) if (url or "").startswith("https://") else None
    if slug and _gh_ready():
        run(["gh", "repo", "clone", slug, dest], cwd=cwd)
        return
    res = run(["git", "clone", url, dest], cwd=cwd, check=False, env={"GIT_TERMINAL_PROMPT": "0"})
    if res.returncode == 0:
        return
    if slug:
        die("could not clone %s - a private GitHub repo cannot be cloned over HTTPS without "
            "credentials, and the interactive prompt is disabled so init never hangs. Either:\n"
            "       - use the SSH URL:  git@github.com:%s.git\n"
            "       - or run `gh auth login` (gh is then used automatically), then re-run\n"
            "       - or configure a git credential helper for github.com, then re-run" % (url, slug))
    die("could not clone %s (git exit %d) - check the URL and your access "
        "(SSH key / credential helper / token)." % (url, res.returncode))


# ---- preflight + state -------------------------------------------------------------------

def preflight():
    section("Tools")
    need = {"git": True, "python3": True, "opencode": False, "gh": False}
    for tool, hard in need.items():
        path = shutil.which(tool)
        if path:
            ver = ""
            try:
                ver = subprocess.run([tool, "--version"], capture_output=True, text=True, timeout=10).stdout.splitlines()[0]
            except Exception:
                pass
            ok("%-8s %s" % (tool, ver))
        elif hard:
            die("%-8s MISSING (required)" % tool)
        elif tool == "gh":
            warn("gh       not found - only needed to create GitHub repos by name; git URLs work without it")
        else:
            warn("opencode not found - needed to choose the agents' models: install opencode 2")
    try:
        import yaml  # noqa: F401
        ok("PyYAML   present")
    except Exception:
        warn("PyYAML   missing - run `uv run tools/chisel-init.py`, which installs it")


def git(*a, cwd=None):
    try:
        r = subprocess.run(["git", *a], cwd=cwd, capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def _base_pointer(top):
    """Chisel's URL as recorded in <top>/tools/base-repo.txt (its first line that is not a comment),
    or "" when there is none."""
    bf = os.path.join(top, "tools", "base-repo.txt")
    if os.path.isfile(bf):
        for ln in open(bf, encoding="utf-8"):
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                return ln
    return ""


def detect_state():
    section("This clone")
    top = git("rev-parse", "--show-toplevel")
    if not top:
        die("not inside a git repository - clone Chisel first, then run this from it")
    is_chisel = os.path.isfile(os.path.join(top, ".opencode/skill/code-port/SKILL.md"))
    origin = git("remote", "get-url", "origin", cwd=top)
    upstream = git("remote", "get-url", "upstream", cwd=top)
    base_file = _base_pointer(top)
    ok("folder   %s" % top)
    ok("origin   %s" % (origin or "(none)"))
    if upstream:
        ok("upstream %s" % upstream)
    if base_file:
        ok("Chisel   %s (tools/base-repo.txt)" % base_file)
    else:
        warn("tools/base-repo.txt is missing: cannot tell where Chisel lives")
    if not is_chisel:
        warn("this does not look like a clone of Chisel (.opencode/skill/code-port/SKILL.md is missing)")
    return {"top": top, "is_chisel": is_chisel, "origin": origin, "upstream": upstream, "base": base_file}


def _repo_slug(u):
    """The 'owner/name' a repo ref points at - comparing a gh name and a git URL alike
    (git@github.com:o/n.git, https://github.com/o/n, and o/n all map to 'o/n')."""
    s = re.sub(r"\.git/?$", "", (u or "").strip().rstrip("/"))
    parts = re.split(r"[/:]", s)
    return ("/".join(parts[-2:])).lower() if len(parts) >= 2 else s.lower()


def _same_repo(a, b):
    return bool(a) and bool(b) and _repo_slug(a) == _repo_slug(b)


def _github_slug(u):
    """'owner/name' when `u` names a GitHub repo (SSH, scp-like, or HTTPS URL), else None."""
    m = re.match(r"^(?:https?://(?:[^@/\s]+@)?github\.com/|(?:ssh://)?git@github\.com[:/])"
                 r"([^/\s]+/[^/\s]+?)(?:\.git)?/?$", (u or "").strip())
    return m.group(1) if m else None


def _gh_canonical(u):
    """GitHub's current 'owner/name' for the repo `u` names, lower-cased, following the redirects
    GitHub keeps after a rename or transfer - or None when it cannot be asked (not a GitHub URL, gh
    absent or unauthenticated, offline, no access). Best effort: a None never decides anything."""
    slug = _github_slug(u)
    if not slug or shutil.which("gh") is None:
        return None
    try:
        r = subprocess.run(["gh", "repo", "view", slug, "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                           capture_output=True, text=True, timeout=30)
    except Exception:
        return None
    name = r.stdout.strip()
    return name.lower() if r.returncode == 0 and "/" in name else None


def _is_base_clone(state):
    """True when this clone IS the base (so a new port must flip it), False when it is already an
    instance. A flipped instance has an `upstream` remote. Without one, the clone is the base when its
    origin names the recorded base repo - compared as owner/name, so SSH vs HTTPS, letter case, and a
    trailing .git do not matter; and if those still differ, as GitHub resolves them, so a base that
    was renamed or transferred is recognized under either name (a clone made from its old URL, or a
    tools/base-repo.txt written before the move). A raw URL-string comparison would misread a fresh
    HTTPS clone of an SSH-recorded base as an instance and then set the port up inside the base clone."""
    if state["upstream"]:
        return False
    origin, base = state["origin"], state["base"]
    if not origin or not base or _same_repo(origin, base):
        return True
    canon_base = _gh_canonical(base)
    canon = _gh_canonical(origin)
    if canon is not None and canon == canon_base:
        return True
    # The origin is not the recorded base. A clone holding a port's own state is a workbench (even
    # one made as a fork); a GitHub fork of the base without one is a copy of Chisel. Anything else -
    # a mirror of Chisel, or a workbench whose first sprint has not run - looks the same from here,
    # so the user says which.
    if _has_port_state(state["top"]):
        return False
    if canon_base is not None and _gh_fork_parent(origin) == canon_base:
        info("origin %s is a fork of Chisel (%s) - setting up a new port from it" % (origin, base))
        return True
    return _ask_copy_or_workbench(origin, base)


def _gh_fork_parent(u):
    """The lower-cased 'owner/name' of the repo `u` was forked from on GitHub, or None (not a fork,
    not a GitHub URL, or gh cannot be asked)."""
    slug = _github_slug(u)
    if not slug or shutil.which("gh") is None:
        return None
    try:
        r = subprocess.run(["gh", "repo", "view", slug, "--json", "isFork,parent", "-q",
                            'if .isFork then .parent.owner.login + "/" + .parent.name else "" end'],
                           capture_output=True, text=True, timeout=30)
    except Exception:
        return None
    name = r.stdout.strip()
    return name.lower() if r.returncode == 0 and "/" in name else None


def _has_port_state(top):
    """True when the clone holds a port's own state, which Chisel itself never has: a linked product,
    a provenance record, or original code imported under source/."""
    if os.path.isfile(os.path.join(top, "port", "product.yaml")):
        return True
    prov = os.path.join(top, "port", "provenance")
    if os.path.isdir(prov) and any(n.endswith(".yaml") for n in os.listdir(prov)):
        return True
    src = os.path.join(top, "source")
    return os.path.isdir(src) and any(os.path.isdir(os.path.join(src, n)) and not n.startswith(".")
                                      for n in os.listdir(src))


def _ask_copy_or_workbench(origin, base):
    """Ask whether a clone that is neither recognizably Chisel nor a workbench is a copy of Chisel
    (True: set up a new port) or an existing port's workbench (False: resume its setup). Without a
    terminal, --new-repo answers: it asks for a new port."""
    if not _interactive():
        if _opts.new_repo:
            info("origin %s is not Chisel's recorded home %s; --new-repo given, so treating this "
                 "clone as a copy of Chisel" % (origin, base))
            return True
        die("cannot tell what this clone is: its origin %s is not Chisel's recorded home %s, and it "
            "holds no port yet.\n     A copy of Chisel (a fork or a mirror): pass --new-repo to set up "
            "a new port from it.\n     A port's workbench whose first sprint has not run: add Chisel as "
            "its upstream (git remote add upstream %s), then re-run." % (origin, base, base))
    print("\n  This clone's origin, %s, is not Chisel's recorded home (%s), and it holds no port yet." % (origin, base))
    print("    1) it is a copy of Chisel (a fork or a mirror): set up a new port from it")
    print("    2) it is a port's workbench whose first sprint has not run: resume its setup")
    while True:
        sel = input("  choose [1/2]: ").strip()
        if sel in ("1", "2"):
            return sel == "1"
        warn("enter 1 or 2.")


# ---- models ------------------------------------------------------------------------------

def list_models(top):
    """opencode's model catalog for the workbench at `top`, as {"provider/model": entry}, or None
    when opencode cannot be asked. An entry carries the model's family, release time and variants
    (its reasoning efforts). Deprecated and disabled models are left out."""
    if shutil.which("opencode") is None:
        return None
    where = os.path.abspath(top) if os.path.isdir(top) else os.getcwd()  # a dry run clones nothing
    query = urllib.parse.urlencode({"location[directory]": where})
    try:
        r = subprocess.run(["opencode", "api", "get", "/api/model?" + query],
                           capture_output=True, text=True, timeout=60)
        data = json.loads(r.stdout)["data"]
        return {"%s/%s" % (m["providerID"], m["id"]): m for m in data
                if m.get("enabled", True) and m.get("status") != "deprecated"}
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, AttributeError):
        return None


def recommended(avail, role):
    """The role's default model: the newest available one of its family; of models released
    together (a model and its -fast twin), the plainest id. None when the family is not here."""
    _id, _name, provider, family, _family_name = ROLE[role]
    fam = [mid for mid, m in avail.items() if m.get("providerID") == provider and m.get("family") == family]
    if not fam:
        return None
    return max(fam, key=lambda mid: ((avail[mid].get("time") or {}).get("released") or 0, -len(mid)))


def efforts_of(entry):
    """The reasoning efforts a model offers: the ids of its catalog variants."""
    return [v["id"] for v in (entry or {}).get("variants") or [] if isinstance(v, dict) and v.get("id")]


def pick_model(avail, provider):
    """Two-step drill-down: choose a PROVIDER, then a model within it. `provider` is the role's
    recommended provider, offered as the default. Returns a model id, or None to skip (inherit
    the global default). Only called interactively."""
    providers = sorted({m.split("/", 1)[0] for m in avail})
    while True:
        print("    available providers:")
        for i, p in enumerate(providers, 1):
            print("      %2d) %s%s" % (i, p, "  (recommended)" if p == provider else ""))
        print("       s) skip (inherit the global default model)")
        default_i = providers.index(provider) + 1 if provider in providers else None
        sel = input("    provider [1-%d%s / s]: " % (len(providers), ", default %d" % default_i if default_i else "")).strip().lower()
        if sel == "s":
            return None
        if not sel and default_i:
            prov = providers[default_i - 1]
        elif sel.isdigit() and 1 <= int(sel) <= len(providers):
            prov = providers[int(sel) - 1]
        else:
            print("    (enter a number 1-%d, or s to skip)" % len(providers))
            continue
        models = sorted(m for m in avail if m.split("/", 1)[0] == prov)
        print("    %s models:" % prov)
        for i, m in enumerate(models, 1):
            print("      %2d) %s" % (i, m))
        print("       b) back to providers")
        print("       s) skip (inherit the global default model)")
        while True:
            msel = input("    model [1-%d / b / s]: " % len(models)).strip().lower()
            if msel == "s":
                return None
            if msel == "b":
                break
            if msel.isdigit() and 1 <= int(msel) <= len(models):
                return models[int(msel) - 1]
            print("    (enter a number 1-%d, b for back, or s to skip)" % len(models))


EFFORT_ORDER = ("none", "minimal", "low", "medium", "high", "xhigh", "max")


def _role_effort(name, model, avail, default=None):
    """The reasoning effort for a role's model, one the model offers, or None to write the model
    without one (its own default then applies). A --model ROLE=...#effort overrides --effort, which
    overrides DEFAULT_EFFORT; an effort asked for by flag that the model does not offer stops
    init, while a default it does not offer is left out."""
    if _opts.skip_effort or not model:
        return None
    override = _model_flags.get(name, (None, None))[1]
    asked = override or _opts.effort
    eff = asked or default or DEFAULT_EFFORT
    if not eff:
        return None
    if model not in avail:  # --allow-unknown-model: no catalog entry to check the effort against
        warn("%s: effort '%s' not checked - %s is not in opencode's model list" % (ROLE[name][1], eff, model))
        return eff
    offered = efforts_of(avail[model])
    if eff in offered:
        return eff
    if asked:
        die("%s: %s offers no effort '%s' - pick one of: %s"
            % (ROLE[name][1], model, eff, ", ".join(offered) or "(none: pass --skip-effort)"))
    info("%s: %s offers no effort '%s'%s - using its own default"
         % (ROLE[name][1], model, eff, " (it offers: %s)" % ", ".join(offered) if offered else ""))
    return None


def _parse_model_flags(values):
    """The --model flags, ROLE=provider/model[#effort] each, as {role: (model, effort or None)}."""
    out = {}
    for v in values:
        role, sep, ref = v.partition("=")
        model, _hash, eff = ref.partition("#")
        if not sep or role not in ROLE or "/" not in model:
            die("--model %s: write it as ROLE=provider/model[#effort], with ROLE one of: %s"
                % (v, ", ".join(ROLE)))
        out[role] = (model, eff or None)
    return out


def select_models(top):
    section("Agent models")
    if _opts.skip_models:
        info("--skip-models: the agents keep opencode's default model")
        return None, None
    avail = list_models(top)
    if not avail:
        warn("could not read opencode's model list (`opencode api get /api/model`, opencode 2) - "
             "skipping; the agents keep opencode's default model until you run this again")
        return None, None
    chosen = {}
    for name, label, provider, _family, family_name in ROLES:
        f = _model_flags.get(name, (None, None))[0]
        if f:
            if f not in avail and not _opts.allow_unknown_model:
                die("%s: '%s' is not in opencode's model list - use an available id, or pass "
                    "--allow-unknown-model to use it anyway." % (label, f))
            if f not in avail:
                warn("%s: '%s' is not in opencode's model list - using it anyway (--allow-unknown-model)" % (label, f))
            chosen[name] = f
            continue
        rec = recommended(avail, name)
        if rec:
            if confirm("%s: use %s, the newest %s?" % (label, rec, family_name), True):
                chosen[name] = rec
            else:
                chosen[name] = pick_model(avail, provider) if _interactive() else rec
        else:
            info("%s: no %s model here - pick one of yours" % (label, family_name))
            chosen[name] = pick_model(avail, provider) if _interactive() else None
    rev = chosen.get("port-review")
    worker = chosen.get("kha-worker")
    coord = {chosen.get("ptah-orchestrator"), chosen.get("seshat-integrator")}
    if rev and worker and rev == worker:
        warn("port-review has Kha-Worker's model (%s): a different model reviews the worker's code "
             "more independently than a separate session alone" % rev)
    elif rev and rev in coord:
        info("port-review shares its model with Ptah-Orchestrator or Seshat-Integrator: fine while they "
             "write no code")
    elif rev is None and (worker or any(coord)):
        info("port-review has no model of its own: one different from Kha-Worker's reviews more independently")
    # Asked once for all agents when the effort is not given by flag; an agent whose model does not
    # offer the answer keeps its model's own default rather than stopping init.
    default = None
    role_flags = [eff for _model, eff in _model_flags.values()]
    if _interactive() and any(chosen.values()) and not (_opts.skip_effort or _opts.effort or any(role_flags)):
        offered = {e for m in chosen.values() if m in avail for e in efforts_of(avail[m])}
        ordered = [e for e in EFFORT_ORDER if e in offered] + sorted(offered - set(EFFORT_ORDER))
        while True:
            default = ask("Reasoning effort for the agents (%s)" % ", ".join(ordered), default="high")
            if default in offered:
                break
            warn("'%s' is not an effort these models offer" % default)
    efforts = {name: _role_effort(name, chosen.get(name), avail, default) for name, *_ in ROLES}
    for name, label, *_ in ROLES:
        model, eff = chosen.get(name), efforts.get(name)
        ok("%-18s %s" % (label, (model + (", effort " + eff if eff else "")) if model else "opencode's default model"))
    return chosen, efforts


def write_opencode_json(target_dir, chosen, efforts=None):
    """Save the agents' models in the workbench's opencode.json, keeping its other settings. Nothing
    is written when no models were chosen (--skip-models, or opencode could not be asked)."""
    if chosen is None:
        return
    efforts = efforts or {}
    path = os.path.join(target_dir, "opencode.json")
    cfg = {}
    if os.path.isfile(path):
        try:
            cfg = json.load(open(path, encoding="utf-8"))
        except ValueError as exc:
            die("%s is not valid JSON (%s) - fix it or delete it, then re-run" % (path, exc))
        if not isinstance(cfg, dict):
            die("%s is not a JSON object - fix it or delete it, then re-run" % path)
    cfg.setdefault("$schema", "https://opencode.ai/config.json")
    if chosen:
        # opencode 2: `agents`, the effort joined to the model as `provider/model#effort`. An earlier
        # run wrote the opencode 1 shape (`agent`, a separate `variant`); its model and variant move
        # here, since opencode reads each agent entry in one format. A role left without a model
        # loses an earlier run's, so it really inherits the default, as init reports.
        raw_agents = cfg.get("agents")
        agents = raw_agents if isinstance(raw_agents, dict) else {}
        legacy = cfg.get("agent") if isinstance(cfg.get("agent"), dict) else None
        for name, model in chosen.items():
            for table in (legacy, agents):
                if table is not None and isinstance(table.get(name), dict):
                    for key in ("model", "variant"):
                        table[name].pop(key, None)
                    if not table[name]:
                        del table[name]
            if model:
                if not isinstance(agents.get(name), dict):
                    agents[name] = {}
                eff = efforts.get(name)
                agents[name]["model"] = "%s#%s" % (model, eff) if eff else model
        if legacy is not None and not legacy:
            del cfg["agent"]
        if agents:
            cfg["agents"] = agents
        else:
            cfg.pop("agents", None)
    text = json.dumps(cfg, indent=2) + "\n"
    if _opts.dry_run:
        print("  %s[dry-run]%s would save the agents' models in opencode.json:\n%s" % (C["d"], C["0"], text))
        return
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    ok("saved the agents' models in opencode.json (it stays on this machine)")


# ---- SOURCE import -----------------------------------------------------------------------

def import_source(top):
    if _opts.skip_source:
        return
    section("The original code")
    prov = os.path.join(top, "port", "provenance")
    done = sorted(n[:-5] for n in os.listdir(prov) if n.endswith(".yaml")) if os.path.isdir(prov) else []
    src = _opts.source_repo if _opts.source_repo is not None else ask(
        "The original code's repo (a git URL or a local git repo; blank to skip for now)", default="")
    if not src:
        if done:
            ok("already imported: %s" % ", ".join("source/" + n for n in done))
        else:
            info("no original code yet: clone it into source/<name>, then run tools/import-source.sh source/<name>")
        return
    # A pasted browser URL (https://github.com/owner/repo/tree/main, /blob/..., GitLab /-/tree/...) is
    # not a clone URL - normalize it to https://owner/repo.git and recover the ref from the path.
    src, url_ref = normalize_source_url(src)
    if url_ref is not None:
        info("using %s at '%s' (a browser link turned into a clone URL)" % (src, url_ref))
    default_name = re.sub(r"\.git$", "", os.path.basename(src.rstrip("/"))) or "source-program"
    name = resolve_valid(
        _opts.source_name or None, "directory name under source/",
        lambda v: None if (re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", v or "") and v not in (".", "..")
                           and not (v or "").endswith(".git"))
        else "use a single safe directory name (letters/digits/._- ; no '/', '..', or '.git')",
        default=default_name, flagname="--source-name")
    dest = os.path.join("source", name)
    destabs = os.path.join(top, dest)
    if os.path.exists(destabs):
        if os.path.isdir(os.path.join(destabs, ".git")):
            # Importing it as it is could pin a different commit than the one asked for.
            die("%s holds a clone whose import did not finish (it still has its .git). Remove it "
                "(rm -rf %s) and re-run, so the code is imported at the ref you ask for." % (dest, dest))
        ok("%s is already imported - skipping" % dest)
        return
    ref = resolve_valid(
        _opts.source_ref, "tag, branch or commit to pin (blank: the default branch)",
        lambda v: "a ref may not start with '-'" if (v or "").startswith("-") else None,
        default=(url_ref or ""), flagname="--source-ref")
    if not confirm("Import %s%s into %s?" % (src, (" at " + ref) if ref else "", dest), changes=True):
        info("skipped the original code; import it later with tools/import-source.sh")
        return
    robust_clone(src, dest, cwd=top)
    if ref and run(["git", "-C", dest, "checkout", "-q", ref], cwd=top, check=False).returncode != 0:
        shutil.rmtree(destabs, ignore_errors=True)
        die("'%s' is not a tag, branch or commit of %s - nothing was imported. Check the ref, then "
            "re-run." % (ref, src))
    run(["bash", "tools/import-source.sh", dest], cwd=top, env={"CHISEL_INIT": "1"})
    if _opts.dry_run:
        info("would import %s and record its commit in port/provenance/%s.yaml" % (dest, name))
    else:
        commit = (_prov_field(top, name, "commit") or "")[:9]
        ok("imported %s%s; its commit is recorded in port/provenance/%s.yaml"
           % (dest, " at " + commit if commit else "", name))


# ---- flows -------------------------------------------------------------------------------

_GH_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$")
REPO_HINT = "use a git URL (file:///path/to/repo.git for a local one) or a GitHub owner/name"


def _repo_kind(v):
    """'url' for a git URL, 'gh' for a GitHub owner/name, None for anything else (a bare local path
    included). The same rule as tools/new-instance.sh and tools/new-product.sh."""
    v = (v or "").strip()
    if "://" in v or (v.startswith("git@") and ":" in v):
        return "url"
    return "gh" if _GH_NAME.match(v) else None


def preflight_target(new_repo):
    """Before the irreversible flip, confirm the target repo is REACHABLE (a git URL) or
    CREATABLE (a gh name + an authenticated gh), so a push/create failure does not leave a
    half-flipped clone with its remotes already renamed."""
    if _opts.dry_run:
        return
    if _repo_kind(new_repo) == "url":
        r = subprocess.run(["git", "ls-remote", new_repo], capture_output=True, text=True,
                           env=dict(os.environ, GIT_TERMINAL_PROMPT="0"))  # fail fast, never wait on a prompt
        if r.returncode != 0:
            tail = (r.stderr or "").strip().splitlines()
            die("cannot reach %s - create it (and check your access) first. git says: %s"
                % (new_repo, tail[-1] if tail else "ls-remote failed"))
        ok("your workbench repo is reachable: %s" % new_repo)
    else:
        if shutil.which("gh") is None:
            die("'%s' needs the gh CLI to create the repo; install gh or pass a git URL of a repo you made" % new_repo)
        if not _gh_ready():
            die("gh is not signed in - run `gh auth login` first (needed to create %s)" % new_repo)
        ok("gh is signed in; it will create %s" % new_repo)


def setup_product(top):
    section("Your product repo (the translated code)")
    if _opts.skip_product:
        info("--skip-product: no product repo yet (create one later with tools/new-product.sh)")
        return
    if os.path.isfile(os.path.join(top, "port/product.yaml")):
        ok("a product is already linked (port/product.yaml) - skipping")
        return
    repo = resolve_valid(
        _opts.product_repo,
        "Your product repo: a GitHub owner/name to create (needs gh), or the git URL of an empty repo you made (blank to skip for now)",
        lambda v: None if (not v or _repo_kind(v)) else "'%s' is not a repo: %s, or leave it blank to skip" % (v, REPO_HINT),
        default="", flagname="--product-repo")
    if not repo:
        info("no product repo yet: create one later with tools/new-product.sh <repo>")
        return
    name = re.sub(r"\.git$", "", os.path.basename(repo.rstrip("/"))) or "product"
    checkout = resolve_valid(
        _opts.product_dir or None, "where to clone it, beside this folder",
        lambda v: ("'%s' already exists - choose another folder (or remove it)" % v)
        if os.path.exists(os.path.join(top, v or "")) else None,
        default=os.path.join("..", name), flagname="--product-dir")
    if not confirm("Create %s, clone it as %s and link it?" % (repo, checkout), changes=True):
        info("skipped the product repo; create it later with tools/new-product.sh")
        return
    run(["bash", "tools/new-product.sh", repo, checkout], cwd=top, env={"CHISEL_INIT": "1"})
    if _opts.dry_run:
        info("would create %s, clone it as %s and link it in port/product.yaml" % (repo, checkout))
    else:
        ok("created %s, cloned as %s and linked in port/product.yaml" % (repo, checkout))
    info("if the product repo is private, give CI a read-only token for it: the workbench's Actions "
         "secret PRODUCT_RO_TOKEN (see .github/workflows/ci.yml)")


def _yaml_field(top, path, field):
    """One top-level field of the YAML file at `path`, read with the shared strict reader
    tools/coordination/yaml_get.py, or None when it is absent or the file cannot be read."""
    reader = os.path.join(top, "tools", "coordination", "yaml_get.py")
    try:
        r = subprocess.run([sys.executable, reader, path, field], capture_output=True, text=True)
    except OSError:
        return None
    return r.stdout.rstrip("\n") if r.returncode == 0 else None


def _prov_field(top, name, field):
    """Read one top-level field of port/provenance/<name>.yaml (written by import-source.sh) as YAML
    data, through the shared strict reader tools/coordination/yaml_get.py (a line scan also matched a
    nested key and kept an inline comment). Returns the value, or None when the field is absent or
    the file cannot be read (no PyYAML, malformed): the handoff then points at the file instead of
    quoting a value it could not read."""
    return _yaml_field(top, os.path.join(top, "port", "provenance", name + ".yaml"), field)


def write_bootstrap_handoff(top, inst):
    """Rewrite port/handoffs/main.md to the freshly-bootstrapped state, so the FIRST
    /port-sprint-start reads accurate ground truth (a new instance, Phase 0 not begun) instead of the
    pre-init template that says 'source is empty'. Clobber-guard: only overwrites a bootstrap handoff,
    never one a real work sprint already wrote."""
    path = os.path.join(top, "port", "handoffs", "main.md")
    if os.path.isfile(path):
        try:
            head = open(path, encoding="utf-8").read(4000)
        except Exception:
            head = ""
        m = re.search(r"^##\s*Written by:\s*(.+)$", head, re.M)
        writer = m.group(1).strip() if m else ""
        low = writer.lower()
        if writer and not (low.startswith("repo bootstrap") or low.startswith("chisel-init")):
            info("port/handoffs/main.md was rewritten by a sprint (%s) - leaving it untouched." % writer)
            return

    sources = []
    sdir = os.path.join(top, "source")
    if os.path.isdir(sdir):
        for n in sorted(os.listdir(sdir)):
            if n == ".git" or not os.path.isdir(os.path.join(sdir, n)):
                continue
            if not os.path.isfile(os.path.join(top, "port", "provenance", n + ".yaml")):
                warn("source/%s has no provenance record (port/provenance/%s.yaml), so the handoff does "
                     "not list it as imported" % (n, n))
                continue
            sources.append((n, _prov_field(top, n, "commit"), _prov_field(top, n, "remote")))
    has_product = os.path.isfile(os.path.join(top, "port", "product.yaml"))
    has_models = False
    try:
        _oc = json.load(open(os.path.join(top, "opencode.json"), encoding="utf-8"))
        has_models = isinstance(_oc, dict) and any(isinstance(_oc.get(k), dict) and _oc[k] for k in ("agents", "agent"))
    except Exception:
        has_models = False
    inst_name = re.sub(r"\.git$", "", os.path.basename((inst or "instance").rstrip("/"))) or "instance"

    if _opts.dry_run:
        print("  %s[dry-run]%s would write the first sprint's handoff (port/handoffs/main.md)" % (C["d"], C["0"]))
        return
    state_lines = []
    for n, commit, remote in sources:
        state_lines.append("- SOURCE imported: `source/%s/`%s at `%s` (provenance: `port/provenance/%s.yaml`)."
                           % (n, (" from %s" % remote) if remote else "", commit or ("see port/provenance/%s.yaml" % n), n))
    if not sources:
        state_lines.append("- SOURCE: not imported yet (clone under source/, then `tools/import-source.sh source/<name>`).")
    state_lines.append("- Product repo: %s" % ("linked - see `port/product.yaml`; the ported code lives there."
                                               if has_product else "not linked yet (`tools/new-product.sh <repo>`)."))
    state_lines.append("- Agent models + effort: %s" % ("set in `opencode.json`." if has_models
                                                        else "not set (agents inherit defaults)."))
    pin = ("- SOURCE commit to pin is in `port/provenance/<name>.yaml` (captured at import) - use it\n"
           "  for charter section 2 + TRACE `meta.source_commit`. Do NOT ask for or invent a commit.\n"
           if sources else "")
    # The handoff's text is the code-port skill's FIRST-HANDOFF template; only these facts vary.
    tpl = os.path.join(top, ".opencode", "skill", "code-port", "assets", "FIRST-HANDOFF.template.md")
    text = string.Template(open(tpl, encoding="utf-8").read()).substitute(
        name=inst_name, imported="\n".join(state_lines), pin=pin)

    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    ok("wrote the first sprint's handoff (port/handoffs/main.md)")


def _finish_new(state, inst, resumed, models):
    """The remaining setup after the flip - SOURCE import, product, models, handoff. Each step is
    idempotent (it skips what is already done), so this is safe to re-run after a partial init.
    `models` was chosen before anything changed, so a bad model or effort flag stops init first."""
    import_source(state["top"])
    setup_product(state["top"])
    section("Saving the setup")
    write_opencode_json(state["top"], *models)
    write_bootstrap_handoff(state["top"], inst)
    if _opts.dry_run:
        section("Dry run done: nothing changed")
        info("run it again without --dry-run to set up your workbench")
        return
    section("Done: your workbench is ready")
    info("nothing is committed yet: your first /port-sprint-start commits and pushes the setup")
    info("next: run `uv run opencode` here and type /port-sprint-start")


def flow_new(state):
    section("New port: this folder becomes your workbench")
    if not state["is_chisel"]:
        die("this is not a clone of Chisel - clone Chisel, then run this from it")
    base = state["base"] or state["origin"]
    if not base:
        die("cannot tell where Chisel lives (no origin remote, no tools/base-repo.txt)")
    flipped = not _is_base_clone(state)

    # RESUME: this clone is already an instance and no repoint was requested. The flip is done, so
    # re-running just continues the remaining (idempotent) setup - no --force-reinstance needed.
    # init is resumable when an earlier run failed midway (e.g. the SOURCE clone).
    if flipped and not _opts.force_reinstance:
        inst = state["origin"] or "(unknown origin)"
        if not state["upstream"]:
            # Inferred from origin vs the recorded base alone - say so, so a stale pointer is visible.
            warn("treating this clone as a port's workbench: it holds a port, and its origin %s is not "
                 "Chisel's recorded home %s (tools/base-repo.txt). If it is a fresh clone of Chisel, "
                 "correct tools/base-repo.txt and re-run." % (state["origin"], base))
        if _opts.new_repo and not _same_repo(state["origin"], _opts.new_repo):
            die("this folder is already the workbench %s, but you asked for %s.\n     To start another "
                "port, run setup from a fresh clone of Chisel (or pass --force-reinstance to repoint this "
                "one)." % (inst, _opts.new_repo))
        ok("this folder is already your workbench (%s) - continuing its setup" % inst)
        models = select_models(state["top"])  # before anything changes: a bad flag stops init here
        _finish_new(state, inst, resumed=True, models=models)
        return

    new_repo = resolve_valid(
        _opts.new_repo or None,
        "Your workbench repo: a GitHub owner/name to create (needs gh), or the git URL of an empty repo you made",
        lambda v: None if _repo_kind(v) else "'%s' is not a repo: %s" % (v, REPO_HINT),
        required=True, flagname="--new-repo")
    flip = ["bash", "tools/new-instance.sh", new_repo]
    if flipped:  # --force-reinstance: deliberately repoint this already-flipped clone at new_repo
        warn("--force-reinstance: pointing this workbench at %s instead (Chisel stays its upstream)" % new_repo)
        flip.append("--force")
    preflight_target(new_repo)
    models = select_models(state["top"])  # before the flip: a bad flag stops init here
    if not confirm("Make this folder your workbench %s? Chisel becomes its upstream, and main is pushed there."
                   % new_repo, changes=True):
        die("aborted: nothing changed")
    run(flip, cwd=state["top"], env={"CHISEL_INIT": "1"})
    if not _opts.dry_run:
        ok("this folder is now your workbench %s, with Chisel as its upstream" % new_repo)
    _finish_new(state, new_repo, resumed=False, models=models)


def flow_join(state):
    section("Join a port")
    existing = _opts.existing_repo or ask("The workbench repo of the port to join (a git URL or GitHub owner/name)", required=True)
    name = re.sub(r"\.git$", "", os.path.basename(existing.rstrip("/"))) or "port-instance"
    def _dest_error(v):
        # A clone of this same port is an earlier join to continue; anything else there is in the way.
        p = os.path.abspath(v or ".")
        if os.path.exists(p) and not _same_repo(git("remote", "get-url", "origin", cwd=p) if os.path.isdir(p) else "", existing):
            return "'%s' already exists and is not a clone of %s - choose another (or remove it)" % (v, existing)
        return None
    dest = resolve_valid(_opts.dir or None, "where to clone it", _dest_error,
                         default=os.path.join("..", name), flagname="--dir")
    destabs = os.path.abspath(dest)
    base = state["base"]
    chosen, efforts = select_models(state["top"])  # before the clone: a bad flag stops init here
    if os.path.isdir(destabs):
        ok("%s is already a clone of %s - continuing its setup" % (dest, existing))
    else:
        if not confirm("Clone %s into %s?" % (existing, dest), changes=True):
            die("aborted: nothing changed")
        robust_clone(existing, destabs)
    # The workbench carries its own tools/base-repo.txt; prefer that over this clone's.
    base = _base_pointer(destabs) or base
    if not base:
        base = ask("Chisel's repo URL (its updates come from there)", required=True)
    if git("remote", "get-url", "upstream", cwd=destabs):
        run(["git", "-C", destabs, "remote", "set-url", "upstream", base])
    else:
        run(["git", "-C", destabs, "remote", "add", "upstream", base])
    run(["git", "-C", destabs, "config", "merge.ours.driver", "true"])
    run(["git", "-C", destabs, "config", "merge.theirs.driver", "cp -f %B %A"])
    ok("Chisel is its upstream (%s), so /port-sync-with-base can bring Chisel's updates" % base)
    write_opencode_json(destabs, chosen, efforts)
    # Two-repo port? The ported code lives in a sibling PRODUCT repo linked by port/product.yaml.
    # Check it out beside the workbench and let opencode reach it - otherwise the new contributor hits
    # fail-closed UNRELIABLE product checks with no breadcrumb (the `new`/product flow gets this via
    # new-product.sh; joining must do it too).
    two_repo = os.path.isfile(os.path.join(destabs, "port", "product.yaml"))
    if two_repo:
        info("the port has a product repo: cloning it beside the workbench")
        run(["bash", "tools/checkout-product.sh"], cwd=destabs, check=False)
        co = _yaml_field(destabs, os.path.join(destabs, "port", "product.yaml"), "checkout")
        if _opts.dry_run or (co and os.path.isdir(os.path.join(destabs, co))):
            ok("product checked out beside the workbench")
        else:
            warn("the product could not be checked out (see above). Set up access to its repo, then "
                 "run: (cd %s && bash tools/checkout-product.sh)" % dest)
    if _opts.dry_run:
        section("Dry run done: nothing changed")
        info("run it again without --dry-run to join the port")
        return
    section("Done: you joined the port")
    ok("its workbench: %s" % dest)
    info("next: cd %s, run `uv run opencode` and type /port-sprint-start" % dest)


def main():
    global _opts
    # Line by line even into a pipe or a log, so these lines and the scripts init runs stay in order.
    sys.stdout.reconfigure(line_buffering=True)
    ap = argparse.ArgumentParser(prog="uv run tools/chisel-init.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--mode", choices=["new", "join"], default=None,
                    help="new: start a new port from this clone; join: join a port someone else started")
    ap.add_argument("--dry-run", action="store_true", help="show every step; change nothing")
    ap.add_argument("--non-interactive", action="store_true",
                    help="ask nothing: take values from flags and defaults; a change also needs --yes")
    ap.add_argument("--yes", action="store_true", help="confirm every change without asking")
    new = ap.add_argument_group("a new port")
    new.add_argument("--new-repo", default=None,
                     help="your workbench repo: a git URL of an empty repo, or a GitHub owner/name to create (needs gh)")
    new.add_argument("--source-repo", default=None,
                     help="the original code's repo: a git URL or a local git repo; '' to skip for now")
    new.add_argument("--source-ref", default=None, help="the tag, branch or commit of the original code to pin")
    new.add_argument("--source-name", default=None, help="its folder under source/ (default: the repo's name)")
    new.add_argument("--skip-source", action="store_true", help="import the original code later")
    new.add_argument("--product-repo", default=None,
                     help="your product repo: a git URL of an empty repo, or a GitHub owner/name to create; "
                          "'' to skip for now")
    new.add_argument("--product-dir", default=None,
                     help="where to clone the product, beside the workbench (default: ../<its name>)")
    new.add_argument("--skip-product", action="store_true", help="create the product repo later")
    new.add_argument("--force-reinstance", action="store_true",
                     help="point an existing workbench at a different repo (advanced)")
    join = ap.add_argument_group("joining a port")
    join.add_argument("--existing-repo", default=None, help="the workbench repo of the port to join")
    join.add_argument("--dir", default=None, help="where to clone that workbench (default: ../<its name>)")
    models = ap.add_argument_group("the agents' models")
    models.add_argument("--model", action="append", default=[], metavar="ROLE=PROVIDER/MODEL[#EFFORT]",
                        help="an agent's model, and optionally its effort, e.g. "
                             "kha-worker=anthropic/claude-sonnet-5-5#high; repeat it for each agent to set "
                             "(agents: %s)" % ", ".join(ROLE))
    models.add_argument("--effort", default=None,
                        help="the reasoning effort of every agent, one its model offers (e.g. low, high, "
                             "xhigh, max; default %s)" % DEFAULT_EFFORT)
    models.add_argument("--skip-effort", action="store_true", help="set the models without an effort (each model's own default applies)")
    models.add_argument("--skip-models", action="store_true", help="leave the agents on opencode's default model")
    models.add_argument("--allow-unknown-model", action="store_true",
                        help="accept a --model that opencode's model list does not have")
    _opts = ap.parse_args()
    _model_flags.update(_parse_model_flags(_opts.model))

    banner()
    print("  %sset up a port the right way%s%s\n" % (C["d"], C["0"], "   [dry-run - nothing will change]" if _opts.dry_run else ""))
    if not _opts.non_interactive and not sys.stdin.isatty():
        info("input is not a terminal, so setup asks nothing: it takes the defaults, and makes no "
             "change without --yes")
    preflight()
    state = detect_state()

    mode = _opts.mode
    if mode is None:
        if not _interactive():
            die("non-interactive: pass --mode new|join")
        print("\n  Are you starting a new port, or joining one someone else started?")
        print("    1) new  - start a new port: this folder becomes your workbench")
        print("    2) join - join a port someone else started")
        while mode is None:
            sel = input("  choose [1/2]: ").strip()
            mode = "new" if sel == "1" else "join" if sel == "2" else None
            if mode is None:
                warn("enter 1 (new) or 2 (join).")
    if mode == "new":
        flow_new(state)
    else:
        flow_join(state)


if __name__ == "__main__":
    try:
        main()
    except (KeyboardInterrupt, EOFError):  # Ctrl-C, or Ctrl-D at a prompt: stop without a traceback
        print("\n  %sx%s aborted" % (C["r"], C["0"]), file=sys.stderr)
        sys.exit(130)
