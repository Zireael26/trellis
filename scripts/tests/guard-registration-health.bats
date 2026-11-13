#!/usr/bin/env bats
# Doctor rows for stall-safe bright-line guards: perl must exist (ERROR), and a
# rendered guard registration must start through guard-supervise.pl with a 30s
# timeout, and the attach-rendered Claude settings must carry onFailure block
# when the installed Claude Code supports it (WARN, re-render only). Fixtures
# are private copies of the templates; claude is a stub, never the real CLI.
REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/guard-health.XXXXXX")"
  ROOT="$SANDBOX/project"
  mkdir -p "$ROOT/.claude" "$ROOT/.codex" "$SANDBOX/bin" "$SANDBOX/claude-bin"
  # shellcheck disable=SC1090
  . "$REPO/scripts/lib/attachment.sh"
  # shellcheck disable=SC1090
  . "$REPO/scripts/lib/health-checks.sh"
  unset TRELLIS_ATTACH_CALLER_PATH
  PATH="$SANDBOX/claude-bin:/usr/bin:/bin"
}

stub_claude() {
  printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$1" > "$SANDBOX/claude-bin/claude"
  chmod 755 "$SANDBOX/claude-bin/claude"
}

# guard_hook <name>: jq selector for a guard's hook in either command form.
guard_hook() {
  printf '.hooks[][].hooks[] | select([.command] + (.args // []) | join(" ") | contains("/%s.sh"))' "$1"
}

teardown() { [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"; }

# Rendered settings plus the supervisor their commands reference.
render() {
  cp "$REPO/core-rules/legacy-hooks/claude-settings.local.json" "$ROOT/.claude/settings.local.json"
  cp "$REPO/core-rules/legacy-hooks/codex-hooks.local.json" "$ROOT/.codex/hooks.json"
  mkdir -p "$ROOT/.trellis/runtime/core-rules/hooks/lib" "$ROOT/.trellis/runtime/core-rules/templates" "$ROOT/.claude/hooks/lib"
  # This models an intact legacy runtime, not just its supervisor (T34: the
  # legacy surface is core-rules/legacy-hooks; production templates are native). A runtime
  # with a missing harness template is now correctly diagnosed as broken.
  cp "$REPO/core-rules/legacy-hooks/claude-settings.local.json" "$ROOT/.trellis/runtime/core-rules/templates/claude-settings.local.json"
  cp "$REPO/core-rules/legacy-hooks/codex-hooks.local.json" "$ROOT/.trellis/runtime/core-rules/templates/codex-hooks.local.json"
  : > "$ROOT/.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl"
  : > "$ROOT/.claude/hooks/lib/guard-supervise.pl"
}

@test "perl on PATH -> silent; missing -> ERROR" {
  run hc_guard_supervisor_perl
  [ "$status" -eq "$HC_OK" ]
  [ -z "$output" ]
  local tool
  for tool in bash sh; do ln -s "$(command -v "$tool")" "$SANDBOX/bin/$tool"; done
  if output="$(PATH="$SANDBOX/bin" hc_guard_supervisor_perl)"; then status=0; else status=$?; fi
  [ "$status" -eq "$HC_ERROR" ] || { echo "status=$status $output"; false; }
  [[ "$output" == *"perl not found"* ]] || false
}

@test "freshly rendered templates -> silent OK; no rendered settings -> silent OK" {
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ]
  [ -z "$output" ]
  render
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "status=$status $output"; false; }
  [ -z "$output" ]
}

@test "a 5s or unsupervised guard registration -> WARN naming file, guard and remedy" {
  local f="$ROOT/.claude/settings.local.json"
  render
  jq "($(guard_hook block-destructive) | .timeout) = 5" "$f" > "$f.next" && mv "$f.next" "$f"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ] || { echo "status=$status $output"; false; }
  [[ "$output" == *".claude/settings.local.json: block-destructive (timeout 5)"* ]] || { echo "$output"; false; }
  [[ "$output" == *"detach + attach"* ]] || false
  f="$ROOT/.codex/hooks.json"
  jq '(.hooks.PreToolUse[].hooks[] | select(.command | contains("/reread-guard.sh")) | .command) =
      "\"$PWD/.trellis/runtime/core-rules/codex/hooks/reread-guard.sh\""' "$f" > "$f.next" && mv "$f.next" "$f"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *".codex/hooks.json: reread-guard (timeout 30, unsupervised)"* ]] || { echo "$output"; false; }
}

@test "a supervised registration whose guard-supervise.pl is missing -> WARN" {
  render
  mv "$ROOT/.trellis/runtime/core-rules/hooks/lib/guard-supervise.pl" "$SANDBOX/aside.pl"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ] || { echo "status=$status $output"; false; }
  [[ "$output" == *".claude/settings.local.json: block-destructive (timeout 30, supervisor missing)"* ]] || { echo "$output"; false; }
  [[ "$output" == *".codex/hooks.json: reread-guard (timeout 30, supervisor missing)"* ]] || { echo "$output"; false; }
}

@test "a legacy direct-copy .claude/settings.json is checked too" {
  local f="$ROOT/.claude/settings.json"
  render
  cp "$REPO/core-rules/templates/claude-settings.json" "$f"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "status=$status $output"; false; }
  jq '(.hooks.PreToolUse[].hooks[] | select(.command | contains("/skill-preload-guard.sh")) | .timeout) = 5' \
    "$f" > "$f.next" && mv "$f.next" "$f"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ]
  [[ "$output" == *".claude/settings.json: skill-preload-guard (timeout 5)"* ]] || { echo "$output"; false; }
}

@test "a rendered Claude guard without onFailure block -> WARN at or above 2.1.295, silent below it" {
  local f="$ROOT/.claude/settings.local.json" version
  render
  jq "($(guard_hook reread-guard)) |= del(.onFailure)" "$f" > "$f.next" && mv "$f.next" "$f"
  for version in 2.1.295 2.1.314 2.2.0; do
    stub_claude "$version"
    run hc_guard_registrations "$ROOT"
    [ "$status" -eq "$HC_WARN" ] || { echo "$version: status=$status $output"; false; }
    [[ "$output" == *".claude/settings.local.json: reread-guard (timeout 30, no onFailure block)"* ]] ||
      { echo "$version: $output"; false; }
    [[ "$output" != *"block-destructive"* ]] || { echo "$version: $output"; false; }
  done
  # Below the floor, or with no readable claude, attach renders without the
  # key on purpose, so its absence is healthy.
  stub_claude 2.1.294
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "status=$status $output"; false; }
  rm "$SANDBOX/claude-bin/claude"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "status=$status $output"; false; }
}

# Spec 074 T67: skill-slash-guard is a bright-line guard too. A render from
# before it was supervised (5 s, direct) is not stall-safe.
@test "an unsupervised or onFailure-less skill-slash-guard -> WARN" {
  local f="$ROOT/.claude/settings.local.json"
  render
  jq '.hooks.UserPromptExpansion[0].hooks[0] = {type:"command",command:"/usr/bin/env",
      args:["TRELLIS_ROOT=${CLAUDE_PROJECT_DIR}/.trellis/runtime",
            "${CLAUDE_PROJECT_DIR}/.trellis/runtime/core-rules/hooks/skill-slash-guard.sh"],timeout:5}' \
    "$f" > "$f.next" && mv "$f.next" "$f"
  stub_claude 2.1.294
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ] || { echo "status=$status $output"; false; }
  [[ "$output" == *".claude/settings.local.json: skill-slash-guard (timeout 5, unsupervised)"* ]] || { echo "$output"; false; }
  render
  jq "($(guard_hook skill-slash-guard)) |= del(.onFailure)" "$f" > "$f.next" && mv "$f.next" "$f"
  stub_claude 2.1.300
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_WARN" ] || { echo "status=$status $output"; false; }
  [[ "$output" == *".claude/settings.local.json: skill-slash-guard (timeout 30, no onFailure block)"* ]] ||
    { echo "$output"; false; }
}

@test "B9 L3 malformed settings are a named doctor ERROR" {
  local file content
  for file in .claude/settings.local.json .claude/settings.json .codex/hooks.json; do
    for content in '{' 'null'; do
      printf '%s\n' "$content" > "$ROOT/$file"
      run hc_guard_registrations "$ROOT"
      [ "$status" -eq "$HC_ERROR" ] || { echo "$file $status $output"; return 1; }
      [[ "$output" == *"$file: malformed settings"* ]] || { echo "$file: $output"; return 1; }
    done
    rm -f "${ROOT:?}/$file"
  done
}

@test "portable doctor reports both rows only when they are not healthy" {
  grep -q 'if perl_row="$(hc_guard_supervisor_perl)"; then :; else' "$REPO/scripts/doctor.sh"
  grep -q 'if guard_row="$(hc_guard_registrations "$root")"; then :; else' "$REPO/scripts/doctor.sh"
}

# T62: prepare the paired launcher + companion and render native registrations
# with the real T56 selector. The release lookup is deliberately isolated to
# this fixture; release-store's own verification has separate suites.
native_health_fixture() {
  local digest target version source context companion asset size manifest launcher_digest ledger
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=aarch64-apple-darwin ;;
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    Linux:aarch64) target=aarch64-unknown-linux-musl ;;
    *) skip 'unsupported native candidate fixture host' ;;
  esac
  export HOME="$SANDBOX/native user 'quoted" TRELLIS_HOME="$SANDBOX/trellis"
  NATIVE_RELEASE="$SANDBOX/release"
  export NATIVE_RELEASE
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME" "$NATIVE_RELEASE/payload/core-rules/templates" "$NATIVE_RELEASE/payload/scripts" "$ROOT/.trellis"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  git -C "$ROOT" init -q
  cp -R "$REPO/core-rules/native" "$NATIVE_RELEASE/payload/core-rules/native"
  cp "$REPO/scripts/trellis-launcher.sh" "$NATIVE_RELEASE/payload/scripts/trellis-launcher.sh"
  manifest="$NATIVE_RELEASE/payload/core-rules/native/artifacts.json"
  asset="$NATIVE_RELEASE/payload/core-rules/native/$target/trellis-hooks"
  if [ ! -f "$asset" ]; then
    mkdir -p "${asset%/*}"; printf 'inert candidate fixture\n' > "$asset"
    digest="$(_attachment_hash "$asset")"
    size="$(wc -c < "$asset" | tr -d ' ')"
    jq --arg t "$target" --arg digest "$digest" --argjson size "$size" \
      '.assets[$t] = {path:($t + "/trellis-hooks"),sha256:$digest,size:$size,format:"fixture",signature:"fixture",minimum_os:null}' \
      "$manifest" > "$manifest.next" && mv "$manifest.next" "$manifest"
  fi
  version="$(jq -r '.version' "$manifest")"
  digest="$(jq -r --arg t "$target" '.assets[$t].sha256' "$manifest")"
  companion="$TRELLIS_HOME/bin/native/$version/$target/$digest/trellis-hooks"
  mkdir -p "${companion%/*}"
  chmod 700 "$TRELLIS_HOME/bin" "$TRELLIS_HOME/bin/native" "$TRELLIS_HOME/bin/native/$version" "$TRELLIS_HOME/bin/native/$version/$target" "${companion%/*}"
  cp "$NATIVE_RELEASE/payload/core-rules/native/$target/trellis-hooks" "$companion"
  chmod 500 "$companion"
  python3 -I - "$NATIVE_RELEASE/payload/scripts/trellis-launcher.sh" "$HOME/.local/bin/trellis" "$companion" "$digest" "$version" <<'PY'
from pathlib import Path
import sys
source,dest,entry,digest,version=sys.argv[1:]
s=Path(source).read_text(); q=lambda x:"'"+x.replace("'", "'\\\\''")+"'"
for k,v in (('launcher_native_entry',entry),('launcher_native_sha256',digest),('launcher_native_version',version)):
    before=k+"=''\n"
    assert s.count(before)==1
    s=s.replace(before,k+'='+q(v)+'\n')
p=Path(dest); p.write_text(s); p.chmod(0o755)
PY
  launcher_digest="$(_attachment_hash "$HOME/.local/bin/trellis")"
  ledger="$TRELLIS_HOME/bin/launchers/$launcher_digest/trellis"
  mkdir -p "${ledger%/*}"; chmod 700 "$TRELLIS_HOME/bin/launchers" "${ledger%/*}"
  cp "$HOME/.local/bin/trellis" "$ledger"; chmod 500 "$ledger"
  printf '{"active_cli_release":"%s"}\n' "$version" > "$TRELLIS_HOME/config.json"
  ln -s "$NATIVE_RELEASE/payload" "$ROOT/.trellis/runtime"
  source="$NATIVE_RELEASE/payload/core-rules/templates/claude-settings.local.json"
  jq -n '{hooks:{PreToolUse:(["Bash","Edit|MultiEdit|Write","Skill"] | map({matcher:.,hooks:[{type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event","claude","PreToolUse"],timeout:30,onFailure:"block"}]})), UserPromptSubmit:[{hooks:[{type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event","claude","UserPromptSubmit"],timeout:30,onFailure:"block"}]}], UserPromptExpansion:[{matcher:".*",hooks:[{type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event","claude","UserPromptExpansion"],timeout:30,onFailure:"block"}]}], Stop:[{hooks:[{type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event","claude","Stop"],timeout:30,onFailure:"block"}]}]}}' > "$source"
  context="$(attachment_contextual_render_context "$TRELLIS_HOME")" || return 1
  stub_claude 2.1.300
  attachment_contextual_template_render "$source" core-rules/templates/claude-settings.local.json "$context" "$ROOT" > "$ROOT/.claude/settings.local.json" || return 1
  native_health_owner claude
  release_store_locate() { printf '%s\n' "$NATIVE_RELEASE"; }
}

native_health_owner() {
  local harness="$1" common checkout worktree owner file render version
  common="$(CDPATH='' cd "$ROOT/.git" && pwd -P)"
  checkout="$(_attachment_hash_text "$common")"
  worktree="$(_attachment_hash_text "$ROOT")"
  owner="$TRELLIS_HOME/state/attachments/$checkout/$worktree.json"
  mkdir -p "${owner%/*}"; chmod 700 "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/attachments" "${owner%/*}"
  file="$ROOT/.claude/settings.local.json"; render=.claude/settings.local.json
  if [ "$harness" = codex ]; then file="$ROOT/.codex/hooks.json"; render=.codex/hooks.json; fi
  version="$(jq -r '.version' "$NATIVE_RELEASE/payload/core-rules/native/artifacts.json")"
  if [ ! -f "$owner" ]; then
    jq -n --arg root "$ROOT" --arg co "$checkout" --arg wt "$worktree" --arg target "$NATIVE_RELEASE/payload" --arg version "$version" \
      '{status:"committed",project_root:$root,worktree_root:$root,checkout_id:$co,worktree_id:$wt,release:$version,artifacts:[{kind:"symlink",path:".trellis/runtime",target:$target}],renders:[]}' > "$owner"
  fi
  jq --arg render "$render" --slurpfile doc "$file" \
    '.renders |= (map(select(.path != $render)) + [{path:$render,owned_keys:[{path:["hooks","UserPromptSubmit"],value:$doc[0].hooks.UserPromptSubmit}]}])' "$owner" > "$owner.next" && mv "$owner.next" "$owner"
  chmod 600 "$owner"
}

native_health_codex() {
  local source="$NATIVE_RELEASE/payload/core-rules/templates/codex-hooks.local.json" context
  jq -n '{hooks:{PreToolUse:(["Bash","Edit|MultiEdit|Write"] | map({matcher:.,hooks:[{type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event","codex","PreToolUse"],timeout:30}]})), UserPromptSubmit:[{hooks:[{type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event","codex","UserPromptSubmit"],timeout:30}]}], Stop:[{hooks:[{type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event","codex","Stop"],timeout:30}]}]}}' > "$source"
  context="$(attachment_contextual_render_context "$TRELLIS_HOME")" || return 1
  attachment_contextual_template_render "$source" core-rules/templates/codex-hooks.local.json "$context" "$ROOT" > "$ROOT/.codex/hooks.json" || return 1
  native_health_owner codex
}

@test "T62 native guard coverage is required and malformed coverage is ERROR" {
  native_health_fixture
  local f="$ROOT/.claude/settings.local.json" original="$SANDBOX/original.json" mutation
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "valid native: $status $output"; return 1; }
  cp "$f" "$original"
  for mutation in 'del(.hooks.UserPromptSubmit)' 'del(.hooks.PreToolUse[1])' '(.hooks.PreToolUse[0].hooks[0].type) = "prompt"' '(.hooks.PreToolUse[0].hooks[0].timeout) = 5' 'del(.hooks.PreToolUse[0].hooks[0].onFailure)'; do
    jq "$mutation" "$original" > "$f"
    run hc_guard_registrations "$ROOT"
    [ "$status" -eq "$HC_ERROR" ] || { echo "$mutation: status=$status output=$output"; return 1; }
  done
}

@test "B9 empty Codex directory is not Codex attachment evidence" {
  native_health_fixture
  [ -d "$ROOT/.codex" ] || return 1
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "absent Codex: $status $output"; return 1; }
  # A release may ship both native templates while only Claude is attached.
  native_health_codex
  local owner
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  jq '.renders |= map(select(.path != ".codex/hooks.json"))' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  rm -f "${ROOT:?}/.codex/hooks.json"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "unused Codex native template: $status $output"; return 1; }
}

@test "B9 empty Claude directory is not Claude attachment evidence" {
  native_health_fixture; native_health_codex
  local owner
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  jq '.renders |= map(select(.path != ".claude/settings.local.json"))' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  rm -f "${ROOT:?}/.claude/settings.local.json"
  mv "$NATIVE_RELEASE/payload/core-rules/templates/claude-settings.local.json" "$SANDBOX/unused-claude-template"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "absent Claude: $status $output"; return 1; }
  cp "$SANDBOX/unused-claude-template" "$NATIVE_RELEASE/payload/core-rules/templates/claude-settings.local.json"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "unused Claude native template: $status $output"; return 1; }
}

@test "B9 Claude-only native project permits a user Codex hook" {
  native_health_fixture; native_health_codex
  local owner
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  jq '.renders |= map(select(.path != ".codex/hooks.json"))' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  mkdir -p "$ROOT/.codex/hooks"
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/.codex/hooks/notify.sh"
  jq -n '{hooks:{PreToolUse:[{hooks:[{type:"command",command:".codex/hooks/notify.sh"}]}]}}' > "$ROOT/.codex/hooks.json"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "user Codex hook: $status $output"; return 1; }
}

@test "B9 Codex-only native project permits a user Claude hook" {
  native_health_fixture; native_health_codex
  local owner
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  jq '.renders |= map(select(.path != ".claude/settings.local.json"))' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  rm -f "${ROOT:?}/.claude/settings.local.json"
  mkdir -p "$ROOT/.claude/hooks"
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/.claude/hooks/format.sh"
  jq -n '{hooks:{PreToolUse:[{hooks:[{type:"command",command:".claude/hooks/format.sh"}]}]}}' > "$ROOT/.claude/settings.json"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "user Claude hook: $status $output"; return 1; }
}

@test "B9 a plain project user Claude hook is unarmed and doctor OK" {
  local deps="$REPO/core-rules/hooks/lib/deps.sh" state
  mkdir -p "$ROOT/.claude/hooks"
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/.claude/hooks/format.sh"
  jq -n '{hooks:{PreToolUse:[{hooks:[{type:"command",command:".claude/hooks/format.sh"}]}]}}' > "$ROOT/.claude/settings.json"
  state="$(. "$deps"; _se_turn_baseline_arming "$ROOT" claude)"
  [ "$state" = unarmed ] || { echo "user hook state: $state"; return 1; }
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "user hook doctor: $status $output"; return 1; }
}

@test "B9 owned Claude with missing template is a guard ERROR" {
  native_health_fixture
  local owner
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  jq '.renders |= map(if .path == ".claude/settings.local.json" then .owned_keys = [] else . end)' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  printf '{}\n' > "$ROOT/.claude/settings.local.json"
  rm -f "${NATIVE_RELEASE:?}/payload/core-rules/templates/claude-settings.local.json"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_ERROR" ] || { echo "missing owned Claude template: $status $output"; return 1; }
  [[ "$output" == *"claude native wiring or companion could not be verified"* ]] || false
}

@test "B9 owned Codex with missing template is a guard ERROR" {
  native_health_fixture; native_health_codex
  local owner
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  jq '.renders |= map(if .path == ".codex/hooks.json" then .owned_keys = [] else . end)' "$owner" > "$owner.next" && mv "$owner.next" "$owner" && chmod 600 "$owner"
  printf '{}\n' > "$ROOT/.codex/hooks.json"
  rm -f "${NATIVE_RELEASE:?}/payload/core-rules/templates/codex-hooks.local.json"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_ERROR" ] || { echo "missing owned Codex template: $status $output"; return 1; }
  [[ "$output" == *"codex native wiring or companion could not be verified"* ]] || false
}

@test "T62 Codex native guard coverage and prompt binding are enforced" {
  native_health_fixture; native_health_codex
  local f="$ROOT/.codex/hooks.json" original="$SANDBOX/codex-original.json" mutation
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "valid Codex native: $status $output"; return 1; }
  cp "$f" "$original"
  for mutation in 'del(.hooks.UserPromptSubmit)' 'del(.hooks.PreToolUse[1])' '(.hooks.PreToolUse[0].hooks[0].timeout) = 5'; do
    jq "$mutation" "$original" > "$f"
    run hc_guard_registrations "$ROOT"
    [ "$status" -eq "$HC_ERROR" ] || { echo "$mutation: status=$status output=$output"; return 1; }
  done
}

@test "T62 native guard health rejects short and fractional member timeouts" {
  native_health_fixture; native_health_codex
  local harness file original="$SANDBOX/timeout-original.json" timeout
  for harness in claude codex; do
    file="$ROOT/.codex/hooks.json"
    [ "$harness" != claude ] || file="$ROOT/.claude/settings.local.json"
    cp "$file" "$original"
    for timeout in 29 30.5; do
      jq --argjson timeout "$timeout" '.hooks.PreToolUse[0].hooks[0].timeout = $timeout' "$original" > "$file"
      run hc_guard_registrations "$ROOT"
      [ "$status" -eq "$HC_ERROR" ] || { echo "$harness timeout $timeout: $status $output"; return 1; }
      [[ "$output" == *"native member coverage or wiring differs"* ]] || { echo "$harness timeout $timeout: $output"; return 1; }
    done
    for timeout in 30 31; do
      jq --argjson timeout "$timeout" '.hooks.PreToolUse[0].hooks[0].timeout = $timeout' "$original" > "$file"
      run hc_guard_registrations "$ROOT"
      [ "$status" -eq "$HC_OK" ] || { echo "$harness timeout $timeout: $status $output"; return 1; }
    done
    cp "$original" "$file"
  done
}

@test "T62 native health preserves unrelated project hooks and rejects missing settings" {
  native_health_fixture
  local f="$ROOT/.claude/settings.local.json"
  jq '.hooks.PreToolUse += [{matcher:"Read",hooks:[{type:"command",command:"project-owned",timeout:10}]}]' "$f" > "$f.next" && mv "$f.next" "$f"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "project hook: $status $output"; return 1; }
  mv "$f" "$SANDBOX/removed-settings"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_ERROR" ] || { echo "missing settings: $status $output"; return 1; }
}

native_health_acl_add() {
  case "$(uname -s)" in
    Darwin)
      if [ -d "$1" ]; then chmod +a 'everyone allow add_file,delete_child' "$1" 2>/dev/null
      else chmod +a 'everyone allow write' "$1" 2>/dev/null; fi ;;
    Linux)
      command -v setfacl >/dev/null 2>&1 || skip 'setfacl unavailable'
      setfacl -m "u:$(id -u):rw,m::---" "$1" 2>/dev/null ;;
    *) skip 'ACL fixture unsupported' ;;
  esac
}
native_health_acl_clear() {
  case "$(uname -s)" in Darwin) chmod -N "$1" ;; Linux) setfacl -b "$1" ;; esac
}

@test "T62 native guard and launcher health reject ACLs even behind xattrs" {
  native_health_fixture
  local owner companion path digest_dir target_dir version_dir
  owner="$(find "$TRELLIS_HOME/state/attachments" -type f -name '*.json')"
  companion="$(find "$TRELLIS_HOME/bin/native" -type f -name trellis-hooks)"
  [ -n "$owner" ] && [ -n "$companion" ]
  digest_dir="${companion%/*}"; target_dir="${digest_dir%/*}"; version_dir="${target_dir%/*}"
  if [ "$(uname -s)" = Darwin ] && command -v xattr >/dev/null 2>&1; then
    xattr -w com.trellis.test 'fixture' "$TRELLIS_HOME/bin/native" || skip 'xattrs unavailable'
  fi
  for path in "$TRELLIS_HOME" "$TRELLIS_HOME/bin" "$TRELLIS_HOME/bin/native" "$version_dir" "$target_dir" "$digest_dir" "$companion"; do
    native_health_acl_add "$path" || skip 'ACLs unavailable on test filesystem'
    run hc_guard_registrations "$ROOT"
    [ "$status" -eq "$HC_ERROR" ] || { echo "guard accepted ACL on $path: $status $output"; return 1; }
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_ERROR" ] || { echo "launcher accepted ACL on $path: $status $output"; return 1; }
    native_health_acl_clear "$path"
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_OK" ] || { echo "xattr without ACL rejected: $path: $status $output"; return 1; }
  done
  for path in "$TRELLIS_HOME/state" "${owner%/*}" "$owner"; do
    native_health_acl_add "$path" || skip 'ACLs unavailable on test filesystem'
    run hc_guard_registrations "$ROOT"
    [ "$status" -eq "$HC_ERROR" ] || { echo "guard accepted owner ACL on $path: $status $output"; return 1; }
    native_health_acl_clear "$path"
  done
}

@test "T62 active native release rejects an unpinned launcher" {
  native_health_fixture
  local launcher="$HOME/.local/bin/trellis" original="$SANDBOX/launcher-original" template="$NATIVE_RELEASE/payload/scripts/trellis-launcher.sh"
  cp "$launcher" "$original"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_OK" ] || { echo "pinned control: $status $output"; return 1; }
  cp "$template" "$launcher"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "blank pins accepted: $status $output"; return 1; }
  awk '!/^launcher_native_(entry|sha256|version)=/' "$template" > "$launcher"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "missing pins accepted: $status $output"; return 1; }
  cp "$original" "$launcher"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_OK" ] || { echo "restored pinned control: $status $output"; return 1; }
}

@test "T62 native launcher currency requires its expected private digest ledger" {
  native_health_fixture
  local launcher="$HOME/.local/bin/trellis" digest ledger altered
  digest="$(_attachment_hash "$launcher")"
  ledger="$TRELLIS_HOME/bin/launchers/$digest/trellis"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_OK" ] || { echo "paired launcher: $status $output"; return 1; }
  mv "$ledger" "$SANDBOX/ledger-saved"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "missing ledger: $status $output"; return 1; }
  cp "$SANDBOX/ledger-saved" "$ledger"; chmod 500 "$ledger"
  chmod u+w "$ledger"; printf '# ledger tamper\n' >> "$ledger"; chmod 500 "$ledger"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "tampered ledger: $status $output"; return 1; }
  chmod u+w "$ledger"; cp "$SANDBOX/ledger-saved" "$ledger"; chmod 500 "$ledger"
  chmod 700 "$ledger"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "unsafe ledger mode: $status $output"; return 1; }
  chmod 500 "$ledger"
  mv "$ledger" "$SANDBOX/ledger-original"
  ln -s "$SANDBOX/ledger-original" "$ledger"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "symlinked ledger: $status $output"; return 1; }
  mv "$ledger" "$SANDBOX/ledger-link"; mv "$SANDBOX/ledger-original" "$ledger"
  # A forged ledger matching a forged installed launcher is not proof: the
  # expected bytes must still be derived from the verified release template.
  printf '# altered launcher\n' >> "$launcher"
  altered="$(_attachment_hash "$launcher")"
  mkdir -p "$TRELLIS_HOME/bin/launchers/$altered"; chmod 700 "$TRELLIS_HOME/bin/launchers/$altered"
  cp "$launcher" "$TRELLIS_HOME/bin/launchers/$altered/trellis"; chmod 500 "$TRELLIS_HOME/bin/launchers/$altered/trellis"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "forged launcher and ledger: $status $output"; return 1; }
}

@test "T62 real pair publisher produces a current launcher and ledger" {
  [ "$(uname -s):$(uname -m)" = Darwin:arm64 ] || skip 'real signed Darwin asset fixture'
  native_health_fixture
  local version target release
  version="$(jq -r '.version' "$NATIVE_RELEASE/payload/core-rules/native/artifacts.json")"
  target=aarch64-apple-darwin; release="$TRELLIS_HOME/releases/$version"
  mkdir -p "$release"; cp -R "$NATIVE_RELEASE/payload" "$release/payload"
  python3 -I - "$release" "$version" "$target" <<'PY'
import hashlib,json,os,sys
from pathlib import Path
release=Path(sys.argv[1]); version,target=sys.argv[2:]
paths=['scripts/trellis-launcher.sh','core-rules/native/artifacts.json',f'core-rules/native/{target}/trellis-hooks']
rows=[]
for name in paths:
    path=release/'payload'/name; data=path.read_bytes()
    oid=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    rows.append({'path':name,'oid':oid,'mode':'100755' if os.stat(path).st_mode & 0o111 else '100644'})
(release/'release.json').write_text(json.dumps({'version':version,'tree':rows}))
PY
  # Keep this test's release lookup/outer verification isolated; the real B1
  # publisher still validates and publishes its template, asset and ledger.
  NATIVE_RELEASE="$release"; export NATIVE_RELEASE
  mv "$HOME/.local/bin/trellis" "$SANDBOX/manual-launcher"
  mv "$TRELLIS_HOME/bin/native" "$SANDBOX/manual-native"
  mv "$TRELLIS_HOME/bin/launchers" "$SANDBOX/manual-ledgers"
  # shellcheck source=scripts/lib/trellis-home.sh disable=SC1090
  . "$REPO/scripts/lib/trellis-home.sh"
  release_store_locate() { printf '%s\n' "$NATIVE_RELEASE"; }
  release_store_verify_path() { return 0; }
  run trellis_home_install_launcher "$release/payload/scripts/trellis-launcher.sh" "$HOME/.local/bin/trellis" "$TRELLIS_HOME" "$version"
  [ "$status" -eq 0 ] || { echo "real pair publisher: $status $output"; return 1; }
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_OK" ] || { echo "published pair not current: $status $output"; return 1; }
}

@test "T62 native launcher ledger ACLs are integrity errors" {
  native_health_fixture
  local digest ledger path
  digest="$(_attachment_hash "$HOME/.local/bin/trellis")"
  ledger="$TRELLIS_HOME/bin/launchers/$digest/trellis"
  for path in "$TRELLIS_HOME/bin/launchers" "${ledger%/*}" "$ledger"; do
    native_health_acl_add "$path" || skip 'ACLs unavailable on test filesystem'
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_ERROR" ] || { echo "ledger ACL on $path: $status $output"; return 1; }
    native_health_acl_clear "$path"
  done
}

@test "T62 launcher currency rejects group or world writable launcher" {
  native_health_fixture
  local launcher="$HOME/.local/bin/trellis" mode
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_OK" ] || { echo "initial launcher: $status $output"; return 1; }
  for mode in 0775 0757 0777; do
    chmod "$mode" "$launcher"
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_ERROR" ] || { echo "launcher mode $mode: $status $output"; return 1; }
    chmod 0755 "$launcher"
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_OK" ] || { echo "restored launcher: $status $output"; return 1; }
  done
}

@test "T62 launcher currency rejects group or world writable launcher directory" {
  native_health_fixture
  local dir="$HOME/.local/bin" mode
  for mode in 0757 0777; do
    chmod "$mode" "$dir"
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_ERROR" ] || { echo "launcher directory mode $mode: $status $output"; return 1; }
    chmod 0755 "$dir"
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_OK" ] || { echo "restored directory: $status $output"; return 1; }
  done
}

native_health_private_group() {
  /usr/bin/python3 -I - "$1" <<'PY'
import grp,os,pwd,sys
try:
    s=os.stat(sys.argv[1]); uid=os.getuid(); gid=s.st_gid
    user=pwd.getpwuid(uid); group=grp.getgrgid(gid)
    accounts=pwd.getpwall(); groups=grp.getgrall()
    safe=(gid!=0 and gid==os.getgid()==user.pw_gid and group.gr_name==user.pw_name
          and any(p.pw_uid==uid and p.pw_gid==gid and p.pw_name==user.pw_name for p in accounts)
          and any(g.gr_gid==gid and g.gr_name==group.gr_name for g in groups)
          and not any(p.pw_gid==gid and (p.pw_uid!=uid or p.pw_name!=user.pw_name) for p in accounts)
          and all(m==user.pw_name for m in group.gr_mem)
          and all(m==user.pw_name for g in groups if g.gr_gid==gid for m in g.gr_mem))
except Exception:
    safe=False
sys.exit(0 if safe else 1)
PY
}

native_group_policy_test() {
  local mode="$1" policy="$SANDBOX/launcher-policy.py"
  : > "$policy"
  if declare -F trellis_home_launcher_directory_policy_python >/dev/null; then
    trellis_home_launcher_directory_policy_python > "$policy" || return 1
  fi
  run /usr/bin/python3 -I "$REPO/scripts/tests/helpers/launcher-group-policy-test.py" \
    "$REPO/scripts/lib/health-checks.sh" "$REPO/scripts/lib/trellis-home.sh" "$policy" "$mode"
  [ "$status" -eq 0 ] || { echo "group policy $mode: $output"; return 1; }
}

@test "T62 installer and doctor agree on the same private and shared group fixtures" {
  native_group_policy_test same-fixture
}

@test "T62 private group rejects other primary gids gid zero duplicate groups and enumeration failure" {
  native_group_policy_test enumeration
}

@test "T62 launcher currency admits only user-private group write on its directory" {
  native_health_fixture
  local dir="$HOME/.local/bin" expected
  # Exercise the real host group; the separate shared fixture matrix covers
  # both private and shared groups even without permission to chgrp.
  if native_health_private_group "$dir"; then expected="$HC_OK"; else expected="$HC_ERROR"; fi
  chmod 0775 "$dir"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$expected" ] || { echo "real group 0775 expected $expected: $status $output"; return 1; }
  chmod 0777 "$dir"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "world writable directory accepted: $status $output"; return 1; }

}

@test "T62 real publisher and doctor agree on the same 0775 launcher directory" {
  native_health_fixture
  local dir="$HOME/.local/bin" expected version target release
  chmod 0775 "$dir"
  if native_health_private_group "$dir"; then expected=private; else expected=shared; fi
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  if [ "$expected" = private ]; then
    [ "$status" -eq "$HC_OK" ] || { echo "private doctor: $status $output"; return 1; }
  else
    [ "$status" -eq "$HC_ERROR" ] || { echo "shared doctor: $status $output"; return 1; }
  fi
  version="$(jq -r '.version' "$NATIVE_RELEASE/payload/core-rules/native/artifacts.json")"
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=aarch64-apple-darwin ;;
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    Linux:aarch64) target=aarch64-unknown-linux-musl ;;
    *) skip 'unsupported native candidate fixture host' ;;
  esac
  release="$TRELLIS_HOME/releases/$version"
  mkdir -p "$release"; chmod 755 "$TRELLIS_HOME/releases" "$release"
  cp -R "$NATIVE_RELEASE/payload" "$release/payload"
  # Linux has no checked-in musl artifact in this checkout. Create an inert
  # static ELF header that meets the publisher's metadata validation; it is
  # never executed. Darwin uses the real signed release asset.
  /usr/bin/python3 -I - "$release" "$version" "$target" <<'PY'
import hashlib,json,os,sys
from pathlib import Path
release=Path(sys.argv[1]); version,target=sys.argv[2:]; payload=release/'payload'
asset=payload/'core-rules/native'/target/'trellis-hooks'
manifest=payload/'core-rules/native/artifacts.json'
if target.endswith('linux-musl'):
    data=bytearray(120); data[:6]=b'\x7fELF\x02\x01'
    data[18:20]=(62 if target.startswith('x86_64') else 183).to_bytes(2,'little')
    data[32:40]=(64).to_bytes(8,'little'); data[54:56]=(56).to_bytes(2,'little'); data[56:58]=(1).to_bytes(2,'little')
    data[64:68]=(1).to_bytes(4,'little'); asset.parent.mkdir(parents=True,exist_ok=True); asset.parent.chmod(0o755); asset.write_bytes(data)
    d=json.loads(manifest.read_text()); d['assets'][target]={'path':target+'/trellis-hooks','size':len(data),'sha256':hashlib.sha256(data).hexdigest(),'format':'elf-static','signature':'none','minimum_os':None}
    manifest.write_text(json.dumps(d))
paths=['scripts/trellis-launcher.sh','core-rules/native/artifacts.json',f'core-rules/native/{target}/trellis-hooks']
rows=[]
for name in paths:
    path=payload/name; data=path.read_bytes()
    oid=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
    rows.append({'path':name,'oid':oid,'mode':'100755' if os.stat(path).st_mode & 0o111 else '100644'})
(release/'release.json').write_text(json.dumps({'version':version,'tree':rows}))
PY
  NATIVE_RELEASE="$release"; export NATIVE_RELEASE
  mv "$HOME/.local/bin/trellis" "$SANDBOX/manual-launcher"
  mv "$TRELLIS_HOME/bin/native" "$SANDBOX/manual-native"
  mv "$TRELLIS_HOME/bin/launchers" "$SANDBOX/manual-ledgers"
  # shellcheck source=scripts/lib/trellis-home.sh disable=SC1090
  . "$REPO/scripts/lib/trellis-home.sh"
  release_store_locate() { printf '%s\n' "$NATIVE_RELEASE"; }
  release_store_verify_path() { return 0; }
  run trellis_home_install_launcher "$release/payload/scripts/trellis-launcher.sh" "$dir/trellis" "$TRELLIS_HOME" "$version"
  if [ "$expected" = private ]; then
    [ "$status" -eq 0 ] || { echo "private 0775 publisher: $status $output"; return 1; }
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_OK" ] || { echo "private 0775 published pair: $status $output"; return 1; }
  else
    [ "$status" -eq "$TRELLIS_EX_STATE" ] || { echo "shared 0775 publisher: $status $output"; return 1; }
    [ ! -e "$dir/trellis" ] || { echo 'unsafe group published a launcher'; return 1; }
    chmod 0755 "$dir"
    run trellis_home_install_launcher "$release/payload/scripts/trellis-launcher.sh" "$dir/trellis" "$TRELLIS_HOME" "$version"
    [ "$status" -eq 0 ] || { echo "safe 0755 publisher: $status $output"; return 1; }
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_OK" ] || { echo "safe 0755 published pair: $status $output"; return 1; }
  fi
}

@test "T62 missing unsupported-host launcher directory remains WARN" {
  native_health_fixture
  local manifest="$NATIVE_RELEASE/payload/core-rules/native/artifacts.json"
  mv "$HOME/.local/bin" "$SANDBOX/removed-bin"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "missing native launcher: $status $output"; return 1; }
  jq '.assets = {}' "$manifest" > "$manifest.next" && mv "$manifest.next" "$manifest"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_WARN" ] || { echo "unsupported-host missing launcher: $status $output"; return 1; }
  [[ "$output" == *'not identical'* ]] || { echo "missing WARN diagnostic: $output"; return 1; }
}

@test "T62 launcher currency rejects write ACL on launcher and physical directory" {
  native_health_fixture
  local dir="$HOME/.local/bin" path
  for path in "$dir/trellis" "$dir"; do
    native_health_acl_add "$path" || skip 'ACLs unavailable on test filesystem'
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_ERROR" ] || { echo "launcher ACL on $path: $status $output"; return 1; }
    native_health_acl_clear "$path"
    run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
    [ "$status" -eq "$HC_OK" ] || { echo "ACL cleared on $path: $status $output"; return 1; }
  done
}

@test "T62 launcher currency follows a safe symlinked bin and checks its physical target" {
  native_health_fixture
  local dir="$SANDBOX/physical-bin"
  mv "$HOME/.local/bin" "$dir"
  ln -s "$dir" "$HOME/.local/bin"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_OK" ] || { echo "safe symlinked bin: $status $output"; return 1; }
  chmod 0777 "$dir"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "unsafe physical bin: $status $output"; return 1; }
  chmod 0755 "$dir"
  native_health_acl_add "$dir" || skip 'ACLs unavailable on test filesystem'
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "physical bin ACL: $status $output"; return 1; }
  native_health_acl_clear "$dir"
}

@test "T62 launcher currency rejects a hardlinked ledger" {
  native_health_fixture
  local digest ledger
  digest="$(_attachment_hash "$HOME/.local/bin/trellis")"
  ledger="$TRELLIS_HOME/bin/launchers/$digest/trellis"
  ln "$ledger" "$SANDBOX/ledger-extra-link"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "hardlinked ledger: $status $output"; return 1; }
  rm -f "${SANDBOX:?}/ledger-extra-link"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_OK" ] || { echo "single-link ledger: $status $output"; return 1; }
}

@test "T62 launcher currency compares rendered pinned bytes and rejects stale companion" {
  native_health_fixture
  local companion
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_OK" ] || { echo "valid pinned launcher: $status $output"; return 1; }
  companion="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].args[4]' "$ROOT/.claude/settings.local.json")"
  chmod u+w "$companion"; printf 'tamper' >> "$companion"; chmod 500 "$companion"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "stale companion: $status $output"; return 1; }
}

@test "T62 launcher currency rejects a changed launcher, wrong release and missing companion" {
  native_health_fixture
  local launcher="$HOME/.local/bin/trellis" companion
  companion="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].args[4]' "$ROOT/.claude/settings.local.json")"
  cp "$launcher" "$SANDBOX/good-launcher"
  printf '# drift\n' >> "$launcher"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "changed launcher: $status $output"; return 1; }
  cp "$SANDBOX/good-launcher" "$launcher"
  printf '{"active_cli_release":"9.9.9"}\n' > "$TRELLIS_HOME/config.json"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "wrong release: $status $output"; return 1; }
  printf '{"active_cli_release":"%s"}\n' "$(jq -r .version "$NATIVE_RELEASE/payload/core-rules/native/artifacts.json")" > "$TRELLIS_HOME/config.json"
  mv "$companion" "$SANDBOX/missing-companion"
  run hc_launcher_currency "$HOME" "$TRELLIS_HOME"
  [ "$status" -eq "$HC_ERROR" ] || { echo "missing companion: $status $output"; return 1; }
}

# 1.5.1: `release adopt` renders without the caller's PATH, so it finds no
# claude and writes the adapter (R2) form; doctor runs with the caller's PATH,
# finds a supporting claude and expected the direct (R1) form: a false ERROR on
# every correctly adopted checkout. R2 is a valid render of the same release.
@test "native guard health accepts the R2 render when doctor sees an onFailure-capable claude" {
  native_health_fixture
  local f="$ROOT/.claude/settings.local.json" source context original="$SANDBOX/r2.json"
  source="$NATIVE_RELEASE/payload/core-rules/templates/claude-settings.local.json"
  context="$(attachment_contextual_render_context "$TRELLIS_HOME")"
  rm -f "$SANDBOX/claude-bin/claude"
  attachment_contextual_template_render "$source" core-rules/templates/claude-settings.local.json "$context" "$ROOT" > "$f"
  jq -e 'all(.hooks.PreToolUse[].hooks[]; has("args") | not)' "$f" >/dev/null || { cat "$f"; false; }
  native_health_owner claude
  stub_claude 2.1.300
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_OK" ] || { echo "R2 under a capable client: $status $output"; false; }
  # Still exact: a mutated R2 member is an ERROR under either expectation.
  cp "$f" "$original"
  jq '.hooks.PreToolUse[0].hooks[0].command |= . + " tampered"' "$original" > "$f"
  run hc_guard_registrations "$ROOT"
  [ "$status" -eq "$HC_ERROR" ] || { echo "tampered R2: $status $output"; false; }
  [[ "$output" == *"native member coverage or wiring differs"* ]] || { echo "$output"; false; }
}
