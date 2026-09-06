#!/usr/bin/env bash
# Rollout: reconcile the attachment-managed `writing` skill surface for
# registered portable projects. It never writes project runtime leaves itself:
# every eligible row is validated against its immutable release payload and
# delegated to attach-project.sh relink.
#
# Usage:
#   rollout-writing-skill.sh                 # interactive, all local registry rows
#   rollout-writing-skill.sh --dry-run       # show reconciliation plan only
#   rollout-writing-skill.sh --yes           # non-interactive
#   rollout-writing-skill.sh <fleet/project> # one logical project
#   rollout-writing-skill.sh <project>       # one unambiguous project ID

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


SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

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

SKILL="writing"
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

select_target_rows() {
  local project_key
  local -a project_keys=()

  if [ -z "$ONLY_PROJECT" ]; then
    while IFS= read -r row; do
      [ -n "$row" ] && TARGET_ROWS+=("$row")
    done < <(printf '%s\n' "$REGISTRY_JSON" | jq -c '.entries[]')
    return 0
  fi

  case "$ONLY_PROJECT" in
    */*)
      while IFS= read -r row; do
        [ -n "$row" ] && TARGET_ROWS+=("$row")
      done < <(printf '%s\n' "$REGISTRY_JSON" | jq -c --arg project_key "$ONLY_PROJECT" '.entries[] | select(.project_key == $project_key)')
      if [ "${#TARGET_ROWS[@]}" -eq 0 ]; then
        echo "project not in local registry: $ONLY_PROJECT" >&2
        return "$TRELLIS_EX_UNAVAILABLE"
      fi
      ;;
    *)
      while IFS= read -r project_key; do
        [ -n "$project_key" ] && project_keys+=("$project_key")
      done < <(printf '%s\n' "$REGISTRY_JSON" | jq -r --arg project_id "$ONLY_PROJECT" '[.entries[] | select(.project_id == $project_id) | .project_key] | unique[]')
      case "${#project_keys[@]}" in
        0)
          echo "project not in local registry: $ONLY_PROJECT" >&2
          return "$TRELLIS_EX_UNAVAILABLE"
          ;;
        1)
          while IFS= read -r row; do
            [ -n "$row" ] && TARGET_ROWS+=("$row")
          done < <(printf '%s\n' "$REGISTRY_JSON" | jq -c --arg project_key "${project_keys[0]}" '.entries[] | select(.project_key == $project_key)')
          ;;
        *)
          echo "project ID is ambiguous across fleets: $ONLY_PROJECT; use <fleet>/<project>" >&2
          return "$TRELLIS_EX_CONFLICT"
          ;;
      esac
      ;;
  esac
}

print_targets() {
  local row project_key root
  if [ "${#TARGET_ROWS[@]}" -eq 0 ]; then
    echo "Targets: (none)"
    return 0
  fi
  echo "Targets:"
  for row in "${TARGET_ROWS[@]}"; do
    project_key="$(printf '%s\n' "$row" | jq -r '.project_key')"
    root="$(printf '%s\n' "$row" | jq -r '.root // "(no root)"')"
    printf '  %s — %s\n' "$project_key" "$(safe_display_root "$root")"
  done
}

row_identity_matches() {
  local resolved="$1" project_key="$2" root="$3" checkout_id="$4" worktree_id="$5"

  printf '%s\n' "$resolved" |
    jq -e \
      --arg project_key "$project_key" \
      --arg root "$root" \
      --arg checkout_id "$checkout_id" \
      --arg worktree_id "$worktree_id" '
        .project_key == $project_key
        and .root == $root
        and .checkout_id == $checkout_id
        and .worktree_id == $worktree_id
      ' >/dev/null
}

rollout_one() {
  local row="$1" fleet project_key project_id kind availability status excluded root release attachment_id checkout_id worktree_id
  local release_dir payload plan harness expected_destination resolved rc relink_status expected_harnesses_json
  local -a harnesses=()

  fleet="$(printf '%s\n' "$row" | jq -r '.fleet')"
  project_key="$(printf '%s\n' "$row" | jq -r '.project_key')"
  project_id="$(printf '%s\n' "$row" | jq -r '.project_id')" || return "$TRELLIS_EX_STATE"
  kind="$(printf '%s\n' "$row" | jq -r '.kind')"
  availability="$(printf '%s\n' "$row" | jq -r '.availability')"
  status="$(printf '%s\n' "$row" | jq -r '.status')"
  excluded="$(printf '%s\n' "$row" | jq -r '.excluded')"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')"
  release="$(printf '%s\n' "$row" | jq -r '.release // empty')"
  attachment_id="$(printf '%s\n' "$row" | jq -r '.attachment_id // empty')"
  checkout_id="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')"
  worktree_id="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')"

  # identity_error is tested BEFORE the excluded skip: drift is a property of the
  # row's recorded identity, not of whether this run would have acted on it, so
  # an excluded row's drift must not be swallowed into an exit 0. Report-only —
  # the row is still never processed.
  if [ "$availability" = identity_error ]; then
    echo "error (registry row failed identity validation): $project_key → $(safe_display_root "${root:-<no local root>}")" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ "$excluded" = true ]; then
    echo "skip (excluded local registry row): $project_key"
    return 0
  fi
  if [ "$availability" != available ]; then
    printf 'skip (unavailable): %s → %s\n' "$project_key" "$(safe_display_root "${root:-<no local root>}")"
    return 0
  fi
  if [ "$kind" != worktree ] || [ -z "$root" ]; then
    echo "skip (no available worktree): $project_key"
    return 0
  fi
  if [ "$status" != active ] || [ -z "$attachment_id" ]; then
    echo "skip (not attached): $project_key → $(safe_display_root "$root")"
    return 0
  fi
  require_safe_display_path "$root" || return "$?"

  if resolved="$(local_registry_resolve_root "$TRELLIS_HOME" "$root")"; then
    :
  else
    rc=$?
    echo "error (row root no longer resolves through local registry; status $rc): $project_key → $root" >&2
    return "$rc"
  fi
  if row_identity_matches "$resolved" "$project_key" "$root" "$checkout_id" "$worktree_id"; then
    :
  else
    rc=$?
    echo "error (registry identity changed while resolving row; status $rc): $project_key → $root" >&2
    return "$TRELLIS_EX_STATE"
  fi

  if [ -z "$release" ]; then
    echo "error (row has no recorded release): $project_key → $root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r harness; do
    [ -n "$harness" ] && harnesses+=("$harness")
  done < <(printf '%s\n' "$row" | jq -r '.harnesses[]')
  if [ "${#harnesses[@]}" -eq 0 ]; then
    echo "skip (no registered harnesses): $project_key → $root"
    return 0
  fi
  expected_harnesses_json="$(jq -cn --args '$ARGS.positional' "${harnesses[@]}")" || return "$TRELLIS_EX_STATE"
  expected_harnesses_json="$(local_registry_normalize_harnesses "$expected_harnesses_json")" || return "$TRELLIS_EX_STATE"

  if release_dir="$(release_store_locate "$release")"; then
    :
  else
    rc=$?
    echo "error (recorded release is unavailable or unverified; status $rc): $project_key → $release" >&2
    return "$rc"
  fi
  payload="$release_dir/payload"
  if [ ! -d "$payload" ] || [ -L "$payload" ]; then
    echo "error (verified release has no payload directory): $project_key → $release" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if plan="$(surface_plan_emit "$payload" "${harnesses[@]}")"; then
    :
  else
    rc=$?
    echo "error (invalid release surface plan; status $rc): $project_key → $release" >&2
    return "$TRELLIS_EX_STATE"
  fi
  for harness in "${harnesses[@]}"; do
    case "$harness" in
      claude) expected_destination=".claude/skills/$SKILL" ;;
      codex) expected_destination=".agents/skills/$SKILL" ;;
      *)
        echo "error (unknown registered harness): $project_key → $harness" >&2
        return "$TRELLIS_EX_STATE"
        ;;
    esac
    if printf '%s\n' "$plan" | jq -e \
      --arg harness "$harness" \
      --arg source "core-rules/skills/$SKILL" \
      --arg destination "$expected_destination" '
        [.artifacts[]
          | select(.harness == $harness
              and .kind == "symlink"
              and .source == $source
              and .destination == $destination)]
        | length == 1
      ' >/dev/null; then
      :
    else
      rc=$?
      echo "error (skill surface has no exact planned artifact for $harness; status $rc): $project_key → $release" >&2
      return "$TRELLIS_EX_STATE"
    fi
  done

  echo "== $project_key — $root =="
  if $DRY_RUN; then
    echo "  + would reconcile attachment-managed $SKILL surfaces from release $release"
    return 0
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
    relink_status=$?
    echo "error (attachment relink failed; status $relink_status): $project_key → $root" >&2
    return "$relink_status"
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
echo "Skill: $SKILL"
if $DRY_RUN; then
  echo "(dry-run mode — no project or home writes)"
fi

if ! $ASSUME_YES && ! $DRY_RUN; then
  printf "Proceed? [y/N] "
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit "$AGGREGATE_FLOOR"; }
fi

aggregate_status="$AGGREGATE_FLOOR"
if [ "${#TARGET_ROWS[@]}" -gt 0 ]; then
  for row in "${TARGET_ROWS[@]}"; do
    if rollout_one "$row"; then
      :
    else
      rc=$?
      if [ "$rc" -gt "$aggregate_status" ]; then
        aggregate_status=$rc
      fi
    fi
  done
fi

echo "== done =="
echo
echo "Per-project next steps:"
echo "  1. The selected immutable release remains the sole source of the"
echo "     attachment-managed skill surfaces."
echo "  2. Re-run this command after attaching a release or changing its local"
echo "     registry row; unavailable and detached rows are intentionally skipped."
exit "$aggregate_status"
