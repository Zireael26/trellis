#!/usr/bin/env bash
# Configure local-only Trellis machine state.
#
# Bash 3.2 compatible.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/trellis-home.sh
. "$SCRIPT_DIR/lib/trellis-home.sh"

print_help() {
  cat <<'EOF'
trellis configure — local machine and fleet setup

Usage:
  configure.sh configure --source PATH [options]
  configure.sh --source PATH [options]
  configure.sh fleet add NAME --discovery-root PATH [options]
  configure.sh fleet update NAME [--discovery-root PATH...] [options]
  configure.sh fleet set-default NAME [--home PATH]
  configure.sh --help

Configure options:
  --source PATH                 Trellis policy source checkout. CLI wins over
                                TRELLIS_SOURCE_ROOT and existing config.
  --home PATH                   Trellis home. CLI wins over TRELLIS_HOME;
                                default is $HOME/.trellis. Canonicalized before
                                use (repeated/trailing separators collapsed,
                                existing ancestors resolved); a path that cannot
                                be canonicalized is refused rather than
                                persisted for later dispatches to reject.
  --default-fleet NAME          Default fleet. CLI wins over TRELLIS_FLEET,
                                existing config, then "personal".
  --discovery-root PATH         Discovery root for the default fleet. May repeat.
                                Defaults to the source parent only for a new
                                default fleet.
  --shared-infra-root PATH      Optional shared-infra root for the default fleet.
  --active-cli-release VERSION  Active management release. CLI wins over
                                TRELLIS_RELEASE, existing config, then
                                core-rules/VERSION under --source.
  --release VERSION             Alias for --active-cli-release.
  --release-remote URL          Release fetch remote. Default: existing config,
                                source trellis.config.json template.remote,
                                source git origin, then source path.
  --launcher-template PATH      Launcher template to atomically install.
                                Default: <source>/scripts/trellis-launcher.sh.
  --no-install-launcher         Write config only; do not install the launcher.

Fleet options:
  --home PATH                   Trellis home override.
  --discovery-root PATH         Add a discovery root. Required for new fleets.
  --shared-infra-root PATH      Set or replace the fleet shared-infra root.
  --make-default                Also set this fleet as default.

Environment precedence:
  explicit CLI flag
    > TRELLIS_HOME / TRELLIS_FLEET / TRELLIS_RELEASE / TRELLIS_SOURCE_ROOT
    > ~/.trellis/config.json
    > portable defaults

Exit classes:
  0  success
  2  bad arguments
  3  ownership or identity conflict
  4  invalid or corrupt local state
  5  unavailable path, remote, or required local capability
EOF
}

usage_error() {
  printf 'trellis configure: %s\n\n' "$*" >&2
  print_help >&2
  exit "$TRELLIS_EX_USAGE"
}


config_write() {
  local home proposed cfg
  home="$1"
  proposed="$2"
  cfg="$(trellis_home_config_path "$home")"
  trellis_home_atomic_write_json "$cfg" "$proposed" || trellis_home_die "$?" "failed to write $cfg"
}

load_existing_config_or_empty() {
  local cfg out
  cfg="$1"
  out="$2"
  if [ -e "$cfg" ] || [ -L "$cfg" ]; then
    if [ -L "$cfg" ] || [ ! -f "$cfg" ]; then
      trellis_home_die "$TRELLIS_EX_STATE" "existing config is not a regular file: $cfg"
    fi
    trellis_home_validate_config "$cfg" || trellis_home_die "$?" "existing config is invalid: $cfg"
    cp "$cfg" "$out" || trellis_home_die "$TRELLIS_EX_UNAVAILABLE" "could not read existing config: $cfg"
  else
    jq -n '{schema_version: 1, fleets: {}}' > "$out" ||
      trellis_home_die "$TRELLIS_EX_STATE" "failed to create an empty machine config"
  fi
}

cmd_configure() {
  local home_opt source_opt default_fleet_opt release_opt remote_opt shared_infra_root
  local launcher_template_opt install_launcher discovery_roots_seen
  local home cfg source_root default_fleet release release_remote roots_tmp
  local base_tmp proposed_tmp root launcher_template launcher_bin roots_json jq_filter
  local existing_roots_count launcher_action
  home_opt=""
  source_opt=""
  default_fleet_opt=""
  release_opt=""
  remote_opt=""
  shared_infra_root=""
  launcher_template_opt=""
  install_launcher=1
  discovery_roots_seen=0
  base_tmp=""
  proposed_tmp=""
  roots_tmp="$(mktemp "${TMPDIR:-/tmp}/trellis.roots.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
  trap 'rm -f "${roots_tmp:-}" "${base_tmp:-}" "${proposed_tmp:-}"; trellis_home_lock_release >/dev/null 2>&1 || true' EXIT

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || usage_error "--home requires PATH"; home_opt="$2"; shift 2 ;;
      --source) [ "$#" -ge 2 ] || usage_error "--source requires PATH"; source_opt="$2"; shift 2 ;;
      --default-fleet) [ "$#" -ge 2 ] || usage_error "--default-fleet requires NAME"; default_fleet_opt="$2"; shift 2 ;;
      --discovery-root)
        [ "$#" -ge 2 ] || usage_error "--discovery-root requires PATH"
        trellis_home_require_absolute_safe_path "discovery root" "$2" || exit "$?"
        printf '%s\n' "$2" >> "$roots_tmp"
        discovery_roots_seen=1
        shift 2
        ;;
      --shared-infra-root) [ "$#" -ge 2 ] || usage_error "--shared-infra-root requires PATH"; shared_infra_root="$2"; shift 2 ;;
      --active-cli-release|--release) [ "$#" -ge 2 ] || usage_error "$1 requires VERSION"; release_opt="$2"; shift 2 ;;
      --release-remote) [ "$#" -ge 2 ] || usage_error "--release-remote requires URL"; remote_opt="$2"; shift 2 ;;
      --launcher-template) [ "$#" -ge 2 ] || usage_error "--launcher-template requires PATH"; launcher_template_opt="$2"; shift 2 ;;
      --no-install-launcher) install_launcher=0; shift ;;
      -h|--help) print_help; exit 0 ;;
      *) usage_error "unknown option for configure: $1" ;;
    esac
  done

  if [ "$install_launcher" -eq 0 ] && [ -n "$launcher_template_opt" ]; then
    usage_error "--no-install-launcher cannot be combined with --launcher-template"
  fi
  trellis_home_require_jq || exit "$?"
  home="$(trellis_home_resolve "$home_opt")" || exit "$?"
  home="$(trellis_home_canonical_home "$home")" || exit "$?"
  trellis_home_prepare_home "$home" || exit "$?"
  cfg="$(trellis_home_config_path "$home")"
  trellis_home_lock_acquire "$home" config 30 || exit "$?"

  base_tmp="$(mktemp "${TMPDIR:-/tmp}/trellis.config.base.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
  proposed_tmp="$(mktemp "${TMPDIR:-/tmp}/trellis.config.proposed.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
  load_existing_config_or_empty "$cfg" "$base_tmp"

  source_root="$(trellis_home_resolve_source_root "$source_opt" "$cfg")" || exit "$?"
  default_fleet="$(trellis_home_resolve_fleet "$default_fleet_opt" "$cfg")" || exit "$?"
  release="$(trellis_home_resolve_release "$release_opt" "$cfg" "$source_root")" || exit "$?"
  release_remote="$(trellis_home_default_release_remote "$remote_opt" "$cfg" "$source_root")" || exit "$?"

  if [ -n "$shared_infra_root" ]; then
    trellis_home_require_absolute_safe_path "shared infra root" "$shared_infra_root" || exit "$?"
  fi
  if [ "$discovery_roots_seen" -eq 0 ]; then
    existing_roots_count="$(jq -r --arg fleet "$default_fleet" \
      '(.fleets[$fleet].discovery_roots // []) | length' "$base_tmp")" ||
      trellis_home_die "$TRELLIS_EX_STATE" "failed to inspect existing discovery roots"
    case "$existing_roots_count" in
      ''|*[!0-9]*) trellis_home_die "$TRELLIS_EX_STATE" "existing discovery roots are invalid" ;;
    esac
    if [ "$existing_roots_count" -eq 0 ]; then
      root="$(trellis_home_parent_dir "$source_root")"
      trellis_home_require_absolute_safe_path "discovery root" "$root" || exit "$?"
      printf '%s\n' "$root" >> "$roots_tmp"
    fi
  fi

  roots_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "$roots_tmp")" ||
    trellis_home_die "$TRELLIS_EX_STATE" "failed to construct discovery roots"
  jq_filter='
    .schema_version = 1
    | .source_root = $source_root
    | .release_remote = $release_remote
    | .active_cli_release = $release
    | .default_fleet = $default_fleet
    | .fleets = (.fleets // {})
    | .fleets[$default_fleet] = (.fleets[$default_fleet] // {discovery_roots: []})
    | .fleets[$default_fleet].discovery_roots =
        (((.fleets[$default_fleet].discovery_roots // []) + $roots) | unique)
    | if $shared_infra_root != "" then
        .fleets[$default_fleet].shared_infra_root = $shared_infra_root
      else . end
  '
  jq \
    --arg source_root "$source_root" \
    --arg release_remote "$release_remote" \
    --arg release "$release" \
    --arg default_fleet "$default_fleet" \
    --arg shared_infra_root "$shared_infra_root" \
    --argjson roots "$roots_json" \
    "$jq_filter" "$base_tmp" > "$proposed_tmp" ||
    trellis_home_die "$TRELLIS_EX_STATE" "failed to construct machine config JSON"
  trellis_home_validate_config "$proposed_tmp" || exit "$?"

  if [ "$install_launcher" -eq 1 ]; then
    if [ -n "$launcher_template_opt" ]; then
      launcher_template="$launcher_template_opt"
    else
      launcher_template="$source_root/scripts/trellis-launcher.sh"
    fi
    [ -n "${HOME:-}" ] ||
      trellis_home_die "$TRELLIS_EX_USAGE" "HOME is required for the stable launcher destination"
    launcher_bin="$HOME/.local/bin/trellis"
    trellis_home_install_launcher "$launcher_template" "$launcher_bin" || exit "$?"
    launcher_action="$TRELLIS_HOME_LAUNCHER_ACTION"
  else
    launcher_bin=""
    launcher_action="skipped"
  fi

  config_write "$home" "$proposed_tmp"
  trellis_home_lock_release || exit "$?"
  rm -f "$roots_tmp" "$base_tmp" "$proposed_tmp"
  trap - EXIT

  printf 'Configured Trellis home: %s\n' "$home"
  printf 'Machine config: %s\n' "$cfg"
  printf 'Source root: %s\n' "$source_root"
  printf 'Default fleet: %s\n' "$default_fleet"
  printf 'Active CLI release: %s\n' "$release"
  case "$launcher_action" in
    installed) printf 'Launcher: installed at %s\n' "$launcher_bin" ;;
    retained) printf 'Launcher: retained at %s\n' "$launcher_bin" ;;
    *) printf 'Launcher: skipped\n' ;;
  esac
}

cmd_fleet_add_or_update() {
  local mode fleet home_opt shared_infra_root make_default home cfg exists
  local roots_tmp base_tmp proposed_tmp roots_json roots_count jq_filter
  mode="$1"
  shift
  [ "$#" -ge 1 ] || usage_error "fleet $mode requires NAME"
  fleet="$1"
  shift
  trellis_home_require_fleet_name "$fleet" || exit "$?"

  home_opt=""
  shared_infra_root=""
  make_default=0
  roots_tmp="$(mktemp "${TMPDIR:-/tmp}/trellis.fleet.roots.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
  base_tmp=""
  proposed_tmp=""
  trap 'rm -f "${roots_tmp:-}" "${base_tmp:-}" "${proposed_tmp:-}"; trellis_home_lock_release >/dev/null 2>&1 || true' EXIT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || usage_error "--home requires PATH"; home_opt="$2"; shift 2 ;;
      --discovery-root)
        [ "$#" -ge 2 ] || usage_error "--discovery-root requires PATH"
        trellis_home_require_absolute_safe_path "discovery root" "$2" || exit "$?"
        printf '%s\n' "$2" >> "$roots_tmp"
        shift 2
        ;;
      --shared-infra-root) [ "$#" -ge 2 ] || usage_error "--shared-infra-root requires PATH"; shared_infra_root="$2"; shift 2 ;;
      --make-default) make_default=1; shift ;;
      -h|--help) print_help; exit 0 ;;
      *) usage_error "unknown option for fleet $mode: $1" ;;
    esac
  done

  trellis_home_require_jq || exit "$?"
  home="$(trellis_home_resolve "$home_opt")" || exit "$?"
  home="$(trellis_home_canonical_home "$home")" || exit "$?"
  trellis_home_prepare_home "$home" || exit "$?"
  cfg="$(trellis_home_config_path "$home")"
  trellis_home_lock_acquire "$home" config 30 || exit "$?"
  if [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then
    trellis_home_die "$TRELLIS_EX_STATE" "machine config not found; run configure --source PATH first"
  fi
  trellis_home_validate_config "$cfg" || exit "$?"

  if [ -n "$shared_infra_root" ]; then
    trellis_home_require_absolute_safe_path "shared infra root" "$shared_infra_root" || exit "$?"
  fi
  base_tmp="$(mktemp "${TMPDIR:-/tmp}/trellis.fleet.base.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
  proposed_tmp="$(mktemp "${TMPDIR:-/tmp}/trellis.fleet.proposed.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
  cp "$cfg" "$base_tmp" || trellis_home_die "$TRELLIS_EX_UNAVAILABLE" "could not read existing config: $cfg"

  exists="$(jq -r --arg fleet "$fleet" 'if .fleets[$fleet] then "yes" else "no" end' "$base_tmp")" ||
    trellis_home_die "$TRELLIS_EX_STATE" "failed to inspect existing fleets"
  if [ "$mode" = "add" ] && [ "$exists" = "yes" ]; then
    trellis_home_die "$TRELLIS_EX_CONFLICT" "fleet already exists: $fleet"
  fi
  if [ "$mode" = "update" ] && [ "$exists" = "no" ]; then
    trellis_home_die "$TRELLIS_EX_CONFLICT" "fleet does not exist: $fleet"
  fi
  roots_count="$(wc -l < "$roots_tmp" | tr -d '[:space:]')"
  if [ "$mode" = "add" ] && [ "${roots_count:-0}" -eq 0 ]; then
    trellis_home_die "$TRELLIS_EX_USAGE" "new fleet $fleet requires at least one --discovery-root"
  fi

  roots_json="$(jq -R -s 'split("\n") | map(select(length > 0))' "$roots_tmp")" ||
    trellis_home_die "$TRELLIS_EX_STATE" "failed to construct discovery roots"
  jq_filter='
    .fleets = (.fleets // {})
    | .fleets[$fleet] = (.fleets[$fleet] // {discovery_roots: []})
    | .fleets[$fleet].discovery_roots =
        (((.fleets[$fleet].discovery_roots // []) + $roots) | unique)
    | if $shared_infra_root != "" then
        .fleets[$fleet].shared_infra_root = $shared_infra_root
      else . end
    | if $make_default == "1" then .default_fleet = $fleet else . end
  '
  jq \
    --arg fleet "$fleet" \
    --arg shared_infra_root "$shared_infra_root" \
    --arg make_default "$make_default" \
    --argjson roots "$roots_json" \
    "$jq_filter" "$base_tmp" > "$proposed_tmp" ||
    trellis_home_die "$TRELLIS_EX_STATE" "failed to construct machine config JSON"
  trellis_home_validate_config "$proposed_tmp" || exit "$?"

  config_write "$home" "$proposed_tmp"
  trellis_home_lock_release || exit "$?"
  rm -f "$roots_tmp" "$base_tmp" "$proposed_tmp"
  trap - EXIT

  printf 'Fleet %s: %s\n' "$mode" "$fleet"
  printf 'Machine config: %s\n' "$cfg"
}

cmd_fleet_set_default() {
  local fleet home_opt home cfg proposed_tmp
  [ "$#" -ge 1 ] || usage_error "fleet set-default requires NAME"
  fleet="$1"
  shift
  trellis_home_require_fleet_name "$fleet" || exit "$?"
  home_opt=""
  proposed_tmp=""
  trap 'rm -f "${proposed_tmp:-}"; trellis_home_lock_release >/dev/null 2>&1 || true' EXIT
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || usage_error "--home requires PATH"; home_opt="$2"; shift 2 ;;
      -h|--help) print_help; exit 0 ;;
      *) usage_error "unknown option for fleet set-default: $1" ;;
    esac
  done

  trellis_home_require_jq || exit "$?"
  home="$(trellis_home_resolve "$home_opt")" || exit "$?"
  home="$(trellis_home_canonical_home "$home")" || exit "$?"
  trellis_home_prepare_home "$home" || exit "$?"
  cfg="$(trellis_home_config_path "$home")"
  trellis_home_lock_acquire "$home" config 30 || exit "$?"
  if [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then
    trellis_home_die "$TRELLIS_EX_STATE" "machine config not found; run configure --source PATH first"
  fi
  trellis_home_validate_config "$cfg" || exit "$?"
  if ! jq -e --arg fleet "$fleet" '.fleets[$fleet] != null' "$cfg" >/dev/null; then
    trellis_home_die "$TRELLIS_EX_CONFLICT" "fleet does not exist: $fleet"
  fi

  proposed_tmp="$(mktemp "${TMPDIR:-/tmp}/trellis.default.proposed.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
  jq --arg fleet "$fleet" '.default_fleet = $fleet' "$cfg" > "$proposed_tmp" ||
    trellis_home_die "$TRELLIS_EX_STATE" "failed to construct machine config JSON"
  trellis_home_validate_config "$proposed_tmp" || exit "$?"
  config_write "$home" "$proposed_tmp"
  trellis_home_lock_release || exit "$?"
  rm -f "$proposed_tmp"
  trap - EXIT

  printf 'Default fleet: %s\n' "$fleet"
  printf 'Machine config: %s\n' "$cfg"
}

main() {
  local sub
  if [ "$#" -eq 0 ]; then
    usage_error "missing command or --source"
  fi
  case "${1:-}" in
    -h|--help|help)
      print_help
      ;;
    configure)
      shift
      cmd_configure "$@"
      ;;
    fleet)
      shift
      [ "$#" -ge 1 ] || usage_error "fleet requires add, update, or set-default"
      sub="$1"
      shift
      case "$sub" in
        add|update) cmd_fleet_add_or_update "$sub" "$@" ;;
        set-default) cmd_fleet_set_default "$@" ;;
        *) usage_error "unknown fleet command: $sub" ;;
      esac
      ;;
    --source|--home|--default-fleet|--discovery-root|--shared-infra-root|--active-cli-release|--release|--release-remote|--launcher-template|--no-install-launcher)
      cmd_configure "$@"
      ;;
    *)
      usage_error "unknown command: $1"
      ;;
  esac
}

main "$@"
