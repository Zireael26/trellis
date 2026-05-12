#!/usr/bin/env bats
# Tests P1.5 jq-missing fail-closed across ALL 18 hook scripts (Claude + Codex).

load helpers

HOOKS=(
  "$HOOKS_DIR/block-destructive.sh"
  "$HOOKS_DIR/code-review-subagent.sh"
  "$HOOKS_DIR/post-compact-context.sh"
  "$HOOKS_DIR/post-edit-verify.sh"
  "$HOOKS_DIR/save-context-log.sh"
  "$HOOKS_DIR/session-context.sh"
  "$HOOKS_DIR/stop-verify.sh"
  "$HOOKS_DIR/truncation-check.sh"
  "$HOOKS_DIR/ui-verify.sh"
  "$CODEX_HOOKS_DIR/block-destructive.sh"
  "$CODEX_HOOKS_DIR/code-review-subagent.sh"
  "$CODEX_HOOKS_DIR/post-compact-context.sh"
  "$CODEX_HOOKS_DIR/post-edit-verify.sh"
  "$CODEX_HOOKS_DIR/save-context-log.sh"
  "$CODEX_HOOKS_DIR/session-context.sh"
  "$CODEX_HOOKS_DIR/stop-verify.sh"
  "$CODEX_HOOKS_DIR/truncation-check.sh"
  "$CODEX_HOOKS_DIR/ui-verify.sh"
)

@test "P1.5: every hook fails closed (rc!=0 + install help) when jq missing" {
  jq_free_path="$(make_jq_free_path)"
  PATH_BACKUP="$PATH"
  failed=()
  for h in "${HOOKS[@]}"; do
    PATH="$jq_free_path" run_with_stderr "$h" '{}'
    if [ "$status" -eq 0 ] || ! [[ "$stderr" == *"install jq"* ]]; then
      failed+=("$h:rc=$status")
    fi
  done
  PATH="$PATH_BACKUP"
  rm -rf "$jq_free_path"
  [ ${#failed[@]} -eq 0 ] || { printf 'FAIL: %s\n' "${failed[@]}"; false; }
}

@test "P1.5: every hook degrades cleanly when TRELLIS_NO_JQ_DEGRADE=1" {
  jq_free_path="$(make_jq_free_path)"
  PATH_BACKUP="$PATH"
  export TRELLIS_NO_JQ_DEGRADE=1
  failed=()
  for h in "${HOOKS[@]}"; do
    PATH="$jq_free_path" run_with_stderr "$h" '{}'
    if [ "$status" -ne 0 ] || ! [[ "$stderr" == *"TRELLIS_NO_JQ_DEGRADE=1"* ]]; then
      failed+=("$h:rc=$status")
    fi
  done
  unset TRELLIS_NO_JQ_DEGRADE
  PATH="$PATH_BACKUP"
  rm -rf "$jq_free_path"
  [ ${#failed[@]} -eq 0 ] || { printf 'FAIL: %s\n' "${failed[@]}"; false; }
}
