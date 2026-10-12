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
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME/releases/1.2.3/payload/scripts"
  chmod 700 "$TRELLIS_HOME"
  cat > "$TRELLIS_HOME/config.json" <<'EOF'
{"schema_version":1,"active_cli_release":"1.2.3"}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"
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

# BSD and GNU stat are probed in SEPARATE captures: GNU `stat -f` is
# --file-system and prints a filesystem block before failing, which a chained
# substitution would concatenate onto the value.
file_mode() {
  local candidate
  candidate="$(stat -f '%Lp' "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-7]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c '%a' "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

write_test_release_manifest() {
  local version="$1" script="$2"
  local oid
  oid="$(git hash-object --no-filters "$script")"
  cat > "$TRELLIS_HOME/releases/$version/release.json" <<EOF
{"schema_version":1,"version":"$version","tag":"v$version","commit":"0000000000000000000000000000000000000000","remote":"fixture","tree":[{"path":"scripts/pi-spill-watchdog.sh","mode":"100755","oid":"$oid"}]}
EOF
}

file_inode() {
  local candidate
  candidate="$(stat -f '%i' "$1" 2>/dev/null)" || candidate=""
  case "$candidate" in
    ''|*[!0-9]*) candidate="" ;;
  esac
  if [ -z "$candidate" ]; then
    candidate="$(stat -c '%i' "$1" 2>/dev/null)" || return 1
  fi
  printf '%s\n' "$candidate"
}

# Execute the script's public main entrypoint while replacing only the
# launchctl process boundary. Production still resolves that command by its
# fixed absolute path; no PATH-based test double exists.
run_installer() {
  run /usr/bin/env \
    HOME="$HOME" \
    TRELLIS_HOME="$TRELLIS_HOME" \
    TMPDIR="${TMPDIR:-}" \
    TRELLIS_ATTACH_CALLER_PATH="${TRELLIS_ATTACH_CALLER_PATH:-}" \
    TRELLIS_LAUNCHER="${TRELLIS_LAUNCHER:-}" \
    PATH="${INSTALLER_PATH:-$PATH}" \
    LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    TRELLIS_TEST_ACL_PATH="${TRELLIS_TEST_ACL_PATH:-}" \
    TRELLIS_TEST_ACL_PREFIX="${TRELLIS_TEST_ACL_PREFIX:-}" \
    TRELLIS_TEST_VAR_FOLDERS_PREFIX="${TRELLIS_TEST_VAR_FOLDERS_PREFIX:-}" \
    TRELLIS_TEST_SKIP_JANITOR_DRY_RUN="${TRELLIS_TEST_SKIP_JANITOR_DRY_RUN:-}" \
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

make_owned_apply() {
  local destination="$HOME/Library/LaunchAgents/org.trellis.disk-janitor-apply.plist"
  mkdir -p "$(dirname "$destination")"
  sed \
    -e "s|__USER_HOME__|$HOME|g" \
    -e "s|__TRELLIS_HOME__|$TRELLIS_HOME|g" \
    "$REPO_ROOT/core-rules/templates/org.trellis.disk-janitor-apply.plist" > "$destination"
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

@test "--with-apply dry-runs nightly apply argv and refuses to load when it exits non-zero" {
  local apply="$HOME/Library/LaunchAgents/org.trellis.disk-janitor-apply.plist"

  run_installer --with-apply

  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to load org.trellis.disk-janitor-apply"*"nightly apply argv failed dry-run"* ]] || { echo "$output"; false; }
  ! grep -Fq "load	$apply" "$LAUNCHCTL_LOG"
  # Plist must NOT be published when dry-run gate fails
  [ ! -e "$apply" ]

  # Retry must be allowed without degraded refusal
  run_installer --with-apply
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to load org.trellis.disk-janitor-apply"*"nightly apply argv failed dry-run"* ]] || { echo "$output"; false; }
  [[ "$output" != *"is degraded"* ]]
}

@test "--with-apply replaces an existing degraded apply plist when dry-run succeeds" {
  local apply="$HOME/Library/LaunchAgents/org.trellis.disk-janitor-apply.plist"
  make_owned_apply

  # Re-running with dry-run succeeding replaces the degraded agent without requiring manual remedy
  TRELLIS_TEST_SKIP_JANITOR_DRY_RUN=1 run_installer --with-apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$apply" ]
  grep -Fq "load	$apply" "$LAUNCHCTL_LOG"
}

@test "--with-apply renders the opt-in agent through the same clean bootstrap" {
  local report="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist"
  local apply="$HOME/Library/LaunchAgents/org.trellis.disk-janitor-apply.plist" expected_log

  TRELLIS_TEST_SKIP_JANITOR_DRY_RUN=1 run_installer --with-apply

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

@test "--with-pi-watchdog renders the watchdog agent through the same clean bootstrap" {
  local report="$HOME/Library/LaunchAgents/$REPORT_LABEL.plist"
  local watchdog="$HOME/Library/LaunchAgents/org.trellis.pi-spill-watchdog.plist" expected_log

  run_installer --with-pi-watchdog

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$report" ]
  [ -f "$watchdog" ]
  grep -F '<string>/usr/bin/env</string>' "$watchdog"
  grep -F '<string>-i</string>' "$watchdog"
  grep -F "<string>HOME=$HOME</string>" "$watchdog"
  grep -F "<string>TRELLIS_HOME=$TRELLIS_HOME</string>" "$watchdog"
  grep -F '<string>/bin/bash</string>' "$watchdog"
  grep -F '<string>--noprofile</string>' "$watchdog"
  grep -F '<string>--norc</string>' "$watchdog"
  grep -F "<string>$TRELLIS_HOME/state/disk-janitor/pi-spill-watchdog</string>" "$watchdog"
  grep -F '<key>StartInterval</key>' "$watchdog"
  grep -F '<integer>60</integer>' "$watchdog"
  run grep -F '<key>EnvironmentVariables</key>' "$watchdog"
  [ "$status" -eq 1 ]
  expected_log="$(printf 'load\t%s\nload\t%s' "$report" "$watchdog")"
  [ "$(cat "$LAUNCHCTL_LOG")" = "$expected_log" ]
}

@test "watchdog agent uses stable entry point resolving active release across upgrades and prunes" {
  local watchdog_plist="$HOME/Library/LaunchAgents/org.trellis.pi-spill-watchdog.plist"
  local stable_entry="$TRELLIS_HOME/state/disk-janitor/pi-spill-watchdog"
  local r1="$TRELLIS_HOME/releases/1.2.3/payload/scripts/pi-spill-watchdog.sh"
  local r2_dir="$TRELLIS_HOME/releases/1.2.4/payload/scripts"
  local r2="$r2_dir/pi-spill-watchdog.sh"

  mkdir -p "$r2_dir"
  cat > "$r1" <<'EOF'
#!/bin/sh
printf 'WATCHDOG_123 %s\n' "$*"
EOF
  chmod 755 "$r1"
  write_test_release_manifest 1.2.3 "$r1"
  cat > "$r2" <<'EOF'
#!/bin/sh
printf 'WATCHDOG_124 %s\n' "$*"
EOF
  chmod 755 "$r2"
  write_test_release_manifest 1.2.4 "$r2"

  run_installer --with-pi-watchdog
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$watchdog_plist" ]

  # Plist must point at stable entry point, NOT at a versioned payload
  grep -F "<string>$stable_entry</string>" "$watchdog_plist"
  ! grep -F "<string>$r1</string>" "$watchdog_plist"
  [ -f "$stable_entry" ]
  [ -x "$stable_entry" ]
  [ "$(file_mode "$stable_entry")" = "500" ]
  [ "$(file_mode "$TRELLIS_HOME/state/disk-janitor")" = "700" ]

  # First run uses active release 1.2.3
  run env TRELLIS_HOME="$TRELLIS_HOME" "$stable_entry" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"WATCHDOG_123 --dry-run"* ]]

  # Switch active to 1.2.4 without re-running installer
  cat > "$TRELLIS_HOME/config.json" <<'EOF'
{"schema_version":1,"active_cli_release":"1.2.4"}
EOF

  # Next run uses 1.2.4
  run env TRELLIS_HOME="$TRELLIS_HOME" "$stable_entry" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"WATCHDOG_124 --dry-run"* ]]

  # Prune version 1.2.3: no error loop, still runs 1.2.4
  rm -rf "$TRELLIS_HOME/releases/1.2.3"
  run env TRELLIS_HOME="$TRELLIS_HOME" "$stable_entry" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"WATCHDOG_124 --dry-run"* ]]

  # Prune active version 1.2.4: logs and exits 0 (no error loop in launchd)
  rm -rf "$TRELLIS_HOME/releases/1.2.4"
  run env TRELLIS_HOME="$TRELLIS_HOME" "$stable_entry" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"missing"* || "$output" == *"not executable"* || "$output" == *"not available"* ]]

  # Symlink escape: watchdog script escaping the release store is rejected
  local r3_dir="$TRELLIS_HOME/releases/1.2.5/payload/scripts"
  local evil_outside="$SANDBOX/outside-evil/pwn.sh"
  mkdir -p "$r3_dir" "$SANDBOX/outside-evil"
  cat > "$evil_outside" <<'EOF'
#!/bin/sh
printf 'PWNED\n'
EOF
  chmod 755 "$evil_outside"
  ln -s "$evil_outside" "$r3_dir/pi-spill-watchdog.sh"
  cat > "$TRELLIS_HOME/config.json" <<'EOF'
{"schema_version":1,"active_cli_release":"1.2.5"}
EOF
  run env TRELLIS_HOME="$TRELLIS_HOME" "$stable_entry" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"symlink"* || "$output" == *"escaped"* ]]
  [[ "$output" != *"PWNED"* ]]
}

@test "watchdog install enforces state dir to 0700 and entry point mode to 0500 atomically" {
  local state_dir="$TRELLIS_HOME/state/disk-janitor"
  local stable_entry="$state_dir/pi-spill-watchdog"

  # Pre-create state directory with permissive permissions
  mkdir -p "$state_dir"
  chmod 755 "$state_dir"
  [ "$(file_mode "$state_dir")" = "755" ]

  run_installer --with-pi-watchdog
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # State dir must be enforced to 0700 on install
  [ "$(file_mode "$state_dir")" = "700" ]
  # Entry point must be mode 0500
  [ -f "$stable_entry" ]
  [ "$(file_mode "$stable_entry")" = "500" ]
}

@test "watchdog entry point rejects payload script whose hash does not match release manifest" {
  local stable_entry="$TRELLIS_HOME/state/disk-janitor/pi-spill-watchdog"
  local r_dir="$TRELLIS_HOME/releases/1.2.3/payload/scripts"
  local script="$r_dir/pi-spill-watchdog.sh"

  mkdir -p "$r_dir"
  cat > "$script" <<'EOF'
#!/bin/sh
printf 'WATCHDOG_LEGIT %s\n' "$*"
EOF
  chmod 755 "$script"
  write_test_release_manifest 1.2.3 "$script"

  run_installer --with-pi-watchdog
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Tamper with the script inside the release payload
  cat > "$script" <<'EOF'
#!/bin/sh
printf 'WATCHDOG_TAMPERED %s\n' "$*"
EOF

  run env TRELLIS_HOME="$TRELLIS_HOME" "$stable_entry" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"manifest verification failed"* || "$output" == *"hash mismatch"* ]]
  [[ "$output" != *"WATCHDOG_TAMPERED"* ]]
}

@test "watchdog entry point rejects payload script when release manifest is missing" {
  local stable_entry="$TRELLIS_HOME/state/disk-janitor/pi-spill-watchdog"
  local r_dir="$TRELLIS_HOME/releases/1.2.3/payload/scripts"
  local script="$r_dir/pi-spill-watchdog.sh"

  mkdir -p "$r_dir"
  cat > "$script" <<'EOF'
#!/bin/sh
printf 'WATCHDOG_LEGIT %s\n' "$*"
EOF
  chmod 755 "$script"

  run_installer --with-pi-watchdog
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  # Ensure release.json is absent
  rm -f "$TRELLIS_HOME/releases/1.2.3/release.json"

  run env TRELLIS_HOME="$TRELLIS_HOME" "$stable_entry" --dry-run
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"manifest missing"* ]]
  [[ "$output" != *"WATCHDOG_LEGIT"* ]]
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

@test "an ACL on Library/Logs is refused with the inspect and remove remedy" {
  local logs quoted line
  # A home that needs quoting: each remedy line must still name exactly $logs.
  HOME="$SANDBOX/O'Brien home"
  mkdir -p "$HOME/.local/bin"
  cp "$SANDBOX/operator-home/.local/bin/trellis" "$HOME/.local/bin/trellis"
  logs="$HOME/Library/Logs"
  mkdir -p "$logs"
  TRELLIS_TEST_ACL_PATH="$logs"
  printf -v quoted %q "$logs"

  run_installer --with-apply

  [ "$status" -eq 4 ]
  [[ "$output" == *"Logs directory has an extended ACL: $logs"* ]] || { echo "$output"; false; }
  [[ "$output" == *$'\n'"  /bin/ls -led $quoted"$'\n'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'\n'"  /bin/chmod -a# N $quoted"$'\n'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'\n'"  /bin/chmod -N $quoted"$'\n'* ]] || { echo "$output"; false; }
  # Every command line is one shell command whose last word is the Logs path.
  while IFS= read -r line; do
    case "$line" in
      '  /bin/'*) eval "set -- ${line#  }"; [ "${!#}" = "$logs" ] || { echo "$line"; false; } ;;
    esac
  done <<< "$output"
  [ ! -e "$HOME/Library/LaunchAgents/$REPORT_LABEL.plist" ]
  [ ! -e "$HOME/Library/LaunchAgents/org.trellis.disk-janitor-apply.plist" ]
  [ ! -s "$LAUNCHCTL_LOG" ]
}

@test "caller PATH with a cmux shim under /var/folders and a missing directory drops both when writing tool-path" {
  local var_prefix="$SANDBOX/fake-var-folders"
  local shim_dir="$var_prefix/test-cmux-shim"
  local missing_dir="$SANDBOX/missing-dir"

  mkdir -p "$shim_dir" "$SANDBOX/isolated-tmp"
  # Put an executable tool in shim_dir (e.g. gh) so it WOULD be picked up if /var/folders case is deleted
  cat > "$shim_dir/gh" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 755 "$shim_dir/gh"

  TRELLIS_TEST_VAR_FOLDERS_PREFIX="$var_prefix" \
  TMPDIR="$SANDBOX/isolated-tmp" \
  INSTALLER_PATH="$shim_dir:$missing_dir:/usr/sbin:/usr/bin:/bin" run_installer

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$TRELLIS_HOME/state/disk-janitor/tool-path" ]
  [ "$(file_mode "$TRELLIS_HOME/state/disk-janitor/tool-path")" = "600" ]
  if grep -Fq "$shim_dir" "$TRELLIS_HOME/state/disk-janitor/tool-path"; then
    echo "ERROR: shim_dir found in tool-path: $shim_dir" >&2
    false
  fi
  ! grep -Fq "$missing_dir" "$TRELLIS_HOME/state/disk-janitor/tool-path"
  grep -Fq "/usr/sbin" "$TRELLIS_HOME/state/disk-janitor/tool-path"
}

@test "tool-path drops directories under TMPDIR including when reached via symlink and reads TRELLIS_ATTACH_CALLER_PATH" {
  local fixture_tmp="$SANDBOX/caller-tmp"
  local real_tool_in_tmp="$fixture_tmp/tools"
  local symlinked_tool_dir="$SANDBOX/symlink-to-tmp-tools"

  mkdir -p "$real_tool_in_tmp"
  ln -s "$real_tool_in_tmp" "$symlinked_tool_dir"

  # Place gh in the tmp dir (reached via symlink)
  cat > "$real_tool_in_tmp/gh" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 755 "$real_tool_in_tmp/gh"

  # Execute installer where PATH does NOT have /usr/sbin, but TRELLIS_ATTACH_CALLER_PATH does
  TMPDIR="$fixture_tmp" TRELLIS_ATTACH_CALLER_PATH="$symlinked_tool_dir:/usr/sbin:/usr/bin:/bin" \
  INSTALLER_PATH="/usr/bin:/bin" run_installer

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$TRELLIS_HOME/state/disk-janitor/tool-path" ]
  # Must NOT contain symlink into tmp or real tmp dir
  if grep -Fq "$symlinked_tool_dir" "$TRELLIS_HOME/state/disk-janitor/tool-path"; then
    echo "ERROR: symlinked_tool_dir found in tool-path: $symlinked_tool_dir" >&2
    false
  fi
  if grep -Fq "$real_tool_in_tmp" "$TRELLIS_HOME/state/disk-janitor/tool-path"; then
    echo "ERROR: real_tool_in_tmp found in tool-path: $real_tool_in_tmp" >&2
    false
  fi
  # Must contain /usr/sbin from TRELLIS_ATTACH_CALLER_PATH
  grep -Fq "/usr/sbin" "$TRELLIS_HOME/state/disk-janitor/tool-path"
}

@test "tool-path stores canonical (pwd -P) directory instead of symlink" {
  local real_tools symlink_tools isolated_tmp
  real_tools="$(mktemp -d /tmp/real-tools.XXXXXX)"
  real_tools="$(cd "$real_tools" && pwd -P)"
  isolated_tmp="$(mktemp -d /tmp/isolated-tmp.XXXXXX)"
  symlink_tools="/tmp/symlink-tools.$$"

  ln -s "$real_tools" "$symlink_tools"

  cat > "$real_tools/gh" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 755 "$real_tools/gh"

  TMPDIR="$isolated_tmp" \
  INSTALLER_PATH="$symlink_tools:/usr/bin:/bin" run_installer

  rm -rf "$real_tools" "$isolated_tmp" "$symlink_tools"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$TRELLIS_HOME/state/disk-janitor/tool-path" ]
  # Must contain canonical real_tools, NOT symlink_tools
  grep -Fq "$real_tools" "$TRELLIS_HOME/state/disk-janitor/tool-path"
  ! grep -Fq "$symlink_tools" "$TRELLIS_HOME/state/disk-janitor/tool-path"
}

@test "nightly apply argv contains only the approved safe set of scopes and flags" {
  local -a expected_argv
  local -a scopes=()
  local scope arg safe_only=false yes_flag=false dehydrate_flag=false apply_flag=false scopes_flag=false

  # Check DJ_AGENT_EXPECTED_ARGV from disk-janitor-agents.sh
  . "$REPO_ROOT/scripts/lib/disk-janitor-agents.sh"
  dj_agent_expected "org.trellis.disk-janitor-apply" "$HOME" "$TRELLIS_HOME"
  expected_argv=("${DJ_AGENT_EXPECTED_ARGV[@]}")

  # Parse the expected argv after disk-janitor
  local found_dj=false
  local i=0
  while [ "$i" -lt "${#expected_argv[@]}" ]; do
    arg="${expected_argv[$i]}"
    if [ "$found_dj" = true ]; then
      case "$arg" in
        --apply) apply_flag=true ;;
        --yes) yes_flag=true ;;
        --safe-only) safe_only=true ;;
        --dehydrate) dehydrate_flag=true ;;
        --scopes)
          scopes_flag=true
          i=$((i + 1))
          local raw_scopes="${expected_argv[$i]}"
          local old_ifs="$IFS"
          IFS=','
          # shellcheck disable=SC2206
          scopes=($raw_scopes)
          IFS="$old_ifs"
          ;;
        *)
          echo "forbidden or unexpected flag in nightly apply argv: $arg"
          false
          ;;
      esac
    elif [ "$arg" = "disk-janitor" ]; then
      found_dj=true
    fi
    i=$((i + 1))
  done

  [ "$apply_flag" = true ] || { echo "missing --apply"; false; }
  [ "$yes_flag" = true ] || { echo "missing --yes"; false; }
  [ "$safe_only" = true ] || { echo "missing --safe-only"; false; }
  [ "$dehydrate_flag" = true ] || { echo "missing --dehydrate"; false; }
  [ "$scopes_flag" = true ] || { echo "missing --scopes"; false; }

  # Validate scopes: must be a subset of safe set {worktrees, caches, releases, pi, tmp, docker}
  for scope in "${scopes[@]}"; do
    case "$scope" in
      worktrees|caches|releases|pi|tmp|docker) ;;
      *)
        echo "scope '$scope' is outside the safe set (worktrees, caches, releases, pi, tmp, docker)"
        false
        ;;
    esac
  done

  # Verify template plist matches the exact same safe argv
  local template_plist="$REPO_ROOT/core-rules/templates/org.trellis.disk-janitor-apply.plist"
  local -a template_args=()
  local count
  count="$(/usr/bin/plutil -extract ProgramArguments raw "$template_plist")"
  i=0
  while [ "$i" -lt "$count" ]; do
    template_args+=("$(/usr/bin/plutil -extract "ProgramArguments.$i" raw "$template_plist")")
    i=$((i + 1))
  done

  # Check that template ProgramArguments match the expected argv (with placeholders replaced)
  local rendered_expected
  for i in "${!expected_argv[@]}"; do
    rendered_expected="${expected_argv[$i]//"$HOME"/__USER_HOME__}"
    rendered_expected="${rendered_expected//"$TRELLIS_HOME"/__TRELLIS_HOME__}"
    [ "${template_args[$i]}" = "$rendered_expected" ] || {
      echo "template arg[$i] is '${template_args[$i]}', expected '$rendered_expected'"
      false
    }
  done
  [ "${#template_args[@]}" -eq "${#expected_argv[@]}" ]
}


