#!/usr/bin/env bats
# Cross-family pi review route in lib/code-reviewer.sh and Herdr SessionStart
# writer authority. The retired omp-review-route suite is deleted; these cases
# prove the ported deciding-artifact contract against ~/.trellis/state.

load helpers

assert_valid_findings() {
  if command -v jq >/dev/null 2>&1; then
    echo "$output" | jq -e 'type == "object" and (.findings | type == "array")' >/dev/null
  else
    [[ "$output" == *'{"findings":'* ]] || { echo "$output"; false; }
  fi
}

LIB="$HOOKS_DIR/lib/code-reviewer.sh"
HOOK="$HOOKS_DIR/code-review-subagent.sh"
SESSION_HOOK="$HOOKS_DIR/herdr-foreman-session.sh"

REVIEW_INPUT='diff --git a/fixture.txt b/fixture.txt
--- a/fixture.txt
+++ b/fixture.txt
@@ -0,0 +1 @@
+fixture reviewer input'

make_tombstone_claude() {
  local dir stub
  dir="$(mktemp -d "$BATS_TMPDIR/piclaude.XXXXXX")"
  stub="$dir/claude"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "CLAUDE_REACHED\\n" >> "%s"\n' "$TOMBSTONE"
    printf 'printf \x27{"findings":[]}\x27\\n'
  } >"$stub"
  chmod +x "$stub"
  printf '%s' "$dir"
}

make_pi_stub() {
  local dir out="$1"
  dir="$(mktemp -d "$BATS_TMPDIR/pistub.XXXXXX")"
  cat >"$dir/pi" <<EOF
#!/usr/bin/env bash
cat >/dev/null
{
  printf 'RAN_PI\n'
  printf 'ARGS'
  printf '\t%s' "\$@"
  printf '\n'
} >> "$out"
printf '{"findings":[]}\n'
EOF
  chmod +x "$dir/pi"
  printf '%s' "$dir"
}

make_session_resolver_stubs() {
  local dir
  dir="$(mktemp -d "$BATS_TMPDIR/resolverstubs.XXXXXX")"
  cat >"$dir/pi" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$dir/herdr" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = agent ] && [ "${2:-}" = list ]; then
  printf '{"result":{"agents":[]}}\n'
  exit 0
fi
exit 64
EOF
  chmod +x "$dir/pi" "$dir/herdr"
  printf '%s' "$dir"
}

make_active_release_policy() {
  local home="$1" release="1.2.3"
  local policy="$home/.trellis/releases/$release/payload/core-rules/skills/herdr-foreman/roles.json"

  mkdir -p "$(dirname "$policy")"
  cp "$HOOKS_DIR/../skills/herdr-foreman/roles.json" "$policy"
  printf '{"active_cli_release":"%s"}\n' "$release" >"$home/.trellis/config.json"
  chmod 600 "$home/.trellis/config.json"
  printf '%s' "$policy"
}

make_usage_stub() {
  local dest="$1"
  cat >"$dest" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({
    "reports": [
        {"provider": "openai-codex", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "xai-oauth", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "opencode-go", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "nous-portal", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "meta", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "antigravity", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "opencode", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "opencode-go-2", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
    ],
    "disabledCredentials": [],
}))
PY
}

make_active_release_resolver() {
  local home="$1" policy resolver
  policy="$(make_active_release_policy "$home")"
  resolver="$(dirname "$policy")/scripts/resolve-roles.py"
  mkdir -p "$(dirname "$resolver")"
  cp "$HOOKS_DIR/../skills/herdr-foreman/scripts/resolve-roles.py" "$resolver"
  make_usage_stub "$(dirname "$resolver")/usage_openusage.py"
  printf '%s' "$resolver"
}

make_deciding_reviewer_state() {
  local home="$1"
  local nonce="${2:-fixture-workspace:fixture-pane:fixture-pass}"
  local workspace="${3:-fixture-workspace}"
  local pane="${4:-fixture-pane}"
  local state="$home/.trellis/state/roles-resolved.json"
  local resolver
  resolver="$(make_active_release_resolver "$home")"

  mkdir -p "$(dirname "$state")"
  python3 - "$resolver" "$home" "$nonce" "$workspace" "$pane" <<'PY'
import contextlib
import importlib.util
import io
import os
import sys

resolver_path, home, nonce, workspace, pane = sys.argv[1:]
os.environ["HOME"] = home
os.environ["TRELLIS_HOME"] = os.path.join(home, ".trellis")
os.environ["HERDR_ENV"] = "1"
os.environ["HERDR_WORKSPACE_ID"] = workspace
os.environ["HERDR_PANE_ID"] = pane
os.environ["HERDR_RESOLUTION_NONCE"] = nonce

usage = {
    "reports": [
        {"provider": "openai-codex", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "xai-oauth", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "opencode-go", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "nous-portal", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "meta", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "antigravity", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "opencode", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
        {"provider": "opencode-go-2", "limits": [{"id": "shared", "amount": {"remainingFraction": 0.9}}]},
    ],
    "disabledCredentials": [],
}

spec = importlib.util.spec_from_file_location("rr", resolver_path)
rr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rr)
rr.load_usage = lambda ttl, fresh, usage_source="openusage": (usage, "fixture")
rr.auth_probe_passes = lambda candidate, cache: True
sys.argv = [resolver_path, "--implementer", "luna"]
with contextlib.redirect_stdout(io.StringIO()):
    rr.main()
PY
  chmod 600 "$state"
  printf '%s' "$state"
}

assert_pi_reviewer_fail_closed() {
  local fake_home="$1"
  local workspace="${2:-fixture-workspace}"
  local pane="${3:-fixture-pane}"
  local marker stub_dir path_backup claude_dir
  marker="$(mktemp "$BATS_TMPDIR/failclosed.XXXXXX")"
  stub_dir="$(make_pi_stub "$marker")"
  path_backup="$PATH"
  claude_dir="$(make_tombstone_claude)"
  export PATH="$stub_dir:$claude_dir:$PATH"
  run env -u CODE_REVIEWER_CMD \
    HOME="$fake_home" TRELLIS_HOME="$fake_home/.trellis" \
    HERDR_ENV=1 HERDR_WORKSPACE_ID="$workspace" HERDR_PANE_ID="$pane" \
    bash "$LIB" <<<"$REVIEW_INPUT"
  export PATH="$path_backup"
  [ "$status" -eq 0 ]
  [[ "$output" == *'{"findings":[]}'* ]] || { echo "GOT:[$output]"; false; }
  grep -q RAN_PI "$marker" && { echo "pi should not have run"; false; }
  [ ! -s "$TOMBSTONE" ] || { cat "$TOMBSTONE"; false; }
  rm -rf "$stub_dir" "$claude_dir"
  rm -f "$marker"
}

setup_tombstone() {
  TOMBSTONE="$(mktemp "$BATS_TMPDIR/tomb.XXXXXX")"
  : >"$TOMBSTONE"
}

teardown_tombstone() {
  [ -n "${TOMBSTONE:-}" ] && rm -f "$TOMBSTONE"
}

@test "pi-review: CODE_REVIEWER_CMD wins before pi" {
  setup_tombstone
  OP_MARKER="$(mktemp "$BATS_TMPDIR/opmark.XXXXXX")"
  dir="$(mktemp -d "$BATS_TMPDIR/oprev.XXXXXX")"
  cat >"$dir/myreviewer" <<EOF
#!/usr/bin/env bash
cat
printf '%s\n' '{"findings":[{"severity":"important","file":"a","line":1,"msg":"from-operator"}]}'
printf "OPERATOR_RAN\n" >>"$OP_MARKER"
EOF
  chmod +x "$dir/myreviewer"

  PATH_BACKUP="$PATH"
  CLAUDE_DIR="$(make_tombstone_claude)"
  PI_MARKER="$(mktemp "$BATS_TMPDIR/nopi.XXXXXX")"
  PI_DIR="$(make_pi_stub "$PI_MARKER")"
  export PATH="$PI_DIR:$CLAUDE_DIR:$PATH"
  run env CODE_REVIEWER_CMD="$dir/myreviewer" HERDR_ENV=1 \
    HERDR_WORKSPACE_ID=fixture-workspace HERDR_PANE_ID=fixture-pane \
    bash "$LIB" <<<"$REVIEW_INPUT"
  export PATH="$PATH_BACKUP"
  rm -rf "$dir" "$CLAUDE_DIR" "$PI_DIR"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"from-operator"'* ]]
  grep -q OPERATOR_RAN "$OP_MARKER"
  rm -f "$OP_MARKER" "$PI_MARKER"
  [ ! -s "$TOMBSTONE" ] || { cat "$TOMBSTONE"; false; }
  teardown_tombstone
}

@test "pi-review: missing deciding artifact fails closed without invoking pi or claude" {
  setup_tombstone
  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  MARKER="$(mktemp "$BATS_TMPDIR/piran.XXXXXX")"
  STUB_DIR="$(make_pi_stub "$MARKER")"

  PATH_BACKUP="$PATH"
  CLAUDE_DIR="$(make_tombstone_claude)"
  export PATH="$STUB_DIR:$CLAUDE_DIR:$PATH"
  run env -u CODE_REVIEWER_CMD \
    HOME="$FAKE_HOME" TRELLIS_HOME="$FAKE_HOME/.trellis" \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=fixture-workspace HERDR_PANE_ID=fixture-pane \
    bash "$LIB" <<<"$REVIEW_INPUT"
  export PATH="$PATH_BACKUP"

  [ "$status" -eq 0 ]
  [[ "$output" == *'{"findings":[]}'* ]] || { echo "GOT:[$output]"; false; }
  grep -q RAN_PI "$MARKER" && { echo "pi should not have run"; false; }
  [ ! -s "$TOMBSTONE" ] || { cat "$TOMBSTONE"; false; }
  rm -rf "$FAKE_HOME" "$STUB_DIR" "$CLAUDE_DIR"
  rm -f "$MARKER"
  teardown_tombstone
}

@test "pi-review: healthy current Herdr artifact uses its resolved model and documented flags" {
  setup_tombstone
  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  STATE="$(make_deciding_reviewer_state "$FAKE_HOME")"
  MODEL="$(python3 - "$STATE" <<'PY'
import json, sys
artifact = json.load(open(sys.argv[1], encoding="utf-8"))
assert artifact["roles"]["reviewer"]["chosen"] is not None
print(artifact["roles"]["reviewer"]["chosen"]["model"])
PY
)"
  MARKER="$(mktemp "$BATS_TMPDIR/piran.XXXXXX")"
  STUB_DIR="$(make_pi_stub "$MARKER")"

  PATH_BACKUP="$PATH"
  CLAUDE_DIR="$(make_tombstone_claude)"
  export PATH="$STUB_DIR:$CLAUDE_DIR:$PATH"
  run env -u CODE_REVIEWER_CMD \
    HOME="$FAKE_HOME" TRELLIS_HOME="$FAKE_HOME/.trellis" \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=fixture-workspace HERDR_PANE_ID=fixture-pane \
    bash "$LIB" <<<"$REVIEW_INPUT"
  export PATH="$PATH_BACKUP"

  [ "$status" -eq 0 ]
  assert_valid_findings
  grep -q RAN_PI "$MARKER"
  grep -qF "$MODEL" "$MARKER"
  grep -q -- '--no-session' "$MARKER"
  grep -q -- '--no-tools' "$MARKER"
  grep -q -- '--no-extensions' "$MARKER"
  grep -q -- '--no-skills' "$MARKER"
  grep -q -- '--no-prompt-templates' "$MARKER"
  grep -q -- '--no-themes' "$MARKER"
  grep -q -- '--no-context-files' "$MARKER"
  grep -q -- '--no-approve' "$MARKER"
  grep -q -- '-p' "$MARKER"
  [ ! -s "$TOMBSTONE" ] || { cat "$TOMBSTONE"; false; }
  rm -rf "$FAKE_HOME" "$STUB_DIR" "$CLAUDE_DIR"
  rm -f "$MARKER"
  teardown_tombstone
}

@test "pi-review: never consumes a deciding artifact outside Herdr" {
  setup_tombstone
  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  STATE="$(make_deciding_reviewer_state "$FAKE_HOME")"
  MARKER="$(mktemp "$BATS_TMPDIR/nonherdr.XXXXXX")"
  STUB_DIR="$(make_pi_stub "$MARKER")"

  PATH_BACKUP="$PATH"
  CLAUDE_DIR="$(make_tombstone_claude)"
  export PATH="$STUB_DIR:$CLAUDE_DIR:$PATH"
  run env -u CODE_REVIEWER_CMD -u HERDR_ENV -u HERDR_WORKSPACE_ID -u HERDR_PANE_ID \
    HOME="$FAKE_HOME" TRELLIS_HOME="$FAKE_HOME/.trellis" \
    bash "$LIB" <<<"$REVIEW_INPUT"
  export PATH="$PATH_BACKUP"

  [ "$status" -eq 0 ]
  grep -q RAN_PI "$MARKER" && { echo "pi should not have run outside Herdr"; false; }
  # Outside Herdr the Claude rung may run; tombstone records that, which is allowed.
  rm -rf "$FAKE_HOME" "$STUB_DIR" "$CLAUDE_DIR"
  rm -f "$MARKER"
  teardown_tombstone
}

@test "pi-review: refuses a policy-consistent resolved Anthropic model" {
  setup_tombstone
  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  STATE="$(make_deciding_reviewer_state "$FAKE_HOME")"
  POLICY="$FAKE_HOME/.trellis/releases/1.2.3/payload/core-rules/skills/herdr-foreman/roles.json"
  python3 - "$STATE" "$POLICY" <<'PY'
import hashlib, json, sys
state_path, policy_path = sys.argv[1:]
with open(policy_path, encoding="utf-8") as source:
    policy = json.load(source)
with open(state_path, encoding="utf-8") as source:
    artifact = json.load(source)
reviewer_agent = artifact["roles"]["reviewer"]["chosen"]["agent"]
policy["agents"][reviewer_agent].update({
    "model": "google-antigravity/claude-opus-9:xhigh",
    "effort": "xhigh",
})
with open(policy_path, "w", encoding="utf-8") as destination:
    json.dump(policy, destination)
with open(policy_path, "rb") as source:
    policy_bytes = source.read()
for candidate in (
    artifact["roles"]["reviewer"]["chosen"],
    *artifact["roles"]["reviewer"]["trail"],
):
    if candidate.get("agent") == reviewer_agent:
        candidate["model"] = "google-antigravity/claude-opus-9:xhigh"
artifact["roles_policy"] = {
    "roles_sha256": hashlib.sha256(policy_bytes).hexdigest(),
    "cache_ttl_seconds": policy["cache_ttl_seconds"],
}
with open(state_path, "w", encoding="utf-8") as destination:
    json.dump(artifact, destination)
PY
  chmod 600 "$STATE"
  assert_pi_reviewer_fail_closed "$FAKE_HOME"
  rm -rf "$FAKE_HOME"
  teardown_tombstone
}

@test "pi-review: rejects a stale deciding artifact" {
  setup_tombstone
  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  STATE="$(make_deciding_reviewer_state "$FAKE_HOME")"
  python3 - "$STATE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    artifact = json.load(source)
artifact["resolved_at"] = "2000-01-01T00:00:00+00:00"
with open(path, "w", encoding="utf-8") as destination:
    json.dump(artifact, destination)
PY
  chmod 600 "$STATE"
  assert_pi_reviewer_fail_closed "$FAKE_HOME"
  rm -rf "$FAKE_HOME"
  teardown_tombstone
}

@test "pi-review: canonical release lookup ignores a foreign high-TTL policy" {
  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  ACTIVE_POLICY="$(make_active_release_policy "$FAKE_HOME")"
  ACTIVE_POLICY_REAL="$(python3 - "$ACTIVE_POLICY" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
)"
  FOREIGN_PROJECT="$(mktemp -d "$BATS_TMPDIR/foreignpolicy.XXXXXX")"
  FOREIGN_POLICY="$FOREIGN_PROJECT/.claude/skills/herdr-foreman/roles.json"
  mkdir -p "$(dirname "$FOREIGN_POLICY")"
  cp "$HOOKS_DIR/../skills/herdr-foreman/roles.json" "$FOREIGN_POLICY"
  python3 - "$FOREIGN_POLICY" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    policy = json.load(source)
policy["cache_ttl_seconds"] = 86400
with open(sys.argv[1], "w", encoding="utf-8") as destination:
    json.dump(policy, destination)
PY

  run env -u TRELLIS_ROOT -u CODEX_PROJECT_DIR \
    HOME="$FAKE_HOME" TRELLIS_HOME="$FAKE_HOME/.trellis" \
    CLAUDE_PROJECT_DIR="$FOREIGN_PROJECT" \
    bash -c 'source "$1"; reviewer_roles_config' -- "$LIB"

  [ "$status" -eq 0 ]
  [ "$output" = "$ACTIVE_POLICY_REAL" ]
  rm -rf "$FAKE_HOME" "$FOREIGN_PROJECT"
}

@test "pi-review: rejects a prefix-only cross-pane artifact" {
  setup_tombstone
  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  STATE="$(make_deciding_reviewer_state \
    "$FAKE_HOME" \
    "this-workspace:this-pane:fixture-pass" \
    "other-workspace" \
    "other-pane")"
  assert_pi_reviewer_fail_closed "$FAKE_HOME" "this-workspace" "this-pane"
  rm -rf "$FAKE_HOME"
  teardown_tombstone
}

@test "pi-review: rejects a non-private deciding artifact mode" {
  setup_tombstone
  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  STATE="$(make_deciding_reviewer_state "$FAKE_HOME")"
  chmod 644 "$STATE"
  assert_pi_reviewer_fail_closed "$FAKE_HOME"
  rm -rf "$FAKE_HOME"
  teardown_tombstone
}

@test "pi-review: rejects an explicitly degraded reviewer" {
  setup_tombstone
  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  STATE="$(make_deciding_reviewer_state "$FAKE_HOME")"
  python3 - "$STATE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    artifact = json.load(source)
reviewer = artifact["roles"]["reviewer"]
reviewer["chosen"] = None
reviewer["trail"] = []
artifact["degraded_roles"] = ["reviewer", "merge_reviewer", "refuter"]
artifact["degraded_verdict_roles"] = ["reviewer", "merge_reviewer", "refuter"]
with open(path, "w", encoding="utf-8") as destination:
    json.dump(artifact, destination)
PY
  chmod 600 "$STATE"
  assert_pi_reviewer_fail_closed "$FAKE_HOME"
  rm -rf "$FAKE_HOME"
  teardown_tombstone
}

@test "herdr session hook writes ~/.trellis/state/roles-resolved.json" {
  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  RELEASE_RESOLVER="$(make_active_release_resolver "$FAKE_HOME")"
  POISON_PROJECT="$(mktemp -d "$BATS_TMPDIR/poisonproject.XXXXXX")"
  POISON_RESOLVER="$POISON_PROJECT/.claude/skills/herdr-foreman/scripts/resolve-roles.py"
  mkdir -p "$(dirname "$POISON_RESOLVER")"
  printf 'raise SystemExit(91)\n' >"$POISON_RESOLVER"
  CLI_DIR="$(make_session_resolver_stubs)"
  ROLE_STATE="$FAKE_HOME/.trellis/state/roles-resolved.json"
  POLICY="$FAKE_HOME/.trellis/releases/1.2.3/payload/core-rules/skills/herdr-foreman/roles.json"

  run env -u CODE_REVIEWER_CMD \
    HOME="$FAKE_HOME" TRELLIS_HOME="$FAKE_HOME/.trellis" \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=fixture-workspace HERDR_PANE_ID=fixture-pane \
    CLAUDE_PROJECT_DIR="$POISON_PROJECT" PATH="$CLI_DIR:$PATH" \
    bash "$SESSION_HOOK"

  [ "$status" -eq 0 ]
  [ -f "$RELEASE_RESOLVER" ]
  [ -f "$ROLE_STATE" ] || { echo "release resolver was not selected: $output"; false; }
  [[ "$output" == *"pi foreman pane"* ]] || { echo "missing pi wording: $output"; false; }
  [[ "$output" == *"Existing pi panes"* ]] || { echo "missing pi panes: $output"; false; }
  python3 - "$ROLE_STATE" "$POLICY" <<'PY'
import hashlib, json, os, stat, sys
state_path, policy_path = sys.argv[1:]
mode = stat.S_IMODE(os.stat(state_path).st_mode)
assert mode == 0o600, oct(mode)
with open(policy_path, "rb") as source:
    policy_bytes = source.read()
with open(state_path, encoding="utf-8") as source:
    artifact = json.load(source)
assert artifact["roles_policy"] == {
    "roles_sha256": hashlib.sha256(policy_bytes).hexdigest(),
    "cache_ttl_seconds": json.loads(policy_bytes)["cache_ttl_seconds"],
}
scope = artifact["resolution_scope"]
assert scope["herdr_workspace_id"] == "fixture-workspace"
assert scope["herdr_pane_id"] == "fixture-pane"
assert scope["implementer"] == "luna"
assert artifact["family_collapse"] == []
PY
  rm -rf "$FAKE_HOME" "$POISON_PROJECT" "$CLI_DIR"
}

@test "code-review-subagent inside Herdr routes to pi, never claude" {
  setup_project_dir
  setup_tombstone
  (
    cd "$PROJECT_DIR" || exit 1
    printf 'def a():\n    return 1\n' >a.py
    printf 'def b():\n    return 2\n' >b.py
    printf 'def c():\n    return 3\n' >c.py
    git add -A
  )

  FAKE_HOME="$(mktemp -d "$BATS_TMPDIR/fakehome.XXXXXX")"
  STATE="$(make_deciding_reviewer_state "$FAKE_HOME")"
  HOME_BACKUP="${HOME:-}"
  TRELLIS_HOME_BACKUP="${TRELLIS_HOME:-}"
  export HOME="$FAKE_HOME"
  export TRELLIS_HOME="$FAKE_HOME/.trellis"
  unset CODE_REVIEWER_CMD
  export HERDR_ENV=1 HERDR_WORKSPACE_ID=fixture-workspace HERDR_PANE_ID=fixture-pane
  MARKER="$(mktemp "$BATS_TMPDIR/hookran.XXXXXX")"
  STUB_DIR="$(make_pi_stub "$MARKER")"
  PATH_BACKUP="$PATH"
  CLAUDE_DIR="$(make_tombstone_claude)"
  export PATH="$STUB_DIR:$CLAUDE_DIR:$PATH"
  run_with_stderr "$HOOK" '{"stop_hook_active":false}'
  unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID
  export PATH="$PATH_BACKUP"
  export HOME="$HOME_BACKUP"
  if [ -n "$TRELLIS_HOME_BACKUP" ]; then
    export TRELLIS_HOME="$TRELLIS_HOME_BACKUP"
  else
    unset TRELLIS_HOME
  fi
  RAN="$(cat "$MARKER" 2>/dev/null || true)"
  rm -rf "$FAKE_HOME" "$STUB_DIR" "$CLAUDE_DIR"
  rm -f "$MARKER"

  [ "$status" -eq 0 ]
  [[ "$RAN" == *RAN_PI* ]] || { echo "expected the pi route to run; stderr: $stderr"; false; }
  [ ! -s "$TOMBSTONE" ] || { echo "CLAUDE REACHED:"; cat "$TOMBSTONE"; false; }
  teardown_tombstone
}
