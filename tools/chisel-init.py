#!/usr/bin/env python3
"""chisel-init - set up a port the right way, interactively.

Two situations it handles:
  * NEW project        - you are starting a fresh port. This clone of the chisel BASE repo is
                         flipped into your own port instance (the workbench, where all state and
                         lessons persist): the base becomes `upstream`, your new repo becomes
                         `origin`, the layer merge drivers are set, and main is pushed. You may
                         also point it at the SOURCE program's repo, which it clones into source/
                         and imports (pinned, nested .git removed) ready for the charter. It also
                         creates the separate, clean PRODUCT repo that holds the ported code (its
                         own repo, a sibling clone, linked from the workbench via port/product.yaml).
  * CONTRIBUTE         - someone already started the port (its workbench is an existing repo).
                         This clones that instance for you and wires `upstream` -> the base plus
                         the merge drivers, so you can sync base improvements while you work.

In both, it parses `opencode models` and configures each agent's model AND its reasoning effort,
writing them to a per-instance opencode.json - the authoritative, instance-owned source of both
(the agents carry no model/variant in their base-owned frontmatter, so a /port-sync-with-base
never clobbers your choice). Model defaults, when available: Kha-Worker ->
anthropic/claude-sonnet-4-6 (a capable, lower-cost model for the many parallel workers);
Ptah-Orchestrator + Seshat-Integrator -> anthropic/claude-opus-4-8; port-review ->
openai/gpt-5.5 (a reviewer model distinct from the worker it reviews is a stronger independence
control than a different session alone). Effort is written as opencode's provider-agnostic `variant` and defaults
to `high` for every role (validated against the chosen model's provider so it is never a
silently-ignored value); raise a role to anthropic `max` / openai `xhigh` for maximum scrutiny.

It REPORTS each step and ASKS before anything that writes, clones, or pushes. Re-runnable and
non-destructive: it detects existing remotes/sources and skips rather than clobbering.

Usage:
  tools/chisel-init.py                         # interactive, run from a chisel clone
  tools/chisel-init.py --dry-run               # show every step, change nothing
  tools/chisel-init.py --mode new --new-repo me/port-foo --source-repo URL --source-ref TAG
  tools/chisel-init.py --mode contribute --existing-repo URL --dir ../port-foo
  Flags: --non-interactive --yes --skip-source --skip-models --skip-product
         --product-repo R --product-dir D
         --worker-model M --orchestrator-model M --integrator-model M --review-model M
         --effort V (all roles) --worker-effort V --orchestrator-effort V --integrator-effort V
         --review-effort V --skip-effort --allow-unknown-effort
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys

REC = {
    "kha-worker": "anthropic/claude-sonnet-4-6",
    "ptah-orchestrator": "anthropic/claude-opus-4-8",
    "seshat-integrator": "anthropic/claude-opus-4-8",
    "port-review": "openai/gpt-5.5",
}
ROLES = [
    ("kha-worker", "Worker        (Kha-Worker)", "anthropic"),
    ("ptah-orchestrator", "Orchestrator  (Ptah-Orchestrator)", "anthropic"),
    ("seshat-integrator", "Integrator    (Seshat-Integrator)", "anthropic"),
    ("port-review", "Reviewer      (port-review)", "openai"),
]
# Default reasoning EFFORT per role, written to opencode.json as the provider-agnostic `variant`
# (opencode's effort selector). `high` across the board is the strongest STANDARD level on every
# provider we default to - deliberately not the cost-maximizing extreme (anthropic `max`, openai
# `xhigh`), which you opt into per role via the --*-effort flags when budget allows. Both the
# worker carving numerics and the independent reviewer catching a silent divergence earn a high
# budget; the gate ladder + independent review remain the real backstop, not raw model effort.
EFFORT = {
    "kha-worker": "high",
    "ptah-orchestrator": "high",
    "seshat-integrator": "high",
    "port-review": "high",
}
# opencode's built-in model variants per provider (the valid effort values). A chosen variant is
# validated against the CHOSEN model's provider so chisel-init never writes a silently-ignored
# value - the same class of bug as a frontmatter model that opencode.json cannot override.
PROVIDER_VARIANTS = {
    "anthropic": {"high", "max"},
    "openai": {"none", "minimal", "low", "medium", "high", "xhigh"},
    "google": {"low", "high"},
}
_opts = argparse.Namespace()  # the parsed args; the real value is installed in main()


def _color():
    if os.environ.get("NO_COLOR") or not sys.stdout.isatty():
        return {k: "" for k in ("g", "y", "r", "b", "d", "0")}
    return {"g": "\033[32m", "y": "\033[33m", "r": "\033[31m", "b": "\033[1m", "d": "\033[2m", "0": "\033[0m"}


C = _color()

BANNER = r"""
                P R O J E C T
     ____  _   _  ___  ____   _____  _
    / ___|| | | ||_ _|/ ___| | ____|| |
   | |    | |_| | | | \___ \ |  _|  | |
   | |___ |  _  | | |  ___) || |___ | |___
    \____||_| |_||___||____/ |_____||_____|
   01  carve, validate, never trust - one gated cut  10
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


def avail_mark(have):
    """A green tick / red x for 'is this (recommended) model available here'. Unicode glyphs on a
    UTF-8 terminal; an ASCII fallback so a non-UTF-8 stdout cannot crash the bootstrap. The source
    stays ASCII (escape sequences), the runtime shows the tick/x."""
    enc = (getattr(sys.stdout, "encoding", "") or "").lower()
    if "utf" in enc:
        return "%s\u2713%s" % (C["g"], C["0"]) if have else "%s\u2717%s" % (C["r"], C["0"])
    return "%s[have]%s" % (C["g"], C["0"]) if have else "%s[missing]%s" % (C["r"], C["0"])


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


def confirm(prompt, default=True):
    if _opts.yes or not _interactive():
        return True if _opts.yes else default
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


def run(cmd, mutating=True, cwd=None, check=True, capture=False, env=None):
    """Run a command. In --dry-run, mutating commands are echoed and skipped; reads still run.
    `env` (when given) is merged onto the inherited environment for this one call."""
    shown = " ".join(cmd) + (" (in %s)" % cwd if cwd else "")
    if _opts.dry_run and mutating:
        print("  %s[dry-run]%s would run: %s" % (C["d"], C["0"], shown))
        return subprocess.CompletedProcess(cmd, 0, "", "")
    info("run: %s" % shown)
    full_env = None
    if env:
        full_env = dict(os.environ)
        full_env.update(env)
    res = subprocess.run(cmd, cwd=cwd, text=True, env=full_env,
                         capture_output=capture, stdout=None if not capture else subprocess.PIPE,
                         stderr=None if not capture else subprocess.PIPE)
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


def _https_github_slug(url):
    """owner/repo for an HTTPS github.com URL (the case that prompts for a password), else None.
    An SSH URL (git@github.com:...) is left alone - it authenticates with the user's keys."""
    m = re.match(r"^https://github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?/?$", url or "")
    return m.group(1) if m else None


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
    slug = _https_github_slug(url)
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
    section("Tooling preflight")
    need = {"git": True, "python3": True, "opencode": False, "gh": False, "jq": False}
    missing_hard = []
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
        else:
            warn("%-8s not found%s" % (tool, " - needed to create a repo by name; a git URL works without it" if tool == "gh" else " - needed to configure agent models" if tool == "opencode" else ""))
            if tool in ("gh", "opencode"):
                missing_hard.append(tool)
    try:
        import yaml  # noqa: F401
        ok("PyYAML   present (the coordination checks need it)")
    except Exception:
        warn("PyYAML   missing - `pip install pyyaml`; the coordination checks need it")
    return missing_hard


def git(*a, cwd=None):
    try:
        r = subprocess.run(["git", *a], cwd=cwd, capture_output=True, text=True)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def detect_state():
    section("Where am I")
    top = git("rev-parse", "--show-toplevel")
    if not top:
        die("not inside a git repository - clone the chisel base first, then run this from it")
    is_chisel = os.path.isfile(os.path.join(top, ".opencode/skill/code-port/SKILL.md"))
    origin = git("remote", "get-url", "origin", cwd=top)
    upstream = git("remote", "get-url", "upstream", cwd=top)
    base_file = ""
    bf = os.path.join(top, "tools/base-repo.txt")
    if os.path.isfile(bf):
        for ln in open(bf, encoding="utf-8"):
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                base_file = ln
                break
    ok("repo root : %s" % top)
    ok("chisel    : %s" % ("yes" if is_chisel else "NO (not a chisel clone?)"))
    ok("origin    : %s" % (origin or "(none)"))
    ok("upstream  : %s" % (upstream or "(none)"))
    ok("base      : %s" % (base_file or "(tools/base-repo.txt absent)"))
    return {"top": top, "is_chisel": is_chisel, "origin": origin, "upstream": upstream, "base": base_file}


def _norm_url(u):
    return re.sub(r"\.git$", "", (u or "").strip().lower())


def _repo_slug(u):
    """The 'owner/name' a repo ref points at - comparing a gh name and a git URL alike
    (git@github.com:o/n.git, https://github.com/o/n, and o/n all map to 'o/n')."""
    s = re.sub(r"\.git/?$", "", (u or "").strip().rstrip("/"))
    parts = re.split(r"[/:]", s)
    return ("/".join(parts[-2:])).lower() if len(parts) >= 2 else s.lower()


def _same_repo(a, b):
    return bool(a) and bool(b) and _repo_slug(a) == _repo_slug(b)


# ---- models ------------------------------------------------------------------------------

def list_models():
    if shutil.which("opencode") is None:
        return None
    try:
        r = subprocess.run(["opencode", "models"], capture_output=True, text=True, timeout=60)
    except Exception:
        return None
    if r.returncode != 0:
        return None
    return sorted({ln.strip() for ln in r.stdout.splitlines() if "/" in ln and ln.strip()})


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
        models = [m for m in avail if m.split("/", 1)[0] == prov]
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


def _role_effort(name, model):
    """The reasoning effort (opencode `variant`) for a role, validated against the CHOSEN model's
    provider. Returns None to write no variant (--skip-effort, or no model so no provider to
    validate against). A --*-effort flag overrides --effort overrides the EFFORT default."""
    if _opts.skip_effort or not model:
        return None
    override = {"kha-worker": _opts.worker_effort, "ptah-orchestrator": _opts.orchestrator_effort,
                "seshat-integrator": _opts.integrator_effort,
                "port-review": _opts.review_effort}.get(name)
    eff = override or _opts.effort or EFFORT.get(name)
    if not eff:
        return None
    provider = model.split("/", 1)[0]
    allowed = PROVIDER_VARIANTS.get(provider)
    if allowed is None:
        warn("%s: provider '%s' has no known variant set - writing effort '%s' unvalidated "
             "(confirm it is a real variant for that provider)" % (name, provider, eff))
        return eff
    if eff not in allowed:
        if _opts.allow_unknown_effort:
            warn("%s: '%s' is not a known %s variant - writing anyway (--allow-unknown-effort)" % (name, eff, provider))
            return eff
        die("%s: effort '%s' is not a valid %s variant - pick one of: %s (or pass --allow-unknown-effort)"
            % (name, eff, provider, ", ".join(sorted(allowed))))
    return eff


def select_models():
    section("Agent models")
    if _opts.skip_models:
        info("--skip-models: leaving agent models unset (inherit the global default)")
        return None, None
    avail = list_models()
    if not avail:
        warn("`opencode models` returned nothing usable - skipping; set agent models in opencode.json later")
        return None, None
    flags = {"kha-worker": _opts.worker_model,
             "ptah-orchestrator": _opts.orchestrator_model, "seshat-integrator": _opts.integrator_model,
             "port-review": _opts.review_model}
    chosen = {}
    for name, label, provider in ROLES:
        f = flags.get(name)
        if f:
            if f not in avail and not _opts.allow_unknown_model:
                die("%s: '%s' is not in `opencode models` - use an available id, or pass "
                    "--allow-unknown-model to use it anyway." % (label, f))
            if f not in avail:
                warn("%s: '%s' is not listed by `opencode models` - using it anyway (--allow-unknown-model)" % (label, f))
            chosen[name] = f
            ok("%s -> %s" % (label, f))
            continue
        rec = REC[name]
        have = rec in avail
        # Always SHOW the recommended model with a tick/x for availability, so the user sees what
        # the recommendation is and whether they have it - even when it is not installed here.
        if have:
            if confirm("%s: use recommended %s %s?" % (label, rec, avail_mark(True)), True):
                chosen[name] = rec
            else:
                chosen[name] = pick_model(avail, provider) if _interactive() else rec
        else:
            info("%s: recommended %s %s (not available here) - pick from your installed models"
                 % (label, rec, avail_mark(False)))
            chosen[name] = pick_model(avail, provider) if _interactive() else None
        ok("%s -> %s" % (label, chosen[name] or "(unset; inherit global default)"))
    rev = chosen.get("port-review")
    worker = chosen.get("kha-worker")
    coord = {chosen.get("ptah-orchestrator"), chosen.get("seshat-integrator")}
    if rev and worker and rev == worker:
        warn("reviewer model (%s) equals the WORKER's - the worker authors what the reviewer checks, so a different reviewer model is the key independence control (B1/B2/B3), stronger than a different session alone" % rev)
    elif rev and rev in coord:
        info("reviewer model (%s) equals a coordination agent's - fine unless that agent authors code (e.g. an integrator semantic-conflict fix), which then needs its own independent review" % rev)
    elif rev is None and (worker or any(coord)):
        info("reviewer model is unset; for stronger independence set it distinct from the worker's model")
    efforts = {name: _role_effort(name, chosen.get(name)) for name, _lbl, _prov in ROLES}
    for name, label, _prov in ROLES:
        if efforts.get(name):
            ok("%s effort -> %s" % (label, efforts[name]))
    return chosen, efforts


def write_opencode_json(target_dir, chosen, efforts=None):
    efforts = efforts or {}
    path = os.path.join(target_dir, "opencode.json")
    cfg = {}
    if os.path.isfile(path):
        try:
            loaded = json.load(open(path, encoding="utf-8"))
        except Exception as exc:
            if not _opts.replace_opencode_json:
                die("existing %s is not valid JSON (%s) - NOT overwriting.\n     Add the agent "
                    "models by hand, or re-run with --replace-opencode-json." % (path, exc))
            warn("existing %s is not valid JSON; replacing it (--replace-opencode-json)" % path)
            loaded = None
        if isinstance(loaded, dict):
            cfg = loaded
        elif loaded is not None:
            if not _opts.replace_opencode_json:
                die("existing %s is not a JSON object - NOT overwriting.\n     Fix it, or re-run "
                    "with --replace-opencode-json." % path)
            warn("existing %s is not a JSON object; replacing it (--replace-opencode-json)" % path)
    cfg.setdefault("$schema", "https://opencode.ai/config.json")
    # Always grant /tmp scratch so hands-off / parallel workers never prompt on a mktemp temp file
    # (mirrors tools/coordination/grant_external_access.py, which maintains it at sync time). Fail
    # closed on a malformed permission block like the grant tool, rather than silently clobbering it.
    def _ensure_obj(container, key, label):
        if key not in container:          # absent -> create; an explicit null is "present and not an object"
            container[key] = {}
            return container[key]
        v = container[key]
        if not isinstance(v, dict):
            if not _opts.replace_opencode_json:
                die("existing %s `%s` is not an object - NOT overwriting.\n     Fix it, or re-run with "
                    "--replace-opencode-json." % (path, label))
            warn("existing %s `%s` is not an object; replacing it (--replace-opencode-json)" % (path, label))
            container[key] = {}
        return container[key]
    extd = _ensure_obj(_ensure_obj(cfg, "permission", "permission"), "external_directory", "permission.external_directory")
    for _p in ("/tmp/**", "/tmp/*"):
        extd[_p] = "allow"
    if chosen and any(chosen.values()):
        raw_agent = cfg.get("agent")
        agent = raw_agent if isinstance(raw_agent, dict) else {}
        for name, model in chosen.items():
            if model:
                raw_entry = agent.get(name)
                entry = raw_entry if isinstance(raw_entry, dict) else {}
                entry["model"] = model
                eff = efforts.get(name)
                if eff:
                    entry["variant"] = eff
                agent[name] = entry
        cfg["agent"] = agent
    text = json.dumps(cfg, indent=2) + "\n"
    if _opts.dry_run:
        print("  %s[dry-run]%s would write %s:\n%s" % (C["d"], C["0"], path, text))
        return
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    # opencode.json is instance-local (gitignored); never tracked. Untrack if a clone inherited it.
    if git("-C", target_dir, "ls-files", "opencode.json"):
        run(["git", "-C", target_dir, "rm", "--cached", "--quiet", "opencode.json"], check=False)
    ok("wrote %s (instance-local: /tmp scratch grant + agent models; gitignored, never committed)" % path)


# ---- SOURCE import -----------------------------------------------------------------------

def import_source(top):
    if _opts.skip_source:
        return
    section("SOURCE program")
    src = _opts.source_repo if _opts.source_repo is not None else ask(
        "SOURCE repo to port (git URL or local path; blank to skip for now)", default="")
    if not src:
        info("no SOURCE given; import it later: clone into source/<name> (gh repo clone <owner/repo> "
             "for a private GitHub repo, else git clone), then tools/import-source.sh source/<name>")
        return
    # A pasted browser URL (https://github.com/owner/repo/tree/main, /blob/..., GitLab /-/tree/...) is
    # not a clone URL - normalize it to https://owner/repo.git and recover the ref from the path.
    src, url_ref = normalize_source_url(src)
    if url_ref is not None:
        info("normalized the SOURCE URL to a cloneable form: %s (ref '%s' taken from the URL)" % (src, url_ref))
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
            warn("%s already exists WITH a nested .git - a previous import did not finish." % dest)
            info("finish it: tools/import-source.sh %s   (or `rm -rf %s` and re-run to re-import)" % (dest, dest))
        else:
            info("%s already exists (SOURCE looks already imported) - skipping clone/import." % dest)
        return
    ref = resolve_valid(
        _opts.source_ref, "ref/commit to pin (tag/commit/sha; blank = default branch)",
        lambda v: "a ref may not start with '-'" if (v or "").startswith("-") else None,
        default=(url_ref or ""), flagname="--source-ref")
    if not confirm("Clone %s into %s%s and import (remove nested .git)?" % (src, dest, (" @ " + ref) if ref else "")):
        info("skipped SOURCE import")
        return
    robust_clone(src, dest, cwd=top)
    if ref:
        run(["git", "-C", dest, "checkout", ref], cwd=top)
    run(["bash", "tools/import-source.sh", dest], cwd=top)
    info("SOURCE imported; provenance saved to port/provenance/%s.yaml (the commit to pin) - NOT committed yet." % name)
    info("Phase 0 reads that file for charter section 2 + TRACE meta.source_commit; then commit it yourself (routine commits are yours).")


# ---- flows -------------------------------------------------------------------------------

def preflight_target(new_repo):
    """Before the irreversible flip, confirm the target repo is REACHABLE (a git URL) or
    CREATABLE (a gh name + an authenticated gh), so a push/create failure does not leave a
    half-flipped clone with its remotes already renamed."""
    if _opts.dry_run:
        return
    if new_repo.startswith(("http", "git@", "ssh://", "git://", "file://")):
        r = subprocess.run(["git", "ls-remote", new_repo], capture_output=True, text=True)
        if r.returncode != 0:
            tail = (r.stderr or "").strip().splitlines()
            die("cannot reach target repo '%s' - create it (and check access) first.  git: %s"
                % (new_repo, tail[-1] if tail else "ls-remote failed"))
        ok("target reachable: %s" % new_repo)
    else:
        if shutil.which("gh") is None:
            die("'%s' needs the gh CLI to create the repo; install gh or pass a git URL of a repo you made" % new_repo)
        if subprocess.run(["gh", "auth", "status"], capture_output=True, text=True).returncode != 0:
            die("gh is not authenticated - run `gh auth login` first (needed to create '%s')" % new_repo)
        ok("gh authenticated; will create %s" % new_repo)


def setup_product(top):
    if _opts.skip_product:
        info("--skip-product: not creating a product repo (link one later with tools/new-product.sh)")
        return
    section("Product repository (the ported code gets its own clean repo)")
    if os.path.isfile(os.path.join(top, "port/product.yaml")):
        info("port/product.yaml already exists - a product is already linked; skipping.")
        return
    repo = resolve_valid(
        _opts.product_repo,
        "Product repo to create - a gh name 'me/foo-product' (uses gh) OR a git URL of an empty repo you made (blank to skip)",
        lambda v: None if (not v or "/" in v) else "use a gh 'owner/name' or a git URL (no '/' found), or leave blank to skip",
        default="", flagname="--product-repo")
    if not repo:
        info("no product repo yet; create one later with: tools/new-product.sh <repo>")
        return
    name = re.sub(r"\.git$", "", os.path.basename(repo.rstrip("/"))) or "product"
    checkout = _opts.product_dir or ask("local checkout dir for the product (a sibling)", default=os.path.join("..", name))
    if not confirm("Create product repo '%s' and link it (checkout '%s')?" % (repo, checkout)):
        info("skipped product repo")
        return
    run(["bash", "tools/new-product.sh", repo, checkout], cwd=top)
    info("product linked via port/product.yaml - commit it yourself (routine commits AND their push to the workbench origin are yours; only product-code landing / milestone tag / upstream / claim refs stay gated).")


def _prov_field(top, name, field):
    """Read one flat field from port/provenance/<name>.yaml (written by import-source.sh) without a
    PyYAML dependency. Returns the value (quotes stripped) or None."""
    path = os.path.join(top, "port", "provenance", name + ".yaml")
    try:
        for ln in open(path, encoding="utf-8"):
            m = re.match(r"\s*" + re.escape(field) + r"\s*:\s*(.+?)\s*$", ln)
            if m:
                return m.group(1).strip().strip('"').strip("'")
    except Exception:
        pass
    return None


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
            sources.append((n, _prov_field(top, n, "commit"), _prov_field(top, n, "remote")))
    has_product = os.path.isfile(os.path.join(top, "port", "product.yaml"))
    has_models = False
    try:
        _oc = json.load(open(os.path.join(top, "opencode.json"), encoding="utf-8"))
        has_models = isinstance(_oc, dict) and isinstance(_oc.get("agent"), dict) and bool(_oc.get("agent"))
    except Exception:
        has_models = False
    inst_name = re.sub(r"\.git$", "", os.path.basename((inst or "instance").rstrip("/"))) or "instance"

    L = ["# HANDOFF - %s / main" % inst_name, "",
         "> Rewritten at the END of every sprint. The next sprint starts by reading this file,",
         "> then LESSONS.md (STANDING RULES at minimum), then the relevant charter section, then",
         "> KNOWN-DIVERGENCES.md - before doing anything else.", "",
         "## Written by: chisel-init bootstrap (no work sprints yet)", "",
         "### Current state",
         "- Freshly bootstrapped by chisel-init. Phase: 0 (scoping) - NOT started.",
         "- No PORT milestone tag yet. (Any inherited tag like `v0.1.0` is the METHODOLOGY's own release",
         "  version from the base clone - semver per VERSION, NOT a port milestone; do not treat it as one.)",
         "- The bootstrap below is UNCOMMITTED - the expected fresh-instance state, NOT a divergence;",
          "  committing it is your first Phase 0 step (routine commits AND pushing them to the workbench origin are yours; only product-code landing / milestone tag / upstream / claim refs stay gated)."]
    if sources:
        for n, commit, remote in sources:
            c = commit or ("see port/provenance/%s.yaml" % n)
            r = (" from %s" % remote) if remote else ""
            L.append("- SOURCE imported: `source/%s/`%s at `%s` (provenance: `port/provenance/%s.yaml`)." % (n, r, c, n))
    else:
        L.append("- SOURCE: not imported yet (clone under source/, then `tools/import-source.sh source/<name>`).")
    L.append("- Product repo: %s" % ("linked - see `port/product.yaml`; the ported code lives there."
                                     if has_product else "not linked yet (`tools/new-product.sh <repo>`)."))
    L.append("- Agent models + effort: %s" % ("set in `opencode.json`." if has_models else "not set (agents inherit defaults)."))
    L.append("- Charter `port/plan/00-charter.md` sections 1/2/3: still the un-instantiated template (TBD).")
    L.append("- `port/TRACE.yaml`: empty; `meta.source_commit` still null.")
    L += ["", "### Canonical reference artifacts in force"]
    if sources:
        L.append("- SOURCE commit to pin is in `port/provenance/<name>.yaml` (captured at import) - use it")
        L.append("  for charter section 2 + TRACE `meta.source_commit`. Do NOT ask for or invent a commit.")
    L.append("- Reference run: not yet defined (charter section 2 is TBD).")
    L += ["", "### NEXT TASK (Phase 0 scoping - one coherent arc)",
          "DRIVE Phase 0 to completion in this sprint - it is one bounded scoping arc (no TARGET code",
          "yet). Do the ROUTINE work without stalling and COMMIT it yourself. But Phase 0 opens with TWO",
          "FOUNDATIONAL decisions that are the human's to make - the **TARGET language** and the **SCOPE** -",
          "and you must ASK and get their answer BEFORE proceeding (this is a genuine human decision, not the",
          "don't-pester case). Steps:",
          "1. COMMIT the bootstrap yourself - `source/`, `port/product.yaml`, `port/provenance/`, this",
          "   handoff - as one conventional commit, then report what you committed. Routine commits (and",
          "   pushing this project-layer state to the workbench origin) are YOURS - they carry the human's",
          "   authorship, no AI attribution; only product-code landing / the milestone tag+sign-off / upstream",
          "   / claim refs stay gated, so do NOT ask whether to commit or push routine state. (`opencode.json` is gitignored.)",
          "2. ASK THE HUMAN the two foundational decisions, then WAIT for their answer - do not pick for them",
          "   and march on. OBSERVE the SOURCE first so you can lead with a recommendation (a quick confirm,",
          "   not an open-ended question), but the decision is theirs:",
          "   a. **TARGET** language/standard, compilers + flags, and execution model (charter section 1).",
          "      OBSERVE the SOURCE language/standard from the imported tree (cite file:line); PROPOSE a",
          "      recommended TARGET + rationale. NEVER silently infer the TARGET from the repo/instance/product",
          "      name or the tree (a product repo named `<x>-c` is NOT a decision to port to C).",
          "   b. **SCOPE** (charter section 3): the pinned configuration, the LIVE subset, and the EXCLUDED",
          "      subsystems. PROPOSE a scope from coverage/build-log/link-map evidence; the human confirms",
          "      what is in and out of the port.",
          "   Record their decisions in sections 1 and 3 only once you have them.",
          "3. Set charter section 2 + TRACE `meta.source_commit` from `port/provenance/<name>.yaml`.",
          "4. Record selection-criteria gaps (section 10); finalize the pinned configuration (section 3) with provenance.",
          "5. Define the canonical reference run + fast rig in `reference/runs.md`; populate `port/TRACE.yaml`.",
          "6. /port-digest - compile the evidence pack + a prefilled SIGNOFF.md for the human.",
          "Done = decisions recorded in the charter, provenance pinned, state committed, this handoff",
          "rewritten, and the /port-digest pack prepared -> human SIGNOFF.md -> the `phase0-signed` tag.",
          "", "### In-flight anomalies / open questions", "- none",
          "", "### Do-not-touch", "- nothing locked (single stream)",
          "", "### Notes for the human",
          "- This instance was freshly bootstrapped by chisel-init; the SOURCE commit is already captured",
          "  under port/provenance/, so Phase 0 never needs to ask for a URL or commit.",
          "- The TARGET language and the SCOPE are YOUR decisions: the agent proposes a recommendation with",
          "  rationale and ASKS you up front, never silently assuming the target from how this instance or the",
          "  product was named. Everything else in Phase 0 is routine and proceeds without pestering you."]
    text = "\n".join(L) + "\n"

    if _opts.dry_run:
        print("  %s[dry-run]%s would rewrite %s (bootstrap handoff)" % (C["d"], C["0"], path))
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    ok("rewrote port/handoffs/main.md to the fresh-instance state (the first /port-sprint-start reads it)")


def _finish_new(state, inst, resumed):
    """The remaining setup after the flip - SOURCE import, product, models, handoff. Each step is
    idempotent (it skips what is already done), so this is safe to re-run after a partial init."""
    import_source(state["top"])
    setup_product(state["top"])
    write_opencode_json(state["top"], *select_models())
    write_bootstrap_handoff(state["top"], inst)
    section("Done - %s port instance" % ("resumed" if resumed else "new"))
    ok("instance %s ready; all state + lessons persist in this workbench" % inst)
    info("next: open a fresh conversation and run /port-sprint-start - it loads the handoff and names your Phase 0 task")


def flow_new(state):
    section("New port  (flip this clone into your port instance)")
    if not state["is_chisel"]:
        die("this is not a chisel base clone - clone the base repo, then run this from it")
    base = state["base"] or state["origin"]
    if not base:
        die("cannot determine the base repo (no origin, no tools/base-repo.txt)")
    flipped = bool(state["upstream"]) or bool(state["origin"] and _norm_url(state["origin"]) != _norm_url(base))

    # RESUME: this clone is already an instance and no repoint was requested. The flip is done, so
    # re-running just continues the remaining (idempotent) setup - no --force-reinstance needed.
    # init is resumable when an earlier run failed midway (e.g. the SOURCE clone).
    if flipped and not _opts.force_reinstance:
        inst = state["origin"] or "(unknown origin)"
        if _opts.new_repo and not _same_repo(state["origin"], _opts.new_repo):
            die("this clone is already the instance %s, but you asked for %s.\n     To REPOINT it at a "
                "different repo pass --force-reinstance (advanced); to start a different port, run init "
                "from a fresh base clone." % (inst, _opts.new_repo))
        ok("already flipped to instance %s (upstream=%s) - the flip is done; resuming the remaining setup."
           % (inst, state["upstream"] or "(none)"))
        info("(--force-reinstance is only needed to repoint this clone at a DIFFERENT repo.)")
        _finish_new(state, inst, resumed=True)
        return

    new_repo = resolve_valid(
        _opts.new_repo or None,
        "New port-instance repo - a gh name 'me/port-foo' (uses gh) OR a git URL you created",
        lambda v: None if "/" in (v or "") else "use a gh 'owner/name' or a git URL (no '/' found)",
        required=True, flagname="--new-repo")
    flip = ["bash", "tools/new-instance.sh", new_repo]
    if flipped:  # --force-reinstance: deliberately repoint this already-flipped clone at new_repo
        warn("--force-reinstance: repointing this clone to '%s' (origin rewritten; upstream stays the base)" % new_repo)
        flip.append("--force")
    preflight_target(new_repo)
    if not confirm("Flip this clone into instance '%s' (origin->upstream=base, set merge drivers, push main)?" % new_repo):
        die("aborted before creating the instance")
    run(flip, cwd=state["top"])
    _finish_new(state, new_repo, resumed=False)


def flow_contribute(state):
    section("Contribute  (join an existing port someone else started)")
    existing = _opts.existing_repo or ask("Existing port-instance repo URL to join", required=True)
    name = re.sub(r"\.git$", "", os.path.basename(existing.rstrip("/"))) or "port-instance"
    dest = resolve_valid(
        _opts.dir or None, "clone into directory",
        lambda v: ("'%s' already exists - choose another (or remove it)" % v) if os.path.exists(os.path.abspath(v or ".")) else None,
        default=os.path.join("..", name), flagname="--dir")
    destabs = os.path.abspath(dest)
    base = state["base"]
    if not confirm("Clone %s into %s, then wire upstream=base + merge drivers?" % (existing, dest)):
        die("aborted")
    robust_clone(existing, destabs)
    # The instance carries tools/base-repo.txt (inherited); prefer that over our own base.
    bf = os.path.join(destabs, "tools/base-repo.txt")
    if os.path.isfile(bf):
        for ln in open(bf, encoding="utf-8"):
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                base = ln
                break
    if not base:
        base = ask("base (methodology) repo URL for `upstream`", required=True)
    run(["git", "-C", destabs, "remote", "remove", "upstream"], check=False)
    run(["git", "-C", destabs, "remote", "add", "upstream", base])
    run(["git", "-C", destabs, "config", "merge.ours.driver", "true"])
    run(["git", "-C", destabs, "config", "merge.theirs.driver", "cp -f %B %A"])
    ok("upstream -> %s ; layer merge drivers set (so /port-sync-with-base works)" % base)
    chosen, efforts = select_models()
    write_opencode_json(destabs, chosen, efforts)
    # Two-repo port? The ported code lives in a sibling PRODUCT repo linked by port/product.yaml.
    # Check it out beside the workbench and let opencode reach it - otherwise the new contributor hits
    # fail-closed UNRELIABLE product checks with no breadcrumb (the `new`/product flow gets this via
    # new-product.sh; contribute must do it too).
    two_repo = os.path.isfile(os.path.join(destabs, "port", "product.yaml"))
    if two_repo:
        info("two-repo port (port/product.yaml) - checking out the linked product beside the workbench")
        run(["bash", "tools/checkout-product.sh"], cwd=destabs, check=False)
        # Grant opencode the product dir (best-effort; idempotent - it also re-asserts /tmp scratch).
        run(["python3", "tools/coordination/grant_external_access.py"], cwd=destabs, check=False)
        ok("product checked out beside the workbench (if reachable) and granted to opencode")
    section("Done - joined the port")
    ok("working copy: %s (origin = the shared port; upstream = the base)" % dest)
    if two_repo:
        info("if the product clone failed (private repo / no creds), set product access then re-run: "
             "(cd %s && bash tools/checkout-product.sh)" % dest)
    info("next: cd %s, open a fresh conversation, run /port-sprint-start, and claim a ready work item" % dest)


def main():
    global _opts
    ap = argparse.ArgumentParser(add_help=True, description="Set up a chisel port (new or contribute).")
    ap.add_argument("--mode", choices=["new", "contribute"], default=None)
    ap.add_argument("--dry-run", action="store_true", help="show every step; change nothing")
    ap.add_argument("--non-interactive", action="store_true", help="never prompt; use flags/defaults (fail if a required value is missing)")
    ap.add_argument("--yes", action="store_true", help="assume yes to confirmations")
    ap.add_argument("--new-repo", default=None, help="new instance repo (gh 'owner/name' or git URL)")
    ap.add_argument("--source-repo", default=None, help="SOURCE program repo (git URL or path); '' to skip")
    ap.add_argument("--source-ref", default=None, help="SOURCE ref/commit to pin")
    ap.add_argument("--source-name", default=None, help="dir name under source/")
    ap.add_argument("--existing-repo", default=None, help="existing instance repo URL (contribute)")
    ap.add_argument("--dir", default=None, help="clone target dir (contribute)")
    ap.add_argument("--worker-model", default=None)
    ap.add_argument("--orchestrator-model", default=None)
    ap.add_argument("--integrator-model", default=None)
    ap.add_argument("--review-model", default=None)
    ap.add_argument("--effort", default=None, help="reasoning effort (opencode variant) for ALL agents; a per-role flag overrides it")
    ap.add_argument("--worker-effort", default=None)
    ap.add_argument("--orchestrator-effort", default=None)
    ap.add_argument("--integrator-effort", default=None)
    ap.add_argument("--review-effort", default=None)
    ap.add_argument("--skip-effort", action="store_true", help="write models without a variant (inherit each provider's default effort)")
    ap.add_argument("--allow-unknown-effort", action="store_true", help="accept an effort that is not a known variant for the chosen model's provider")
    ap.add_argument("--skip-source", action="store_true")
    ap.add_argument("--skip-models", action="store_true")
    ap.add_argument("--product-repo", default=None, help="product repo to create (gh 'owner/name' or git URL); '' to skip")
    ap.add_argument("--product-dir", default=None, help="local checkout dir for the product (sibling of the workbench)")
    ap.add_argument("--skip-product", action="store_true")
    ap.add_argument("--force-reinstance", action="store_true", help="allow flipping a clone that is already an instance (advanced; can repoint remotes)")
    ap.add_argument("--replace-opencode-json", action="store_true", help="overwrite an existing opencode.json that is not a valid JSON object")
    ap.add_argument("--allow-unknown-model", action="store_true", help="accept a --*-model id that `opencode models` does not list")
    _opts = ap.parse_args()

    banner()
    print("  %sset up a port the right way%s%s\n" % (C["d"], C["0"], "   [dry-run - nothing will change]" if _opts.dry_run else ""))
    preflight()
    state = detect_state()

    mode = _opts.mode
    if mode is None:
        if not _interactive():
            die("non-interactive: pass --mode new|contribute")
        print("\n  Are you starting a NEW port, or CONTRIBUTING to one someone already started?")
        print("    1) new        - flip this clone into your own port instance")
        print("    2) contribute - clone and join an existing port instance")
        while mode is None:
            sel = input("  choose [1/2]: ").strip()
            mode = "new" if sel == "1" else "contribute" if sel == "2" else None
            if mode is None:
                warn("enter 1 (new) or 2 (contribute).")
    if mode == "new":
        flow_new(state)
    else:
        flow_contribute(state)


if __name__ == "__main__":
    main()
