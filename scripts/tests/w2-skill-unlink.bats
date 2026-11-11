#!/usr/bin/env bats
# Unlink must not silently leave a store skill exposed or discard drifted records.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SKILLS="$REPO_ROOT/scripts/skills.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-unlink.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
  STORE="$TRELLIS_HOME/skills/foo" RECORD="$TRELLIS_HOME/state/user-skills.json"
  mkdir -p "$STORE" "$HOME/.agents/skills"
  printf '%s\n' '---' 'name: foo' 'description: fixture' '---' > "$STORE/SKILL.md"
}

@test "unrecorded link to store refuses rather than reporting unlinked" {
  link="$HOME/.agents/skills/foo"
  ln -s "$STORE" "$link"
  run "$SKILLS" unlink foo
  [ "$status" -eq 3 ] || { echo "unrecorded link ignored: $output"; false; }
  [ -L "$link" ]
  [ ! -e "$RECORD" ]
}

@test "retargeted recorded link refuses without dropping ownership" {
  run "$SKILLS" link foo
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  cp "$RECORD" "$SANDBOX/record-before"
  link="$HOME/.agents/skills/foo"
  rm -f "${link:?}"
  ln -s "$TRELLIS_HOME/skills/../skills/foo" "$link"
  run "$SKILLS" unlink foo
  [ "$status" -eq 3 ] || { echo "retargeted active link ignored: $output"; false; }
  [ -L "$link" ]
  [ -L "$HOME/.claude/skills/foo" ]
  cmp "$SANDBOX/record-before" "$RECORD"
}

@test "intact owned links can still be removed and an absent link is idempotent" {
  run "$SKILLS" unlink foo
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$SKILLS" link foo
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  run "$SKILLS" unlink foo
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$HOME/.agents/skills/foo" ]
  [ ! -e "$HOME/.claude/skills/foo" ]
  [ -f "$STORE/SKILL.md" ]
}
