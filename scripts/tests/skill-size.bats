#!/usr/bin/env bats

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
LIB="$REPO_ROOT/scripts/lib/skill-size.sh"
CHECK="$REPO_ROOT/scripts/check-skill-sizes.sh"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TMPDIR/skill-size.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  PROJECT="$SANDBOX/project with spaces"
  USER_HOME="$SANDBOX/user home"
  mkdir -p "$PROJECT" "$USER_HOME"
  # shellcheck disable=SC1090
  . "$LIB"
}

teardown() {
  rm -rf "$SANDBOX"
}

make_skill() {
  local root="$1" bytes="${2:-1}"
  mkdir -p "$root"
  python3 - "$root/SKILL.md" "$bytes" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_bytes(b"a" * int(sys.argv[2]))
PY
}

make_named_skill() {
  local root="$1" name="$2"
  mkdir -p "$root"
  printf '%s\n' '---' "name: $name" '---' > "$root/SKILL.md"
}

@test "manifest check accepts under and exact budget, rejects one byte over" {
  make_skill "$SANDBOX/under" 65535
  make_skill "$SANDBOX/exact" 65536
  make_skill "$SANDBOX/over" 65537

  run skill_size_check_root "$SANDBOX/under"
  [ "$status" -eq 0 ]
  run skill_size_check_root "$SANDBOX/exact"
  [ "$status" -eq 0 ]
  run skill_size_check_root "$SANDBOX/over"
  [ "$status" -eq 1 ]
  [[ "$output" == *"65537 bytes; budget is 65536 bytes"* ]]
}

@test "manifest size counts UTF-8 bytes rather than characters" {
  mkdir -p "$SANDBOX/multibyte"
  python3 - "$SANDBOX/multibyte/SKILL.md" <<'PY'
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text("é" * 32768, encoding="utf-8")
PY
  run skill_size_manifest_bytes "$SANDBOX/multibyte"
  [ "$status" -eq 0 ]
  [ "$output" = "65536" ]
}

@test "resolver discovers project, user, cache plugin, and marketplace plugin roots" {
  make_skill "$PROJECT/.claude/skills/project-skill"
  make_skill "$USER_HOME/.claude/skills/user-skill"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.2.3/skills/cache-skill"
  make_skill "$USER_HOME/.claude/plugins/marketplaces/vendor/plugins/market/skills/market-skill"

  run skill_size_resolve_root project-skill "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/.claude/skills/project-skill" ]
  run skill_size_resolve_root user-skill "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/skills/user-skill" ]
  run skill_size_resolve_root cache-skill "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.2.3/skills/cache-skill" ]
  run skill_size_resolve_root market-skill "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/plugins/marketplaces/vendor/plugins/market/skills/market-skill" ]
}

@test "resolver preserves spaces in roots and Skill names" {
  make_skill "$PROJECT/.claude/skills/skill with spaces"
  run skill_size_resolve_root "skill with spaces" "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/.claude/skills/skill with spaces" ]
}

@test "resolver applies project then user precedence" {
  make_skill "$PROJECT/.claude/skills/duplicate"
  make_skill "$USER_HOME/.claude/skills/duplicate"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/duplicate"
  make_skill "$USER_HOME/.claude/skills/user-wins"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/user-wins"
  run skill_size_resolve_root duplicate "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/.claude/skills/duplicate" ]

  run skill_size_resolve_root user-wins "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/skills/user-wins" ]
}

@test "resolver fails closed for distinct duplicate Skill names at one precedence" {
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/one/1.0.0/skills/duplicate"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/two/1.0.0/skills/duplicate"
  run skill_size_resolve_root duplicate "$PROJECT" "$USER_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous Skill 'duplicate' (2 roots)"* ]]
}

@test "resolver deduplicates symlink aliases to the same physical Skill root" {
  make_skill "$USER_HOME/.claude/skills/shared"
  mkdir -p "$PROJECT/.claude/skills"
  ln -s "$USER_HOME/.claude/skills/shared" "$PROJECT/.claude/skills/shared"

  run skill_size_resolve_root shared "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/skills/shared" ]
}

@test "resolver matches declared frontmatter name and directory basename" {
  make_named_skill "$PROJECT/.claude/skills/directory-name" "declared-name"

  run skill_size_resolve_root declared-name "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/.claude/skills/directory-name" ]

  run skill_size_resolve_root directory-name "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJECT/.claude/skills/directory-name" ]

  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/one/1.0.0/skills/first-root" "declared-conflict"
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/two/1.0.0/skills/second-root" "declared-conflict"
  run skill_size_resolve_root declared-conflict "$PROJECT" "$USER_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous Skill 'declared-conflict' (2 roots)"* ]]
}

@test "plugin-qualified resolution tries exact identity before final-colon suffix" {
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/one/1.0.0/skills/first" "active-plugin:shared"
  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/two/1.0.0/skills/shared" "other-name"

  run skill_size_resolve_root "active-plugin:shared" "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/plugins/cache/vendor/one/1.0.0/skills/first" ]

  make_named_skill "$USER_HOME/.claude/plugins/cache/vendor/three/1.0.0/skills/active-name" "plain-name"
  run skill_size_resolve_root "active-plugin:active-name" "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/plugins/cache/vendor/three/1.0.0/skills/active-name" ]
}

@test "cache wins over marketplace source while same-tier conflicts deny" {
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/shared"
  make_skill "$USER_HOME/.claude/plugins/marketplaces/vendor/plugins/plugin/skills/shared"

  run skill_size_resolve_root shared "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [ "$output" = "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/shared" ]

  make_skill "$USER_HOME/.claude/plugins/cache/other/plugin/1.0.0/skills/shared"
  run skill_size_resolve_root shared "$PROJECT" "$USER_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ambiguous Skill 'shared' (2 roots)"* ]]
}

@test "discovery excludes Cursor Windsurf and foreign nested skill trees" {
  make_skill "$USER_HOME/.cursor/skills/cursor-skill"
  make_skill "$USER_HOME/.windsurf/skills/windsurf-skill"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/foreign/.cursor/skills/nested-cursor"
  make_skill "$USER_HOME/.claude/plugins/marketplaces/vendor/foreign/skills/nested-foreign"
  make_skill "$USER_HOME/.claude/plugins/cache/vendor/plugin/1.0.0/skills/claude-skill"

  run skill_size_discover_roots "$PROJECT" "$USER_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/claude-skill"* ]]
  [[ "$output" != *"cursor-skill"* ]]
  [[ "$output" != *"windsurf-skill"* ]]
  [[ "$output" != *"nested-foreign"* ]]
}

@test "canonicalization rejects control-character roots without newline aliasing" {
  local plain="$SANDBOX/collision" newline_root="$SANDBOX/collision"$'\n'
  local tab_root="$SANDBOX/tab"$'\t'"root"
  make_skill "$plain"
  make_skill "$newline_root"
  make_skill "$tab_root"

  run skill_size__canonical_dir "$newline_root"
  [ "$status" -eq 1 ]
  run skill_size_check_root "$newline_root"
  [ "$status" -eq 2 ]
  run skill_size__canonical_dir "$tab_root"
  [ "$status" -eq 1 ]
  run skill_size__canonical_dir "$plain"
  [ "$status" -eq 0 ]
  [ "$output" = "$plain" ]

  local control_project="$SANDBOX/control-project"$'\n'
  make_skill "$control_project/.claude/skills/anything"
  run skill_size_resolve_root anything "$control_project" "$USER_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid project directory"* ]]
}

@test "canonicalization and checker handle leading-dash roots literally" {
  local parent="$SANDBOX/dash-parent"
  mkdir -p "$parent"
  make_skill "$parent/-P/skill"

  run bash -c 'cd -- "$1" && . "$2" && skill_size__canonical_dir "-P"' _ "$parent" "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "$parent/-P" ]

  run bash -c 'cd -- "$1" && "$2" "-P"' _ "$parent" "$CHECK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK (1 Skill roots checked"* ]]
}

@test "library rejects missing roots, malformed names, invalid UTF-8, and invalid budgets" {
  run skill_size_check_root "$SANDBOX/missing"
  [ "$status" -eq 2 ]
  run skill_size_resolve_root "bad/name" "$PROJECT" "$USER_HOME"
  [ "$status" -eq 2 ]
  make_skill "$SANDBOX/invalid-utf8"
  printf '\377' > "$SANDBOX/invalid-utf8/SKILL.md"
  run skill_size_check_root "$SANDBOX/invalid-utf8"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not valid UTF-8"* ]]
  run skill_size_check_root "$SANDBOX/invalid-utf8" nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"budget must be a positive integer"* ]]
}

@test "canonical checker passes bounded collections and hard-fails oversized Skills" {
  local collection="$SANDBOX/canonical skills"
  make_skill "$collection/ok" 65536
  run "$CHECK" "$collection"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK (1 Skill roots checked; budget 65536 bytes)"* ]]

  make_skill "$collection/too-large" 65537
  run "$CHECK" "$collection"
  [ "$status" -eq 1 ]
  [[ "$output" == *"too-large/SKILL.md is 65537 bytes"* ]]
  [[ "$output" == *"FAILED (2 Skill roots checked)"* ]]
}

@test "canonical checker rejects a non-directory input" {
  printf 'not a directory\n' > "$SANDBOX/file"
  run "$CHECK" "$SANDBOX/file"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a directory"* ]]
}
