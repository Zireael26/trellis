#!/usr/bin/env bash
# trellis skills — Trellis-owned operator skill store.
#
# Operator and third-party user skills live as real directories only under
# $TRELLIS_HOME/skills/<name>/. Each harness discovery root holds only
# Trellis-managed absolute symlinks into the store. A store skill carries an
# optional trellis-skill.json naming the harnesses that receive it; absent
# means all three (claude, codex, pi). The harness-set to discovery-root
# table is defined once in scripts/lib/skill-roots.sh and sourced here, never
# duplicated.
#
# Subcommands: list | import <dir>... | link [name...] | unlink <name>
#
# Exit classes (scripts/lib/trellis-home.sh): 0 success, 2 bad arguments or
# malformed harness set, 3 ownership conflict or refusal (never forced), 4
# corrupt local state, 5 unavailable path or capability.
#
# Bash 3.2 compatible: no associative arrays, no mapfile.

set -euo pipefail

case "$0" in
  */*) SKILLS_SCRIPT_DIR="$(CDPATH='' cd -- "${0%/*}" && pwd -P)" ;;
  *)   SKILLS_SCRIPT_DIR="$(CDPATH='' cd -- "." && pwd -P)" ;;
esac

# shellcheck source=lib/trellis-home.sh
. "$SKILLS_SCRIPT_DIR/lib/trellis-home.sh"
# shellcheck source=lib/skill-roots.sh
. "$SKILLS_SCRIPT_DIR/lib/skill-roots.sh"
# shellcheck source=lib/attachment.sh
. "$SKILLS_SCRIPT_DIR/lib/attachment.sh"

SKILLS_STATE_SCHEMA='trellis-user-skills/v1'

skills_err() {
  printf 'trellis skills: %s\n' "$*" >&2
}

skills_usage() {
  cat <<'EOF'
Usage:
  trellis skills list
  trellis skills import <dir>...
  trellis skills link [name...]
  trellis skills unlink <name>
EOF
}

skills_uuid() {
  local raw
  if command -v uuidgen >/dev/null 2>&1; then
    raw="$(uuidgen | tr '[:upper:]' '[:lower:]')" || return "$TRELLIS_EX_UNAVAILABLE"
  else
    raw="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')" || return "$TRELLIS_EX_UNAVAILABLE"
  fi
  [ -n "$raw" ] || return "$TRELLIS_EX_UNAVAILABLE"
  printf '%s\n' "$raw"
}

skills_resolve_home() {
  local home
  home="$(trellis_home_resolve "")" || return "$?"
  home="$(trellis_home_canonical_home "$home")" || return "$?"
  printf '%s\n' "$home"
}

skills_prepare_home() {
  local home="$1"
  trellis_home_prepare_private_dir "$home" "TRELLIS_HOME" || return "$?"
  trellis_home_prepare_private_dir "$home/state" "Trellis state directory" || return "$?"
  trellis_home_prepare_private_dir "$home/state/locks" "Trellis locks directory" || return "$?"
  trellis_home_prepare_private_dir "$home/skills" "Trellis skills directory" || return "$?"
}

# The user-surface lock from attachment.sh, shared with attach --user so a
# skills mutation never races one. Reclaim-then-acquire mirrors
# attach-project.sh; the EXIT trap releases on every return path.
skills_lock_acquire() {
  local home="$1" rc
  attachment_user_lock_reclaim "$home" || {
    rc=$?
    [ "$rc" -eq 1 ] && return "$TRELLIS_EX_UNAVAILABLE"
    return "$rc"
  }
  attachment_user_lock_acquire "$home" "$(skills_uuid)" || {
    rc=$?
    [ "$rc" -eq 1 ] && return "$TRELLIS_EX_UNAVAILABLE"
    return "$rc"
  }
  trap '_attachment_signal_exit' HUP
  trap '_attachment_signal_exit' INT
  trap '_attachment_signal_exit' TERM
  trap 'attachment_user_lock_release >/dev/null 2>&1 || true' EXIT
  return 0
}

skills_lock_release() {
  local rc
  trap - HUP INT TERM EXIT
  attachment_user_lock_release || {
    rc=$?
    [ "$rc" -eq 1 ] && return "$TRELLIS_EX_UNAVAILABLE"
    return "$rc"
  }
}

skills_state_path() {
  printf '%s/state/user-skills.json\n' "$1"
}

# Canonical state JSON on stdout. A missing record is the empty record; a
# present-but-unparseable one is corrupt state, never silently rebuilt.
skills_state_read() {
  local home="$1" path state
  path="$(skills_state_path "$home")"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    jq -cn --arg schema "$SKILLS_STATE_SCHEMA" '{schema:$schema,links:[]}'
    return 0
  fi
  if [ -L "$path" ] || [ ! -f "$path" ]; then
    skills_err "user skills record is unavailable or unsafe: $path"
    return "$TRELLIS_EX_STATE"
  fi
  state="$(cat "$path" 2>/dev/null)" || {
    skills_err "user skills record is unreadable: $path"
    return "$TRELLIS_EX_STATE"
  }
  printf '%s\n' "$state" | jq -e --arg schema "$SKILLS_STATE_SCHEMA" '
    type == "object" and .schema == $schema and (.links | type == "array")
    and ([.links[]
      | type == "object"
        and has("path") and has("target") and has("skill")
        and (.path | type == "string")
        and (.target | type == "string")
        and (.skill | type == "string")] | all)
  ' >/dev/null 2>&1 || {
    skills_err "user skills record is corrupt: $path"
    return "$TRELLIS_EX_STATE"
  }
  printf '%s\n' "$state" | jq -cS '.'
}

# Atomic temp+rename write of canonical state JSON. The caller holds the
# user-surface lock; _attachment_write_json refuses symlinked destinations.
skills_state_write() {
  local home="$1" json="$2" rc
  _attachment_write_json "$(skills_state_path "$home")" "$json" || {
    rc=$?
    [ "$rc" -eq 1 ] && return "$TRELLIS_EX_UNAVAILABLE"
    return "$rc"
  }
}

# Canonical harness names for a store (or import-source) skill directory, one
# per line in fixed claude/codex/pi order. Absent trellis-skill.json means all
# three. Anything else malformed — bad JSON, missing or empty harnesses list,
# unknown harness — is exit 2 naming the skill.
skills_harness_set() {
  local dir="$1" name="$2" cfg h
  cfg="$dir/trellis-skill.json"
  if [ ! -e "$cfg" ] && [ ! -L "$cfg" ]; then
    printf 'claude\ncodex\npi\n'
    return 0
  fi
  if [ -L "$cfg" ] || [ ! -f "$cfg" ]; then
    skills_err "skill $name has an unreadable trellis-skill.json"
    return "$TRELLIS_EX_USAGE"
  fi
  jq -e '
    type == "object" and has("harnesses")
    and (.harnesses | type == "array" and length > 0
      and all(.[]; . == "claude" or . == "codex" or . == "pi"))
  ' "$cfg" >/dev/null 2>&1 || {
    skills_err "skill $name has a malformed trellis-skill.json: expected {\"harnesses\":[...]} with at least one of claude, codex, pi"
    return "$TRELLIS_EX_USAGE"
  }
  for h in claude codex pi; do
    if jq -e --arg h "$h" '.harnesses | index($h) != null' "$cfg" >/dev/null 2>&1; then
      printf '%s\n' "$h"
    fi
  done
}

# Discovery roots (relative to $HOME) for a skill directory, one per line.
skills_skill_roots() {
  local dir="$1" name="$2" harnesses roots
  harnesses="$(skills_harness_set "$dir" "$name")" || return "$?"
  # The set is validated to known harness names above, so word-splitting it
  # into arguments is exact.
  # shellcheck disable=SC2086
  roots="$(skill_roots_for_harnesses $harnesses)" || return "$?"
  printf '%s\n' "$roots"
}

# Every physical harness skill root, one per line, derived from the table —
# never literals. Covers the shared codex+pi root and both solo roots.
skills_all_skill_roots() {
  {
    skill_roots_for_harnesses claude codex pi
    skill_roots_for_harnesses pi
    skill_roots_for_harnesses codex
  } | LC_ALL=C sort -u
}

# Release user skill names: basenames of shipped user-surface link
# destinations that land directly in a harness skill root.
skills_release_names() {
  local manifest roots_json
  manifest="$SKILLS_SCRIPT_DIR/../core-rules/inheritance-manifest.json"
  if [ -L "$manifest" ] || [ ! -f "$manifest" ]; then
    skills_err "shipped inheritance manifest is unavailable: $manifest"
    return "$TRELLIS_EX_STATE"
  fi
  roots_json="$(skills_all_skill_roots | jq -R . | jq -cs 'unique')" || {
    skills_err "could not resolve harness skill roots"
    return "$TRELLIS_EX_STATE"
  }
  jq -r --argjson roots "$roots_json" '
    (.harnesses.user.links // [])
    | .[]
    | .destination as $d
    | select(type == "object"
      and (.destination_home // false)
      and (.destination | type == "string")
      and ((.destination | split("/") | .[0:-1] | join("/")) as $parent
        | $roots | index($parent) != null))
    | ($d | split("/") | .[-1])
  ' "$manifest" || {
    skills_err "shipped inheritance manifest is malformed: $manifest"
    return "$TRELLIS_EX_STATE"
  }
}

# Store skill names, one per line, sorted. Only real directories qualify.
skills_store_names() {
  local store="$1" d names
  names=""
  if [ -d "$store" ]; then
    for d in "$store"/*/; do
      [ -e "$d" ] || [ -L "$d" ] || continue
      d="${d%/}"
      [ -d "$d" ] && [ ! -L "$d" ] || continue
      names="$names${d##*/}"$'\n'
    done
  fi
  [ -z "$names" ] || printf '%s' "$names" | LC_ALL=C sort
}

skills_store_names_json() {
  local names
  names="$(skills_store_names "$1")" || return "$?"
  printf '%s' "$names" | jq -R . | jq -cs '.'
}

skills_is_real_dir() {
  [ -d "$1" ] && [ ! -L "$1" ]
}

# True when both paths name the same canonical directory (symlinks resolved).
skills_same_dir() {
  local a b
  [ -d "$1" ] && [ -d "$2" ] || return 1
  a="$(CDPATH='' cd "$1" && pwd -P)" || return 1
  b="$(CDPATH='' cd "$2" && pwd -P)" || return 1
  [ "$a" = "$b" ]
}

skills_list_contains() {
  local list="$1" item="$2"
  case "$(printf '\n%s\n' "$list")" in
    *"
$item
"*) return 0 ;;
  esac
  return 1
}

skills_dirs_identical() {
  diff -r -x .DS_Store -- "$1" "$2" >/dev/null 2>&1
}

skills_canonical_source() {
  local src="$1" canon
  [ -n "${src:-}" ] || {
    skills_err "import source must be a real directory containing SKILL.md"
    return "$TRELLIS_EX_USAGE"
  }
  if [ -L "$src" ] || { [ ! -e "$src" ] && [ ! -L "$src" ]; } || [ ! -d "$src" ]; then
    skills_err "import source must be a real directory containing SKILL.md: $src"
    return "$TRELLIS_EX_USAGE"
  fi
  canon="$(CDPATH='' cd "$src" && pwd -P)" || {
    skills_err "import source is unavailable: $src"
    return "$TRELLIS_EX_UNAVAILABLE"
  }
  [ -f "$canon/SKILL.md" ] || {
    skills_err "import source must be a real directory containing SKILL.md: $src"
    return "$TRELLIS_EX_USAGE"
  }
  printf '%s\n' "$canon"
}

skills_valid_name() {
  local name="$1"
  case "$name" in
    ""|"."|".."|*"/"*|*$'\n'*) return 1 ;;
  esac
  return 0
}

# True when $3 is a symlink to $4 recorded for skill $2 in state $1.
skills_link_is_owned() {
  local state="$1" skill="$2" link_path="$3" target="$4" current
  [ -L "$link_path" ] || return 1
  current="$(readlink "$link_path")" || return 1
  [ "$current" = "$target" ] || return 1
  printf '%s' "$state" | jq -e --arg skill "$skill" --arg path "$link_path" '
    [.links[] | select(.skill == $skill and .path == $path)] | length > 0' >/dev/null 2>&1
}
# Reconcile one store skill's links. Reads $1 (state JSON), preflights every
# desired path with zero mutation, then removes owned links no longer desired
# and creates missing links (mkdir parents), printing the new state JSON.
# Refuses exit 3 on any existing path that is not a correct owned link —
# never replaced or deleted.
skills_link_one() {
  local state="$1" store="$2" user_home="$3" name="$4"
  local dir target harnesses roots desired rel desired_json stale entry
  local link_path current
  dir="$store/$name"
  target="$dir"
  harnesses="$(skills_harness_set "$dir" "$name")" || return "$?"
  # shellcheck disable=SC2086
  roots="$(skill_roots_for_harnesses $harnesses)" || return "$?"
  desired=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    desired="$desired$user_home/$rel/$name"$'\n'
  done <<< "$roots"
  desired_json="$(printf '%s' "$desired" | jq -R . | jq -cs '.')" || return "$TRELLIS_EX_STATE"
  # Preflight with zero mutation: every desired path is absent or a correct
  # owned link before anything is removed or created, so a refusal below
  # cannot leave the filesystem ahead of the record.
  while IFS= read -r link_path; do
    [ -n "$link_path" ] || continue
    if [ -e "$link_path" ] || [ -L "$link_path" ]; then
      if skills_link_is_owned "$state" "$name" "$link_path" "$target"; then
        continue
      fi
      skills_err "refusing unowned path (never replaced or deleted): $link_path"
      return "$TRELLIS_EX_CONFLICT"
    fi
  done <<< "$desired"
  stale="$(printf '%s' "$state" | jq -r --arg skill "$name" --argjson desired "$desired_json" '
    [.links[] | .path as $p | select(.skill == $skill and ($desired | index($p) | not)) | .path] | .[]')" || return "$TRELLIS_EX_STATE"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    if [ -L "$entry" ]; then
      current="$(readlink "$entry")" || return "$TRELLIS_EX_UNAVAILABLE"
      if [ "$current" = "$target" ]; then
        rm -f -- "$entry" || return "$TRELLIS_EX_UNAVAILABLE"
      fi
    fi
  done <<< "$stale"
  state="$(printf '%s' "$state" | jq -cS --arg skill "$name" --argjson desired "$desired_json" '
    .links |= map(.path as $p | select(.skill != $skill or ($desired | index($p) != null)))')" || return "$TRELLIS_EX_STATE"
  while IFS= read -r link_path; do
    [ -n "$link_path" ] || continue
    if [ -e "$link_path" ] || [ -L "$link_path" ]; then
      # Preflight above already proved this is a correct owned link; the
      # check stays so a hand edit between preflight and create stays safe.
      if skills_link_is_owned "$state" "$name" "$link_path" "$target"; then
        continue
      fi
      skills_err "refusing unowned path (never replaced or deleted): $link_path"
      return "$TRELLIS_EX_CONFLICT"
    fi
    mkdir -p -- "$(dirname "$link_path")" || return "$TRELLIS_EX_UNAVAILABLE"
    ln -s -- "$target" "$link_path" || return "$TRELLIS_EX_UNAVAILABLE"
    state="$(printf '%s' "$state" | jq -cS --arg skill "$name" --arg path "$link_path" --arg target "$target" '
      .links += [{path:$path,target:$target,skill:$skill}]
      | .links |= (unique | sort_by(.path))')" || return "$TRELLIS_EX_STATE"
  done <<< "$desired"
  printf '%s\n' "$state"
}

# Drop record entries for skills no longer in the store, removing the link
# itself only when it is still the exact recorded symlink.
skills_gc_orphans() {
  local state="$1" store="$2" store_json entries entry entry_path entry_target current
  store_json="$(skills_store_names_json "$store")" || return "$?"
  entries="$(printf '%s' "$state" | jq -c --argjson store "$store_json" '
    .links[] | .skill as $s | select($store | index($s) | not)')" || return "$TRELLIS_EX_STATE"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    entry_path="$(printf '%s' "$entry" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
    entry_target="$(printf '%s' "$entry" | jq -r '.target')" || return "$TRELLIS_EX_STATE"
    if [ -L "$entry_path" ]; then
      current="$(readlink "$entry_path")" || return "$TRELLIS_EX_UNAVAILABLE"
      if [ "$current" = "$entry_target" ]; then
        rm -f -- "$entry_path" || return "$TRELLIS_EX_UNAVAILABLE"
      fi
    fi
  done <<< "$entries"
  printf '%s' "$state" | jq -cS --argjson store "$store_json" '
    .links |= map(.skill as $s | select($store | index($s) != null))' || return "$TRELLIS_EX_STATE"
}

skills_cmd_list() {
  local home="$1" user_home="$2" store state names name dir harnesses csv roots rel link_path status current display desired_abs desired_json stale_paths p
  store="$home/skills"
  state="$(skills_state_read "$home")" || return "$?"
  names="$(skills_store_names "$store")" || return "$?"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    skills_harness_set "$store/$name" "$name" >/dev/null || return "$?"
  done <<< "$names"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    dir="$store/$name"
    harnesses="$(skills_harness_set "$dir" "$name")" || return "$?"
    csv="$(printf '%s' "$harnesses" | tr '\n' ',')"
    csv="${csv%,}"
    printf '%s harnesses=%s\n' "$name" "$csv"
    roots="$(skills_skill_roots "$dir" "$name")" || return "$?"
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      link_path="$user_home/$rel/$name"
      if [ ! -e "$link_path" ] && [ ! -L "$link_path" ]; then
        status="missing"
      else
        current=""
        if [ -L "$link_path" ]; then
          current="$(readlink "$link_path")" || return "$TRELLIS_EX_UNAVAILABLE"
        fi
        if [ "$current" = "$dir" ] && printf '%s' "$state" | jq -e --arg skill "$name" --arg path "$link_path" '
            [.links[] | select(.skill == $skill and .path == $path)] | length > 0' >/dev/null 2>&1; then
          status="linked"
        else
          status="unowned"
        fi
      fi
      printf '  %s: %s\n' "$rel/$name" "$status"
    done <<< "$roots"
    desired_abs=""
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      desired_abs="$desired_abs$user_home/$rel/$name"$'\n'
    done <<< "$roots"
    desired_json="$(printf '%s' "$desired_abs" | jq -R . | jq -cs '.')" || return "$TRELLIS_EX_STATE"
    stale_paths="$(printf '%s' "$state" | jq -r --arg skill "$name" --argjson desired "$desired_json" '
      [.links[] | .path as $p | select(.skill == $skill and ($desired | index($p) | not)) | .path] | .[]')" || return "$TRELLIS_EX_STATE"
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      case "$p" in
        "$user_home"/*) display="${p#$user_home/}" ;;
        *) display="$p" ;;
      esac
      printf '  %s: stale\n' "$display"
    done <<< "$stale_paths"
  done <<< "$names"
}

# Every refusal check for one import source; zero mutation. Copies must be
# byte-identical to the source (ignoring .DS_Store) or the import refuses
# naming the path; desired link paths must be absent (an import source is by
# definition unrecorded, so any existing desired path is unowned).
skills_import_check_one() {
  local store="$1" user_home="$2" release_names="$3" all_roots="$4" canon="$5"
  local name rel
  name="${canon##*/}"
  if [ -e "$store/$name" ] || [ -L "$store/$name" ]; then
    skills_err "skill name is already in the store: $name"
    return "$TRELLIS_EX_CONFLICT"
  fi
  if skills_list_contains "$release_names" "$name"; then
    skills_err "skill name collides with a release user skill: $name"
    return "$TRELLIS_EX_CONFLICT"
  fi
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if skills_same_dir "$user_home/$rel/$name" "$canon"; then
      continue
    fi
    if skills_is_real_dir "$user_home/$rel/$name"; then
      if ! skills_dirs_identical "$canon" "$user_home/$rel/$name"; then
        skills_err "harness copy differs from $canon (import refused): $user_home/$rel/$name"
        return "$TRELLIS_EX_CONFLICT"
      fi
    fi
  done <<< "$all_roots"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    if skills_same_dir "$user_home/$rel/$name" "$canon"; then
      continue
    fi
    if skills_is_real_dir "$user_home/$rel/$name"; then
      continue
    fi
    if [ -e "$user_home/$rel/$name" ] || [ -L "$user_home/$rel/$name" ]; then
      skills_err "refusing unowned path (never replaced or deleted): $user_home/$rel/$name"
      return "$TRELLIS_EX_CONFLICT"
    fi
  done <<< "$(skills_skill_roots "$canon" "$name")"
}

skills_cmd_import() {
  local home="$1" user_home="$2"
  shift 2
  [ "$#" -ge 1 ] || {
    skills_err "import requires at least one directory"
    skills_usage >&2
    return "$TRELLIS_EX_USAGE"
  }
  local store="$home/skills" state release_names all_roots copy
  local src canon name pointer_paths pointer_texts texts ppath ptext current
  local canons="" names=""
  for src in "$@"; do
    canon="$(skills_canonical_source "$src")" || return "$?"
    name="${canon##*/}"
    skills_valid_name "$name" || {
      skills_err "import source has an invalid skill name: $src"
      return "$TRELLIS_EX_USAGE"
    }
    if skills_list_contains "$names" "$name"; then
      skills_err "duplicate skill name in import arguments: $name"
      return "$TRELLIS_EX_CONFLICT"
    fi
    canons="$canons$canon"$'\n'
    names="$names$name"$'\n'
  done
  release_names="$(skills_release_names)" || return "$?"
  all_roots="$(skills_all_skill_roots)" || return "$?"
  # Lock first (as attach --user does): checks and moves serialize with
  # attachment mutations, and the per-skill re-check below closes the
  # remaining hand-edit window.
  skills_prepare_home "$home" || return "$?"
  skills_lock_acquire "$home" || return "$?"
  state="$(skills_state_read "$home")" || return "$?"
  # Phase 1: every refusal check for every source before any move, so a
  # refusal leaves the store, the harness roots and the record untouched.
  while IFS= read -r canon; do
    [ -n "$canon" ] || continue
    skills_import_check_one "$store" "$user_home" "$release_names" "$all_roots" "$canon" || return "$?"
  done <<< "$canons"
  # Phase 2, per skill: re-check under lock, move into the store, remove
  # identical copies, link, commit the record. A later skill's refusal names
  # that skill while earlier skills stay fully committed (store, links and
  # record agree), never half-moved.
  while IFS= read -r canon; do
    [ -n "$canon" ] || continue
    name="${canon##*/}"
    skills_import_check_one "$store" "$user_home" "$release_names" "$all_roots" "$canon" || return "$?"
    # Pointers: harness-root symlinks resolving to the source are the same
    # bytes, not foreign paths. Capture path plus readlink text so that only
    # a pointer still pointing at the original source is removed post-move.
    pointer_paths=""
    pointer_texts=""
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      copy="$user_home/$rel/$name"
      if [ -L "$copy" ] && skills_same_dir "$copy" "$canon"; then
        current="$(readlink "$copy")" || return "$TRELLIS_EX_UNAVAILABLE"
        pointer_paths="$pointer_paths$copy"$'\n'
        pointer_texts="$pointer_texts$current"$'\n'
      fi
    done <<< "$all_roots"
    mv -- "$canon" "$store/$name" || return "$TRELLIS_EX_UNAVAILABLE"
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      copy="$user_home/$rel/$name"
      if skills_same_dir "$copy" "$store/$name"; then
        continue
      fi
      if skills_is_real_dir "$copy"; then
        if ! skills_dirs_identical "$store/$name" "$copy"; then
          skills_err "harness copy changed during import (store already holds $name; reconcile by hand, then run trellis skills link): $copy"
          return "$TRELLIS_EX_CONFLICT"
        fi
        rm -rf -- "$copy" || return "$TRELLIS_EX_UNAVAILABLE"
      fi
    done <<< "$all_roots"
    # Replace untouched pointers with owned links: remove only a symlink
    # whose text is unchanged since before the move. A retargeted or
    # replaced path is left for link reconciliation to refuse, never deleted.
    texts="$pointer_texts"
    while IFS= read -r ppath; do
      [ -n "$ppath" ] || continue
      ptext="${texts%%$'\n'*}"
      case "$texts" in
        *$'\n'*) texts="${texts#*$'\n'}" ;;
        *) texts="" ;;
      esac
      [ -L "$ppath" ] || continue
      current="$(readlink "$ppath")" || return "$TRELLIS_EX_UNAVAILABLE"
      [ "$current" = "$ptext" ] || continue
      rm -f -- "$ppath" || return "$TRELLIS_EX_UNAVAILABLE"
    done <<< "$pointer_paths"
    state="$(skills_link_one "$state" "$store" "$user_home" "$name")" || return "$?"
    skills_state_write "$home" "$state" || return "$?"
    printf 'imported skill: %s\n' "$name"
  done <<< "$canons"
  skills_lock_release || return "$?"
}

skills_cmd_link() {
  local home="$1" user_home="$2"
  shift 2
  local store="$home/skills" state names name full=0
  if [ "$#" -eq 0 ]; then
    full=1
    names="$(skills_store_names "$store")" || return "$?"
  else
    names=""
    for name in "$@"; do
      skills_valid_name "$name" || {
        skills_err "invalid skill name: $name"
        return "$TRELLIS_EX_USAGE"
      }
      if [ -L "$store/$name" ] || [ ! -d "$store/$name" ]; then
        skills_err "no such skill in the store: $name"
        return "$TRELLIS_EX_USAGE"
      fi
      names="$names$name"$'\n'
    done
  fi
  skills_prepare_home "$home" || return "$?"
  skills_lock_acquire "$home" || return "$?"
  state="$(skills_state_read "$home")" || return "$?"
  # Each skill commits its record before the next is reconciled, so a later
  # skill's refusal cannot leave an earlier skill's links unrecorded.
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    state="$(skills_link_one "$state" "$store" "$user_home" "$name")" || return "$?"
    skills_state_write "$home" "$state" || return "$?"
    printf 'linked skill: %s\n' "$name"
  done <<< "$names"
  if [ "$full" -eq 1 ]; then
    state="$(skills_gc_orphans "$state" "$store" "$user_home")" || return "$?"
    skills_state_write "$home" "$state" || return "$?"
  fi
  skills_lock_release || return "$?"
}

skills_cmd_unlink() {
  local home="$1" user_home="$2"
  shift 2
  [ "$#" -eq 1 ] || {
    skills_err "unlink requires exactly one skill name"
    skills_usage >&2
    return "$TRELLIS_EX_USAGE"
  }
  local name="$1" store="$home/skills" state entries entry entry_path entry_target current
  skills_valid_name "$name" || {
    skills_err "invalid skill name: $name"
    return "$TRELLIS_EX_USAGE"
  }
  skills_prepare_home "$home" || return "$?"
  skills_lock_acquire "$home" || return "$?"
  state="$(skills_state_read "$home")" || return "$?"
  if { [ -d "$store/$name" ] && [ ! -L "$store/$name" ]; } || printf '%s' "$state" | jq -e --arg skill "$name" '
      [.links[] | select(.skill == $skill)] | length > 0' >/dev/null 2>&1; then
    :
  else
    skills_err "no such skill in the store: $name"
    return "$TRELLIS_EX_USAGE"
  fi
  entries="$(printf '%s' "$state" | jq -c --arg skill "$name" '
    .links[] | select(.skill == $skill)')" || return "$TRELLIS_EX_STATE"
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    entry_path="$(printf '%s' "$entry" | jq -r '.path')" || return "$TRELLIS_EX_STATE"
    entry_target="$(printf '%s' "$entry" | jq -r '.target')" || return "$TRELLIS_EX_STATE"
    if [ -L "$entry_path" ]; then
      current="$(readlink "$entry_path")" || return "$TRELLIS_EX_UNAVAILABLE"
      if [ "$current" = "$entry_target" ]; then
        rm -f -- "$entry_path" || return "$TRELLIS_EX_UNAVAILABLE"
      fi
    fi
  done <<< "$entries"
  state="$(printf '%s' "$state" | jq -cS --arg skill "$name" '
    .links |= map(select(.skill != $skill))')" || return "$TRELLIS_EX_STATE"
  skills_state_write "$home" "$state" || return "$?"
  skills_lock_release || return "$?"
  printf 'unlinked skill: %s\n' "$name"
}

skills_main() {
  local cmd=""
  trellis_home_require_jq || exit "$?"
  if [ "$#" -ge 1 ]; then
    cmd="$1"
    shift
  fi
  case "$cmd" in
    list|import|link|unlink) ;;
    ""|-h|--help|help)
      skills_usage
      exit 0
      ;;
    *)
      skills_usage >&2
      exit "$TRELLIS_EX_USAGE"
      ;;
  esac
  local home user_home
  home="$(skills_resolve_home)" || exit "$?"
  user_home="$(_attachment_user_runtime_home)" || exit "$?"
  case "$cmd" in
    list) skills_cmd_list "$home" "$user_home" ;;
    import) skills_cmd_import "$home" "$user_home" ${1+"$@"} ;;
    link) skills_cmd_link "$home" "$user_home" ${1+"$@"} ;;
    unlink) skills_cmd_unlink "$home" "$user_home" ${1+"$@"} ;;
  esac
}

skills_main ${1+"$@"}
