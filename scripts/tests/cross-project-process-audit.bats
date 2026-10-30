#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/cross-project-process-audit"
  mkdir -p "$SANDBOX"
  cp "$REPO/scheduled-tasks/cross-project-process-audit/prompt.md" "$SANDBOX/prompt.md"
  PROMPT="$SANDBOX/prompt.md"
}

section() {
  local start="$1" end="$2"
  awk -v start="$start" -v end="$end" '
    $0 == start { in_section = 1 }
    $0 == end { in_section = 0 }
    in_section {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      printf "%s ", line
    }
  ' "$PROMPT"
}

@test "root instructions accept either file and map checks use available documents" {
  local required map
  required="$(section '### 3. Bypass history and required files' '### 4. Parent-rule inheritance wiring')"
  map="$(section '### 6. Codebase map' '### 7. Pipeline and steering drift')"

  [[ "$required" == *'`AGENTS.md` or `CLAUDE.md`'* ]]
  [[ "$required" == *'`gotchas.md`'* && "$required" == *'`context-log.md`'* ]]
  [[ "$required" != *'Require `CLAUDE.md`'* ]]

  [[ "$map" == *'AGENTS.md'* && "$map" == *'CLAUDE.md'* ]]
  [[ "$map" == *'either'* || "$map" == *'one valid'* ]]
  [[ "$map" == *'both'* && "$map" == *'duplicate'* ]]
  [[ "$map" != *'skip this check if `CLAUDE.md` is already missing'* ]]
}

@test "managed dispatcher handling avoids project hook demands but keeps unmanaged fallbacks" {
  local native merge_gate
  native="$(section '### 2. Native hook handling' '### 3. Bypass history and required files')"
  merge_gate="$(section '### 8. Merge-gate and loop-safety declaration' '## Output')"

  [[ "$native" == *'release doctor verifies `core.hooksPath`'* ]]
  [[ "$native" == *'managed Trellis dispatcher'* ]]
  [[ "$native" == *'canonical effective managed pre-push wiring'* ]]
  [[ "$native" == *'never execute'* ]]
  [[ "$native" == *'Do not require `.husky/pre-commit`'* ]]
  [[ "$native" == *'`.husky/commit-msg`'* && "$native" == *'`.husky/pre-push`'* ]]
  [[ "$native" == *'tracked dispatcher files inside the project'* ]]
  [[ "$native" == *'unmanaged Node projects'* && "$native" == *'unmanaged native/legacy projects'* ]]
  [[ "$native" == *'normal pre-commit, commit-message, and pre-push stack'* ]]
  [[ "$native" == *'Missing, broken, or untracked expected native hooks are **critical**'* ]]
  [[ "$native" == *'Missing or broken hooks remain findings'* ]]
  [[ "$native" != *'tracked hook directory must contain'* ]]
  [[ "$native" != *'Missing or untracked native hooks are **critical**'* ]]

  [[ "$merge_gate" == *'managed Trellis dispatcher'* ]]
  [[ "$merge_gate" == *'never execute'* ]]
  [[ "$merge_gate" == *'unmanaged'* ]]
  [[ "$merge_gate" != *'Inspect, never execute, the local pre-push hook. It must reference'* ]]
}
