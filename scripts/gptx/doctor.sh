#!/usr/bin/env bash
# gptx-doctor.sh — health probe + certification for the gptx router (spec 020).
#
# Public health probe. It prints no credentials.
#
# Probes, in the order failures cascade:
#   1. router up on 127.0.0.1:8318 and answering /__gptx/status
#   2. Anthropic lane end-to-end through the REAL claude client (also teaches the
#      router this build's version + anthropic-beta set, which certification records)
#   3. GPT lane: a plain completion
#   4. GPT lane: a tool-call round-trip      <- catches translation drift
#   5. GPT lane: a structured-output turn    <- catches translation drift
#   6. GPT lane: advisor server-tool bridge  <- catches fork/router drift
#   7. GPT lane: immediate post-advisor completion
#
# Probes 1-2 alone would go green on a broken upgrade; 4-5 are the ones that bite.
#
# `--certify` runs all five and, on green, records the baseline that clears the
# router's `unverified` state. Read-only without it.
#
# Exit: 0 all green (warnings allowed), 1 any check failed, 2 GPT lane unavailable
# for quota/cooldown reasons (distinct on purpose: that is not an upgrade break and
# must not be mistaken for one).

set -uo pipefail

ROUTER="http://127.0.0.1:8318"
MODEL="${GPTX_MODEL:-gpt-5.6-sol}"
BASELINE="$HOME/.cli-proxy-api/gptx-baseline.json"
MANIFEST="${TRELLIS_GPTX_MANIFEST:-$HOME/.trellis/gptx-install.json}"
GLOBAL_CLAUDE="$HOME/.claude/CLAUDE.md"
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  SOURCE_DIR=$(unset CDPATH; cd -P -- "$(dirname -- "$SOURCE")" && pwd)
  SOURCE=$(readlink "$SOURCE")
  case "$SOURCE" in /*) ;; *) SOURCE="$SOURCE_DIR/$SOURCE" ;; esac
done
REPO_ROOT=$(unset CDPATH; cd -- "$(dirname -- "$SOURCE")/../.." && pwd)
SETTINGS="$REPO_ROOT/scripts/gptx/settings-router.json"
CERTIFY=0
FAIL=0
QUOTA=0
[ "${1:-}" = "--certify" ] && CERTIFY=1

ok()    { printf 'OK    %s\n' "$1"; }
fail()  { printf 'FAIL  %s\n' "$1"; FAIL=1; }
quota() { printf 'QUOTA %s\n' "$1"; QUOTA=1; }
warn()  { printf 'WARN  %s\n' "$1"; }

# GPT-lane call. Sets the globals $BODY and $HTTP — deliberately not echoed, because
# a `BODY=$(gpt_call ...)` capture would run this in a subshell and lose $HTTP.
BODY=""
HTTP=""
gpt_call() {
  local payload="$1" advisor="${2:-}" timeout="${3:-180}" out
  if [ -n "$advisor" ]; then
    out=$(curl -s -m "$timeout" -w '\n%{http_code}' -X POST "$ROUTER/v1/messages" \
      -H 'content-type: application/json' \
      -H "X-Trellis-Advisor: $advisor" \
      -d "$payload" 2>/dev/null)
  else
    out=$(curl -s -m "$timeout" -w '\n%{http_code}' -X POST "$ROUTER/v1/messages" \
      -H 'content-type: application/json' -d "$payload" 2>/dev/null)
  fi
  HTTP="${out##*$'\n'}"
  BODY="${out%$'\n'*}"
}

top_level_yaml_value() {
  local file="$1" key="$2"
  awk -v key="$key" '$0 ~ ("^" key ":[[:space:]]*") { print $2; exit }' "$file"
}

# Preflight policy. These checks are local and secret-free.
PROXY_CONFIG=""
if [ -f "$MANIFEST" ]; then
  PROXY_CONFIG=$(jq -r '.proxy_config // empty' "$MANIFEST" 2>/dev/null)
fi
if [ -z "$PROXY_CONFIG" ] && [ -f /opt/homebrew/etc/cliproxyapi.conf ]; then
  PROXY_CONFIG=/opt/homebrew/etc/cliproxyapi.conf
fi
if [ -n "$PROXY_CONFIG" ] && [ -f "$PROXY_CONFIG" ]; then
  PROXY_RETRY=$(top_level_yaml_value "$PROXY_CONFIG" request-retry)
  PROXY_DISABLE_COOLING=$(top_level_yaml_value "$PROXY_CONFIG" disable-cooling)
  PROXY_TRANSIENT=$(top_level_yaml_value "$PROXY_CONFIG" transient-error-cooldown-seconds)
  if [ "$PROXY_RETRY" = 1 ] \
    && [ "$PROXY_DISABLE_COOLING" = false ] \
    && [ "$PROXY_TRANSIENT" = -1 ]; then
    ok "proxy recovery policy (one retry, transient cooldown off, quota cooling on)"
  else
    fail "proxy recovery policy is stale — rerun scripts/gptx/install.sh (request-retry=$PROXY_RETRY, disable-cooling=$PROXY_DISABLE_COOLING, transient=$PROXY_TRANSIENT)"
  fi
else
  fail "proxy config not found through $MANIFEST or /opt/homebrew/etc/cliproxyapi.conf"
fi

if [ -f "$GLOBAL_CLAUDE" ] \
  && grep -qE "GPT agents cannot use the built-in|Keep orchestration, planning, and merge decisions on Claude" "$GLOBAL_CLAUDE"; then
  warn "obsolete pre-bridge GPTX policy in $GLOBAL_CLAUDE — follow AGENT_ONBOARD_GPTX.md#upgrade-existing-private-gptx-instructions"
else
  ok "global instructions do not disable the bridged GPT advisor"
fi

# A GPT probe that is unavailable for quota reasons is reported as QUOTA, never FAIL:
# the translation surface is untested, not broken, and certification must refuse either
# way — but only one of the two means "an upgrade broke us".
classify_gpt() {
  local label="$1" body="$2" expect="$3"
  if [ "$HTTP" = "200" ] && printf '%s' "$body" | grep -q "$expect"; then
    ok "$label"
  elif printf '%s' "$body" | grep -qE 'auth_unavailable|no auth available|quota|rate.?limit'; then
    quota "$label — codex auth unavailable (quota/cooldown), not a translation break"
  else
    fail "$label — http=$HTTP $(printf '%s' "$body" | head -c 180)"
  fi
}

# 0. routing table, offline. The live probes below all send `gpt-5.6-sol`, so they
# stay green on a router whose predicate has been broken by an edit. This is the only
# check that would catch a misroute — in particular a `claude-*` id being handed to
# Codex, which surfaces as a model error rather than a routing one.
# shellcheck disable=SC2016  # the JS body is deliberately unexpanded; root arrives via env
if GPTX_ROOT="$REPO_ROOT" node -e '
const { laneFor } = require(process.env.GPTX_ROOT + "/scripts/gptx/lanes");
const table = [
  ["gpt-5.6-sol", "codex"], ["gpt-5.4-mini", "codex"], ["gpt-5.6-terra", "codex"],
  ["codex-auto-review", "codex"], ["o3-mini", "codex"],
  ["claude-opus-5", "anthropic"], ["claude-sonnet-5", "anthropic"],
  ["claude-fable-5", "anthropic"], ["claude-haiku-4-5-20251001", "anthropic"],
  ["claude-haiku-4-5-20251001-sol", "anthropic"],   // adversarial: -sol suffix on a Claude id
  [" claude-haiku-4-5-20251001-sol", "anthropic"], // leading space must not defeat the guard
  ["claude-opus-5 ", "anthropic"],          // trailing space
  ["ｃlaude-opus-5-sol", "anthropic"],   // fullwidth c: NFKC folds it back to claude-
  ["", "anthropic"], [null, "anthropic"], ["something-unknown", "anthropic"],
];
const bad = table.filter(([m, want]) => laneFor(m) !== want);
if (bad.length) {
  console.error(bad.map(([m, w]) => `  ${JSON.stringify(m)} -> ${laneFor(m)} (want ${w})`).join("\n"));
  process.exit(1);
}
' 2>/tmp/gptx-lanes.err; then
  ok "routing table (15 cases, incl. claude-*-sol adversarial)"
else
  fail "routing predicate is wrong:"; cat /tmp/gptx-lanes.err
fi
rm -f /tmp/gptx-lanes.err

# 1. router reachable
STATUS_JSON=$(curl -s -m 3 "$ROUTER/__gptx/status" 2>/dev/null)
if [ -n "$STATUS_JSON" ]; then
  ok "router answering on ${ROUTER#http://}"
else
  fail "router not answering on ${ROUTER#http://} — launchctl kickstart -k gui/$(id -u)/dev.trellis.gptx-router"
  echo; echo "Router down: every later probe would be meaningless. Stopping."
  exit 1
fi

# 2. Anthropic lane through the real client (populates version + beta set)
if [ -f "$SETTINGS" ]; then
  CLAUDE_OUT=$(cd "$REPO_ROOT" && env -u ANTHROPIC_BASE_URL claude --settings "$SETTINGS" \
    -p 'Reply with exactly: GPTX_LANE_OK' < /dev/null 2>&1 | tail -3)
  if printf '%s' "$CLAUDE_OUT" | grep -q 'GPTX_LANE_OK'; then
    ok "Anthropic lane end-to-end via claude-cli (subscription OAuth intact)"
  else
    fail "Anthropic lane probe failed: $(printf '%s' "$CLAUDE_OUT" | head -c 200)"
  fi
else
  fail "missing $SETTINGS — cannot probe the Anthropic lane through the real client"
fi

# 3. GPT lane: plain completion
gpt_call '{"model":"'"$MODEL"'","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"Reply with exactly: OK"}]}'
classify_gpt "GPT lane completion" "$BODY" 'content_block_delta\|message_start'

# 4. GPT lane: tool-call round-trip
gpt_call '{"model":"'"$MODEL"'","max_tokens":256,"stream":true,
  "tools":[{"name":"get_weather","description":"Get weather for a city","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}],
  "tool_choice":{"type":"tool","name":"get_weather"},
  "messages":[{"role":"user","content":"Weather in Bengaluru?"}]}'
classify_gpt "GPT lane tool-call round-trip" "$BODY" 'tool_use'

# 5. GPT lane: structured output (schema-constrained turn)
gpt_call '{"model":"'"$MODEL"'","max_tokens":256,"stream":true,
  "tools":[{"name":"StructuredOutput","description":"Return the answer","input_schema":{"type":"object","properties":{"answer":{"type":"number"}},"required":["answer"]}}],
  "tool_choice":{"type":"tool","name":"StructuredOutput"},
  "messages":[{"role":"user","content":"What is 6 times 7? Use the tool."}]}'
classify_gpt "GPT lane structured output" "$BODY" 'StructuredOutput'

# 6. GPT lane: force the advisor tool and require the fork's two server-tool blocks.
gpt_call '{"model":"'"$MODEL"'","max_tokens":512,"stream":true,
  "tools":[{"type":"advisor_20260301","name":"advisor"}],
  "tool_choice":{"type":"tool","name":"advisor"},
  "messages":[{"role":"user","content":"Use the advisor once, then follow its recommendation."}]}' sol 330
if [ "$HTTP" = "200" ] \
  && printf '%s' "$BODY" | grep -q 'server_tool_use' \
  && printf '%s' "$BODY" | grep -q 'advisor_tool_result' \
  && printf '%s' "$BODY" | grep -Fq "Trellis advisor model: $MODEL"; then
  ok "GPT lane advisor server-tool bridge (actual model receipt: $MODEL)"
elif printf '%s' "$BODY" | grep -qE 'auth_unavailable|no auth available|quota|rate.?limit'; then
  quota "GPT lane advisor server-tool bridge — provider quota unavailable"
else
  fail "GPT lane advisor server-tool bridge — http=$HTTP $(printf '%s' "$BODY" | head -c 180)"
fi

# 7. A successful or failed advisor attempt must not make the only Codex credential
# ineligible for an unrelated turn.
gpt_call '{"model":"'"$MODEL"'","max_tokens":16,"stream":true,"messages":[{"role":"user","content":"Reply with exactly: RECOVERY_OK"}]}'
classify_gpt "GPT lane available immediately after advisor" "$BODY" 'content_block_delta\|message_start'

# 8. Agent slug vs running router. Every gpt-* profile declares a `model:` slug in
# its frontmatter; the RUNNING router must know it. These drift apart silently: the
# repo can gain an alias (making a profile's effort real rather than cosmetic) while
# the installed router predates it, and the only symptom is a 502 at the moment an
# operator delegates. Observed 2026-07-30: gpt-terra.md moved to
# `gpt-5.6-terra-xhigh` in rc.18, and the running router answered
# `502 unknown provider for model gpt-5.6-terra-xhigh` while every sol alias was fine.
# Checked offline against the router's own alias table — no provider call, so this
# stays green on a quota cooldown and costs nothing.
AGENTS_DIR="$(cd "$(dirname "$0")/../.." && pwd)/core-rules/agents"
LIVE_ALIASES=$(printf '%s' "$STATUS_JSON" | python3 -c \
  'import json,sys;d=json.load(sys.stdin);print(" ".join(d["aliases"]) if isinstance(d.get("aliases"),list) else "")' 2>/dev/null || echo "")
if [ ! -d "$AGENTS_DIR" ]; then
  :
elif [ -z "$LIVE_ALIASES" ]; then
  # The running process predates alias reporting, so the comparison is impossible
  # rather than failing. Warn — this is precisely the stale-but-healthy state that
  # `state: ok` cannot distinguish from current.
  warn "running router does not report its alias table — it predates this check, so agent slugs cannot be verified against it. Restart to enable: launchctl kickstart -k gui/$(id -u)/dev.trellis.gptx-router"
else
  UNKNOWN=""
  for af in "$AGENTS_DIR"/gpt-*.md; do
    [ -f "$af" ] || continue
    slug=$(sed -n 's/^model:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$af" | head -1)
    [ -n "$slug" ] || continue
    case " $LIVE_ALIASES " in
      *" $slug "*) ;;
      *) UNKNOWN="$UNKNOWN $(basename "$af")=$slug" ;;
    esac
  done
  if [ -n "$UNKNOWN" ]; then
    fail "agent slug unknown to the RUNNING router —$UNKNOWN. Delegating to that profile returns 502 'unknown provider'. The router process is older than the checkout; restart it: launchctl kickstart -k gui/$(id -u)/dev.trellis.gptx-router"
  else
    ok "every gpt-* agent slug is served by the running router"
  fi
fi

# --- report / certify -------------------------------------------------------
echo
STATE=$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["state"])' 2>/dev/null || echo unknown)
DRIFT=$(printf '%s' "$STATUS_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("drift") or "-")' 2>/dev/null || echo -)
echo "router state: $STATE${DRIFT:+  (drift: $DRIFT)}"

if [ "$CERTIFY" -eq 1 ]; then
  if [ "$FAIL" -ne 0 ] || [ "$QUOTA" -ne 0 ]; then
    echo "NOT CERTIFIED — every probe must pass first. Baseline left unchanged."
  else
    SNAP=$(mktemp -t gptx-status)
    curl -s -m 3 "$ROUTER/__gptx/status" > "$SNAP"
    python3 - "$BASELINE" "$SNAP" <<'PY'
import json, sys, datetime
s = json.load(open(sys.argv[2]))
json.dump({
    "cliVersion": s.get("cliVersion"),
    "betas": s.get("betas", []),
    "betaHash": s.get("betaHash"),
    "certifiedAt": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
}, open(sys.argv[1], "w"), indent=2)
print(f'certified: claude-cli {s.get("cliVersion")} / {len(s.get("betas", []))} beta flags -> {sys.argv[1]}')
PY
    rm -f "$SNAP"
  fi
fi

[ "$FAIL" -ne 0 ] && exit 1
[ "$QUOTA" -ne 0 ] && exit 2
exit 0
