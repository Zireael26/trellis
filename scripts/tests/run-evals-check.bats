#!/usr/bin/env bats

SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  HARNESS_ROOT="$(mktemp -d)"
  mkdir -p "$HARNESS_ROOT/scripts" "$HARNESS_ROOT/core-rules/evals"
  cp "$SOURCE_ROOT/scripts/run-evals.sh" "$HARNESS_ROOT/scripts/run-evals.sh"
  chmod +x "$HARNESS_ROOT/scripts/run-evals.sh"
  write_blacklist
}

teardown() {
  rm -rf "$HARNESS_ROOT"
}

write_registry() {
  {
    printf '%s\n' '# Project registry' '' '## Active projects' ''
    printf '%s\n' '| Project | Path | Class | Notes |' '|---|---|---|---|'
    for project in "$@"; do
      printf '| %s | `/personal/%s` | app | test |\n' "$project" "$project"
    done
    printf '%s\n' '' '---'
  } > "$HARNESS_ROOT/registry.md"
}

write_blacklist() {
  {
    printf '%s\n' '# Blacklist' '' '## 1. Temporarily excluded (registered projects)' ''
    printf '%s\n' '| Project | Reason | Added | Review after |' '|---|---|---|---|'
    for project in "$@"; do
      printf '| %s | test | 2026-07-14 | 2026-07-15 |\n' "$project"
    done
    printf '%s\n' '' '## 2. Permanently excluded from management' ''
    printf '%s\n' '| Path | Reason |' '|---|---|'
  } > "$HARNESS_ROOT/blacklist.md"
}

write_fixture() {
  project="$1"
  fixture="$HARNESS_ROOT/core-rules/evals/$project/smoke"
  mkdir -p "$fixture"
  cat > "$fixture/manifest.yml" <<EOF
version: 1
id: smoke
project: $project
prompt: Create SMOKE.md.
EOF
  printf '%s\n' '{"assertions": []}' > "$fixture/expected.json"
}

run_mode() {
  local mode="$1"
  run bash "$HARNESS_ROOT/scripts/run-evals.sh" "--$mode"
}

@test "check and dry-run allow the public mirror when all private inputs are absent" {
  rm -f "$HARNESS_ROOT/registry.md" "$HARNESS_ROOT/blacklist.md"
  rm -rf "$HARNESS_ROOT/core-rules/evals"

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 0 ]
    [[ "$output" == *"no fixtures matched"* ]]
  done
}

@test "check and dry-run fail closed when private inputs are partial" {
  write_registry alpha
  rm -f "$HARNESS_ROOT/blacklist.md"
  rm -rf "$HARNESS_ROOT/core-rules/evals"

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 4 ]
    [[ "$output" == *"blacklist"* ]]
  done
}

@test "check and dry-run fail when an active registry project has no eval fixture manifest" {
  write_registry beta
  mkdir -p "$HARNESS_ROOT/core-rules/evals/beta"

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 4 ]
    [[ "$output" == *"beta"* ]]
    [[ "$output" == *"missing eval fixture"* ]]
  done
}

@test "check and dry-run validate a complete private fixture set" {
  write_registry alpha beta
  write_blacklist beta
  write_fixture alpha

  for mode in check dry-run; do
    run_mode "$mode"

    [ "$status" -eq 0 ]
    [[ "$output" == *"1 fixture(s) valid"* ]]
    if [ "$mode" = "dry-run" ]; then
      [[ "$output" == *"would run:"* ]]
    fi
  done
}
