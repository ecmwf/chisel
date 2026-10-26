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
import unicodedata


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


def text_loader(yaml):
    """strict_loader, except that every scalar that is not null is read as the text written in the
    file: `0001` stays '0001', `yes` stays 'yes' and a commit id stays a string, instead of turning
    into a number, a bool or a date. For a reader that prints values or compares them as text, such
    as yaml_get.py and the conformance checks. Anchors and aliases resolve as usual, so an alias
    reads as the value it points to."""
    class TextLoader(strict_loader(yaml)):
        pass

    def as_text(loader, node):
        return loader.construct_scalar(node)

    for tag in ("bool", "int", "float", "timestamp"):
        TextLoader.add_constructor("tag:yaml.org,2002:" + tag, as_text)
    return TextLoader


def control_char(text):
    """The first control character in `text` other than a tab (U+0000-U+001F, U+007F-U+009F), or
    None. A YAML escape such as "\\0" puts one in a value, and a shell that receives the value drops
    or splits on it, so a reader refuses such a value rather than hand it on."""
    for ch in text:
        if ch != "\t" and unicodedata.category(ch) == "Cc":
            return ch
    return None


# The unit vocabulary changed from 'gate / gated' to 'proof / proven'. Ports that have not yet run
# tools/migrate-proof-vocabulary.py still hold the old names in their state files, so every reader
# maps them on load; writers emit only the new names. This table is the one place that lists them.
LEGACY_KEYS = {"gate": "proof", "gate_tier": "proof_tier", "gate_commit": "proof_commit"}
LEGACY_VALUES = {"status": {"gated": "proven"}, "state": {"gated": "proven"},
                 "integration": {"gated": "proven"}, "kind": {"gate": "proof"}}
LEGACY_STRINGS = {"mark-gated": "mark-proven"}


class VocabularyConflict(ValueError):
    """A record holds the same field under both its old and its new name."""


def modern(value):
    """Return parsed YAML with the old vocabulary mapped to the new: keys gate / gate_tier /
    gate_commit become proof / proof_tier / proof_commit, the value 'gated' of status, state and
    integration becomes 'proven', kind
    'gate' becomes 'proof', and the planner action 'mark-gated' becomes 'mark-proven'. A mapping
    that holds a field under both names is ambiguous, so it raises VocabularyConflict rather than
    silently preferring one."""
    if isinstance(value, dict):
        out = {}
        for key, item in value.items():
            new_key = LEGACY_KEYS.get(key, key) if isinstance(key, str) else key
            if new_key in out or (new_key != key and new_key in value):
                raise VocabularyConflict("both %r and %r are set" % (key, new_key))
            item = modern(item)
            if isinstance(item, str) and new_key in LEGACY_VALUES:
                item = LEGACY_VALUES[new_key].get(item, item)
            out[new_key] = item
        return out
    if isinstance(value, list):
        return [modern(item) for item in value]
    if isinstance(value, str):
        return LEGACY_STRINGS.get(value, value)
    return value


def repo_root():
    """The git working-tree root (cwd-based), falling back to the cwd outside a repo."""
    try:
        return subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                                       stderr=subprocess.DEVNULL).decode().strip()
    except Exception:
        return os.getcwd()
