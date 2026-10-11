#!/usr/bin/env bats
# Tests for check-bypass.sh — commit trailers, persistent git bypasses,
# and native hook registration.
#
# Approach: each test stands up a fresh fixture git repo (single empty commit
# on `main`) and adds only the config knob or harness surface under test.
# Other sections stay silent, so the exit code isolates the intended check.
#
# Exit codes follow pg_exit_code: 0=pass, 1=fail, 2=warn.
#   §3a (core.hooksPath disabled) -> fail (exit 1)
#   §3b (commit.gpgsign=false)    -> warn (exit 2)

setup() {
  # Owner records and replacements must preserve attach's private-file contract.
  umask 077
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-bypass.sh"
  # Interpreter under test. macOS hosts run these hooks under /bin/bash 3.2, so
  # default there rather than to whichever bash PATH resolves first (homebrew
  # 5.x on a dev box would let a 3.2-incompatible edit ship green). Override
  # with BASH_BIN=/path/to/bash to exercise another build.
  BASH_BIN="${BASH_BIN:-/bin/bash}"
  [ -x "$BASH_BIN" ] || BASH_BIN="bash"
  GLOBAL_CONFIG="$(mktemp "$BATS_TEST_TMPDIR/check-bypass-global.XXXXXX")"
  cat > "$GLOBAL_CONFIG" <<'EOF'
[user]
  email = test@example.com
  name = test
EOF
  export GIT_CONFIG_GLOBAL="$GLOBAL_CONFIG"
  export GIT_CONFIG_NOSYSTEM=1
  PROJECT_DIR="$(mktemp -d "$BATS_TEST_TMPDIR/check-bypass-project.XXXXXX")"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q -b main
    git -c commit.gpgsign=false commit --allow-empty -q -m "init"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  export TRELLIS_HOME="$BATS_TEST_TMPDIR/trellis-home"
  mkdir -p "$TRELLIS_HOME"
  unset CODEX_PROJECT_DIR
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
}

# Run check-bypass.sh against the fixture from inside it (so the default
# range resolves to `main..HEAD`, which is empty on a single-commit repo).
# The script is invoked through $BASH_BIN explicitly: letting its shebang
# resolve would hand execution back to `env bash` and skip the 3.2 check.
run_check() {
  run "$BASH_BIN" -c "cd '$PROJECT_DIR' && '$BASH_BIN' '$SCRIPT'"
}

# Add an empty commit carrying the given body, then run check-bypass.sh over
# just that commit (HEAD~1..HEAD) so commit-trailer detection is isolated.
commit_body_and_check() {
  local body="$1"
  (
    cd "$PROJECT_DIR" || exit 1
    git -c commit.gpgsign=false commit --allow-empty -q -m "chore: trailer test" -m "$body"
  )
  run "$BASH_BIN" -c "cd '$PROJECT_DIR' && '$BASH_BIN' '$SCRIPT' --range=HEAD~1..HEAD"
}

# --- §3a: core.hooksPath active-disable ---

@test "§3a: core.hooksPath=/dev/null -> fail with finding" {
  git -C "$PROJECT_DIR" config core.hooksPath /dev/null
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"core.hooksPath"* ]] || { echo "$output"; false; }
  [[ "$output" == *"actively set to disable hooks"* ]] || { echo "$output"; false; }
  [[ "$output" == *"/dev/null"* ]]
}

@test "§3a: core.hooksPath unset -> no finding from this check (exit 0)" {
  # Sanity: ensure key is not set in the fixture. `if`, not a leading `!`: a
  # negated command never trips `set -e`, so the bare form was inert and a
  # fixture that DID carry the key would have sailed past it.
  if git -C "$PROJECT_DIR" config --get core.hooksPath; then
    echo "fixture precondition violated: core.hooksPath is set"; false
  fi
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively set to disable hooks"* ]]
}

@test "§3a: core.hooksPath=/custom/path -> no finding (legitimate override)" {
  git -C "$PROJECT_DIR" config core.hooksPath /custom/path
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively set to disable hooks"* ]]
}

# --- §3b: commit.gpgsign actively disabled ---

@test "§3b: commit.gpgsign=false -> warn with finding (exit 2)" {
  git -C "$PROJECT_DIR" config commit.gpgsign false
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"commit.gpgsign"* ]] || { echo "$output"; false; }
  [[ "$output" == *"actively disabled via persistent config"* ]]
}

@test "§3b: commit.gpgsign=true -> no finding (exit 0)" {
  git -C "$PROJECT_DIR" config commit.gpgsign true
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively disabled via persistent config"* ]]
}

@test "§3b: commit.gpgsign unset -> no finding (exit 0)" {
  if git -C "$PROJECT_DIR" config --get commit.gpgsign; then
    echo "fixture precondition violated: commit.gpgsign is set"; false
  fi
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"actively disabled via persistent config"* ]]
}

# --- §1a: PROCESS_GATE_SKIP=1 commit-trailer detection ---

@test "§1a: PROCESS_GATE_SKIP=1 trailer in range -> warn (exit 2) with finding" {
  commit_body_and_check "PROCESS_GATE_SKIP=1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"PROCESS_GATE_SKIP=1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"must be justified"* ]]
}

@test "§1a: no PROCESS_GATE_SKIP trailer -> no finding from this check (exit 0)" {
  commit_body_and_check "ordinary body with no override trailers"
  [ "$status" -eq 0 ]
  [[ "$output" != *"PROCESS_GATE_SKIP=1 found"* ]]
}

@test "§1 baseline: TRELLIS_ALLOW_MAIN_PUSH=1 trailer in range -> warn (exit 2)" {
  commit_body_and_check "TRELLIS_ALLOW_MAIN_PUSH=1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"TRELLIS_ALLOW_MAIN_PUSH=1"* ]]
}

# --- §4: hooks registration across both settings files ---
#
# Portable attachment registers hooks in the machine-local settings.local.json
# and leaves the tracked settings.json free of them, so either file satisfies
# the check.

# Write a settings file into the fixture's .claude/ dir.
write_settings() {
  mkdir -p "$PROJECT_DIR/.claude"
  cat > "$PROJECT_DIR/.claude/$1" <<EOF
$2
EOF
}

# Owner records encode harnesses through artifacts/pre_existing, not a top-level
# harnesses key. Use the same canonical identity inputs as local-registry.sh;
# the fixture home is exported by setup, never the operator's ~/.trellis.
write_attachment_owner() {
  local root common checkout_id worktree_id payload
  root="$(cd "$PROJECT_DIR" && pwd -P)"
  payload="${PI_PAYLOAD:-$BATS_TEST_TMPDIR/fixture-payload}"
  mkdir -p "$payload" "$PROJECT_DIR/.trellis"
  payload="$(cd "$payload" && pwd -P)"
  if [ ! -e "$PROJECT_DIR/.trellis/runtime" ] && [ ! -L "$PROJECT_DIR/.trellis/runtime" ]; then
    ln -s "$payload" "$PROJECT_DIR/.trellis/runtime"
  fi
  common="$(git -C "$root" rev-parse --git-common-dir)"
  case "$common" in /*) ;; *) common="$root/$common" ;; esac
  common="$(cd "$common" && pwd -P)"
  checkout_id="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$common")"
  worktree_id="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$root")"
  OWNER_PATH="$TRELLIS_HOME/state/attachments/$checkout_id/$worktree_id.json"
  mkdir -p "$(dirname "$OWNER_PATH")"
  jq -n --arg root "$root" --arg checkout "$checkout_id" --arg worktree "$worktree_id" \
    --arg payload "$payload" --args '
    {schema_version:1,status:"committed",worktree_root:$root,
     checkout_id:$checkout,worktree_id:$worktree,pre_existing:[],
     artifacts:([{path:".trellis/runtime",kind:"symlink",target:$payload}] +
       [$ARGS.positional[] |
         if . == "pi" then
           {kind:"symlink",path:".pi/extensions/trellis.ts",target:"../../.trellis/runtime/core-rules/pi/extensions/trellis.ts"},
           {kind:"symlink",path:".pi/hooks/dispatch.sh",target:"../../.trellis/runtime/core-rules/pi/hooks/dispatch.sh"}
         elif . == "claude" then {kind:"file",path:".claude/settings.local.json"}
         elif . == "codex" then {kind:"file",path:".codex/hooks.json"}
         else error("unsupported fixture harness") end])}
  ' "$@" > "$OWNER_PATH"
  record_hook_expectations
  chmod 600 "$OWNER_PATH"
}

# Record the attach-time hook baseline before tampering. The real owner records
# file SHA-256 and explicit-json renders with owned event values; fixture paths
# that do not exist yet have no baseline and must never authenticate commands.
record_hook_expectations() {
  python3 -I -c '
import base64, hashlib, json, os, sys
owner_path, root = sys.argv[1:]
with open(owner_path) as source:
    owner = json.load(source)
owner["renders"] = []
paths = [entry["path"] for entry in owner["artifacts"] if entry["kind"] == "file"]
if any(path.startswith(".claude/") for path in paths) and os.path.isfile(os.path.join(root, ".claude/settings.json")):
    with open(os.path.join(root, ".claude/settings.json")) as source:
        if "hooks" in json.load(source):
            paths.append(".claude/settings.json")
for path in paths:
    absolute = os.path.join(root, path)
    if not os.path.isfile(absolute):
        continue
    with open(absolute, "rb") as source:
        content = source.read()
    digest = hashlib.sha256(content).hexdigest()
    matches = [entry for entry in owner["artifacts"] if entry["path"] == path]
    if not matches:
        owner["artifacts"].append({"path":path, "kind":"file", "sha256":digest})
    else:
        matches[0]["sha256"] = digest
    settings = json.loads(content)
    owner["renders"].append({"path":path, "merge":"explicit-json", "after_sha256":digest,
        "after_base64":base64.b64encode(content).decode(),
        "owned_keys":[{"path":["hooks", event], "value":groups} for event, groups in settings.get("hooks", {}).items()]})
with open(owner_path, "w") as destination:
    json.dump(owner, destination)
' "$OWNER_PATH" "$PROJECT_DIR"
}

@test "§4: hooks only in settings.local.json (attachment layout) -> pass (exit 0)" {
  write_settings settings.json '{ "permissions": { "allow": [] } }'
  write_settings settings.local.json '{
  "hooks": {
    "PreToolUse": [{ "matcher": "Edit", "hooks": [{ "type": "command", "command": "reread-guard" }] }]
  }
}'
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
}

@test "§4: hooks in neither settings file -> fail naming both (exit 1)" {
  write_settings settings.json '{ "permissions": { "allow": [] } }'
  write_settings settings.local.json '{ "permissions": { "deny": [] } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
  [[ "$output" == *".claude/settings.json"* ]]
  [[ "$output" == *".claude/settings.local.json"* ]]
}

@test "§4: hooks in settings.json (legacy layout) -> pass (exit 0)" {
  write_settings settings.json '{
  "hooks": {
    "Stop": [{ "matcher": "", "hooks": [{ "type": "command", "command": "dod-receipt" }] }]
  }
}'
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
}

@test "§4: empty hooks block in both -> fail (no registered event)" {
  write_settings settings.json '{ "hooks": {} }'
  write_settings settings.local.json '{ "hooks": {} }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
}

# The tampering shape the gate exists for: keep the event keys, strip the hook
# entries. An event key alone is not a registration.
@test "§4: event keys with no hook entries -> fail (exit 1)" {
  write_settings settings.json '{ "hooks": { "PreToolUse": [] } }'
  write_settings settings.local.json '{ "hooks": { "Stop": [], "PreToolUse": [] } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
}

@test "§4: junk empty-name event key -> fail (exit 1)" {
  write_settings settings.json '{ "hooks": { "": [{ "hooks": [{ "type": "command", "command": "true" }] }] } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
}

@test "§4: no settings file in an unattached project -> no finding (exit 0)" {
  [ ! -e "$PROJECT_DIR/.claude" ]
  [ ! -e "$PROJECT_DIR/.trellis.json" ]
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]]
}

# Deleting the settings pair fails when this worktree's owner declares Claude.
@test "§4: attached project with no settings file at all -> fail (exit 1)" {
  printf '{"schema_version":1,"project_id":"fixture"}\n' > "$PROJECT_DIR/.trellis.json"
  write_attachment_owner claude
  [ ! -e "$PROJECT_DIR/.claude" ]
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]] || { echo "$output"; false; }
  [[ "$output" == *"neither file exists"* ]]
}

# --- §4: Codex registration and per-harness tampering ---

write_codex_hooks() {
  mkdir -p "$PROJECT_DIR/.codex"
  printf '%s\n' "$1" > "$PROJECT_DIR/.codex/hooks.json"
}

# Use the attach template with its contextual markers resolved. This preserves
# the actual event/group/command shape without invoking attach or any hook.
registered_codex_fixture() {
  printf '{"schema_version":1,"project_id":"fixture"}\n' > "$PROJECT_DIR/.trellis.json"
  mkdir -p "$PROJECT_DIR/.codex/hooks"
  jq -S --arg home "'/fixture/home'" --arg trellis_home "'/fixture/trellis'" \
    --arg launcher "'/fixture/user-home/.local/bin/trellis'" '
    (.hooks.SessionStart[0].hooks[].command) |= (
      split("__TRELLIS_USER_HOME__") | join($home)
      | split("__TRELLIS_HOME__") | join($trellis_home)
      | split("__TRELLIS_LAUNCHER__") | join($launcher))
  ' "$(dirname "$SCRIPT")/../../../templates/codex-hooks.local.json" > "$PROJECT_DIR/.codex/hooks.json"
  write_attachment_owner codex
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "§4: codex-only rendered hooks.json -> pass (exit 0)" {
  registered_codex_fixture
  [ ! -e "$PROJECT_DIR/.claude" ]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]]
}

@test "§4: codex-only empty hooks.json -> fail (exit 1)" {
  registered_codex_fixture
  write_codex_hooks '{ "hooks": {} }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: no \"hooks\" event with a command entry"* ]]
}

@test "§4: codex-only event keys stripped of command entries -> fail (exit 1)" {
  registered_codex_fixture
  write_codex_hooks '{ "hooks": { "PreToolUse": [], "Stop": [] } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: no \"hooks\" event with a command entry"* ]]
}

@test "§4: codex-only event groups stripped of command entries -> fail (exit 1)" {
  registered_codex_fixture
  write_codex_hooks '{ "hooks": { "PreToolUse": [{ "matcher": "Bash", "hooks": [] }] } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: no \"hooks\" event with a command entry"* ]]
}

@test "§4: codex-only empty or missing command string -> fail (exit 1)" {
  registered_codex_fixture
  for entry in '{"type":"command"}' '{"type":"command","command":""}' '{"type":"command","command":"   "}'; do
    write_codex_hooks "{\"hooks\":{\"Stop\":[{\"hooks\":[$entry]}]}}"
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *".codex/hooks.json: no \"hooks\" event with a command entry"* ]]
  done
}

@test "§4: codex-only unrelated command cannot mask stripped hooks -> fail (exit 1)" {
  registered_codex_fixture
  write_codex_hooks '{ "hooks": { "Stop": [] }, "project": { "type": "command", "command": "unrelated" } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: no \"hooks\" event with a command entry"* ]]
}

@test "§4: codex-only invalid hook shapes or malformed JSON -> fail (exit 1)" {
  registered_codex_fixture
  for json in '{"hooks":[]}' '{"hooks":null}' '{"hooks":false}' '{"hooks":'; do
    write_codex_hooks "$json"
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *".codex/hooks.json: no \"hooks\" event with a command entry"* ]]
  done
}

@test "§4: codex-only hooks.json deleted with hook directory remaining -> fail (exit 1)" {
  registered_codex_fixture
  rm "$PROJECT_DIR/.codex/hooks.json"
  [ ! -e "$PROJECT_DIR/.claude" ]
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
}

@test "§4: codex-only entire hook surface deleted but tracked -> fail (exit 1)" {
  registered_codex_fixture
  git -C "$PROJECT_DIR" add .codex/hooks.json
  rm -rf "$PROJECT_DIR/.codex"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
}

@test "§4: staged deletion of committed Codex registration -> fail (exit 1)" {
  registered_codex_fixture
  git -C "$PROJECT_DIR" add .codex/hooks.json
  git -C "$PROJECT_DIR" -c commit.gpgsign=false commit -q -m "fixture: Codex registration"
  git -C "$PROJECT_DIR" rm -q .codex/hooks.json
  rm -rf "$PROJECT_DIR/.codex"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
}

@test "§4: Codex owner ignores stray Claude skills and unowned Pi files -> pass (exit 0)" {
  registered_codex_fixture
  mkdir -p "$PROJECT_DIR/.claude/skills/process-gate" "$PROJECT_DIR/.pi/hooks" "$PROJECT_DIR/.pi/extensions"
  ln -s "$(dirname "$SCRIPT")/../../../pi/extensions/trellis.ts" "$PROJECT_DIR/.pi/extensions/trellis.ts"
  printf '%s\n' '# --- Trellis local attachment exclude block ---' \
    '/.claude/skills/process-gate' '/.codex/hooks.json' '/.pi/extensions/trellis.ts' \
    '# --- end Trellis local attachment exclude block ---' >> "$PROJECT_DIR/.git/info/exclude"
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]]
}

@test "§4: no hooks in any harness declared by the owner -> fail (exit 1)" {
  registered_codex_fixture
  write_attachment_owner claude codex
  rm -rf "$PROJECT_DIR/.codex"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".claude/settings.json / .claude/settings.local.json: neither file exists"* ]]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
}

@test "§4: empty Claude settings cannot be masked by registered Codex hooks -> fail (exit 1)" {
  registered_codex_fixture
  for settings in settings.json settings.local.json; do
    write_settings "$settings" '{ "hooks": {} }'
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *".claude/settings.json / .claude/settings.local.json: no \"hooks\" event with a command entry"* ]]
    rm "$PROJECT_DIR/.claude/$settings"
  done
}

@test "§4: empty Codex hooks cannot be masked by registered Claude hooks -> fail (exit 1)" {
  registered_codex_fixture
  write_settings settings.json '{ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "dod-receipt" }] }] } }'
  run_check
  [ "$status" -eq 0 ]
  write_codex_hooks '{ "hooks": {} }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: no \"hooks\" event with a command entry"* ]]
}

@test "§4: deleted tracked Claude settings cannot be masked by Codex hooks -> fail (exit 1)" {
  registered_codex_fixture
  write_settings settings.json '{ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "dod-receipt" }] }] } }'
  write_attachment_owner claude codex
  git -C "$PROJECT_DIR" add .claude/settings.json
  run_check
  [ "$status" -eq 0 ]
  rm "$PROJECT_DIR/.claude/settings.json"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".claude/settings.json / .claude/settings.local.json: neither file exists"* ]]
}

@test "§4: ignored Claude registration in owner cannot be deleted behind Codex -> fail (exit 1)" {
  registered_codex_fixture
  write_settings settings.local.json '{ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "dod-receipt" }] }] } }'
  write_attachment_owner claude codex
  printf '%s\n' '# --- Trellis local attachment exclude block ---' \
    '/.claude/settings.local.json' '/.codex/hooks.json' \
    '# --- end Trellis local attachment exclude block ---' >> "$PROJECT_DIR/.git/info/exclude"
  run_check
  [ "$status" -eq 0 ]
  rm -rf "$PROJECT_DIR/.claude"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".claude/settings.json / .claude/settings.local.json: neither file exists"* ]]
}

@test "§4: ignored Codex registration declared by attach cannot be deleted behind Claude -> fail (exit 1)" {
  registered_codex_fixture
  write_settings settings.json '{ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "dod-receipt" }] }] } }'
  printf '%s\n' '# --- Trellis local attachment exclude block ---' \
    '/.codex/hooks.json' '# --- end Trellis local attachment exclude block ---' >> "$PROJECT_DIR/.git/info/exclude"
  run_check
  [ "$status" -eq 0 ]
  rm -rf "$PROJECT_DIR/.codex"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
}

# --- §4: local ownership versus manifest-only clones ---

@test "§4: owner-declared Claude with local settings hooks -> pass (exit 0)" {
  write_settings settings.json '{ "permissions": { "allow": [] } }'
  write_settings settings.local.json '{ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "dod-receipt" }] }] } }'
  write_attachment_owner claude
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"not attached"* ]]
}

@test "§4: manifest-only checkout before attachment -> warn not attached (exit 2)" {
  printf '{"schema_version":1,"project_id":"fixture"}\n' > "$PROJECT_DIR/.trellis.json"
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"not attached in this checkout"* ]]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]]
}

@test "§4: tracked hook files and managed excludes do not attach a raw clone -> warn (exit 2)" {
  registered_codex_fixture
  rm "$OWNER_PATH" "$PROJECT_DIR/.trellis/runtime"
  git -C "$PROJECT_DIR" add .codex/hooks.json
  printf '%s\n' '# --- Trellis local attachment exclude block ---' \
    '/.codex/hooks.json' '# --- end Trellis local attachment exclude block ---' >> "$PROJECT_DIR/.git/info/exclude"
  run_check
  [ "$status" -eq 2 ]
  [[ "$output" == *"not attached in this checkout"* ]]
}

@test "§4: no manifest or local owner preserves legacy unattached behavior -> pass (exit 0)" {
  write_codex_hooks '{ "hooks": {} }'
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"not attached"* ]]
}

@test "§4: owner without a manifest still requires its Codex hooks -> pass then fail" {
  registered_codex_fixture
  rm "$PROJECT_DIR/.trellis.json"
  run_check
  [ "$status" -eq 0 ]
  rm "$PROJECT_DIR/.codex/hooks.json"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
}

@test "§4: runtime anchor without an owner fails closed instead of warning (exit 1)" {
  printf '{"schema_version":1,"project_id":"fixture"}\n' > "$PROJECT_DIR/.trellis.json"
  run_check
  [ "$status" -eq 2 ]
  mkdir -p "$PROJECT_DIR/.trellis"
  ln -s "$BATS_TEST_TMPDIR/missing-runtime" "$PROJECT_DIR/.trellis/runtime"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"owner record unavailable or invalid"* ]]
}

@test "§4: malformed owner cannot downgrade attachment to a warning (exit 1)" {
  registered_codex_fixture
  printf '{"schema_version":' > "$OWNER_PATH"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"owner record unavailable or invalid"* ]]
}

@test "§4: wrong-root owner is rejected rather than borrowing its harness set (exit 1)" {
  registered_codex_fixture
  jq '.worktree_root = "/different/checkout"' "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"owner record unavailable or invalid"* ]]
}

@test "§4: sibling worktree does not inherit this worktree's owner -> warn (exit 2)" {
  registered_codex_fixture
  original_root="$PROJECT_DIR"
  sibling="$BATS_TEST_TMPDIR/sibling-worktree"
  git -C "$PROJECT_DIR" worktree add -q --detach "$sibling" HEAD
  PROJECT_DIR="$sibling"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  printf '{"schema_version":1,"project_id":"fixture"}\n' > "$PROJECT_DIR/.trellis.json"
  run_check
  PROJECT_DIR="$original_root"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not attached in this checkout"* ]]
}

@test "§4: unset TRELLIS_HOME reads owner from HOME/.trellis -> pass (exit 0)" {
  registered_codex_fixture
  export HOME="$BATS_TEST_TMPDIR/default-home"
  export TRELLIS_HOME="$HOME/.trellis"
  write_attachment_owner codex
  unset TRELLIS_HOME
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"not attached"* ]]
}

@test "§4: deferred Claude without a recorded baseline cannot authenticate arbitrary hooks" {
  registered_codex_fixture
  jq '.pre_existing = [{path:".claude/settings.local.json",kind:"file",reason:"project-authored-render",target:null}]' \
    "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".claude/settings.json / .claude/settings.local.json: neither file exists"* ]]
  write_settings settings.local.json '{ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "dod-receipt" }] }] } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]]
}

@test "§4: legacy shared-agent owner without Pi still requires Codex hooks" {
  registered_codex_fixture
  jq '(.artifacts[] | select(.path == ".codex/hooks.json") | .path) = "AGENTS.md"' \
    "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  run_check
  [ "$status" -eq 0 ]
  rm "$PROJECT_DIR/.codex/hooks.json"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
}

@test "§4: symlink alias of worktree root resolves to its canonical owner -> pass (exit 0)" {
  registered_codex_fixture
  alias_root="$BATS_TEST_TMPDIR/project-alias"
  ln -s "$PROJECT_DIR" "$alias_root"
  export CLAUDE_PROJECT_DIR="$alias_root"
  run_check
  [ "$status" -eq 0 ]
  [[ "$output" != *"not attached"* ]]
}

@test "§4: manifest-only warning cannot mask empty Claude settings -> fail (exit 1)" {
  printf '{"schema_version":1,"project_id":"fixture"}\n' > "$PROJECT_DIR/.trellis.json"
  write_settings settings.json '{ "hooks": {} }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"not attached in this checkout"* ]]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]]
}

# --- §4: Pi native artifacts, pinned to the local owner ---

registered_pi_fixture() {
  local source
  source="$(dirname "$SCRIPT")/../../../pi"
  PI_PAYLOAD="$BATS_TEST_TMPDIR/pi-payload"
  mkdir -p "$PI_PAYLOAD/core-rules/pi/extensions" "$PI_PAYLOAD/core-rules/pi/hooks" \
    "$PROJECT_DIR/.trellis" "$PROJECT_DIR/.pi/extensions" "$PROJECT_DIR/.pi/hooks"
  cp "$source/extensions/trellis.ts" "$PI_PAYLOAD/core-rules/pi/extensions/trellis.ts"
  cp "$source/hooks/dispatch.sh" "$PI_PAYLOAD/core-rules/pi/hooks/dispatch.sh"
  # Symlink owners pin targets; their content baseline is the sealed release tree.
  python3 -I - "$PI_PAYLOAD" <<'PY'
import hashlib, json, pathlib, sys
payload = pathlib.Path(sys.argv[1])
tree = []
for path in payload.rglob("*"):
    if path.is_file():
        content = path.read_bytes()
        tree.append({"path":str(path.relative_to(payload)),
                     "mode":"100755" if path.stat().st_mode & 0o111 else "100644",
                     "oid":hashlib.sha1(("blob %d\0" % len(content)).encode() + content).hexdigest()})
(payload.parent / "release.json").write_text(json.dumps({"tree":tree}))
PY
  PI_PAYLOAD="$(cd "$PI_PAYLOAD" && pwd -P)"
  # A combined fixture may already have the JSON harness's runtime anchor.
  [ ! -L "$PROJECT_DIR/.trellis/runtime" ] || rm "$PROJECT_DIR/.trellis/runtime"
  ln -s "$PI_PAYLOAD" "$PROJECT_DIR/.trellis/runtime"
  ln -s '../../.trellis/runtime/core-rules/pi/extensions/trellis.ts' "$PROJECT_DIR/.pi/extensions/trellis.ts"
  ln -s '../../.trellis/runtime/core-rules/pi/hooks/dispatch.sh' "$PROJECT_DIR/.pi/hooks/dispatch.sh"
  write_attachment_owner pi "$@"
  jq '.artifacts += [{kind:"symlink",path:"AGENTS.md",target:".agents/rules/trellis.md"}]' \
    "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "§4: Pi owner with both recorded native artifacts and no Codex JSON -> pass (exit 0)" {
  registered_pi_fixture
  [ ! -e "$PROJECT_DIR/.codex/hooks.json" ]
  [ ! -e "$PROJECT_DIR/.claude" ]
  [[ "$output" != *"not registered"* ]]
}

@test "§4: Pi extension missing -> fail (exit 1)" {
  registered_pi_fixture
  rm "$PROJECT_DIR/.pi/extensions/trellis.ts"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts: native Pi hook artifact"* ]]
}

@test "§4: Pi dispatcher missing -> fail (exit 1)" {
  registered_pi_fixture
  rm "$PROJECT_DIR/.pi/hooks/dispatch.sh"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/hooks/dispatch.sh: native Pi hook artifact"* ]]
}

@test "§4: Pi symlink artifacts replaced by regular copies -> fail (exit 1)" {
  registered_pi_fixture
  for path in .pi/extensions/trellis.ts .pi/hooks/dispatch.sh; do
    target="$(readlink "$PROJECT_DIR/$path")"
    cp "$PROJECT_DIR/$path" "$BATS_TEST_TMPDIR/pi-replacement"
    rm "$PROJECT_DIR/$path"
    cp "$BATS_TEST_TMPDIR/pi-replacement" "$PROJECT_DIR/$path"
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"$path: native Pi hook artifact"* ]]
    rm "$PROJECT_DIR/$path"
    ln -s "$target" "$PROJECT_DIR/$path"
  done
}

@test "§4: Pi artifacts emptied behind their recorded symlinks -> fail (exit 1)" {
  registered_pi_fixture
  for path in extensions/trellis.ts hooks/dispatch.sh; do
    cp "$PI_PAYLOAD/core-rules/pi/$path" "$BATS_TEST_TMPDIR/pi-backup"
    : > "$PI_PAYLOAD/core-rules/pi/$path"
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *".pi/$path: native Pi hook artifact"* ]]
    cp "$BATS_TEST_TMPDIR/pi-backup" "$PI_PAYLOAD/core-rules/pi/$path"
  done
}

@test "§4: Pi owner with Codex JSON only and no native artifacts -> fail (exit 1)" {
  registered_codex_fixture
  registered_pi_fixture
  rm -rf "$PROJECT_DIR/.pi"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts: native Pi hook artifact"* ]]
  [[ "$output" == *".pi/hooks/dispatch.sh: native Pi hook artifact"* ]]
}

@test "§4: Pi symlink retargeted to identical content still differs from owner -> fail (exit 1)" {
  registered_pi_fixture
  cp "$PI_PAYLOAD/core-rules/pi/extensions/trellis.ts" "$BATS_TEST_TMPDIR/other-extension.ts"
  rm "$PROJECT_DIR/.pi/extensions/trellis.ts"
  ln -s "$BATS_TEST_TMPDIR/other-extension.ts" "$PROJECT_DIR/.pi/extensions/trellis.ts"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts: native Pi hook artifact"* ]]
}

@test "§4: Pi newline-suffixed link target is not the recorded target -> fail (exit 1)" {
  registered_pi_fixture
  cp "$PI_PAYLOAD/core-rules/pi/extensions/trellis.ts" "$PI_PAYLOAD/core-rules/pi/extensions/trellis.ts"$'\n'
  rm "$PROJECT_DIR/.pi/extensions/trellis.ts"
  ln -s '../../.trellis/runtime/core-rules/pi/extensions/trellis.ts'$'\n' "$PROJECT_DIR/.pi/extensions/trellis.ts"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts: native Pi hook artifact"* ]]
}

@test "§4: Pi broken symlink with unchanged recorded target -> fail (exit 1)" {
  registered_pi_fixture
  rm "$PI_PAYLOAD/core-rules/pi/hooks/dispatch.sh"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/hooks/dispatch.sh: native Pi hook artifact"* ]]
}

@test "§4: Pi files present but a native artifact absent from owner -> fail (exit 1)" {
  registered_pi_fixture
  jq '.artifacts |= map(select(.path != ".pi/extensions/trellis.ts"))' \
    "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts: native Pi hook artifact"* ]]
}

@test "§4: Pi regular-file artifacts use recorded content hashes, not hard-coded contents" {
  registered_pi_fixture
  for path in .pi/extensions/trellis.ts .pi/hooks/dispatch.sh; do
    cp "$PROJECT_DIR/$path" "$BATS_TEST_TMPDIR/pi-copy"
    rm "$PROJECT_DIR/$path"
    cp "$BATS_TEST_TMPDIR/pi-copy" "$PROJECT_DIR/$path"
    # Distinct but valid source bytes prove the recorded digest is authoritative.
    printf '\n\n' >> "$PROJECT_DIR/$path"
    digest="$(python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$PROJECT_DIR/$path")"
    jq --arg path "$path" --arg digest "$digest" '
      .artifacts |= map(if .path == $path then {path:$path,kind:"file",sha256:$digest} else . end)
    ' "$OWNER_PATH" > "$OWNER_PATH.tmp"
    mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  done
  run_check
  [ "$status" -eq 0 ]
  for path in .pi/extensions/trellis.ts .pi/hooks/dispatch.sh; do
    cp "$PROJECT_DIR/$path" "$BATS_TEST_TMPDIR/pi-copy"
    printf 'different file content\n' > "$PROJECT_DIR/$path"
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"$path: native Pi hook artifact"* ]]
    cp "$BATS_TEST_TMPDIR/pi-copy" "$PROJECT_DIR/$path"
  done
}

@test "§4: Pi deferred symlink entries in owner are honored and cannot be removed" {
  registered_pi_fixture
  jq '
    .pre_existing = [.artifacts[] | select(.path | startswith(".pi/")) | . + {reason:"pre-existing-symlink"}]
    | .artifacts |= map(select(.path | startswith(".pi/") | not))
  ' "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  run_check
  [ "$status" -eq 0 ]
  rm "$PROJECT_DIR/.pi/hooks/dispatch.sh"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/hooks/dispatch.sh: native Pi hook artifact"* ]]
}

@test "§4: Codex+Pi requires both registrations independently" {
  registered_codex_fixture
  registered_pi_fixture codex
  rm "$PROJECT_DIR/.codex/hooks.json"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
}

@test "§4: unrelated command cannot mask stripped Claude hooks -> fail (exit 1)" {
  write_settings settings.json '{ "hooks": { "Stop": [] }, "project": { "type": "command", "command": "unrelated" } }'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]]
}

# --- Round 1: authenticate the complete owner-recorded registration ---

registered_claude_fixture() {
  mkdir -p "$PROJECT_DIR/.claude"
  jq -S --arg home "'/fixture/home'" --arg trellis_home "'/fixture/trellis'" \
    --arg launcher "'/fixture/user-home/.local/bin/trellis'" '
    (.hooks.SessionStart[0].hooks[].command) |= (
      split("__TRELLIS_USER_HOME__") | join($home)
      | split("__TRELLIS_HOME__") | join($trellis_home)
      | split("__TRELLIS_LAUNCHER__") | join($launcher))
  ' "$(dirname "$SCRIPT")/../../../templates/claude-settings.local.json" > "$PROJECT_DIR/.claude/settings.local.json"
  write_attachment_owner claude
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

# Change only the live file, never the recorded attachment baseline.
mutate_hook_file() {
  local relative="$1" filter="$2"
  jq "$filter" "$PROJECT_DIR/$relative" > "$PROJECT_DIR/$relative.tmp"
  mv "$PROJECT_DIR/$relative.tmp" "$PROJECT_DIR/$relative"
}

@test "R1: Codex one surviving real command cannot mask all stripped registrations" {
  registered_codex_fixture
  mutate_hook_file .codex/hooks.json '.hooks = {Stop:[{hooks:[.hooks.Stop[0].hooks[0]]}]}'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"matching owner-recorded Trellis hooks"* ]]
}

@test "R1: Codex dummy event with true cannot mask stripped real events" {
  registered_codex_fixture
  write_codex_hooks '{"hooks":{"Stop":[],"PreToolUse":[],"X":[{"hooks":[{"type":"command","command":"true"}]}]}}'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"matching owner-recorded Trellis hooks"* ]]
}

@test "R1: Codex command replacement in a real event fails against the recorded render" {
  registered_codex_fixture
  mutate_hook_file .codex/hooks.json '.hooks.PreToolUse[0].hooks[0].command = "true"'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"matching owner-recorded Trellis hooks"* ]]
}

@test "R1: Codex missing one expected event fails despite all other commands" {
  registered_codex_fixture
  mutate_hook_file .codex/hooks.json 'del(.hooks.SessionStart)'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"matching owner-recorded Trellis hooks"* ]]
}

@test "R1: Codex changed matcher fails with every recorded command still present" {
  registered_codex_fixture
  mutate_hook_file .codex/hooks.json '.hooks.PreToolUse[0].matcher = "NeverMatches"'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"matching owner-recorded Trellis hooks"* ]]
}

@test "R1: hash-only owner authenticates Codex bytes and rejects command replacement" {
  registered_codex_fixture
  jq 'del(.renders)' "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  mutate_hook_file .codex/hooks.json '.hooks.Stop[0].hooks[0].command = "true"'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"matching owner-recorded Trellis hooks"* ]]
}

@test "R1: identical Codex hooks behind a substituted file symlink fail" {
  registered_codex_fixture
  mv "$PROJECT_DIR/.codex/hooks.json" "$BATS_TEST_TMPDIR/copied-hooks.json"
  ln -s "$BATS_TEST_TMPDIR/copied-hooks.json" "$PROJECT_DIR/.codex/hooks.json"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"matching owner-recorded Trellis hooks"* ]]
}

@test "R1: identical Codex hooks behind a substituted parent symlink fail" {
  registered_codex_fixture
  mv "$PROJECT_DIR/.codex" "$BATS_TEST_TMPDIR/decoy-codex"
  ln -s "$BATS_TEST_TMPDIR/decoy-codex" "$PROJECT_DIR/.codex"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"matching owner-recorded Trellis hooks"* ]]
}

@test "R1: Claude full rendered registration passes in either settings file" {
  registered_claude_fixture
  mv "$PROJECT_DIR/.claude/settings.local.json" "$PROJECT_DIR/.claude/settings.json"
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "R1: unrelated permission edits preserve the owner-recorded Claude hook keys" {
  registered_claude_fixture
  mutate_hook_file .claude/settings.local.json '.permissions.allow = ["Read"]'
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "R1: Claude arbitrary valid command cannot authenticate a stripped registration" {
  registered_claude_fixture
  write_settings settings.local.json '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true"}]}]}}'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]]
}

@test "R1: Claude missing expected event fails despite surviving real commands" {
  registered_claude_fixture
  mutate_hook_file .claude/settings.local.json 'del(.hooks.SessionStart)'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]]
}

@test "R1: Claude replaced command fails despite every other real command" {
  registered_claude_fixture
  mutate_hook_file .claude/settings.local.json '.hooks.PreToolUse[0].hooks[0].command = "true"'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]]
}

@test "R1: Claude other settings file with a dummy command cannot mask stripped owned hooks" {
  registered_claude_fixture
  write_settings settings.json '{"hooks":{"X":[{"hooks":[{"type":"command","command":"true"}]}]}}'
  mutate_hook_file .claude/settings.local.json '.hooks = {}'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]]
}

@test "R1: every attached JSON harness fails closed when its expectation baseline is lost" {
  registered_claude_fixture
  registered_codex_fixture
  write_attachment_owner claude codex
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq 'del(.renders) | .artifacts |= map(del(.sha256))' "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]]
  [[ "$output" == *"matching owner-recorded Trellis hooks"* ]]
}

@test "R1: full Claude hooks cannot mask a single lost owner-recorded Codex event" {
  registered_claude_fixture
  registered_codex_fixture
  write_attachment_owner claude codex
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  mutate_hook_file .codex/hooks.json 'del(.hooks.PostToolUse)'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"matching owner-recorded Trellis hooks"* ]]
}

@test "R1: deferred Claude with recorded render expectations cannot lose a command" {
  registered_claude_fixture
  jq '.pre_existing = [.artifacts[] | select(.path == ".claude/settings.local.json")
        | {path,kind:"file",target:null,reason:"project-authored-render"}]
      | .artifacts |= map(select(.path != ".claude/settings.local.json"))' \
    "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  mutate_hook_file .claude/settings.local.json '.hooks.Stop[0].hooks[0].command = "true"'
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"Tier 1+2 hooks not registered"* ]]
}

# --- Round 1: pin the runtime and resolve Pi leaves, not just readlink text ---

# A decoy with nonempty stubs and exactly the recorded leaf-link text. Pointing
# any Pi surface parent at it passed the old readlink-plus-nonempty check.
pi_decoy_fixture() {
  PI_DECOY="$BATS_TEST_TMPDIR/deep/decoy-project"
  PI_DECOY_PAYLOAD="$BATS_TEST_TMPDIR/decoy-payload"
  mkdir -p "$PI_DECOY/.pi/extensions" "$PI_DECOY/.pi/hooks" "$PI_DECOY/.trellis" \
    "$PI_DECOY_PAYLOAD/core-rules/pi/extensions" "$PI_DECOY_PAYLOAD/core-rules/pi/hooks"
  printf 'export default function () {}\n' > "$PI_DECOY_PAYLOAD/core-rules/pi/extensions/trellis.ts"
  printf '#!/bin/bash\nexit 0\n' > "$PI_DECOY_PAYLOAD/core-rules/pi/hooks/dispatch.sh"
  ln -s "$PI_DECOY_PAYLOAD" "$PI_DECOY/.trellis/runtime"
  ln -s '../../.trellis/runtime/core-rules/pi/extensions/trellis.ts' "$PI_DECOY/.pi/extensions/trellis.ts"
  ln -s '../../.trellis/runtime/core-rules/pi/hooks/dispatch.sh' "$PI_DECOY/.pi/hooks/dispatch.sh"
}

@test "R1: replaced runtime anchor cannot redirect unchanged Pi leaf links to stubs" {
  registered_pi_fixture
  pi_decoy_fixture
  rm "$PROJECT_DIR/.trellis/runtime"
  ln -s "$PI_DECOY_PAYLOAD" "$PROJECT_DIR/.trellis/runtime"
  [ -s "$PROJECT_DIR/.pi/extensions/trellis.ts" ]
  [ -s "$PROJECT_DIR/.pi/hooks/dispatch.sh" ]
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts: native Pi hook artifact"* ]]
  [[ "$output" == *".pi/hooks/dispatch.sh: native Pi hook artifact"* ]]
}

@test "R1: runtime anchor replaced by a nonempty directory fails its recorded kind" {
  registered_pi_fixture
  rm "$PROJECT_DIR/.trellis/runtime"
  mkdir -p "$PROJECT_DIR/.trellis/runtime"
  cp -R "$PI_PAYLOAD/core-rules" "$PROJECT_DIR/.trellis/runtime/"
  [ -s "$PROJECT_DIR/.pi/extensions/trellis.ts" ]
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts: native Pi hook artifact"* ]]
}

@test "R1: replaced pi parent cannot run decoys with unchanged recorded leaf links" {
  registered_pi_fixture
  pi_decoy_fixture
  mv "$PROJECT_DIR/.pi" "$BATS_TEST_TMPDIR/original-pi"
  ln -s "$PI_DECOY/.pi" "$PROJECT_DIR/.pi"
  for relative in extensions/trellis.ts hooks/dispatch.sh; do
    [ -s "$PROJECT_DIR/.pi/$relative" ]
    [ "$(readlink "$PROJECT_DIR/.pi/$relative")" = "../../.trellis/runtime/core-rules/pi/$relative" ]
  done
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts: native Pi hook artifact"* ]]
  [[ "$output" == *".pi/hooks/dispatch.sh: native Pi hook artifact"* ]]
}

@test "R1: each Pi leaf parent rejects a symlink to a decoy with the same link text" {
  registered_pi_fixture
  pi_decoy_fixture
  for relative in extensions/trellis.ts hooks/dispatch.sh; do
    parent="${relative%/*}"
    mv "$PROJECT_DIR/.pi/$parent" "$BATS_TEST_TMPDIR/original-parent"
    ln -s "$PI_DECOY/.pi/$parent" "$PROJECT_DIR/.pi/$parent"
    [ -s "$PROJECT_DIR/.pi/$relative" ]
    [ "$(readlink "$PROJECT_DIR/.pi/$relative")" = "../../.trellis/runtime/core-rules/pi/$relative" ]
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *".pi/$relative: native Pi hook artifact"* ]]
    rm "$PROJECT_DIR/.pi/$parent"
    mv "$BATS_TEST_TMPDIR/original-parent" "$PROJECT_DIR/.pi/$parent"
  done
}

@test "R1: payload leaf redirection outside the recorded runtime fails despite nonempty follow" {
  registered_pi_fixture
  for relative in extensions/trellis.ts hooks/dispatch.sh; do
    mv "$PI_PAYLOAD/core-rules/pi/$relative" "$BATS_TEST_TMPDIR/external-payload-file"
    ln -s "$BATS_TEST_TMPDIR/external-payload-file" "$PI_PAYLOAD/core-rules/pi/$relative"
    [ -s "$PROJECT_DIR/.pi/$relative" ]
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *".pi/$relative: native Pi hook artifact"* ]]
    rm "$PI_PAYLOAD/core-rules/pi/$relative"
    mv "$BATS_TEST_TMPDIR/external-payload-file" "$PI_PAYLOAD/core-rules/pi/$relative"
  done
}

@test "R1: payload leaf redirection to another file inside runtime also fails resolved identity" {
  registered_pi_fixture
  for relative in extensions/trellis.ts hooks/dispatch.sh; do
    mv "$PI_PAYLOAD/core-rules/pi/$relative" "$PI_PAYLOAD/other-file"
    ln -s "$PI_PAYLOAD/other-file" "$PI_PAYLOAD/core-rules/pi/$relative"
    [ -s "$PROJECT_DIR/.pi/$relative" ]
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *".pi/$relative: native Pi hook artifact"* ]]
    rm "$PI_PAYLOAD/core-rules/pi/$relative"
    mv "$PI_PAYLOAD/other-file" "$PI_PAYLOAD/core-rules/pi/$relative"
  done
}

@test "R1: unchanged runtime link text cannot mask a replaced recorded payload directory" {
  registered_pi_fixture
  mv "$PI_PAYLOAD" "$BATS_TEST_TMPDIR/moved-payload"
  ln -s "$BATS_TEST_TMPDIR/moved-payload" "$PI_PAYLOAD"
  [ -s "$PROJECT_DIR/.pi/hooks/dispatch.sh" ]
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/hooks/dispatch.sh: native Pi hook artifact"* ]]
}

@test "R1: linked trellis surface parent cannot mask unchanged anchor and Pi leaves" {
  registered_pi_fixture
  mv "$PROJECT_DIR/.trellis" "$BATS_TEST_TMPDIR/moved-trellis"
  ln -s "$BATS_TEST_TMPDIR/moved-trellis" "$PROJECT_DIR/.trellis"
  [ -s "$PROJECT_DIR/.pi/hooks/dispatch.sh" ]
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/hooks/dispatch.sh: native Pi hook artifact"* ]]
}

@test "R1: Pi owner must record its runtime target rather than borrowing the live anchor" {
  registered_pi_fixture
  jq '(.artifacts[] | select(.path == ".trellis/runtime")) |= del(.target)' "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".pi/extensions/trellis.ts: native Pi hook artifact"* ]]
}

# --- Round 1: git-toplevel identity and private owner reads ---

@test "R1: Claude and Codex project-dir subdirectories are refused, never not attached" {
  registered_codex_fixture
  mkdir -p "$PROJECT_DIR/subdirectory"
  rm "$PROJECT_DIR/.codex/hooks.json"
  for harness_env in CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR; do
    export "$harness_env=$PROJECT_DIR/subdirectory"
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *"project root must equal the Git worktree top level"* ]]
    [[ "$output" != *"not attached"* ]]
  done
}

@test "R1: local config redirecting project-dir is refused as not data" {
  registered_codex_fixture
  mkdir -p "$PROJECT_DIR/subdirectory" "$PROJECT_DIR/.claude/skills/process-gate-local"
  printf 'CLAUDE_PROJECT_DIR="%s/subdirectory"\n' "$PROJECT_DIR" \
    > "$PROJECT_DIR/.claude/skills/process-gate-local/local.config.sh"
  git -C "$PROJECT_DIR" add .claude/skills/process-gate-local/local.config.sh
  git -C "$PROJECT_DIR" -c commit.gpgsign=false commit -qm "redirecting config"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"process-gate local config is not data: .claude/skills/process-gate-local/local.config.sh:1: CLAUDE_PROJECT_DIR="* ]]
  [[ "$output" != *"not attached"* ]]
}

@test "R1: subdirectory PWD fallback canonicalizes to the real attached toplevel" {
  registered_codex_fixture
  mkdir -p "$PROJECT_DIR/subdirectory"
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
  run "$BASH_BIN" -c "cd '$PROJECT_DIR/subdirectory' && '$BASH_BIN' '$SCRIPT'"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  rm "$PROJECT_DIR/.codex/hooks.json"
  run "$BASH_BIN" -c "cd '$PROJECT_DIR/subdirectory' && '$BASH_BIN' '$SCRIPT'"
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
  [[ "$output" != *"not attached"* ]]
}

@test "R1: missing HOME and TRELLIS_HOME cannot silently read phantom root attachment state" {
  registered_codex_fixture
  unset HOME TRELLIS_HOME
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"owner record unavailable or invalid"* ]]
  [[ "$output" != *"not attached"* ]]
}

@test "R1: non-private owner record fails rather than authenticating hook commands" {
  registered_codex_fixture
  chmod 644 "$OWNER_PATH"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"owner record unavailable or invalid"* ]]
}

@test "R1: symlinked owner record cannot authenticate even identical attachment contents" {
  registered_codex_fixture
  mv "$OWNER_PATH" "$OWNER_PATH.copy"
  ln -s "$OWNER_PATH.copy" "$OWNER_PATH"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"owner record unavailable or invalid"* ]]
}

# --- Round 4: managed Git hook authority survives package installs ---

managed_hooks_fixture() {
  registered_codex_fixture
  MANAGED_HOOKS="$TRELLIS_HOME/state/git-hooks/$(jq -r '.checkout_id' "$OWNER_PATH")"
  mkdir -p "$MANAGED_HOOKS" "$PROJECT_DIR/.husky/_"
  printf '{"scripts":{"prepare":"husky"}}\n' > "$PROJECT_DIR/package.json"
  jq --arg managed "$MANAGED_HOOKS" '
    .git_hooks = {enabled:true,managed_hooks_path:$managed}
  ' "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
}

@test "R4: husky prepare reset fails with the exact managed restore command" {
  managed_hooks_fixture
  git -C "$PROJECT_DIR" config core.hooksPath .husky/_
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"core.hooksPath: local path does not match owner-recorded managed dispatcher"* ]]
  [[ "$output" == *"git config --replace-all core.hooksPath $MANAGED_HOOKS"* ]]
}

@test "R4: unset managed hooksPath fails even with package.json" {
  managed_hooks_fixture
  if git -C "$PROJECT_DIR" config --local --get core.hooksPath; then
    echo "fixture precondition violated: core.hooksPath is set"; false
  fi
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"core.hooksPath: local path does not match owner-recorded managed dispatcher"* ]]
  [[ "$output" == *"git config --replace-all core.hooksPath $MANAGED_HOOKS"* ]]
}

@test "R4: owner-recorded managed hooksPath requires doctor's literal path" {
  managed_hooks_fixture
  git -C "$PROJECT_DIR" config core.hooksPath "$MANAGED_HOOKS"
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"core.hooksPath:"* ]]
  ln -s "$MANAGED_HOOKS" "$PROJECT_DIR/.hooks-alias"
  git -C "$PROJECT_DIR" config core.hooksPath .hooks-alias
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"restore with: git config --replace-all core.hooksPath $MANAGED_HOOKS"* ]]
}

@test "R4: git_hooks disabled in a truly unmanaged checkout preserves hooksPath behavior" {
  managed_hooks_fixture
  jq '.git_hooks.enabled = false' "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  rmdir "$MANAGED_HOOKS"
  for path in .husky/_ unset /custom/path /dev/null; do
    if [ "$path" = unset ]; then
      git -C "$PROJECT_DIR" config --local --unset-all core.hooksPath
    else
      git -C "$PROJECT_DIR" config core.hooksPath "$path"
    fi
    run_check
    if [ "$path" = /dev/null ]; then
      [ "$status" -eq 1 ]
      [[ "$output" == *"actively set to disable hooks"* ]]
    else
      [ "$status" -eq 0 ] || { echo "$output"; false; }
    fi
    [[ "$output" != *"owner-recorded managed dispatcher"* ]]
  done
}

# --- Round 5: linked worktrees share the checkout's managed hook authority ---

linked_managed_hooks_fixture() {
  managed_hooks_fixture
  MAIN_PROJECT_DIR="$PROJECT_DIR"
  MAIN_OWNER_PATH="$OWNER_PATH"
  git -C "$PROJECT_DIR" config core.hooksPath "$MANAGED_HOOKS"
  git -C "$PROJECT_DIR" worktree add -q --detach "$BATS_TEST_TMPDIR/linked-worktree" HEAD
  PROJECT_DIR="$BATS_TEST_TMPDIR/linked-worktree"
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  registered_codex_fixture
  jq '.git_hooks = {enabled:false}' "$OWNER_PATH" > "$OWNER_PATH.tmp"
  mv "$OWNER_PATH.tmp" "$OWNER_PATH"
  mkdir -p "$PROJECT_DIR/.husky/_"
  printf '{"scripts":{"prepare":"husky"}}\n' > "$PROJECT_DIR/package.json"
}

@test "R5: linked-worktree husky reset fails with the main owner's restore command" {
  linked_managed_hooks_fixture
  git -C "$PROJECT_DIR" config core.hooksPath .husky/_
  [ "$(git -C "$MAIN_PROJECT_DIR" config --local --get core.hooksPath)" = .husky/_ ]
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"core.hooksPath: local path does not match owner-recorded managed dispatcher"* ]]
  [[ "$output" == *"git config --replace-all core.hooksPath $MANAGED_HOOKS"* ]]
}

@test "R5: linked-worktree managed hooksPath passes but its realpath alias fails" {
  linked_managed_hooks_fixture
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"core.hooksPath:"* ]]
  ln -s "$MANAGED_HOOKS" "$PROJECT_DIR/.hooks-alias"
  git -C "$PROJECT_DIR" config core.hooksPath .hooks-alias
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"restore with: git config --replace-all core.hooksPath $MANAGED_HOOKS"* ]]
}

@test "R5: enabled sibling alone supplies its recorded managed path" {
  linked_managed_hooks_fixture
  rmdir "$MANAGED_HOOKS"
  MANAGED_HOOKS="$BATS_TEST_TMPDIR/owner-managed-hooks"
  mkdir "$MANAGED_HOOKS"
  jq --arg managed "$MANAGED_HOOKS" '.git_hooks.managed_hooks_path = $managed' \
    "$MAIN_OWNER_PATH" > "$MAIN_OWNER_PATH.tmp"
  mv "$MAIN_OWNER_PATH.tmp" "$MAIN_OWNER_PATH"
  git -C "$PROJECT_DIR" config core.hooksPath .husky/_
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"git config --replace-all core.hooksPath $MANAGED_HOOKS"* ]]
}

@test "R5: managed directory alone rejects a linked-worktree husky reset" {
  linked_managed_hooks_fixture
  rm "$MAIN_OWNER_PATH"
  git -C "$PROJECT_DIR" config core.hooksPath .husky/_
  run_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"git config --replace-all core.hooksPath $MANAGED_HOOKS"* ]]
}

@test "R5: managed directory alone accepts the linked-worktree managed path" {
  linked_managed_hooks_fixture
  rm "$MAIN_OWNER_PATH"
  run_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"core.hooksPath:"* ]]
}

# --- Round 3: every harness pins the runtime and the owner-recorded root ---

@test "R3: Claude-only owner rejects a retargeted runtime with unchanged hooks" {
  registered_claude_fixture
  mkdir -p "$BATS_TEST_TMPDIR/other-payload"
  rm "$PROJECT_DIR/.trellis/runtime"
  ln -s "$BATS_TEST_TMPDIR/other-payload" "$PROJECT_DIR/.trellis/runtime"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".trellis/runtime: runtime anchor missing or does not match owner"* ]]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]]
}

@test "R3: Codex-only owner rejects a retargeted runtime with unchanged hooks" {
  registered_codex_fixture
  mkdir -p "$BATS_TEST_TMPDIR/other-payload"
  rm "$PROJECT_DIR/.trellis/runtime"
  ln -s "$BATS_TEST_TMPDIR/other-payload" "$PROJECT_DIR/.trellis/runtime"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".trellis/runtime: runtime anchor missing or does not match owner"* ]]
  [[ "$output" != *"Tier 1+2 hooks not registered"* ]]
}

@test "R3: JSON harness owners reject missing and directory-replaced runtime anchors" {
  registered_claude_fixture
  registered_codex_fixture
  for harness in claude codex; do
    write_attachment_owner "$harness"
    target="$(readlink "$PROJECT_DIR/.trellis/runtime")"
    rm "$PROJECT_DIR/.trellis/runtime"
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *".trellis/runtime: runtime anchor missing or does not match owner"* ]]
    mkdir "$PROJECT_DIR/.trellis/runtime"
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *".trellis/runtime: runtime anchor missing or does not match owner"* ]]
    rmdir "$PROJECT_DIR/.trellis/runtime"
    ln -s "$target" "$PROJECT_DIR/.trellis/runtime"
  done
}

@test "R3: JSON harness owners reject redirected payloads despite unchanged runtime link text" {
  registered_claude_fixture
  registered_codex_fixture
  target="$(readlink "$PROJECT_DIR/.trellis/runtime")"
  for harness in claude codex; do
    write_attachment_owner "$harness"
    mv "$target" "$BATS_TEST_TMPDIR/moved-payload"
    ln -s "$BATS_TEST_TMPDIR/moved-payload" "$target"
    [ "$(readlink "$PROJECT_DIR/.trellis/runtime")" = "$target" ]
    run_check
    [ "$status" -eq 1 ]
    [[ "$output" == *".trellis/runtime: runtime anchor missing or does not match owner"* ]]
    rm "$target"
    mv "$BATS_TEST_TMPDIR/moved-payload" "$target"
  done
}

@test "R3: nested Git toplevel cannot hide an attached ancestor owner" {
  registered_codex_fixture
  nested="$PROJECT_DIR/subdirectory"
  mkdir "$nested"
  git -C "$nested" init -q -b main
  # Two commits so the gated range's base resolves in the nested repo and
  # config loads; the owner check is what must refuse. The spec 067 resolver
  # derives the range in the working directory, so the run starts there too.
  git -C "$nested" -c commit.gpgsign=false commit --allow-empty -qm one
  git -C "$nested" -c commit.gpgsign=false commit --allow-empty -qm two
  rm "$PROJECT_DIR/.codex/hooks.json"
  for harness_env in CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR; do
    unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
    export "$harness_env=$nested"
    run "$BASH_BIN" -c "cd '$nested' && '$BASH_BIN' '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"project root must equal the owner-recorded worktree path"* ]]
    [[ "$output" != *"not attached"* ]]
  done
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
  run "$BASH_BIN" -c "cd '$nested' && '$BASH_BIN' '$SCRIPT' --range=HEAD~1..HEAD"
  [ "$status" -eq 1 ]
  [[ "$output" == *"project root must equal the owner-recorded worktree path"* ]]
  [[ "$output" != *"not attached"* ]]
}

@test "R3: exported Git identity variables cannot hide the attached worktree" {
  registered_codex_fixture
  decoy="$BATS_TEST_TMPDIR/unattached-repo"
  mkdir "$decoy" "$PROJECT_DIR/subdirectory"
  git -C "$decoy" init -q -b main
  rm "$PROJECT_DIR/.codex/hooks.json" "$PROJECT_DIR/.trellis.json"
  export GIT_DIR="$decoy/.git" GIT_WORK_TREE="$PROJECT_DIR"
  export GIT_COMMON_DIR="$decoy/.git" GIT_INDEX_FILE="$decoy/.git/index"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
  [[ "$output" != *"not attached"* ]]
  # The PWD fallback must also ignore the exported identity before discovery.
  unset CLAUDE_PROJECT_DIR CODEX_PROJECT_DIR
  export GIT_WORK_TREE="$decoy"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *".codex/hooks.json: file missing"* ]]
  # A plain subdirectory cannot become a toplevel through GIT_WORK_TREE.
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR/subdirectory"
  export GIT_WORK_TREE="$CLAUDE_PROJECT_DIR"
  run_check
  [ "$status" -eq 1 ]
  [[ "$output" == *"project root must equal the Git worktree top level"* ]]
  [[ "$output" != *"not attached"* ]]
}
