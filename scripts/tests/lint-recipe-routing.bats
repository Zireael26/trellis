#!/usr/bin/env bats

REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LINT="$REPO/scripts/lint-recipe-routing.sh"
RECIPES="$REPO/core-rules/skills/orchestrate/recipes"

setup() {
  FIXTURES="$BATS_TEST_TMPDIR/lint-recipe-routing-$BATS_TEST_NUMBER"
  mkdir -p "$FIXTURES"
}

@test "typed agent site passes" {
  cat > "$FIXTURES/typed.wf.js" <<'JS'
const receipt = await settle('work', () => agent(
  prompt(),
  { agentType: 'code-reviewer', label: 'work' },
))
JS

  run bash "$LINT" "$FIXTURES/typed.wf.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 agent() call sites: 1 typed, 0 marked"* ]]
}

@test "marked inherited agent site passes" {
  cat > "$FIXTURES/marked.wf.js" <<'JS'
const receipts = await parallel(items.map((item) => async () => {
  // routing: inherit — deliberate judgment leg keeps the main-loop prompt and tools
  return agent(prompt(item), { label: 'judge:' + item.id })
}))
JS

  run bash "$LINT" "$FIXTURES/marked.wf.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 agent() call sites: 0 typed, 1 marked"* ]]
}

@test "unclassified agent site fails with file and line" {
  cat > "$FIXTURES/unclassified.wf.js" <<'JS'
phase('Work')
const receipt = await settle('work', () =>
  agent(prompt(), { label: 'work' }))
JS

  run bash "$LINT" "$FIXTURES/unclassified.wf.js"
  [ "$status" -ne 0 ]
  [[ "$output" == *"$FIXTURES/unclassified.wf.js:3"* ]]
  [[ "$output" == *"1 unclassified site(s)"* ]]
}

@test "commented-out example does not trigger" {
  cat > "$FIXTURES/commented.wf.js" <<'JS'
// Fan-out example only:
// const receipts = await parallel(items.map((item) => () => agent(prompt(item), {
//   label: 'work:' + item.id,
// })))
JS

  run bash "$LINT" "$FIXTURES/commented.wf.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 agent() call sites: 0 typed, 0 marked"* ]]
}

@test "regexes and string examples do not hide an opts-line marker" {
  cat > "$FIXTURES/lexical.wf.js" <<'JS'
const examples = ["agent(fakePrompt())", /don't/, /a\/\/b/]
const receipt = await settle('work', () => agent(
  prompt(examples),
  { label: 'work' }, // routing: inherit — deliberate main-loop judgment leg
))
JS

  run bash "$LINT" "$FIXTURES/lexical.wf.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 agent() call sites: 0 typed, 1 marked"* ]]
}

@test "canonical recipes keep the complete routing inventory explicit" {
  run bash "$LINT" --list "$RECIPES"
  [ "$status" -eq 0 ]

  # Assert the INVARIANT (every site is classified), not a snapshot of the current
  # allocation. Counts move whenever routing is retuned; completeness must not.
  local typed marked total
  typed="$(printf '%s\n' "$output" | grep -c ':agentType$' || true)"
  marked="$(printf '%s\n' "$output" | grep -c ':inherit$' || true)"
  total="$(printf '%s\n' "$output" | grep -cE ':(agentType|inherit)$' || true)"

  [ "$total" -gt 0 ]
  [ "$(( typed + marked ))" -eq "$total" ]
  [[ "$output" == *"$total agent() call sites: $typed typed, $marked marked"* ]]
}
