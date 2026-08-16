#!/usr/bin/env bats
# Tests for check-docs.sh package.json ADR-trigger classification.
#
# A dependency value bump is maintenance, not an architectural decision, only
# when every changed dependency admits the same semver majors and the manifest
# is otherwise semantically identical. Anything uncertain stays fail-closed
# and requires an ADR.

setup() {
  SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/scripts/check-docs.sh"
  PROJECT_DIR="$(mktemp -d)"
  (
    cd "$PROJECT_DIR" || exit 1
    git init -q -b main
    git config user.email "test@example.com"
    git config user.name "test"
    printf '# Changelog\n\n## Unreleased\n' > CHANGELOG.md
    printf '# Gotchas\n' > gotchas.md
    write_baseline_package > package.json
    git add CHANGELOG.md gotchas.md package.json
    git commit -q -m "chore: seed fixture"
  )
  export CLAUDE_PROJECT_DIR="$PROJECT_DIR"
  unset CODEX_PROJECT_DIR
}

teardown() {
  if [ -n "${PROJECT_DIR:-}" ] && [ -d "$PROJECT_DIR" ]; then
    rm -rf "$PROJECT_DIR"
  fi
}

write_baseline_package() {
  printf '%s\n' \
    '{' \
    '  "name": "fixture",' \
    '  "private": true,' \
    '  "scripts": {"test": "true"},' \
    '  "engines": {"node": ">=20"},' \
    '  "dependencies": {' \
    '    "runtime": "^1.2.3",' \
    '    "remove-me": "2.4.0"' \
    '  },' \
    '  "devDependencies": {"tool": "~3.4.5"},' \
    '  "optionalDependencies": {"optional": "4.5.6"},' \
    '  "peerDependencies": {' \
    '    "peer": "^5.6.7",' \
    '    "peer-range": ">=7.1.0 <8.0.0"' \
    '  },' \
    '  "config": {"port": 3000}' \
    '}'
}

commit_package_and_check() {
  (
    cd "$PROJECT_DIR" || exit 1
    git add -A -- package.json
    git commit -q -m "chore: update package manifest"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
}

commit_all_and_check() {
  (
    cd "$PROJECT_DIR" || exit 1
    git add -A
    git commit -q -m "chore: update package manifest"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
}

set_runtime_range() {
  RANGE_VALUE="$1" node - "$PROJECT_DIR/package.json" <<'NODE'
const fs = require('node:fs')
const packagePath = process.argv[2]
const manifest = JSON.parse(fs.readFileSync(packagePath, 'utf8'))
manifest.dependencies.runtime = process.env.RANGE_VALUE
fs.writeFileSync(packagePath, `${JSON.stringify(manifest, null, 2)}\n`)
NODE
}

commit_runtime_transition_and_check() {
  set_runtime_range "$1"
  (
    cd "$PROJECT_DIR" || exit 1
    git add package.json
    git commit -q -m "chore: prepare dependency range"
  )
  set_runtime_range "$2"
  commit_package_and_check
}

@test "dependency patch update within the same major does not require an ADR" {
  sed 's/\^1\.2\.3/\^1.2.4/' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]]
}

@test "minor updates across all dependency maps within the same major do not require an ADR" {
  sed \
    -e 's/\^1\.2\.3/\^1.3.0/' \
    -e 's/~3\.4\.5/~3.5.0/' \
    -e 's/4\.5\.6/4.6.0/' \
    -e 's/\^5\.6\.7/\^5.7.0/' \
    -e 's/>=7\.1\.0 <8\.0\.0/>=7.2.0 <8.0.0/' \
    "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]]
}

@test "satisfiable comparator range updates within the same majors do not require an ADR" {
  commit_runtime_transition_and_check ">=1.2.0 <1.4.0" ">=1.2.1 <1.4.0"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]]
}

@test "satisfiable hyphen range updates within the same majors do not require an ADR" {
  commit_runtime_transition_and_check "1.2.2 - 1.4.0" "1.2.3 - 1.5.0"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]]
}

@test "satisfiable exact-bound updates within the same major do not require an ADR" {
  commit_runtime_transition_and_check ">=1.2.0 <=1.2.0" ">=1.2.1 <=1.2.1"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]]
}

@test "satisfiable adjacent strict-bound updates within the same major do not require an ADR" {
  commit_runtime_transition_and_check ">1.2.3 <=1.2.4" ">1.2.4 <=1.2.5"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]]
}

@test "satisfiable OR and wildcard updates preserve the maintenance exemption" {
  commit_runtime_transition_and_check "^1.2.3 || 2.4.x" "^1.3.0 || 2.5.x"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]]
}

@test "exact prerelease updates within the same major do not require an ADR" {
  commit_runtime_transition_and_check "1.2.3-beta.1" "1.2.3-beta.2"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]]
}

@test "valid-to-reversed hyphen range requires an ADR" {
  commit_runtime_transition_and_check "1.2.2 - 1.2.3" "1.2.4 - 1.2.3"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "valid-to-empty comparator range requires an ADR" {
  commit_runtime_transition_and_check ">=1.2.0 <1.4.0" ">=1.5.0 <1.4.0"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "empty-to-empty comparator range still requires an ADR" {
  commit_runtime_transition_and_check ">=1.5.0 <1.4.0" ">=1.6.0 <1.4.0"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "conflicting exact comparator range requires an ADR" {
  commit_runtime_transition_and_check "1.2.3 1.2.4" "1.2.5 1.2.6"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "strict comparator gap with no stable version requires an ADR" {
  commit_runtime_transition_and_check ">1.2.2 <1.2.4" ">1.2.3 <1.2.4"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "wildcard prerelease syntax requires an ADR" {
  commit_runtime_transition_and_check "1.x-alpha" "1.x-beta"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "leading-zero semver syntax requires an ADR" {
  commit_runtime_transition_and_check "01.2.3" "01.2.4"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "comparator wildcards remain fail-closed parser uncertainty" {
  commit_runtime_transition_and_check ">=1.x" ">=1.X"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "empty dependency ranges require an ADR" {
  commit_runtime_transition_and_check "" " "

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "widening a comparator upper bound into a new major requires an ADR" {
  sed 's/>=7\.1\.0 <8\.0\.0/>=7.1.0 <8.9.0/' \
    "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "adding a dependency still requires an ADR" {
  sed 's/"runtime": "\^1\.2\.3",/"runtime": "^1.2.3",\n    "new-package": "1.0.0",/' \
    "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "removing a dependency still requires an ADR" {
  sed '/"remove-me":/d' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "deleting package.json still requires an ADR" {
  rm "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "renaming package.json away still requires an ADR" {
  mv "$PROJECT_DIR/package.json" "$PROJECT_DIR/manifest.json"

  commit_all_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "changing package.json from a file to a symlink still requires an ADR" {
  cp "$PROJECT_DIR/package.json" "$PROJECT_DIR/package-target.json"
  rm "$PROJECT_DIR/package.json"
  ln -s package-target.json "$PROJECT_DIR/package.json"

  commit_all_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "changing a dependency major still requires an ADR" {
  sed 's/\^1\.2\.3/\^2.0.0/' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "changing scripts still requires an ADR" {
  sed 's/"test": "true"/"test": "false"/' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "changing engines or config still requires an ADR" {
  sed \
    -e 's/">=20"/">=22"/' \
    -e 's/"port": 3000/"port": 4000/' \
    "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "changing a dependency from a non-semver source still requires an ADR" {
  sed 's#\^1\.2\.3#git+https://example.com/runtime.git#' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "changing dependency range shape still requires an ADR" {
  sed 's/\^1\.2\.3/~1.2.4/' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "malformed package.json still requires an ADR" {
  printf '%s\n' '{"name":"fixture","dependencies":{"runtime":"1.2.4"}' \
    > "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]]
}

@test "invalid or stale range fails closed" {
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=refs/heads/does-not-exist..HEAD"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: unable to enumerate trigger paths"* ]]
}
