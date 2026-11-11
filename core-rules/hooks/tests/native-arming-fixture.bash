#!/usr/bin/env bash
# Real T56 candidate render for both deployed fallback suites. The digest-
# matched companion is inspected, never executed by these shell tests.

native_prompt_candidate() {
  local harness="$1" form="${2:-direct}" repo source template digest target version companion context output asset size manifest
  repo="$(cd "$HOOKS_DIR/../.." && pwd -P)"
  case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=aarch64-apple-darwin ;;
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    Linux:aarch64) target=aarch64-unknown-linux-musl ;;
    *) skip 'unsupported native candidate fixture host' ;;
  esac
  export HOME="$BATS_TEST_TMPDIR/native user 'quoted"
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME" "$BATS_TEST_TMPDIR/native-payload/core-rules/templates"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  cp -R "$repo/core-rules/native" "$BATS_TEST_TMPDIR/native-payload/core-rules/native"
  manifest="$BATS_TEST_TMPDIR/native-payload/core-rules/native/artifacts.json"
  asset="$BATS_TEST_TMPDIR/native-payload/core-rules/native/$target/trellis-hooks"
  if [ ! -f "$asset" ]; then
    # Inert bytes supply a digest-matched fixture, not native qualification.
    mkdir -p "${asset%/*}"; printf 'inert candidate fixture\n' > "$asset"
    digest="$(shasum -a 256 "$asset")"; digest="${digest%% *}"
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
  cp "$BATS_TEST_TMPDIR/native-payload/core-rules/native/$target/trellis-hooks" "$companion"
  chmod 500 "$companion"
  cp "$repo/scripts/trellis-launcher.sh" "$HOME/.local/bin/trellis"
  template=claude-settings.local.json; output="$PROJECT_DIR/.claude/settings.local.json"
  if [ "$harness" = codex ]; then
    template=codex-hooks.local.json; output="$PROJECT_DIR/.codex/hooks.json"
    mkdir -p "$PROJECT_DIR/.codex"
    printf '/.codex/hooks.json\n' >> "$PROJECT_DIR/.git/info/exclude"
  fi
  source="$BATS_TEST_TMPDIR/native-payload/core-rules/templates/$template"
  jq -n --arg h "$harness" '{hooks:(["PreToolUse","UserPromptSubmit","Stop"] | map(. as $event | {key:$event,value:[{hooks:[({type:"command",command:"__TRELLIS_LAUNCHER__",args:["hook","event",$h,$event],timeout:30} + (if $h == "claude" then {onFailure:"block"} else {} end))]}]}) | from_entries)}' > "$source"
  context="$(bash -c 'source "$1"; attachment_contextual_render_context "$2"' _ "$repo/scripts/lib/attachment.sh" "$TRELLIS_HOME")" || return 1
  bash -c 'source "$1"; form="$6"; attachment_claude_on_failure_supported() { [ "$form" = direct ]; }; attachment_contextual_template_render "$2" "$3" "$4" "$5"' \
    _ "$repo/scripts/lib/attachment.sh" "$source" "core-rules/templates/$template" "$context" "$PROJECT_DIR" "$form" > "$output" 2> "$BATS_TEST_TMPDIR/native-render.err" || {
      printf 'candidate render failed for %s: %s\n' "$PROJECT_DIR" "$(<"$BATS_TEST_TMPDIR/native-render.err")" >&2
      return 1
    }
  mkdir -p "$PROJECT_DIR/.trellis"
  ln -s "$BATS_TEST_TMPDIR/native-payload" "$PROJECT_DIR/.trellis/runtime"
  printf '/.trellis/\n' >> "$PROJECT_DIR/.git/info/exclude"
  native_prompt_owner_record "$harness"
}

# The owner binds the physical worktree and the actual rendered prompt value.
native_prompt_owner_record() {
  local harness="$1" common checkout worktree owner file render version
  common="$(CDPATH='' cd "$PROJECT_DIR/.git" && pwd -P)"
  checkout="$(printf '%s' "$common" | shasum -a 256)"; checkout="${checkout%% *}"
  worktree="$(printf '%s' "$PROJECT_DIR" | shasum -a 256)"; worktree="${worktree%% *}"
  owner="$TRELLIS_HOME/state/attachments/$checkout/$worktree.json"
  mkdir -p "${owner%/*}"; chmod 700 "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/attachments" "${owner%/*}"
  file="$PROJECT_DIR/.claude/settings.local.json"; render=.claude/settings.local.json
  if [ "$harness" = codex ]; then file="$PROJECT_DIR/.codex/hooks.json"; render=.codex/hooks.json; fi
  version="$(jq -r '.version' "$BATS_TEST_TMPDIR/native-payload/core-rules/native/artifacts.json")"
  jq -n --arg root "$PROJECT_DIR" --arg checkout "$checkout" --arg worktree "$worktree" --arg render "$render" --arg target "$BATS_TEST_TMPDIR/native-payload" --arg version "$version" --slurpfile rendered "$file" \
    '{status:"committed",project_root:$root,worktree_root:$root,checkout_id:$checkout,worktree_id:$worktree,release:$version,attachment_id:"00000000-0000-4000-8000-000000000001",artifacts:[{kind:"symlink",path:".trellis/runtime",target:$target}],renders:[{path:$render,owned_keys:[{path:["hooks","UserPromptSubmit"],value:$rendered[0].hooks.UserPromptSubmit}]}]}' > "$owner"
  chmod 600 "$owner"
  native_prompt_ok_verdict
}

# T14 amended (owner 2026-11-10): an attached fixture whose checks job recorded
# ok for exactly its current owner record. Call again after any owner edit.
native_prompt_ok_verdict() {
  local owner status sha
  owner="$(find "$TRELLIS_HOME/state/attachments" -name '*.json' -type f)"
  status="$TRELLIS_HOME/state/attachment-status/${owner#"$TRELLIS_HOME/state/attachments/"}"
  mkdir -p "${status%/*}"; chmod 700 "$TRELLIS_HOME/state/attachment-status" "${status%/*}"
  sha="$(shasum -a 256 "$owner")"; sha="${sha%% *}"
  jq --arg sha "$sha" '{schema_version:2,state:"ok",checkout_id,worktree_id,attachment_id,owner_sha256:$sha,
    release,worktree_root,updated_at:0,checks:[],failure:null}' "$owner" > "$status"
  chmod 600 "$status"
}
