#!/usr/bin/env bash
# disk-janitor-agents.sh — the one definition of the disk-janitor LaunchAgents
# that scripts/install-disk-janitor-launchd.sh writes, and the exact-match check
# that `trellis launchd` (install refusal) and `trellis doctor` (error row) both
# apply to every org.trellis.disk-janitor* entry in a LaunchAgents directory
# (spec 059 R3).
#
# An installed agent must carry the installer's full ProgramArguments vector and
# schedule, element for element. A substring test is not enough: a legacy apply
# agent with no --scopes falls back to the janitor's default scopes.
#
# Read-only. Plists are read with the fixed /usr/bin/plutil so the check runs
# unchanged under the installer's empty environment. bash 3.2 compatible.

DJ_AGENT_REPORT_LABEL='org.trellis.disk-janitor'
DJ_AGENT_APPLY_LABEL='org.trellis.disk-janitor-apply'
DJ_AGENT_WATCHDOG_LABEL='org.trellis.pi-spill-watchdog'
DJ_AGENT_PLUTIL='/usr/bin/plutil'

# dj_agent_has_forbidden_docker_args ARGV_STRING
#
# Return 0 if the argument string contains any forbidden docker volume,
# image, container, or compose removal commands.
dj_agent_has_forbidden_docker_args() {
  local str="$1"
  case "$str" in
    *" volume rm "*|*" volume remove "*|*" volume prune "*|\
    *" image prune "*|*" container prune "*|*" system prune "*|\
    *" rm -v "*|*" rmi "*|*" docker rm "*|\
    *" image rm "*|*" image remove "*|\
    *" container rm "*|*" container remove "*|\
    *" compose rm "*)
      return 0
      ;;
  esac
  case "$str" in
    *" compose "*|*" docker-compose "*)
      case "$str" in
        *" down "*)
          case "$str" in
            *" -v "*|*" --volumes "*|*" --volumes="*|*" -"*v*" "*)
              return 0
              ;;
          esac
          ;;
      esac
      ;;
  esac
  return 1
}

# dj_agent_expected LABEL USER_HOME TRELLIS_HOME
#
# Set DJ_AGENT_EXPECTED_ARGV, DJ_AGENT_EXPECTED_HOUR and DJ_AGENT_EXPECTED_MINUTE
# to what the installer renders for LABEL. Returns 1 for any other label.
dj_agent_expected() {
  local label="$1" user_home="$2" trellis_home="$3"
  DJ_AGENT_EXPECTED_ARGV=(
    /usr/bin/env
    -i
    "HOME=$user_home"
    "TRELLIS_HOME=$trellis_home"
    'PATH=/usr/bin:/bin:/usr/sbin:/sbin'
    /bin/bash
    --noprofile
    --norc
  )
  case "$label" in
    "$DJ_AGENT_REPORT_LABEL")
      DJ_AGENT_EXPECTED_ARGV+=("$user_home/.local/bin/trellis" disk-janitor --report)
      DJ_AGENT_EXPECTED_HOUR=3
      DJ_AGENT_EXPECTED_MINUTE=30
      ;;
    "$DJ_AGENT_APPLY_LABEL")
      DJ_AGENT_EXPECTED_ARGV+=("$user_home/.local/bin/trellis" disk-janitor --apply --yes --safe-only --dehydrate --scopes "worktrees,caches,releases,pi,tmp,docker")
      DJ_AGENT_EXPECTED_HOUR=4
      DJ_AGENT_EXPECTED_MINUTE=0
      ;;
    "$DJ_AGENT_WATCHDOG_LABEL")
      DJ_AGENT_EXPECTED_ARGV+=(
        "$trellis_home/state/disk-janitor/pi-spill-watchdog"
      )
      DJ_AGENT_EXPECTED_INTERVAL=60
      ;;
    *) return 1 ;;
  esac
}

# dj_agent_value PLIST KEYPATH TYPE — set DJ_AGENT_VALUE to the raw value at
# KEYPATH, which must have plist TYPE. For an array the raw value is its count;
# for a dictionary, its keys one per line. The trailing newline plutil appends is
# removed and nothing else, so a string compares byte for byte.
dj_agent_value() {
  local value
  value="$("$DJ_AGENT_PLUTIL" -extract "$2" raw -expect "$3" -o - "$1" 2>/dev/null && printf '.')" || return 1
  value="${value%.}"
  DJ_AGENT_VALUE="${value%$'\n'}"
}

# dj_agent_has PLIST KEYPATH — does the plist carry any value at KEYPATH?
dj_agent_has() {
  "$DJ_AGENT_PLUTIL" -extract "$2" raw -o - "$1" >/dev/null 2>&1
}

# dj_agent_matches PLIST LABEL USER_HOME TRELLIS_HOME
#
# Return 0 when the plist's ProgramArguments equal the installer's expected
# vector exactly and its schedule is exactly the expected daily
# StartCalendarInterval (no other launch trigger, RunAtLoad not true).
# Otherwise return 1 with DJ_AGENT_DETAIL naming every difference found.
dj_agent_matches() {
  local plist="$1" label="$2" user_home="$3" trellis_home="$4"
  local count i expected actual keys
  local -a found=() details=()
  DJ_AGENT_DETAIL=""
  if [ ! -x "$DJ_AGENT_PLUTIL" ]; then
    DJ_AGENT_DETAIL="cannot verify: $DJ_AGENT_PLUTIL is unavailable"
    return 1
  fi
  if ! dj_agent_expected "$label" "$user_home" "$trellis_home"; then
    DJ_AGENT_DETAIL="not an installer-managed agent name (expected $DJ_AGENT_REPORT_LABEL.plist, $DJ_AGENT_APPLY_LABEL.plist, or $DJ_AGENT_WATCHDOG_LABEL.plist)"
    return 1
  fi

  # Program or BundleProgram replaces the executable ProgramArguments names;
  # the installer never renders either.
  for keys in Program BundleProgram; do
    if dj_agent_has "$plist" "$keys"; then
      details+=("$keys overrides the executable ProgramArguments names")
    fi
  done
  if ! dj_agent_value "$plist" ProgramArguments array; then
    details+=("ProgramArguments is missing or not an array")
  else
    count="$DJ_AGENT_VALUE"
    case "$count" in ''|*[!0-9]*) count=0 ;; esac
    i=0
    while [ "$i" -lt "$count" ]; do
      if dj_agent_value "$plist" "ProgramArguments.$i" string; then
        found+=("$DJ_AGENT_VALUE")
      else
        found+=("<non-string>")
      fi
      i=$((i + 1))
    done
    # Name the two ways a janitor agent reaches Docker before the raw diff.
    actual=" "
    [ "$count" -eq 0 ] || actual=" ${found[*]} "
    case "$actual" in
      *" --apply "*)
        case "$actual" in
          *" --scopes "*|*" --scopes="*) ;;
          *) details+=("no --scopes: the janitor falls back to its default scopes") ;;
        esac
        ;;
    esac
    if dj_agent_has_forbidden_docker_args "$actual"; then
      details+=("flags docker volume/image/container removal")
    fi
    i=0
    while [ "$i" -lt "$count" ] && [ "$i" -lt "${#DJ_AGENT_EXPECTED_ARGV[@]}" ]; do
      expected="${DJ_AGENT_EXPECTED_ARGV[$i]}"
      if [ "${found[$i]}" != "$expected" ]; then
        details+=("ProgramArguments[$i] is '${found[$i]}', expected '$expected'")
        break
      fi
      i=$((i + 1))
    done
    if [ "$count" -ne "${#DJ_AGENT_EXPECTED_ARGV[@]}" ]; then
      details+=("ProgramArguments has $count entries, expected ${#DJ_AGENT_EXPECTED_ARGV[@]}")
    fi
  fi

  if [ "$label" = "$DJ_AGENT_WATCHDOG_LABEL" ]; then
    if ! dj_agent_value "$plist" StartInterval integer; then
      details+=("schedule: StartInterval is missing or not an integer")
    elif [ "$DJ_AGENT_VALUE" != "$DJ_AGENT_EXPECTED_INTERVAL" ]; then
      details+=("schedule: StartInterval is $DJ_AGENT_VALUE, expected $DJ_AGENT_EXPECTED_INTERVAL")
    fi
    for keys in StartCalendarInterval KeepAlive OnDemand WatchPaths QueueDirectories StartOnMount Sockets MachServices LaunchEvents; do
      if dj_agent_has "$plist" "$keys"; then
        details+=("schedule: unexpected launch trigger $keys")
      fi
    done
  else
    if ! dj_agent_value "$plist" StartCalendarInterval dictionary; then
      details+=("schedule: StartCalendarInterval is missing or not a single daily interval")
    else
      keys="$(printf '%s\n' "$DJ_AGENT_VALUE" | LC_ALL=C sort | tr '\n' ' ')"
      if [ "$keys" != "Hour Minute " ]; then
        details+=("schedule: StartCalendarInterval keys are '${keys% }', expected 'Hour Minute'")
      else
        dj_agent_value "$plist" StartCalendarInterval.Hour integer || DJ_AGENT_VALUE='<non-integer>'
        actual="$DJ_AGENT_VALUE"
        dj_agent_value "$plist" StartCalendarInterval.Minute integer || DJ_AGENT_VALUE='<non-integer>'
        if [ "$actual" != "$DJ_AGENT_EXPECTED_HOUR" ] || [ "$DJ_AGENT_VALUE" != "$DJ_AGENT_EXPECTED_MINUTE" ]; then
          details+=("schedule: Hour=$actual Minute=$DJ_AGENT_VALUE, expected Hour=$DJ_AGENT_EXPECTED_HOUR Minute=$DJ_AGENT_EXPECTED_MINUTE")
        fi
      fi
    fi
    # Every launchd.plist(5) key that can start the job besides the calendar
    # interval (OnDemand=false is a legacy spelling of KeepAlive=true).
    for keys in StartInterval KeepAlive OnDemand WatchPaths QueueDirectories StartOnMount Sockets MachServices LaunchEvents; do
      if dj_agent_has "$plist" "$keys"; then
        details+=("schedule: unexpected launch trigger $keys")
      fi
    done
  fi
  if dj_agent_value "$plist" RunAtLoad bool && [ "$DJ_AGENT_VALUE" = true ]; then
    details+=("schedule: RunAtLoad is true")
  fi

  [ "${#details[@]}" -eq 0 ] && return 0
  DJ_AGENT_DETAIL="${details[0]}"
  i=1
  while [ "$i" -lt "${#details[@]}" ]; do
    DJ_AGENT_DETAIL="$DJ_AGENT_DETAIL; ${details[$i]}"
    i=$((i + 1))
  done
  # The detail quotes plist strings verbatim: escape tab, newline and CR so it
  # stays one field of one scan row.
  DJ_AGENT_DETAIL="${DJ_AGENT_DETAIL//$'\t'/\\t}"
  DJ_AGENT_DETAIL="${DJ_AGENT_DETAIL//$'\n'/\\n}"
  DJ_AGENT_DETAIL="${DJ_AGENT_DETAIL//$'\r'/\\r}"
  return 1
}

# dj_agent_scan LAUNCH_AGENTS_DIR USER_HOME TRELLIS_HOME
#
# Print one STATE<TAB>PATH<TAB>DETAIL row per org.trellis.disk-janitor* entry,
# PATH shell-quoted (printf %q) so any file name stays one field and pastes
# into a shell as one word:
#   match     a .plist equal to the installer's expected agent
#   mismatch  a .plist that differs in any way (launchd loads it)
#   disabled  any name not ending in .plist (renamed aside, never loaded)
# An absent directory prints nothing.
dj_agent_scan() {
  local dir="$1" user_home="$2" trellis_home="$3" entry name
  [ -d "$dir" ] || return 0
  for entry in "$dir"/org.trellis.disk-janitor* "$dir"/org.trellis.pi-spill-watchdog*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    name="${entry##*/}"
    case "$name" in
      *.plist) ;;
      *) printf 'disabled\t%q\t%s\n' "$entry" 'name does not end in .plist'; continue ;;
    esac
    if [ -L "$entry" ]; then
      printf 'mismatch\t%q\t%s\n' "$entry" 'is a symlink'
    elif [ ! -f "$entry" ]; then
      printf 'mismatch\t%q\t%s\n' "$entry" 'is not a regular file'
    elif dj_agent_matches "$entry" "${name%.plist}" "$user_home" "$trellis_home"; then
      if [ "${name%.plist}" = "$DJ_AGENT_APPLY_LABEL" ] && [ "${TRELLIS_TEST_SKIP_JANITOR_DRY_RUN:-0}" != "1" ]; then
        local dj_script=""
        if [ -n "${SCRIPT_DIR:-}" ] && [ -f "$SCRIPT_DIR/disk-janitor.sh" ]; then
          dj_script="$SCRIPT_DIR/disk-janitor.sh"
        elif [ -f "$(dirname "${BASH_SOURCE[0]}")/../disk-janitor.sh" ]; then
          dj_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/disk-janitor.sh"
        fi
        local dry_run_rc=0 dry_run_out=""
        if [ -n "$dj_script" ] && [ -x "$dj_script" ]; then
          dry_run_out="$(TRELLIS_HOME="$trellis_home" HOME="$user_home" "$dj_script" --apply --yes --safe-only --dehydrate --scopes "worktrees,caches,releases,pi,tmp,docker" --dry-run 2>&1)" || dry_run_rc=$?
        fi
        if [ "$dry_run_rc" -ne 0 ]; then
          printf 'degraded\t%q\t%s\n' "$entry" "nightly argv dry-run failed (exit $dry_run_rc): ${dry_run_out//$'\n'/ }"
          continue
        fi
      elif [ "${name%.plist}" = "$DJ_AGENT_WATCHDOG_LABEL" ]; then
        if ! dj_agent_verify_watchdog_entry "$trellis_home"; then
          printf 'degraded\t%q\t%s\n' "$entry" "watchdog entry point bytes or mode mismatch; remedy: trellis launchd --with-pi-watchdog"
          continue
        fi
      fi
      printf 'match\t%q\t\n' "$entry"
    else
      printf 'mismatch\t%q\t%s\n' "$entry" "$DJ_AGENT_DETAIL"
    fi
  done
}

# dj_agent_remedy PLIST_WORD — the shell command that unloads a mismatching
# agent and renames it aside, for PLIST_WORD as dj_agent_scan prints it
# (already shell-quoted). The renamed file is then reported as disabled.
dj_agent_remedy() {
  printf 'launchctl bootout gui/$(id -u) %s; mv %s %s.disabled-$(date +%%Y%%m%%d)' "$1" "$1" "$1"
}

# What the operator does after dj_agent_remedy, printed on its own line so the
# command above stays copy-paste safe.
# shellcheck disable=SC2034  # read by the installer and health-checks.sh
DJ_AGENT_REMEDY_NEXT='then re-run trellis launchd (add --with-apply for the nightly worktree agent, --with-pi-watchdog for the watchdog); trellis launchd --uninstall removes only agents that match the installer'

# dj_agent_write_tool_path TRELLIS_HOME CALLER_PATH [TMPDIR]
#
# Resolve directories for gh, docker, colima, pnpm, uv, bun, go, and lsof from
# the caller PATH. Drop entries under /var/folders/, under TMPDIR, or missing on
# disk. Canonicalize (realpath) directories before filtering so symlinks into
# /var/folders/ or TMPDIR are rejected. Write the deduplicated, existing
# directories to TRELLIS_HOME/state/disk-janitor/tool-path with mode 0600.
dj_agent_write_tool_path() {
  local trellis_home="$1" caller_path="$2" custom_tmp="${3:-${TMPDIR:-}}"
  local dest_dir dest_file tmp_file dir tool entry tmp_clean already real_dir dir_clean var_prefix
  local -a tools=(gh docker colima pnpm uv bun go lsof)
  local -a path_dirs=() resolved_dirs=()

  [ -n "$trellis_home" ] || return 1
  dest_dir="$trellis_home/state/disk-janitor"
  dest_file="$dest_dir/tool-path"

  if [ ! -d "$dest_dir" ]; then
    mkdir -p "$dest_dir" || return 1
  fi
  chmod 700 "$dest_dir" 2>/dev/null || true

  if [ -n "$caller_path" ]; then
    local old_ifs="$IFS"
    IFS=':'
    # shellcheck disable=SC2206
    path_dirs=($caller_path)
    IFS="$old_ifs"
  fi

  tmp_clean=""
  if [ -n "$custom_tmp" ]; then
    tmp_clean="$(cd "$custom_tmp" 2>/dev/null && pwd -P || echo "$custom_tmp")"
    tmp_clean="${tmp_clean%/}"
  fi

  var_prefix="${TRELLIS_TEST_VAR_FOLDERS_PREFIX:-/var/folders}"
  var_prefix="${var_prefix%/}"

  for tool in "${tools[@]}"; do
    for dir in "${path_dirs[@]+"${path_dirs[@]}"}"; do
      [ -n "$dir" ] || continue
      # Must be an absolute path
      case "$dir" in /*) ;; *) continue ;; esac
      # Must exist on disk
      [ -d "$dir" ] || continue

      # Resolve symlinks (realpath) before filtering
      real_dir="$(cd "$dir" 2>/dev/null && pwd -P || echo "$dir")"
      real_dir="${real_dir%/}"
      dir_clean="${dir%/}"

      # Must not be under /var/folders/ or /private/var/folders/
      if [ -n "$var_prefix" ]; then
        case "$dir_clean" in
          "$var_prefix"/*|"$var_prefix") continue ;;
        esac
        case "$real_dir" in
          "$var_prefix"/*|"$var_prefix") continue ;;
        esac
      fi
      case "$dir_clean" in
        /var/folders/*|/var/folders|/private/var/folders/*|/private/var/folders) continue ;;
      esac
      case "$real_dir" in
        /var/folders/*|/var/folders|/private/var/folders/*|/private/var/folders) continue ;;
      esac

      # Must not be under TMPDIR
      if [ -n "$tmp_clean" ]; then
        case "$dir_clean" in
          "$tmp_clean"/*|"$tmp_clean") continue ;;
        esac
        case "$real_dir" in
          "$tmp_clean"/*|"$tmp_clean") continue ;;
        esac
      fi

      # Must contain the executable tool
      if [ -x "$dir/$tool" ] && [ ! -d "$dir/$tool" ]; then
        already=false
        for entry in "${resolved_dirs[@]+"${resolved_dirs[@]}"}"; do
          if [ "$entry" = "$real_dir" ]; then
            already=true
            break
          fi
        done
        if [ "$already" = false ]; then
          resolved_dirs+=("$real_dir")
        fi
        break
      fi
    done
  done

  tmp_file="$(mktemp "$dest_dir/tool-path.XXXXXX")" || return 1
  chmod 600 "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  for entry in "${resolved_dirs[@]+"${resolved_dirs[@]}"}"; do
    printf '%s\n' "$entry" >> "$tmp_file"
  done
  mv -f "$tmp_file" "$dest_file" || { rm -f "$tmp_file"; return 1; }
  chmod 600 "$dest_file" 2>/dev/null || true
  return 0
}

dj_agent_watchdog_entry_content() {
  cat <<'WATCHDOG_STABLE_EOF'
#!/usr/bin/env bash
# Trellis pi-spill-watchdog stable entry point.
# Resolves the active release from TRELLIS_HOME/config.json on each run
# and dispatches to the watchdog script inside that release payload.
set -euo pipefail

trellis_home="${TRELLIS_HOME:-}"
if [ -z "$trellis_home" ]; then
  printf 'pi-spill-watchdog: TRELLIS_HOME is not set\n' >&2
  exit 0
fi

config="$trellis_home/config.json"
if [ ! -f "$config" ]; then
  printf 'pi-spill-watchdog: config file missing: %s\n' "$config" >&2
  exit 0
fi

active_release=""
if [ -x "/usr/bin/plutil" ]; then
  active_release="$(/usr/bin/plutil -extract active_cli_release raw -o - "$config" 2>/dev/null || true)"
fi
if [ -z "$active_release" ] && command -v jq >/dev/null 2>&1; then
  active_release="$(jq -r '.active_cli_release // empty' "$config" 2>/dev/null || true)"
fi
if [ -z "$active_release" ] && command -v python3 >/dev/null 2>&1; then
  active_release="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("active_cli_release") or "")' "$config" 2>/dev/null || true)"
fi

if [ -z "$active_release" ]; then
  printf 'pi-spill-watchdog: could not resolve active_cli_release from %s\n' "$config" >&2
  exit 0
fi

case "$active_release" in
  *[!0-9A-Za-z._-]*|'')
    printf 'pi-spill-watchdog: invalid active_cli_release: %s\n' "$active_release" >&2
    exit 0
    ;;
esac

releases_dir="$trellis_home/releases"
if [ ! -d "$releases_dir" ]; then
  printf 'pi-spill-watchdog: releases directory missing: %s\n' "$releases_dir" >&2
  exit 0
fi

canonical_releases="$(cd "$releases_dir" 2>/dev/null && pwd -P)" || {
  printf 'pi-spill-watchdog: could not resolve releases directory: %s\n' "$releases_dir" >&2
  exit 0
}

watchdog_script="$releases_dir/$active_release/payload/scripts/pi-spill-watchdog.sh"
if [ ! -f "$watchdog_script" ] || [ ! -x "$watchdog_script" ]; then
  printf 'pi-spill-watchdog: watchdog script missing or not executable in release %s: %s\n' "$active_release" "$watchdog_script" >&2
  exit 0
fi

if [ -L "$watchdog_script" ]; then
  printf 'pi-spill-watchdog: watchdog script is a symlink: %s\n' "$watchdog_script" >&2
  exit 0
fi

watchdog_dir="$(cd "$(dirname "$watchdog_script")" 2>/dev/null && pwd -P)" || {
  printf 'pi-spill-watchdog: could not resolve watchdog directory: %s\n' "$watchdog_script" >&2
  exit 0
}

case "$watchdog_dir" in
  "$canonical_releases/"*) ;;
  *)
    printf 'pi-spill-watchdog: watchdog script escaped release store: %s -> %s\n' "$watchdog_script" "$watchdog_dir" >&2
    exit 0
    ;;
esac

release_json="$releases_dir/$active_release/release.json"
if [ ! -f "$release_json" ] || [ -L "$release_json" ]; then
  printf 'pi-spill-watchdog: release manifest missing or invalid in release %s: %s\n' "$active_release" "$release_json" >&2
  exit 0
fi

expected_oid=""
if command -v jq >/dev/null 2>&1; then
  expected_oid="$(jq -r '.tree[]? | select(.path == "scripts/pi-spill-watchdog.sh") | .oid // empty' "$release_json" 2>/dev/null || true)"
fi
if [ -z "$expected_oid" ] && command -v python3 >/dev/null 2>&1; then
  expected_oid="$(python3 -c 'import json, sys; print(next((e.get("oid") for e in json.load(open(sys.argv[1])).get("tree", []) if e.get("path") == sys.argv[2]), ""))' "$release_json" "scripts/pi-spill-watchdog.sh" 2>/dev/null || true)"
fi

if [ -z "$expected_oid" ]; then
  printf 'pi-spill-watchdog: watchdog script missing from manifest in release %s: %s\n' "$active_release" "$release_json" >&2
  exit 0
fi

actual_oid=""
if command -v git >/dev/null 2>&1; then
  actual_oid="$(git hash-object --no-filters "$watchdog_script" 2>/dev/null || true)"
fi
if [ -z "$actual_oid" ] && command -v python3 >/dev/null 2>&1; then
  actual_oid="$(python3 -c 'import hashlib, sys; c = open(sys.argv[1], "rb").read(); print(hashlib.sha1(b"blob " + str(len(c)).encode() + c).hexdigest())' "$watchdog_script" 2>/dev/null || true)"
fi

if [ -z "$actual_oid" ] || [ "$actual_oid" != "$expected_oid" ]; then
  printf 'pi-spill-watchdog: watchdog script manifest verification failed in release %s: expected %s, got %s\n' "$active_release" "$expected_oid" "$actual_oid" >&2
  exit 0
fi

exec "$watchdog_script" "$@"
WATCHDOG_STABLE_EOF
}

# dj_agent_verify_watchdog_entry TRELLIS_HOME
# Verify the stable entry point pi-spill-watchdog in TRELLIS_HOME/state/disk-janitor
# compares byte-for-byte and mode 0500 with what the installer writes.
dj_agent_verify_watchdog_entry() {
  local trellis_home="$1"
  local dest_dir dest_file mode dir_mode expected_hash actual_hash

  [ -n "$trellis_home" ] || return 1
  dest_dir="$trellis_home/state/disk-janitor"
  dest_file="$dest_dir/pi-spill-watchdog"

  [ -d "$dest_dir" ] || return 1
  [ ! -L "$dest_dir" ] || return 1

  dir_mode="$(stat -f '%Lp' "$dest_dir" 2>/dev/null || stat -c '%a' "$dest_dir" 2>/dev/null || true)"
  case "$dir_mode" in
    700|0700) ;;
    *) return 1 ;;
  esac

  [ -f "$dest_file" ] || return 1
  [ ! -L "$dest_file" ] || return 1

  mode="$(stat -f '%Lp' "$dest_file" 2>/dev/null || stat -c '%a' "$dest_file" 2>/dev/null || true)"
  case "$mode" in
    500|0500) ;;
    *) return 1 ;;
  esac

  expected_hash="$(dj_agent_watchdog_entry_content | shasum -a 256 2>/dev/null || dj_agent_watchdog_entry_content | sha256sum 2>/dev/null || true)"
  expected_hash="${expected_hash%% *}"
  actual_hash="$(shasum -a 256 "$dest_file" 2>/dev/null || sha256sum "$dest_file" 2>/dev/null || true)"
  actual_hash="${actual_hash%% *}"

  [ -n "$expected_hash" ] && [ "$expected_hash" = "$actual_hash" ] || return 1
  return 0
}

# dj_agent_write_watchdog_entry TRELLIS_HOME
#
# Writes the stable entry point for the pi-spill-watchdog LaunchAgent to
# TRELLIS_HOME/state/disk-janitor/pi-spill-watchdog. Enforces the state directory
# to 0700 on every install and writes the entry point with mode 0500 atomically.
dj_agent_write_watchdog_entry() {
  local trellis_home="$1"
  local dest_dir dest_file tmp_file

  [ -n "$trellis_home" ] || return 1
  dest_dir="$trellis_home/state/disk-janitor"
  dest_file="$dest_dir/pi-spill-watchdog"

  if [ ! -d "$dest_dir" ]; then
    mkdir -p "$dest_dir" || return 1
  fi
  chmod 700 "$dest_dir" || return 1

  tmp_file="$(mktemp "$dest_dir/pi-spill-watchdog.XXXXXX")" || return 1
  dj_agent_watchdog_entry_content > "$tmp_file" || { rm -f "$tmp_file"; return 1; }

  chmod 500 "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  mv -f "$tmp_file" "$dest_file" || { rm -f "$tmp_file"; return 1; }
  chmod 500 "$dest_file" 2>/dev/null || true
  return 0
}

