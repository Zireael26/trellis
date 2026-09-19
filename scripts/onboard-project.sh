#!/usr/bin/env bash
# Onboarding writes one inert portable manifest, then delegates every local
# effect to the attachment transaction.
#
# Tracked footprint: exactly `<project>/.trellis.json`, created only when
# absent. Everything else — native Claude Code and Codex surfaces, the
# managed `.git/info/exclude` block, local settings, and the clone-local hook
# dispatcher — is machine-local state owned by `scripts/attach-project.sh` and
# recorded under `TRELLIS_HOME`. A contributor who never attaches sees only the
# inert manifest.
#
# The historical direct-link writer (`--legacy`, `--legacy-relative`, and its
# `--infra-entry` shared-infrastructure registration) shipped for exactly one
# compatibility release and was REMOVED at v1.0.0-rc.25. Nothing here creates an
# absolute link into a mutable source checkout any more. A checkout still on the
# legacy layout is migrated, not re-seeded:
#
#   trellis migrate --prepare <project-path>   # reviewed tracked cleanup
#   trellis attach --fleet NAME <project-path> # local surfaces from a release
#
# Then runs the initial Mode 1 security-gate baseline (override:
# TRELLIS_SKIP_SECURITY_BASELINE=1).
#
# Usage:
#   onboard-project.sh --fleet NAME [portable options] <project-path>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

portable_usage() {
  cat <<'EOF'
usage: onboard-project.sh --fleet NAME [--home PATH] [--release VERSION]
       [--harness claude|codex|pi]... [--project-id ID] <project-path>
EOF
}

# Portable onboarding must not silently layer attachment state over the
# compatibility-release layout. Keep this inventory aligned with the legacy
# direct-link writer: any occupied destination is ambiguous until migration
# classifies ownership, including divergent user content in a legacy slot.
portable_legacy_surface() {
  local root="$1" path
  local -a legacy_paths=(
    ".trellis.config.json"
    ".claude/rules/trellis.md"
    ".claude/rules/se-core.md"
    ".claude/skills/process-gate"
    ".claude/skills/security-gate"
    ".claude/skills/aeo-gate"
    ".claude/skills/clarify"
    ".claude/skills/spec"
    ".claude/skills/plan"
    ".claude/skills/tasks"
    ".claude/skills/analyze"
    ".claude/skills/execute"
    ".claude/skills/brainstorming"
    ".claude/skills/orchestrate"
    ".claude/skills/debrief"
    ".claude/skills/writing"
    ".claude/commands/primer.md"
    ".claude/commands/primer-refresh.md"
    ".claude/commands/primer-check.md"
    ".claude/commands/explore.md"
    ".claude/commands/autonomy.md"
    ".claude/commands/surgical.md"
    ".agents/rules/trellis.md"
    ".agents/rules/se-core.md"
    ".agents/skills/process-gate"
    ".agents/skills/security-gate"
    ".agents/skills/aeo-gate"
    ".agents/skills/clarify"
    ".agents/skills/spec"
    ".agents/skills/plan"
    ".agents/skills/tasks"
    ".agents/skills/analyze"
    ".agents/skills/execute"
    ".agents/skills/brainstorming"
    ".agents/skills/orchestrate"
    ".agents/skills/debrief"
    ".agents/skills/writing"
    ".agents/commands/primer.md"
    ".agents/commands/primer-refresh.md"
    ".agents/commands/primer-check.md"
    ".agents/commands/explore.md"
    ".agents/commands/autonomy.md"
    ".agents/commands/surgical.md"
    "AGENTS.md"
  )

  for path in "${legacy_paths[@]}"; do
    if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  if [ -e "$root/CLAUDE.md" ] || [ -L "$root/CLAUDE.md" ]; then
    if [ ! -f "$root/CLAUDE.md" ] || [ -L "$root/CLAUDE.md" ] || [ ! -r "$root/CLAUDE.md" ] ||
      LC_ALL=C grep -Eq '^@/.*/core-rules/CLAUDE\.md$' "$root/CLAUDE.md"; then
      printf '%s\n' "CLAUDE.md"
      return 0
    fi
  fi
  for path in "$root"/.claude/rules/preset-*.md "$root"/.agents/rules/preset-*.md; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    printf '%s\n' "${path#"$root"/}"
    return 0
  done
  if [ -e "$root/.gitignore" ] || [ -L "$root/.gitignore" ]; then
    if [ ! -f "$root/.gitignore" ] || [ -L "$root/.gitignore" ] || [ ! -r "$root/.gitignore" ] ||
      LC_ALL=C grep -Eq '^# --- Trellis inheritance symlinks' "$root/.gitignore"; then
      printf '%s\n' ".gitignore"
      return 0
    fi
  fi
  return 1
}

portable_definite_legacy_surface() {
  local root="$1" path
  if [ -e "$root/.trellis.config.json" ] || [ -L "$root/.trellis.config.json" ]; then
    printf '%s\n' '.trellis.config.json'
    return 0
  fi
  for path in .claude/rules/se-core.md .agents/rules/se-core.md; do
    if [ -e "$root/$path" ] || [ -L "$root/$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  for path in "$root"/.claude/rules/preset-*.md "$root"/.agents/rules/preset-*.md; do
    [ -e "$path" ] || [ -L "$path" ] || continue
    printf '%s\n' "${path#"$root"/}"
    return 0
  done
  if [ -f "$root/CLAUDE.md" ] && [ ! -L "$root/CLAUDE.md" ] &&
    LC_ALL=C grep -Eq '^@/.*/core-rules/CLAUDE\.md$' "$root/CLAUDE.md"; then
    printf '%s\n' 'CLAUDE.md'
    return 0
  fi
  if [ -f "$root/.gitignore" ] && [ ! -L "$root/.gitignore" ] &&
    LC_ALL=C grep -Eq '^# --- Trellis inheritance symlinks' "$root/.gitignore"; then
    printf '%s\n' '.gitignore'
    return 0
  fi
  return 1
}

portable_manifest_temp_identity() {
  local path="$1"
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  case "$(uname -s)" in
    Darwin|*BSD) stat -f '%d:%i' "$path" ;;
    *) stat -c '%d:%i' "$path" ;;
  esac
}

portable_manifest_temp_link_count() {
  case "$(uname -s)" in
    Darwin|*BSD) stat -f '%l' "$1" ;;
    *) stat -c '%h' "$1" ;;
  esac
}

portable_manifest_temp_matches() {
  local path="$1" expected="$2" actual links
  actual="$(portable_manifest_temp_identity "$path")" || return 1
  links="$(portable_manifest_temp_link_count "$path")" || return 1
  [ "$actual" = "$expected" ] && [ "$links" = "1" ]
}

portable_manifest_temp_cleanup() {
  local path="${1:-}" expected="${2:-}" actual
  [ -n "$path" ] && [ -n "$expected" ] || return 0
  actual="$(portable_manifest_temp_identity "$path")" || return 0
  [ "$actual" = "$expected" ] || return 0
  rm -f -- "$path"
}

portable_onboard() (
  local home="" fleet="" release="" project_id="" project_arg="" arg root top
  local manifest existing_id tmp tmp_identity legacy_path rc
  local -a harnesses=() attach_args=()

  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --home)
        [ "$#" -ge 2 ] || { printf 'onboard-project: --home requires PATH\n' >&2; portable_usage >&2; return 2; }
        home="$2"; shift 2 ;;
      --fleet)
        [ "$#" -ge 2 ] || { printf 'onboard-project: --fleet requires NAME\n' >&2; portable_usage >&2; return 2; }
        fleet="$2"; shift 2 ;;
      --release)
        [ "$#" -ge 2 ] || { printf 'onboard-project: --release requires VERSION\n' >&2; portable_usage >&2; return 2; }
        release="$2"; shift 2 ;;
      --harness)
        [ "$#" -ge 2 ] || { printf 'onboard-project: --harness requires NAME\n' >&2; portable_usage >&2; return 2; }
        case "$2" in claude|codex|pi) ;; *) printf 'onboard-project: unsupported harness: %s\n' "$2" >&2; return 2 ;; esac
        harnesses+=("$2"); shift 2 ;;
      --project-id)
        [ "$#" -ge 2 ] || { printf 'onboard-project: --project-id requires ID\n' >&2; portable_usage >&2; return 2; }
        project_id="$2"; shift 2 ;;
      -h|--help)
        portable_usage
        return 0 ;;
      --)
        shift
        [ "$#" -eq 1 ] && [ -z "$project_arg" ] || { printf 'onboard-project: -- must precede one project path\n' >&2; portable_usage >&2; return 2; }
        project_arg="$1"; shift
        break ;;
      -*)
        printf 'onboard-project: unknown option: %s\n' "$arg" >&2
        portable_usage >&2
        return 2 ;;
      *)
        [ -z "$project_arg" ] || { printf 'onboard-project: unexpected argument: %s\n' "$arg" >&2; portable_usage >&2; return 2; }
        project_arg="$arg"; shift ;;
    esac
  done
  [ "$#" -eq 0 ] || { printf 'onboard-project: unexpected argument: %s\n' "$1" >&2; portable_usage >&2; return 2; }
  [ -n "$fleet" ] || { printf 'onboard-project: --fleet is required for portable onboarding\n' >&2; portable_usage >&2; return 2; }
  [ -n "$project_arg" ] || { portable_usage >&2; return 2; }

  # shellcheck source=lib/local-registry.sh
  . "$SCRIPT_DIR/lib/local-registry.sh"
  trellis_home_require_fleet_name "$fleet" || return "$?"
  root="$(local_registry_real_directory 'project root' "$project_arg")" || return "$?"
  top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'onboard-project: not a git worktree: %s\n' "$root" >&2
    return "$TRELLIS_EX_STATE"
  }
  top="$(local_registry_real_directory 'Git worktree top level' "$top")" || return "$?"
  [ "$root" = "$top" ] || {
    printf 'onboard-project: project path must equal the Git worktree root: %s\n' "$root" >&2
    return "$TRELLIS_EX_STATE"
  }
  manifest="$root/.trellis.json"
  if [ -f "$manifest" ] && [ ! -L "$manifest" ]; then
    legacy_path="$(portable_definite_legacy_surface "$root")" || legacy_path=""
  else
    legacy_path="$(portable_legacy_surface "$root")" || legacy_path=""
  fi
  if [ -n "$legacy_path" ]; then
    printf 'onboard-project: legacy or mixed Trellis layout detected (%s); run `trellis migrate --prepare %s` (the `--legacy` writer was removed in v1.0.0-rc.25)\n' \
      "$legacy_path" "$root" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ -L "$manifest" ] || { [ -e "$manifest" ] && [ ! -f "$manifest" ]; }; then
    printf 'onboard-project: project manifest collides with non-regular state: %s\n' "$manifest" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ -f "$manifest" ]; then
    existing_id="$(local_registry_manifest_project_id "$manifest")" || return "$TRELLIS_EX_CONFLICT"
    if [ -n "$project_id" ] && [ "$project_id" != "$existing_id" ]; then
      printf 'onboard-project: existing project ID %s conflicts with requested ID %s\n' "$existing_id" "$project_id" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
  else
    [ -n "$project_id" ] || project_id="$(basename "$root")"
    local_registry_require_project_id "$project_id" || return "$?"
    trellis_home_require_jq || return "$?"
    [ -d "$root" ] && [ ! -L "$root" ] || {
      printf 'onboard-project: refusing unsafe manifest parent: %s\n' "$root" >&2
      return "$TRELLIS_EX_CONFLICT"
    }
    tmp="$(umask 077; mktemp "$root/.trellis.json.tmp.XXXXXX")" || {
      printf 'onboard-project: could not create manifest temporary file\n' >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    }
    if [ "$(dirname "$tmp")" != "$root" ]; then
      printf 'onboard-project: manifest temporary file escaped the project root\n' >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    case "$tmp" in
      "$root"/.trellis.json.tmp.*) ;;
      *)
        printf 'onboard-project: invalid manifest temporary file name\n' >&2
        return "$TRELLIS_EX_CONFLICT"
        ;;
    esac
    tmp_identity="$(portable_manifest_temp_identity "$tmp")" || {
      printf 'onboard-project: refusing non-regular manifest temporary file\n' >&2
      return "$TRELLIS_EX_CONFLICT"
    }
    portable_manifest_temp_matches "$tmp" "$tmp_identity" || {
      printf 'onboard-project: refusing shared manifest temporary file\n' >&2
      return "$TRELLIS_EX_CONFLICT"
    }
    trap 'portable_manifest_temp_cleanup "${tmp:-}" "${tmp_identity:-}"' EXIT HUP INT TERM
    if ! exec 9>>"$tmp"; then
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    if ! jq -n -S --arg project_id "$project_id" \
      '{"$schema":"https://trellis.local/schemas/trellis.project.schema.json",schema_version:1,project_id:$project_id}' >&9; then
      exec 9>&-
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    exec 9>&-
    portable_manifest_temp_matches "$tmp" "$tmp_identity" || {
      printf 'onboard-project: manifest temporary file changed during creation\n' >&2
      return "$TRELLIS_EX_CONFLICT"
    }
    chmod 644 "$tmp" || return "$TRELLIS_EX_UNAVAILABLE"
    portable_manifest_temp_matches "$tmp" "$tmp_identity" || {
      printf 'onboard-project: manifest temporary file changed during creation\n' >&2
      return "$TRELLIS_EX_CONFLICT"
    }
    if ! ln "$tmp" "$manifest" 2>/dev/null; then
      portable_manifest_temp_cleanup "$tmp" "$tmp_identity"
      tmp=""
      tmp_identity=""
      if [ -f "$manifest" ] && [ ! -L "$manifest" ]; then
        existing_id="$(local_registry_manifest_project_id "$manifest")" || return "$TRELLIS_EX_CONFLICT"
        [ "$existing_id" = "$project_id" ] || return "$TRELLIS_EX_CONFLICT"
      else
        printf 'onboard-project: project manifest appeared during creation: %s\n' "$manifest" >&2
        return "$TRELLIS_EX_CONFLICT"
      fi
    else
      portable_manifest_temp_identity "$manifest" | grep -Fqx -- "$tmp_identity" || {
        printf 'onboard-project: manifest changed during publication: %s\n' "$manifest" >&2
        return "$TRELLIS_EX_CONFLICT"
      }
      portable_manifest_temp_cleanup "$tmp" "$tmp_identity"
      tmp=""
      tmp_identity=""
      printf 'created tracked manifest: %s\n' "$manifest"
    fi
    trap - EXIT HUP INT TERM
  fi

  [ -n "$home" ] && attach_args+=("--home" "$home")
  attach_args+=("--fleet" "$fleet")
  [ -n "$release" ] && attach_args+=("--release" "$release")
  for arg in "${harnesses[@]+"${harnesses[@]}"}"; do
    attach_args+=("--harness" "$arg")
  done
  "$SCRIPT_DIR/attach-project.sh" attach "${attach_args[@]}" "$root"
  rc=$?
  return "$rc"
)

case "${1:-}" in
  --legacy|--compatibility|--legacy-relative|--infra-entry|--infra-entry=*)
    printf 'onboard-project: legacy direct-link onboarding was removed in v1.0.0-rc.25 (%s)\n' "$1" >&2
    printf 'onboard-project: migrate the checkout, then attach it:\n' >&2
    printf 'onboard-project:   trellis migrate --prepare <project-path>\n' >&2
    printf 'onboard-project:   trellis attach --fleet NAME <project-path>\n' >&2
    exit 2
    ;;
  *)
    portable_onboard "$@"
    exit $?
    ;;
esac
