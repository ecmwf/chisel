#!/usr/bin/env python3
"""chisel-init - set up a port the right way, interactively.

Two situations it handles:
  * NEW project        - you are starting a fresh port. This clone of the chisel BASE repo is
                         flipped into your own port instance (the workbench, where all state and
                         lessons persist): the base becomes `upstream`, your new repo becomes
                         `origin`, the layer merge drivers are set, and main is pushed. You may
                         also point it at the SOURCE program's repo, which it clones into source/
                         and imports (pinned, nested .git removed) ready for the charter.
  * CONTRIBUTE         - someone already started the port (its workbench is an existing repo).
                         This clones that instance for you and wires `upstream` -> the base plus
                         the merge drivers, so you can sync base improvements while you work.

In both, it parses `opencode models` and configures each agent's model, writing them to a
per-instance opencode.json - the authoritative, instance-owned source of per-agent models (the
agents carry no model in their base-owned frontmatter, so a /port-sync-with-base never clobbers
your choice). Defaults, when available: Kha-Worker ->
anthropic/claude-sonnet-4-6 (a capable, lower-cost model for the many parallel workers);
Ptah-Orchestrator + Seshat-Integrator -> anthropic/claude-opus-4-8; port-review -> openai/gpt-5.5
(a reviewer model distinct from the worker it reviews is a stronger independence control than a
different session alone).

It REPORTS each step and ASKS before anything that writes, clones, or pushes. Re-runnable and
non-destructive: it detects existing remotes/sources and skips rather than clobbering.

Usage:
  tools/chisel-init.py                         # interactive, run from a chisel clone
  tools/chisel-init.py --dry-run               # show every step, change nothing
  tools/chisel-init.py --mode new --new-repo me/port-foo --source-repo URL --source-ref TAG
  tools/chisel-init.py --mode contribute --existing-repo URL --dir ../port-foo
  Flags: --non-interactive --yes --skip-source --skip-models
         --worker-model M --orchestrator-model M --integrator-model M --review-model M
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


def run(cmd, mutating=True, cwd=None, check=True, capture=False):
    """Run a command. In --dry-run, mutating commands are echoed and skipped; reads still run."""
    shown = " ".join(cmd) + (" (in %s)" % cwd if cwd else "")
    if _opts.dry_run and mutating:
        print("  %s[dry-run]%s would run: %s" % (C["d"], C["0"], shown))
        return subprocess.CompletedProcess(cmd, 0, "", "")
    info("run: %s" % shown)
    res = subprocess.run(cmd, cwd=cwd, text=True,
                         capture_output=capture, stdout=None if not capture else subprocess.PIPE,
                         stderr=None if not capture else subprocess.PIPE)
    if check and res.returncode != 0:
        die("command failed (%d): %s" % (res.returncode, shown))
    return res


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


def select_models():
    section("Agent models")
    if _opts.skip_models:
        info("--skip-models: leaving agent models unset (inherit the global default)")
        return None
    avail = list_models()
    if not avail:
        warn("`opencode models` returned nothing usable - skipping; set agent models in opencode.json later")
        return None
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
        if rec in avail:
            if confirm("%s: use recommended %s?" % (label, rec), True):
                chosen[name] = rec
            else:
                chosen[name] = pick_model(avail, provider) if _interactive() else rec
        else:
            warn("%s: recommended %s is not available here" % (label, rec))
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
    return chosen


def write_opencode_json(target_dir, chosen):
    if not chosen or not any(chosen.values()):
        info("no agent models chosen; not writing opencode.json")
        return
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
    raw_agent = cfg.get("agent")
    agent = raw_agent if isinstance(raw_agent, dict) else {}
    for name, model in chosen.items():
        if model:
            raw_entry = agent.get(name)
            entry = raw_entry if isinstance(raw_entry, dict) else {}
            entry["model"] = model
            agent[name] = entry
    cfg["agent"] = agent
    text = json.dumps(cfg, indent=2) + "\n"
    if _opts.dry_run:
        print("  %s[dry-run]%s would write %s:\n%s" % (C["d"], C["0"], path, text))
        return
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    ok("wrote %s (authoritative per-agent model source; instance-owned, survives a base sync)" % path)


# ---- SOURCE import -----------------------------------------------------------------------

def import_source(top):
    if _opts.skip_source:
        return
    section("SOURCE program")
    src = _opts.source_repo if _opts.source_repo is not None else ask(
        "SOURCE repo to port (git URL or local path; blank to skip for now)", default="")
    if not src:
        info("no SOURCE given; import it later with: git clone ... source/<name> && tools/import-source.sh source/<name>")
        return
    default_name = re.sub(r"\.git$", "", os.path.basename(src.rstrip("/"))) or "source-program"
    name = _opts.source_name or ask("directory name under source/", default=default_name)
    if not re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", name) or name in (".", "..") or name.endswith(".git"):
        die("source name '%s' must be a single safe directory name (letters/digits/._- ; no '/', '..', or '.git')" % name)
    dest = os.path.join("source", name)
    destabs = os.path.join(top, dest)
    if os.path.exists(destabs):
        if os.path.isdir(os.path.join(destabs, ".git")):
            warn("%s already exists WITH a nested .git - a previous import did not finish." % dest)
            info("finish it: tools/import-source.sh %s   (or `rm -rf %s` and re-run to re-import)" % (dest, dest))
        else:
            info("%s already exists (SOURCE looks already imported) - skipping clone/import." % dest)
        return
    ref = _opts.source_ref if _opts.source_ref is not None else ask(
        "ref/commit to pin (tag/branch/sha; blank = default branch)", default="")
    if ref.startswith("-"):
        die("ref '%s' may not start with '-'" % ref)
    if not confirm("Clone %s into %s%s and import (remove nested .git)?" % (src, dest, (" @ " + ref) if ref else "")):
        info("skipped SOURCE import")
        return
    run(["git", "clone", src, dest], cwd=top)
    if ref:
        run(["git", "-C", dest, "checkout", ref], cwd=top)
    run(["bash", "tools/import-source.sh", dest], cwd=top)
    info("SOURCE imported but NOT committed - record the printed provenance in port/plan/00-charter.md")
    info("and port/TRACE.yaml, then stage it yourself (git operations + the charter are the human's).")


# ---- flows -------------------------------------------------------------------------------

def preflight_target(new_repo):
    """Before the irreversible flip, confirm the target repo is REACHABLE (a git URL) or
    CREATABLE (a gh name + an authenticated gh), so a push/create failure does not leave a
    half-flipped clone with its remotes already renamed."""
    if _opts.dry_run:
        return
    if new_repo.startswith(("http", "git@", "ssh://")):
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


def flow_new(state):
    section("New port  (flip this clone into your port instance)")
    if not state["is_chisel"]:
        die("this is not a chisel base clone - clone the base repo, then run this from it")
    base = state["base"] or state["origin"]
    if not base:
        die("cannot determine the base repo (no origin, no tools/base-repo.txt)")
    already = bool(state["upstream"]) or bool(state["origin"] and _norm_url(state["origin"]) != _norm_url(base))
    if already and not _opts.force_reinstance:
        die("this clone is already an instance (upstream=%s, origin=%s); re-flipping would repoint "
            "remotes at the wrong repo.\n     Start a NEW port from a fresh base clone, or pass "
            "--force-reinstance if you truly intend to re-flip." % (state["upstream"] or "(none)", state["origin"] or "(none)"))
    if already:
        warn("already an instance, but --force-reinstance given - proceeding (this can repoint remotes)")
    new_repo = _opts.new_repo or ask(
        "New port-instance repo - a gh name 'me/port-foo' (uses gh) OR a git URL you created", required=True)
    if "/" not in new_repo:
        die("new-repo must be 'owner/name' (gh) or a git URL")
    preflight_target(new_repo)
    if confirm("Flip this clone into instance '%s' (origin->upstream=base, set merge drivers, push main)?" % new_repo):
        run(["bash", "tools/new-instance.sh", new_repo], cwd=state["top"])
    else:
        die("aborted before creating the instance")
    import_source(state["top"])
    chosen = select_models()
    write_opencode_json(state["top"], chosen)
    section("Done - new port instance")
    ok("workbench (this repo) is your port's home; all state + lessons persist here")
    info("next: author port/plan/00-charter.md (Phase 0), then open a fresh conversation and run /port-sprint-start")


def flow_contribute(state):
    section("Contribute  (join an existing port someone else started)")
    existing = _opts.existing_repo or ask("Existing port-instance repo URL to join", required=True)
    name = re.sub(r"\.git$", "", os.path.basename(existing.rstrip("/"))) or "port-instance"
    dest = _opts.dir or ask("clone into directory", default=os.path.join("..", name))
    destabs = os.path.abspath(dest)
    if os.path.exists(destabs):
        die("%s already exists - choose another --dir or remove it" % dest)
    base = state["base"]
    if not confirm("Clone %s into %s, then wire upstream=base + merge drivers?" % (existing, dest)):
        die("aborted")
    run(["git", "clone", existing, destabs])
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
    chosen = select_models()
    write_opencode_json(destabs, chosen)
    section("Done - joined the port")
    ok("working copy: %s (origin = the shared port; upstream = the base)" % dest)
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
    ap.add_argument("--skip-source", action="store_true")
    ap.add_argument("--skip-models", action="store_true")
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
        sel = input("  choose [1/2]: ").strip()
        mode = "new" if sel == "1" else "contribute" if sel == "2" else die("choose 1 or 2")
    if mode == "new":
        flow_new(state)
    else:
        flow_contribute(state)


if __name__ == "__main__":
    main()
