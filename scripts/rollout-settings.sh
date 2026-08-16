#!/usr/bin/env bash
# Rollout: reconcile each locally attached project's release-backed Claude
# settings surface. Idempotent; safe to re-run.
#
# The attachment owns `.claude/settings.local.json`, rendering its explicit
# local settings contract from the project's exact verified immutable release.
# This rollout never changes project-owned `.claude/settings.json` or any other
# project settings.
#
# Usage:
#   rollout-settings.sh                 # interactive, all local registry rows
#   rollout-settings.sh --dry-run       # show plan only
#   rollout-settings.sh --yes           # non-interactive
#   rollout-settings.sh <project-name>  # project ID or fleet/project ID

set -euo pipefail
# Registry identity and attachment relinks must not inherit caller-controlled Git state.
for git_environment in "${!GIT_@}"; do
  unset "$git_environment"
done
unset git_environment
# Rollouts always source their libraries from SCRIPT_DIR. An inherited
# preloaded-libs marker would half-initialize them here and would also make
# the attach-project.sh child a no-op that exits 0 without relinking.
unset TRELLIS_LIBS_PRELOADED
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=core.fsmonitor
export GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=core.hooksPath
export GIT_CONFIG_VALUE_1=/dev/null


SCRIPT_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd -P)"

for arg in "$@"; do
  case "$arg" in
    --help|-h) sed -n '2,/^$/p' "$0" | sed 's/^# \?//'; exit 0 ;;
  esac
done

# shellcheck source=lib/trellis-home.sh
. "$SCRIPT_DIR/lib/trellis-home.sh"
# shellcheck source=lib/local-registry.sh
. "$SCRIPT_DIR/lib/local-registry.sh"
# shellcheck source=lib/release-store.sh
. "$SCRIPT_DIR/lib/release-store.sh"
# shellcheck source=lib/surface-plan.sh
. "$SCRIPT_DIR/lib/surface-plan.sh"

safe_display_root() {
  if trellis_home_has_unsafe_chars "${1:-}"; then
    printf '<unsafe local root>'
  else
    printf '%s' "${1:-}"
  fi
}

require_safe_display_path() {
  if trellis_home_has_unsafe_chars "${1:-}"; then
    printf 'error: local registry root has terminal control characters\n' >&2
    return "$TRELLIS_EX_STATE"
  fi
}

if trellis_home_require_jq; then
  :
else
  rc=$?
  exit "$rc"
fi

DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y) ASSUME_YES=true ;;
    --help|-h) ;;
    -*) echo "unknown option: $arg" >&2; exit "$TRELLIS_EX_USAGE" ;;
    *) ONLY_PROJECT="$arg" ;;
  esac
done

if TRELLIS_HOME="$(trellis_home_resolve "${TRELLIS_HOME:-}")"; then
  :
else
  rc=$?
  exit "$rc"
fi
export TRELLIS_HOME

if REGISTRY_JSON="$(local_registry_list_json "$TRELLIS_HOME")"; then
  :
else
  rc=$?
  exit "$rc"
fi

TARGET_ROWS=()

# A registry state error is a property of the REGISTRY, not of the selection.
# Selecting one project narrows what this rollout ACTS on; it must never narrow
# what counts toward the exit class. `registry_state_floor` reports the drifted
# rows this run will not visit — from the FULL listing — and floors the given
# class with theirs, so neither a selection refusal nor an operator abort can
# report below a registry state error already proven.
AGGREGATE_FLOOR=0

registry_state_floor() {
  local class="${1:-0}" selected="${2:-}" rc=0
  local_registry_report_unselected_state_errors "$REGISTRY_JSON" "$selected" || rc="$?"
  local_registry_max_class "$class" "$rc"
}

selected_rows_json() {
  [ "${#TARGET_ROWS[@]}" -gt 0 ] || return 0
  printf '%s\n' "${TARGET_ROWS[@]}"
}

append_target_rows() {
  local rows="$1" row

  while IFS= read -r row; do
    if [ -n "$row" ]; then
      TARGET_ROWS+=("$row")
    fi
  done <<EOF
$rows
EOF
  return 0
}

select_target_rows() {
  local rows project_keys project_key rc
  local -a matching_keys=()

  TARGET_ROWS=()
  if [ -z "$ONLY_PROJECT" ]; then
    if rows="$(printf '%s\n' "$REGISTRY_JSON" | jq -c '.entries[]')"; then
      :
    else
      rc=$?
      printf 'could not select strict local registry rows\n' >&2
      return "$rc"
    fi
    append_target_rows "$rows"
    return 0
  fi

  case "$ONLY_PROJECT" in
    */*)
      if rows="$(printf '%s\n' "$REGISTRY_JSON" | jq -c --arg project_key "$ONLY_PROJECT" \
        '.entries[] | select(.project_key == $project_key)')"; then
        :
      else
        rc=$?
        printf 'could not select strict local registry row: %s\n' "$ONLY_PROJECT" >&2
        return "$rc"
      fi
      append_target_rows "$rows"
      if [ "${#TARGET_ROWS[@]}" -eq 0 ]; then
        printf 'project not in local registry: %s\n' "$ONLY_PROJECT" >&2
        return "$TRELLIS_EX_UNAVAILABLE"
      fi
      return 0
      ;;
    *)
      if project_keys="$(printf '%s\n' "$REGISTRY_JSON" | jq -r --arg project_id "$ONLY_PROJECT" \
        '[.entries[] | select(.project_id == $project_id) | .project_key] | unique[]')"; then
        :
      else
        rc=$?
        printf 'could not select strict local registry project IDs\n' >&2
        return "$rc"
      fi
      while IFS= read -r project_key; do
        if [ -n "$project_key" ]; then
          matching_keys+=("$project_key")
        fi
      done <<EOF
$project_keys
EOF
      case "${#matching_keys[@]}" in
        0)
          printf 'project not in local registry: %s\n' "$ONLY_PROJECT" >&2
          return "$TRELLIS_EX_UNAVAILABLE"
          ;;
        1)
          if rows="$(printf '%s\n' "$REGISTRY_JSON" | jq -c --arg project_key "${matching_keys[0]}" \
            '.entries[] | select(.project_key == $project_key)')"; then
            :
          else
            rc=$?
            printf 'could not select strict local registry row: %s\n' "${matching_keys[0]}" >&2
            return "$rc"
          fi
          append_target_rows "$rows"
          return 0
          ;;
        *)
          printf 'ambiguous project ID in local registry: %s; use fleet/project ID\n' "$ONLY_PROJECT" >&2
          return "$TRELLIS_EX_CONFLICT"
          ;;
      esac
      ;;
  esac
}

print_targets() {
  local row project_key root rc

  printf 'Targets:\n'
  if [ "${#TARGET_ROWS[@]}" -eq 0 ]; then
    printf '  (none)\n'
    return 0
  fi
  for row in "${TARGET_ROWS[@]}"; do
    if project_key="$(printf '%s\n' "$row" | jq -r '.project_key')"; then
      :
    else
      rc=$?
      return "$rc"
    fi
    if root="$(printf '%s\n' "$row" | jq -r '.root // "<no local root>"')"; then
      :
    else
      rc=$?
      return "$rc"
    fi
    printf '  %s → %s\n' "$project_key" "$(safe_display_root "$root")"
  done
  return 0
}

row_identity_matches() {
  local row="$1" resolved="$2" project_key root checkout_id worktree_id rc

  if project_key="$(printf '%s\n' "$row" | jq -r '.project_key')"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  if root="$(printf '%s\n' "$row" | jq -r '.root // empty')"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  if checkout_id="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  if worktree_id="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  if printf '%s\n' "$resolved" | jq -e \
    --arg project_key "$project_key" \
    --arg root "$root" \
    --arg checkout_id "$checkout_id" \
    --arg worktree_id "$worktree_id" '
      .project_key == $project_key
      and .root == $root
      and .checkout_id == $checkout_id
      and .worktree_id == $worktree_id
    ' >/dev/null; then
    return 0
  else
    rc=$?
    return "$TRELLIS_EX_STATE"
  fi
}

row_has_harness() {
  local row="$1" harness="$2" rc

  if printf '%s\n' "$row" | jq -e --arg harness "$harness" \
    '(.harnesses | type == "array") and (.harnesses | index($harness) != null)' >/dev/null; then
    return 0
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      return 1
    fi
    return "$TRELLIS_EX_STATE"
  fi
}

settings_plan_is_exact() {
  local plan="$1" rc

  if printf '%s\n' "$plan" | jq -e '
    [.artifacts[]
      | select(
          .harness == "claude"
          and .kind == "render"
          and .source == "core-rules/templates/claude-settings.local.json"
          and .destination == ".claude/settings.local.json"
          and .merge == "explicit-json"
          and .mode == "0600"
        )]
    | length == 1
  ' >/dev/null; then
    return 0
  else
    rc=$?
    return "$TRELLIS_EX_STATE"
  fi
}

reconcile_row() {
  local row="$1" fleet project_key project_id kind availability status excluded root release attachment_id checkout_id worktree_id
  local resolved release_dir payload plan ans rc harnesses_json expected_harnesses_json

  # Read each field on its own. A tab-separated row escapes backslashes, so a
  # legal backslash-containing root would never reconcile against the registry.
  # Required fields use `jq -er` so a missing one fails instead of yielding the
  # literal string "null"; nullable fields keep an explicit empty-string default.
  if fleet="$(printf '%s\n' "$row" | jq -er '.fleet' 2>/dev/null)" &&
     project_key="$(printf '%s\n' "$row" | jq -er '.project_key' 2>/dev/null)" &&
     kind="$(printf '%s\n' "$row" | jq -er '.kind' 2>/dev/null)" &&
     availability="$(printf '%s\n' "$row" | jq -er '.availability' 2>/dev/null)" &&
     status="$(printf '%s\n' "$row" | jq -er '.status' 2>/dev/null)" &&
     excluded="$(printf '%s\n' "$row" | jq -er '((.excluded // false) | tostring)' 2>/dev/null)" &&
     root="$(printf '%s\n' "$row" | jq -r '(.root // "")' 2>/dev/null)" &&
     release="$(printf '%s\n' "$row" | jq -r '(.release // "")' 2>/dev/null)" &&
     attachment_id="$(printf '%s\n' "$row" | jq -r '(.attachment_id // "")' 2>/dev/null)"; then
    :
  else
    printf 'ERROR: could not parse strict local registry row\n' >&2
    return "$TRELLIS_EX_STATE"
  fi
  if project_id="$(printf '%s\n' "$row" | jq -er '.project_id' 2>/dev/null)"; then
    :
  else
    printf 'ERROR: could not parse strict local registry row\n' >&2
    return "$TRELLIS_EX_STATE"
  fi
  if checkout_id="$(printf '%s\n' "$row" | jq -r '(.checkout_id // "")' 2>/dev/null)"; then
    :
  else
    printf 'ERROR: could not parse strict local registry row\n' >&2
    return "$TRELLIS_EX_STATE"
  fi
  if worktree_id="$(printf '%s\n' "$row" | jq -r '(.worktree_id // "")' 2>/dev/null)"; then
    :
  else
    printf 'ERROR: could not parse strict local registry row\n' >&2
    return "$TRELLIS_EX_STATE"
  fi
  if harnesses_json="$(printf '%s\n' "$row" | jq -c '.harnesses // []')"; then
    :
  else
    return "$TRELLIS_EX_STATE"
  fi
  if expected_harnesses_json="$(local_registry_normalize_harnesses "$harnesses_json")"; then
    :
  else
    return "$TRELLIS_EX_STATE"
  fi


  if [ "$availability" = "identity_error" ]; then
    printf 'error (registry row failed identity validation): %s → %s\n' \
      "$project_key" "$(safe_display_root "${root:-<no local root>}")" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ "$availability" != "available" ]; then
    printf 'skip (unavailable): %s → %s\n' "$project_key" "$(safe_display_root "${root:-<no local root>}")"
    return 0
  fi
  if [ "$excluded" = "true" ]; then
    printf 'skip (excluded): %s\n' "$project_key"
    return 0
  fi
  if [ "$kind" != "worktree" ]; then
    printf 'skip (ineligible registry row: %s): %s\n' "$kind" "$project_key"
    return 0
  fi
  if [ "$status" != "active" ]; then
    printf 'skip (ineligible status: %s): %s\n' "$status" "$project_key"
    return 0
  fi
  if [ -z "$root" ]; then
    printf 'ERROR: active worktree row has no root: %s\n' "$project_key" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -z "$attachment_id" ]; then
    printf 'skip (ineligible row without attachment ownership): %s → %s\n' "$project_key" "$(safe_display_root "$root")"
    return 0
  fi
  if row_has_harness "$row" "claude"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      printf 'skip (ineligible row without Claude harness): %s → %s\n' "$project_key" "$(safe_display_root "$root")"
      return 0
    fi
    printf 'ERROR: invalid harness data for %s\n' "$project_key" >&2
    return "$rc"
  fi
  require_safe_display_path "$root" || return "$?"
  if [ -z "$release" ]; then
    printf 'ERROR: active attached row has no recorded release: %s → %s\n' "$project_key" "$root" >&2
    return "$TRELLIS_EX_STATE"
  fi

  if resolved="$(local_registry_resolve_root "$TRELLIS_HOME" "$root")"; then
    :
  else
    rc=$?
    printf 'ERROR: active row root no longer resolves through the strict local registry: %s → %s\n' \
      "$project_key" "$root" >&2
    return "$rc"
  fi
  if row_identity_matches "$row" "$resolved"; then
    :
  else
    rc=$?
    printf 'ERROR: active row identity differs from the strict local registry: %s → %s\n' \
      "$project_key" "$root" >&2
    return "$rc"
  fi

  if release_dir="$(release_store_locate "$release")"; then
    :
  else
    rc=$?
    printf 'ERROR: recorded release is unavailable or invalid: %s → %s (%s)\n' \
      "$project_key" "$root" "$release" >&2
    return "$rc"
  fi
  payload="$release_dir/payload"
  if plan="$(surface_plan_emit "$payload" "claude")"; then
    :
  else
    rc=$?
    printf 'ERROR: release surface plan is invalid: %s → %s (%s)\n' \
      "$project_key" "$root" "$release" >&2
    return "$rc"
  fi
  if settings_plan_is_exact "$plan"; then
    :
  else
    rc=$?
    printf 'ERROR: release lacks the exact Claude local-settings surface: %s → %s (%s)\n' \
      "$project_key" "$root" "$release" >&2
    return "$rc"
  fi

  printf '== %s ==\n' "$project_key"
  if $DRY_RUN; then
    printf '  + would reconcile attachment-managed Claude local settings from release %s at %s\n' \
      "$release" "$root"
    return 0
  fi
  if $ASSUME_YES; then
    :
  else
    ans=""
    printf '  reconcile attachment-managed local settings? [y/N] '
    if read -r ans; then
      :
    else
      rc=$?
      printf 'ERROR: could not read reconciliation confirmation for %s\n' "$project_key" >&2
      return "$rc"
    fi
    case "$ans" in
      y|Y|yes|YES) ;;
      *) printf '  skipped by user\n'; return 0 ;;
    esac
  fi

  if "$SCRIPT_DIR/attach-project.sh" relink \
    --home "$TRELLIS_HOME" \
    --fleet "$fleet" \
    --expected-fleet "$fleet" \
    --expected-project-id "$project_id" \
    --expected-root "$root" \
    --expected-checkout-id "$checkout_id" \
    --expected-worktree-id "$worktree_id" \
    --expected-attachment-id "$attachment_id" \
    --expected-release "$release" \
    --expected-harnesses-json "$expected_harnesses_json" \
    "$root"; then
    return 0
  else
    rc=$?
    printf 'ERROR: attachment relink failed: %s → %s\n' "$project_key" "$root" >&2
    return "$rc"
  fi
}

if select_target_rows; then
  AGGREGATE_FLOOR="$(registry_state_floor 0 "$(selected_rows_json)")"
else
  rc=$?
  exit "$(registry_state_floor "$rc")"
fi
if print_targets; then
  :
else
  rc=$?
  # Floored like every other exit past the selection: a listing failure here is
  # a display fault, and it must not report below the registry state class
  # `registry_state_floor` has already proven and printed.
  exit "$(local_registry_max_class "$rc" "$AGGREGATE_FLOOR")"
fi
$DRY_RUN && printf '(dry-run mode — no writes)\n'

aggregate_rc="$AGGREGATE_FLOOR"
if [ "${#TARGET_ROWS[@]}" -gt 0 ]; then
  for row in "${TARGET_ROWS[@]}"; do
    if reconcile_row "$row"; then
      :
    else
      rc=$?
      if [ "$rc" -gt "$aggregate_rc" ]; then
        aggregate_rc="$rc"
      fi
    fi
  done
fi

if [ "$aggregate_rc" -ne 0 ]; then
  printf '== completed with errors (status %s) ==\n' "$aggregate_rc" >&2
  exit "$aggregate_rc"
fi

printf '== done ==\n'
printf '\n'
printf 'Claude local settings are release-backed, local attachment-managed surfaces.\n'
printf 'This rollout never writes project-owned settings.\n'
