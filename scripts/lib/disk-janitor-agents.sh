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
DJ_AGENT_PLUTIL='/usr/bin/plutil'

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
    "$user_home/.local/bin/trellis"
    disk-janitor
  )
  case "$label" in
    "$DJ_AGENT_REPORT_LABEL")
      DJ_AGENT_EXPECTED_ARGV+=(--report)
      DJ_AGENT_EXPECTED_HOUR=3
      DJ_AGENT_EXPECTED_MINUTE=30
      ;;
    "$DJ_AGENT_APPLY_LABEL")
      DJ_AGENT_EXPECTED_ARGV+=(--apply --scopes worktrees --yes --safe-only)
      DJ_AGENT_EXPECTED_HOUR=4
      DJ_AGENT_EXPECTED_MINUTE=0
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
    DJ_AGENT_DETAIL="not an installer-managed agent name (expected $DJ_AGENT_REPORT_LABEL.plist or $DJ_AGENT_APPLY_LABEL.plist)"
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
          *) details+=("no --scopes: the janitor falls back to its default scopes, docker included") ;;
        esac
        ;;
    esac
    i=0
    while [ "$i" -lt "$count" ]; do
      case "${found[$i]}" in
        --scopes=*docker*) details+=("docker in --scopes") ;;
        --scopes)
          case "${found[$((i + 1))]-}" in *docker*) details+=("docker in --scopes") ;; esac
          ;;
      esac
      i=$((i + 1))
    done
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
  for entry in "$dir"/org.trellis.disk-janitor*; do
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
DJ_AGENT_REMEDY_NEXT='then re-run trellis launchd (add --with-apply for the nightly worktree agent); trellis launchd --uninstall removes only agents that match the installer'
