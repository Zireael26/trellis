#!/usr/bin/env bats
# Legacy doctor must not certify an uninspected fleet as healthy.
load doctor-fix-common
umask 077

# The legacy helper uses bare mktemp -d, which ignores TMPDIR on macOS.
mktemp() {
  if [ "$#" -eq 1 ] && [ "$1" = -d ]; then
    command mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/doctor-legacy.XXXXXX"
  else
    command mktemp "$@"
  fi
}

@test "legacy doctor does not report healthy when its registry is missing" {
  build_canonical_tree
  mv "$CANON/registry.md" "$SANDBOX/registry-aside"
  git_init_canonical_main
  write_config
  run_doctor
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"registry"*"$CANON/registry.md"* ]] || { echo "$output"; false; }
  [[ "$output" != *"healthy — no drift detected (0 project(s) checked)"* ]] || { echo "$output"; false; }
  run_doctor --fix --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"$CANON/registry.md"*"no projects checked"*"a real run would exit 1"* ]] || { echo "$output"; false; }
}

@test "legacy doctor reports a malformed active table and an unreadable registry as errors" {
  [ "$(id -u)" -ne 0 ] || skip 'root can read mode-000 files'
  build_canonical_tree
  printf '# registry\n\n## Renamed projects\n\n| Project | Path |\n|---|---|\n' > "$CANON/registry.md"
  git_init_canonical_main
  write_config
  run_doctor
  [ "$status" -eq 1 ] && [[ "$output" == *"$CANON/registry.md"* ]] || { echo "$output"; false; }
  chmod 000 "$CANON/registry.md"
  run_doctor
  [ "$status" -eq 1 ] && [[ "$output" == *"$CANON/registry.md"* ]] || { echo "$output"; false; }
}

@test "legacy doctor distinguishes a valid empty active table from a healthy checked fleet" {
  build_canonical_tree
  printf '# registry\n\n## Active projects\n\n| Project | Path | Class | Notes |\n|---|---|---|---|\n\n---\n' > "$CANON/registry.md"
  git_init_canonical_main
  write_config
  run_doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"no projects checked"*"active registry is empty"* ]] || { echo "$output"; false; }
  [[ "$output" != *"healthy — no drift detected"* ]] || { echo "$output"; false; }
}

@test "legacy doctor names the count of all-held rows without claiming healthy" {
  build_canonical_tree
  printf '## 1. Temporarily excluded (registered projects)\n\n| Project | Reason |\n|---|---|\n| healthy | fixture |\n\n## 2. Permanently excluded from management\n\n## Semantics\n' > "$CANON/blacklist.md"
  git_init_canonical_main
  write_config
  run_doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"no projects checked"*"1 active row(s) held"* ]] || { echo "$output"; false; }
  [[ "$output" != *"healthy — no drift detected"* ]] || { echo "$output"; false; }
}

@test "legacy doctor still checks a valid active project" {
  build_canonical_tree
  git_init_canonical_main
  build_healthy_project
  write_config
  run_doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"healthy ("* ]] || { echo "$output"; false; }
  [[ "$output" != *"no projects checked"* ]] || { echo "$output"; false; }
}
