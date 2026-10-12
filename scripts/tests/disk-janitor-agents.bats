#!/usr/bin/env bats
# Spec 059 R3/R4: every org.trellis.disk-janitor*.plist must equal the launchd
# installer's expected ProgramArguments and schedule exactly. `trellis launchd`
# refuses to install beside a mismatching agent and `trellis doctor` reports it
# as an error; a name not ending in .plist is reported as disabled.
#
# Hermetic: HOME is a fresh sandbox operator home, so every LaunchAgents
# directory read or written here is a fixture under it; the real
# ~/Library/LaunchAgents is never touched. The installer runs through its sourced
# body with only the launchctl boundary replaced, exactly as
# install-disk-janitor-launchd.bats drives it. Doctor runs with a stub `docker`
# first on PATH so its container-runtime row never reaches a real Docker CLI.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/install-disk-janitor-launchd.sh"
DOCTOR="$REPO_ROOT/scripts/doctor.sh"
HEALTH_CHECKS="$REPO_ROOT/scripts/lib/health-checks.sh"
TEMPLATES="$REPO_ROOT/core-rules/templates"
APPLY_LABEL='org.trellis.disk-janitor-apply'
REPORT_LABEL='org.trellis.disk-janitor'

setup() {
  SANDBOX="$(mktemp -d "$BATS_TEST_TMPDIR/dj-agents.XXXXXX")"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME="$SANDBOX/operator-home"
  TRELLIS_HOME="$SANDBOX/trellis-home"
  AGENTS="$HOME/Library/LaunchAgents"
  LAUNCHCTL_LOG="$SANDBOX/launchctl.log"
  STUB_BIN="$SANDBOX/stub-bin"
  mkdir -p "$HOME/.local/bin" "$TRELLIS_HOME/releases/1.2.3/payload/scripts" "$AGENTS" "$STUB_BIN"
  chmod 700 "$TRELLIS_HOME"
  cat > "$TRELLIS_HOME/config.json" <<'EOF'
{"schema_version":1,"active_cli_release":"1.2.3"}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"
  printf '#!/bin/bash\nexit 0\n' > "$HOME/.local/bin/trellis"
  chmod 755 "$HOME/.local/bin/trellis"
  printf '#!/bin/sh\n[ "$1 $2" = "context show" ] && echo colima\nexit 0\n' > "$STUB_BIN/docker"
  chmod 755 "$STUB_BIN/docker"
  : > "$LAUNCHCTL_LOG"
  export HOME TRELLIS_HOME LAUNCHCTL_LOG
}

teardown() {
  [ -z "${SANDBOX:-}" ] || rm -rf "$SANDBOX"
}

run_installer() {
  run /usr/bin/env \
    HOME="$HOME" \
    TRELLIS_HOME="$TRELLIS_HOME" \
    TRELLIS_TEST_SKIP_JANITOR_DRY_RUN="${TRELLIS_TEST_SKIP_JANITOR_DRY_RUN:-}" \
    PATH="$PATH" \
    LAUNCHCTL_LOG="$LAUNCHCTL_LOG" \
    /bin/bash -c '
      installer="$1"
      shift
      . "$installer"
      launchctl_run() {
        printf "%s\t%s\n" "$1" "$2" >> "$LAUNCHCTL_LOG"
      }
      main "$@"
    ' _ "$INSTALLER" "$@"
}

run_agent_rows() {
  run /bin/bash -c 'TRELLIS_TEST_SKIP_JANITOR_DRY_RUN="${TRELLIS_TEST_SKIP_JANITOR_DRY_RUN:-}" . "$1"; hc_disk_janitor_agent_rows "$2" "$3"' \
    _ "$HEALTH_CHECKS" "$HOME" "$TRELLIS_HOME"
}

# A minimal portable machine home: enough for doctor to reach its host rows.
write_doctor_home() {
  mkdir -p "$SANDBOX/source" "$SANDBOX/projects"
  printf '{"schema_version":2,"harnesses":["claude"]}\n' > "$SANDBOX/source/trellis.config.json"
  cat > "$TRELLIS_HOME/config.json" <<EOF
{"schema_version":1,"source_root":"$SANDBOX/source","release_remote":"$SANDBOX/source","active_cli_release":"1.2.3","default_fleet":"personal","fleets":{"personal":{"discovery_roots":["$SANDBOX/projects"]}}}
EOF
  chmod 600 "$TRELLIS_HOME/config.json"
  printf '{"schema_version":1,"projects":{},"discovery_ignores":{}}\n' > "$TRELLIS_HOME/registry.json"
  chmod 600 "$TRELLIS_HOME/registry.json"
}

run_doctor() {
  run /usr/bin/env -u TRELLIS_CONFIG -u DOCKER_HOST HOME="$HOME" TRELLIS_HOME="$TRELLIS_HOME" \
    TRELLIS_TEST_SKIP_JANITOR_DRY_RUN="${TRELLIS_TEST_SKIP_JANITOR_DRY_RUN:-}" \
    PATH="$STUB_BIN:$PATH" bash "$DOCTOR"
}

doctor_error_count() {
  printf '%s\n' "$1" | sed -n 's/^✗ \([0-9][0-9]*\) error(s).*/\1/p'
}

# render_agent LABEL DEST — the plist exactly as the installer renders it.
render_agent() {
  sed -e "s|__USER_HOME__|$HOME|g" \
      -e "s|__TRELLIS_HOME__|$TRELLIS_HOME|g" \
    "$TEMPLATES/$1.plist" > "$2"
  chmod 600 "$2"
}

# mismatch_fixture KIND DEST — an apply agent that differs in one way.
mismatch_fixture() {
  local kind="$1" dest="$2"
  render_agent "$APPLY_LABEL" "$dest"
  case "$kind" in
    no-scopes)
      /usr/bin/plutil -remove ProgramArguments.14 "$dest"
      /usr/bin/plutil -remove ProgramArguments.14 "$dest"
      ;;
    docker-scope) /usr/bin/plutil -replace ProgramArguments.15 -string worktrees,docker "$dest" ;;
    extra-flag) /usr/bin/plutil -insert ProgramArguments.16 -string --verbose "$dest" ;;
    launcher-path) /usr/bin/plutil -replace ProgramArguments.8 -string "$HOME/bin/trellis" "$dest" ;;
    schedule) /usr/bin/plutil -replace StartCalendarInterval.Hour -integer 3 "$dest" ;;
    Sockets) /usr/bin/plutil -insert Sockets -json '{"Listeners":{"SockServiceName":"8080"}}' "$dest" ;;
    MachServices) /usr/bin/plutil -insert MachServices -json '{"org.trellis.disk-janitor.port":true}' "$dest" ;;
    LaunchEvents) /usr/bin/plutil -insert LaunchEvents -json '{"com.apple.notifyd.matching":{"wake":{"Notification":"com.apple.powermanagement.systempowerstate"}}}' "$dest" ;;
    OnDemand) /usr/bin/plutil -insert OnDemand -bool false "$dest" ;;
    Program) /usr/bin/plutil -insert Program -string /bin/sh "$dest" ;;
    BundleProgram) /usr/bin/plutil -insert BundleProgram -string Contents/MacOS/sh "$dest" ;;
    *) return 1 ;;
  esac
}

# assert_flagged KIND DETAIL — install refuses and doctor errors on the fixture.
assert_flagged() {
  local kind="$1" detail="$2" plist="$AGENTS/$APPLY_LABEL.plist" before baseline
  write_doctor_home
  run_doctor
  baseline="$(doctor_error_count "$output")"
  [ -n "$baseline" ] || { echo "$output"; false; }

  mismatch_fixture "$kind" "$plist"
  before="$SANDBOX/before.plist"
  cp "$plist" "$before"

  # Plain install selects only the report agent; the apply mismatch still blocks it.
  run_installer
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"refusing to install: $plist does not match the installer's expected arguments and schedule"* ]] || { echo "$output"; false; }
  [[ "$output" == *"$detail"* ]] || { echo "$output"; false; }
  [[ "$output" == *"remedy:"$'\n'"  launchctl bootout gui/\$(id -u) $plist; mv $plist $plist.disabled-\$(date +%Y%m%d)"$'\n'* ]] || { echo "$output"; false; }
  [[ "$output" == *$'\n'"trellis launchd: then re-run trellis launchd"* ]] || { echo "$output"; false; }
  cmp "$before" "$plist"
  # Refused before any write: the Logs directory the install would create is absent.
  [ ! -e "$HOME/Library/Logs" ]
  [ ! -e "$AGENTS/$REPORT_LABEL.plist" ]
  [ ! -s "$LAUNCHCTL_LOG" ]

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == $'1\tdisk-janitor agent: '"$plist does not match"*"$detail"* ]] || { echo "$output"; false; }

  run_doctor
  [ "$status" -ne 0 ]
  [[ "$output" == *"✗ disk-janitor agent: $plist does not match"* ]] || { echo "$output"; false; }
  [ "$(doctor_error_count "$output")" -eq $((baseline + 1)) ] || { echo "$output"; false; }
}

@test "installer-rendered agents match the shared expectation in install and doctor" {
  local apply="$AGENTS/$APPLY_LABEL.plist" report="$AGENTS/$REPORT_LABEL.plist"
  TRELLIS_TEST_SKIP_JANITOR_DRY_RUN=1 run_installer --with-apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$apply" ] && [ -f "$report" ]

  TRELLIS_TEST_SKIP_JANITOR_DRY_RUN=1 run_agent_rows
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '0\tdisk-janitor agent: %s matches the installer'"'"'s expected arguments and schedule\n0\tdisk-janitor agent: %s matches the installer'"'"'s expected arguments and schedule' "$apply" "$report")" ] ||
    { echo "$output"; false; }

  # An exact pre-existing apply agent does not block a reinstall.
  : > "$LAUNCHCTL_LOG"
  TRELLIS_TEST_SKIP_JANITOR_DRY_RUN=1 run_installer --with-apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" != *"refusing"* ]] || { echo "$output"; false; }

  write_doctor_home
  TRELLIS_TEST_SKIP_JANITOR_DRY_RUN=1 run_doctor
  [[ "$output" == *"✓ disk-janitor agent: $apply matches"* ]] || { echo "$output"; false; }
  [[ "$output" != *"✗ disk-janitor agent"* ]] || { echo "$output"; false; }
}

@test "legacy apply agent with no --scopes is refused by install and an error in doctor" {
  assert_flagged no-scopes "no --scopes: the janitor falls back to its default scopes"
}

@test "apply agent with worktrees,docker scopes is refused by install and an error in doctor" {
  assert_flagged docker-scope "ProgramArguments[15] is 'worktrees,docker', expected 'worktrees,caches,releases,pi,tmp,docker'"
}

@test "apply agent with an extra flag is refused by install and an error in doctor" {
  assert_flagged extra-flag "ProgramArguments has 17 entries, expected 16"
}

@test "apply agent with a different launcher path is refused by install and an error in doctor" {
  assert_flagged launcher-path "ProgramArguments[8] is '$HOME/bin/trellis', expected '$HOME/.local/bin/trellis'"
}

@test "apply agent with a different schedule is refused by install and an error in doctor" {
  assert_flagged schedule "schedule: Hour=3 Minute=0, expected Hour=4 Minute=0"
}

@test "apply agent whose Program overrides the executable is refused by install and an error in doctor" {
  assert_flagged Program "Program overrides the executable ProgramArguments names"
}

@test "apply agent whose BundleProgram overrides the executable is refused by install and an error in doctor" {
  assert_flagged BundleProgram "BundleProgram overrides the executable ProgramArguments names"
}

@test "a janitor plist under any other name is a mismatch, not ignored" {
  local plist="$AGENTS/org.trellis.disk-janitor-legacy.plist"
  render_agent "$APPLY_LABEL" "$plist"
  run_installer
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"$plist does not match"*"not an installer-managed agent name"* ]] || { echo "$output"; false; }
  run_agent_rows
  [[ "$output" == $'1\t'*"$plist does not match"* ]] || { echo "$output"; false; }
}

@test "a renamed .disabled-* agent is reported as disabled, not as an error" {
  local disabled="$AGENTS/$APPLY_LABEL.plist.disabled-20260928"
  mismatch_fixture docker-scope "$disabled"

  run_agent_rows
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '3\tdisk-janitor agent: %s is disabled (name does not end in .plist; launchd does not load it)' "$disabled")" ] ||
    { echo "$output"; false; }

  run_installer
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"note: disabled disk-janitor agent left in place: $disabled"* ]] || { echo "$output"; false; }
  [ -f "$disabled" ]

  write_doctor_home
  run_doctor
  [[ "$output" == *"i disk-janitor agent: $disabled is disabled"* ]] || { echo "$output"; false; }
  [[ "$output" != *"✗ disk-janitor agent"* ]] || { echo "$output"; false; }
}

@test "a renamed .disabled-* agent with missing EnvironmentVariables.PATH does not warn" {
  local disabled="$AGENTS/$APPLY_LABEL.plist.disabled-20260928"
  render_agent "$REPORT_LABEL" "$disabled"
  /usr/bin/plutil -insert EnvironmentVariables -json "{\"PATH\":\"/usr/bin:$SANDBOX/missing-disabled-dir\"}" "$disabled"

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'3\tdisk-janitor agent: '"$disabled is disabled"* ]] || { echo "$output"; false; }
  [[ "$output" != *"missing directory"* ]] || { echo "$output"; false; }

  write_doctor_home
  run_doctor
  [[ "$output" == *"i disk-janitor agent: $disabled is disabled"* ]] || { echo "$output"; false; }
  [[ "$output" != *"⚠ disk-janitor agent"* ]] || { echo "$output"; false; }
}

@test "no LaunchAgents directory reports none installed" {
  rm -rf "$HOME/Library"
  run_agent_rows
  [ "$status" -eq 0 ]
  [ "$output" = $'3\tdisk-janitor agents: none installed' ]
}

@test "an agent with any other launchd trigger is refused by install and an error in doctor" {
  local plist="$AGENTS/$APPLY_LABEL.plist" key
  for key in Sockets MachServices LaunchEvents OnDemand; do
    mismatch_fixture "$key" "$plist"
    run_installer
    [ "$status" -eq 3 ] || { echo "$key: $output"; false; }
    [[ "$output" == *"schedule: unexpected launch trigger $key"* ]] || { echo "$output"; false; }
    run_agent_rows
    [ "$output" = "$(printf '1\tdisk-janitor agent: %s does not match the installer'"'"'s expected arguments and schedule (schedule: unexpected launch trigger %s); remedy: %s\n3\tdisk-janitor agents: after the remedy, %s' \
      "$plist" "$key" "launchctl bootout gui/\$(id -u) $plist; mv $plist $plist.disabled-\$(date +%Y%m%d)" \
      'then re-run trellis launchd (add --with-apply for the nightly worktree agent, --with-pi-watchdog for the watchdog); trellis launchd --uninstall removes only agents that match the installer')" ] ||
      { echo "$output"; false; }
  done
}

# run_remedy LINE — run a printed remedy command as an operator would paste it,
# in the LaunchAgents directory, with launchctl recorded instead of called.
run_remedy() {
  run /bin/bash -c 'log="$1.launchctl"; launchctl() { printf "%s\n" "$@" > "$log"; }; cd "$2" && eval "$3"' \
    _ "$SANDBOX/remedy" "$AGENTS" "$1"
}

@test "the printed remedy renames exactly the flagged agent when its name needs quoting" {
  local name plist remedy
  name="org.trellis.disk-janitor-O'Brien \$(touch PWNED)"$'\n'"x.plist"
  plist="$AGENTS/$name"
  render_agent "$APPLY_LABEL" "$plist"

  run_agent_rows
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ] || { echo "$output"; false; }
  remedy="${output%%$'\n'*}"
  remedy="${remedy##*; remedy: }"
  run_remedy "$remedy"
  [ "$status" -eq 0 ] || { echo "$remedy: $output"; false; }
  [ ! -e "$plist" ]
  [ -f "$plist.disabled-$(date +%Y%m%d)" ]
  [ "$(cat "$SANDBOX/remedy.launchctl")" = "$(printf 'bootout\ngui/%s\n%s' "$(id -u)" "$plist")" ]
  [ ! -e "$AGENTS/PWNED" ] && [ ! -e "$SANDBOX/PWNED" ]

  run_agent_rows
  [[ "$output" == $'3\t'*"is disabled"* ]] || { echo "$output"; false; }
}

@test "a plist string holding a newline cannot forge a doctor row" {
  local plist="$AGENTS/$APPLY_LABEL.plist"
  render_agent "$APPLY_LABEL" "$plist"
  /usr/bin/plutil -replace ProgramArguments.9 -string "disk-janitor"$'\n0\tforged ok row' "$plist"

  run_agent_rows
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c .)" -eq 2 ] || { echo "$output"; false; }
  [[ "$output" == $'1\t'*"ProgramArguments[9] is 'disk-janitor\n0\tforged ok row', expected 'disk-janitor'"* ]] || { echo "$output"; false; }

  write_doctor_home
  run_doctor
  [[ "$output" != *"✓ forged"* ]] || { echo "$output"; false; }
}

@test "install and doctor agree when HOME and TRELLIS_HOME are reached through symlinks" {
  local apply="$AGENTS/$APPLY_LABEL.plist"
  ln -s "$HOME" "$SANDBOX/home-link"
  ln -s "$TRELLIS_HOME" "$SANDBOX/trellis-home-link"
  HOME="$SANDBOX/home-link" TRELLIS_HOME="$SANDBOX/trellis-home-link" TRELLIS_TEST_SKIP_JANITOR_DRY_RUN=1 run_installer --with-apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(/usr/bin/plutil -extract ProgramArguments.3 raw -o - "$apply")" = "TRELLIS_HOME=$TRELLIS_HOME" ]

  run /bin/bash -c 'export TRELLIS_TEST_SKIP_JANITOR_DRY_RUN=1; . "$1"; hc_disk_janitor_agent_rows "$2" "$3"' \
    _ "$HEALTH_CHECKS" "$SANDBOX/home-link" "$SANDBOX/trellis-home-link"
  [ "$status" -eq 0 ]
  [[ "$output" == $'0\t'*"$apply matches"*$'\n0\t'*"matches"* ]] || { echo "$output"; false; }

  HOME="$SANDBOX/home-link" TRELLIS_HOME="$SANDBOX/trellis-home-link" TRELLIS_TEST_SKIP_JANITOR_DRY_RUN=1 run_installer --with-apply
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "doctor warns when tool-path names a missing directory" {
  mkdir -p "$TRELLIS_HOME/state/disk-janitor"
  printf '%s\n' "$SANDBOX/missing-tool-dir" > "$TRELLIS_HOME/state/disk-janitor/tool-path"

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'2\tdisk-janitor tool-path: entry names a missing directory: '"$SANDBOX/missing-tool-dir"* ]] || { echo "$output"; false; }

  write_doctor_home
  run_doctor
  [[ "$output" == *"⚠ disk-janitor tool-path: entry names a missing directory: $SANDBOX/missing-tool-dir"* ]] || { echo "$output"; false; }
}

@test "doctor warns when tool-path lacks gh" {
  mkdir -p "$TRELLIS_HOME/state/disk-janitor" "$SANDBOX/valid-tools"
  # Put docker in valid-tools, but NOT gh
  cat > "$SANDBOX/valid-tools/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
  chmod 755 "$SANDBOX/valid-tools/docker"
  printf '%s\n' "$SANDBOX/valid-tools" > "$TRELLIS_HOME/state/disk-janitor/tool-path"

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'2\tdisk-janitor tool-path: lacks gh'* ]] || { echo "$output"; false; }

  write_doctor_home
  run_doctor
  [[ "$output" == *"⚠ disk-janitor tool-path: lacks gh"* ]] || { echo "$output"; false; }
}

@test "doctor flags agent plists specifying docker volume/image/container removal" {
  local plist="$AGENTS/org.trellis.disk-janitor-bad.plist"
  render_agent "$REPORT_LABEL" "$plist"
  /usr/bin/plutil -insert ProgramArguments.10 -string "volume rm" "$plist"

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tdisk-janitor agent: '"$plist"*"flags docker volume/image/container removal"* || \
     "$output" == *$'1\tdisk-janitor agent: '"$plist"*"forbidden docker"* ]] || { echo "$output"; false; }
}

@test "doctor flags extended denylist: docker image rm, container rm, compose rm, compose down -v" {
  local plist="$AGENTS/org.trellis.disk-janitor-bad.plist"
  local cmd
  for cmd in "image rm" "container rm" "compose rm" "compose down -v"; do
    render_agent "$REPORT_LABEL" "$plist"
    /usr/bin/plutil -insert ProgramArguments.10 -string "$cmd" "$plist"
    run_agent_rows
    [ "$status" -eq 0 ]
    [[ "$output" == *$'1\tdisk-janitor agent: '"$plist"*"flags docker volume/image/container removal"* || \
       "$output" == *$'1\tdisk-janitor agent: '"$plist"*"contains forbidden docker"* ]] || {
      echo "Failed to flag '$cmd': $output"
      false
    }
  done
}

@test "rendered apply agent matches: nightly argv dry-run passes against landed scopes" {
  local plist="$AGENTS/$APPLY_LABEL.plist"
  render_agent "$APPLY_LABEL" "$plist"
  write_doctor_home

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'0\tdisk-janitor agent: '"$plist matches"* ]] || { echo "$output"; false; }

  run_doctor
  [[ "$output" == *"✓ disk-janitor agent: $plist matches"* ]] || { echo "$output"; false; }
}

@test "doctor warns when a legacy plist PATH names a missing directory" {
  local plist="$AGENTS/org.trellis.disk-janitor.plist"
  render_agent "$REPORT_LABEL" "$plist"
  /usr/bin/plutil -insert EnvironmentVariables -json "{\"PATH\":\"/usr/bin:$SANDBOX/missing-legacy-dir\"}" "$plist"

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'2\tdisk-janitor agent: '"$plist EnvironmentVariables.PATH names a missing directory: $SANDBOX/missing-legacy-dir"* ]] || { echo "$output"; false; }

  write_doctor_home
  run_doctor
  [[ "$output" == *"⚠ disk-janitor agent: $plist EnvironmentVariables.PATH names a missing directory: $SANDBOX/missing-legacy-dir"* ]] || { echo "$output"; false; }
}

@test "installer renders watchdog agent matching shared expectation in install and doctor" {
  local watchdog="$AGENTS/org.trellis.pi-spill-watchdog.plist"
  run_installer --with-pi-watchdog
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$watchdog" ]

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *"disk-janitor agent: $watchdog matches the installer's expected arguments and schedule"* ]] ||
    { echo "$output"; false; }

  write_doctor_home
  run_doctor
  [[ "$output" == *"✓ disk-janitor agent: $watchdog matches"* ]] || { echo "$output"; false; }
  [[ "$output" != *"✗ disk-janitor agent"* ]] || { echo "$output"; false; }
}

@test "watchdog agent with incorrect StartInterval is reported as mismatch" {
  local watchdog="$AGENTS/org.trellis.pi-spill-watchdog.plist"
  render_agent "org.trellis.pi-spill-watchdog" "$watchdog"
  /usr/bin/plutil -replace StartInterval -integer 120 "$watchdog"

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tdisk-janitor agent: '"$watchdog does not match"*"schedule: StartInterval is 120, expected 60"* ]] || { echo "$output"; false; }

  run_installer
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"refusing to install: $watchdog does not match"* ]] || { echo "$output"; false; }
}

@test "watchdog agent pointing to versioned payload script is reported as mismatch in doctor" {
  local watchdog="$AGENTS/org.trellis.pi-spill-watchdog.plist"
  render_agent "org.trellis.pi-spill-watchdog" "$watchdog"
  # Replace ProgramArguments.7 with a version-pinned script
  /usr/bin/plutil -replace ProgramArguments.7 -string "$TRELLIS_HOME/releases/1.2.3/payload/scripts/pi-spill-watchdog.sh" "$watchdog"

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'1\tdisk-janitor agent: '"$watchdog does not match"*"ProgramArguments[7]"* ]] || { echo "$output"; false; }

  run_installer
  [ "$status" -eq 3 ] || { echo "$output"; false; }
  [[ "$output" == *"refusing to install: $watchdog does not match"* ]] || { echo "$output"; false; }
}

@test "doctor reports watchdog agent as degraded when entry point bytes or mode mismatch" {
  local watchdog="$AGENTS/org.trellis.pi-spill-watchdog.plist"
  local entry="$TRELLIS_HOME/state/disk-janitor/pi-spill-watchdog"
  run_installer --with-pi-watchdog
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$watchdog" ]
  [ -f "$entry" ]

  # Healthy baseline in doctor
  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *"disk-janitor agent: $watchdog matches the installer's expected arguments and schedule"* ]] || { echo "$output"; false; }

  # Tamper with entry point
  chmod 700 "$entry"
  printf '#!/bin/sh\necho EVIL\n' > "$entry"
  chmod 755 "$entry"

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'2\tdisk-janitor agent: '"$watchdog is degraded"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis launchd --with-pi-watchdog"* ]] || { echo "$output"; false; }

  write_doctor_home
  run_doctor
  [[ "$output" == *"⚠ disk-janitor agent: $watchdog is degraded"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis launchd --with-pi-watchdog"* ]] || { echo "$output"; false; }
}

@test "doctor reports watchdog agent as degraded when entry point mode is not 0500" {
  local watchdog="$AGENTS/org.trellis.pi-spill-watchdog.plist"
  local entry="$TRELLIS_HOME/state/disk-janitor/pi-spill-watchdog"
  run_installer --with-pi-watchdog
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  chmod 755 "$entry"

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'2\tdisk-janitor agent: '"$watchdog is degraded"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis launchd --with-pi-watchdog"* ]] || { echo "$output"; false; }
}

@test "doctor reports degraded when watchdog entry point is tampered without plist in LaunchAgents" {
  local entry="$TRELLIS_HOME/state/disk-janitor/pi-spill-watchdog"
  mkdir -p "$TRELLIS_HOME/state/disk-janitor"
  printf '#!/bin/sh\necho EVIL\n' > "$entry"
  chmod 755 "$entry"

  run_agent_rows
  [ "$status" -eq 0 ]
  [[ "$output" == *$'2\tdisk-janitor agent: '"$entry is degraded"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis launchd --with-pi-watchdog"* ]] || { echo "$output"; false; }

  write_doctor_home
  run_doctor
  [[ "$output" == *"⚠ disk-janitor agent: $entry is degraded"* ]] || { echo "$output"; false; }
  [[ "$output" == *"trellis launchd --with-pi-watchdog"* ]] || { echo "$output"; false; }
}


