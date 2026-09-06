#!/usr/bin/env bats

ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
LOADER="$ROOT/scripts/lib/config-load.sh"

setup() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
  HOME_DIR="$SANDBOX/home"
  TRELLIS_HOME_DIR="$HOME_DIR/.trellis"
  POLICY_ROOT="$SANDBOX/policy source"
  POLICY="$POLICY_ROOT/trellis.config.json"
  PERSONAL_ROOT="$SANDBOX/personal projects"
  PERSONAL_SECOND_ROOT="$SANDBOX/personal projects second"
  WORK_ROOT="$SANDBOX/work projects"
  PERSONAL_INFRA="$SANDBOX/personal infra"
  WORK_INFRA="$SANDBOX/work infra"

  mkdir -p "$TRELLIS_HOME_DIR" "$POLICY_ROOT" "$PERSONAL_ROOT" \
    "$PERSONAL_SECOND_ROOT" "$WORK_ROOT" "$PERSONAL_INFRA" "$WORK_INFRA"
  chmod 700 "$TRELLIS_HOME_DIR"
  write_policy "$POLICY" "Portable Maintainer" "portable-user"
  write_machine
  unset TRELLIS_CONFIG TRELLIS_HOME TRELLIS_FLEET TRELLIS_RELEASE TRELLIS_SOURCE_ROOT
}

teardown() {
  [ -n "${SANDBOX:-}" ] && [ -d "$SANDBOX" ] && rm -rf "$SANDBOX"
}
file_mode() {
  case "$(uname -s)" in
    Darwin) stat -f '%Lp' "$1" ;;
    *) stat -c '%a' "$1" ;;
  esac
}


write_policy() {
  local file maintainer github_user
  file="$1"
  maintainer="$2"
  github_user="$3"

  jq -n \
    --arg maintainer "$maintainer" \
    --arg github_user "$github_user" \
    '{
      schema_version: 2,
      maintainer_name: $maintainer,
      github_user: $github_user,
      harnesses: ["claude", "codex"],
      template: {remote: "https://example.invalid/trellis.git", branch: "main"},
      trellis_version: "1.2.3",
      sed_flavor: "auto"
    }' > "$file"
}

write_machine() {
  jq -n \
    --arg source "$POLICY_ROOT" \
    --arg personal "$PERSONAL_ROOT" \
    --arg work "$WORK_ROOT" \
    --arg personal_infra "$PERSONAL_INFRA" \
    --arg work_infra "$WORK_INFRA" \
    '{
      schema_version: 1,
      source_root: $source,
      release_remote: "https://example.invalid/trellis.git",
      active_cli_release: "1.2.3",
      default_fleet: "personal",
      fleets: {
        personal: {
          discovery_roots: [$personal],
          shared_infra_root: $personal_infra
        },
        work: {
          discovery_roots: [$work],
          shared_infra_root: $work_infra
        }
      }
    }' > "$TRELLIS_HOME_DIR/config.json"
}

run_loader() {
  local policy fleet
  policy="$1"
  fleet="${2:-}"

  if [ -n "$fleet" ]; then
    run env \
      HOME="$HOME_DIR" \
      TRELLIS_HOME="$TRELLIS_HOME_DIR" \
      TRELLIS_CONFIG="$policy" \
      TRELLIS_FLEET="$fleet" \
      bash -c '
        . "$1"
        status=$?
        [ "$status" -eq 0 ] || exit "$status"
        printf "policy=%s\\n" "$TRELLIS_CONFIG_PATH"
        printf "home_config=%s\\n" "$TRELLIS_HOME_CONFIG"
        printf "source=%s\\n" "$TRELLIS_SOURCE_ROOT"
        printf "release=%s\\n" "$TRELLIS_ACTIVE_RELEASE"
        printf "fleet=%s\\n" "$TRELLIS_FLEET_NAME"
        printf "harnesses=%s\\n" "${HARNESSES[*]}"
        printf "maintainer=%s\\n" "$MAINTAINER_NAME"
        printf "template=%s@%s\\n" "$TEMPLATE_REMOTE" "$TEMPLATE_BRANCH"
        printf "sed=%s\\n" "$SED_FLAVOR"
        printf "style=%s\n" "$SYMLINK_STYLE"
        printf "roots_count=%s\n" "${#TRELLIS_DISCOVERY_ROOTS[@]}"
        for discovery_root in "${TRELLIS_DISCOVERY_ROOTS[@]}"; do
          printf "discovery_root=%s\n" "$discovery_root"
        done
        printf "roots_json=%s\nfleet_local=%s\ninfra_available=%s\n" \
          "$TRELLIS_DISCOVERY_ROOTS_JSON" "$TRELLIS_FLEET_LOCAL_JSON" "$SHARED_INFRA_ROOT_AVAILABLE"
        printf "root=%s\\nprojects=%s\\ninfra=%s\\nhome=%s\\n" \
          "${TRELLIS_ROOT-<unset>}" "$PROJECTS_ROOT" "$SHARED_INFRA_ROOT" "$USER_HOME"
      ' _ "$LOADER"
  else
    run env \
      HOME="$HOME_DIR" \
      TRELLIS_HOME="$TRELLIS_HOME_DIR" \
      TRELLIS_CONFIG="$policy" \
      bash -c '
        . "$1"
        status=$?
        [ "$status" -eq 0 ] || exit "$status"
        printf "policy=%s\\n" "$TRELLIS_CONFIG_PATH"
        printf "home_config=%s\\n" "$TRELLIS_HOME_CONFIG"
        printf "source=%s\\n" "$TRELLIS_SOURCE_ROOT"
        printf "release=%s\\n" "$TRELLIS_ACTIVE_RELEASE"
        printf "fleet=%s\\n" "$TRELLIS_FLEET_NAME"
        printf "harnesses=%s\\n" "${HARNESSES[*]}"
        printf "maintainer=%s\\n" "$MAINTAINER_NAME"
        printf "template=%s@%s\\n" "$TEMPLATE_REMOTE" "$TEMPLATE_BRANCH"
        printf "sed=%s\\n" "$SED_FLAVOR"
        printf "style=%s\n" "$SYMLINK_STYLE"
        printf "roots_count=%s\n" "${#TRELLIS_DISCOVERY_ROOTS[@]}"
        for discovery_root in "${TRELLIS_DISCOVERY_ROOTS[@]}"; do
          printf "discovery_root=%s\n" "$discovery_root"
        done
        printf "roots_json=%s\nfleet_local=%s\ninfra_available=%s\n" \
          "$TRELLIS_DISCOVERY_ROOTS_JSON" "$TRELLIS_FLEET_LOCAL_JSON" "$SHARED_INFRA_ROOT_AVAILABLE"
        printf "root=%s\\nprojects=%s\\ninfra=%s\\nhome=%s\\n" \
          "${TRELLIS_ROOT-<unset>}" "$PROJECTS_ROOT" "$SHARED_INFRA_ROOT" "$USER_HOME"
      ' _ "$LOADER"
  fi
}

output_value() {
  local key
  key="$1"
  printf '%s\n' "$output" | sed -n "s/^${key}=//p"
}

run_loader_without_ajv() {
  local policy
  policy="$1"

  run env \
    HOME="$HOME_DIR" \
    TRELLIS_HOME="$TRELLIS_HOME_DIR" \
    TRELLIS_CONFIG="$policy" \
    bash -c '
      ajv() { return 127; }
      npx() { return 127; }
      . "$1"
      exit "$?"
    ' _ "$LOADER"
}

run_loader_with_ajv_probe() {
  local compile_status validate_status direct_status
  compile_status="$1"
  validate_status="$2"
  direct_status="${3:-127}"
  PROBE_LOG="$SANDBOX/ajv-probe.log"
  : > "$PROBE_LOG"

  run env \
    HOME="$HOME_DIR" \
    TRELLIS_HOME="$TRELLIS_HOME_DIR" \
    TRELLIS_CONFIG="$POLICY" \
    PROBE_LOG="$PROBE_LOG" \
    COMPILE_STATUS="$compile_status" \
    VALIDATE_STATUS="$validate_status" \
    DIRECT_STATUS="$direct_status" \
    bash -c '
      ajv() {
        [ "$DIRECT_STATUS" -ne 127 ] || return 127
        printf "ajv %s\n" "$*" >> "$PROBE_LOG"
        return "$DIRECT_STATUS"
      }
      npx() {
        printf "npx %s\n" "$*" >> "$PROBE_LOG"
        [ "$1" = --no-install ] && [ "$2" = --offline ] &&
          [ "$3" = --no-update-notifier ] || return 96
        shift 3
        [ "$1" = ajv ] || return 97
        case "$2" in
          compile) return "$COMPILE_STATUS" ;;
          validate) return "$VALIDATE_STATUS" ;;
          *) return 98 ;;
        esac
      }
      . "$1"
      exit "$?"
    ' _ "$LOADER"
}

@test "offline npx compile unavailable accepts valid policy through fallback" {
  run_loader_with_ajv_probe 1 99

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(< "$PROBE_LOG")" = "npx --no-install --offline --no-update-notifier ajv compile --spec=draft2020 --strict=false -s $ROOT/scripts/lib/trellis.config.schema.json" ]
}

@test "offline npx compile unavailable rejects invalid policy through fallback" {
  jq '.package_manager = "not-a-supported-package-manager"' "$POLICY" > "$POLICY.tmp"
  mv "$POLICY.tmp" "$POLICY"

  run_loader_with_ajv_probe 1 0

  [ "$status" -eq 4 ]
  [[ "$output" == *"portable policy failed schema validation"* ]]
  [ "$(< "$PROBE_LOG")" = "npx --no-install --offline --no-update-notifier ajv compile --spec=draft2020 --strict=false -s $ROOT/scripts/lib/trellis.config.schema.json" ]
}

@test "offline npx compiles then validates valid policy" {
  run_loader_with_ajv_probe 0 0

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(< "$PROBE_LOG")" = "npx --no-install --offline --no-update-notifier ajv compile --spec=draft2020 --strict=false -s $ROOT/scripts/lib/trellis.config.schema.json
npx --no-install --offline --no-update-notifier ajv validate --spec=draft2020 --strict=false -s $ROOT/scripts/lib/trellis.config.schema.json -d $POLICY" ]
}

@test "offline npx validation rejection never falls through to jq acceptance" {
  # presets is schema-validated but not consumed by the compatibility fallback.
  jq '.presets = "not-an-array"' "$POLICY" > "$POLICY.tmp"
  mv "$POLICY.tmp" "$POLICY"

  run_loader_with_ajv_probe 0 1

  [ "$status" -eq 4 ]
  [[ "$output" == *"portable policy failed schema validation"* ]]
  [ "$(< "$PROBE_LOG")" = "npx --no-install --offline --no-update-notifier ajv compile --spec=draft2020 --strict=false -s $ROOT/scripts/lib/trellis.config.schema.json
npx --no-install --offline --no-update-notifier ajv validate --spec=draft2020 --strict=false -s $ROOT/scripts/lib/trellis.config.schema.json -d $POLICY" ]
}

@test "injected direct AJV remains preferred over offline npx" {
  run_loader_with_ajv_probe 99 99 0

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(< "$PROBE_LOG")" = "ajv compile --spec=draft2020 --strict=false -s $ROOT/scripts/lib/trellis.config.schema.json
ajv validate --spec=draft2020 --strict=false -s $ROOT/scripts/lib/trellis.config.schema.json -d $POLICY" ]
}

@test "loads portable policy and separate validated local state" {
  run_loader "$POLICY"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"policy=$POLICY"* ]] || { echo "$output"; false; }
  [[ "$output" == *"home_config=$TRELLIS_HOME_DIR/config.json"* ]] || { echo "$output"; false; }
  [[ "$output" == *"source=$POLICY_ROOT"* ]] || { echo "$output"; false; }
  [[ "$output" == *"release=1.2.3"* ]] || { echo "$output"; false; }
  [[ "$output" == *"fleet=personal"* ]] || { echo "$output"; false; }
  [[ "$output" == *"harnesses=claude codex"* ]] || { echo "$output"; false; }
  [[ "$output" == *"maintainer=Portable Maintainer"* ]] || { echo "$output"; false; }
  [[ "$output" == *"template=https://example.invalid/trellis.git@main"* ]] || { echo "$output"; false; }
  [[ "$output" == *"sed=auto"* ]] || { echo "$output"; false; }
  [[ "$output" == *"style=relative"* ]] || { echo "$output"; false; }
}

@test "uses TRELLIS_FLEET before the configured default fleet" {
  run_loader "$POLICY"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"fleet=personal"* ]] || { echo "$output"; false; }
  [[ "$output" == *"projects=$PERSONAL_ROOT"* ]] || { echo "$output"; false; }
  [[ "$output" == *"infra=$PERSONAL_INFRA"* ]] || { echo "$output"; false; }

  run_loader "$POLICY" work
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"fleet=work"* ]] || { echo "$output"; false; }
  [[ "$output" == *"projects=$WORK_ROOT"* ]] || { echo "$output"; false; }
  [[ "$output" == *"infra=$WORK_INFRA"* ]] || { echo "$output"; false; }
}

@test "exports multiple discovery roots and clears the PROJECTS_ROOT bridge" {
  local fleet_state
  jq --arg second "$PERSONAL_SECOND_ROOT" \
    '.fleets.personal.discovery_roots += [$second]' \
    "$TRELLIS_HOME_DIR/config.json" > "$TRELLIS_HOME_DIR/config.tmp"
  mv "$TRELLIS_HOME_DIR/config.tmp" "$TRELLIS_HOME_DIR/config.json"

  run_loader "$POLICY"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value roots_count)" -eq 2 ]
  [[ "$output" == *"discovery_root=$PERSONAL_ROOT"* ]] || { echo "$output"; false; }
  [[ "$output" == *"discovery_root=$PERSONAL_SECOND_ROOT"* ]] || { echo "$output"; false; }
  [ "$(output_value roots_json)" = "[\"$PERSONAL_ROOT\",\"$PERSONAL_SECOND_ROOT\"]" ]
  [ "$(output_value projects)" = "" ]
  fleet_state="$(output_value fleet_local)"
  [ "$(jq -r '.discovery_roots | length' <<<"$fleet_state")" -eq 2 ]
  [ "$(jq -r '.discovery_roots[0].configured_path' <<<"$fleet_state")" = "$PERSONAL_ROOT" ]
  [ "$(jq -r '.discovery_roots[0].available' <<<"$fleet_state")" = true ]
  [ "$(jq -r '.discovery_roots[1].configured_path' <<<"$fleet_state")" = "$PERSONAL_SECOND_ROOT" ]
  [ "$(jq -r '.discovery_roots[1].available' <<<"$fleet_state")" = true ]
}

@test "walks from the calling script and honors explicit portable policy override" {
  local caller override
  caller="$POLICY_ROOT/nested/bin/load-policy.sh"
  override="$SANDBOX/override-policy.json"
  mkdir -p "$(dirname "$caller")"
  write_policy "$override" "Override Maintainer" "override-user"
  cat > "$caller" <<'EOF'
#!/usr/bin/env bash
. "$LOADER"
status=$?
[ "$status" -eq 0 ] || exit "$status"
printf 'maintainer=%s\n' "$MAINTAINER_NAME"
EOF

  run env HOME="$HOME_DIR" TRELLIS_HOME="$TRELLIS_HOME_DIR" LOADER="$LOADER" bash "$caller"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"maintainer=Portable Maintainer"* ]] || { echo "$output"; false; }

  run env \
    HOME="$HOME_DIR" \
    TRELLIS_HOME="$TRELLIS_HOME_DIR" \
    TRELLIS_CONFIG="$override" \
    LOADER="$LOADER" \
    bash "$caller"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"maintainer=Override Maintainer"* ]] || { echo "$output"; false; }
}

@test "rejects corrupt machine state" {
  jq '.unexpected = true' "$TRELLIS_HOME_DIR/config.json" > "$TRELLIS_HOME_DIR/config.tmp"
  mv "$TRELLIS_HOME_DIR/config.tmp" "$TRELLIS_HOME_DIR/config.json"

  run_loader "$POLICY"

  [ "$status" -eq 4 ]
  [[ "$output" == *"machine config failed schema-aware validation"* ]] || { echo "$output"; false; }
}

@test "rejects forbidden machine fields in portable policy" {
  jq '.source_root = "/forbidden"' "$POLICY" > "$POLICY.tmp"
  mv "$POLICY.tmp" "$POLICY"

  run_loader_without_ajv "$POLICY"

  [ "$status" -eq 4 ]
  [[ "$output" == *"portable policy contains machine-local fields"* ]] || { echo "$output"; false; }
}

@test "fallback rejects unsafe template remotes and branches" {
  local field
  for field in remote branch; do
    write_policy "$POLICY" "Portable Maintainer" "portable-user"
    jq --arg field "$field" \
      '.template[$field] = "-leading-option"' "$POLICY" > "$POLICY.tmp"
    mv "$POLICY.tmp" "$POLICY"

    run_loader_without_ajv "$POLICY"

    [ "$status" -eq 4 ]
    [[ "$output" == *"portable policy failed schema validation"* ]] || { echo "$output"; false; }
  done

  write_policy "$POLICY" "Portable Maintainer" "portable-user"
  jq '.template.remote = "git@github.com:org/repo.git:refs/heads/main"' \
    "$POLICY" > "$POLICY.tmp"
  mv "$POLICY.tmp" "$POLICY"

  run_loader_without_ajv "$POLICY"

  [ "$status" -eq 4 ]
  [[ "$output" == *"portable policy failed schema validation"* ]] || { echo "$output"; false; }
}

@test "fallback rejects disk janitor arithmetic strings without execution" {
  local sentinel payload
  sentinel="$SANDBOX/fallback-command-substitution-ran"
  payload='x[$(touch '"$sentinel"')]'
  jq --arg value "$payload" \
    '.disk_janitor.cache_ceiling_gb = $value' "$POLICY" > "$POLICY.tmp"
  mv "$POLICY.tmp" "$POLICY"

  run_loader_without_ajv "$POLICY"

  [ "$status" -eq 4 ]
  [[ "$output" == *"portable policy failed schema validation"* ]] || { echo "$output"; false; }
  [ ! -e "$sentinel" ]
}

@test "fallback validates conductor auto_execute_top_n as a non-negative integer" {
  local value
  for value in -1 1.5 '"2"'; do
    write_policy "$POLICY" "Portable Maintainer" "portable-user"
    jq --argjson value "$value" \
      '.conductor.auto_execute_top_n = $value' "$POLICY" > "$POLICY.tmp"
    mv "$POLICY.tmp" "$POLICY"

    run_loader_without_ajv "$POLICY"

    [ "$status" -eq 4 ]
    [[ "$output" == *"portable policy failed schema validation"* ]] || { echo "$output"; false; }
  done

  write_policy "$POLICY" "Portable Maintainer" "portable-user"
  jq '.conductor.auto_execute_top_n = 2' "$POLICY" > "$POLICY.tmp"
  mv "$POLICY.tmp" "$POLICY"
  run_loader_without_ajv "$POLICY"
  [ "$status" -eq 0 ] || { echo "$output"; false; }
}

@test "keeps an unavailable discovery root in fleet-local state" {
  local fleet_state missing
  missing="$SANDBOX/missing volume"
  jq --arg root "$missing" \
    '.fleets.personal.discovery_roots = [$root]' \
    "$TRELLIS_HOME_DIR/config.json" > "$TRELLIS_HOME_DIR/config.tmp"
  mv "$TRELLIS_HOME_DIR/config.tmp" "$TRELLIS_HOME_DIR/config.json"

  run_loader "$POLICY"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value roots_count)" -eq 1 ]
  [ "$(output_value roots_json)" = "[\"$missing\"]" ]
  [ "$(output_value projects)" = "" ]
  fleet_state="$(output_value fleet_local)"
  [ "$(jq -r '.discovery_roots[0].configured_path' <<<"$fleet_state")" = "$missing" ]
  [ "$(jq -r '.discovery_roots[0].available' <<<"$fleet_state")" = false ]
  [ "$(jq -r '.discovery_roots[0].canonical_path' <<<"$fleet_state")" = null ]
}

@test "repairs local machine config permissions to private mode" {
  chmod 644 "$TRELLIS_HOME_DIR/config.json"

  run_loader "$POLICY"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(file_mode "$TRELLIS_HOME_DIR/config.json")" = 600 ]
}

@test "refuses a group-or-other-accessible Trellis home before config repair" {
  local loader_status loader_output
  chmod 777 "$TRELLIS_HOME_DIR"

  run_loader "$POLICY"
  loader_status="$status"
  loader_output="$output"
  chmod 700 "$TRELLIS_HOME_DIR"

  [ "$loader_status" -eq 4 ]
  [[ "$loader_output" == *"TRELLIS_HOME must not grant group or other permissions"* ]] || { echo "$loader_output"; false; }
}

@test "refuses a symlinked local machine config" {
  mv "$TRELLIS_HOME_DIR/config.json" "$TRELLIS_HOME_DIR/real-config.json"
  ln -s real-config.json "$TRELLIS_HOME_DIR/config.json"

  run_loader "$POLICY"

  [ "$status" -eq 4 ]
  [[ "$output" == *"machine config must not be a symlink"* ]] || { echo "$output"; false; }
}

@test "sources under set -euo pipefail" {
  run env \
    HOME="$HOME_DIR" \
    TRELLIS_HOME="$TRELLIS_HOME_DIR" \
    TRELLIS_CONFIG="$POLICY" \
    bash -c '
      set -euo pipefail
      . "$1"
      printf "strict=%s/%s/%s\n" "$TRELLIS_FLEET_NAME" "$PROJECTS_ROOT" "$SYMLINK_STYLE"
    ' _ "$LOADER"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"strict=personal/$PERSONAL_ROOT/relative"* ]] || { echo "$output"; false; }
}

@test "AJV rejects invalid optional portable policy values when draft2020 support is available" {
  if command -v ajv >/dev/null 2>&1 &&
     ajv compile --spec=draft2020 --strict=false \
       -s "$ROOT/scripts/lib/trellis.config.schema.json" >/dev/null 2>&1; then
    :
  elif command -v npx >/dev/null 2>&1 &&
       npx --no-install --offline --no-update-notifier ajv compile --spec=draft2020 --strict=false \
         -s "$ROOT/scripts/lib/trellis.config.schema.json" >/dev/null 2>&1; then
    :
  else
    skip "AJV CLI lacks draft2020 support"
  fi
  jq '.package_manager = "not-a-supported-package-manager"' "$POLICY" > "$POLICY.tmp"
  mv "$POLICY.tmp" "$POLICY"

  run_loader "$POLICY"

  [ "$status" -eq 4 ]
  [[ "$output" == *"portable policy failed schema validation"* ]] || { echo "$output"; false; }
}


@test "keeps optional unavailable shared infrastructure in fleet-local state" {
  local fleet_state missing
  missing="$SANDBOX/missing shared infra"
  jq --arg infra "$missing" \
    '.fleets.personal.shared_infra_root = $infra' \
    "$TRELLIS_HOME_DIR/config.json" > "$TRELLIS_HOME_DIR/config.tmp"
  mv "$TRELLIS_HOME_DIR/config.tmp" "$TRELLIS_HOME_DIR/config.json"

  run_loader "$POLICY"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(output_value projects)" = "$PERSONAL_ROOT" ]
  [ "$(output_value infra)" = "$missing" ]
  [ "$(output_value infra_available)" = 0 ]
  fleet_state="$(output_value fleet_local)"
  [ "$(jq -r '.shared_infra_root.configured_path' <<<"$fleet_state")" = "$missing" ]
  [ "$(jq -r '.shared_infra_root.available' <<<"$fleet_state")" = false ]
  [ "$(jq -r '.shared_infra_root.canonical_path' <<<"$fleet_state")" = null ]
}

@test "uses its sole available discovery root as the PROJECTS_ROOT bridge" {
  local canonical_root canonical_infra fleet_state infra_link root_link
  canonical_root="$SANDBOX/canonical personal"
  canonical_infra="$SANDBOX/canonical infra"
  root_link="$SANDBOX/personal link"
  infra_link="$SANDBOX/infra link"
  mkdir -p "$canonical_root" "$canonical_infra"
  ln -s "$canonical_root" "$root_link"
  ln -s "$canonical_infra" "$infra_link"

  jq \
    --arg root "$root_link" \
    --arg infra "$infra_link" \
    '.fleets.personal.discovery_roots = [$root]
      | .fleets.personal.shared_infra_root = $infra' \
    "$TRELLIS_HOME_DIR/config.json" > "$TRELLIS_HOME_DIR/config.tmp"
  mv "$TRELLIS_HOME_DIR/config.tmp" "$TRELLIS_HOME_DIR/config.json"

  run_loader "$POLICY"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  # v1.0.0-rc.25 stopped exporting the source root as TRELLIS_ROOT. The probe
  # prints `<unset>` for it, and the source root is read from TRELLIS_SOURCE_ROOT.
  [ "$(output_value root)" = "<unset>" ]
  [ "$(output_value source)" = "$POLICY_ROOT" ]
  [ "$(output_value roots_count)" -eq 1 ]
  [ "$(output_value roots_json)" = "[\"$root_link\"]" ]
  [ "$(output_value projects)" = "$canonical_root" ]
  [ "$(output_value infra)" = "$infra_link" ]
  [ "$(output_value infra_available)" = 1 ]
  fleet_state="$(output_value fleet_local)"
  [ "$(jq -r '.discovery_roots[0].configured_path' <<<"$fleet_state")" = "$root_link" ]
  [ "$(jq -r '.discovery_roots[0].canonical_path' <<<"$fleet_state")" = "$canonical_root" ]
  [ "$(jq -r '.shared_infra_root.configured_path' <<<"$fleet_state")" = "$infra_link" ]
  [ "$(jq -r '.shared_infra_root.canonical_path' <<<"$fleet_state")" = "$canonical_infra" ]
  [ "$(output_value home)" = "$HOME_DIR" ]
}

@test "the loader no longer exports the source root as TRELLIS_ROOT" {
  # Cutover contract (v1.0.0-rc.25): TRELLIS_ROOT carries exactly one meaning —
  # a project's `.trellis/runtime` anchor. If the loader re-exported the mutable
  # source checkout under that name, every hook library that resolves policy
  # from $TRELLIS_ROOT would silently read the source tree again, which is the
  # whole failure mode immutable releases exist to prevent.
  run env \
    HOME="$HOME_DIR" \
    TRELLIS_HOME="$TRELLIS_HOME_DIR" \
    TRELLIS_CONFIG="$POLICY" \
    bash -c '
      set -u
      . "$1"
      printf "trellis_root=%s\n" "${TRELLIS_ROOT-<unset>}"
      printf "source=%s\n" "$TRELLIS_SOURCE_ROOT"
      env | grep -c "^TRELLIS_ROOT=" || true
    ' _ "$LOADER"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"trellis_root=<unset>"* ]] || { echo "$output"; false; }
  [[ "$output" == *"source=$POLICY_ROOT"* ]] || { echo "$output"; false; }
  # Not merely unset in the sourcing shell — absent from the exported environment.
  [[ "$output" == *$'\n0' ]] || { echo "$output"; false; }
}

@test "an inherited TRELLIS_ROOT is not adopted as the source root" {
  # An operator (or a stale shell profile) still exporting the old compatibility
  # variable must not steer the loader. The source root comes from validated
  # machine state, and TRELLIS_ROOT is passed through untouched.
  run env \
    HOME="$HOME_DIR" \
    TRELLIS_HOME="$TRELLIS_HOME_DIR" \
    TRELLIS_CONFIG="$POLICY" \
    TRELLIS_ROOT="$SANDBOX/not-the-source" \
    bash -c '
      set -u
      . "$1"
      printf "trellis_root=%s\nsource=%s\n" "$TRELLIS_ROOT" "$TRELLIS_SOURCE_ROOT"
    ' _ "$LOADER"

  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [[ "$output" == *"trellis_root=$SANDBOX/not-the-source"* ]] || { echo "$output"; false; }
  [[ "$output" == *"source=$POLICY_ROOT"* ]] || { echo "$output"; false; }
}
