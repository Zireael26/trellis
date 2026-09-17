#!/usr/bin/env bash
# Deterministically expand the immutable inheritance payload into owned project
# leaves and HOME-scoped user leaves. Source this library or execute it with --payload.
#
# Exit classes: 0 success; 2 usage; 3 destination conflict; 4 invalid payload
# state; 5 unavailable local capability/path. Bash 3.2 compatible.

if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ]; then
  _SURFACE_PLAN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=trellis-home.sh
  . "$_SURFACE_PLAN_LIB_DIR/trellis-home.sh"
  # shellcheck source=skill-roots.sh
  . "$_SURFACE_PLAN_LIB_DIR/skill-roots.sh"
else
  _SURFACE_PLAN_LIB_DIR=""
fi

_SURFACE_PLAN_HARNESSES=()
_SURFACE_PLAN_DESTINATIONS=()
_SURFACE_PLAN_RECORDS=()
_SURFACE_PLAN_OPTIONAL_MISSING=()
_SURFACE_PLAN_TEMP_FILES=()
_SURFACE_PLAN_LAST_TMP=""
_SURFACE_PLAN_CANONICAL_HOME=""

surface_plan_err() {
  printf 'surface-plan: %s\n' "$*" >&2
}

surface_plan_is_safe_text() {
  local value="${1:-}"
  [ -n "$value" ] || return 1
  case "$value" in
    *$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  return 0
}

surface_plan_is_safe_relative_path() {
  local value="${1:-}"
  surface_plan_is_safe_text "$value" || return 1
  case "$value" in
    /*|*//*|.|..|./*|../*|*/.|*/..|*/./*|*/../*) return 1 ;;
  esac
  return 0
}

surface_plan_is_safe_destination() {
  local destination="${1:-}"
  surface_plan_is_safe_relative_path "$destination" || return 1
  case "$destination" in
    .[Gg][Ii][Tt]|.[Gg][Ii][Tt]/*|.[Tt][Rr][Ee][Ll][Ll][Ii][Ss]|.[Tt][Rr][Ee][Ll][Ll][Ii][Ss]/*) return 1 ;;
  esac
  return 0
}

surface_plan_realpath() {
  local candidate="${1:-}" parent base target hops=0

  case "$candidate" in
    /*) ;;
    *) return 1 ;;
  esac

  while [ -L "$candidate" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    target="$(readlink "$candidate")" || return 1
    case "$target" in
      /*) candidate="$target" ;;
      *) candidate="$(dirname "$candidate")/$target" ;;
    esac
    parent="$(cd -P "$(dirname "$candidate")" 2>/dev/null && pwd -P)" || return 1
    candidate="$parent/$(basename "$candidate")"
  done

  parent="$(cd -P "$(dirname "$candidate")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename "$candidate")"
  [ -e "$parent/$base" ] || return 1
  printf '%s/%s\n' "$parent" "$base"
}

surface_plan_prepare_user_home() {
  local home="${HOME:-}" canonical canonical_check

  if ! trellis_home_require_absolute_safe_path "HOME" "$home" >/dev/null 2>&1; then
    surface_plan_err "HOME is required as a safe absolute path for user harness planning"
    return "$TRELLIS_EX_USAGE"
  fi
  case "$home" in
    *//*|*/)
      surface_plan_err "HOME must be a canonical absolute path for user harness planning"
      return "$TRELLIS_EX_USAGE"
      ;;
  esac
  if [ ! -d "$home" ] || [ -L "$home" ]; then
    surface_plan_err "HOME is unavailable or is a symlink for user harness planning"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  canonical="$(CDPATH='' cd "$home" 2>/dev/null && pwd -P)" || {
    surface_plan_err "HOME cannot be canonicalized for user harness planning"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  canonical_check="$(surface_plan_realpath "$canonical" 2>/dev/null)" || canonical_check=""
  if ! trellis_home_require_absolute_safe_path "canonical HOME" "$canonical" >/dev/null 2>&1 \
     || [ ! -d "$canonical" ] || [ -L "$canonical" ] || [ "$canonical_check" != "$canonical" ]; then
    surface_plan_err "canonical HOME is malformed or unsafe"
    return "$TRELLIS_EX_STATE"
  fi
  _SURFACE_PLAN_CANONICAL_HOME="$canonical"
  return 0
}

surface_plan_resolve_home_destination() {
  local relative="$1" parent base remaining component candidate resolved

  if [ -z "$_SURFACE_PLAN_CANONICAL_HOME" ]; then
    surface_plan_err "internal error: canonical HOME is unavailable"
    return "$TRELLIS_EX_STATE"
  fi
  if ! surface_plan_is_safe_relative_path "$relative"; then
    surface_plan_err "unsafe HOME-relative destination: $relative"
    return "$TRELLIS_EX_STATE"
  fi

  resolved="$_SURFACE_PLAN_CANONICAL_HOME"
  case "$relative" in
    */*)
      parent="${relative%/*}"
      base="${relative##*/}"
      ;;
    *)
      parent="."
      base="$relative"
      ;;
  esac
  if [ "$parent" != "." ]; then
    remaining="$parent"
    while [ -n "$remaining" ]; do
      case "$remaining" in
        */*)
          component="${remaining%%/*}"
          remaining="${remaining#*/}"
          ;;
        *)
          component="$remaining"
          remaining=""
          ;;
      esac
      candidate="$resolved/$component"
      if [ -L "$candidate" ]; then
        surface_plan_err "HOME destination parent symlink escapes the canonical HOME safety boundary: $relative"
        return "$TRELLIS_EX_STATE"
      fi
      if [ -e "$candidate" ]; then
        if [ ! -d "$candidate" ]; then
          surface_plan_err "HOME destination parent is not a directory: $relative"
          return "$TRELLIS_EX_STATE"
        fi
      fi
      resolved="$candidate"
    done
  fi

  resolved="$resolved/$base"
  case "$resolved" in
    "$_SURFACE_PLAN_CANONICAL_HOME"/*) ;;
    *)
      surface_plan_err "HOME destination escapes canonical HOME: $relative"
      return "$TRELLIS_EX_STATE"
      ;;
  esac
  printf '%s\n' "$resolved"
}

surface_plan_payload_root() {
  local payload="${1:-}" payload_real

  if ! trellis_home_require_absolute_safe_path "payload root" "$payload" >/dev/null; then
    return "$TRELLIS_EX_USAGE"
  fi
  if [ ! -d "$payload" ]; then
    surface_plan_err "payload is unavailable: $payload"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  payload_real="$(surface_plan_realpath "$payload")" || {
    surface_plan_err "payload cannot be resolved: $payload"
    return "$TRELLIS_EX_STATE"
  }
  if [ ! -d "$payload_real" ]; then
    surface_plan_err "payload is not a directory: $payload"
    return "$TRELLIS_EX_STATE"
  fi
  printf '%s\n' "$payload_real"
}

surface_plan_require_source() {
  local payload="$1" relative="$2" expected_type="$3"
  local source source_real

  if ! surface_plan_is_safe_relative_path "$relative"; then
    surface_plan_err "unsafe source path in immutable payload: $relative"
    return "$TRELLIS_EX_STATE"
  fi

  source="$payload/$relative"
  if [ ! -e "$source" ] && [ ! -L "$source" ]; then
    surface_plan_err "required source is missing from immutable payload: $relative"
    return "$TRELLIS_EX_STATE"
  fi

  source_real="$(surface_plan_realpath "$source")" || {
    surface_plan_err "source cannot be resolved from immutable payload: $relative"
    return "$TRELLIS_EX_STATE"
  }
  case "$source_real" in
    "$payload"/*) ;;
    *)
      surface_plan_err "source symlink escapes immutable payload: $relative"
      return "$TRELLIS_EX_STATE"
      ;;
  esac
  if [ "$source_real" != "$source" ]; then
    surface_plan_err "source symlink collision inside immutable payload: $relative"
    return "$TRELLIS_EX_STATE"
  fi

  case "$expected_type" in
    file)
      if [ ! -f "$source" ] || [ -L "$source" ]; then
        surface_plan_err "required source is not a regular file: $relative"
        return "$TRELLIS_EX_STATE"
      fi
      ;;
    directory)
      if [ ! -d "$source" ] || [ -L "$source" ]; then
        surface_plan_err "required source is not a directory: $relative"
        return "$TRELLIS_EX_STATE"
      fi
      ;;
    *)
      surface_plan_err "internal error: unknown source type $expected_type"
      return "$TRELLIS_EX_STATE"
      ;;
  esac
  return 0
}

surface_plan_require_source_parent() {
  local payload="$1" relative="$2" parent
  parent="$(dirname "$relative")"
  [ "$parent" = "." ] && return 0
  surface_plan_require_source "$payload" "$parent" directory
}

surface_plan_make_tempfile() {
  _SURFACE_PLAN_LAST_TMP="$(mktemp "${TMPDIR:-/tmp}/trellis-surface-plan.XXXXXX")" || {
    surface_plan_err "could not create a temporary planning file"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  _SURFACE_PLAN_TEMP_FILES+=("$_SURFACE_PLAN_LAST_TMP")
}

surface_plan_cleanup() {
  local temporary
  for temporary in "${_SURFACE_PLAN_TEMP_FILES[@]+"${_SURFACE_PLAN_TEMP_FILES[@]}"}"; do
    [ -n "$temporary" ] && rm -f "$temporary"
  done
  _SURFACE_PLAN_TEMP_FILES=()
  _SURFACE_PLAN_LAST_TMP=""
}

surface_plan_assert_tree_safe() {
  local payload="$1" source="$2" temporary candidate relative resolved

  surface_plan_make_tempfile || return "$?"
  temporary="$_SURFACE_PLAN_LAST_TMP"
  if ! find -P "$source" -print0 > "$temporary"; then
    surface_plan_err "could not enumerate immutable source tree: ${source#"$payload"/}"
    return "$TRELLIS_EX_STATE"
  fi

  while IFS= read -r -d '' candidate; do
    relative="${candidate#"$payload"/}"
    if ! surface_plan_is_safe_relative_path "$relative"; then
      surface_plan_err "unsafe path inside immutable payload: $relative"
      return "$TRELLIS_EX_STATE"
    fi
    if [ -L "$candidate" ]; then
      resolved="$(surface_plan_realpath "$candidate")" || {
        surface_plan_err "source symlink cannot be resolved inside immutable payload: $relative"
        return "$TRELLIS_EX_STATE"
      }
      case "$resolved" in
        "$payload"/*)
          surface_plan_err "source symlink collision inside immutable payload: $relative"
          ;;
        *)
          surface_plan_err "source symlink escapes immutable payload: $relative"
          ;;
      esac
      return "$TRELLIS_EX_STATE"
    fi
  done < "$temporary"
  return 0
}

surface_plan_path_has_excluded_component() {
  local relative="$1" component remaining excluded
  shift
  remaining="$relative"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      */*)
        component="${remaining%%/*}"
        remaining="${remaining#*/}"
        ;;
      *)
        component="$remaining"
        remaining=""
        ;;
    esac
    for excluded in "$@"; do
      [ "$component" = "$excluded" ] && return 0
    done
  done
  return 1
}

surface_plan_runtime_target() {
  local destination="$1" source="$2" parent remaining component up=""

  parent="$(dirname "$destination")"
  if [ "$parent" = "." ]; then
    printf '.trellis/runtime/%s\n' "$source"
    return 0
  fi

  remaining="$parent"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      */*)
        component="${remaining%%/*}"
        remaining="${remaining#*/}"
        ;;
      *)
        component="$remaining"
        remaining=""
        ;;
    esac
    [ "$component" = "." ] && continue
    if [ -n "$up" ]; then
      up="$up/.."
    else
      up=".."
    fi
  done
  printf '%s/.trellis/runtime/%s\n' "$up" "$source"
}

surface_plan_project_target() {
  local destination="$1" source="$2" parent remaining component up=""

  parent="$(dirname "$destination")"
  if [ "$parent" = "." ]; then
    printf '%s\n' "$source"
    return 0
  fi
  remaining="$parent"
  while [ -n "$remaining" ]; do
    case "$remaining" in
      */*)
        component="${remaining%%/*}"
        remaining="${remaining#*/}"
        ;;
      *)
        component="$remaining"
        remaining=""
        ;;
    esac
    [ "$component" = "." ] && continue
    if [ -n "$up" ]; then
      up="$up/.."
    else
      up=".."
    fi
  done
  printf '%s/%s\n' "$up" "$source"
}

surface_plan_register_destination() {
  local destination="$1" existing
  for existing in "${_SURFACE_PLAN_DESTINATIONS[@]+"${_SURFACE_PLAN_DESTINATIONS[@]}"}"; do
    if [ "$existing" = "$destination" ]; then
      surface_plan_err "duplicate managed destination: $destination"
      return "$TRELLIS_EX_CONFLICT"
    fi
  done
  _SURFACE_PLAN_DESTINATIONS+=("$destination")
  return 0
}

# User destinations are absolute by construction; project destinations remain
# relative. Normalize every user destination in one Perl process so reserved
# control-path and duplicate detection cover Unicode canonical equivalence and
# full case folding rather than jq's ASCII-only folding. Duplicate checks are
# deliberately conservative on case-sensitive filesystems too, matching
# attachment's no-alias contract.
surface_plan_validate_user_destination_aliases() {
  local destination violation violation_kind violation_path
  local -a user_destinations=()

  for destination in "${_SURFACE_PLAN_DESTINATIONS[@]+"${_SURFACE_PLAN_DESTINATIONS[@]}"}"; do
    case "$destination" in
      /*) user_destinations+=("$destination") ;;
    esac
  done
  [ "${#user_destinations[@]}" -gt 0 ] || return 0

  if ! command -v perl >/dev/null 2>&1; then
    surface_plan_err "Perl Unicode normalization is required for user harness planning"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if ! violation="$(perl -MUnicode::Normalize -Mfeature=fc -CAO -e '
      my $home = NFC(fc(NFC(shift @ARGV)));
      my (%seen, %duplicates, %reserved);
      for my $path (@ARGV) {
        my $key = NFC(fc(NFC($path)));
        my $prefix = $home . "/";
        if (index($key, $prefix) == 0) {
          my ($first) = split m{/}, substr($key, length($prefix));
          $reserved{$key} = 1 if $first eq ".git" || $first eq ".trellis";
        }
        $duplicates{$key} = 1 if $seen{$key}++;
      }
      my @reserved = sort keys %reserved;
      my @duplicates = sort keys %duplicates;
      if (@reserved) {
        print "reserved\t", $reserved[0];
      } elsif (@duplicates) {
        print "duplicate\t", $duplicates[0];
      }
    ' -- "$_SURFACE_PLAN_CANONICAL_HOME" "${user_destinations[@]}")"; then
    surface_plan_err "Perl Unicode normalization is unavailable for user harness planning"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  [ -n "$violation" ] || return 0
  violation_kind="${violation%%$'\t'*}"
  violation_path="${violation#*$'\t'}"
  case "$violation_kind" in
    reserved)
      surface_plan_err "reserved managed destination alias: $violation_path"
      return "$TRELLIS_EX_STATE"
      ;;
    duplicate)
      surface_plan_err "duplicate managed destination alias: $violation_path"
      return "$TRELLIS_EX_CONFLICT"
      ;;
    *)
      surface_plan_err "internal error: invalid user destination alias result"
      return "$TRELLIS_EX_STATE"
      ;;
  esac
}

surface_plan_add_link_record() {
  local harness="$1" source="$2" destination="$3" executable="$4" payload="${5:-}" target record

  surface_plan_register_destination "$destination" || return "$?"
  if [ "$harness" = "user" ]; then
    if [ -z "$payload" ]; then
      surface_plan_err "internal error: user symlink record is missing its immutable payload"
      return "$TRELLIS_EX_STATE"
    fi
    target="$payload/$source"
  else
    target="$(surface_plan_runtime_target "$destination" "$source")" || return "$TRELLIS_EX_STATE"
  fi
  record="$(jq -cn \
    --arg harness "$harness" \
    --arg source "$source" \
    --arg destination "$destination" \
    --arg target "$target" \
    --argjson executable "$executable" \
    '{harness: $harness, kind: "symlink", source: $source, source_scope: "payload", destination: $destination, target: $target, executable: $executable}')" || {
      surface_plan_err "could not encode symlink plan record"
      return "$TRELLIS_EX_STATE"
    }
  _SURFACE_PLAN_RECORDS+=("$record")
  return 0
}

surface_plan_add_project_link_record() {
  local harness="$1" source="$2" fallback_source="$3" destination="$4"
  local target fallback_target record

  surface_plan_register_destination "$destination" || return "$?"
  target="$(surface_plan_project_target "$destination" "$source")" || return "$TRELLIS_EX_STATE"
  fallback_target="$(surface_plan_runtime_target "$destination" "$fallback_source")" || return "$TRELLIS_EX_STATE"
  record="$(jq -cn \
    --arg harness "$harness" \
    --arg source "$source" \
    --arg target "$target" \
    --arg fallback_source "$fallback_source" \
    --arg destination "$destination" \
    --arg fallback_target "$fallback_target" \
    '{harness: $harness, kind: "symlink", source: $source, source_scope: "project", destination: $destination, target: $target, fallback_source: $fallback_source, fallback_source_scope: "payload", fallback_target: $fallback_target, target_policy: "project-if-present-else-payload", executable: false}')" || {
      surface_plan_err "could not encode project symlink plan record"
      return "$TRELLIS_EX_STATE"
    }
  _SURFACE_PLAN_RECORDS+=("$record")
  return 0
}

surface_plan_add_render_record() {
  local collection="$1" harness="$2" template="$3" destination="$4" merge="$5" mode="$6" required="$7" render_if_absent="$8" record

  surface_plan_register_destination "$destination" || return "$?"
  record="$(jq -cn \
    --arg harness "$harness" \
    --arg template "$template" \
    --arg destination "$destination" \
    --arg merge "$merge" \
    --arg mode "$mode" \
    --argjson required "$required" \
    --argjson render_if_absent "$render_if_absent" \
    '{harness: $harness, kind: "render", source: $template, template: $template, destination: $destination, merge: $merge, mode: $mode, required: $required, render_if_absent: $render_if_absent}')" || {
      surface_plan_err "could not encode render plan record"
      return "$TRELLIS_EX_STATE"
    }
  case "$collection" in
    artifact) _SURFACE_PLAN_RECORDS+=("$record") ;;
    optional-missing) _SURFACE_PLAN_OPTIONAL_MISSING+=("$record") ;;
    *)
      surface_plan_err "internal error: unknown render record collection $collection"
      return "$TRELLIS_EX_STATE"
      ;;
  esac
  return 0
}

surface_plan_emit_direct_link() {
  local payload="$1" harness="$2" entry="$3" source destination executable

  source="$(printf '%s' "$entry" | jq -r '.source')" || return "$TRELLIS_EX_STATE"
  destination="$(printf '%s' "$entry" | jq -r '.destination')" || return "$TRELLIS_EX_STATE"
  executable="$(printf '%s' "$entry" | jq -r '.executable // false')" || return "$TRELLIS_EX_STATE"
  if [ "$harness" = "user" ]; then
    destination="$(surface_plan_resolve_home_destination "$destination")" || return "$?"
    if [ -d "$payload/$source" ] && [ ! -L "$payload/$source" ]; then
      surface_plan_require_source "$payload" "$source" directory || return "$?"
      surface_plan_assert_tree_safe "$payload" "$payload/$source" || return "$?"
    else
      surface_plan_require_source "$payload" "$source" file || return "$?"
    fi
  else
    surface_plan_require_source "$payload" "$source" file || return "$?"
  fi
  surface_plan_add_link_record "$harness" "$source" "$destination" "$executable" "$payload"
}

surface_plan_emit_project_link() {
  local payload="$1" harness="$2" entry="$3" source fallback_source destination

  source="$(printf '%s' "$entry" | jq -r '.project_target')" || return "$TRELLIS_EX_STATE"
  fallback_source="$(printf '%s' "$entry" | jq -r '.fallback_source')" || return "$TRELLIS_EX_STATE"
  destination="$(printf '%s' "$entry" | jq -r '.destination')" || return "$TRELLIS_EX_STATE"
  surface_plan_require_source "$payload" "$fallback_source" file || return "$?"
  surface_plan_add_project_link_record "$harness" "$source" "$fallback_source" "$destination"
}

surface_plan_emit_children_link() {
  local payload="$1" harness="$2" entry="$3"
  local source destination_dir entry_type suffix required_file recursive temporary candidate child_relative
  local source_relative destination executable exclusions_file unsorted_file sorted_file
  local -a excluded_dirs=()
  local -a candidates=()
  local sorted_candidate

  source="$(printf '%s' "$entry" | jq -r '.source_children')" || return "$TRELLIS_EX_STATE"
  destination_dir="$(printf '%s' "$entry" | jq -r '.destination_dir')" || return "$TRELLIS_EX_STATE"
  entry_type="$(printf '%s' "$entry" | jq -r '.entry_type')" || return "$TRELLIS_EX_STATE"
  suffix="$(printf '%s' "$entry" | jq -r '.suffix // ""')" || return "$TRELLIS_EX_STATE"
  required_file="$(printf '%s' "$entry" | jq -r '.required_file // ""')" || return "$TRELLIS_EX_STATE"
  recursive="$(printf '%s' "$entry" | jq -r '.recursive // false')" || return "$TRELLIS_EX_STATE"
  executable="$(printf '%s' "$entry" | jq -r '.executable // false')" || return "$TRELLIS_EX_STATE"
  surface_plan_make_tempfile || return "$?"
  exclusions_file="$_SURFACE_PLAN_LAST_TMP"
  if ! jq -r '.exclude_dirs // [] | .[]' <<< "$entry" > "$exclusions_file"; then
    surface_plan_err "could not enumerate source exclusions: $source"
    return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r source_relative; do
    [ -n "$source_relative" ] && excluded_dirs+=("$source_relative")
  done < "$exclusions_file"

  surface_plan_require_source "$payload" "$source" directory || return "$?"
  surface_plan_assert_tree_safe "$payload" "$payload/$source" || return "$?"

  surface_plan_make_tempfile || return "$?"
  temporary="$_SURFACE_PLAN_LAST_TMP"
  if ! find -P "$payload/$source" -print0 > "$temporary"; then
    surface_plan_err "could not enumerate immutable source children: $source"
    return "$TRELLIS_EX_STATE"
  fi

  while IFS= read -r -d '' candidate; do
    [ "$candidate" = "$payload/$source" ] && continue
    child_relative="${candidate#"$payload/$source/"}"
    if [ "$recursive" != "true" ]; then
      case "$child_relative" in
        */*) continue ;;
      esac
    fi
    if surface_plan_path_has_excluded_component "$child_relative" "${excluded_dirs[@]+"${excluded_dirs[@]}"}"; then
      continue
    fi

    case "$entry_type" in
      directory)
        if [ -d "$candidate" ] && [ ! -L "$candidate" ]; then
          candidates+=("$candidate")
        fi
        ;;
      file)
        case "$(basename "$candidate")" in
          *"$suffix")
            if [ -f "$candidate" ] && [ ! -L "$candidate" ]; then
              candidates+=("$candidate")
            elif [ -e "$candidate" ]; then
              surface_plan_err "filtered source is not a regular file: ${candidate#"$payload"/}"
              return "$TRELLIS_EX_STATE"
            fi
            ;;
        esac
        ;;
      *)
        surface_plan_err "internal error: unknown source-child entry type $entry_type"
        return "$TRELLIS_EX_STATE"
        ;;
    esac
  done < "$temporary"

  if [ "${#candidates[@]}" -eq 0 ]; then
    return 0
  fi

  surface_plan_make_tempfile || return "$?"
  unsorted_file="$_SURFACE_PLAN_LAST_TMP"
  if ! printf '%s\n' "${candidates[@]}" > "$unsorted_file"; then
    surface_plan_err "could not stage immutable source candidates: $source"
    return "$TRELLIS_EX_STATE"
  fi
  surface_plan_make_tempfile || return "$?"
  sorted_file="$_SURFACE_PLAN_LAST_TMP"
  if ! LC_ALL=C sort "$unsorted_file" > "$sorted_file"; then
    surface_plan_err "could not sort immutable source candidates: $source"
    return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r sorted_candidate || [ -n "$sorted_candidate" ]; do
    child_relative="${sorted_candidate#"$payload/$source/"}"
    source_relative="$source/$child_relative"
    destination="$destination_dir/$child_relative"
    if [ "$harness" = "user" ]; then
      destination="$(surface_plan_resolve_home_destination "$destination")" || return "$?"
    fi

    if [ "$entry_type" = "directory" ] && [ -n "$required_file" ]; then
      surface_plan_require_source "$payload" "$source_relative/$required_file" file || return "$?"
    else
      surface_plan_require_source "$payload" "$source_relative" "$entry_type" || return "$?"
    fi
    surface_plan_add_link_record "$harness" "$source_relative" "$destination" "$executable" "$payload" || return "$?"
  done < "$sorted_file"

  return 0
}

# `render_if_absent` marks a seed render: the payload owns the bytes only while
# the destination has none of its own. The planner emits the record without
# inspecting the final destination and remains no-write, so attach owns the
# create-only decision. Restricted to `replace` by the manifest validator:
# `explicit-json` already coexists with destination keys by merging, so a
# skip-if-exists rule there would only mean "never merge".
surface_plan_emit_render() {
  local payload="$1" harness="$2" entry="$3"
  local template destination merge mode required render_if_absent source_path

  template="$(printf '%s' "$entry" | jq -r '.template')" || return "$TRELLIS_EX_STATE"
  destination="$(printf '%s' "$entry" | jq -r '.destination')" || return "$TRELLIS_EX_STATE"
  if [ "$harness" = "user" ]; then
    destination="$(surface_plan_resolve_home_destination "$destination")" || return "$?"
  fi
  merge="$(printf '%s' "$entry" | jq -r '.merge')" || return "$TRELLIS_EX_STATE"
  mode="$(printf '%s' "$entry" | jq -r '.mode')" || return "$TRELLIS_EX_STATE"
  required="$(printf '%s' "$entry" | jq -r '.required')" || return "$TRELLIS_EX_STATE"
  render_if_absent="$(printf '%s' "$entry" | jq -r '.render_if_absent // false')" || return "$TRELLIS_EX_STATE"
  source_path="$payload/$template"
  surface_plan_require_source_parent "$payload" "$template" || return "$?"

  if [ -e "$source_path" ] || [ -L "$source_path" ]; then
    surface_plan_require_source "$payload" "$template" file || return "$?"
    surface_plan_add_render_record artifact "$harness" "$template" "$destination" "$merge" "$mode" "$required" "$render_if_absent"
    return "$?"
  fi

  if [ "$required" = "true" ]; then
    surface_plan_err "required render template is missing from immutable payload: $template"
    return "$TRELLIS_EX_STATE"
  fi
  surface_plan_add_render_record optional-missing "$harness" "$template" "$destination" "$merge" "$mode" "$required" "$render_if_absent"
}

surface_plan_emit_link_entry() {
  local payload="$1" harness="$2" entry="$3" direct project
  direct="$(printf '%s' "$entry" | jq -r 'has("source")')" || return "$TRELLIS_EX_STATE"
  project="$(printf '%s' "$entry" | jq -r 'has("project_target")')" || return "$TRELLIS_EX_STATE"
  if [ "$direct" = "true" ]; then
    surface_plan_emit_direct_link "$payload" "$harness" "$entry"
  elif [ "$project" = "true" ]; then
    surface_plan_emit_project_link "$payload" "$harness" "$entry"
  else
    surface_plan_emit_children_link "$payload" "$harness" "$entry"
  fi
}

surface_plan_emit_harness() {
  local payload="$1" manifest="$2" harness="$3" entry links_file render_file

  if [ "$harness" = "user" ]; then
    surface_plan_prepare_user_home || return "$?"
  fi

  surface_plan_make_tempfile || return "$?"
  links_file="$_SURFACE_PLAN_LAST_TMP"
  if ! jq -c --arg harness "$harness" '.harnesses[$harness].links[]' "$manifest" > "$links_file"; then
    surface_plan_err "could not enumerate links for harness: $harness"
    return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    surface_plan_emit_link_entry "$payload" "$harness" "$entry" || return "$?"
  done < "$links_file"

  surface_plan_make_tempfile || return "$?"
  render_file="$_SURFACE_PLAN_LAST_TMP"
  if ! jq -c --arg harness "$harness" '.harnesses[$harness].render[]' "$manifest" > "$render_file"; then
    surface_plan_err "could not enumerate renders for harness: $harness"
    return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    surface_plan_emit_render "$payload" "$harness" "$entry" || return "$?"
  done < "$render_file"
  return 0
}

surface_plan_validate_manifest() {
  local manifest="$1" harness require_user=false require_pi=false
  local shared_root pi_root codex_root destinations_file destination skill
  local shared_names="" pi_names="" codex_names="" nl pi_scan codex_scan

  for harness in "${_SURFACE_PLAN_HARNESSES[@]+"${_SURFACE_PLAN_HARNESSES[@]}"}"; do
    if [ "$harness" = "user" ]; then
      require_user=true
    elif [ "$harness" = "pi" ]; then
      require_pi=true
    fi
  done
  if ! jq -e --argjson require_user "$require_user" --argjson require_pi "$require_pi" '
    def safe_text:
      if type != "string" then false
      else length > 0
        and (contains("\u0000") | not)
        and (contains("\t") | not)
        and (contains("\n") | not)
        and (contains("\r") | not)
      end;
    def safe_component:
      if safe_text then
        (contains("/") | not) and . != "." and . != ".."
      else false end;
    def safe_relative_path:
      if safe_text then
        (startswith("/") | not)
        and (endswith("/") | not)
        and (split("/") | (all(.[]; safe_component)))
      else false end;
    def safe_destination:
      if safe_relative_path then
        (ascii_downcase
         | . != ".git" and (startswith(".git/") | not)
         and . != ".trellis" and (startswith(".trellis/") | not))
      else false end;
    def valid_suffix:
      if safe_component then startswith(".") else false end;
    def allowed($allowed_keys): ((keys - $allowed_keys) | length) == 0;
    def optional_boolean($key):
      if has($key) then (.[$key] | type == "boolean") else true end;
    def valid_home_marker($home):
      if $home
      then has("destination_home") and .destination_home == true
      else (has("destination_home") | not)
      end;
    def valid_direct_link($home):
      if type == "object" and has("source") and has("destination")
         and (has("source_children") | not) and (has("project_target") | not)
      then
        allowed(if $home
                then ["destination", "destination_home", "executable", "source"]
                else ["destination", "executable", "source"]
                end)
        and valid_home_marker($home)
        and (.source | safe_relative_path)
        and (.destination | safe_destination)
        and optional_boolean("executable")
      else false end;
    def valid_project_link($home):
      if $home then false
      elif type == "object" and has("project_target") and has("fallback_source") and has("destination")
           and (has("source") | not) and (has("source_children") | not)
      then
        allowed(["destination", "fallback_source", "project_target"])
        and (.project_target | safe_relative_path)
        and (.fallback_source | safe_relative_path)
        and (.destination | safe_destination)
      else false end;
    def valid_children_link($home):
      if type == "object" and has("source_children") and has("destination_dir") and has("entry_type")
         and (has("source") | not) and (has("project_target") | not)
      then
        allowed(if $home
                then ["destination_dir", "destination_home", "entry_type", "executable", "exclude_dirs", "recursive", "required_file", "source_children", "suffix"]
                else ["destination_dir", "entry_type", "executable", "exclude_dirs", "recursive", "required_file", "source_children", "suffix"]
                end)
        and valid_home_marker($home)
        and (.source_children | safe_relative_path)
        and (.destination_dir | safe_destination)
        and ((.entry_type == "file") or (.entry_type == "directory"))
        and optional_boolean("executable")
        and (if has("recursive") then (.recursive | type == "boolean") else true end)
        and (if has("exclude_dirs") then (.exclude_dirs | (type == "array" and all(.[]; safe_component))) else true end)
        and (if .entry_type == "file" then
               has("suffix") and (.suffix | valid_suffix)
               and (has("required_file") | not)
             else
               (has("suffix") | not)
               and (has("exclude_dirs") | not)
               and ((has("recursive") | not) or .recursive == false)
               and (if has("required_file") then (.required_file | safe_relative_path) else true end)
             end)
      else false end;
    def valid_link($home):
      valid_direct_link($home) or valid_project_link($home) or valid_children_link($home);
    def valid_render($home):
      if type == "object" and has("template") and has("destination") and has("merge") and has("mode") and has("required")
      then
        allowed(if $home
                then ["destination", "destination_home", "merge", "mode", "render_if_absent", "required", "template"]
                else ["destination", "merge", "mode", "render_if_absent", "required", "template"]
                end)
        and valid_home_marker($home)
        and (.template | safe_relative_path)
        and (.destination | safe_destination)
        and ((.merge == "explicit-json") or (.merge == "replace"))
        and (.mode | (type == "string" and test("^0[0-7]{3}$")))
        and (.required | type == "boolean")
        and (if has("render_if_absent")
             then (.render_if_absent | type == "boolean") and .merge == "replace"
             else true end)
      else false end;
    def valid_harness($home):
      if type == "object" and has("links") and has("render")
      then
        allowed(["links", "render"])
        and (.links | (type == "array" and all(.[]; valid_link($home))))
        and (.render | (type == "array" and all(.[]; valid_render($home))))
      else false end;
    .schema_version as $manifest_schema_version
    | if type == "object"
       and ((keys | sort) == ["harnesses", "schema_version"])
       and (.schema_version == 1 or .schema_version == 2)
       and (.harnesses | (
         type == "object"
         and (
           (if $manifest_schema_version == 1 then
              ((keys | sort) == ["claude", "codex"])
              or ((keys | sort) == ["claude", "codex", "user"])
            else
              ((keys | sort) == ["claude", "codex", "pi", "shared_agents"])
              or ((keys | sort) == ["claude", "codex", "pi", "shared_agents", "user"])
            end)
         )
         and (if $require_user then has("user") else true end)
         and (if $require_pi then has("pi") and has("shared_agents") else true end)
       ))
    then
      (.harnesses.claude | valid_harness(false))
      and (.harnesses.codex | valid_harness(false))
      and (if .schema_version == 2 then (.harnesses.pi | valid_harness(false)) and (.harnesses.shared_agents | valid_harness(false)) else true end)
      and (if .harnesses | has("user") then (.harnesses.user | valid_harness(true)) else true end)
    else false end
  ' "$manifest" >/dev/null 2>&1; then
    surface_plan_err "inheritance manifest is malformed or unsafe: $manifest"
    return "$TRELLIS_EX_STATE"
  fi

  # Duplicate-exposure rule (SC2/SC3): one harness must never see the same
  # user skill name twice. The shared codex+pi root overlaps both solo
  # roots, so a name under the shared root may not repeat under the pi
  # solo root (pi would see it twice) nor under the codex solo root (codex
  # would see it twice). Root strings come from the harness table in
  # skill-roots.sh, not from literals here.
  if ! jq -e '.harnesses | has("user")' "$manifest" >/dev/null 2>&1; then
    return 0
  fi
  shared_root="$(skill_roots_for_harnesses codex pi)" || return "$?"
  pi_root="$(skill_roots_for_harnesses pi)" || return "$?"
  codex_root="$(skill_roots_for_harnesses codex)" || return "$?"
  surface_plan_make_tempfile || return "$?"
  destinations_file="$_SURFACE_PLAN_LAST_TMP"
  if ! jq -r '.harnesses.user.links[] | select(has("destination")) | .destination' "$manifest" > "$destinations_file"; then
    surface_plan_err "could not enumerate user skill destinations: $manifest"
    return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r destination || [ -n "$destination" ]; do
    [ -n "$destination" ] || continue
    case "$destination" in
      "$shared_root"/*)
        skill="${destination#"$shared_root"/}"
        skill="${skill%%/*}"
        [ -n "$skill" ] || continue
        shared_names="${shared_names}${skill}
"
        ;;
      "$pi_root"/*)
        skill="${destination#"$pi_root"/}"
        skill="${skill%%/*}"
        [ -n "$skill" ] || continue
        pi_names="${pi_names}${skill}
"
        ;;
      "$codex_root"/*)
        skill="${destination#"$codex_root"/}"
        skill="${skill%%/*}"
        [ -n "$skill" ] || continue
        codex_names="${codex_names}${skill}
"
        ;;
    esac
  done < "$destinations_file"
  [ -n "$shared_names" ] || return 0
  nl='
'
  pi_scan="${nl}${pi_names}"
  codex_scan="${nl}${codex_names}"
  while IFS= read -r skill || [ -n "$skill" ]; do
    [ -n "$skill" ] || continue
    case "$pi_scan" in
      *"${nl}${skill}${nl}"*)
        surface_plan_err "user skill '$skill' is exposed twice to one harness via '$shared_root' and '$pi_root': $manifest"
        return "$TRELLIS_EX_STATE"
        ;;
    esac
    case "$codex_scan" in
      *"${nl}${skill}${nl}"*)
        surface_plan_err "user skill '$skill' is exposed twice to one harness via '$shared_root' and '$codex_root': $manifest"
        return "$TRELLIS_EX_STATE"
        ;;
    esac
  done <<< "$shared_names"
  return 0
}

surface_plan_normalize_harnesses() {
  local requested canonical present
  _SURFACE_PLAN_HARNESSES=()

  if [ "$#" -eq 0 ]; then
    _SURFACE_PLAN_HARNESSES=(claude codex)
    return 0
  fi

  for requested in "$@"; do
    case "$requested" in
      claude|codex|pi|user) ;;
      *)
        surface_plan_err "unknown harness: ${requested:-<empty>}"
        return "$TRELLIS_EX_USAGE"
        ;;
    esac
  done

  for canonical in claude codex pi user; do
    present=false
    for requested in "$@"; do
      if [ "$requested" = "$canonical" ]; then
        present=true
        break
      fi
    done
    if [ "$present" = true ]; then
      _SURFACE_PLAN_HARNESSES+=("$canonical")
    fi
  done
  return 0
}

surface_plan_json_array() {
  if [ "$#" -eq 0 ]; then
    printf '[]\n'
    return 0
  fi
  printf '%s\n' "$@" | jq -cs '.'
}

surface_plan_write_json() {
  local harnesses artifacts optional_missing plan

  harnesses="$(jq -cn --args '$ARGS.positional' "${_SURFACE_PLAN_HARNESSES[@]+"${_SURFACE_PLAN_HARNESSES[@]}"}")" || return "$TRELLIS_EX_STATE"
  artifacts="$(surface_plan_json_array "${_SURFACE_PLAN_RECORDS[@]+"${_SURFACE_PLAN_RECORDS[@]}"}")" || return "$TRELLIS_EX_STATE"
  optional_missing="$(surface_plan_json_array "${_SURFACE_PLAN_OPTIONAL_MISSING[@]+"${_SURFACE_PLAN_OPTIONAL_MISSING[@]}"}")" || return "$TRELLIS_EX_STATE"
  plan="$(jq -n \
    --argjson harnesses "$harnesses" \
    --argjson artifacts "$artifacts" \
    --argjson optional_missing "$optional_missing" \
    '{schema_version: 1, harnesses: $harnesses, artifacts: ($artifacts | sort_by([.harness, .destination, .kind, .source])), optional_missing: ($optional_missing | sort_by([.harness, .destination, .kind, .source]))}')" || {
      surface_plan_err "could not encode inheritance plan"
      return "$TRELLIS_EX_STATE"
    }
  printf '%s\n' "$plan" | jq -S . || {
    surface_plan_err "could not format inheritance plan"
    return "$TRELLIS_EX_STATE"
  }
}

surface_plan_emit() {
  local payload="${1:-}" payload_root manifest harness emit_shared=false
  [ "$#" -gt 0 ] && shift

  (
    _SURFACE_PLAN_DESTINATIONS=()
    _SURFACE_PLAN_RECORDS=()
    _SURFACE_PLAN_OPTIONAL_MISSING=()
    _SURFACE_PLAN_TEMP_FILES=()
    _SURFACE_PLAN_LAST_TMP=""
    _SURFACE_PLAN_CANONICAL_HOME=""
    trap 'surface_plan_cleanup' EXIT

    trellis_home_require_jq || return "$?"
    surface_plan_normalize_harnesses "$@" || return "$?"
    payload_root="$(surface_plan_payload_root "$payload")" || return "$?"
    # Accept either an immutable release payload root or its canonical
    # core-rules directory. The release/runtime callers pass the former; the
    # operator-facing acceptance probe passes the latter.
    if [ "$(basename "$payload_root")" = "core-rules" ] \
       && [ -f "$payload_root/inheritance-manifest.json" ] \
       && [ ! -L "$payload_root/inheritance-manifest.json" ]; then
      payload_root="$(dirname "$payload_root")"
    fi
    surface_plan_require_source "$payload_root" "core-rules/inheritance-manifest.json" file || return "$?"
    manifest="$payload_root/core-rules/inheritance-manifest.json"
    surface_plan_validate_manifest "$manifest" || return "$?"

    if [ "$(jq -r '.schema_version' "$manifest")" = 2 ]; then
      for harness in "${_SURFACE_PLAN_HARNESSES[@]+"${_SURFACE_PLAN_HARNESSES[@]}"}"; do
        case "$harness" in codex|pi) emit_shared=true ;; esac
      done
      if [ "$emit_shared" = true ]; then
        surface_plan_emit_harness "$payload_root" "$manifest" shared_agents || return "$?"
      fi
    fi

    for harness in "${_SURFACE_PLAN_HARNESSES[@]+"${_SURFACE_PLAN_HARNESSES[@]}"}"; do
      surface_plan_emit_harness "$payload_root" "$manifest" "$harness" || return "$?"
    done
    surface_plan_validate_user_destination_aliases || return "$?"
    surface_plan_write_json
  )
}

surface_plan_usage() {
  cat <<'EOF'
Usage: surface-plan.sh --payload ABSOLUTE_PAYLOAD_OR_CORE_RULES_PATH [--harness claude|codex|pi|user]...

Expand the immutable inheritance payload into a deterministic, no-write JSON plan.
The payload may be the release root or its canonical core-rules directory.
With no --harness selectors, emits Claude Code and Codex in canonical order.
EOF
}

surface_plan_main() {
  local payload="" argument
  local -a harnesses=()

  while [ "$#" -gt 0 ]; do
    argument="$1"
    case "$argument" in
      --payload)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          surface_plan_err "--payload requires an absolute path"
          return "$TRELLIS_EX_USAGE"
        fi
        payload="$2"
        shift 2
        ;;
      --payload=*)
        payload="${argument#--payload=}"
        if [ -z "$payload" ]; then
          surface_plan_err "--payload requires an absolute path"
          return "$TRELLIS_EX_USAGE"
        fi
        shift
        ;;
      --harness)
        if [ "$#" -lt 2 ] || [ -z "$2" ]; then
          surface_plan_err "--harness requires claude, codex, pi, or user"
          return "$TRELLIS_EX_USAGE"
        fi
        harnesses+=("$2")
        shift 2
        ;;
      --harness=*)
        harnesses+=("${argument#--harness=}")
        shift
        ;;
      --help|-h)
        surface_plan_usage
        return 0
        ;;
      --)
        shift
        if [ "$#" -gt 0 ]; then
          surface_plan_err "unexpected positional argument: $1"
          return "$TRELLIS_EX_USAGE"
        fi
        ;;
      *)
        surface_plan_err "unknown option: $argument"
        return "$TRELLIS_EX_USAGE"
        ;;
    esac
  done

  if [ -z "$payload" ]; then
    surface_plan_err "--payload is required"
    surface_plan_usage >&2
    return "$TRELLIS_EX_USAGE"
  fi
  surface_plan_emit "$payload" "${harnesses[@]+"${harnesses[@]}"}"
}

if [ "${TRELLIS_LIBS_PRELOADED:-}" != 1 ] && [ "${BASH_SOURCE[0]}" = "$0" ]; then
  surface_plan_main "$@"
fi
