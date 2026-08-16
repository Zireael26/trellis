#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
CONFIGURE="$ROOT/scripts/configure.sh"
HOME_LIB="$ROOT/scripts/lib/trellis-home.sh"
VALID_MACHINE="$ROOT/scripts/tests/fixtures/local-fleets/valid-machine-personal-work-a.json"
MACHINE_SCHEMA="$ROOT/scripts/lib/trellis.machine.schema.json"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  TRELLIS_HOME_DIR="$SANDBOX/home"
  SOURCE="$SANDBOX/source"
  PROJECTS="$SANDBOX/projects"
  export HOME="$SANDBOX/operator-home"
  WORK_ROOT="$SANDBOX/work projects"
  LIVE_LOCK_PID=""
  unset TRELLIS_HOME TRELLIS_FLEET TRELLIS_RELEASE TRELLIS_SOURCE_ROOT

  mkdir -p "$HOME" "$SOURCE/core-rules" "$PROJECTS" "$WORK_ROOT"
  printf '{}\n' > "$SOURCE/trellis.config.json"
  printf '1.2.3\n' > "$SOURCE/core-rules/VERSION"
}

teardown() {
  if [ -n "${LIVE_LOCK_PID:-}" ]; then
    kill "$LIVE_LOCK_PID" 2>/dev/null || true
    wait "$LIVE_LOCK_PID" 2>/dev/null || true
  fi
  if [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
}

validate_config() {
  run bash -c '. "$1"; trellis_home_validate_config "$2"' _ "$HOME_LIB" "$1"
}

schema_path_accepts() {
  run python3 -c '
import json
import re
import sys

schema = json.load(open(sys.argv[1], encoding="utf-8"))["$defs"]["absoluteSafePath"]
value = sys.argv[2]
accepted = (
    isinstance(value, str)
    and len(value) >= schema["minLength"]
    and re.search(schema["pattern"], value) is not None
    and re.search(schema["not"]["pattern"], value) is None
)
raise SystemExit(0 if accepted else 1)
' "$MACHINE_SCHEMA" "$1"
}

file_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}

configure_no_launcher() {
  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$TRELLIS_HOME_DIR" \
    --default-fleet personal \
    --discovery-root "$PROJECTS" \
    --no-install-launcher
}

@test "configure writes local machine config when launcher installation is explicitly skipped" {
  configure_no_launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Launcher: skipped"* ]] || { echo "$output"; false; }

  jq -e --arg source "$SOURCE" --arg projects "$PROJECTS" '
    .source_root == $source
    and .active_cli_release == "1.2.3"
    and .default_fleet == "personal"
    and .fleets.personal.discovery_roots == [$projects]
  ' "$TRELLIS_HOME_DIR/config.json" >/dev/null
}

@test "configure honors explicit precedence and preserves roots when its source moves" {
  local env_source moved_source env_home
  env_source="$SANDBOX/source from environment"
  moved_source="$SANDBOX/moved source"
  env_home="$SANDBOX/environment home"
  mkdir -p "$env_source/core-rules" "$moved_source/core-rules"
  printf '{}\n' > "$env_source/trellis.config.json"
  printf '9.9.9\n' > "$env_source/core-rules/VERSION"
  printf '{}\n' > "$moved_source/trellis.config.json"
  printf '7.8.9\n' > "$moved_source/core-rules/VERSION"

  run env \
    TRELLIS_HOME="$env_home" \
    TRELLIS_SOURCE_ROOT="$env_source" \
    TRELLIS_FLEET=environment \
    TRELLIS_RELEASE=9.9.9 \
    bash "$CONFIGURE" \
      --source "$SOURCE" \
      --home "$TRELLIS_HOME_DIR" \
      --default-fleet cli \
      --active-cli-release 4.5.6 \
      --discovery-root "$PROJECTS" \
      --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$env_home/config.json" ]
  jq -e --arg source "$SOURCE" --arg root "$PROJECTS" '
    .source_root == $source
    and .active_cli_release == "4.5.6"
    and .default_fleet == "cli"
    and .fleets.cli.discovery_roots == [$root]
  ' "$TRELLIS_HOME_DIR/config.json" >/dev/null

  run bash "$CONFIGURE" \
    --source "$moved_source" \
    --home "$TRELLIS_HOME_DIR" \
    --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e --arg source "$moved_source" --arg root "$PROJECTS" '
    .source_root == $source
    and .active_cli_release == "4.5.6"
    and .default_fleet == "cli"
    and .fleets.cli.discovery_roots == [$root]
  ' "$TRELLIS_HOME_DIR/config.json" >/dev/null
}

@test "machine config validation rejects extra keys and control characters" {
  local cfg="$SANDBOX/config.json"

  cp "$VALID_MACHINE" "$cfg"
  validate_config "$cfg"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  jq '.unexpected = true' "$VALID_MACHINE" > "$cfg"
  validate_config "$cfg"
  [ "$status" -eq 4 ]

  jq '.fleets.personal.unexpected = true' "$VALID_MACHINE" > "$cfg"
  validate_config "$cfg"
  [ "$status" -eq 4 ]

  jq --arg remote $'git@example.com:org/repo.git\nignored' \
    '.release_remote = $remote' "$VALID_MACHINE" > "$cfg"
  validate_config "$cfg"
  [ "$status" -eq 4 ]

  jq --arg path $'/tmp/tab\troot' \
    '.fleets.personal.discovery_roots = [$path]' "$VALID_MACHINE" > "$cfg"
  validate_config "$cfg"
  [ "$status" -eq 4 ]

  jq --arg path $'/tmp/newline\nroot' \
    '.source_root = $path' "$VALID_MACHINE" > "$cfg"
  validate_config "$cfg"
  [ "$status" -eq 4 ]

  jq '.source_root = "/tmp/nul\u0000root"' "$VALID_MACHINE" > "$cfg"
  validate_config "$cfg"
  [ "$status" -eq 4 ]

  jq '.source_root = "//tmp/source"' "$VALID_MACHINE" > "$cfg"
  validate_config "$cfg"
  [ "$status" -eq 4 ]

  jq '.fleets.personal.discovery_roots = ["/tmp/./projects"]' "$VALID_MACHINE" > "$cfg"
  validate_config "$cfg"
  [ "$status" -eq 4 ]

  jq '.fleets.personal.shared_infra_root = "/tmp/../shared-infra"' "$VALID_MACHINE" > "$cfg"
  validate_config "$cfg"
  [ "$status" -eq 4 ]
}

@test "machine schema absolute-path regex matches runtime safe-path rules" {
  schema_path_accepts "/Volumes/Work Drive/checkouts"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  schema_path_accepts "//tmp/projects"
  [ "$status" -eq 1 ]

  schema_path_accepts "/tmp/./projects"
  [ "$status" -eq 1 ]

  schema_path_accepts "/tmp/../projects"
  [ "$status" -eq 1 ]

  schema_path_accepts $'/tmp/control\tprojects'
  [ "$status" -eq 1 ]
}

@test "home directories and machine config are private and repaired on validation" {
  configure_no_launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  [ "$(file_mode "$TRELLIS_HOME_DIR")" = "700" ]
  [ "$(file_mode "$TRELLIS_HOME_DIR/locks")" = "700" ]
  [ "$(file_mode "$TRELLIS_HOME_DIR/state")" = "700" ]
  [ "$(file_mode "$TRELLIS_HOME_DIR/releases")" = "700" ]
  [ "$(file_mode "$TRELLIS_HOME_DIR/config.json")" = "600" ]

  chmod 777 "$TRELLIS_HOME_DIR/config.json"
  validate_config "$TRELLIS_HOME_DIR/config.json"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(file_mode "$TRELLIS_HOME_DIR/config.json")" = "600" ]
}

@test "locks reject unsafe names, preserve foreign contents, and recover only dead recorded PIDs" {
  local stale_pid_copy foreign_copy
  stale_pid_copy="$SANDBOX/stale-pid.before"
  foreign_copy="$SANDBOX/foreign.before"
  run bash -c '. "$1"; trellis_home_prepare_home "$2"; trellis_home_lock_acquire "$2" "../config" 0' \
    _ "$HOME_LIB" "$TRELLIS_HOME_DIR"
  [ "$status" -eq 2 ]
  [ ! -e "$TRELLIS_HOME_DIR/config.lock" ]

  mkdir -p "$TRELLIS_HOME_DIR/locks/config.lock"
  printf '999999999\n' > "$TRELLIS_HOME_DIR/locks/config.lock/pid"
  run bash -c '. "$1"; trellis_home_lock_acquire "$2" config 0; code=$?; [ "$code" -eq 0 ] || exit "$code"; trellis_home_lock_release' \
    _ "$HOME_LIB" "$TRELLIS_HOME_DIR"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -d "$TRELLIS_HOME_DIR/locks/config.lock" ]

  mkdir -p "$TRELLIS_HOME_DIR/locks/config.lock"
  printf 'not-a-pid\n' > "$TRELLIS_HOME_DIR/locks/config.lock/pid"
  run bash -c '. "$1"; trellis_home_lock_acquire "$2" config 0' \
    _ "$HOME_LIB" "$TRELLIS_HOME_DIR"
  [ "$status" -eq 4 ]
  [ -d "$TRELLIS_HOME_DIR/locks/config.lock" ]
  rm -rf "$TRELLIS_HOME_DIR/locks/config.lock"

  mkdir -p "$TRELLIS_HOME_DIR/locks/config.lock"
  printf '999999999\n' > "$TRELLIS_HOME_DIR/locks/config.lock/pid"
  printf 'do not delete\n' > "$TRELLIS_HOME_DIR/locks/config.lock/foreign"
  cp "$TRELLIS_HOME_DIR/locks/config.lock/pid" "$stale_pid_copy"
  cp "$TRELLIS_HOME_DIR/locks/config.lock/foreign" "$foreign_copy"
  run bash -c '. "$1"; trellis_home_lock_acquire "$2" config 0' \
    _ "$HOME_LIB" "$TRELLIS_HOME_DIR"
  [ "$status" -eq 4 ]
  cmp -s "$stale_pid_copy" "$TRELLIS_HOME_DIR/locks/config.lock/pid"
  cmp -s "$foreign_copy" "$TRELLIS_HOME_DIR/locks/config.lock/foreign"
  rm -rf "$TRELLIS_HOME_DIR/locks/config.lock"

  run bash -c '. "$1"; trellis_home_lock_acquire "$2" config 0 || exit "$?"; printf "999999999\n" > "$2/locks/config.lock/pid"; trellis_home_lock_release' \
    _ "$HOME_LIB" "$TRELLIS_HOME_DIR"
  [ "$status" -eq 4 ]
  [ -d "$TRELLIS_HOME_DIR/locks/config.lock" ]
  rm -rf "$TRELLIS_HOME_DIR/locks/config.lock"

  sleep 30 &
  LIVE_LOCK_PID="$!"
  mkdir -p "$TRELLIS_HOME_DIR/locks/config.lock"
  printf '%s\n' "$LIVE_LOCK_PID" > "$TRELLIS_HOME_DIR/locks/config.lock/pid"

  run bash -c '. "$1"; trellis_home_lock_acquire "$2" config 0' \
    _ "$HOME_LIB" "$TRELLIS_HOME_DIR"
  [ "$status" -eq 4 ]
  [ -d "$TRELLIS_HOME_DIR/locks/config.lock" ]
  [ "$(sed -n '1p' "$TRELLIS_HOME_DIR/locks/config.lock/pid")" = "$LIVE_LOCK_PID" ]
}

@test "an initializing lock is retried until its directory becomes available" {
  run bash -c '
    . "$1"
    trellis_home_prepare_home "$2" || exit "$?"
    mkdir "$2/locks/config.lock" || exit "$?"
    (sleep 1; rmdir "$2/locks/config.lock") &
    remover="$!"
    trellis_home_lock_acquire "$2" config 3
    code="$?"
    wait "$remover"
    [ "$code" -eq 0 ] || exit "$code"
    trellis_home_lock_release
  ' _ "$HOME_LIB" "$TRELLIS_HOME_DIR"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -d "$TRELLIS_HOME_DIR/locks/config.lock" ]
}

@test "configure rejects a newline-bearing discovery root as one unsafe argument" {
  local bad_root="$PROJECTS"$'\n'"/tmp/trellis-bypass"

  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$TRELLIS_HOME_DIR" \
    --discovery-root "$bad_root" \
    --no-install-launcher
  [ "$status" -eq 2 ]
  [[ "$output" == *"discovery root contains terminal control characters"* ]] || { echo "$output"; false; }
  [ ! -f "$TRELLIS_HOME_DIR/config.json" ]
}

@test "configure canonicalizes a non-canonical home instead of persisting one later dispatches reject" {
  # The launcher's own home test rejects any embedded `//`, so a configure that
  # accepted one would exit 0 and strand the machine.
  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$SANDBOX//home" \
    --default-fleet personal \
    --discovery-root "$PROJECTS" \
    --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Configured Trellis home: $TRELLIS_HOME_DIR"$'\n'* ]] || { echo "$output"; false; }
  [ -f "$TRELLIS_HOME_DIR/config.json" ]
  jq -e --arg root "$PROJECTS" '.fleets.personal.discovery_roots == [$root]' \
    "$TRELLIS_HOME_DIR/config.json" >/dev/null

  # A trailing separator resolves to the same home rather than a second one.
  run bash "$CONFIGURE" fleet add work \
    --home "$TRELLIS_HOME_DIR/" \
    --discovery-root "$WORK_ROOT"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '.fleets | has("personal") and has("work")' "$TRELLIS_HOME_DIR/config.json" >/dev/null

  # A symlinked ancestor is resolved to the real directory it names.
  mkdir -p "$SANDBOX/real base"
  ln -s "$SANDBOX/real base" "$SANDBOX/linked base"
  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$SANDBOX/linked base/home" \
    --discovery-root "$PROJECTS" \
    --no-install-launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -f "$SANDBOX/real base/home/config.json" ]
  [[ "$output" == *"Configured Trellis home: $SANDBOX/real base/home"$'\n'* ]] || { echo "$output"; false; }
}

@test "configure refuses a home it cannot canonicalize and writes nothing" {
  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$SANDBOX/nested/../home" \
    --discovery-root "$PROJECTS" \
    --no-install-launcher
  [ "$status" -eq 2 ]
  [[ "$output" == *"TRELLIS_HOME must not contain . or .. path components"* ]] || { echo "$output"; false; }
  [ ! -f "$TRELLIS_HOME_DIR/config.json" ]

  ln -s "$PROJECTS" "$SANDBOX/home link"
  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$SANDBOX/home link" \
    --discovery-root "$PROJECTS" \
    --no-install-launcher
  [ "$status" -eq 4 ]
  [[ "$output" == *"TRELLIS_HOME must not be a symlink"* ]] || { echo "$output"; false; }
  [ ! -f "$PROJECTS/config.json" ]

  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "//" \
    --discovery-root "$PROJECTS" \
    --no-install-launcher
  [ "$status" -eq 2 ]
  [ ! -f "$TRELLIS_HOME_DIR/config.json" ]
}

@test "fleet add and update use conflict exits for existing or missing fleets" {
  configure_no_launcher
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run bash "$CONFIGURE" fleet add personal \
    --home "$TRELLIS_HOME_DIR" \
    --discovery-root "$WORK_ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"fleet already exists: personal"* ]] || { echo "$output"; false; }

  run bash "$CONFIGURE" fleet update work \
    --home "$TRELLIS_HOME_DIR" \
    --discovery-root "$WORK_ROOT"
  [ "$status" -eq 3 ]
  [[ "$output" == *"fleet does not exist: work"* ]] || { echo "$output"; false; }

  run bash "$CONFIGURE" fleet add work \
    --home "$TRELLIS_HOME_DIR" \
    --discovery-root "$WORK_ROOT" \
    --make-default
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  run bash "$CONFIGURE" fleet update work \
    --home "$TRELLIS_HOME_DIR" \
    --shared-infra-root "$SANDBOX/shared infra"
  [ "$status" -eq 0 ] || { echo "$output"; false; }

  jq -e --arg root "$WORK_ROOT" --arg shared "$SANDBOX/shared infra" '
    .default_fleet == "work"
    and .fleets.work.discovery_roots == [$root]
    and .fleets.work.shared_infra_root == $shared
  ' "$TRELLIS_HOME_DIR/config.json" >/dev/null

  run bash "$CONFIGURE" fleet set-default personal --home "$TRELLIS_HOME_DIR"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  jq -e '.default_fleet == "personal"' "$TRELLIS_HOME_DIR/config.json" >/dev/null
}

@test "missing default launcher template is unavailable, not corrupt state" {
  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$TRELLIS_HOME_DIR"
  [ "$status" -eq 5 ]
  [[ "$output" == *"launcher template not found"* ]] || { echo "$output"; false; }
  [ ! -f "$TRELLIS_HOME_DIR/config.json" ]
}

@test "configure rejects the retired custom launcher destination" {
  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$TRELLIS_HOME_DIR" \
    --launcher-bin "$SANDBOX/foreign-bin/trellis"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option for configure: --launcher-bin"* ]] || { echo "$output"; false; }
  [ ! -e "$TRELLIS_HOME_DIR/config.json" ]
  [ ! -e "$HOME/.local/bin/trellis" ]
}

@test "an existing non-regular config blocks launcher mutation" {
  local template launcher
  template="$SOURCE/scripts/trellis-launcher.sh"
  launcher="$HOME/.local/bin/trellis"
  mkdir -p "$SOURCE/scripts" "$TRELLIS_HOME_DIR"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$template"
  chmod 755 "$template"
  mkdir "$TRELLIS_HOME_DIR/config.json"

  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$TRELLIS_HOME_DIR" \
    --discovery-root "$PROJECTS" \
    --launcher-template "$template"
  [ "$status" -eq 4 ]
  [ -d "$TRELLIS_HOME_DIR/config.json" ]
  [ ! -e "$launcher" ]
}

@test "launcher installation is 0755, byte-idempotent, and rejects a nonmatching destination" {
  local template launcher checksum
  template="$SOURCE/scripts/trellis-launcher.sh"
  launcher="$HOME/.local/bin/trellis"
  mkdir -p "$SOURCE/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$template"
  chmod 755 "$template"

  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$TRELLIS_HOME_DIR" \
    --discovery-root "$PROJECTS" \
    --launcher-template "$template"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(file_mode "$launcher")" = "755" ]
  run cmp -s "$template" "$launcher"
  [ "$status" -eq 0 ]
  checksum="$(shasum -a 256 "$launcher" | awk '{print $1}')"

  chmod 644 "$launcher"
  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$TRELLIS_HOME_DIR" \
    --launcher-template "$template"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"Launcher: retained at $launcher"* ]] || { echo "$output"; false; }
  [ "$(file_mode "$launcher")" = "755" ]
  [ "$(shasum -a 256 "$launcher" | awk '{print $1}')" = "$checksum" ]

  printf 'foreign launcher\n' > "$launcher"
  run bash "$CONFIGURE" \
    --source "$SOURCE" \
    --home "$TRELLIS_HOME_DIR" \
    --active-cli-release 2.0.0 \
    --launcher-template "$template"
  [ "$status" -eq 3 ]
  [ "$(cat "$launcher")" = "foreign launcher" ]
  jq -e '.active_cli_release == "1.2.3"' "$TRELLIS_HOME_DIR/config.json" >/dev/null
}

@test "atomic no-replace launcher publish keeps a competing destination intact" {
  local tmp launcher
  launcher="$SANDBOX/bin/trellis"
  tmp="$SANDBOX/bin/.trellis.launcher.tmp"
  mkdir -p "$SANDBOX/bin"
  printf 'new launcher\n' > "$tmp"
  printf 'competing launcher\n' > "$launcher"

  run bash -c '. "$1"; trellis_home_publish_file_noreplace "$2" "$3"' \
    _ "$HOME_LIB" "$tmp" "$launcher"
  [ "$status" -eq 3 ]
  [ "$(cat "$launcher")" = "competing launcher" ]
  [ ! -e "$tmp" ]
}
