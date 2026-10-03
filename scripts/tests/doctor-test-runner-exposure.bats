#!/usr/bin/env bats
# Spec 055 R3.2 / A3.1: doctor's conservative vitest heuristic.
#
# `.trellis/runtime` is a symlink to the payload. Payloads before 1.3.7 carry
# JS/TS tests, and vitest follows the link unless the project excludes
# '**/.trellis/**'. hc_test_runner_exposure never loads a config: it strips
# comments and matches one ERE under BSD /usr/bin/grep -E. The unit cases below
# drive it with PATH limited to /usr/bin:/bin; the last case runs the real
# portable doctor on an attached project to prove the row is wired.

REPO_ROOT="$(CDPATH= cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
HEALTH_CHECKS="$REPO_ROOT/scripts/lib/health-checks.sh"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"
load helpers/release-fixture
load helpers/t25-portable

setup() {
  PROJ="$BATS_TEST_TMPDIR/project"
  PAYLOAD="$BATS_TEST_TMPDIR/releases/1.3.5/payload"
  mkdir -p "$PROJ/.trellis" "$PAYLOAD/core-rules/pi/web-search/tests"
  printf 'test("x", () => {})\n' > "$PAYLOAD/core-rules/pi/web-search/tests/search.test.ts"
  ln -s "$PAYLOAD" "$PROJ/.trellis/runtime"
}

teardown() {
  [ -z "${T25_SANDBOX:-}" ] || t25_teardown_sandbox
}

exposure() {
  run env -i HOME="$HOME" PATH=/usr/bin:/bin /bin/bash --noprofile --norc -c \
    '. "$1"; hc_test_runner_exposure "$2"' _ "$HEALTH_CHECKS" "$PROJ"
}

no_row() {
  [ "$status" -eq 0 ] || { echo "expected no row (0), got $status: $output"; false; }
  [ -z "$output" ] || { echo "expected no row: $output"; false; }
}

warns() {
  [ "$status" -eq 2 ] || { echo "expected WARN (2), got $status: $output"; false; }
  [[ "$output" == 'test-runner exposure: '*"$1"* ]] || { echo "expected WARN naming '$1': $output"; false; }
}

config() {
  printf '%s\n' "$2" > "$PROJ/$1"
}

@test "A3.1 the ERE is stored with a literal backtick and BSD grep is what runs it" {
  grep -Fq "HC_VITEST_EXCLUDE_ERE='exclude[[:space:]]*:[[:space:]]*\\[[^]]*[\`" "$HEALTH_CHECKS"
  run grep -c 'HC_VITEST_EXCLUDE_ERE=.*x60' "$HEALTH_CHECKS"
  [ "$output" = 0 ]
  if [ "$(uname -s)" = Darwin ]; then
    /usr/bin/grep --version | grep -q 'BSD grep'
  fi
}

@test "A3.1 the heuristic's EREs use POSIX classes, never the GNU \\s" {
  run sed -n -e '/^HC_VITEST_EXCLUDE_ERE=/p' -e '/^hc_test_runner_exposure()/,/^}/p' "$HEALTH_CHECKS"
  [ -n "$output" ] || { echo 'the heuristic was not found'; false; }
  [[ "$output" != *'\s'* ]] || { echo "$output" | grep -n '\\s'; false; }
}

@test "A3.1 a literal exclude passes with single quotes, double quotes and backticks" {
  local quote
  for quote in "'" '"' '`'; do
    config vitest.config.ts "import { configDefaults, defineConfig } from 'vitest/config'
export default defineConfig({
  test: {
    exclude: [
      ...configDefaults.exclude,
      ${quote}**/.trellis/**${quote},
    ],
  },
})"
    exposure
    no_row
  done
  config vitest.config.ts "export default { test: { exclude: ['.trellis/**'] } }"
  exposure
  no_row
}

@test "A3.1 no exclude warns" {
  config vitest.config.ts "export default { test: { include: ['src/**/*.test.ts'] } }"
  exposure
  warns 'no literal'
  [[ "$output" == *'vitest.config.ts'* ]] || { echo "$output"; false; }
}

@test "A3.1 .trellis only in a comment warns" {
  config vitest.config.ts "export default { test: {
  // exclude: ['**/.trellis/**'],
  exclude: ['node_modules/**'] } }"
  exposure
  warns 'vitest.config.ts'
  config vitest.config.ts "export default { test: {
  /* exclude: ['**/.trellis/**'], */
  exclude: ['node_modules/**'] } }"
  exposure
  warns 'vitest.config.ts'
}

@test "A3.1 .trellis in an alias warns" {
  config vitest.config.ts "export default { resolve: { alias: { trellis: '.trellis/**' } }, test: { exclude: ['dist/**'] } }"
  exposure
  warns 'vitest.config.ts'
}

@test "A3.1 two configs with one lacking the exclude warn" {
  config vitest.config.ts "export default { test: { exclude: ['**/.trellis/**'] } }"
  config vite.config.ts "export default { test: { environment: 'jsdom' } }"
  exposure
  warns 'vite.config.ts'
  [[ "$output" != *'vitest.config.ts'* ]] || { echo "$output"; false; }
}

@test "A3.1 a vite config with no test block is not read" {
  config vite.config.ts "export default { build: { outDir: 'dist' } }"
  exposure
  no_row
}

@test "A3.1 a workspace file or test.projects always warns" {
  config vitest.config.ts "export default { test: { exclude: ['**/.trellis/**'] } }"
  config vitest.workspace.ts "export default ['packages/*']"
  exposure
  warns 'vitest.workspace.ts is present'

  rm "$PROJ/vitest.workspace.ts"
  config vitest.config.ts "export default { test: { projects: ['packages/*'], exclude: ['**/.trellis/**'] } }"
  exposure
  warns 'vitest.config.ts declares test.projects'
}

@test "A3.1 an exclude through a variable warns (documented false positive)" {
  config vitest.config.ts "const trellis = '**/.trellis/**'
export default { test: { exclude: [...configDefaults.exclude, trellis] } }"
  exposure
  warns 'vitest.config.ts'
}

@test "A3.1 a payload with no JS/TS tests gives no row" {
  rm "$PAYLOAD/core-rules/pi/web-search/tests/search.test.ts"
  printf '@test "x" { true; }\n' > "$PAYLOAD/core-rules/pi/web-search/tests/search.bats"
  config vitest.config.ts "export default { test: { include: ['src/**/*.test.ts'] } }"
  exposure
  no_row
}

@test "A3.1 a --config file lacking the exclude warns even when vitest.config passes" {
  config vitest.config.ts "export default { test: { exclude: ['**/.trellis/**'] } }"
  config other.ts "export default { test: { include: ['e2e/**'] } }"
  config package.json '{ "scripts": { "test": "vitest run", "e2e": "vitest --config other.ts" } }'
  exposure
  warns 'other.ts'

  config package.json '{ "scripts": { "e2e": "vitest --config=./other.ts" } }'
  exposure
  warns 'other.ts'
}

@test "A3.1 a quoted --config file lacking the exclude warns" {
  config vitest.config.ts "export default { test: { exclude: ['**/.trellis/**'] } }"
  config other.ts "export default { test: { include: ['e2e/**'] } }"
  config package.json "{ \"scripts\": { \"e2e\": \"vitest --config 'other.ts'\" } }"
  exposure
  warns 'other.ts'

  config package.json '{ "scripts": { "e2e": "vitest --config \"other.ts\"" } }'
  exposure
  warns 'other.ts'

  config package.json '{ "scripts": { "e2e": "vitest run --config=\"./other.ts\" --reporter dot" } }'
  exposure
  warns 'other.ts'

  config other.ts "export default { test: { exclude: ['**/.trellis/**'] } }"
  exposure
  no_row
}

# ---------------------------------------------------------------------------
# Wiring: the real portable doctor on an attached project.
# ---------------------------------------------------------------------------

exposure_install_release() {
  local version=1.2.4 repo="$T25_SANDBOX/exposure release source"
  mkdir -p "$repo/scripts" "$repo/core-rules/skills/fixture-skill" "$repo/core-rules/githooks" \
    "$repo/core-rules/pi/web-search/tests"
  cp "$REPO_ROOT/scripts/seed-inheritance-symlinks.sh" "$repo/scripts/seed-inheritance-symlinks.sh"
  cp "$REPO_ROOT/scripts/attach-project.sh" "$repo/scripts/attach-project.sh"
  cp "$REPO_ROOT/scripts/trellis-launcher.sh" "$repo/scripts/trellis-launcher.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$repo/scripts/lib"
  chmod 755 "$repo/scripts/seed-inheritance-symlinks.sh" "$repo/scripts/attach-project.sh"
  printf '{"schema_version":2}\n' > "$repo/trellis.config.json"
  printf '# fixture policy\n' > "$repo/core-rules/CLAUDE.md"
  printf '%s\n' "$version" > "$repo/core-rules/VERSION"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$repo/core-rules/githooks/pre-push"
  chmod 755 "$repo/core-rules/githooks/pre-push"
  printf '%s\n' '---' 'name: fixture-skill' 'description: fixture skill' '---' > \
    "$repo/core-rules/skills/fixture-skill/SKILL.md"
  printf 'test("x", () => {})\n' > "$repo/core-rules/pi/web-search/tests/search.test.ts"
  cat > "$repo/core-rules/inheritance-manifest.json" <<'JSON'
{
  "schema_version": 1,
  "harnesses": {
    "claude": {
      "links": [
        {"source_children":"core-rules/skills","destination_dir":".claude/skills","entry_type":"directory","required_file":"SKILL.md"}
      ],
      "render": []
    },
    "codex": {
      "links": [
        {"source_children":"core-rules/skills","destination_dir":".agents/skills","entry_type":"directory","required_file":"SKILL.md"}
      ],
      "render": []
    }
  }
}
JSON
  release_fixture_install "$T25_USER_HOME" "$T25_TRELLIS_HOME" "$version" "$repo" || return 1
  T25_RELEASE="$version"
  T25_PAYLOAD="$T25_TRELLIS_HOME/releases/$version/payload"
  T25_MANIFEST="$T25_PAYLOAD/core-rules/inheritance-manifest.json"
}

@test "A3.1 the portable doctor reports the row for an attached project and drops it once excluded" {
  t25_setup_attachment_fixture
  exposure_install_release
  t25_attach >/dev/null
  printf "export default { test: { include: ['src/**/*.test.ts'] } }\n" > "$T25_PROJECT/vitest.config.ts"

  run t25_attachment_env bash "$DOCTOR" --home "$T25_TRELLIS_HOME" --project t25-fixture-project
  t25_contains "$output" "test-runner exposure: .trellis/runtime holds JS/TS test files"
  t25_contains "$output" 'no literal'

  printf "export default { test: { exclude: ['**/.trellis/**'] } }\n" > "$T25_PROJECT/vitest.config.ts"
  run t25_attachment_env bash "$DOCTOR" --home "$T25_TRELLIS_HOME" --project t25-fixture-project
  t25_lacks "$output" 'test-runner exposure'
}
