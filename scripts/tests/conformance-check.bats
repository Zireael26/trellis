#!/usr/bin/env bats

REPO_ROOT="$(CDPATH='' cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  ROOT="$BATS_TEST_TMPDIR/conformance"
  mkdir -p "$ROOT/scripts" "$ROOT/docs" "$ROOT/core-rules/skills/process-gate/references"
  cp "$REPO_ROOT/scripts/conformance-check.sh" "$ROOT/scripts/"
  printf '#!/bin/sh\nexit 0\n' > "$ROOT/scripts/existing.sh"
}

check_conformance() {
  run bash "$ROOT/scripts/conformance-check.sh" --quiet
}

@test "absolute checkout references cannot hide missing repo paths" {
  local operator_root="/User""s/operator/projects/trellis"
  printf 'Broken `%s/scripts/gone.sh`\n' "$operator_root" > "$ROOT/engineering-process.md"
  check_conformance
  [ "$status" -ne 0 ] || { echo "absolute path was ignored: $output"; false; }
  [[ "$output" == *"MISS: engineering-process.md:1"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$operator_root/scripts/gone.sh"* ]] || false

  printf 'Use `scripts/existing.sh` and example `/Users/you/project/scripts/example.sh`\n' > "$ROOT/engineering-process.md"
  check_conformance
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "path references with command arguments and parentheticals are checked" {
  printf 'Run `scripts/gone.sh --check` and read `docs/gone.md (section 2)`.\n' > "$ROOT/engineering-process.md"
  check_conformance
  [ "$status" -ne 0 ] || { echo "path-bearing commands were ignored: $output"; false; }
  [[ "$output" == *'`scripts/gone.sh`'* && "$output" == *'`docs/gone.md`'* ]] || { echo "$output"; false; }

  printf 'document\n' > "$ROOT/docs/my guide.md"
  printf 'Run `scripts/existing.sh --check` and read `docs/my guide.md`.\n' > "$ROOT/engineering-process.md"
  check_conformance
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "NUL-bearing documents cannot be certified as clean" {
  printf 'ok\000 `scripts/missing.sh`\n' > "$ROOT/engineering-process.md"
  check_conformance
  [ "$status" -ne 0 ] || { echo "binary document was ignored: $output"; false; }
  [[ "$output" == *'engineering-process.md'* && "$output" == *'non-text'* ]] || { echo "$output"; false; }

  printf 'Use `scripts/existing.sh`.\n' > "$ROOT/engineering-process.md"
  check_conformance
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "unreadable documents cannot be certified as clean" {
  printf 'Use `scripts/existing.sh`.\n' > "$ROOT/engineering-process.md"
  chmod 000 "$ROOT/engineering-process.md"
  if head -c 1 "$ROOT/engineering-process.md" >/dev/null 2>&1; then
    chmod 600 "$ROOT/engineering-process.md"
    skip 'current account can read mode-000 files'
  fi
  check_conformance
  chmod 600 "$ROOT/engineering-process.md"
  [ "$status" -ne 0 ] || { echo "unreadable document was ignored: $output"; false; }
  [[ "$output" == *'engineering-process.md'* && "$output" == *'could not read'* ]] || { echo "$output"; false; }
}
