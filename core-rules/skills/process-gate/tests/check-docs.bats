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
  [[ "$output" != *"ADR: trigger paths changed"* ]] || false
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
  [[ "$output" != *"ADR: trigger paths changed"* ]] || false
}

@test "satisfiable comparator range updates within the same majors do not require an ADR" {
  commit_runtime_transition_and_check ">=1.2.0 <1.4.0" ">=1.2.1 <1.4.0"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]] || false
}

@test "satisfiable hyphen range updates within the same majors do not require an ADR" {
  commit_runtime_transition_and_check "1.2.2 - 1.4.0" "1.2.3 - 1.5.0"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]] || false
}

@test "satisfiable exact-bound updates within the same major do not require an ADR" {
  commit_runtime_transition_and_check ">=1.2.0 <=1.2.0" ">=1.2.1 <=1.2.1"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]] || false
}

@test "satisfiable adjacent strict-bound updates within the same major do not require an ADR" {
  commit_runtime_transition_and_check ">1.2.3 <=1.2.4" ">1.2.4 <=1.2.5"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]] || false
}

@test "satisfiable OR and wildcard updates preserve the maintenance exemption" {
  commit_runtime_transition_and_check "^1.2.3 || 2.4.x" "^1.3.0 || 2.5.x"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]] || false
}

@test "exact prerelease updates within the same major do not require an ADR" {
  commit_runtime_transition_and_check "1.2.3-beta.1" "1.2.3-beta.2"

  [ "$status" -eq 0 ]
  [[ "$output" != *"ADR: trigger paths changed"* ]] || false
}

@test "valid-to-reversed hyphen range requires an ADR" {
  commit_runtime_transition_and_check "1.2.2 - 1.2.3" "1.2.4 - 1.2.3"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "valid-to-empty comparator range requires an ADR" {
  commit_runtime_transition_and_check ">=1.2.0 <1.4.0" ">=1.5.0 <1.4.0"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "empty-to-empty comparator range still requires an ADR" {
  commit_runtime_transition_and_check ">=1.5.0 <1.4.0" ">=1.6.0 <1.4.0"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "conflicting exact comparator range requires an ADR" {
  commit_runtime_transition_and_check "1.2.3 1.2.4" "1.2.5 1.2.6"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "strict comparator gap with no stable version requires an ADR" {
  commit_runtime_transition_and_check ">1.2.2 <1.2.4" ">1.2.3 <1.2.4"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "wildcard prerelease syntax requires an ADR" {
  commit_runtime_transition_and_check "1.x-alpha" "1.x-beta"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "leading-zero semver syntax requires an ADR" {
  commit_runtime_transition_and_check "01.2.3" "01.2.4"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "comparator wildcards remain fail-closed parser uncertainty" {
  commit_runtime_transition_and_check ">=1.x" ">=1.X"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "empty dependency ranges require an ADR" {
  commit_runtime_transition_and_check "" " "

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "widening a comparator upper bound into a new major requires an ADR" {
  sed 's/>=7\.1\.0 <8\.0\.0/>=7.1.0 <8.9.0/' \
    "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "adding a dependency still requires an ADR" {
  sed 's/"runtime": "\^1\.2\.3",/"runtime": "^1.2.3",\n    "new-package": "1.0.0",/' \
    "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "removing a dependency still requires an ADR" {
  sed '/"remove-me":/d' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "deleting package.json still requires an ADR" {
  rm "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "renaming package.json away still requires an ADR" {
  mv "$PROJECT_DIR/package.json" "$PROJECT_DIR/manifest.json"

  commit_all_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "changing package.json from a file to a symlink still requires an ADR" {
  cp "$PROJECT_DIR/package.json" "$PROJECT_DIR/package-target.json"
  rm "$PROJECT_DIR/package.json"
  ln -s package-target.json "$PROJECT_DIR/package.json"

  commit_all_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "changing a dependency major still requires an ADR" {
  sed 's/\^1\.2\.3/\^2.0.0/' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "changing scripts still requires an ADR" {
  sed 's/"test": "true"/"test": "false"/' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "changing engines or config still requires an ADR" {
  sed \
    -e 's/">=20"/">=22"/' \
    -e 's/"port": 3000/"port": 4000/' \
    "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "changing a dependency from a non-semver source still requires an ADR" {
  sed 's#\^1\.2\.3#git+https://example.com/runtime.git#' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "changing dependency range shape still requires an ADR" {
  sed 's/\^1\.2\.3/~1.2.4/' "$PROJECT_DIR/package.json" > "$PROJECT_DIR/package.json.next"
  mv "$PROJECT_DIR/package.json.next" "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "malformed package.json still requires an ADR" {
  printf '%s\n' '{"name":"fixture","dependencies":{"runtime":"1.2.4"}' \
    > "$PROJECT_DIR/package.json"

  commit_package_and_check

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "invalid or stale range fails closed" {
  # The base must resolve (gate config loads from it); the stale end is the
  # row's own fail-closed path.
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD..refs/heads/does-not-exist"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ADR: unable to enumerate trigger paths"* ]] || false
}

# --- large-payload membership: the SIGPIPE regression ----------------------
# The three membership tests against $changed_files must not pipe into an
# early-exiting `grep -q`. Under pipefail `grep -q` exits at the first match,
# `printf` takes SIGPIPE and returns 141, and the pipeline reports 141, so the
# check reports "not found" because the match succeeded early. Measurements are
# in the release evidence, not here.
#
# These tests invoke check-docs.sh itself. A test that re-implements the fixed
# expression would pass even if the production logic were broken or deleted.
# Invocations are kept to a handful; the payload does the work, since the race
# needs a changed-file list large enough to fill a pipe buffer.

# Commit a wide changed-file set under a CHANGELOG_PATHS trigger prefix, then
# run the real checker over exactly that one commit. $1 is the commit SUBJECT,
# so a test can place a gotcha phrase inside the checked range; remaining args
# are membership targets to touch in the SAME commit. Anything a case needs the
# checker to see must be uncommitted when this is called — HEAD~1..HEAD covers
# this commit only, so a precondition staged earlier is outside the range and
# the case would be vacuous.
seed_wide_change() {
  local subject="$1"
  shift
  (
    cd "$PROJECT_DIR" || exit 1
    mkdir -p scripts
    i=0
    while [ "$i" -lt 900 ]; do
      printf 'x\n' > "scripts/generated-$i.sh"
      i=$((i + 1))
    done
    for target in "$@"; do
      mkdir -p "$(dirname "$target")"
      printf '\n- entry %s\n' "$(date +%s)" >> "$target"
    done
    git add -A
    git commit -q -m "$subject"
  )
  run bash -c "cd '$PROJECT_DIR' && '$SCRIPT' --range=HEAD~1..HEAD"
}

@test "changelog membership is found in a large changed-file set" {
  seed_wide_change "chore: wide change" CHANGELOG.md

  [ "$status" -eq 0 ]
  [[ "$output" != *"CHANGELOG.md: not updated despite code changes"* ]] || false
}

@test "changelog absence is still reported in a large changed-file set" {
  seed_wide_change "chore: wide change"

  [ "$status" -eq 1 ]
  [[ "$output" == *"CHANGELOG.md: not updated despite code changes"* ]] || false
}

@test "gotchas membership is found when the hint is in the checked range" {
  # "silently" is one of check-docs.sh's gotcha_phrases, and it has to be in
  # THIS commit: the check reads git log over $RANGE, not the whole history.
  seed_wide_change "fix: the hook silently dropped the exclude block" \
    CHANGELOG.md gotchas.md

  [ "$status" -eq 0 ]
  [[ "$output" != *"gotchas.md"* ]] || false
}

@test "gotchas absence is still reported when the hint is in the checked range" {
  seed_wide_change "fix: the hook silently dropped the exclude block" CHANGELOG.md

  [ "$status" -eq 2 ]
  [[ "$output" == *"gotchas.md: commit message hints suggest"* ]] || false
}

@test "EPM membership is found when the trigger is in the checked range" {
  (
    cd "$PROJECT_DIR" || exit 1
    printf '# process\n' > engineering-process.md
    git add engineering-process.md
    git commit -q -m "chore: seed EPM"
    # Left UNCOMMITTED so seed_wide_change commits it into the checked range.
    mkdir -p .claude/skills
    printf 'x\n' > .claude/skills/trigger.md
  )
  export PROCESS_GATE_PROJECT_EPM="engineering-process.md"

  seed_wide_change "chore: wide change" CHANGELOG.md engineering-process.md

  [ "$status" -eq 0 ]
  [[ "$output" != *"engineering-process.md: process trigger paths changed"* ]] || false
}

@test "EPM absence is still reported when the trigger is in the checked range" {
  (
    cd "$PROJECT_DIR" || exit 1
    printf '# process\n' > engineering-process.md
    git add engineering-process.md
    git commit -q -m "chore: seed EPM"
    mkdir -p .claude/skills
    printf 'x\n' > .claude/skills/trigger.md
  )
  export PROCESS_GATE_PROJECT_EPM="engineering-process.md"

  seed_wide_change "chore: wide change" CHANGELOG.md

  [ "$status" -eq 2 ]
  [[ "$output" == *"engineering-process.md: process trigger paths changed"* ]] || false
}

@test "no membership test against changed_files pipes into an early-exiting grep" {
  # Supplementary source guard. The integration cases above are the evidence;
  # this only stops the transport being reintroduced silently. Scoped to
  # `grep -q`: a plain grep on the same payload consumes the whole stream and
  # is not exposed. check-docs.sh has one such site for the ADR path filter.
  run grep -nE 'printf "%s.n" "\$changed_files" \| *grep [^|]*-[A-Za-z]*q' \
    "$BATS_TEST_DIRNAME/../scripts/check-docs.sh"

  [ "$status" -ne 0 ]
}

@test "143-pg: quoted code filenames trigger a changelog without rejecting docs-only changes" {
  printf 'docs\n' > "$PROJECT_DIR/notes.md"
  commit_all_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  mkdir -p "$PROJECT_DIR/src"
  printf 'code\n' > "$PROJECT_DIR/src/café.ts"
  commit_all_and_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"CHANGELOG.md: not updated despite code changes"* ]] || false
}

@test "143-pg: deleted code requires a changelog but docs deletion does not" {
  mkdir -p "$PROJECT_DIR/src"
  printf 'code\n' > "$PROJECT_DIR/src/old.ts"
  printf 'docs\n' > "$PROJECT_DIR/old-doc.md"
  git -C "$PROJECT_DIR" add src/old.ts old-doc.md
  git -C "$PROJECT_DIR" commit -qm 'seed files'
  git -C "$PROJECT_DIR" rm -q old-doc.md
  commit_all_and_check
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  git -C "$PROJECT_DIR" rm -q src/old.ts
  commit_all_and_check
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"CHANGELOG.md: not updated despite code changes"* ]] || false
}

@test "143-pg-r2: unpadded reference resolves Trellis numbered ADR" {
  local trellis_root
  trellis_root="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd -P)"
  mkdir -p "$PROJECT_DIR/docs/adr"
  cp "$trellis_root/docs/adr/0001-security-gate-stack-consolidation.md" "$PROJECT_DIR/docs/adr/"
  git -C "$PROJECT_DIR" add docs/adr
  git -C "$PROJECT_DIR" commit -qm 'seed real numbered ADR'
  printf '{"dependencies":{"new":"1.0.0"}}\n' > "$PROJECT_DIR/package.json"
  git -C "$PROJECT_DIR" add package.json
  git -C "$PROJECT_DIR" commit -qm 'change dependencies' -m 'Refs: ADR-1'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "143-pg-r2: full path cites Trellis date-named ADR without accepting prefixes" {
  local trellis_root path='docs/adr/2026-10-18-retire-astra-routing.md'
  trellis_root="$(cd "$BATS_TEST_DIRNAME/../../../.." && pwd -P)"
  mkdir -p "$PROJECT_DIR/docs/adr"
  cp "$trellis_root/$path" "$PROJECT_DIR/$path"
  git -C "$PROJECT_DIR" add "$path"
  git -C "$PROJECT_DIR" commit -qm 'seed real dated ADR'
  printf '{"dependencies":{"new":"1.0.0"}}\n' > "$PROJECT_DIR/package.json"
  git -C "$PROJECT_DIR" add package.json
  git -C "$PROJECT_DIR" commit -qm 'change dependencies' -m "Refs: [decision]($path)"
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf '{"dependencies":{"other":"2.0.0"}}\n' > "$PROJECT_DIR/package.json"
  git -C "$PROJECT_DIR" add package.json
  git -C "$PROJECT_DIR" commit -qm 'change dependencies again' -m "Refs: ${path}-not-the-adr"
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
  printf '{"dependencies":{"prefix":"3.0.0"}}\n' > "$PROJECT_DIR/package.json"
  git -C "$PROJECT_DIR" add package.json
  git -C "$PROJECT_DIR" commit -qm 'change dependencies with prefixed path' -m "Refs: x${path}"
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
  printf '{"dependencies":{"another":"3.0.0"}}\n' > "$PROJECT_DIR/package.json"
  git -C "$PROJECT_DIR" add package.json
  git -C "$PROJECT_DIR" commit -qm 'change dependencies once more' -m 'Refs: ADR-2026'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
}

@test "143-pg-r3: literal paths must name ADRs, not README or template files" {
  mkdir -p "$PROJECT_DIR/docs/adr"
  local name i=0
  for name in README.md template.md 0042-decision.md ADR-0043-decision.md adr-0044.md 2026-10-18-decision.md; do
    printf '# fixture\n' > "$PROJECT_DIR/docs/adr/$name"
  done
  git -C "$PROJECT_DIR" add docs/adr
  git -C "$PROJECT_DIR" commit -qm 'seed ADR directory'
  for name in README.md template.md; do
    i=$((i + 1))
    printf '{"dependencies":{"new":"%s.0.0"}}\n' "$i" > "$PROJECT_DIR/package.json"
    git -C "$PROJECT_DIR" add package.json
    git -C "$PROJECT_DIR" commit -qm 'change dependencies' -m "Refs: docs/adr/$name"
    run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
    [ "$status" -eq 1 ] || { echo "accepted $name: $output"; false; }
    [[ "$output" == *"ADR: trigger paths changed"* ]] || false
  done
  for name in 0042-decision.md ADR-0043-decision.md adr-0044.md 2026-10-18-decision.md; do
    i=$((i + 1))
    printf '{"dependencies":{"new":"%s.0.0"}}\n' "$i" > "$PROJECT_DIR/package.json"
    git -C "$PROJECT_DIR" add package.json
    git -C "$PROJECT_DIR" commit -qm 'change dependencies' -m "Refs: docs/adr/$name"
    run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "rejected $name: $output"; false; }
  done
}

@test "143-pg-r2: numbered ADR filenames may carry ADR prefixes" {
  mkdir -p "$PROJECT_DIR/docs/adr"
  printf '# ADR\n' > "$PROJECT_DIR/docs/adr/ADR-0042-decision.md"
  printf '# ADR\n' > "$PROJECT_DIR/docs/adr/adr-0043-decision.md"
  git -C "$PROJECT_DIR" add docs/adr
  git -C "$PROJECT_DIR" commit -qm 'seed prefixed ADRs'
  local number
  for number in 42 43; do
    printf '{"dependencies":{"new":"%s.0.0"}}\n' "$number" > "$PROJECT_DIR/package.json"
    git -C "$PROJECT_DIR" add package.json
    git -C "$PROJECT_DIR" commit -qm 'change dependencies' -m "Refs: ADR-$number"
    run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
  done
}

@test "143-pg-r2: symlink ADR cannot satisfy a reference but a tracked regular ADR can" {
  mkdir -p "$PROJECT_DIR/docs/adr"
  ln -s ../../missing "$PROJECT_DIR/docs/adr/0042-link.md"
  git -C "$PROJECT_DIR" add docs/adr/0042-link.md
  git -C "$PROJECT_DIR" commit -qm 'seed symlink ADR'
  printf '{"dependencies":{"new":"1.0.0"}}\n' > "$PROJECT_DIR/package.json"
  git -C "$PROJECT_DIR" add package.json
  git -C "$PROJECT_DIR" commit -qm 'change dependencies' -m 'Refs: ADR-0042'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
  unlink "$PROJECT_DIR/docs/adr/0042-link.md"
  printf '# Real ADR\n' > "$PROJECT_DIR/docs/adr/0042-link.md"
  git -C "$PROJECT_DIR" add docs/adr/0042-link.md
  git -C "$PROJECT_DIR" commit -qm 'make ADR regular'
  printf '{"dependencies":{"new":"2.0.0"}}\n' > "$PROJECT_DIR/package.json"
  git -C "$PROJECT_DIR" add package.json
  git -C "$PROJECT_DIR" commit -qm 'change dependencies again' -m 'Refs: ADR-0042'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "143-pg-r2: changelog path enumeration failure is independently fatal" {
  git -C "$PROJECT_DIR" commit --allow-empty -qm 'chore: no changes'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local mock_bin="$BATS_TEST_TMPDIR/mock-git" real_git
  real_git="$(command -v git)"
  mkdir "$mock_bin"
  printf '%s\n' '#!/bin/bash' \
    'case " $* " in *" --name-only --no-renames --diff-filter=ACMRDT -z "*) exit 73 ;; esac' \
    'exec "$REAL_GIT" "$@"' > "$mock_bin/git"
  chmod +x "$mock_bin/git"
  run env PATH="$mock_bin:$PATH" REAL_GIT="$real_git" \
    bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"CHANGELOG: unable to enumerate changed paths"* ]] || false
}

@test "143-pg: ADR reference must resolve to an existing tracked ADR" {
  mkdir -p "$PROJECT_DIR/docs/adr"
  printf '# Existing ADR\n' > "$PROJECT_DIR/docs/adr/0001-decision.md"
  git -C "$PROJECT_DIR" add docs/adr/0001-decision.md
  git -C "$PROJECT_DIR" commit -qm 'seed existing decision'
  # An untracked file with the requested number must not satisfy the range.
  printf '# Untracked\n' > "$PROJECT_DIR/docs/adr/0099-untracked.md"
  printf '{"dependencies":{"new":"1.0.0"}}\n' > "$PROJECT_DIR/package.json"
  git -C "$PROJECT_DIR" add package.json
  git -C "$PROJECT_DIR" commit -qm 'change dependencies' -m 'See ADR-0099'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  [[ "$output" == *"ADR: trigger paths changed"* ]] || false
  printf '{"dependencies":{"new":"1.0.0","another":"2.0.0"}}\n' > "$PROJECT_DIR/package.json"
  git -C "$PROJECT_DIR" add package.json
  git -C "$PROJECT_DIR" commit -qm 'change dependencies again' -m 'See ADR-0099 and ADR-0001'
  run bash -c 'cd "$1" && exec bash "$2" --range=HEAD~1..HEAD' fixture "$PROJECT_DIR" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}
