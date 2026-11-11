#!/usr/bin/env bash
# Shared resolution and diagnostics for Skill pre-load hooks.
# Source after lib/skill-size.sh. Public functions use skill_preload_ prefix.

skill_preload_owner() {
  local root="$1" project="$2" user_home="$3"
  project="$(skill_size__canonical_dir "$project" 2>/dev/null || printf '%s' "$project")"
  user_home="$(skill_size__canonical_dir "$user_home" 2>/dev/null || printf '%s' "$user_home")"
  case "$root" in
    "$project"/.claude/skills/*) printf '%s\n' project ;;
    "$user_home"/.claude/skills/*) printf '%s\n' user ;;
    "$user_home"/.claude/plugins/cache/*) printf '%s\n' plugin-cache ;;
    "$user_home"/.claude/plugins/marketplaces/*) printf '%s\n' plugin-marketplace ;;
    *) printf '%s\n' discoverable ;;
  esac
}

# Check a single potential loader target without reading its body into context.
skill_preload_check_manifest() {
  local name="$1" root="$2" project="$3" user_home="$4" bytes owner
  bytes="$(skill_size_manifest_bytes "$root" 2>/dev/null)" || {
    printf "Skill '%s' has an unreadable manifest at %s; refusing pre-load before body injection\n" "$name" "$root"
    return 2
  }
  [ "$bytes" -gt "$SKILL_SIZE_BUDGET_BYTES" ] || return 0
  owner="$(skill_preload_owner "$root" "$project" "$user_home")"
  printf "Skill root exceeds %s-byte inline budget: '%s' (%s, owner=%s, bytes=%s)\n" \
    "$SKILL_SIZE_BUDGET_BYTES" "$name" "$root" "$owner" "$bytes"
  return 1
}

# Protect identities where the loader may select a different named target than
# the documented basename/suffix precedence. Check only plausible alternatives,
# retaining exact-name precedence and cache-before-marketplace behavior.
skill_preload_check_shadowed() {
  local name="$1" project="$2" user_home="$3" root="$4"
  local declared suffix qualifier entry candidate ranked rank cache_match=0
  declared="$(skill_size__declared_name "$root" 2>/dev/null || true)"
  case "$name" in
    *:*)
      [ "${root##*/}" != "$name" ] && [ "$declared" != "$name" ] || return 0
      suffix="${name##*:}"; qualifier="${name%:*}"
      case "$qualifier" in ''|.|..|*/*) return 0 ;; esac
      for entry in \
        "$user_home/.claude/plugins/cache"/*/"$qualifier"/*/skills/* \
        "$user_home/.claude/plugins/marketplaces"/*/plugins/"$qualifier"/skills/*; do
        case "$entry" in
          "$user_home"/.claude/plugins/marketplaces/*) [ "$cache_match" -eq 0 ] || break ;;
        esac
        [ -d "$entry" ] && [ -f "$entry/SKILL.md" ] || continue
        candidate="$(skill_size__declared_name "$entry" 2>/dev/null || true)"
        [ "${entry##*/}" = "$suffix" ] || [ "$candidate" = "$suffix" ] || continue
        case "$entry" in "$user_home"/.claude/plugins/cache/*) cache_match=1 ;; esac
        if skill_preload_check_manifest "$name" "$entry" "$project" "$user_home"; then :; else return $?; fi
      done
      ;;
    *)
      [ "${root##*/}" = "$name" ] && [ -n "$declared" ] && [ "$declared" != "$name" ] || return 0
      ranked="$(skill_size__discover_ranked_roots "$project" "$user_home" "$name")" || {
        printf "Skill '%s' has an unsafe discoverable root; refusing pre-load before body injection\n" "$name"
        return 2
      }
      while IFS="$(printf '\t')" read -r rank entry; do
        [ -n "$rank" ] && [ -n "$entry" ] && [ "$entry" != "$root" ] || continue
        candidate="$(skill_size__declared_name "$entry" 2>/dev/null || true)"
        [ "$candidate" = "$name" ] || continue
        if skill_preload_check_manifest "$name" "$entry" "$project" "$user_home"; then :; else return $?; fi
      done <<< "$ranked"
      ;;
  esac
  return 0
}

# skill_preload_check <skill-name> <project-dir> <user-home>
# Return 0 when allowed, 1 when oversized, 2 when resolution is ambiguous or
# invalid. On denial, print the user-facing reason; never reads SKILL.md bodies.
skill_preload_check() {
  local name="$1" project="$2" user_home="$3" root rc

  root="$(skill_size_resolve_root "$name" "$project" "$user_home" detailed 2>/dev/null)"
  rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;; # Unknown/non-authoritative name: allow.
    3)
      printf "Skill '%s' resolves ambiguously across discoverable roots; refusing pre-load before body injection\n" "$name"
      return 2
      ;;
    *)
      printf "Skill '%s' has an invalid name or discovery root; refusing pre-load before body injection\n" "$name"
      return 2
      ;;
  esac

  if skill_preload_check_manifest "$name" "$root" "$project" "$user_home"; then :; else return $?; fi
  skill_preload_check_shadowed "$name" "$project" "$user_home" "$root"
}
