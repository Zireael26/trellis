#!/usr/bin/env bats
# Immutable-launcher and dispatcher contracts.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LAUNCHER_TEMPLATE="$REPO_ROOT/scripts/trellis-launcher.sh"
DISPATCHER_TEMPLATE="$REPO_ROOT/scripts/trellis"

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/trellis-launcher.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  export HOME="$SANDBOX/home"
  export TRELLIS_HOME="$SANDBOX/trellis-home"
  SOCKET_FIXTURE=""
  SOURCE_POISON="$SANDBOX/source-poison"
  SOURCE_POISON_MARKER="$SANDBOX/source-poison-ran"
  ARGV_LOG="$HOME/trellis-launcher-argv.log"
  ATTACH_PATH_LOG="$HOME/trellis-launcher-attach-path.log"
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
  if [ -n "${SOCKET_FIXTURE:-}" ] && [ -d "$SOCKET_FIXTURE" ]; then
    rm -rf "$SOCKET_FIXTURE"
  fi
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] || return 0
  find "$SANDBOX" -depth -type d -exec chmod u+w {} + 2>/dev/null || true
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
  local version="$1" fixture="${2:-dispatcher}" manifest
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
printf '%s\n' "${TRELLIS_ATTACH_CALLER_PATH-__UNSET__}" > "$HOME/trellis-launcher-attach-path.log"
exit 3
EOF
      ;;
    stdin)
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      mkdir -p "$PAYLOAD/core-rules/hooks"
      cat > "$PAYLOAD/scripts/doctor.sh" <<'EOF'
#!/bin/bash
IFS= read -r line
printf '%s\n' "$line"
exit 3
EOF
      cp "$PAYLOAD/scripts/doctor.sh" "$PAYLOAD/core-rules/hooks/inject-primer-index.sh"
      chmod 755 "$PAYLOAD/scripts/doctor.sh" "$PAYLOAD/core-rules/hooks/inject-primer-index.sh"
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
    scratch-probe)
      # A payload child that reports the command scratch it was handed and, on
      # request, mutates it. The mode file is read at run time so one fixture
      # covers every lifecycle case without a second sealed release.
      cat > "$PAYLOAD/scripts/trellis" <<EOF
#!/bin/bash
mode="\$(cat "$SANDBOX/scratch-probe-mode" 2>/dev/null || printf record)"
printf '%s\n' "\${TMPDIR-__UNSET__}" > "$SANDBOX/scratch-tmpdir.log"
if [ -n "\${TMPDIR-}" ] && [ -d "\$TMPDIR" ]; then
  LC_ALL=C /bin/ls -ld "\$TMPDIR" | /usr/bin/awk '{print substr(\$1, 1, 10)}' > "$SANDBOX/scratch-mode.log"
fi
case "\$mode" in
  record) ;;
  write)
    printf 'command temp file\n' > "\$TMPDIR/probe-file"
    /usr/bin/mktemp "\${TMPDIR:-/tmp}/probe.XXXXXX" > "$SANDBOX/scratch-mktemp.log"
    ;;
  child-symlink)
    /bin/ln -s "$SANDBOX/neighbour-target" "\$TMPDIR/link"
    ;;
  replace-directory)
    /bin/rmdir "\$TMPDIR" && /bin/mkdir "\$TMPDIR" && printf 'replacement\n' > "\$TMPDIR/replacement"
    ;;
  replace-parent)
    printf 'original scratch bytes\n' > "\$TMPDIR/original"
    /bin/mv "\$TRELLIS_HOME/state/scratch" "\$TRELLIS_HOME/state/scratch-retained" || exit 91
    /bin/mkdir -m 700 "\$TRELLIS_HOME/state/scratch" "\$TMPDIR" || exit 92
    printf 'replacement scratch bytes\n' > "\$TMPDIR/replacement"
    printf 'replacement neighbour bytes\n' > "\$TRELLIS_HOME/state/scratch/neighbour"
    ;;
  replace-state-alias)
    printf 'original scratch bytes\n' > "\$TMPDIR/original"
    printf 'state sentinel bytes\n' > "\$TRELLIS_HOME/state/sentinel"
    printf 'neighbour bytes\n' > "\$TRELLIS_HOME/state/scratch/neighbour"
    /bin/mv "\$TRELLIS_HOME/state" "\$TRELLIS_HOME/state.saved" || exit 91
    /bin/ln -s state.saved "\$TRELLIS_HOME/state" || exit 92
    ;;
  replace-symlink)
    /bin/rmdir "\$TMPDIR" && /bin/ln -s "$SANDBOX/neighbour-target" "\$TMPDIR"
    ;;
  term)
    kill -TERM "\$PPID"
    ;;
esac
exit "\$(cat "$SANDBOX/scratch-probe-status" 2>/dev/null || printf 0)"
EOF
      ;;
    command-bundle-scratch)
      # The real release body preloaded under a fixture upgrade body, so the
      # bundle child reports both the TMPDIR the launcher handed it and the
      # value release.sh admitted from it.
      mkdir -p "$PAYLOAD/core-rules"
      cp "$DISPATCHER_TEMPLATE" "$PAYLOAD/scripts/trellis"
      cp "$REPO_ROOT/scripts/release.sh" "$PAYLOAD/scripts/release.sh"
      cp -R "$REPO_ROOT/scripts/lib" "$PAYLOAD/scripts/lib"
      cat > "$PAYLOAD/scripts/upgrade.sh" <<'EOF'
#!/bin/sh
printf 'scratch upgrade wrapper ran\n'
exit 5
# -- trellis upgrade body --
set -u
trellis_command_bundle_is_verified upgrade "${TRELLIS_VERIFIED_COMMAND_BUNDLE_TOKEN:-}" || exit 6
printf 'bundle-tmpdir=%s\n' "${TMPDIR-__UNSET__}"
printf 'bundle-admitted=%s\n' "${RELEASE_ADMITTED_TMPDIR-__UNSET__}"
release_git -c 'alias.trellis-scratch-probe=!printf "git-tmpdir=%s\n" "$TMPDIR"' trellis-scratch-probe || exit 7
exit 0
EOF
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
  python3 "$REPO_ROOT/scripts/tests/helpers/fixture-tree-manifest.py" "$PAYLOAD" > "$manifest"
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
  find "$PAYLOAD" -type f -exec chmod a-w {} +
  find "$PAYLOAD" -type d -exec chmod a-w {} +
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

# Same shape as assert_no_execution_snapshot: prove the root exists first, so an
# absent scratch root cannot pass as an empty one.
assert_no_command_scratch() {
  [ -d "$TRELLIS_HOME/state/scratch" ] ||
    { echo "command scratch root is absent, so the emptiness claim is vacuous: $TRELLIS_HOME/state/scratch"; false; }
  local leftover
  leftover="$(find "$TRELLIS_HOME/state/scratch" -maxdepth 1 -name '.cmd.*' -print 2>&1)"
  [ -z "$leftover" ] || { echo "command scratch survived: $leftover"; false; }
}

run_launcher_with_tmpdir() {
  local candidate="$1"
  shift
  run env HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" TMPDIR="$candidate" "$LAUNCHER" "$@"
}

# release.sh reached by pathname, with the entry gate satisfied exactly as the
# installed payload satisfies it, and CANDIDATE offered as the caller's TMPDIR.
run_release_pathname() {
  local candidate="$1"
  shift
  run env -i "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" \
    "TRELLIS_VERIFIED_PAYLOAD=$PAYLOAD" "TRELLIS_VERIFIED_RELEASE_VERSION=1.2.3" \
    "TMPDIR=$candidate" "PATH=$PATH" \
    /bin/bash "$PAYLOAD/scripts/release.sh" "$@"
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

# The Codex SessionStart command exactly as it is written into a project's
# settings, with the render placeholders resolved. Reading it back out of the
# template is the point: a test that retypes the fallback chain proves only that
# two copies of a string agree, which is all the string assertions elsewhere in
# this file can prove.
render_codex_session_start_command() {
  jq -r '.hooks.SessionStart[0].hooks[].command | select(contains("hook session-context codex "))' \
    "$REPO_ROOT/core-rules/templates/codex-hooks.local.json" |
    sed -e "s#__TRELLIS_USER_HOME__#$HOME#g" \
      -e "s#__TRELLIS_HOME__#$TRELLIS_HOME#g" \
      -e "s#__TRELLIS_LAUNCHER__#$LAUNCHER#g"
}

# Run that command for real from directory $1, with the environment variables
# named in $2.. removed. Everything after the first argument is unset.
run_rendered_codex_session_start() {
  local cwd="$1" command
  shift
  command="$(render_codex_session_start_command)"
  run env -i "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" \
    "PATH=/usr/bin:/bin:/usr/sbin:/sbin" "${@}" \
    /bin/bash --noprofile --norc -c \
    "cd \"\$1\" || exit 1; printf '%s\n' '{\"source\":\"startup\"}' | $command" \
    _ "$cwd"
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
make_agent_socket_fixture() {
  # The isolated runner binds and closes this inert socket before fencing
  # network access. Keep aliases and negative controls in our own subtree.
  if [ -n "${TRELLIS_TEST_SOCKET_PATH:-}" ]; then
    [ -n "${TRELLIS_TEST_SOCKET_METADATA:-}" ] || return 1
    SOCKET_CANONICAL="$TRELLIS_TEST_SOCKET_PATH"
    [ -S "$SOCKET_CANONICAL" ] && [ ! -L "$SOCKET_CANONICAL" ] || return 1
    [ "${SOCKET_CANONICAL##*/}" = s ] || return 1
    SOCKET_FIXTURE="$BATS_TEST_TMPDIR/socket-fixture"
    SOCKET_REAL="$SOCKET_FIXTURE/r"
    SOCKET_ALIAS="$SOCKET_FIXTURE/a"
    mkdir -p "$SOCKET_REAL"
    ln -s "${SOCKET_CANONICAL%/*}" "$SOCKET_ALIAS"
    return
  fi
  # A real AF_UNIX socket: the resolver requires -S, so no plain file can stand
  # in.
  # Built inside the runner's own private temp root, resolved physically so the
  # fixture's path contributes no symlink of its own. A literal /tmp spelling
  # put it outside that boundary, which an isolated runner refuses outright, and
  # /private/tmp does not exist on Linux, which is where CI runs this.
  #
  # sun_path caps a bound socket at 104 bytes and the root is already deep:
  # scripts/run-tests.sh hands each shard a `trellis-test-git.XXXXXX` directory
  # under the ambient temp dir, which is 80 bytes on a stock macOS $TMPDIR. The
  # leaves are therefore spelled as tersely as the limit demands and named
  # through variables, so the cases below still read as real-versus-alias.
  local tmp_root
  tmp_root="$(CDPATH='' cd "${TMPDIR:-/tmp}" && pwd -P)"
  SOCKET_FIXTURE="$(mktemp -d "$tmp_root/s.XXXXXX")"
  SOCKET_REAL="$SOCKET_FIXTURE/r"
  SOCKET_ALIAS="$SOCKET_FIXTURE/a"
  SOCKET_CANONICAL="$SOCKET_REAL/s"
  mkdir -p "$SOCKET_REAL"
  /usr/bin/perl -MSocket -e '
    socket(my $sock, PF_UNIX, SOCK_STREAM, 0) or die "socket: $!";
    bind($sock, sockaddr_un($ARGV[0])) or die "bind: $!";
  ' "$SOCKET_CANONICAL"
  # The stock macOS spelling reaches the launchd socket through /var, a symlink
  # to /private/var, so an alias directory reproduces the real-world path.
  ln -s "$SOCKET_REAL" "$SOCKET_ALIAS"
}

resolve_ssh_auth_sock() {
  local resolver
  resolver="$(
    awk '/^launcher_absolute_path_is_clean\(\) \{/,/^\}/' "$LAUNCHER_TEMPLATE"
    awk '/^launcher_verified_ssh_auth_sock\(\) \{/,/^\}/' "$LAUNCHER_TEMPLATE"
  )"
  SSH_AUTH_SOCK="$1" /bin/bash --noprofile --norc -c "set -u
$resolver
launcher_verified_ssh_auth_sock"
}

@test "verified SSH_AUTH_SOCK resolves a socket reached through a symlinked directory" {
  local canonical
  make_agent_socket_fixture
  canonical="$SOCKET_CANONICAL"

  run resolve_ssh_auth_sock "$SOCKET_ALIAS/s"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$canonical" ] || { echo "$output"; false; }

  run resolve_ssh_auth_sock "$canonical"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$output" = "$canonical" ] || { echo "$output"; false; }
}

@test "verified SSH_AUTH_SOCK refuses a symlinked socket, a non-socket, and an unclean path" {
  make_agent_socket_fixture
  ln -s "$SOCKET_CANONICAL" "$SOCKET_REAL/link.sock"
  : > "$SOCKET_REAL/plain"

  run resolve_ssh_auth_sock "$SOCKET_REAL/link.sock"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }

  run resolve_ssh_auth_sock "$SOCKET_REAL/plain"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }

  run resolve_ssh_auth_sock "$SOCKET_REAL/../r/s"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }

  run resolve_ssh_auth_sock "$SOCKET_REAL/missing.sock"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -z "$output" ] || { echo "$output"; false; }
}

@test "copied launcher runs only active immutable payload with exact argv and status" {
  local expected expected_path="$PATH"
  make_release 1.2.3


  run_launcher attach --fleet "work fleet" ""
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  expected="$(printf '%s\n' 4 '<attach>' '<--fleet>' '<work fleet>' '<>')"
  [ "$(cat "$ARGV_LOG")" = "$expected" ]
  [ ! -e "$SOURCE_POISON_MARKER" ]
  [ "$(cat "$ATTACH_PATH_LOG")" = "$expected_path" ]
  run_launcher doctor
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$(cat "$ATTACH_PATH_LOG")" = __UNSET__ ]
  # The dispatcher intentionally exits 3 after the launcher has created and
  # handed off its sealed snapshot. Cleanup is required on this error path too,
  # not only after a successful payload exit.
  assert_no_execution_snapshot
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

# Extract the actual clean -c program, not a hand-written bootstrap facsimile.
launcher_clean_prologue() {
  awk '
    /^  \/bin\/bash --noprofile --norc -c / { body = 1; next }
    /^\047 trellis-launcher-bootstrap / { exit }
    body { print }
  ' "$LAUNCHER_TEMPLATE"
}

@test "launcher bootstrap preserves ordinary and hook stdin" {
  make_release 1.2.3 stdin
  local route
  for route in doctor hook; do
    run /bin/bash -c '
      printf "%s\n" "caller stdin: spaces and backslash \\" |
        "$1" "$2" "${@:3}"
    ' _ "$LAUNCHER" "$route" inject-primer-index claude "$SANDBOX/projects"
    [ "$status" -eq 3 ] || { echo "$output"; false; }
    [ "$output" = 'caller stdin: spaces and backslash \' ]
    assert_no_execution_snapshot
  done
}

@test "launcher bootstrap rejects missing marker and empty body with status 5" {
  local variant
  for variant in missing empty; do
    awk '/^# -- trellis launcher body --$/ { exit } { print }' "$LAUNCHER_TEMPLATE" > "$LAUNCHER"
    if [ "$variant" = empty ]; then
      printf '%s\n' '# -- trellis launcher body --' >> "$LAUNCHER"
    fi
    run_launcher doctor
    [ "$status" -eq 5 ] || { echo "$output"; false; }
    [[ "$output" == *'trellis: could not prepare trusted launcher bootstrap'* ]]
    [ ! -e "$ARGV_LOG" ]
  done
}

@test "launcher bootstrap source read failure is checked before evaluation" {
  local prologue
  prologue="$(launcher_clean_prologue)"
  [ -n "$prologue" ]
  run /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /bin/bash --noprofile --norc -c "$prologue" trellis-launcher-bootstrap "$SANDBOX/missing-source" doctor
  [ "$status" -eq 5 ] || { echo "$output"; false; }
  [[ "$output" == *'awk:'* ]]
  [[ "$output" == *'trellis: could not prepare trusted launcher bootstrap'* ]]
  [ ! -e "$ARGV_LOG" ]
}

@test "launcher bootstrap executes a valid body larger than ARG_MAX without argv transport" {
  make_release 1.2.3
  python3 - "$LAUNCHER" <<'PY'
import os
from pathlib import Path
import sys
path = Path(sys.argv[1])
with path.open("a") as stream:
    stream.write("\n# padding\n" * (os.sysconf("SC_ARG_MAX") // 10 + 1))
PY
  run_launcher attach --fleet "work fleet" ""
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [ "$(cat "$ARGV_LOG")" = "$(printf '%s\n' 4 '<attach>' '<--fleet>' '<work fleet>' '<>')" ]
  assert_no_execution_snapshot
}

@test "launcher bootstrap final eval preserves options umask EXIT trap and body status" {
  local prologue
  prologue="$(launcher_clean_prologue)"
  [ "${prologue##*$'\n'}" = 'eval "$launcher_body"' ]
  cat > "$SANDBOX/probe-source" <<'EOF'
# -- trellis launcher body --
case "$-" in *u*) ;; *) exit 91 ;; esac
case "$-" in *e*|*x*|*v*) exit 92 ;; esac
[ "$(umask)" = 0077 ] || exit 93
shopt -q nullglob && exit 94
[ "$(set -o | awk '$1 == "pipefail" { print $2 }')" = off ] || exit 95
trap 'printf "exit-status=%s\n" "$?"' EXIT
false
printf 'argc=%s first=<%s> second=<%s>\n' "$#" "$1" "$2"
(exit 42)
EOF
  run /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    /bin/bash --noprofile --norc -c "$prologue" trellis-launcher-bootstrap "$SANDBOX/probe-source" 'with space' ''
  [ "$status" -eq 42 ] || { echo "$output"; false; }
  [ "$output" = "$(printf '%s\n' 'argc=2 first=<with space> second=<>' 'exit-status=42')" ]
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


# Every other assertion about the fallback chain is a string match on the
# template or the rendered JSON, so all of them would still pass if the chain
# resolved nothing at runtime. These execute it. The fixture project's path
# contains a space, which is where an unquoted expansion would come apart.
@test "the Codex SessionStart fallback chain resolves a project dir at runtime" {
  make_release 1.2.3 session-context
  make_poisoned_project_runtime

  # 1. CODEX_PROJECT_DIR wins when Codex sets it.
  rm -f "$PROJECT_RUNTIME_MARKER"
  run_rendered_codex_session_start "$SANDBOX" \
    "CODEX_PROJECT_DIR=$PROJECT" "CLAUDE_PROJECT_DIR=$SANDBOX/projects/wrong"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"verified payload project context"* ]] || { echo "$output"; false; }

  # 2. CLAUDE_PROJECT_DIR is the next leg when Codex does not set its own.
  rm -f "$PROJECT_RUNTIME_MARKER"
  run_rendered_codex_session_start "$SANDBOX" "CLAUDE_PROJECT_DIR=$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"verified payload project context"* ]] || { echo "$output"; false; }

  # 3. With neither set, `$PWD` is the last resort. Before the chain landed this
  #    passed an empty string and the hook exited 2 on a non-absolute path.
  rm -f "$PROJECT_RUNTIME_MARKER"
  run_rendered_codex_session_start "$PROJECT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"verified payload project context"* ]] || { echo "$output"; false; }

  # The project's own runtime is never the thing that ran, in any of the three.
  [ ! -e "$PROJECT_RUNTIME_MARKER" ]
}

# `$PWD` is where the session started, which for a Codex session is routinely a
# subdirectory rather than the project root — and `context-log.md` and
# `.claude/primers/INDEX.md` both live at the root, so the hooks would find
# nothing and inject nothing without ever saying so.
@test "a SessionStart project dir inside a project resolves to the attachment root" {
  make_release 1.2.3 session-context
  make_poisoned_project_runtime
  mkdir -p "$PROJECT/src/deep"

  rm -f "$PROJECT_RUNTIME_MARKER"
  run_rendered_codex_session_start "$PROJECT/src/deep"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"verified payload project context"* ]] || { echo "$output"; false; }
  [ ! -e "$PROJECT_RUNTIME_MARKER" ]
}

# ...and a directory under no attachment at all still resolves to itself, so an
# unattached clone behaves exactly as it did before the walk existed.
@test "a SessionStart project dir under no attachment resolves to itself" {
  make_release 1.2.3 session-context
  make_poisoned_project_runtime
  mkdir -p "$SANDBOX/projects/unattached"

  run_session_context codex "$SANDBOX/projects/unattached"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"verified payload project context"* ]] || { echo "$output"; false; }
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

  # The Claude and Codex project-dir arguments differ on purpose, so this loop
  # cannot reuse the bare-variable form asserted above. Claude Code always sets
  # CLAUDE_PROJECT_DIR, but Codex does not reliably set CODEX_PROJECT_DIR, so
  # every Codex surface in this repo — core-rules/codex/hooks.json and each
  # script under core-rules/codex/hooks/ — resolves it through the documented
  # ${CODEX_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}} chain. The template follows
  # that convention; this expectation had mirrored the Claude form since the
  # template and the assertion landed together in 0d37cf1, so it never matched.
  for name in session-context post-compact-context inject-primer-index; do
    run jq -r --arg name "$name" '.hooks.SessionStart[0].hooks[].command | select(contains("hook " + $name + " codex "))' \
      "$REPO_ROOT/core-rules/templates/codex-hooks.local.json"
    [ "$status" -eq 0 ] || { echo "$output"; false; }
    expected="/usr/bin/env -i HOME=__TRELLIS_USER_HOME__ TRELLIS_HOME=__TRELLIS_HOME__ PATH=/usr/bin:/bin:/usr/sbin:/sbin /bin/bash --noprofile --norc __TRELLIS_LAUNCHER__ hook $name codex \"\${CODEX_PROJECT_DIR:-\${CLAUDE_PROJECT_DIR:-\$PWD}}\""
    [ "$output" = "$expected" ] || { echo "actual:   $output"; echo "expected: $expected"; false; }
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
  find "$TRELLIS_HOME/releases/1.2.3" -depth -type d -exec chmod u+w {} +
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

@test "launcher derives a private command scratch and hands it to the ordinary payload child" {
  local observed
  make_release 1.2.3 scratch-probe
  printf 'write\n' > "$SANDBOX/scratch-probe-mode"

  run_launcher_with_tmpdir "/hostile ambient tmp" doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  case "$observed" in
    "$TRELLIS_HOME/state/scratch/.cmd."*) ;;
    *) echo "observed TMPDIR: $observed"; false ;;
  esac
  [ "$(cat "$SANDBOX/scratch-mode.log")" = 'drwx------' ] ||
    { echo "scratch mode: $(cat "$SANDBOX/scratch-mode.log")"; false; }
  # The permission field only: macOS appends `@` for extended attributes, which
  # the launcher's own private-directory check also ignores (it refuses `+`,
  # an ACL, and reads exactly the ten mode characters).
  [ "$(LC_ALL=C ls -ld "$TRELLIS_HOME/state" | awk '{print substr($1, 1, 10)}')" = 'drwx------' ]
  [ "$(LC_ALL=C ls -ld "$TRELLIS_HOME/state/scratch" | awk '{print substr($1, 1, 10)}')" = 'drwx------' ]
  # A real command temp file allocated through ${TMPDIR:-/tmp}: the hostile
  # ambient value never reached the child, and the derived one is writable.
  case "$(cat "$SANDBOX/scratch-mktemp.log")" in
    "$observed"/probe.??????) ;;
    *) echo "mktemp landed outside the derived scratch: $(cat "$SANDBOX/scratch-mktemp.log")"; false ;;
  esac
  [ ! -e "$observed" ] || { echo "command scratch survived: $observed"; false; }
  assert_no_command_scratch
  assert_no_execution_snapshot
}

@test "command scratch preserves a Trellis home spelled with spaces" {
  local spaced observed
  spaced="$SANDBOX/trellis home with spaces"
  mv "$TRELLIS_HOME" "$spaced"
  export TRELLIS_HOME="$spaced"
  make_release 1.2.3 scratch-probe

  run_launcher_with_tmpdir /tmp doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  case "$observed" in
    "$spaced/state/scratch/.cmd."*) ;;
    *) echo "observed TMPDIR: $observed"; false ;;
  esac
  assert_no_command_scratch
}

@test "command scratch is removed after a nonzero payload exit without changing the status" {
  make_release 1.2.3 scratch-probe
  printf '7\n' > "$SANDBOX/scratch-probe-status"

  run_launcher doctor
  [ "$status" -eq 7 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$(cat "$SANDBOX/scratch-tmpdir.log")" ]
  assert_no_command_scratch
}

@test "the existing TERM trap cleans the command scratch and keeps its 143 status" {
  make_release 1.2.3 scratch-probe
  # The payload signals its own launcher and returns: the trap is exercised
  # exactly as a real TERM exercises it, with no sleep and no polling. The
  # alarm is a hard ceiling on a hang, not the mechanism under test.
  printf 'term\n' > "$SANDBOX/scratch-probe-mode"

  run /usr/bin/perl -e 'alarm 60; exec @ARGV or die "exec: $!"' \
    env "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" "$LAUNCHER" doctor
  [ "$status" -eq 143 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$(cat "$SANDBOX/scratch-tmpdir.log")" ]
  assert_no_command_scratch
}

@test "command scratch cleanup refuses a replaced directory and preserves it and its neighbours" {
  local replaced
  make_release 1.2.3 scratch-probe
  run_launcher doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  printf 'neighbour bytes\n' > "$TRELLIS_HOME/state/scratch/neighbour"

  printf 'replace-directory\n' > "$SANDBOX/scratch-probe-mode"
  run_launcher doctor
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *'could not clean command scratch directory'* ]] || { echo "$output"; false; }
  replaced="$(cat "$SANDBOX/scratch-tmpdir.log")"
  [ -d "$replaced" ] && [ ! -L "$replaced" ]
  [ "$(cat "$replaced/replacement")" = replacement ]
  [ "$(cat "$TRELLIS_HOME/state/scratch/neighbour")" = 'neighbour bytes' ]
}

@test "command scratch cleanup refuses a replaced parent and preserves both directory trees" {
  local observed retained expected
  make_release 1.2.3 scratch-probe

  run_launcher doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$(cat "$SANDBOX/scratch-tmpdir.log")" ]
  assert_no_command_scratch
  assert_no_execution_snapshot
  printf 'original neighbour bytes\n' > "$TRELLIS_HOME/state/scratch/neighbour"

  printf 'replace-parent\n' > "$SANDBOX/scratch-probe-mode"
  run_launcher doctor
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  retained="$TRELLIS_HOME/state/scratch-retained/${observed##*/}"
  expected="$(printf '%s\n' \
    'trellis: the command scratch root changed since it was recorded' \
    "trellis: could not clean command scratch directory: $observed")"
  [ "$output" = "$expected" ] || { echo "parent-identity refusal mismatch: $output"; false; }
  [ -d "$observed" ] && [ ! -L "$observed" ]
  [ -d "$retained" ] && [ ! -L "$retained" ]
  printf 'replacement scratch bytes\n' | cmp - "$observed/replacement"
  printf 'replacement neighbour bytes\n' | cmp - "$TRELLIS_HOME/state/scratch/neighbour"
  printf 'original scratch bytes\n' | cmp - "$retained/original"
  printf 'original neighbour bytes\n' | cmp - "$TRELLIS_HOME/state/scratch-retained/neighbour"
  assert_no_execution_snapshot
}

# Extract the actual helper boundaries without sourcing the launcher entrypoint.
# The emitted Python is executed unchanged, including its imports and arguments.
prepare_command_scratch_helpers() {
  python3 -I -c '
import pathlib, re, subprocess, sys
source = pathlib.Path(sys.argv[1]).read_text()
out = pathlib.Path(sys.argv[2])
functions = re.findall(r"^launcher_(?:command_scratch_[a-z_]+|derive_command_scratch|remove_command_scratch|absolute_path_is_clean|error)\(\) \{\n.*?^\}", source, re.M | re.S)
assert len(functions) >= 6
library = out / "scratch-helpers.sh"
library.write_text("TRELLIS_EX_USAGE=2\nTRELLIS_EX_STATE=4\nTRELLIS_EX_UNAVAILABLE=5\n" + "\n".join(functions))
for mode in ("create", "remove"):
    result = subprocess.run(["/bin/bash", "-c", "source \"$1\"; launcher_command_scratch_" + mode + "_program", "bash", str(library)], capture_output=True, text=True, check=True)
    (out / (mode + ".py")).write_text(result.stdout)
' "$LAUNCHER_TEMPLATE" "$SANDBOX"
}

@test "command scratch repair refuses a completed state ancestor alias before cleanup" {
  local observed retained
  make_release 1.2.3 scratch-probe
  printf 'replace-state-alias\n' > "$SANDBOX/scratch-probe-mode"
  run_launcher doctor
  [ "$status" -eq 5 ] || { echo "repair mismatch: alias cleanup status=$status $output"; false; }
  [[ "$output" == *'without following links'* ]] || { echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  retained="$TRELLIS_HOME/state.saved/scratch/${observed##*/}"
  [ -L "$TRELLIS_HOME/state" ] && [ -d "$retained" ]
  printf 'original scratch bytes\n' | cmp - "$retained/original"
  printf 'state sentinel bytes\n' | cmp - "$TRELLIS_HOME/state.saved/sentinel"
  printf 'neighbour bytes\n' | cmp - "$TRELLIS_HOME/state.saved/scratch/neighbour"
  assert_no_execution_snapshot
}

@test "command scratch repair refuses ancestor aliases when opening the canonical home" {
  prepare_command_scratch_helpers
  mkdir -m 700 "$SANDBOX/entry" "$SANDBOX/entry/home"
  run python3 -I "$SANDBOX/create.py" "$SANDBOX/entry/home"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  mv "$SANDBOX/entry" "$SANDBOX/entry.saved"
  ln -s entry.saved "$SANDBOX/entry"
  printf 'sentinel\n' > "$SANDBOX/entry.saved/sentinel"
  run python3 -I "$SANDBOX/create.py" "$SANDBOX/entry/home"
  [ "$status" -eq 4 ] || { echo "repair mismatch: home alias status=$status $output"; false; }
  [[ "$output" == *'without following links'* ]] || { echo "$output"; false; }
  printf 'sentinel\n' | cmp - "$SANDBOX/entry.saved/sentinel"
  [ -L "$SANDBOX/entry" ]
}

@test "command scratch repair rejects real Darwin ACLs on home state root and new child" {
  [ "$(uname -s)" = Darwin ] || skip "native Darwin ACL fixture"
  prepare_command_scratch_helpers
  run python3 -I -c '
import os, pathlib, stat, subprocess, sys
base = pathlib.Path(sys.argv[1])
program = (base / "create.py").read_text()
failures = []
for label in ("home", "state", "root", "child"):
    home = base / ("acl-" + label)
    root = home / "state" / "scratch"
    root.mkdir(parents=True)
    for p in (home, home / "state", root):
        p.chmod(0o700)
    target = {"home": home, "state": home / "state", "root": root}.get(label)
    if target:
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,search,directory_inherit", str(target)], check=True)
        assert stat.S_IMODE(target.stat().st_mode) == 0o700
        before = subprocess.run(["/bin/ls", "-lde", str(target)], capture_output=True, text=True, check=True).stdout
        assert "allow" in before
        code = program
    else:
        # Install a real ACL immediately after mkdir of the new command child,
        # before the production no-follow open/private check, not on a decoy path.
        code = """import os, subprocess, sys
real_mkdir = os.mkdir
def mkdir(name, mode=0o777, *, dir_fd=None):
    real_mkdir(name, mode, dir_fd=dir_fd)
    if str(name).startswith(".cmd."):
        subprocess.run(["/bin/chmod", "+a", "everyone allow read,search,directory_inherit", sys.argv[1] + "/state/scratch/" + name], check=True)
os.mkdir = mkdir
""" + program
    result = subprocess.run([sys.executable, "-I", "-c", code, str(home)], capture_output=True, text=True)
    print(label, result.returncode, result.stderr, flush=True)
    if result.returncode != 4 or "has an ACL" not in result.stderr:
        failures.append(label)
    if target:
        after = subprocess.run(["/bin/ls", "-lde", str(target)], capture_output=True, text=True, check=True).stdout
        assert before.splitlines()[1:] == after.splitlines()[1:], (label, "ACL was repaired")
        assert stat.S_IMODE(target.stat().st_mode) == 0o700, (label, "mode was repaired")
assert not failures, "repair mismatch: ACL accepted at " + repr(failures)
' "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "command scratch repair rejects malformed identities at wrapper and embedded boundaries" {
  prepare_command_scratch_helpers
  run python3 -I -c '
import pathlib, subprocess, sys
base = pathlib.Path(sys.argv[1])
home = base / "identity-home"
home.mkdir(mode=0o700)
created = subprocess.run([sys.executable, "-I", str(base / "create.py"), str(home)], capture_output=True, text=True, check=True)
name, child_id, root_id = created.stdout.strip().split("\t")
root = str(home / "state" / "scratch")
wrapper = ["/bin/bash", "-c", "source \"$1\"; shift; launcher_remove_command_scratch \"$@\"", "bash", str(base / "scratch-helpers.sh")]
embedded = [sys.executable, "-I", str(base / "remove.py")]
for command in (wrapper, embedded):
    # Both real removal and well-formed missing-child idempotence must work.
    subprocess.run(command + [root, name, child_id, root_id], check=True)
failures = []
for label, command in (("wrapper", wrapper), ("embedded", embedded)):
    for bad in (":", "1::2", "123", "", "1:", ":2", "١:2", "1:2\n", "-1:2"):
        for position in (2, 3):
            args = [root, name, child_id, root_id]
            args[position] = bad
            result = subprocess.run(command + args, capture_output=True, text=True)
            if result.returncode != 2:
                failures.append((label, bad, position, result.returncode))
assert not failures, "repair mismatch: malformed cleanup identities " + repr(failures)
' "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "command scratch distinguishes Darwin ACL inspection errors from absent ACLs" {
  [ "$(uname -s)" = Darwin ] || skip "native Darwin ACL API"
  prepare_command_scratch_helpers
  run python3 -I -c '
import errno, pathlib, subprocess, sys
base = pathlib.Path(sys.argv[1])
home = base / "acl-error-home"
home.mkdir(mode=0o700)
program = (base / "create.py").read_text()
for error in (errno.EBADF, errno.EACCES, errno.EIO, errno.ENOTSUP):
    prefix = """import ctypes
native_cdll = ctypes.CDLL
def load(*args, **kwargs):
    library = native_cdll(*args, **kwargs)
    def get_acl(fd, kind):
        ctypes.set_errno(%d)
        return None
    library.acl_get_fd_np = get_acl
    return library
ctypes.CDLL = load
""" % error
    result = subprocess.run([sys.executable, "-I", "-c", prefix + program, str(home)], capture_output=True, text=True)
    assert result.returncode == 5 and "could not inspect ACL" in result.stderr, (error, result)
    assert not (home / "state").exists()
' "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "command scratch rejects malformed producer identities before publishing its globals" {
  prepare_command_scratch_helpers
  run python3 -I -c '
import pathlib, subprocess, sys
base = pathlib.Path(sys.argv[1])
command = ["/bin/bash", "-c", "source \"$1\"; program=$2; launcher_command_scratch_create_program() { printf %s \"$program\"; }; launcher_derive_command_scratch \"$3\"", "bash", str(base / "scratch-helpers.sh")]
for bad in (":", "1::2", "123", "", "١:2"):
    for identities in ((bad, "1:2"), ("1:2", bad)):
        record = ".cmd.a\t" + "\t".join(identities)
        result = subprocess.run(command + ["print(" + repr(record) + ")", str(base)], capture_output=True, text=True)
        assert result.returncode == 4, (identities, result)
' "$SANDBOX"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "command scratch allows existing nonwritable ancestors when allocation locations are writable" {
  make_release 1.2.3 scratch-probe
  mkdir -p "$TRELLIS_HOME/state/scratch"
  chmod 500 "$TRELLIS_HOME/state"
  chmod 700 "$TRELLIS_HOME/state/scratch"
  run_launcher doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_no_command_scratch
}

@test "command scratch cleanup unlinks a child symlink without following it and refuses a symlinked scratch" {
  local observed
  make_release 1.2.3 scratch-probe
  printf 'target bytes\n' > "$SANDBOX/neighbour-target"

  printf 'child-symlink\n' > "$SANDBOX/scratch-probe-mode"
  run_launcher doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  [ ! -e "$observed" ] && [ ! -L "$observed" ]
  [ "$(cat "$SANDBOX/neighbour-target")" = 'target bytes' ]
  assert_no_command_scratch

  printf 'replace-symlink\n' > "$SANDBOX/scratch-probe-mode"
  run_launcher doctor
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *'could not clean command scratch directory'* ]] || { echo "$output"; false; }
  observed="$(cat "$SANDBOX/scratch-tmpdir.log")"
  [ -L "$observed" ] || { echo "replacement symlink was removed: $observed"; false; }
  [ "$(cat "$SANDBOX/neighbour-target")" = 'target bytes' ]
}

@test "command scratch derivation refuses symlinked, non-private, and unwritable state parents" {
  make_release 1.2.3 scratch-probe
  mkdir -p "$SANDBOX/outside-state"
  ln -s "$SANDBOX/outside-state" "$TRELLIS_HOME/state"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *'command scratch'* ]] || { echo "$output"; false; }
  [ ! -e "$SANDBOX/scratch-tmpdir.log" ] || { echo "the payload child ran anyway"; false; }
  rm "$TRELLIS_HOME/state"

  mkdir -p "$TRELLIS_HOME/state/scratch"
  chmod 700 "$TRELLIS_HOME/state"
  chmod 755 "$TRELLIS_HOME/state/scratch"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$SANDBOX/scratch-tmpdir.log" ] || { echo "the payload child ran anyway"; false; }

  chmod 500 "$TRELLIS_HOME/state/scratch"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$SANDBOX/scratch-tmpdir.log" ] || { echo "the payload child ran anyway"; false; }

  rmdir "$TRELLIS_HOME/state/scratch"
  chmod 500 "$TRELLIS_HOME/state"
  run_launcher doctor
  [ "$status" -eq 4 ] || { echo "status=$status"; echo "$output"; false; }
  [ ! -e "$SANDBOX/scratch-tmpdir.log" ] || { echo "the payload child ran anyway"; false; }

  # Positive control: the same home derives and removes a scratch once its
  # state parents are private and writable again.
  chmod 700 "$TRELLIS_HOME/state"
  run_launcher doctor
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  case "$(cat "$SANDBOX/scratch-tmpdir.log")" in
    "$TRELLIS_HOME/state/scratch/.cmd."*) ;;
    *) echo "observed TMPDIR: $(cat "$SANDBOX/scratch-tmpdir.log")"; false ;;
  esac
  assert_no_command_scratch
}

@test "the verified command bundle child receives and admits the derived command scratch" {
  local observed admitted git_tmpdir
  make_release 1.2.3 command-bundle-scratch

  run_launcher_with_tmpdir "/hostile ambient tmp" upgrade
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"bundle-tmpdir=$TRELLIS_HOME/state/scratch/.cmd."* ]] || { echo "$output"; false; }
  [[ "$output" == *"bundle-admitted=$TRELLIS_HOME/state/scratch/.cmd."* ]] || { echo "$output"; false; }
  [[ "$output" != *'scratch upgrade wrapper ran'* ]] || { echo "$output"; false; }
  observed="$(printf '%s\n' "$output" | sed -n 's/^bundle-tmpdir=//p')"
  admitted="$(printf '%s\n' "$output" | sed -n 's/^bundle-admitted=//p')"
  git_tmpdir="$(printf '%s\n' "$output" | sed -n 's/^git-tmpdir=//p')"
  [ "$admitted" = "$observed" ] || { echo "$output"; false; }
  [ "$git_tmpdir" = "$observed" ] || { echo "Git TMPDIR mismatch: $output"; false; }
  assert_no_command_scratch
}

@test "release pathname execution admits only a private Trellis command scratch candidate" {
  local scratch hostile
  make_release 1.2.3 command-bundle
  mkdir -p "$TRELLIS_HOME/state/scratch"
  chmod 700 "$TRELLIS_HOME/state" "$TRELLIS_HOME/state/scratch"
  scratch="$TRELLIS_HOME/state/scratch/.cmd.fixture"
  mkdir -m 700 "$scratch"

  run_release_pathname "$scratch" adopt 1.2.3 --all
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *'no registered worktrees matched the requested adoption selector'* ]] ||
    { echo "$output"; false; }

  # The admitted value is the directory the command actually allocates in:
  # made unwritable, the same command dies at its first temp allocation.
  chmod 500 "$scratch"
  run_release_pathname "$scratch" adopt 1.2.3 --all
  [ "$status" -eq 5 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" != *'no registered worktrees matched'* ]] ||
    { echo "the command allocated outside the admitted scratch"; echo "$output"; false; }
  chmod 700 "$scratch"

  ln -s "$scratch" "$TRELLIS_HOME/state/scratch/.cmd.link"
  for hostile in \
    /tmp \
    "$SANDBOX" \
    "$TRELLIS_HOME/state/scratch" \
    "$TRELLIS_HOME/state/scratch/.cmd.missing" \
    "$TRELLIS_HOME/state/scratch/.cmd.link" \
    "$TRELLIS_HOME/state/scratch/./.cmd.fixture"; do
    run_release_pathname "$hostile" adopt 1.2.3 --all
    [ "$status" -eq 4 ] || { echo "candidate=$hostile status=$status"; echo "$output"; false; }
    [[ "$output" == *'command scratch directory is not an admissible'* ]] ||
      { echo "candidate=$hostile"; echo "$output"; false; }
  done

  # Direct source execution stays refused, admissible candidate or not.
  run env -i "HOME=$HOME" "TRELLIS_HOME=$TRELLIS_HOME" "PATH=$PATH" "TMPDIR=$scratch" \
    /bin/bash "$REPO_ROOT/scripts/release.sh" adopt 1.2.3 --all
  [ "$status" -eq 2 ] || { echo "status=$status"; echo "$output"; false; }
  [[ "$output" == *'direct source execution is unsupported'* ]] || { echo "$output"; false; }
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
