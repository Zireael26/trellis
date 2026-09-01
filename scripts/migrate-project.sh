#!/usr/bin/env bash
# Prepare a reviewable migration from legacy Trellis inheritance to one inert
# portable manifest. Project mutation starts only after full classification and
# a machine-local rollback snapshot have succeeded.

set -u

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SOURCE_ROOT="$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=lib/trellis-home.sh
. "$SCRIPT_DIR/lib/trellis-home.sh"
# shellcheck source=lib/local-registry.sh
. "$SCRIPT_DIR/lib/local-registry.sh"
# shellcheck source=lib/release-store.sh
. "$SCRIPT_DIR/lib/release-store.sh"

MIGRATE_BEGIN_PREFIX='# --- Trellis inheritance symlinks'
MIGRATE_END='# --- end Trellis fragment ---'
MIGRATE_LEGACY_END='# --- end SE Core fragment ---'
MIGRATE_PROJECT_SCHEMA='https://trellis.local/schemas/trellis.project.schema.json'

migrate_err() {
  printf 'trellis migrate: %s\n' "$*" >&2
}

migrate_warn() {
  printf 'trellis migrate: warning: %s\n' "$*" >&2
}

migrate_usage() {
  cat <<'EOF'
Usage:
  migrate-project.sh --prepare [--home PATH] [--project-id ID] [--legacy-root PATH] PATH
  migrate-project.sh --rollback SNAPSHOT
EOF
}

migrate_usage_error() {
  migrate_err "$*"
  migrate_usage >&2
  return "$TRELLIS_EX_USAGE"
}

migrate_file_mode() {
  local mode
  if mode="$(stat -f '%Lp' "$1" 2>/dev/null)" &&
    printf '%s' "$mode" | LC_ALL=C grep -Eq '^[0-7]{3,4}$'; then
    printf '%s\n' "$mode"
    return 0
  fi
  if mode="$(stat -c '%a' "$1" 2>/dev/null)" &&
    printf '%s' "$mode" | LC_ALL=C grep -Eq '^[0-7]{3,4}$'; then
    printf '%s\n' "$mode"
    return 0
  fi
  return 1
}

migrate_file_identity() {
  local identity
  case "$(uname -s)" in
    Darwin|*BSD|DragonFly) identity="$(stat -f '%d:%i' "$1" 2>/dev/null)" || return 1 ;;
    *) identity="$(stat -c '%d:%i' "$1" 2>/dev/null)" || return 1 ;;
  esac
  case "$identity" in
    *[!0-9:]*|*:*:*|:*|*:|'') return 1 ;;
    *:*) printf '%s\n' "$identity" ;;
    *) return 1 ;;
  esac
}

migrate_file_link_count() {
  local count
  case "$(uname -s)" in
    Darwin|*BSD|DragonFly) count="$(stat -f '%l' "$1" 2>/dev/null)" || return 1 ;;
    *) count="$(stat -c '%h' "$1" 2>/dev/null)" || return 1 ;;
  esac
  case "$count" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$count" ;;
  esac
}

migrate_real_root() {
  local requested="$1" root top
  root="$(local_registry_real_directory 'project root' "$requested")" || return "$?"
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || {
    migrate_err "project root is not a Git worktree: $root"
    return "$TRELLIS_EX_STATE"
  }
  top="$(local_registry_real_directory 'Git worktree top level' "$top")" || return "$?"
  [ "$root" = "$top" ] || {
    migrate_err "project path must equal the Git worktree root: $root"
    return "$TRELLIS_EX_STATE"
  }
  printf '%s\n' "$root"
}

migrate_safe_relative() {
  local path="$1"
  case "$path" in
    ''|/*|.|..|../*|*/../*|*/..|*'//'*) return 1 ;;
  esac
  printf '%s' "$path" | LC_ALL=C grep -Eq '^[^[:cntrl:]]+$'
}

migrate_parent_safe() {
  local root="$1" rel="$2" parent segment current old_ifs
  migrate_safe_relative "$rel" || return 1
  parent="$(dirname "$rel")"
  [ "$parent" != . ] || return 0
  current="$root"
  old_ifs="$IFS"
  IFS='/'
  # shellcheck disable=SC2086
  set -- $parent
  IFS="$old_ifs"
  for segment in "$@"; do
    current="$current/$segment"
    if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
      migrate_err "unsafe symlinked or non-directory parent: $current"
      return 1
    fi
  done
  return 0
}

migrate_resolve_existing_path() {
  local path="$1" target parent base hops=0
  while [ -L "$path" ]; do
    hops=$((hops + 1))
    [ "$hops" -le 40 ] || return 1
    target="$(readlink "$path")" || return 1
    case "$target" in
      /*) path="$target" ;;
      *) path="$(dirname "$path")/$target" ;;
    esac
  done
  if [ -d "$path" ]; then
    (CDPATH='' cd -P "$path" && pwd -P)
  elif [ -e "$path" ]; then
    parent="$(CDPATH='' cd -P "$(dirname "$path")" && pwd -P)" || return 1
    base="$(basename "$path")"
    printf '%s/%s\n' "$parent" "$base"
  else
    return 1
  fi
}

migrate_resolve_link_target() {
  local link="$1" target
  [ -L "$link" ] || return 1
  target="$(readlink "$link")" || return 1
  case "$target" in
    /*) ;;
    *) target="$(dirname "$link")/$target" ;;
  esac
  migrate_resolve_existing_path "$target"
}

migrate_path_in_file() {
  local file="$1" path="$2"
  awk -v path="$path" '$0 == path { found=1 } END { exit !found }' "$file"
}

migrate_append_unique_path() {
  local file="$1" path="$2"
  migrate_path_in_file "$file" "$path" || printf '%s\n' "$path" >> "$file"
}

migrate_count_path() {
  local file="$1" path="$2"
  awk -v path="$path" '$0 == path { count++ } END { print count + 0 }' "$file"
}

migrate_target_owned() {
  local path="$1" source_rel="$2" roots="$3" target source root
  target="$(migrate_resolve_link_target "$path")" || return 1
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    source="$(migrate_resolve_existing_path "$root/$source_rel" 2>/dev/null)" || continue
    [ "$target" = "$source" ] && return 0
  done < "$roots"
  return 1
}

migrate_source_exists() {
  local source_rel="$1" roots="$2" root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    migrate_resolve_existing_path "$root/$source_rel" >/dev/null 2>&1 && return 0
  done < "$roots"
  return 1
}

migrate_regular_copy_owned() {
  local root="$1" rel="$2" path="$3" roots="$4" candidate source
  case "$rel" in
    .claude/rules/trellis.md|.agents/rules/trellis.md|\
    .claude/rules/se-core.md|.agents/rules/se-core.md) ;;
    .omp/AGENTS.md)
      # A materialized copy of the project's own rules is managed output, the
      # same way the static link case treats a link to project CLAUDE.md.
      source="$root/CLAUDE.md"
      [ -f "$source" ] && [ ! -L "$source" ] && cmp -s "$path" "$source" && return 0
      ;;
    AGENTS.md)
      # Root AGENTS.md mirrors its static-link rule exactly: only the project's
      # own CLAUDE.md proves ownership. Canonical rules are never evidence
      # here, so a project that authored AGENTS.md by copying the parent rules
      # keeps it.
      source="$root/CLAUDE.md"
      [ -f "$source" ] && [ ! -L "$source" ] && cmp -s "$path" "$source" && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    source="$candidate/CLAUDE.md"
    [ -f "$source" ] && [ ! -L "$source" ] && cmp -s "$path" "$source" && return 0
  done < "$roots"
  return 1
}

migrate_static_symlink_owned() {
  local root="$1" rel="$2" path="$3" roots="$4" target project_rules source_rel=""
  target="$(migrate_resolve_link_target "$path")" || return 1
  case "$rel" in
    .claude/rules/trellis.md|.agents/rules/trellis.md|\
    .claude/rules/se-core.md|.agents/rules/se-core.md) source_rel='CLAUDE.md' ;;
    .omp/skills) source_rel='skills' ;;
    .omp/commands) source_rel='commands' ;;
    .omp/agents) source_rel='agents' ;;
    .omp/hooks) source_rel='omp/hooks' ;;
    .omp/AGENTS.md)
      project_rules="$(migrate_resolve_existing_path "$root/CLAUDE.md" 2>/dev/null)" || project_rules=""
      [ -n "$project_rules" ] && [ "$target" = "$project_rules" ] && return 0
      source_rel='CLAUDE.md'
      ;;
    AGENTS.md)
      project_rules="$(migrate_resolve_existing_path "$root/CLAUDE.md" 2>/dev/null)" || return 1
      [ "$target" = "$project_rules" ] && return 0
      return 1
      ;;
    *) return 1 ;;
  esac
  migrate_target_owned "$path" "$source_rel" "$roots"
}

migrate_collect_rule_targets() {
  local root="$1" output="$2" rel path target
  for rel in .claude/rules/trellis.md .agents/rules/trellis.md .claude/rules/se-core.md .agents/rules/se-core.md; do
    migrate_parent_safe "$root" "$rel" || return "$TRELLIS_EX_CONFLICT"
    path="$root/$rel"
    [ -L "$path" ] || continue
    target="$(migrate_resolve_link_target "$path")" || {
      migrate_err "unresolvable legacy rule link: $rel"
      return "$TRELLIS_EX_CONFLICT"
    }
    [ "$(basename "$target")" = 'CLAUDE.md' ] || {
      migrate_err "ambiguous legacy rule link: $rel -> $target"
      return "$TRELLIS_EX_CONFLICT"
    }
    printf '%s\n' "$target" >> "$output"
  done
}

migrate_collect_absolute_import_targets() {
  local input="$1" output="$2" line target
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      @/*/CLAUDE.md)
        target="$(migrate_resolve_existing_path "${line#@}")" || {
          migrate_err "unresolvable absolute CLAUDE import: $line"
          return "$TRELLIS_EX_CONFLICT"
        }
        printf '%s\n' "$target" >> "$output"
        ;;
    esac
  done < "$input"
}

migrate_build_canonical_roots() {
  local root="$1" rule_targets="$2" import_targets="$3" output="$4" legacy_root="$5"
  local current_rules legacy_rules
  : "$root" "$rule_targets" "$import_targets"
  current_rules="$(migrate_resolve_existing_path "$SOURCE_ROOT/core-rules/CLAUDE.md")" || {
    migrate_err 'current compatibility rules source is unavailable'
    return "$TRELLIS_EX_STATE"
  }
  [ -f "$current_rules" ] && [ ! -L "$current_rules" ] || {
    migrate_err 'current compatibility rules source is not a regular file'
    return "$TRELLIS_EX_STATE"
  }
  # Project links and imports are untrusted migration input, not ownership
  # evidence. Only the executing checkout or an explicit operator-reviewed
  # historical checkout may own removals.
  migrate_append_unique_path "$output" "$(dirname "$current_rules")"
  if [ -n "$legacy_root" ]; then
    case "$legacy_root" in
      "$root"|"$root"/*)
        migrate_err 'legacy Trellis root must be outside the project worktree'
        return "$TRELLIS_EX_CONFLICT"
        ;;
    esac
    legacy_rules="$(migrate_resolve_existing_path "$legacy_root/core-rules/CLAUDE.md")" || {
      migrate_err 'explicit legacy Trellis root has no core-rules/CLAUDE.md'
      return "$TRELLIS_EX_CONFLICT"
    }
    [ -f "$legacy_rules" ] && [ ! -L "$legacy_rules" ] || {
      migrate_err 'explicit legacy Trellis rules source is not a regular file'
      return "$TRELLIS_EX_CONFLICT"
    }
    migrate_append_unique_path "$output" "$(dirname "$legacy_rules")"
  fi
}

migrate_classify_imports() {
  local input="$1" roots="$2" approved="$3" line target root source owned
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      @/*/CLAUDE.md)
        target="$(migrate_resolve_existing_path "${line#@}")" || return "$TRELLIS_EX_CONFLICT"
        owned=0
        while IFS= read -r root; do
          [ -n "$root" ] || continue
          source="$(migrate_resolve_existing_path "$root/CLAUDE.md" 2>/dev/null)" || continue
          if [ "$target" = "$source" ]; then owned=1; break; fi
        done < "$roots"
        [ "$owned" -eq 1 ] || {
          migrate_err "ambiguous absolute CLAUDE import: $line"
          return "$TRELLIS_EX_CONFLICT"
        }
        printf '%s\n' "$line" >> "$approved"
        ;;
    esac
  done < "$input"
}

migrate_ignore_lists_path() {
  local input="$1" wanted="$2"
  [ -f "$input" ] && [ ! -L "$input" ] || return 1
  awk -v begin="$MIGRATE_BEGIN_PREFIX" -v finish="$MIGRATE_END" -v legacy_finish="$MIGRATE_LEGACY_END" -v wanted="$wanted" '
    index($0, begin) == 1 { inblock=1; next }
    inblock && ($0 == finish || $0 == legacy_finish) { inblock=0; next }
    inblock && $0 == wanted { found=1 }
    END { exit !found }
  ' "$input"
}

migrate_classify_link_family() (
  local root="$1" family_rel="$2" source_dir="$3" actions="$4" roots="$5" ignore="$6"
  local family="$root/$family_rel" path name source_rel rel
  migrate_parent_safe "$root" "$family_rel/.migrate-family-probe" || return "$TRELLIS_EX_CONFLICT"
  if [ ! -e "$family" ] && [ ! -L "$family" ]; then return 0; fi
  [ -d "$family" ] && [ ! -L "$family" ] || {
    migrate_err "ambiguous legacy family path: $family_rel"
    return "$TRELLIS_EX_CONFLICT"
  }
  shopt -s nullglob dotglob
  for path in "$family"/*; do
    name="${path##*/}"
    rel="$family_rel/$name"
    source_rel="$source_dir/$name"
    migrate_ignore_lists_path "$ignore" "$rel" || {
      [ ! -L "$path" ] || {
        migrate_err "legacy generated symlink is missing managed ownership metadata: $rel"
        return "$TRELLIS_EX_CONFLICT"
      }
      continue
    }
    if [ -L "$path" ]; then
      migrate_target_owned "$path" "$source_rel" "$roots" || {
        migrate_err "ambiguous legacy symlink: $rel -> $(readlink "$path")"
        return "$TRELLIS_EX_CONFLICT"
      }
      printf '%s\n' "$rel" >> "$actions"
    elif migrate_source_exists "$source_rel" "$roots"; then
      migrate_err "divergent project-owned legacy candidate: $rel"
      return "$TRELLIS_EX_CONFLICT"
    fi
  done
)

migrate_classify_preset_family() (
  local root="$1" family_rel="$2" actions="$3" roots="$4" ignore="$5"
  local family="$root/$family_rel" path name preset source_rel rel
  migrate_parent_safe "$root" "$family_rel/.migrate-family-probe" || return "$TRELLIS_EX_CONFLICT"
  if [ ! -e "$family" ] && [ ! -L "$family" ]; then return 0; fi
  [ -d "$family" ] && [ ! -L "$family" ] || {
    migrate_err "ambiguous legacy family path: $family_rel"
    return "$TRELLIS_EX_CONFLICT"
  }
  shopt -s nullglob dotglob
  for path in "$family"/*; do
    name="${path##*/}"
    case "$name" in preset-*.md) ;; *) continue ;; esac
    preset="${name#preset-}"
    [ "$preset" != '.md' ] || continue
    rel="$family_rel/$name"
    source_rel="presets/$preset"
    migrate_ignore_lists_path "$ignore" "$rel" || {
      [ ! -L "$path" ] || {
        migrate_err "legacy generated preset is missing managed ownership metadata: $rel"
        return "$TRELLIS_EX_CONFLICT"
      }
      continue
    }
    if [ -L "$path" ]; then
      migrate_target_owned "$path" "$source_rel" "$roots" || {
        migrate_err "ambiguous legacy symlink: $rel -> $(readlink "$path")"
        return "$TRELLIS_EX_CONFLICT"
      }
      printf '%s\n' "$rel" >> "$actions"
    elif migrate_source_exists "$source_rel" "$roots"; then
      migrate_err "divergent project-owned legacy candidate: $rel"
      return "$TRELLIS_EX_CONFLICT"
    fi
  done
)

migrate_transform_imports() {
  local input="$1" output="$2" approved="$3"
  awk -v approved="$approved" '
    BEGIN { while ((getline line < approved) > 0) remove[line] = 1 }
    !($0 in remove) { print }
  ' "$input" > "$output"
}

migrate_transform_ignore() {
  local input="$1" output="$2"
  awk -v begin="$MIGRATE_BEGIN_PREFIX" -v finish="$MIGRATE_END" -v legacy_finish="$MIGRATE_LEGACY_END" '
    index($0, begin) == 1 { inblock=1; next }
    inblock && ($0 == finish || $0 == legacy_finish) { inblock=0; next }
    !inblock { print }
    END { if (inblock) exit 42 }
  ' "$input" > "$output"
}

migrate_publish_file() {
  local source="$1" destination="$2" mode="$3" tmp
  tmp="$destination.migrate.$$"
  [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return "$TRELLIS_EX_CONFLICT"
  cp "$source" "$tmp" || { rm -f "$tmp"; return "$TRELLIS_EX_UNAVAILABLE"; }
  chmod "$mode" "$tmp" || { rm -f "$tmp"; return "$TRELLIS_EX_UNAVAILABLE"; }
  mv "$tmp" "$destination" || { rm -f "$tmp"; return "$TRELLIS_EX_UNAVAILABLE"; }
}

migrate_sha256_file() {
  local output
  output="$(shasum -a 256 "$1" 2>/dev/null)" ||
    output="$(sha256sum "$1" 2>/dev/null)" || return 1
  output="${output%% *}"
  printf '%s' "$output" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$' || return 1
  printf '%s\n' "$output"
}

migrate_claim_legacy_policy() {
  local path="$1" claimed="$2" parent claimed_parent rc
  [ -f "$path" ] && [ ! -L "$path" ] || {
    migrate_err 'legacy policy changed after snapshot; preserved the current path'
    return "$TRELLIS_EX_CONFLICT"
  }
  parent="$(dirname "$path")" || return "$TRELLIS_EX_STATE"
  claimed_parent="$(dirname "$claimed")" || return "$TRELLIS_EX_STATE"
  [ "$claimed_parent" = "$parent" ] || return "$TRELLIS_EX_STATE"
  case "$(basename "$claimed")" in
    .trellis-migrate-removal.*) ;;
    *) return "$TRELLIS_EX_STATE" ;;
  esac
  [ ! -e "$claimed" ] && [ ! -L "$claimed" ] || return "$TRELLIS_EX_CONFLICT"
  release_store_rename_no_clobber "$path" "$claimed"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  legacy_claim_acquired=true
  [ -f "$claimed" ] && [ ! -L "$claimed" ] ||
    return "$TRELLIS_EX_CONFLICT"
  legacy_claim_identity="$(migrate_file_identity "$claimed")" ||
    return "$TRELLIS_EX_STATE"
  legacy_claim_sha="$(migrate_sha256_file "$claimed")" ||
    return "$TRELLIS_EX_STATE"
  legacy_claim_pinned=true
  return 0
}

migrate_copy_file_exclusive() {
  local source="$1" destination="$2" mode="$3" python_bin identity rc
  python_bin="$(command -v python3)" || return "$TRELLIS_EX_UNAVAILABLE"
  identity="$("$python_bin" - "$source" "$destination" "$mode" <<'PY'
import os
import stat
import sys

source, destination, mode_text = sys.argv[1:4]
source_fd = None
destination_fd = None
created_identity = None
try:
    mode = int(mode_text, 8)
    source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    source_stat = os.fstat(source_fd)
    if not stat.S_ISREG(source_stat.st_mode) or source_stat.st_nlink != 1:
        raise OSError("unsafe source")
    destination_fd = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
    )
    destination_stat = os.fstat(destination_fd)
    created_identity = (destination_stat.st_dev, destination_stat.st_ino)
    while True:
        chunk = os.read(source_fd, 1024 * 1024)
        if not chunk:
            break
        offset = 0
        while offset < len(chunk):
            offset += os.write(destination_fd, chunk[offset:])
    os.fchmod(destination_fd, mode)
    os.fsync(destination_fd)
    destination_stat = os.fstat(destination_fd)
    if not stat.S_ISREG(destination_stat.st_mode) or destination_stat.st_nlink != 1:
        raise OSError("unsafe destination")
    print(f"{destination_stat.st_dev}:{destination_stat.st_ino}")
except FileExistsError:
    sys.exit(17)
except (OSError, ValueError):
    if created_identity is not None:
        try:
            current = os.lstat(destination)
            if (current.st_dev, current.st_ino) == created_identity:
                os.unlink(destination)
        except OSError:
            pass
    sys.exit(19)
finally:
    if destination_fd is not None:
        os.close(destination_fd)
    if source_fd is not None:
        os.close(source_fd)
PY
  )"
  rc=$?
  case "$rc" in
    0)
      printf '%s\n' "$identity"
      return 0
      ;;
    17) return "$TRELLIS_EX_CONFLICT" ;;
    *) return "$TRELLIS_EX_UNAVAILABLE" ;;
  esac
}

migrate_publish_file_exclusive() (
  local source="$1" destination="$2" mode="$3"
  local parent stage="" stage_identity source_sha rc stage_owned=false
  migrate_publish_cleanup() {
    local status="${1:-$?}"
    trap - EXIT HUP INT TERM
    if [ "$stage_owned" = true ] && [ -n "$stage" ] &&
      [ -f "$stage" ] && [ ! -L "$stage" ] &&
      [ "$(migrate_file_link_count "$stage")" = 1 ] &&
      [ "$(migrate_file_identity "$stage")" = "$stage_identity" ]; then
      rm "$stage" 2>/dev/null
    fi
    exit "$status"
  }
  trap 'migrate_publish_cleanup "$?"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ -f "$source" ] && [ ! -L "$source" ] || return "$TRELLIS_EX_STATE"
  parent="$(dirname "$destination")" || return "$TRELLIS_EX_STATE"
  stage="$(mktemp "$parent/.trellis-migrate-publish.XXXXXX")" ||
    return "$TRELLIS_EX_UNAVAILABLE"
  rm "$stage" || return "$TRELLIS_EX_UNAVAILABLE"
  stage_identity="$(migrate_copy_file_exclusive "$source" "$stage" "$mode")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    stage=""
    return "$rc"
  fi
  stage_owned=true
  source_sha="$(migrate_sha256_file "$source")" || return "$TRELLIS_EX_STATE"
  if [ ! -f "$stage" ] || [ -L "$stage" ] ||
    [ "$(migrate_file_link_count "$stage")" != 1 ] ||
    [ "$(migrate_file_identity "$stage")" != "$stage_identity" ] ||
    [ "$(migrate_sha256_file "$stage")" != "$source_sha" ]; then
    return "$TRELLIS_EX_CONFLICT"
  fi
  release_store_rename_no_clobber "$stage" "$destination"
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  stage_owned=false
  stage=""
  if [ ! -f "$destination" ] || [ -L "$destination" ] ||
    [ "$(migrate_file_link_count "$destination")" != 1 ] ||
    [ "$(migrate_file_identity "$destination")" != "$stage_identity" ] ||
    [ "$(migrate_sha256_file "$destination")" != "$source_sha" ] ||
    [ "$(migrate_file_mode "$destination")" != "$mode" ]; then
    return "$TRELLIS_EX_CONFLICT"
  fi
  trap - EXIT HUP INT TERM
  return 0
)

migrate_snapshot_path_allowed() {
  local rel="$1" parent name
  case "$rel" in
    .trellis.json|.trellis.config.json|CLAUDE.md|.gitignore|\
    .claude/rules/trellis.md|.agents/rules/trellis.md|\
    .claude/rules/se-core.md|.agents/rules/se-core.md|\
    .omp/skills|.omp/commands|.omp/agents|.omp/hooks|.omp/AGENTS.md|AGENTS.md)
      return 0
      ;;
  esac
  parent="$(dirname "$rel")"
  name="$(basename "$rel")"
  case "$parent" in
    .claude/skills|.agents/skills|.claude/commands|.agents/commands)
      [ -n "$name" ] && [ "$name" != . ] && [ "$name" != .. ]
      ;;
    .claude/rules|.agents/rules)
      case "$name" in preset-*.md) [ "$name" != preset-.md ] ;; *) return 1 ;; esac
      ;;
    *) return 1 ;;
  esac
}

migrate_entry_matches_state() {
  local path="$1" entry="$2" state="$3" type expected actual
  if [ "$state" = pre ]; then
    type="$(printf '%s\n' "$entry" | jq -r '.type')"
  else
    type="$(printf '%s\n' "$entry" | jq -r '.post_type')"
  fi
  case "$type" in
    absent)
      [ ! -e "$path" ] && [ ! -L "$path" ]
      ;;
    symlink)
      [ "$state" = pre ] || return 1
      [ -L "$path" ] || return 1
      expected="$(printf '%s\n' "$entry" | jq -r '.target')"
      actual="$(readlink "$path")" || return 1
      [ "$actual" = "$expected" ]
      ;;
    file)
      [ -f "$path" ] && [ ! -L "$path" ] || return 1
      if [ "$state" = pre ]; then
        expected="$(printf '%s\n' "$entry" | jq -r '.sha256')"
        actual="$(migrate_sha256_file "$path")" || return 1
        [ "$actual" = "$expected" ] || return 1
        expected="$(printf '%s\n' "$entry" | jq -r '.mode')"
      else
        expected="$(printf '%s\n' "$entry" | jq -r '.post_sha256')"
        actual="$(migrate_sha256_file "$path")" || return 1
        [ "$actual" = "$expected" ] || return 1
        expected="$(printf '%s\n' "$entry" | jq -r '.post_mode')"
      fi
      actual="$(migrate_file_mode "$path")" || return 1
      [ "$actual" = "$expected" ]
      ;;
    *) return 1 ;;
  esac
}

migrate_snapshot_create() {
  local home="$1" root="$2" project_id="$3" actions_file="$4" candidate="$5" transforms="$6"
  local machine_local_source="${7:-}" legacy_source_sha="${8:-}" legacy_source_identity="${9:-}"
  local snapshot_root snapshot identity head index rel path type mode target file sha
  local post_type post_source post_mode post_sha machine_local_mode rc counter=0
  snapshot_root="$home/state/migrations"
  trellis_home_prepare_private_dir "$snapshot_root" 'migration snapshots directory' || return "$?"
  snapshot="$snapshot_root/$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  while ! mkdir -m 700 "$snapshot" 2>/dev/null; do
    counter=$((counter + 1))
    [ "$counter" -lt 100 ] || return "$TRELLIS_EX_UNAVAILABLE"
    snapshot="$snapshot_root/$(date -u '+%Y%m%dT%H%M%SZ')-$$-$counter"
  done
  mkdir -m 700 "$snapshot/files" || { rm -rf "$snapshot"; return "$TRELLIS_EX_UNAVAILABLE"; }
  : > "$snapshot/entries.jsonl" || { rm -rf "$snapshot"; return "$TRELLIS_EX_UNAVAILABLE"; }
  chmod 600 "$snapshot/entries.jsonl" || { rm -rf "$snapshot"; return "$TRELLIS_EX_UNAVAILABLE"; }

  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    migrate_safe_relative "$rel" && migrate_snapshot_path_allowed "$rel" ||
      { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
    migrate_parent_safe "$root" "$rel" || { rm -rf "$snapshot"; return "$TRELLIS_EX_CONFLICT"; }
    path="$root/$rel"
    file="$(printf '%04d' "$counter")"
    counter=$((counter + 1))
    post_type=absent
    post_source=""
    post_mode=""
    post_sha=""
    case "$rel" in
      .trellis.json) post_type="file"; post_source="$candidate"; post_mode=644 ;;
      CLAUDE.md) post_type="file"; post_source="$transforms/CLAUDE.md"; post_mode="$(migrate_file_mode "$path")" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; } ;;
      .gitignore) post_type="file"; post_source="$transforms/gitignore"; post_mode="$(migrate_file_mode "$path")" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; } ;;
    esac
    if [ "$post_type" = file ]; then
      [ -f "$post_source" ] && [ ! -L "$post_source" ] || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
      post_sha="$(migrate_sha256_file "$post_source")" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
    fi

    if [ "$rel" = '.trellis.config.json' ] && [ -n "$legacy_source_sha" ]; then
      if [ ! -f "$path" ] || [ -L "$path" ] ||
        [ "$(migrate_file_link_count "$path")" != 1 ] ||
        [ "$(migrate_file_identity "$path")" != "$legacy_source_identity" ]; then
        rm -rf "$snapshot"
        migrate_err 'legacy policy changed while preparing migration'
        return "$TRELLIS_EX_CONFLICT"
      fi
    fi
    if [ -L "$path" ]; then
      type=symlink
      target="$(readlink "$path")" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
      jq -cnS --arg path "$rel" --arg type "$type" --arg target "$target" \
        --arg post_type "$post_type" --arg post_sha256 "$post_sha" --arg post_mode "$post_mode" \
        '{path:$path,type:$type,target:$target,post_type:$post_type}
         + (if $post_type == "file" then {post_sha256:$post_sha256,post_mode:$post_mode} else {} end)' \
        >> "$snapshot/entries.jsonl" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
    elif [ -f "$path" ]; then
      type="file"
      mode="$(migrate_file_mode "$path")" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
      cp -p "$path" "$snapshot/files/$file" || { rm -rf "$snapshot"; return "$TRELLIS_EX_UNAVAILABLE"; }
      chmod 600 "$snapshot/files/$file" || { rm -rf "$snapshot"; return "$TRELLIS_EX_UNAVAILABLE"; }
      sha="$(migrate_sha256_file "$snapshot/files/$file")" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
      [ "$sha" = "$(migrate_sha256_file "$path")" ] || {
        rm -rf "$snapshot"
        migrate_err "project file changed while snapshotting: $rel"
        return "$TRELLIS_EX_CONFLICT"
      }
      if [ "$rel" = '.trellis.config.json' ] && [ -n "$legacy_source_sha" ] &&
        { [ "$sha" != "$legacy_source_sha" ] ||
          [ "$(migrate_file_link_count "$path")" != 1 ] ||
          [ "$(migrate_file_identity "$path")" != "$legacy_source_identity" ]; }; then
        rm -rf "$snapshot"
        migrate_err 'legacy policy changed while preparing migration'
        return "$TRELLIS_EX_CONFLICT"
      fi
      jq -cnS --arg path "$rel" --arg type "$type" --arg mode "$mode" --arg file "$file" --arg sha256 "$sha" \
        --arg post_type "$post_type" --arg post_sha256 "$post_sha" --arg post_mode "$post_mode" \
        '{path:$path,type:$type,mode:$mode,file:$file,sha256:$sha256,post_type:$post_type}
         + (if $post_type == "file" then {post_sha256:$post_sha256,post_mode:$post_mode} else {} end)' \
        >> "$snapshot/entries.jsonl" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
    elif [ -e "$path" ]; then
      rm -rf "$snapshot"
      migrate_err "cannot snapshot unsupported path kind: $path"
      return "$TRELLIS_EX_CONFLICT"
    else
      jq -cnS --arg path "$rel" --arg post_type "$post_type" --arg post_sha256 "$post_sha" --arg post_mode "$post_mode" \
        '{path:$path,type:"absent",post_type:$post_type}
         + (if $post_type == "file" then {post_sha256:$post_sha256,post_mode:$post_mode} else {} end)' \
        >> "$snapshot/entries.jsonl" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
    fi
  done < "$actions_file"

  if [ -n "$machine_local_source" ]; then
    [ -f "$machine_local_source" ] && [ ! -L "$machine_local_source" ] &&
      jq -e 'type == "object" and keys == ["gptx"] and (.gptx | type == "object")' \
        "$machine_local_source" >/dev/null 2>&1 || {
      rm -rf "$snapshot"
      return "$TRELLIS_EX_STATE"
    }
    migrate_publish_file "$machine_local_source" "$snapshot/machine-local.json" 600 || {
      rc="$?"
      rm -rf "$snapshot"
      return "$rc"
    }
    [ -f "$snapshot/machine-local.json" ] && [ ! -L "$snapshot/machine-local.json" ] || {
      rm -rf "$snapshot"
      return "$TRELLIS_EX_STATE"
    }
    machine_local_mode="$(migrate_file_mode "$snapshot/machine-local.json")" || {
      rm -rf "$snapshot"
      return "$TRELLIS_EX_STATE"
    }
    [ "$machine_local_mode" = 600 ] &&
      cmp -s "$machine_local_source" "$snapshot/machine-local.json" || {
      rm -rf "$snapshot"
      return "$TRELLIS_EX_STATE"
    }
  fi

  identity="$(local_registry_identity_for_root "$root")" || {
    rc="$?"
    rm -rf "$snapshot"
    return "$rc"
  }
  head="$(git -C "$root" rev-parse HEAD 2>/dev/null)" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
  index="$(git -C "$root" write-tree 2>/dev/null)" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
  jq -sS \
    --arg root "$root" --arg project_id "$project_id" --arg head "$head" --arg index "$index" \
    --arg checkout_id "$(printf '%s\n' "$identity" | jq -r '.checkout_id')" \
    --arg worktree_id "$(printf '%s\n' "$identity" | jq -r '.worktree_id')" \
    '{schema_version:2,project_root:$root,project_id:$project_id,head:$head,index_tree:$index,checkout_id:$checkout_id,worktree_id:$worktree_id,entries:.}' \
    "$snapshot/entries.jsonl" > "$snapshot/manifest.json" || { rm -rf "$snapshot"; return "$TRELLIS_EX_STATE"; }
  chmod 600 "$snapshot/manifest.json" || { rm -rf "$snapshot"; return "$TRELLIS_EX_UNAVAILABLE"; }
  rm -f "$snapshot/entries.jsonl"
  printf '%s\n' "$snapshot"
}

migrate_prepare() (
  local home_opt="" project_id_opt="" legacy_root_opt="" root_opt="" home root manifest legacy existing_id project_id candidate work actions transforms
  local snapshot rel path mode rule_targets import_targets import_lines canonical_roots legacy_root="" rc
  local legacy_source="" legacy_source_sha="" legacy_source_identity="" legacy_claim="" machine_local_source=""
  local legacy_claim_identity="" legacy_claim_sha="" legacy_claim_acquired=false legacy_claim_pinned=false
  local -a owned_paths=(
    '.claude/rules/trellis.md'
    '.agents/rules/trellis.md'
    '.claude/rules/se-core.md'
    '.agents/rules/se-core.md'
    '.omp/skills'
    '.omp/commands'
    '.omp/agents'
    '.omp/hooks'
    '.omp/AGENTS.md'
    'AGENTS.md'
  )
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home) [ "$#" -ge 2 ] || { migrate_usage_error '--home requires PATH'; return $?; }; home_opt="$2"; shift 2 ;;
      --project-id) [ "$#" -ge 2 ] || { migrate_usage_error '--project-id requires ID'; return $?; }; project_id_opt="$2"; shift 2 ;;
      --legacy-root) [ "$#" -ge 2 ] || { migrate_usage_error '--legacy-root requires PATH'; return $?; }; legacy_root_opt="$2"; shift 2 ;;
      --) shift; break ;;
      -h|--help) migrate_usage; return 0 ;;
      -*) migrate_usage_error "unknown prepare option: $1"; return $? ;;
      *) [ -z "$root_opt" ] || { migrate_usage_error 'prepare accepts one PATH'; return $?; }; root_opt="$1"; shift ;;
    esac
  done
  [ "$#" -eq 0 ] || { migrate_usage_error "unexpected argument: $1"; return $?; }
  [ -n "$root_opt" ] || { migrate_usage_error 'prepare requires PATH'; return $?; }
  root="$(migrate_real_root "$root_opt")" || return "$?"
  home="$(trellis_home_resolve "$home_opt")" || return "$?"
  case "$home" in
    "$root"|"$root"/*)
      migrate_err 'TRELLIS_HOME must be outside the project worktree'
      return "$TRELLIS_EX_CONFLICT"
      ;;
  esac
  trellis_home_prepare_home "$home" || return "$?"
  trellis_home_require_jq || return "$?"
  if [ -n "$legacy_root_opt" ]; then
    legacy_root="$(local_registry_real_directory 'legacy Trellis root' "$legacy_root_opt")" || return "$?"
  fi

  manifest="$root/.trellis.json"
  legacy="$root/.trellis.config.json"
  [ ! -L "$manifest" ] || { migrate_err 'portable project manifest must not be a symlink'; return "$TRELLIS_EX_CONFLICT"; }
  [ ! -e "$manifest" ] || [ -f "$manifest" ] || { migrate_err 'portable project manifest is not a regular file'; return "$TRELLIS_EX_CONFLICT"; }
  [ ! -L "$legacy" ] || { migrate_err 'legacy project policy must not be a symlink'; return "$TRELLIS_EX_CONFLICT"; }
  [ ! -e "$legacy" ] || [ -f "$legacy" ] || { migrate_err 'legacy project policy is not a regular file'; return "$TRELLIS_EX_CONFLICT"; }
  if [ -f "$manifest" ] && [ -f "$legacy" ]; then
    migrate_err 'portable and legacy manifests coexist; ownership is ambiguous'
    return "$TRELLIS_EX_CONFLICT"
  fi

  if [ -f "$manifest" ]; then
    existing_id="$(local_registry_manifest_project_id "$manifest")" || return "$TRELLIS_EX_CONFLICT"
    project_id="${project_id_opt:-$existing_id}"
    [ "$project_id" = "$existing_id" ] || { migrate_err "existing project ID $existing_id conflicts with requested ID $project_id"; return "$TRELLIS_EX_CONFLICT"; }
  else
    project_id="${project_id_opt:-$(basename "$root")}"
    local_registry_require_project_id "$project_id" || return "$?"
  fi

  work="$(mktemp -d "${TMPDIR:-/tmp}/trellis-migrate.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  migrate_prepare_cleanup() {
    local status="${1:-$?}" cleanup_status=0
    trap - EXIT
    trap '' HUP INT TERM
    if [ "$legacy_claim_acquired" = true ] && [ -n "$legacy_claim" ] &&
      { [ -e "$legacy_claim" ] || [ -L "$legacy_claim" ]; }; then
      if [ ! -f "$legacy_claim" ] || [ -L "$legacy_claim" ]; then
        cleanup_status="$TRELLIS_EX_CONFLICT"
      elif [ "$legacy_claim_pinned" = true ] &&
        { [ "$(migrate_file_identity "$legacy_claim")" != "$legacy_claim_identity" ] ||
          [ "$(migrate_sha256_file "$legacy_claim")" != "$legacy_claim_sha" ]; }; then
        cleanup_status="$TRELLIS_EX_CONFLICT"
      elif [ ! -e "$legacy" ] && [ ! -L "$legacy" ]; then
        release_store_rename_no_clobber "$legacy_claim" "$legacy" ||
          cleanup_status="$?"
      else
        cleanup_status="$TRELLIS_EX_CONFLICT"
      fi
    fi
    rm -rf "${work:-}" || cleanup_status="$TRELLIS_EX_UNAVAILABLE"
    if [ "$cleanup_status" -ne 0 ] && [ "$status" -lt "$cleanup_status" ]; then
      status="$cleanup_status"
    fi
    exit "$status"
  }
  trap 'migrate_prepare_cleanup "$?"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  candidate="$work/manifest.json"
  actions="$work/actions"
  transforms="$work/transforms"
  rule_targets="$work/rule-targets"
  import_targets="$work/import-targets"
  import_lines="$work/import-lines"
  canonical_roots="$work/canonical-roots"
  : > "$actions" || return "$TRELLIS_EX_UNAVAILABLE"
  : > "$rule_targets" || return "$TRELLIS_EX_UNAVAILABLE"
  : > "$import_targets" || return "$TRELLIS_EX_UNAVAILABLE"
  : > "$import_lines" || return "$TRELLIS_EX_UNAVAILABLE"
  : > "$canonical_roots" || return "$TRELLIS_EX_UNAVAILABLE"
  mkdir "$transforms" || return "$TRELLIS_EX_UNAVAILABLE"

  if [ -f "$manifest" ]; then
    cp "$manifest" "$candidate" || return "$TRELLIS_EX_UNAVAILABLE"
  elif [ -f "$legacy" ]; then
    legacy_source="$work/legacy.json"
    legacy_source_identity="$(migrate_file_identity "$legacy")" || return "$TRELLIS_EX_STATE"
    if [ "$(migrate_file_link_count "$legacy")" != 1 ]; then
      migrate_err 'legacy project policy must not have multiple hard links'
      return "$TRELLIS_EX_CONFLICT"
    fi
    cp "$legacy" "$legacy_source" || return "$TRELLIS_EX_UNAVAILABLE"
    legacy_source_sha="$(migrate_sha256_file "$legacy_source")" || return "$TRELLIS_EX_STATE"
    if [ "$legacy_source_sha" != "$(migrate_sha256_file "$legacy")" ] ||
      [ "$legacy_source_identity" != "$(migrate_file_identity "$legacy")" ]; then
      migrate_err 'legacy policy changed while preparing migration'
      return "$TRELLIS_EX_CONFLICT"
    fi
    if ! jq -e '
      def portable_string:
        if type == "string" then
          (test("^(?:/|~|[A-Za-z]:)") | not) and (test("\\\\") | not)
        else true end;
      def portable:
        if type == "object" then
          all(to_entries[]; ((.key | portable_string) and (.value | portable)))
        elif type == "array" then all(.[]; portable)
        else portable_string
        end;
      type == "object"
      and ((keys_unsorted - ["$schema","schema_version","project_id","presets","autonomy","package_manager","loop_safety","mandatory_pipeline","gate_profiles","gptx"]) | length == 0)
      and ((has("gptx") | not) or (.gptx | type == "object"))
      and (del(.gptx) | portable)
      and ((has("schema_version") | not) or .schema_version == 1)
      and ((has("project_id") | not) or .project_id == $project_id)
    ' --arg project_id "$project_id" "$legacy_source" >/dev/null 2>&1; then
      migrate_err 'legacy policy contains ambiguous, machine-local, or invalid fields'
      return "$TRELLIS_EX_CONFLICT"
    fi
    if jq -e 'has("gptx")' "$legacy_source" >/dev/null 2>&1; then
      machine_local_source="$work/machine-local.json"
      (umask 077; jq -S '{gptx:.gptx}' "$legacy_source" > "$machine_local_source") ||
        return "$TRELLIS_EX_STATE"
      chmod 600 "$machine_local_source" || return "$TRELLIS_EX_UNAVAILABLE"
    fi
    jq -S --arg project_id "$project_id" --arg schema "$MIGRATE_PROJECT_SCHEMA" \
      'del(.gptx) + {"$schema":$schema,schema_version:1,project_id:$project_id}' \
      "$legacy_source" > "$candidate" || return "$TRELLIS_EX_STATE"
  else
    jq -nS --arg project_id "$project_id" --arg schema "$MIGRATE_PROJECT_SCHEMA" \
      '{"$schema":$schema,schema_version:1,project_id:$project_id}' > "$candidate" || return "$TRELLIS_EX_STATE"
  fi
  local_registry_manifest_project_id "$candidate" >/dev/null || { migrate_err 'prepared portable manifest failed validation'; return "$TRELLIS_EX_CONFLICT"; }

  if [ -f "$root/CLAUDE.md" ] && [ ! -L "$root/CLAUDE.md" ]; then
    migrate_collect_absolute_import_targets "$root/CLAUDE.md" "$import_targets" || return "$?"
  elif [ -e "$root/CLAUDE.md" ] || [ -L "$root/CLAUDE.md" ]; then
    migrate_err 'CLAUDE.md is not a regular project-owned file'
    return "$TRELLIS_EX_CONFLICT"
  fi
  migrate_collect_rule_targets "$root" "$rule_targets" || return "$?"
  migrate_build_canonical_roots "$root" "$rule_targets" "$import_targets" "$canonical_roots" "$legacy_root" || return "$?"

  for rel in "${owned_paths[@]}"; do
    migrate_parent_safe "$root" "$rel" || return "$TRELLIS_EX_CONFLICT"
    path="$root/$rel"
    if [ -L "$path" ]; then
      migrate_static_symlink_owned "$root" "$rel" "$path" "$canonical_roots" || {
        migrate_err "ambiguous legacy symlink: $rel -> $(readlink "$path")"
        return "$TRELLIS_EX_CONFLICT"
      }
      printf '%s\n' "$rel" >> "$actions"
    elif [ -f "$path" ]; then
      migrate_regular_copy_owned "$root" "$rel" "$path" "$canonical_roots" || {
        case "$rel" in
          # An authored AGENTS.md is project content, not managed output: leave
          # it untouched instead of refusing the whole migration. Byte-equality
          # against the compared roots is the only ownership evidence available,
          # so output materialized by a third release reads as authored too —
          # name every left-alone path so the residue is visible in the prepare
          # output rather than discovered later.
          .omp/AGENTS.md|AGENTS.md)
            migrate_warn "left in place, ownership not provable: $rel"
            continue ;;
        esac
        migrate_err "divergent project-owned legacy candidate: $rel"
        return "$TRELLIS_EX_CONFLICT"
      }
      printf '%s\n' "$rel" >> "$actions"
    elif [ -e "$path" ]; then
      migrate_err "ambiguous legacy path kind: $rel"
      return "$TRELLIS_EX_CONFLICT"
    fi
  done

  migrate_classify_link_family "$root" '.claude/skills' 'skills' "$actions" "$canonical_roots" "$root/.gitignore" || return "$?"
  migrate_classify_link_family "$root" '.agents/skills' 'skills' "$actions" "$canonical_roots" "$root/.gitignore" || return "$?"
  migrate_classify_link_family "$root" '.claude/commands' 'commands' "$actions" "$canonical_roots" "$root/.gitignore" || return "$?"
  migrate_classify_link_family "$root" '.agents/commands' 'commands' "$actions" "$canonical_roots" "$root/.gitignore" || return "$?"
  migrate_classify_preset_family "$root" '.claude/rules' "$actions" "$canonical_roots" "$root/.gitignore" || return "$?"
  migrate_classify_preset_family "$root" '.agents/rules' "$actions" "$canonical_roots" "$root/.gitignore" || return "$?"

  if [ -f "$root/CLAUDE.md" ]; then
    migrate_classify_imports "$root/CLAUDE.md" "$canonical_roots" "$import_lines" || return "$?"
    migrate_transform_imports "$root/CLAUDE.md" "$transforms/CLAUDE.md" "$import_lines" || return "$TRELLIS_EX_STATE"
    if ! cmp -s "$root/CLAUDE.md" "$transforms/CLAUDE.md"; then printf 'CLAUDE.md\n' >> "$actions"; fi
  fi

  if [ -f "$root/.gitignore" ] && [ ! -L "$root/.gitignore" ]; then
    if ! migrate_transform_ignore "$root/.gitignore" "$transforms/gitignore"; then
      migrate_err 'legacy managed ignore block is unterminated'
      return "$TRELLIS_EX_CONFLICT"
    fi
    if ! cmp -s "$root/.gitignore" "$transforms/gitignore"; then printf '.gitignore\n' >> "$actions"; fi
  elif [ -e "$root/.gitignore" ] || [ -L "$root/.gitignore" ]; then
    migrate_err '.gitignore is not a regular project-owned file'
    return "$TRELLIS_EX_CONFLICT"
  fi

  if [ -n "$legacy_source" ]; then printf '.trellis.config.json\n' >> "$actions"; fi
  if [ ! -f "$manifest" ]; then printf '.trellis.json\n' >> "$actions"; fi
  LC_ALL=C sort -u "$actions" -o "$actions" || return "$TRELLIS_EX_STATE"

  snapshot="$(migrate_snapshot_create "$home" "$root" "$project_id" "$actions" "$candidate" \
    "$transforms" "$machine_local_source" "$legacy_source_sha" "$legacy_source_identity")" || return "$?"
  printf 'snapshot: %s\n' "$snapshot"
  printf 'rollback: %q --rollback %q\n' "$0" "$snapshot"
  if [ -n "$legacy_source" ]; then
    migrate_parent_safe "$root" '.trellis.config.json' || return "$TRELLIS_EX_CONFLICT"
    legacy_claim="$(mktemp "$root/.trellis-migrate-removal.XXXXXX")" ||
      return "$TRELLIS_EX_UNAVAILABLE"
    rm "$legacy_claim" || return "$TRELLIS_EX_UNAVAILABLE"
    migrate_claim_legacy_policy "$legacy" "$legacy_claim"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ -e "$legacy" ] || [ -L "$legacy" ]; then
        legacy_claim=""
      fi
      return "$rc"
    fi
    if [ "$(migrate_file_link_count "$legacy_claim")" != 1 ] ||
      [ "$legacy_claim_identity" != "$legacy_source_identity" ] ||
      [ "$legacy_claim_sha" != "$legacy_source_sha" ] ||
      [ "$(migrate_file_identity "$legacy_claim")" != "$legacy_claim_identity" ] ||
      [ "$(migrate_sha256_file "$legacy_claim")" != "$legacy_claim_sha" ]; then
      migrate_err 'legacy policy changed after snapshot; preserving the captured file'
      return "$TRELLIS_EX_CONFLICT"
    fi
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    migrate_parent_safe "$root" "$rel" || return "$TRELLIS_EX_CONFLICT"
    path="$root/$rel"
    case "$rel" in
      .trellis.json) migrate_publish_file "$candidate" "$path" 644 || return "$?" ;;
      .trellis.config.json) continue ;;
      CLAUDE.md)
        mode="$(migrate_file_mode "$path")" || return "$TRELLIS_EX_STATE"
        migrate_publish_file "$transforms/CLAUDE.md" "$path" "$mode" || return "$?" ;;
      .gitignore)
        mode="$(migrate_file_mode "$path")" || return "$TRELLIS_EX_STATE"
        migrate_publish_file "$transforms/gitignore" "$path" "$mode" || return "$?" ;;
      *) rm -f "$path" || return "$TRELLIS_EX_UNAVAILABLE" ;;
    esac
  done < "$actions"
  if [ -n "$legacy_source" ] &&
    { [ -e "$legacy" ] || [ -L "$legacy" ]; }; then
    migrate_err 'legacy policy reappeared during migration; use the printed rollback command'
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ -n "$legacy_claim" ]; then
    trap '' HUP INT TERM
    if [ ! -f "$legacy_claim" ] || [ -L "$legacy_claim" ] ||
      [ "$(migrate_file_link_count "$legacy_claim")" != 1 ] ||
      [ "$(migrate_file_identity "$legacy_claim")" != "$legacy_source_identity" ] ||
      [ "$(migrate_sha256_file "$legacy_claim")" != "$legacy_source_sha" ]; then
      migrate_err 'legacy retirement claim changed before migration commit'
      return "$TRELLIS_EX_CONFLICT"
    fi
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
      migrate_err 'legacy policy reappeared at the migration commit boundary'
      return "$TRELLIS_EX_CONFLICT"
    fi
    rm "$legacy_claim" || return "$TRELLIS_EX_UNAVAILABLE"
    legacy_claim=""
    if [ -e "$legacy" ] || [ -L "$legacy" ]; then
      migrate_err 'legacy policy reappeared while committing migration'
      return "$TRELLIS_EX_CONFLICT"
    fi
  fi
  if [ -n "$machine_local_source" ]; then
    printf 'machine-local snapshot: %q\n' "$snapshot/machine-local.json"
    printf '# registry annotate template; replace FLEET:\n'
    printf '%q registry annotate --home %q --fleet FLEET --project %q --metadata-json "$(cat < %q)"\n' \
      "$SCRIPT_DIR/trellis" "$home" "$project_id" "$snapshot/machine-local.json"
  fi

  printf 'prepared migration: %s\n' "$root"
)

migrate_rollback() (
  local snapshot="${1:-}" original_snapshot manifest plan home snapshot_root root identity checkout worktree
  local entry rel type post_type path file mode target current_head current_index actual expected rc preserve_legacy=false
  local legacy_rollback_state="" preserve_legacy_identity="" preserve_legacy_sha=""
  [ -n "$snapshot" ] || { migrate_usage_error 'rollback requires SNAPSHOT'; return $?; }
  [ "$#" -eq 1 ] || { migrate_usage_error 'rollback accepts one SNAPSHOT'; return $?; }
  home="$(trellis_home_resolve)" || return "$?"
  snapshot_root="$(local_registry_real_directory 'migration snapshots directory' "$home/state/migrations")" || return "$?"
  snapshot="$(local_registry_real_directory 'migration snapshot' "$snapshot")" || return "$?"
  [ "$(dirname "$snapshot")" = "$snapshot_root" ] || {
    migrate_err 'snapshot is outside TRELLIS_HOME/state/migrations'
    return "$TRELLIS_EX_CONFLICT"
  }
  [ -f "$snapshot/manifest.json" ] && [ ! -L "$snapshot/manifest.json" ] || { migrate_err 'snapshot manifest is missing or unsafe'; return "$TRELLIS_EX_STATE"; }
  original_snapshot="$snapshot"
  plan="$(umask 077; mktemp -d "$home/state/rollback-plan.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  trap 'chmod -R u+w "${plan:-}" 2>/dev/null || true; rm -rf "${plan:-}"' EXIT HUP INT TERM
  chmod 700 "$plan" || return "$TRELLIS_EX_UNAVAILABLE"
  cp "$snapshot/manifest.json" "$plan/manifest.json" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod 400 "$plan/manifest.json" || return "$TRELLIS_EX_UNAVAILABLE"
  manifest="$plan/manifest.json"
  [ -f "$manifest" ] && [ ! -L "$manifest" ] || { migrate_err 'snapshot manifest is missing or unsafe'; return "$TRELLIS_EX_STATE"; }
  jq -e '
    keys == ["checkout_id","entries","head","index_tree","project_id","project_root","schema_version","worktree_id"] and
    .schema_version == 2 and
    ([.project_root,.project_id,.head,.index_tree,.checkout_id,.worktree_id] | all(type == "string" and length > 0)) and
    (.entries | type == "array") and
    ([.entries[].path] | length == (unique | length)) and
    all(.entries[];
      (type == "object") and
      (.path | type == "string" and length > 0) and
      (.type == "absent" or .type == "symlink" or .type == "file") and
      (.post_type == "absent" or .post_type == "file") and
      (if .type == "absent" then
         (keys - ["path","post_mode","post_sha256","post_type","type"] | length == 0)
       elif .type == "symlink" then
         (.target | type == "string") and
         (keys - ["path","post_mode","post_sha256","post_type","target","type"] | length == 0)
       else
         (.file | type == "string" and test("^[0-9]{4}$")) and
         (.mode | type == "string" and test("^[0-7]{3,4}$")) and
         (.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
         (keys - ["file","mode","path","post_mode","post_sha256","post_type","sha256","type"] | length == 0)
       end) and
      (if .post_type == "file" then
         (.post_mode | type == "string" and test("^[0-7]{3,4}$")) and
         (.post_sha256 | type == "string" and test("^[a-f0-9]{64}$"))
       else
         (has("post_mode") | not) and (has("post_sha256") | not)
       end)
    )
  ' "$manifest" >/dev/null 2>&1 || { migrate_err 'snapshot manifest is corrupt'; return "$TRELLIS_EX_STATE"; }
  mkdir -m 700 "$plan/files" || return "$TRELLIS_EX_UNAVAILABLE"
  while IFS= read -r entry; do
    [ "$(printf '%s\n' "$entry" | jq -r '.type')" = file ] || continue
    file="$(printf '%s\n' "$entry" | jq -r '.file')"
    [ -f "$snapshot/files/$file" ] && [ ! -L "$snapshot/files/$file" ] || {
      migrate_err "snapshot payload is missing or unsafe: $file"
      return "$TRELLIS_EX_STATE"
    }
    cp "$snapshot/files/$file" "$plan/files/$file" || return "$TRELLIS_EX_UNAVAILABLE"
    chmod 400 "$plan/files/$file" || return "$TRELLIS_EX_UNAVAILABLE"
    actual="$(migrate_sha256_file "$plan/files/$file")" || return "$TRELLIS_EX_STATE"
    expected="$(printf '%s\n' "$entry" | jq -r '.sha256')"
    [ "$actual" = "$expected" ] || {
      migrate_err "snapshot payload digest mismatch: $file"
      return "$TRELLIS_EX_STATE"
    }
  done < <(jq -c '.entries[]' "$manifest")
  chmod 500 "$plan/files" "$plan" || return "$TRELLIS_EX_UNAVAILABLE"

  root="$(jq -r '.project_root' "$manifest")" || return "$TRELLIS_EX_STATE"
  root="$(migrate_real_root "$root")" || return "$?"
  identity="$(local_registry_identity_for_root "$root")" || return "$?"
  checkout="$(printf '%s\n' "$identity" | jq -r '.checkout_id')"
  worktree="$(printf '%s\n' "$identity" | jq -r '.worktree_id')"
  [ "$checkout" = "$(jq -r '.checkout_id' "$manifest")" ] && [ "$worktree" = "$(jq -r '.worktree_id' "$manifest")" ] || {
    migrate_err 'snapshot identity does not match the current checkout'
    return "$TRELLIS_EX_CONFLICT"
  }
  current_head="$(git -C "$root" rev-parse HEAD 2>/dev/null)" || return "$TRELLIS_EX_STATE"
  current_index="$(git -C "$root" write-tree 2>/dev/null)" || return "$TRELLIS_EX_STATE"
  [ "$current_head" = "$(jq -r '.head' "$manifest")" ] && [ "$current_index" = "$(jq -r '.index_tree' "$manifest")" ] || {
    migrate_err 'HEAD or index changed since the migration snapshot'
    return "$TRELLIS_EX_CONFLICT"
  }

  # Preflight every entry and payload before the first project mutation.
  while IFS= read -r entry; do
    rel="$(printf '%s\n' "$entry" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
    migrate_safe_relative "$rel" && migrate_snapshot_path_allowed "$rel" || {
      migrate_err "snapshot contains an unapproved path: $rel"
      return "$TRELLIS_EX_STATE"
    }
    migrate_parent_safe "$root" "$rel" || return "$TRELLIS_EX_CONFLICT"
    path="$root/$rel"
    [ ! -d "$path" ] || [ -L "$path" ] || {
      migrate_err "rollback destination is a directory: $rel"
      return "$TRELLIS_EX_CONFLICT"
    }
    type="$(printf '%s\n' "$entry" | jq -r '.type')"
    if [ "$type" = file ]; then
      file="$(printf '%s\n' "$entry" | jq -r '.file')"
      [ -f "$plan/files/$file" ] && [ ! -L "$plan/files/$file" ] || {
        migrate_err "snapshot payload is missing or unsafe: $file"
        return "$TRELLIS_EX_STATE"
      }
      actual="$(migrate_sha256_file "$plan/files/$file")" || return "$TRELLIS_EX_STATE"
      expected="$(printf '%s\n' "$entry" | jq -r '.sha256')"
      [ "$actual" = "$expected" ] || {
        migrate_err "snapshot payload digest mismatch: $file"
        return "$TRELLIS_EX_STATE"
      }
    fi
    if migrate_entry_matches_state "$path" "$entry" pre; then
      [ "$rel" != '.trellis.config.json' ] || legacy_rollback_state=pre
    elif migrate_entry_matches_state "$path" "$entry" post; then
      [ "$rel" != '.trellis.config.json' ] || legacy_rollback_state=post
    else
      post_type="$(printf '%s\n' "$entry" | jq -r '.post_type')" || return "$TRELLIS_EX_STATE"
      if [ "$rel" = '.trellis.config.json' ] && [ "$type" = file ] &&
        [ "$post_type" = absent ] && [ -f "$path" ] && [ ! -L "$path" ]; then
        preserve_legacy=true
        preserve_legacy_identity="$(migrate_file_identity "$path")" || return "$TRELLIS_EX_STATE"
        preserve_legacy_sha="$(migrate_sha256_file "$path")" || return "$TRELLIS_EX_STATE"
      else
        migrate_err "rollback destination changed since prepare: $rel"
        return "$TRELLIS_EX_CONFLICT"
      fi
    fi
  done < <(jq -c '.entries[]' "$manifest")

  while IFS= read -r entry; do
    rel="$(printf '%s\n' "$entry" | jq -r '.path')"
    type="$(printf '%s\n' "$entry" | jq -r '.type')"
    path="$root/$rel"
    migrate_parent_safe "$root" "$rel" || return "$TRELLIS_EX_CONFLICT"
    if [ "$rel" = '.trellis.config.json' ]; then
      if [ "$preserve_legacy" = true ]; then
        if [ -f "$path" ] && [ ! -L "$path" ] &&
          [ "$(migrate_file_identity "$path")" = "$preserve_legacy_identity" ] &&
          [ "$(migrate_sha256_file "$path")" = "$preserve_legacy_sha" ]; then
          continue
        fi
        if ! migrate_entry_matches_state "$path" "$entry" post; then
          migrate_err 'newer legacy policy changed during rollback'
          return "$TRELLIS_EX_CONFLICT"
        fi
        preserve_legacy=false
        legacy_rollback_state=post
      fi
      [ -n "$legacy_rollback_state" ] &&
        migrate_entry_matches_state "$path" "$entry" "$legacy_rollback_state" || {
        migrate_err 'legacy policy changed during rollback'
        return "$TRELLIS_EX_CONFLICT"
      }
      if [ "$legacy_rollback_state" = pre ]; then
        continue
      fi
      [ "$type" = file ] || return "$TRELLIS_EX_STATE"
      file="$(printf '%s\n' "$entry" | jq -r '.file')"
      mode="$(printf '%s\n' "$entry" | jq -r '.mode')"
      migrate_publish_file_exclusive "$plan/files/$file" "$path" "$mode" || {
        rc=$?
        [ "$rc" -ne "$TRELLIS_EX_CONFLICT" ] ||
          migrate_err 'legacy policy appeared during rollback; preserved the current path'
        return "$rc"
      }
      continue
    fi
    rm -f "$path" || return "$TRELLIS_EX_UNAVAILABLE"
    case "$type" in
      absent) ;;
      symlink)
        target="$(printf '%s\n' "$entry" | jq -r '.target')"
        mkdir -p "$(dirname "$path")" || return "$TRELLIS_EX_UNAVAILABLE"
        migrate_parent_safe "$root" "$rel" || return "$TRELLIS_EX_CONFLICT"
        ln -s "$target" "$path" || return "$TRELLIS_EX_UNAVAILABLE"
        ;;
      file)
        file="$(printf '%s\n' "$entry" | jq -r '.file')"
        mode="$(printf '%s\n' "$entry" | jq -r '.mode')"
        mkdir -p "$(dirname "$path")" || return "$TRELLIS_EX_UNAVAILABLE"
        migrate_parent_safe "$root" "$rel" || return "$TRELLIS_EX_CONFLICT"
        cp "$plan/files/$file" "$path" || return "$TRELLIS_EX_UNAVAILABLE"
        chmod "$mode" "$path" || return "$TRELLIS_EX_UNAVAILABLE"
        ;;
    esac
  done < <(jq -c '.entries | sort_by(if .path == ".trellis.config.json" then 0 else 1 end)[]' "$manifest")
  if [ "$preserve_legacy" = true ]; then
    printf 'preserved newer legacy policy during rollback: %s\n' "$root/.trellis.config.json"
  fi
  printf 'restored migration snapshot: %s\n' "$original_snapshot"
  chmod -R u+w "$plan" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  trap - EXIT HUP INT TERM
  rm -rf "$plan"
)

main() {
  local command="${1:-}"
  case "$command" in
    --prepare) shift; migrate_prepare "$@" ;;
    --rollback) shift; migrate_rollback "$@" ;;
    -h|--help|help|'') migrate_usage ;;
    *) migrate_usage_error "unknown command: $command" ;;
  esac
}

main "$@"
