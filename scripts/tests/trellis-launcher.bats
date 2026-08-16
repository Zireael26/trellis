#!/usr/bin/env bats
# Immutable-launcher and dispatcher contracts.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LAUNCHER_TEMPLATE="$REPO_ROOT/scripts/trellis-launcher.sh"
DISPATCHER_TEMPLATE="$REPO_ROOT/scripts/trellis"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  SOURCE_POISON="$SANDBOX/source-poison"
  SOURCE_POISON_MARKER="$SANDBOX/source-poison-ran"
  ARGV_LOG="$HOME/trellis-launcher-argv.log"
  ROUTE_LOG="$SANDBOX/route.log"
  LAUNCHER="$SANDBOX/bin/trellis"
  DISPATCH_ROOT="$SANDBOX/dispatcher"
  mkdir -p "$HOME" "$TRELLIS_HOME/releases" "$SANDBOX/projects" "$SOURCE_POISON/scripts" "$SANDBOX/bin"
  chmod 700 "$TRELLIS_HOME"
  cat > "$SOURCE_POISON/scripts/trellis" <<EOF
#!/usr/bin/env bash
printf 'source poison ran\n' > "$SOURCE_POISON_MARKER"
exit 99
EOF
  chmod 755 "$SOURCE_POISON/scripts/trellis"
  cp "$LAUNCHER_TEMPLATE" "$LAUNCHER"
  chmod 755 "$LAUNCHER"
  write_config 1.2.3
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] || return 0
  find "$SANDBOX" -depth -type d -exec chmod u+w {} \; 2>/dev/null || true
  rm -rf "$SANDBOX"
}

write_config() {
  local version="$1" remote="${2:-fixture://release}"
  jq -n --arg source "$SOURCE_POISON" --arg release "$version" --arg remote "$remote" --arg projects "$SANDBOX/projects" '
    {
      schema_version: 1,
      source_root: $source,
      release_remote: $remote,
      active_cli_release: $release,
      default_fleet: "personal",
      fleets: {personal: {discovery_roots: [$projects]}}
    }
  ' > "$TRELLIS_HOME/config.json"
  chmod 600 "$TRELLIS_HOME/config.json"
}

make_bootstrap_release_remote() {
  local version="$1" remote="$2"
  mkdir -p "$remote/core-rules" "$remote/scripts"
  cp "$DISPATCHER_TEMPLATE" "$remote/scripts/trellis"
  cp "$REPO_ROOT/scripts/release.sh" "$remote/scripts/release.sh"
  cp -R "$REPO_ROOT/scripts/lib" "$remote/scripts/lib"
  printf '%s\n' "$version" > "$remote/core-rules/VERSION"
  (
    cd "$remote" || exit 1
    git init -q
    git config user.email fixture@example.invalid
    git config user.name Fixture
    git add core-rules scripts
    git commit -qm "release $version"
    git tag -a "v$version" -m "release $version"
  )
}

make_release() {
  local version="$1" fixture="${2:-dispatcher}" manifest file relative mode oid target
  RELEASE_DIR="$TRELLIS_HOME/releases/$version"
  PAYLOAD="$RELEASE_DIR/payload"
  manifest="$SANDBOX/manifest-$version.jsonl"
  mkdir -p "$PAYLOAD/scripts"
  case "$fixture" in
    dispatcher)
      cat > "$PAYLOAD/scripts/trellis" <<'EOF'
#!/bin/bash
{
  printf '%s\n' "$#"
  for argument in "$@"; do printf '<%s>\n' "$argument"; done
} > "$HOME/trellis-launcher-argv.log"
exit 3
EOF
      ;;
    session-context)
      mkdir -p \
        "$PAYLOAD/core-rules/hooks/lib" \
        "$PAYLOAD/core-rules/codex/hooks/lib"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      cp "$REPO_ROOT/core-rules/hooks/session-context.sh" \
        "$PAYLOAD/core-rules/hooks/session-context.sh"
      cp "$REPO_ROOT/core-rules/hooks/lib/deps.sh" \
        "$PAYLOAD/core-rules/hooks/lib/deps.sh"
      cp "$REPO_ROOT/core-rules/hooks/lib/autonomy.sh" \
        "$PAYLOAD/core-rules/hooks/lib/autonomy.sh"
      cp "$REPO_ROOT/core-rules/codex/hooks/session-context.sh" \
        "$PAYLOAD/core-rules/codex/hooks/session-context.sh"
      cp "$REPO_ROOT/core-rules/codex/hooks/lib/deps.sh" \
        "$PAYLOAD/core-rules/codex/hooks/lib/deps.sh"
      cp "$REPO_ROOT/core-rules/codex/hooks/lib/autonomy.sh" \
        "$PAYLOAD/core-rules/codex/hooks/lib/autonomy.sh"
      chmod 755 \
        "$PAYLOAD/core-rules/hooks/session-context.sh" \
        "$PAYLOAD/core-rules/codex/hooks/session-context.sh"
      printf '{"autonomy_default":4}\n' > "$PAYLOAD/trellis.config.json"
      ;;
    command-bundle)
      mkdir -p "$PAYLOAD/core-rules"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      cp "$REPO_ROOT/scripts/release.sh" "$PAYLOAD/scripts/release.sh"
      cp "$REPO_ROOT/scripts/upgrade.sh" "$PAYLOAD/scripts/upgrade.sh"
      cp -R "$REPO_ROOT/scripts/lib" "$PAYLOAD/scripts/lib"
      chmod 755 "$PAYLOAD/scripts/release.sh" "$PAYLOAD/scripts/upgrade.sh"
      printf '%s\n' "$version" > "$PAYLOAD/core-rules/VERSION"
      ;;
    command-bundle-pre-bundle-upgrade|command-bundle-unmarked-upgrade)
      # An installed payload from before the launcher routed upgrade through a
      # verified in-memory bundle. Everything else is the current release.
      mkdir -p "$PAYLOAD/core-rules"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      cp "$REPO_ROOT/scripts/release.sh" "$PAYLOAD/scripts/release.sh"
      cp -R "$REPO_ROOT/scripts/lib" "$PAYLOAD/scripts/lib"
      cat > "$PAYLOAD/scripts/upgrade.sh" <<'EOF'
#!/bin/sh
# Pre-bundle upgrade wrapper: a pathname bootstrap and nothing else.
printf 'legacy upgrade wrapper ran\n'
exit 5
EOF
      if [ "$fixture" = command-bundle-pre-bundle-upgrade ]; then
        cat >> "$PAYLOAD/scripts/upgrade.sh" <<'EOF'
# -- trellis upgrade body --
set -u
SCRIPT_DIR="${TRELLIS_UPGRADE_SOURCE_DIR:-}"
printf 'legacy upgrade body ran\n'
exit 0
EOF
      fi
      chmod 755 "$PAYLOAD/scripts/release.sh" "$PAYLOAD/scripts/upgrade.sh"
      printf '%s\n' "$version" > "$PAYLOAD/core-rules/VERSION"
      ;;
    session-primer)
      mkdir -p "$PAYLOAD/core-rules/hooks"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      cat > "$PAYLOAD/core-rules/hooks/inject-primer-index.sh" <<'EOF'
#!/bin/bash
printf 'trusted-primer:%s:%s git-dir=%s git-work-tree=%s fsmonitor=%s hooks=%s no-system=%s global=%s\n' \
  "$CLAUDE_PROJECT_DIR" "$TRELLIS_ROOT" "${GIT_DIR-unset}" "${GIT_WORK_TREE-unset}" \
  "${GIT_CONFIG_VALUE_0-unset}" "${GIT_CONFIG_VALUE_1-unset}" \
  "${GIT_CONFIG_NOSYSTEM-unset}" "${GIT_CONFIG_GLOBAL-unset}"
EOF
      chmod 755 "$PAYLOAD/core-rules/hooks/inject-primer-index.sh"
      ;;
    *)
      printf 'unknown release fixture: %s\n' "$fixture" >&2
      return 2
      ;;
  esac
  chmod 755 "$PAYLOAD/scripts/trellis"
  printf 'immutable fixture %s\n' "$version" > "$PAYLOAD/README"
  printf 'safe symlink target %s\n' "$version" > "$PAYLOAD/linked target"
  ln -s "linked target" "$PAYLOAD/linked fixture"
  : > "$manifest"
  while IFS= read -r file; do
    relative="${file#$PAYLOAD/}"
    if [ -L "$file" ]; then
      mode=120000
      target="$(readlink "$file")"
      oid="$(printf '%s' "$target" | git hash-object --stdin)"
    elif [ -x "$file" ]; then
      mode=100755
      oid="$(git hash-object "$file")"
    else
      mode=100644
      oid="$(git hash-object "$file")"
    fi
    jq -cn --arg path "$relative" --arg mode "$mode" --arg oid "$oid" '{path: $path, mode: $mode, oid: $oid}' >> "$manifest"
  done < <(find "$PAYLOAD" \( -type f -o -type l \) -print | LC_ALL=C sort)
  jq -n --arg version "$version" --slurpfile tree "$manifest" '
    {
      schema_version: 1,
      version: $version,
      tag: ("v" + $version),
      commit: "0000000000000000000000000000000000000000",
      remote: "fixture://release",
      tree: $tree
    }
  ' > "$RELEASE_DIR/release.json"
  find "$PAYLOAD" -type f -exec chmod a-w {} \;
  find "$PAYLOAD" -type d -exec chmod a-w {} \;
  chmod a-w "$RELEASE_DIR/release.json" "$RELEASE_DIR"
}

run_launcher() {
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" "$LAUNCHER" "$@"
}

# The launcher removes its sealed execution snapshot on the way out. `find`
# prints nothing at all when its own start point does not exist — it writes to
# stderr and returns non-zero — so a bare `[ -z "$(find …)" ]` also passes when
# the release store was never created, which is not the claim. Prove the store
# is there first, then fold stderr into the captured text so a find failure is
# non-empty output rather than a silent pass.
assert_no_execution_snapshot() {
  [ -d "$TRELLIS_HOME/releases" ] ||
    { echo "release store is absent, so the emptiness claim is vacuous: $TRELLIS_HOME/releases"; false; }
  local leftover
  leftover="$(find "$TRELLIS_HOME/releases" -maxdepth 1 -name '.tmp.*.exec.*' -print 2>&1)"
  [ -z "$leftover" ] || { echo "execution snapshot survived: $leftover"; false; }
}

make_poisoned_project_runtime() {
  local hook
  PROJECT="$SANDBOX/projects/project with spaces"
  PROJECT_RUNTIME_MARKER="$SANDBOX/project-runtime-ran"
  mkdir -p \
    "$PROJECT/.trellis/runtime/core-rules/hooks" \
    "$PROJECT/.trellis/runtime/core-rules/codex/hooks"
  for hook in \
    "$PROJECT/.trellis/runtime/core-rules/hooks/session-context.sh" \
    "$PROJECT/.trellis/runtime/core-rules/codex/hooks/session-context.sh"; do
    cat > "$hook" <<EOF
#!/usr/bin/env bash
: > "$PROJECT_RUNTIME_MARKER"
exit 97
EOF
    chmod 755 "$hook"
  done
  printf '{"autonomy_default":1}\n' > "$PROJECT/.trellis/runtime/trellis.config.json"
  printf 'verified payload project context\n' > "$PROJECT/context-log.md"
}

run_session_context() {
  local harness="$1" project_root="$2"
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    CLAUDE_PROJECT_DIR="$SANDBOX/incorrect claude project" \
    CODEX_PROJECT_DIR="$SANDBOX/incorrect codex project" \
    PROJECT_RUNTIME_MARKER="$PROJECT_RUNTIME_MARKER" \
    bash -c 'printf "%s\n" "{\"source\":\"startup\"}" | "$1" hook session-context "$2" "$3"' \
    _ "$LAUNCHER" "$harness" "$project_root"
}

make_dispatch_stub() {
  local name="$1"
  cat > "$DISPATCH_ROOT/$name" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" > "$TRELLIS_TEST_ROUTE"
for argument in "$@"; do printf '<%s>\n' "$argument" >> "$TRELLIS_TEST_ROUTE"; done
exit "${TRELLIS_TEST_STATUS:-0}"
EOF
  chmod 755 "$DISPATCH_ROOT/$name"
}

prepare_dispatcher_fixture() {
  mkdir -p "$DISPATCH_ROOT"
  cp "$DISPATCHER_TEMPLATE" "$DISPATCH_ROOT/trellis"
  chmod 755 "$DISPATCH_ROOT/trellis"
  for script in configure.sh release.sh registry.sh show-config.sh attach-project.sh doctor.sh conformance-check.sh install-disk-janitor-launchd.sh materialize-scheduled-task.sh sync-to-template.sh worktree.sh; do
    make_dispatch_stub "$script"
  done
}
@test "copied launcher runs only active immutable payload with exact argv and status" {
  local expected
  make_release 1.2.3


  run_launcher attach --fleet "work fleet" ""
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  expected="$(printf '%s\n' 4 '<attach>' '<--fleet>' '<work fleet>' '<>')"
  [ "$(cat "$ARGV_LOG")" = "$expected" ]
  [ ! -e "$SOURCE_POISON_MARKER" ]
}

@test "direct launcher bootstrap ignores BASH startup and exported function payloads" {
  local startup marker
  make_release 1.2.3
  startup="$SANDBOX/hostile-startup"
  marker="$SANDBOX/hostile-startup-ran"
  cat > "$startup" <<EOF
/usr/bin/touch "$marker"
EOF

  run /usr/bin/env -i \
    "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "HOSTILE_MARKER=$marker" \
    /bin/bash --noprofile --norc -c '
      umask() {
        /usr/bin/touch "$HOSTILE_MARKER"
        builtin umask "$@"
      }
      export -f umask
      BASH_ENV="$2"
      ENV="$2"
      export BASH_ENV ENV
      exec "$1" doctor
    ' trellis-launcher-hostile "$LAUNCHER" "$startup"
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ ! -e "$marker" ]
}

@test "session-context route runs verified data hooks and never poisoned project runtime" {
  local harness
  make_release 1.2.3 session-context
  make_poisoned_project_runtime

  for harness in claude codex; do
    rm -f "$PROJECT_RUNTIME_MARKER"
    run_session_context "$harness" "$PROJECT"

    [ "$status" -eq 0 ] || { echo "$output"; false; }
    [[ "$output" == *"verified payload project context"* ]] || { echo "$output"; false; }
    [[ "$output" == *"Level: L4"* ]] || { echo "$output"; false; }
    [ ! -e "$PROJECT_RUNTIME_MARKER" ]
  done
}


@test "SessionStart routes reject malformed paths and report missing absolute projects as unavailable" {
  make_release 1.2.3 session-context
  mkdir -p "$SANDBOX/projects/valid"

  run /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    "$LAUNCHER" hook session-context claude "$SANDBOX/projects/valid"
  [ "$status" -eq 2 ]
  [[ "$output" == *'TRELLIS_HOME is required for SessionStart hook routes'* ]] || { echo "$output"; false; }

  run_session_context claude relative-project
  [ "$status" -eq 2 ]
  [[ "$output" == *'PROJECT_ROOT must be an absolute canonical directory'* ]] || { echo "$output"; false; }

  run_session_context codex "$SANDBOX/projects/missing"
  [ "$status" -eq 5 ]
  [[ "$output" == *'PROJECT_ROOT is unavailable'* ]] || { echo "$output"; false; }
}

@test "SessionStart runs a non-context hook from the verified payload without project runtime" {
  make_release 1.2.3 session-primer
  mkdir -p "$SANDBOX/projects/valid"

  run_launcher hook inject-primer-index claude "$SANDBOX/projects/valid"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # The executed payload is the sealed private snapshot of the configured
  # release, never the installed release directory itself.
  [[ "$output" == *"trusted-primer:$SANDBOX/projects/valid:$TRELLIS_HOME/releases/.tmp.1.2.3.exec."*"/payload "* ]] ||
    { echo "$output"; false; }
  [[ "$output" != *"trusted-primer:$SANDBOX/projects/valid:$PAYLOAD "* ]] ||
    { echo "$output"; false; }
  # The snapshot is removed again on the way out.
  assert_no_execution_snapshot
}

@test "SessionStart drops inherited Git execution controls before the verified hook" {
  make_release 1.2.3 session-primer
  mkdir -p "$SANDBOX/projects/valid"

  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    GIT_DIR="$SANDBOX/poisoned-git" GIT_WORK_TREE="$SANDBOX/poisoned-worktree" \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=true \
    "$LAUNCHER" hook inject-primer-index claude "$SANDBOX/projects/valid"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *'git-dir=unset git-work-tree=unset fsmonitor=false hooks=/dev/null no-system=1 global=/dev/null'* ]] || { echo "$output"; false; }
}
@test "SessionStart templates route every start hook through the clean stable launcher" {
  local expected
  for name in session-context post-compact-context inject-primer-index skill-size-preflight; do
    run jq -r --arg name "$name" '.hooks.SessionStart[0].hooks[].command | select(contains("hook " + $name + " claude "))' \
      "$REPO_ROOT/core-rules/templates/claude-settings.local.json"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    expected="/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook $name claude \"\$CLAUDE_PROJECT_DIR\""
    [ "$output" = "$expected" ]
  done

  for name in session-context post-compact-context inject-primer-index; do
    run jq -r --arg name "$name" '.hooks.SessionStart[0].hooks[].command | select(contains("hook " + $name + " codex "))' \
      "$REPO_ROOT/core-rules/templates/codex-hooks.local.json"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    expected="/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook $name codex \"\$CODEX_PROJECT_DIR\""
    [ "$output" = "$expected" ]
  done
}

@test "clean home allows only fixed launcher initial active release install" {
  local remote="$SANDBOX/bootstrap-release-remote"
  make_bootstrap_release_remote 1.2.3 "$remote"
  write_config 1.2.3 "$remote"

  run_launcher doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"only 'trellis release install 1.2.3 [--remote URL]' is available"* ]] || { echo "$output"; false; }

  run_launcher release install 1.2.3 --remote "$remote"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -d "$TRELLIS_HOME/releases/1.2.3/payload" ]
  [ ! -e "$SOURCE_POISON_MARKER" ]
}

@test "launcher has no latest fallback when active release is absent" {
  make_release 9.9.9

  run_launcher doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"only 'trellis release install 1.2.3 [--remote URL]' is available"* ]] || { echo "$output"; false; }
  [ ! -e "$ARGV_LOG" ]
}

@test "launcher refuses corrupt missing symlinked and writable release state" {
  make_release 1.2.3
  chmod 755 "$TRELLIS_HOME"
  run_launcher doctor
  [ "$status" -eq 4 ]
  [[ "$output" == *"Trellis home is missing, not private, or not a real directory"* ]] || { echo "$output"; false; }
  chmod 700 "$TRELLIS_HOME"

  chmod u+w "$RELEASE_DIR/release.json"
  printf '{invalid}\n' > "$RELEASE_DIR/release.json"
  chmod a-w "$RELEASE_DIR/release.json"
  run_launcher doctor
  [ "$status" -eq 4 ]
  [[ "$output" == *"release record is missing, writable, or invalid"* ]] || { echo "$output"; false; }

  # A release store with no configured release is not corrupt state: it is the
  # pre-active condition, and the launcher's only pre-active route reports it.
  find "$TRELLIS_HOME/releases/1.2.3" -depth -type d -exec chmod u+w {} \;
  rm -rf "$TRELLIS_HOME/releases/1.2.3"
  run_launcher doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"only 'trellis release install 1.2.3 [--remote URL]' is available"* ]] ||
    { echo "$output"; false; }

  make_release 1.2.3
  chmod u+w "$RELEASE_DIR"
  mv "$RELEASE_DIR" "$RELEASE_DIR.real"
  ln -s "$RELEASE_DIR.real" "$RELEASE_DIR"
  run_launcher doctor
  [ "$status" -eq 4 ]
  [[ "$output" == *"configured release is not a real directory"* ]] || { echo "$output"; false; }

  rm "$RELEASE_DIR"
  mv "$RELEASE_DIR.real" "$RELEASE_DIR"
  chmod u+w "$PAYLOAD/scripts/trellis"
  run_launcher doctor
  [ "$status" -eq 4 ]
  [[ "$output" == *"configured release directory is writable"* ]] || { echo "$output"; false; }
}

@test "launcher runs upgrade as a verified in-memory bundle without a release pathname" {
  make_release 1.2.3 command-bundle

  run_launcher upgrade
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  # The upgrade body only reaches argument validation when it ran from the
  # bundle: the sealed-snapshot pathname route rejects the snapshot payload as
  # direct source execution instead.
  [[ "$output" == *'VERSION is required'* ]] || { echo "$output"; false; }
  [[ "$output" == *'trellis upgrade VERSION'* ]] || { echo "$output"; false; }
  [[ "$output" != *'direct source execution is unsupported'* ]] || { echo "$output"; false; }
  [ ! -e "$SOURCE_POISON_MARKER" ]

  run_launcher upgrade 9.9.9 --all --all
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'upgrade accepts one selector'* ]] || { echo "$output"; false; }
}

@test "launcher upgrade composes the real release and upgrade bodies against a fixture home" {
  local remote="$SANDBOX/upgrade-release-remote"
  make_release 1.2.3 command-bundle
  make_bootstrap_release_remote 1.2.4 "$remote"

  # No stub on either half: the bundle carries the payload's real release body
  # as a preloaded command surface and its real upgrade body on top of it.
  run_launcher upgrade 1.2.4 --remote "$remote" --all

  # install and verify are observed by their effects on the release store.
  [ -d "$TRELLIS_HOME/releases/1.2.4/payload" ] || { echo "$output"; false; }
  [ -f "$TRELLIS_HOME/releases/1.2.4/release.json" ]
  [ ! -w "$TRELLIS_HOME/releases/1.2.4/release.json" ]
  [[ "$output" == *"$TRELLIS_HOME/releases/1.2.4"* ]] || { echo "$output"; false; }
  # verify is silent on success and fatal on failure, so the adoption line
  # below is also the proof that verification of the new payload passed.
  [[ "$output" == *"no registered worktrees matched the requested adoption selector"* ]] ||
    { echo "$output"; false; }
  # The fixture home has no registered worktrees, so the real adoption step
  # ends unavailable rather than silently succeeding.
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$SOURCE_POISON_MARKER" ]
  assert_no_execution_snapshot
}

@test "launcher refuses an installed payload whose upgrade command predates bundle execution" {
  make_release 1.2.3 command-bundle-pre-bundle-upgrade

  run_launcher upgrade 1.2.4 --all
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'installed release 1.2.3 cannot run '"'"'trellis upgrade'"'"' as a verified in-memory bundle'* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *'predates the verified command-bundle attestation'* ]] || { echo "$output"; false; }
  [[ "$output" == *'trellis release install VERSION [--remote URL]'* ]] || { echo "$output"; false; }
  [[ "$output" != *'legacy upgrade body ran'* ]] || { echo "$output"; false; }
  [[ "$output" != *'legacy upgrade wrapper ran'* ]] || { echo "$output"; false; }

  write_config 1.2.5
  make_release 1.2.5 command-bundle-unmarked-upgrade

  run_launcher upgrade 1.2.6 --all
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  [[ "$output" == *'installed release 1.2.5 cannot run '"'"'trellis upgrade'"'"' as a verified in-memory bundle'* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *'carries no command-body marker'* ]] || { echo "$output"; false; }
  [[ "$output" != *'legacy upgrade wrapper ran'* ]] || { echo "$output"; false; }
}

@test "launcher upgrade refuses a payload upgrade source that drifts from its record" {
  make_release 1.2.3 command-bundle

  chmod u+w "$PAYLOAD/scripts" "$PAYLOAD/scripts/upgrade.sh"
  # Exactly one byte, rewritten in place: same size, same mode, different bytes.
  printf 'x' | dd of="$PAYLOAD/scripts/upgrade.sh" bs=1 seek=3 conv=notrunc status=none
  chmod a-w "$PAYLOAD/scripts/upgrade.sh" "$PAYLOAD/scripts"

  run_launcher upgrade 1.2.4 --all
  [ "$status" -eq 4 ] || { echo "$output"; false; }
  # The refusal comes from the launcher's own content verification, which runs
  # before any snapshot is taken and before any bundle is emitted, and it names
  # the drifted path. (The bundle emitter re-checks the same path against the
  # pinned record when it buffers the snapshot; that second check only ever
  # fires on drift introduced after this one passed, so it is unreachable from
  # a test that mutates the payload up front.)
  [[ "$output" == *'configured release content has changed: scripts/upgrade.sh'* ]] ||
    { echo "$output"; false; }
  # Nothing downstream ran: no upgrade body reached argument validation.
  [[ "$output" != *'VERSION is required'* ]] || { echo "$output"; false; }
  [ ! -e "$SOURCE_POISON_MARKER" ]
  assert_no_execution_snapshot
}

@test "dispatcher passes grouped routes and preserves legacy route argv and status" {
  local expected command
  prepare_dispatcher_fixture

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" configure --source "/fixture source"
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' configure.sh '<configure>' '<--source>' '</fixture source>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" fleet add work
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' configure.sh '<fleet>' '<add>' '<work>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]

  for command in release registry; do
    run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" "$command" list
    [ "$status" -eq 3 ]
    expected="$(printf '%s\n' "$command.sh" '<list>')"
    [ "$(cat "$ROUTE_LOG")" = "$expected" ]
  done

  for command in attach detach recover relink; do
    run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" "$command" --probe "$command"
    [ "$status" -eq 3 ]
    expected="$(printf '%s\n' attach-project.sh "<$command>" '<--probe>' "<$command>")"
    [ "$(cat "$ROUTE_LOG")" = "$expected" ]
  done

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" doctor --fix
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' doctor.sh '<--fix>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" mirror --dry-run
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' sync-to-template.sh '<--dry-run>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" conformance --quiet
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' conformance-check.sh '<--quiet>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 "$DISPATCH_ROOT/trellis" launchd --with-apply
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' install-disk-janitor-launchd.sh '<--with-apply>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]
}

@test "dispatcher routes show-config with its home and fleet selection argv" {
  local expected
  prepare_dispatcher_fixture

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 \
    "$DISPATCH_ROOT/trellis" show-config --home "$TRELLIS_HOME" --fleet "work fleet"
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' show-config.sh '<--home>' "<$TRELLIS_HOME>" '<--fleet>' '<work fleet>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]
}

@test "dispatcher refuses the upgrade pathname route and names the launcher route" {
  prepare_dispatcher_fixture
  make_dispatch_stub upgrade.sh

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 \
    "$DISPATCH_ROOT/trellis" upgrade 1.2.4 --all
  [ "$status" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == *'upgrade runs only through the installed stable launcher'* ]] ||
    { echo "$output"; false; }
  [[ "$output" == *'trellis upgrade VERSION'* ]] || { echo "$output"; false; }
  # No upgrade pathname was opened: the stub would have written the route log.
  [ ! -e "$ROUTE_LOG" ] || { cat "$ROUTE_LOG"; false; }
}

@test "dispatcher preserves materialize argv without injecting a duplicate action" {
  prepare_dispatcher_fixture

  run env TRELLIS_TEST_ROUTE="$ROUTE_LOG" TRELLIS_TEST_STATUS=3 \
    "$DISPATCH_ROOT/trellis" task materialize --fleet work nightly
  [ "$status" -eq 3 ]
  expected="$(printf '%s\n' materialize-scheduled-task.sh '<materialize>' '<--fleet>' '<work>' '<nightly>')"
  [ "$(cat "$ROUTE_LOG")" = "$expected" ]
}

@test "dispatcher prints help and rejects unknown commands" {
  prepare_dispatcher_fixture

  run "$DISPATCH_ROOT/trellis" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: trellis <command> [args...]"* ]] || { echo "$output"; false; }
  [[ "$output" == *"configure"* ]] || { echo "$output"; false; }
  [[ "$output" == *"relink"* ]] || { echo "$output"; false; }
  [[ "$output" == *"conformance"* ]] || { echo "$output"; false; }
  [[ "$output" == *"launchd"* ]] || { echo "$output"; false; }
  [[ "$output" == *"show-config"* ]] || { echo "$output"; false; }
  [[ "$output" == *"upgrade"* ]] || { echo "$output"; false; }

  run "$DISPATCH_ROOT/trellis" unknown-command
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: trellis <command> [args...]"* ]] || { echo "$output"; false; }
}
