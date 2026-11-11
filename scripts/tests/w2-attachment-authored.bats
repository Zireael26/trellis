#!/usr/bin/env bats
# Unreadable files must not be mistaken for authored attachment deferrals.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-authored.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  PROJECT="$SANDBOX/project" PAYLOAD="$SANDBOX/payload"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME" "$PROJECT" "$PAYLOAD"
  source "$REPO_ROOT/scripts/attach-project.sh"
  printf 'canonical\n' > "$PAYLOAD/canonical.md"
  cp "$PAYLOAD/canonical.md" "$PROJECT/AGENTS.md"
  SURFACES='{"artifacts":[{"kind":"symlink","destination":"AGENTS.md","source_scope":"project","source":"CLAUDE.md","fallback_source":"canonical.md","target":"CLAUDE.md","fallback_target":".trellis/runtime/canonical.md"}]}'
}

@test "unreadable identical leaf is not deferred as project authored" {
  chmod 000 "$PROJECT/AGENTS.md"
  run attach_deferred_leaves "$PROJECT" "$PAYLOAD" "$SURFACES"
  rc="$status"
  chmod 600 "$PROJECT/AGENTS.md"
  [ "$rc" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = '[]' ] || { echo "unreadable file deferred: $output"; false; }
  run attach_deferred_leaves "$PROJECT" "$PAYLOAD" "$SURFACES"
  [ "$status" -eq 0 ] && [ "$output" = '[]' ]
}

@test "readable distinct authored file remains deferred" {
  printf 'project authored\n' > "$PROJECT/AGENTS.md"
  run attach_deferred_leaves "$PROJECT" "$PAYLOAD" "$SURFACES"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '%s\n' "$output" | jq -e 'length == 1 and .[0].path == "AGENTS.md" and .[0].reason == "project-authored-file"' >/dev/null
}
