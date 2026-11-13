#!/usr/bin/env bats
# Turbo recurrence diagnostics use only private homes and stubbed host tools.
REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"

setup() {
  SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${TMPDIR:-/tmp}}/turbo-unknown.XXXXXX")"; SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/home"; TRELLIS_HOME="$SANDBOX/trellis"; STUB_BIN="$SANDBOX/bin"
  CANON="$SANDBOX/canonical"; PROJECT="$SANDBOX/projects/app"
  local fenced_git
  fenced_git="$(command -v git)"
  mkdir -p "$HOME" "$TRELLIS_HOME" "$STUB_BIN" "$CANON/audits" "$PROJECT"
  chmod 700 "$HOME" "$TRELLIS_HOME"
  printf '#!/bin/bash\nexec %q "$@"\n' "$fenced_git" > "$STUB_BIN/git"
  printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/gh"
  printf '#!/bin/sh\nexit 99\n' > "$STUB_BIN/launchctl"
  chmod 700 "$STUB_BIN/git" "$STUB_BIN/gh" "$STUB_BIN/launchctl"
  PATH="$STUB_BIN:$PATH"; export HOME TRELLIS_HOME PATH
  . "$REPO_ROOT/scripts/lib/disk-janitor-lib.sh"
  . "$REPO_ROOT/scripts/lib/health-checks.sh"
}

teardown() { [ -z "${SANDBOX:-}" ] || rm -rf "${SANDBOX:?}"; }

write_scoped() { printf '%s\n' '{"tasks":{"build":{"outputs":[".next/**","!.next/cache/**"]}}}' > "$PROJECT/turbo.json"; }
write_unparseable() { printf '{\n // comment\n "tasks": {"build": {"outputs": [".next/**"]}}\n}\n' > "$PROJECT/turbo.json"; }

@test "doctor warns with the parse error when turbo outputs cannot be checked" {
  write_scoped
  run hc_turbo_outputs "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  write_unparseable
  run hc_turbo_outputs "$PROJECT"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"could not check"*"$PROJECT/turbo.json"*"parse error"* ]] || { echo "$output"; false; }
  [[ "$output" != *"outputs are scoped"* ]] || false
  PATH="$STUB_BIN" run hc_turbo_outputs "$PROJECT"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"jq unavailable"* ]] || { echo "$output"; false; }
}

@test "janitor predicate returns unknown, not clean, on parse failure or missing jq" {
  write_scoped
  run dj_turbo_outputs_unscoped "$PROJECT/turbo.json"
  [ "$status" -eq 1 ] || { echo "$output"; false; }
  write_unparseable
  run dj_turbo_outputs_unscoped "$PROJECT/turbo.json"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"could not check"*"$PROJECT/turbo.json"*"parse error"* ]] || { echo "$output"; false; }
  PATH="$STUB_BIN" run dj_turbo_outputs_unscoped "$PROJECT/turbo.json"
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *"jq unavailable"* ]] || { echo "$output"; false; }
}

@test "janitor report distinguishes unknown turbo state from a clean recurrence scan" {
  git init -q -b main "$PROJECT"
  git -C "$PROJECT" config user.name fixture
  git -C "$PROJECT" config user.email fixture@example.invalid
  printf 'tracked\n' > "$PROJECT/tracked"
  git -C "$PROJECT" add tracked
  git -C "$PROJECT" commit -qm fixture
  printf '%s\n' '{"schema_version":2,"maintainer_name":"Fixture","github_user":"fixture","harnesses":["claude"]}' > "$CANON/trellis.config.json"
  printf '{"schema_version":1,"source_root":"%s","release_remote":"%s","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["%s"]}}}\n' "$CANON" "$CANON" "$SANDBOX/projects" > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
  printf '%s\n' '{"schema_version":1,"projects":{},"discovery_ignores":{}}' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
  run bash -c '. "$1/scripts/lib/trellis-home.sh"; . "$1/scripts/lib/local-registry.sh"; local_registry_register_worktree "$2" personal fixture "$3" 1.2.3 '\''["claude"]'\'' ""' _ "$REPO_ROOT" "$TRELLIS_HOME" "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  write_unparseable
  run env TRELLIS_CONFIG="$CANON/trellis.config.json" DJ_BUILD_ACTIVE_OVERRIDE=0 \
    TRELLIS_WORKTREE_ROOT="$SANDBOX/worktrees" bash "$REPO_ROOT/scripts/disk-janitor.sh" --report --scopes caches
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"could not check"*"$PROJECT/turbo.json"*"parse error"* ]] || { echo "$output"; false; }
  [[ "$output" != *"no unscoped turbo outputs across scanned projects"* ]] || { echo "$output"; false; }
}
