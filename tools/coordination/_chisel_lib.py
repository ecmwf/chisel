"""Shared helpers for the coordination tools - ONE audited copy of the small primitives that
were otherwise hand-copied into every script (and had begun to drift).

Importable because every coordination tool runs as `python3 tools/coordination/<tool>.py`, so
Python puts this directory on sys.path[0]; the same way autodrive.py imports dashboard. Tools
keep their existing private names by aliasing on import, e.g.
    from _chisel_lib import strict_loader as _strict_loader, repo_root as _repo_root

Only logic-IDENTICAL primitives live here. Deliberately NOT consolidated:
  - `_fail`: each tool prints its own prefix and exits with its own code.
  - `_s`: the dashboard's display form (returns "-", no strip) and the checks' normalize form
    (returns "", strips) are different functions that happen to share a name.
"""
import os
import subprocess


def strict_loader(yaml):
    """A PyYAML SafeLoader that REJECTS duplicate mapping keys. PyYAML's default lets the last
    duplicate win, which would silently hide a conflicting field and break determinism; a
    duplicate key is corruption, so the artifact is treated as malformed instead."""
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


def repo_root():
    """The git working-tree root (cwd-based), falling back to the cwd outside a repo."""
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()
