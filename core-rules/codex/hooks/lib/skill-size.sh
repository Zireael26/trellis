#!/usr/bin/env bash
# Shared Skill root discovery, resolution, and size checks.
# Bash 3.2 compatible; all public functions use the skill_size_ prefix.

SKILL_SIZE_BUDGET_BYTES=65536

skill_size__safe_text() {
  local value="${1:-}" codes
  [ -n "$value" ] || return 1
  codes="$(printf '%s' "$value" | LC_ALL=C od -An -t u1)" || return 1
  if printf '%s\n' "$codes" | awk '
    {
      for (i = 1; i <= NF; i++) {
        if ($i <= 31 || $i == 127) found = 1
      }
    }
    END { exit !found }
  '; then
    return 1
  fi
  return 0
}

skill_size__canonical_dir() {
  local dir="${1:-}" canonical newline='
'
  skill_size__safe_text "$dir" && [ -d "$dir" ] || return 1
  canonical="$(
    cd -- "$dir" 2>/dev/null || exit 1
    pwd -P
    printf '.'
  )" || return 1
  canonical="${canonical%.}"
  canonical="${canonical%"$newline"}"
  skill_size__safe_text "$canonical" || return 1
  printf '%s\n' "$canonical"
}

skill_size__valid_name() {
  local name="${1:-}"
  skill_size__safe_text "$name" || return 1
  case "$name" in
    .|..|*/*) return 1 ;;
  esac
  return 0
}

skill_size__declared_name() {
  local root="${1:-}" name
  [ -f "$root/SKILL.md" ] || return 1
  name="$(
    LC_ALL=C awk '
      NR == 1 {
        if ($0 != "---") exit
        next
      }
      $0 == "---" { exit }
      /^name:[[:space:]]*/ {
        sub(/^name:[[:space:]]*/, "")
        sub(/[[:space:]]+$/, "")
        if (($0 ~ /^".*"$/) || ($0 ~ /^'\''.*'\''$/)) {
          $0 = substr($0, 2, length($0) - 2)
        }
        print
        exit
      }
    ' "$root/SKILL.md"
  )" || return 1
  skill_size__valid_name "$name" || return 1
  printf '%s\n' "$name"
}

# skill_size_manifest_bytes <skill-root>
# Print the UTF-8 byte count of the root's SKILL.md.
skill_size_manifest_bytes() {
  local root="${1:-}" manifest bytes
  root="$(skill_size__canonical_dir "$root")" || {
    echo "skill-size: invalid Skill root: ${1:-<empty>}" >&2
    return 2
  }
  manifest="$root/SKILL.md"
  if [ ! -f "$manifest" ]; then
    echo "skill-size: missing SKILL.md: $root" >&2
    return 2
  fi
  if ! iconv -f UTF-8 -t UTF-8 "$manifest" >/dev/null 2>&1; then
    echo "skill-size: SKILL.md is not valid UTF-8: $manifest" >&2
    return 2
  fi
  bytes="$(LC_ALL=C wc -c < "$manifest" | tr -d '[:space:]')"
  case "$bytes" in
    ''|*[!0-9]*)
      echo "skill-size: could not measure SKILL.md: $manifest" >&2
      return 2
      ;;
  esac
  printf '%s\n' "$bytes"
}

# skill_size_check_root <skill-root> [budget-bytes]
# Return 0 at or below budget, 1 above budget, and 2 for invalid input.
skill_size_check_root() {
  local root="${1:-}" budget="${2:-$SKILL_SIZE_BUDGET_BYTES}" bytes canonical
  case "$budget" in
    ''|*[!0-9]*|0)
      echo "skill-size: budget must be a positive integer: ${budget:-<empty>}" >&2
      return 2
      ;;
  esac
  canonical="$(skill_size__canonical_dir "$root")" || {
    echo "skill-size: invalid Skill root: ${root:-<empty>}" >&2
    return 2
  }
  bytes="$(skill_size_manifest_bytes "$canonical")" || return $?
  if [ "$bytes" -gt "$budget" ]; then
    echo "skill-size: $canonical/SKILL.md is $bytes bytes; budget is $budget bytes" >&2
    return 1
  fi
  return 0
}

skill_size__emit_collection() {
  local rank="$1" collection="$2" entry canonical
  [ -d "$collection" ] || return 0
  for entry in "$collection"/*; do
    [ -d "$entry" ] && [ -f "$entry/SKILL.md" ] || continue
    canonical="$(skill_size__canonical_dir "$entry")" || continue
    printf '%s\t%s\n' "$rank" "$canonical"
  done
}

# skill_size__discover_ranked_roots <project-dir> <user-home>
# Print rank<TAB>canonical-root in precedence order. Only Claude's supported
# project/user locations and exact installed-cache/marketplace layouts count.
skill_size__discover_ranked_roots() {
  local project="${1:-}" user_home="${2:-}" collection rank canonical seen=""
  skill_size__safe_text "$project" && [ -d "$project" ] || {
    echo "skill-size: invalid project directory: ${project:-<empty>}" >&2
    return 2
  }
  skill_size__safe_text "$user_home" && [ -d "$user_home" ] || {
    echo "skill-size: invalid user home: ${user_home:-<empty>}" >&2
    return 2
  }

  {
    skill_size__emit_collection 1 "$project/.claude/skills"
    skill_size__emit_collection 2 "$user_home/.claude/skills"
    for collection in "$user_home/.claude/plugins/cache"/*/*/*/skills; do
      skill_size__emit_collection 3 "$collection"
    done
    for collection in "$user_home/.claude/plugins/marketplaces"/*/plugins/*/skills; do
      skill_size__emit_collection 4 "$collection"
    done
  } | while IFS="$(printf '\t')" read -r rank canonical; do
    [ -n "$rank" ] && [ -n "$canonical" ] || continue
    case "
$seen
" in *"
$canonical
"*) continue ;; esac
    printf '%s\t%s\n' "$rank" "$canonical"
    seen="${seen}${seen:+
}${canonical}"
  done
}

# skill_size_discover_roots <project-dir> <user-home>
# Print canonical Skill roots once, in precedence order:
# project > user > installed plugin cache > marketplace source.
skill_size_discover_roots() {
  local project="${1:-}" user_home="${2:-}" rank root
  skill_size__safe_text "$project" && [ -d "$project" ] || {
    echo "skill-size: invalid project directory: ${project:-<empty>}" >&2
    return 2
  }
  skill_size__safe_text "$user_home" && [ -d "$user_home" ] || {
    echo "skill-size: invalid user home: ${user_home:-<empty>}" >&2
    return 2
  }
  while IFS="$(printf '\t')" read -r rank root; do
    [ -n "$root" ] && printf '%s\n' "$root"
  done < <(skill_size__discover_ranked_roots "$project" "$user_home")
}

skill_size__resolve_identity() {
  local name="$1" project="$2" user_home="$3"
  local rank root declared found="" found_rank="" count=0
  while IFS="$(printf '\t')" read -r rank root; do
    [ -n "$root" ] || continue
    if [ -n "$found_rank" ] && [ "$rank" -gt "$found_rank" ]; then
      break
    fi
    declared="$(skill_size__declared_name "$root" 2>/dev/null || true)"
    if [ "${root##*/}" != "$name" ] && [ "$declared" != "$name" ]; then
      continue
    fi
    if [ -z "$found_rank" ]; then
      found_rank="$rank"
    fi
    found="$root"
    count=$((count + 1))
  done < <(skill_size__discover_ranked_roots "$project" "$user_home") || return $?

  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "skill-size: ambiguous Skill '$name' ($count roots)" >&2
    return 2
  fi
  printf '%s\n' "$found"
}

# skill_size_resolve_root <skill-name> <project-dir> <user-home>
# Match declared frontmatter names and directory basenames. Qualified names are
# matched exactly first, then by the suffix after the final colon. At the first
# matching precedence, distinct physical roots are an ambiguity and fail closed.
skill_size_resolve_root() {
  local name="${1:-}" project="${2:-}" user_home="${3:-}" root rc suffix
  skill_size__valid_name "$name" || {
    echo "skill-size: invalid Skill name: ${name:-<empty>}" >&2
    return 2
  }
  skill_size__safe_text "$project" && [ -d "$project" ] || {
    echo "skill-size: invalid project directory: ${project:-<empty>}" >&2
    return 2
  }
  skill_size__safe_text "$user_home" && [ -d "$user_home" ] || {
    echo "skill-size: invalid user home: ${user_home:-<empty>}" >&2
    return 2
  }

  root="$(skill_size__resolve_identity "$name" "$project" "$user_home")"
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$root"; return 0 ;;
    2) return 2 ;;
  esac

  case "$name" in
    *:*)
      suffix="${name##*:}"
      skill_size__valid_name "$suffix" || {
        echo "skill-size: invalid Skill name: $name" >&2
        return 2
      }
      root="$(skill_size__resolve_identity "$suffix" "$project" "$user_home")"
      rc=$?
      case "$rc" in
        0) printf '%s\n' "$root"; return 0 ;;
        2) return 2 ;;
      esac
      ;;
  esac

  echo "skill-size: Skill not found: $name" >&2
  return 1
}
