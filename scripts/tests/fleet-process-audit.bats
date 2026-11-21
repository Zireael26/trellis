#!/usr/bin/env bats
# The merged fleet audit keeps only the four doctrines `trellis doctor` cannot
# compute. Each assertion pins a sentence that was written in response to a real
# triage failure, so a later prompt rewrite cannot silently drop it.

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$BATS_TEST_TMPDIR/fleet-process-audit"
  mkdir -p "$SANDBOX"
  cp "$REPO/scheduled-tasks/fleet-process-audit/prompt.md" "$SANDBOX/prompt.md"
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

@test "codebase map accepts either root document and does not demand duplicates" {
  local map
  map="$(section '### 1. Codebase map' '### 2. Pipeline drift')"

  [[ "$map" == *'AGENTS.md'* && "$map" == *'CLAUDE.md'* ]] || false
  [[ "$map" == *'either'* ]] || false
  [[ "$map" == *'both'* && "$map" == *'duplicate'* ]] || false
  [[ "$map" != *'skip this check if `CLAUDE.md` is already missing'* ]] || false
  [[ "$map" == *'generated'* && "$map" == *'dependency'* ]] || false
}

@test "pipeline drift stays opt-in and distinguishes real drift from absence" {
  local pipeline
  pipeline="$(section '### 2. Pipeline drift' '### 3. Loop-safety declarations')"

  [[ "$pipeline" == *'opt-in'* ]] || false
  [[ "$pipeline" == *'ordinary maintenance is never a finding'* ]] || false
  [[ "$pipeline" == *'Missing vendoring is not a finding'* ]] || false
  [[ "$pipeline" == *'renamed skill'* ]] || false
}

@test "loop-safety check names every ceiling and every loop surface" {
  local loops
  loops="$(section '### 3. Loop-safety declarations' '### 4. Silent high autonomy')"

  [[ "$loops" == *'orchestrate/recipes'* ]] || false
  [[ "$loops" == *'scheduled-task prompt'* ]] || false
  for token in max_iterations no_progress_iterations budget_ceiling_usd 'progress signal'; do
    [[ "$loops" == *"$token"* ]] || { echo "missing $token"; false; }
  done
  [[ "$loops" == *'non-compliant'* ]] || false
}

@test "silent high autonomy reads the decision log and stops at L4" {
  local autonomy
  autonomy="$(section '### 4. Silent high autonomy' '## Output')"

  [[ "$autonomy" == *'decisions-log.md'* ]] || false
  [[ "$autonomy" == *'silent-high-autonomy'* ]] || false
  [[ "$autonomy" == *'at least L4'* ]] || false
  [[ "$autonomy" == *'Below L4'* && "$autonomy" == *'not a finding'* ]] || false
}

# The whole point of the merge is that the weekly LLM pass no longer restates
# doctor. If the prompt stops deferring, the duplication comes back.
@test "the audit defers to doctor instead of re-deriving its verdicts" {
  local purpose inputs
  purpose="$(section '## Purpose' '## Inputs and environment')"
  inputs="$(section '## Inputs and environment' '## Checks')"

  [[ "$purpose" == *'trellis doctor'* ]] || false
  [[ "$purpose" == *'four checks'* ]] || false
  [[ "$inputs" == *'deterministic verdicts stand'* ]] || false
  [[ "$inputs" == *'do not restate'* ]] || false
  # The retired weekly checks must not reappear as sections.
  run grep -E '^### .*(Hook-stack|Native hook|Parent-rule|Codex parity)' "$PROMPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
}

@test "the template declares a full loop-safety stanza" {
  local stanza
  stanza="$(section '## Loop safety' 'ZZZ_END')"
  for token in max_iterations no_progress_iterations budget_ceiling_usd 'Progress signal'; do
    [[ "$stanza" == *"$token"* ]] || { echo "missing $token"; false; }
  done
}
