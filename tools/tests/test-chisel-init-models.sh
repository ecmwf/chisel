#!/usr/bin/env bash
# chisel-init's agent models, against a stub opencode that serves a fixed model catalog: each role
# defaults to the newest model of its family (a deprecated one never, a -fast twin of the same date
# never), written in the opencode 2 shape `agents.<role>.model = "provider/model#effort"`; an effort
# must be one the chosen model offers (asked for by flag: init stops; a default it lacks: left out);
# an earlier run's opencode 1 entries (`agent`, `variant`) move over, other settings stay; a role
# left without a model loses an earlier run's; when opencode cannot be asked, models are skipped. Each case runs init in --dry-run on a throwaway
# instance and reads the opencode.json it would write.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat >"$TMP/bin/opencode" <<'SH'
#!/usr/bin/env bash
# `opencode api get /api/model?...` prints $OPENCODE_STUB_CATALOG; anything else fails.
if [ "${1:-} ${2:-}" = "api get" ] && [[ "${3:-}" == /api/model\?* ]]; then
	cat "$OPENCODE_STUB_CATALOG"
	exit
fi
exit 1
SH
chmod +x "$TMP/bin/opencode"
export PATH="$TMP/bin:$PATH" NO_COLOR=1

python3 - "$TMP/catalog.json" <<'PY'
import json, sys
E = ["low", "medium", "high", "xhigh", "max"]
def m(provider, mid, family, released, efforts=E, status="active"):
    return {"providerID": provider, "id": mid, "family": family, "time": {"released": released},
            "status": status, "enabled": True, "variants": [{"id": e} for e in efforts]}
data = [
    m("anthropic", "claude-sonnet-4-6", "claude-sonnet", 100, ["low", "medium", "high", "max"]),
    m("anthropic", "claude-sonnet-5-5", "claude-sonnet", 300),
    m("anthropic", "claude-opus-4-8", "claude-opus", 200),
    m("anthropic", "claude-opus-5-5-fast", "claude-opus", 250),
    m("anthropic", "claude-opus-5-5", "claude-opus", 250),
    m("openai", "gpt-6-sol", "gpt-sol", 240),
    m("openai", "gpt-6.1-sol-ultrafast", "gpt-sol", 260),
    m("openai", "gpt-6.1-sol", "gpt-sol", 260),
    m("openai", "gpt-9-sol", "gpt-sol", 999, status="deprecated"),
    m("google", "gemma-x", "gemma", 50, ["none", "thinking"]),
]
json.dump({"location": {"directory": "/x"}, "data": data}, open(sys.argv[1], "w"))
PY
printf '{"_tag":"LocationNotFoundError","message":"Location not found"}\n' >"$TMP/broken.json"

n=0
# run <label> <catalog> <existing opencode.json or ''> <want exit> <python check> [init flags...]
run() {
	local label="$1" catalog="$2" existing="$3" want_rc="$4" check="$5"
	shift 5
	local repo out rc
	n=$((n + 1))
	repo="$TMP/r$n"
	mkdir -p "$repo/tools" "$repo/.opencode/skill/code-port"
	cp "$ROOT/tools/chisel-init.py" "$repo/tools/"
	: >"$repo/.opencode/skill/code-port/SKILL.md"
	printf '%s\n' https://github.com/acme/chisel.git >"$repo/tools/base-repo.txt"
	git -C "$repo" init -q
	git -C "$repo" remote add origin git@github.com:me/port-foo.git
	git -C "$repo" remote add upstream https://github.com/acme/chisel.git
	[ -z "$existing" ] || printf '%s\n' "$existing" >"$repo/opencode.json"
	set +e
	out="$(cd "$repo" && OPENCODE_STUB_CATALOG="$catalog" python3 tools/chisel-init.py --mode new \
		--dry-run --non-interactive --yes --skip-source --skip-product "$@" 2>&1)"
	rc=$?
	set -e
	if [ "$rc" -ne "$want_rc" ] || ! OUT="$out" python3 -c "
import json, os, sys
out = os.environ['OUT']
i = out.find('models in opencode.json:')
cfg = json.JSONDecoder().raw_decode(out[out.index('{', i):])[0] if i >= 0 else None
agents = {k: v.get('model') for k, v in ((cfg or {}).get('agents') or {}).items()}
sys.exit(0 if ($check) else 1)
"; then
		printf 'not ok - %s (exit %s, wanted %s)\n%s\n' "$label" "$rc" "$want_rc" "$out" >&2
		exit 1
	fi
	printf 'ok - %s\n' "$label"
}

C="$TMP/catalog.json"
run "defaults: the newest of each family, effort high, opencode 2 shape" "$C" "" 0 \
	"agents == {'kha-worker': 'anthropic/claude-sonnet-5-5#high', 'ptah-orchestrator': 'anthropic/claude-opus-5-5#high',
	 'seshat-integrator': 'anthropic/claude-opus-5-5#high', 'port-review': 'openai/gpt-6.1-sol#high'} and 'agent' not in cfg"
run "an effort the model offers, asked for one role" "$C" "" 0 \
	"agents['port-review'] == 'openai/gpt-6.1-sol#max' and agents['kha-worker'].endswith('#high')" --model port-review=openai/gpt-6.1-sol#max
run "an effort the model does not offer stops init and names the ones it does" "$C" "" 2 \
	"\"offers no effort 'bogus'\" in out and 'low, medium, high, xhigh, max' in out" --model kha-worker=anthropic/claude-sonnet-5-5#bogus
run "a chosen model without the default effort is written without one" "$C" "" 0 \
	"agents['kha-worker'] == 'google/gemma-x' and 'none, thinking' in out" --model kha-worker=google/gemma-x
run "--skip-effort writes the models alone" "$C" "" 0 \
	"agents['kha-worker'] == 'anthropic/claude-sonnet-5-5' and not any('#' in m for m in agents.values())" --skip-effort
run "an earlier run's opencode 1 entries move over; other settings stay" "$C" \
	'{"theme": "x", "agent": {"kha-worker": {"model": "anthropic/claude-sonnet-4-6", "variant": "high"}, "port-review": {"model": "a/b", "variant": "high", "steps": 5}}}' 0 \
	"cfg['theme'] == 'x' and cfg['agent'] == {'port-review': {'steps': 5}} and agents['kha-worker'] == 'anthropic/claude-sonnet-5-5#high'"
python3 -c "
import json, sys
d = json.load(open(sys.argv[1])); d['data'] = [m for m in d['data'] if m['family'] != 'claude-sonnet']
json.dump(d, open(sys.argv[2], 'w'))" "$C" "$TMP/no-sonnet.json"
run "a role left without a model loses an earlier run's; its other settings stay" "$TMP/no-sonnet.json" \
	'{"agents": {"kha-worker": {"model": "anthropic/claude-sonnet-4-6#high", "steps": 9}}}' 0 \
	"cfg['agents']['kha-worker'] == {'steps': 9} and agents['ptah-orchestrator'] == 'anthropic/claude-opus-5-5#high'"
run "a --model that is not ROLE=provider/model stops init and names the agents" "$C" "" 2 \
	"'kha-worker, ptah-orchestrator, seshat-integrator, port-review' in out" --model worker=anthropic/claude-sonnet-5-5
run "a broken opencode.json stops init, untouched" "$C" '{"agents": {' 2 \
	"'fix it or delete it' in out and not agents"
run "opencode cannot be asked: models are skipped, init goes on" "$TMP/broken.json" "" 0 \
	"\"could not read opencode's model list\" in out and not agents"

printf '# test-chisel-init-models: all %d cases passed\n' "$n"
