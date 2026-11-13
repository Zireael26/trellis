#!/usr/bin/env bash
# Shared Skill root discovery, resolution, and size checks.
# Bash 3.2 compatible; all public functions use the skill_size_ prefix.

SKILL_SIZE_BUDGET_BYTES=65536

skill_size__safe_text() {
  local value="${1:-}" codes
  [ -n "$value" ] || return 1
  codes="$(printf '%s' "$value" | /usr/bin/env LC_ALL=C od -An -t u1)" || return 1
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
    # One lookahead byte prevents a truncated closing-fence line from looking
    # complete. Only a closing fence ending within the first 4096 bytes counts.
    head -c 4097 "$root/SKILL.md" 2>/dev/null | /usr/bin/env LC_ALL=C awk '
      { line_end = offset + length($0); offset = line_end + 1; sub(/\r$/, "") }
      NR == 1 {
        sub("^" sprintf("%c%c%c", 239, 187, 191), "")
        if ($0 !~ /^---[ \t]*$/) exit
        next
      }
      /^---[ \t]*$/ { if (found && line_end <= 4096) print declared; exit }
      !found && /^name:[[:space:]]*/ {
        sub(/^name:[[:space:]]*/, "")
        sub(/[[:space:]]+$/, "")
        if (($0 ~ /^".*"$/) || ($0 ~ /^'\''.*'\''$/)) {
          $0 = substr($0, 2, length($0) - 2)
        }
        declared = $0
        found = 1
      }
    '
  )" || return 1
  skill_size__valid_name "$name" || return 1
  printf '%s\n' "$name"
}

# macOS iconv accepts scalar values above U+10FFFF. Reject those lead bytes
# separately; an unavailable grep or a read error is a refusal, not a match miss.
skill_size__valid_utf8() {
  iconv -f UTF-8 -t UTF-8 "$1" >/dev/null 2>&1 || return 1
  if /usr/bin/env LC_ALL=C grep -a -q -E $'\364[\220-\277]|[\365-\377]' "$1" >/dev/null 2>&1; then
    return 1
  else
    [ "$?" -eq 1 ]
  fi
}

# skill_size_manifest_bytes <skill-root> [budget-bytes]
# Print the byte count; validate UTF-8 only when the manifest is within budget.
skill_size_manifest_bytes() {
  local root="${1:-}" budget="${2:-$SKILL_SIZE_BUDGET_BYTES}" manifest bytes
  case "$budget" in
    ''|*[!0-9]*|0)
      echo "skill-size: budget must be a positive integer: ${budget:-<empty>}" >&2
      return 2 ;;
  esac
  root="$(skill_size__canonical_dir "$root")" || {
    echo "skill-size: invalid Skill root: ${1:-<empty>}" >&2
    return 2
  }
  manifest="$root/SKILL.md"
  if [ ! -f "$manifest" ]; then
    echo "skill-size: missing SKILL.md: $root" >&2
    return 2
  fi
  # wc -c counts bytes in every locale. No temporary LC_ALL= here: Homebrew
  # bash 5.3 under a Node parent segfaults on $(VAR=x cmd < file) (forked child
  # in CoreFoundation prefs before exec), a spurious could-not-measure refusal.
  bytes="$(wc -c < "$manifest")" || {
    echo "skill-size: could not measure SKILL.md: $manifest" >&2
    return 2
  }
  bytes="${bytes//[[:space:]]/}"
  case "$bytes" in
    ''|*[!0-9]*)
      echo "skill-size: could not measure SKILL.md: $manifest" >&2
      return 2
      ;;
  esac
  if [ "$bytes" -gt "$budget" ] 2>/dev/null; then
    printf '%s\n' "$bytes"
    return 0
  fi
  if ! [ "$bytes" -le "$budget" ] 2>/dev/null; then
    echo "skill-size: cannot compare manifest bytes and budget" >&2
    return 2
  fi
  if ! skill_size__valid_utf8 "$manifest"; then
    echo "skill-size: SKILL.md is not valid UTF-8: $manifest" >&2
    return 2
  fi
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
  bytes="$(skill_size_manifest_bytes "$canonical" "$budget")" || return $?
  if [ "$bytes" -gt "$budget" ]; then
    echo "skill-size: $canonical/SKILL.md is $bytes bytes; budget is $budget bytes" >&2
    return 1
  fi
  return 0
}

skill_size__emit_collection() {
  local rank="$1" collection="$2" lookups="${3:-}" entry canonical declared lookup
  [ -d "$collection" ] || return 0
  for entry in "$collection"/*; do
    [ -d "$entry" ] && [ -f "$entry/SKILL.md" ] || continue
    if ! canonical="$(skill_size__canonical_dir "$entry")"; then
      # An unrepresentable path cannot be included in the tab/newline protocol.
      # Refuse enumeration, or an invocation matching its basename or name,
      # without denying unrelated skill names.
      if [ -z "$lookups" ]; then
        echo 'skill-size: unsafe discoverable Skill root' >&2
        return 2
      fi
      declared="$(skill_size__declared_name "$entry" 2>/dev/null || true)"
      while IFS= read -r lookup; do
        [ -n "$lookup" ] || continue
        if [ "${entry##*/}" = "$lookup" ] || [ "$declared" = "$lookup" ]; then
          echo "skill-size: unsafe discoverable root for '$lookup'" >&2
          return 2
        fi
      done <<< "$lookups"
      continue
    fi
    printf '%s\t%s\n' "$rank" "$canonical"
  done
}

# skill_size__discover_ranked_roots <project-dir> <user-home> [lookups]
# Print rank<TAB>canonical-root in precedence order. Only Claude's supported
# project/user locations and exact installed-cache/marketplace layouts count.
# An unsafe root refuses enumeration, or only lookups (one name per line) that
# match its basename or declared name.
skill_size__discover_ranked_roots() {
  local project="${1:-}" user_home="${2:-}" lookup="${3:-}" collection rank canonical ranked seen=""
  skill_size__safe_text "$project" && [ -d "$project" ] || {
    echo "skill-size: invalid project directory: ${project:-<empty>}" >&2
    return 2
  }
  skill_size__safe_text "$user_home" && [ -d "$user_home" ] || {
    echo "skill-size: invalid user home: ${user_home:-<empty>}" >&2
    return 2
  }

  ranked="$(
    skill_size__emit_collection 1 "$project/.claude/skills" "$lookup" || exit 2
    skill_size__emit_collection 2 "$user_home/.claude/skills" "$lookup" || exit 2
    for collection in "$user_home/.claude/plugins/cache"/*/*/*/skills; do
      skill_size__emit_collection 3 "$collection" "$lookup" || exit 2
    done
    for collection in "$user_home/.claude/plugins/marketplaces"/*/plugins/*/skills; do
      skill_size__emit_collection 4 "$collection" "$lookup" || exit 2
    done
  )" || return 2
  while IFS="$(printf '\t')" read -r rank canonical; do
    [ -n "$rank" ] && [ -n "$canonical" ] || continue
    case "
$seen
" in *"
$canonical
"*) continue ;; esac
    printf '%s\t%s\n' "$rank" "$canonical"
    seen="${seen}${seen:+
}${canonical}"
  done <<< "$ranked"
}

# skill_size_discover_roots <project-dir> <user-home>
# Print canonical Skill roots once, in precedence order:
# project > user > installed plugin cache > marketplace source.
skill_size_discover_roots() {
  local project="${1:-}" user_home="${2:-}" rank root ranked
  skill_size__safe_text "$project" && [ -d "$project" ] || {
    echo "skill-size: invalid project directory: ${project:-<empty>}" >&2
    return 2
  }
  skill_size__safe_text "$user_home" && [ -d "$user_home" ] || {
    echo "skill-size: invalid user home: ${user_home:-<empty>}" >&2
    return 2
  }
  ranked="$(skill_size__discover_ranked_roots "$project" "$user_home")" || return 2
  while IFS="$(printf '\t')" read -r rank root; do
    [ -n "$root" ] && printf '%s\n' "$root"
  done <<< "$ranked"
  return 0
}

skill_size__resolve_identity() {
  local name="$1" ranked_roots="$2"
  local rank root declared found="" found_rank="" count=0
  while IFS="$(printf '\t')" read -r rank root; do
    [ -n "$root" ] || continue
    if [ -n "$found_rank" ] && [ "$rank" -gt "$found_rank" ]; then
      # The snapshot is ranked; lower-priority roots cannot change a winner.
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
  done <<< "$ranked_roots" || return 2 # A failed temp-file redirect is not an unknown name.

  if [ "$count" -eq 0 ]; then
    return 1
  fi
  if [ "$count" -gt 1 ]; then
    echo "skill-size: ambiguous Skill '$name' ($count roots)" >&2
    return 3
  fi
  printf '%s\n' "$found"
}

# Match a qualified plugin against its own cache/marketplace namespace before
# considering a bare suffix from an unrelated project or plugin.
skill_size__resolve_qualified_plugin() {
  local qualifier="$1" suffix="$2" user_home="$3" entry declared canonical
  local seen="" found="" count=0 cache_match=0
  case "$qualifier" in ''|.|..|*/*) return 1 ;; esac
  for entry in \
    "$user_home/.claude/plugins/cache"/*/"$qualifier"/*/skills/* \
    "$user_home/.claude/plugins/marketplaces"/*/plugins/"$qualifier"/skills/*; do
    case "$entry" in
      "$user_home"/.claude/plugins/marketplaces/*) [ "$cache_match" -eq 0 ] || break ;;
    esac
    [ -d "$entry" ] && [ -f "$entry/SKILL.md" ] || continue
    declared="$(skill_size__declared_name "$entry" 2>/dev/null || true)"
    [ "${entry##*/}" = "$suffix" ] || [ "$declared" = "$suffix" ] || continue
    canonical="$(skill_size__canonical_dir "$entry")" || {
      echo "skill-size: unsafe discoverable root for '$qualifier:$suffix'" >&2
      return 2
    }
    case "$entry" in "$user_home"/.claude/plugins/cache/*) cache_match=1 ;; esac
    case "
$seen
" in *"
$canonical
"*) continue ;; esac
    seen="${seen}${seen:+
}${canonical}"
    found="$canonical"
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || return 1
  if [ "$count" -gt 1 ]; then
    echo "skill-size: ambiguous Skill '$qualifier:$suffix' ($count roots)" >&2
    return 3
  fi
  printf '%s\n' "$found"
}

# skill_size_resolve_root <skill-name> <project-dir> <user-home> [detailed]
# With detailed, ambiguity returns 3; without it all resolution errors return 2.
# Match declared frontmatter names and directory basenames: exact identity,
# then a qualified plugin's own namespace, then the suffix after the final
# colon. At the first matching precedence, distinct physical roots fail closed.
skill_size_resolve_root() {
  local name="${1:-}" project="${2:-}" user_home="${3:-}" root rc suffix ranked_roots lookups
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

  # Snapshot the ranked, physical roots once: exact and suffix lookups must
  # use the same discovery, including when a qualified name is unknown. An
  # unsafe root refuses only a name this lookup could resolve to.
  lookups="$name"
  case "$name" in *:*) lookups="$name"$'\n'"${name##*:}" ;; esac
  ranked_roots="$(skill_size__discover_ranked_roots "$project" "$user_home" "$lookups")" || return 2
  root="$(skill_size__resolve_identity "$name" "$ranked_roots")"
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$root"; return 0 ;;
    1) ;;
    3) [ "${4:-}" = detailed ] && return 3; return 2 ;;
    *) return 2 ;;
  esac

  case "$name" in
    *:*)
      suffix="${name##*:}"
      skill_size__valid_name "$suffix" || {
        echo "skill-size: invalid Skill name: $name" >&2
        return 2
      }
      root="$(skill_size__resolve_qualified_plugin "${name%:*}" "$suffix" "$user_home")"
      rc=$?
      case "$rc" in
        0) printf '%s\n' "$root"; return 0 ;;
        1) ;;
        3) [ "${4:-}" = detailed ] && return 3; return 2 ;;
        *) return 2 ;;
      esac
      root="$(skill_size__resolve_identity "$suffix" "$ranked_roots")"
      rc=$?
      case "$rc" in
        0) printf '%s\n' "$root"; return 0 ;;
        1) ;;
        3) [ "${4:-}" = detailed ] && return 3; return 2 ;;
        *) return 2 ;;
      esac
      ;;
  esac

  echo "skill-size: Skill not found: $name" >&2
  return 1
}
