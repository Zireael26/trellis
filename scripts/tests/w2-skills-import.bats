#!/usr/bin/env bats
# Import preflight must refuse before moving or deleting any skill.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
SKILLS="$REPO_ROOT/scripts/skills.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/w2-skills.XXXXXX")"
  export HOME="$SANDBOX/home" TRELLIS_HOME="$SANDBOX/trellis"
  mkdir -m 700 "$HOME" "$TRELLIS_HOME"
}

make_skill() {
  mkdir -p "$1"
  printf '%s\n' '---' 'name: fixture' 'description: fixture' '---' > "$1/SKILL.md"
}

@test "malformed import configuration refuses before any source or copy moves" {
  local src="$SANDBOX/inbox/broken" copy="$HOME/.claude/skills/broken"
  make_skill "$src"
  printf '%s\n' '{"harnesses":["gemini"]}' > "$src/trellis-skill.json"
  mkdir -p "${copy%/*}"
  cp -R "$src" "$copy"
  run "$SKILLS" import "$src"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [ -f "$src/SKILL.md" ] && [ -f "$src/trellis-skill.json" ]
  [ -f "$copy/SKILL.md" ] && [ ! -L "$copy" ]
  [ ! -e "$TRELLIS_HOME/skills/broken" ]
  [ ! -e "$TRELLIS_HOME/state/user-skills.json" ]
}

@test "last release skill name is refused before import" {
  local src="$SANDBOX/inbox/trellis-computer-use"
  make_skill "$src"
  printf '%s\n' '{"harnesses":["claude"]}' > "$src/trellis-skill.json"
  run "$SKILLS" import "$src"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ -f "$src/SKILL.md" ] && [ ! -e "$TRELLIS_HOME/skills/trellis-computer-use" ]
  [ ! -e "$HOME/.claude/skills/trellis-computer-use" ]
}

@test "duplicate import arguments refuse before moving either source" {
  local first="$SANDBOX/one/repeat" second="$SANDBOX/two/repeat"
  make_skill "$first"
  make_skill "$second"
  run "$SKILLS" import "$first" "$second"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ -f "$first/SKILL.md" ] && [ -f "$second/SKILL.md" ]
  [ ! -e "$TRELLIS_HOME/skills/repeat" ]
  [ ! -e "$TRELLIS_HOME/state/user-skills.json" ]
}

@test "valid distinct skills still import and link" {
  make_skill "$SANDBOX/one/alpha"
  make_skill "$SANDBOX/two/beta"
  printf '%s\n' '{"harnesses":["claude"]}' > "$SANDBOX/two/beta/trellis-skill.json"
  run "$SKILLS" import "$SANDBOX/one/alpha" "$SANDBOX/two/beta"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$TRELLIS_HOME/skills/alpha/SKILL.md" ]
  [ -f "$TRELLIS_HOME/skills/beta/SKILL.md" ]
  [ -L "$HOME/.claude/skills/alpha" ] && [ -L "$HOME/.claude/skills/beta" ]
  [ -L "$HOME/.agents/skills/alpha" ] && [ ! -e "$HOME/.agents/skills/beta" ]
}
