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

# skill_preload_check <skill-name> <project-dir> <user-home>
# Return 0 when allowed, 1 when oversized, 2 when resolution is ambiguous or
# invalid. On denial, print the user-facing reason; never reads SKILL.md bodies.
skill_preload_check() {
  local name="$1" project="$2" user_home="$3" lookup_name root rc bytes owner

  lookup_name="$name"
  root="$(skill_size_resolve_root "$lookup_name" "$project" "$user_home" 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    case "$name" in
      *:*)
        lookup_name="${name##*:}"
        root="$(skill_size_resolve_root "$lookup_name" "$project" "$user_home" 2>/dev/null)"
        rc=$?
        ;;
    esac
  fi
  case "$rc" in
    0) ;;
    1) return 0 ;; # Unknown/non-authoritative name: allow.
    *)
      printf "Skill '%s' resolves ambiguously across discoverable roots; refusing pre-load before body injection\n" "$name"
      return 2
      ;;
  esac

  bytes="$(skill_size_manifest_bytes "$root" 2>/dev/null)" || {
    printf "Skill '%s' has an unreadable manifest at %s; refusing pre-load before body injection\n" "$name" "$root"
    return 2
  }
  if [ "$bytes" -le "$SKILL_SIZE_BUDGET_BYTES" ]; then
    return 0
  fi

  owner="$(skill_preload_owner "$root" "$project" "$user_home")"
  printf "Skill root exceeds %s-byte inline budget: '%s' (%s, owner=%s, bytes=%s)\n" \
    "$SKILL_SIZE_BUDGET_BYTES" "$name" "$root" "$owner" "$bytes"
  return 1
}
