#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

@test "daily digest and dependency consistency declare all loop-safety fields" {
  local prompt
  for prompt in \
    "$REPO/scheduled-tasks/daily-project-digest/prompt.md" \
    "$REPO/scheduled-tasks/dep-consistency/prompt.md"; do
    grep -q '`max_iterations`:' "$prompt"
    grep -q '`no_progress_iterations`:' "$prompt"
    grep -q '`budget_ceiling_usd`:' "$prompt"
    grep -q 'Progress signal:.*work-list drain' "$prompt"
    grep -q '`spent_usd / budget_ceiling_usd`' "$prompt"
    grep -q 'work completed so far' "$prompt"
  done
}

@test "audit rollup separates catalogue, scheduled, and silent denominators" {
  local prompt="$REPO/scheduled-tasks/audit-report-rollup/prompt.md"
  grep -q 'scheduled-tasks/\*/prompt.md' "$prompt"
  grep -q 'Catalogue denominator:' "$prompt"
  grep -q 'Registered-schedule denominator:' "$prompt"
  grep -q '`dep-consistency` is catalogue-only with \*\*expected runs = 0\*\*' "$prompt"
  grep -q 'Drafted Tier 2 tasks likewise have' "$prompt"
  grep -q 'execution unknown' "$prompt"
  grep -q 'Never infer a missed run or' "$prompt"
  ! grep -q 'Recognized scheduled-task names' "$prompt"
}

@test "registry audit permits temporary overlap and rejects permanent overlap" {
  local prompt="$REPO/scheduled-tasks/registry-blacklist-health/prompt.md"
  grep -q 'section 1 is a valid temporary' "$prompt"
  grep -q 'section 2 (permanent exclusion)' "$prompt"
  grep -q 'is a consistency error because permanent exclusion' "$prompt"
  grep -q 'Do not list valid temporary opt-outs' "$prompt"
}

@test "large-file task declares its canonical output path" {
  grep -q 'Write `audits/YYYY-MM-DD-large-file-watch.md`' \
    "$REPO/scheduled-tasks/large-file-watch/prompt.md"
}
