#!/usr/bin/env bats
# Hermetic security tests for the launchd installer. Installer mutations are
# driven through a sourced body only to replace its fixed launchctl boundary;
# every filesystem path remains under a fresh temporary operator home and
# Trellis machine home.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/install-disk-janitor-launchd.sh"
REPORT_TEMPLATE="$REPO_ROOT/core-rules/templates/org.trellis.disk-janitor.plist"
REPORT_LABEL='org.trellis.disk-janitor'

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/operator-home"
  TRELLIS_HOME="$SANDBOX/trellis-home"
  LAUNCHCTL_LOG="$SANDBOX/launchctl.log"
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME"
  chmod 700 "$TRELLIS_HOME"
  cat > "$HOME/.local/bin/trellis" <<'SH'
#!/bin/bash
exit 0
SH
  chmod 755 "$HOME/.local/bin/trellis"
  export HOME TRELLIS_HOME LAUNCHCTL_LOG
}
teardown() {
  unset BASH_ENV BASH_ENV_POISON TRELLIS_TEST_ACL_PATH TRELLIS_TEST_ACL_PREFIX 2>/dev/null || true
  unset -f poisoned_launchd_function 2>/dev/null || true
  [ -z "${SANDBOX:-}" ] || rm -rf "$SANDBOX"
}

file_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

file_inode() {
  stat -f '%i' "$1" 2>/dev/null || stat -c '%i' "$1"
}

# Execute the script's public main entrypoint while replacing only the
# launchctl process boundary. Production still resolves that command by its
# fixed absolute path; no PATH-based test double exists.
run_installer() {
  run /usr/bin/env \
    HOME="$HOME" \
    TRELLIS_HOME="$TRELLIS_HOME" \
    TRELLIS_LAUNCHER="${TRELLIS_LAUNCHER:-}" \
    PATH="${INSTALLER_PATH:-$PATH}" \
    LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    TRELLIS_TEST_ACL_PATH="${TRELLIS_TEST_ACL_PATH:-}" \
    TRELLIS_TEST_ACL_PREFIX="${TRELLIS_TEST_ACL_PREFIX:-}" \
    /bin/bash -c '
      installer="$1"
      shift
      . "$installer"
      launchctl_run() {
        printf "%s\t%s\n" "$1" "$2" >> "$LAUNCHCTL_LOG"
      }
      if [ -n "${TRELLIS_TEST_ACL_PATH:-}" ] || [ -n "${TRELLIS_TEST_ACL_PREFIX:-}" ]; then
        path_has_extended_acl() {
          case "$1" in
            "${TRELLIS_TEST_ACL_PATH:-}") [ -n "${TRELLIS_TEST_ACL_PATH:-}" ] ;;
            "${TRELLIS_TEST_ACL_PREFIX:-}"*) [ -n "${TRELLIS_TEST_ACL_PREFIX:-}" ] ;;
            *) return 1 ;;
          esac
        }
      fi
      main "$@"
    ' _ "$INSTALLER" "$@"
}

# Insert a same-UID namespace replacement immediately before the descriptor
# sink. The saved implementation still performs the real fixed helper; only
# launchctl is mocked as in run_installer.
run_installer_with_sink_parent_swap() {
  local operation="$1" outside="$2"
  shift 2
  run /usr/bin/env \
    HOME="$HOME" \
    TRELLIS_HOME="$TRELLIS_HOME" \
    PATH="${INSTALLER_PATH:-$PATH}" \
    LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    /bin/bash -c '
      installer="$1"
      outside="$2"
      operation="$3"
      shift 3
      . "$installer"
      launchctl_run() {
        printf "%s\t%s\n" "$1" "$2" >> "$LAUNCHCTL_LOG"
      }
      eval "$(declare -f launch_agents_secure_operation | /usr/bin/sed '"'"'1s/^launch_agents_secure_operation /launch_agents_secure_operation_before_swap /'"'"')"
      launch_agents_secure_operation() {
        if [ "$1" = "$operation" ] && [ "${parent_swapped:-false}" = false ]; then
          /bin/mv "$launch_agents_dir" "$outside/original-LaunchAgents"
          /bin/ln -s "$outside/original-LaunchAgents" "$launch_agents_dir"
          parent_swapped=true
        fi
        launch_agents_secure_operation_before_swap "$@"
      }
      main "$@"
    ' _ "$INSTALLER" "$outside" "$operation" "$@"
}

make_owned_report() {
  local destination="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist"
  mkdir -p "$(dirname "$destination")"
  sed \
    -e "s|__USER_HOME__|$HOME|g" \
    -e "s|__TRELLIS_HOME__|$TRELLIS_HOME|g" \
    "$REPORT_TEMPLATE" > "$destination"
  chmod 600 "$destination"
}
@test "pins a clean canonical bootstrap despite ambient launcher and shell poisoning" {
  local canonical_home="$SANDBOX/canonical-operator-home"
  local canonical_trellis_home="$SANDBOX/canonical-trellis-home"
  local destination poison bash_env expected_log
  mv "$HOME" "$canonical_home"
  mv "$TRELLIS_HOME" "$canonical_trellis_home"
  HOME="$canonical_home"
  TRELLIS_HOME="$canonical_trellis_home"
  export HOME TRELLIS_HOME
  cat > "$canonical_home/.local/bin/trellis" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "$HOME/launchd-argv"
env > "$HOME/launchd-env"
SH
  chmod 755 "$canonical_home/.local/bin/trellis"
  poison="$SANDBOX/poisoned-launcher"
  : > "$poison"
  bash_env="$SANDBOX/poisoned-bash-env"
  printf 'export BASH_ENV_POISON=from-bash-env\n' > "$bash_env"
  poisoned_launchd_function() { printf '%s\n' 'must-not-reach-launchd'; }
  export BASH_ENV="$bash_env" TRELLIS_LAUNCHER="$poison"
  export -f poisoned_launchd_function
  INSTALLER_PATH="$SANDBOX/poison-bin:/usr/bin:/bin"

  run_installer

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  destination="$canonical_home/Library/LaunchAgents/$REPORT_LABEL.plist"
  [ ! -e "$canonical_home/Library/LaunchAgents/org.trellis.disk-janitor-apply.plist" ]
  grep -F '<string>/usr/bin/env</string>' "$destination"
  grep -F '<string>-i</string>' "$destination"
  grep -F "<string>HOME=$canonical_home</string>" "$destination"
  grep -F "<string>TRELLIS_HOME=$canonical_trellis_home</string>" "$destination"
  grep -F '<string>PATH=/usr/bin:/bin:/usr/sbin:/sbin</string>' "$destination"
  grep -F '<string>/bin/bash</string>' "$destination"
  grep -F '<string>--noprofile</string>' "$destination"
  grep -F '<string>--norc</string>' "$destination"
  grep -F "<string>$canonical_home/.local/bin/trellis</string>" "$destination"
  for poison in "$poison" BASH_ENV_POISON poisoned_launchd_function '<key>EnvironmentVariables</key>'; do
    run grep -F "$poison" "$destination"
    [ "$status" -eq 1 ]
  done
  expected_log="$(printf 'load\t%s' "$destination")"
  [ "$(cat "$LAUNCHCTL_LOG")" = "$expected_log" ]
  run /usr/bin/env -i \
    "HOME=$canonical_home" \
    "TRELLIS_HOME=$canonical_trellis_home" \
    'PATH=/usr/bin:/bin:/usr/sbin:/sbin' \
    /bin/bash --noprofile --norc "$canonical_home/.local/bin/trellis" disk-janitor --report
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(cat "$canonical_home/launchd-argv")" = "$(printf 'disk-janitor\n--report')" ]
  grep -Fx "HOME=$canonical_home" "$canonical_home/launchd-env"
  grep -Fx "TRELLIS_HOME=$canonical_trellis_home" "$canonical_home/launchd-env"
  grep -Fx 'PATH=/usr/bin:/bin:/usr/sbin:/sbin' "$canonical_home/launchd-env"
  for poison in 'BASH_ENV=' 'BASH_ENV_POISON=' 'TRELLIS_LAUNCHER=' 'BASH_FUNC_poisoned_launchd_function'; do
    run grep -F "$poison" "$canonical_home/launchd-env"
    [ "$status" -eq 1 ]
  done
}
@test "rejects a symlinked LaunchAgents ancestor before any installation write" {
  local outside="$SANDBOX/outside"
  mkdir -p "$outside"
  ln -s "$outside" "$HOME/Library"

  run_installer

  [ "$status" -eq 4 ]
  [[ "$output" == *"LaunchAgents directory has a symlink or non-directory component"* ]] || { echo "$output"; false; }
  [ ! -e "$outside/LaunchAgents/$REPORT_LABEL.plist" ]
  [ ! -s "$LAUNCHCTL_LOG" ]
}

@test "rejects a symlinked plist victim without following or loading it" {
  local destination="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist" victim="$SANDBOX/victim.plist"
  mkdir -p "$(dirname "$destination")"
  printf 'foreign victim\n' > "$victim"
  ln -s "$victim" "$destination"

  run_installer

  [ "$status" -eq 3 ]
  [ "$(cat "$victim")" = 'foreign victim' ]
  [ ! -e "$HOME/Library/Logs" ]
  [ ! -s "$LAUNCHCTL_LOG" ]
}

@test "rejects non-owned regular and non-regular plist destinations before writes" {
  local destination="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist"
  mkdir -p "$(dirname "$destination")"
  printf 'foreign launchd destination\n' > "$destination"

  run_installer

  [ "$status" -eq 3 ]
  [ "$(cat "$destination")" = 'foreign launchd destination' ]
  [ ! -e "$HOME/Library/Logs" ]
  [ ! -s "$LAUNCHCTL_LOG" ]

  rm "$destination"
  mkdir "$destination"

  run_installer

  [ "$status" -eq 3 ]
  [ -d "$destination" ]
  [ ! -e "$HOME/Library/Logs" ]
  [ ! -s "$LAUNCHCTL_LOG" ]
}

@test "rejects an ACL-bearing agent destination before writes" {
  local destination="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist"
  make_owned_report
  TRELLIS_TEST_ACL_PATH="$destination"

  run_installer

  [ "$status" -eq 4 ]
  [[ "$output" == *"agent destination has an extended ACL"* ]] || { echo "$output"; false; }
  [ -f "$destination" ]
  [ ! -e "$HOME/Library/Logs" ]
  [ ! -s "$LAUNCHCTL_LOG" ]
}

@test "--with-apply renders the opt-in agent through the same clean bootstrap" {
  local report="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist"
  local apply="$HOME/Library/LaunchAgents/org.trellis.disk-janitor-apply.plist" expected_log

  run_installer --with-apply

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$report" ]
  grep -F '<string>/usr/bin/env</string>' "$apply"
  grep -F '<string>-i</string>' "$apply"
  grep -F "<string>HOME=$HOME</string>" "$apply"
  grep -F "<string>TRELLIS_HOME=$TRELLIS_HOME</string>" "$apply"
  grep -F '<string>/bin/bash</string>' "$apply"
  grep -F '<string>--noprofile</string>' "$apply"
  grep -F '<string>--norc</string>' "$apply"
  grep -F "<string>$HOME/.local/bin/trellis</string>" "$apply"
  grep -F '<string>--safe-only</string>' "$apply"
  run grep -F '<key>EnvironmentVariables</key>' "$apply"
  [ "$status" -eq 1 ]
  expected_log="$(printf 'load\t%s\nload\t%s' "$report" "$apply")"
  [ "$(cat "$LAUNCHCTL_LOG")" = "$expected_log" ]
}

@test "atomically replaces an allowed owned regular destination and loads only its final path" {
  local destination="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist" before_inode after_inode expected_log
  make_owned_report
  before_inode="$(file_inode "$destination")"

  run_installer

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  after_inode="$(file_inode "$destination")"
  [ "$before_inode" != "$after_inode" ]
  [ "$(file_mode "$destination")" = 600 ]
  grep -F '<string>PATH=/usr/bin:/bin:/usr/sbin:/sbin</string>' "$destination"
  expected_log="$(printf 'unload\t%s\nload\t%s' "$destination" "$destination")"
  [ "$(cat "$LAUNCHCTL_LOG")" = "$expected_log" ]
}

@test "refuses a same-UID LaunchAgents parent swap at the publication sink" {
  local destination="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist"
  local outside="$SANDBOX/outside" preserved expected_log
  make_owned_report
  preserved="$(cat "$destination")"
  mkdir "$outside"

  run_installer_with_sink_parent_swap publish "$outside"

  [ "$status" -eq 4 ]
  [[ "$output" == *"LaunchAgents directory has a symlink or non-directory component"* ]] || { echo "$output"; false; }
  [ -L "$HOME/Library/LaunchAgents" ]
  [ "$(cat "$outside/original-LaunchAgents/$REPORT_LABEL.plist")" = "$preserved" ]
  expected_log="$(printf 'unload\t%s' "$destination")"
  [ "$(cat "$LAUNCHCTL_LOG")" = "$expected_log" ]
}

@test "--uninstall removes an owned finalized destination" {
  local destination="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist" expected_log
  make_owned_report

  run_installer --uninstall

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$destination" ]
  expected_log="$(printf 'unload\t%s' "$destination")"
  [ "$(cat "$LAUNCHCTL_LOG")" = "$expected_log" ]
}

@test "refuses a same-UID LaunchAgents parent swap at the removal sink" {
  local destination="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist"
  local outside="$SANDBOX/outside" preserved expected_log
  make_owned_report
  preserved="$(cat "$destination")"
  mkdir "$outside"

  run_installer_with_sink_parent_swap remove "$outside" --uninstall

  [ "$status" -eq 4 ]
  [[ "$output" == *"LaunchAgents directory has a symlink or non-directory component"* ]] || { echo "$output"; false; }
  [ -L "$HOME/Library/LaunchAgents" ]
  [ "$(cat "$outside/original-LaunchAgents/$REPORT_LABEL.plist")" = "$preserved" ]
  expected_log="$(printf 'unload\t%s' "$destination")"
  [ "$(cat "$LAUNCHCTL_LOG")" = "$expected_log" ]
}
