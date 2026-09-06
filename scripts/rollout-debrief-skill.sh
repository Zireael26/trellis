#!/usr/bin/env bash
# Rollout: reconcile the release-backed `debrief` skill surface in every locally
# attached project. Idempotent; safe to re-run.
#
# debrief is the explicit-invoke-only teach-it-back skill. Like the builder
# skills it is not part of the clarify → spec → plan → tasks → analyze pipeline,
# so it has its own rollout path. Its native harness leaves remain entirely
# attachment-managed and point only into a verified immutable release payload.
#
# Behavior per selected local-registry row:
#   1. Unavailable, excluded, detached, and otherwise ineligible rows are
#      reported as skips; no replacement root is discovered.
#   2. The row's exact recorded release is verified and its immutable payload is
#      validated with the surface planner for the row's recorded harnesses.
#   3. Attachment-managed surfaces are reconciled only through `attach-project
#      relink`; this script never creates, backs up, or replaces runtime leaves.
#   4. Dry-runs validate the same release-backed plan without project or home
#      mutations.
#
# Usage:
#   rollout-debrief-skill.sh                 # interactive, all local registry rows
#   rollout-debrief-skill.sh --dry-run       # show plan only
#   rollout-debrief-skill.sh --yes           # non-interactive
#   rollout-debrief-skill.sh <project-name>  # project ID or fleet/project ID

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

DEBRIEF_SKILLS=(debrief)

DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y)  ASSUME_YES=true ;;
    --help|-h) ;;
    -*)        echo "unknown option: $arg" >&2; exit 2 ;;
    *)         ONLY_PROJECT="$arg" ;;
  esac
done

TRELLIS_HOME="$(trellis_home_resolve)" || exit $?
export TRELLIS_HOME

REGISTRY_JSON="$(local_registry_list_json "$TRELLIS_HOME")" || exit $?

# A registry state error is a property of the REGISTRY, not of the selection.
# Selecting one project narrows what this rollout ACTS on; it must never narrow
# what counts toward the exit class, and the preflight refusals below used to
# exit on a lower class (unavailable/conflict) while the listing in hand already
# proved the registry corrupt. `registry_state_floor` reports the drifted rows
# this run will not visit and floors the given class with theirs.
aggregate_rc=0

registry_state_floor() {
  local class="${1:-0}" selected="${2:-}" rc=0
  local_registry_report_unselected_state_errors "$REGISTRY_JSON" "$selected" || rc="$?"
  local_registry_max_class "$class" "$rc"
}
SELECTED_KEY=""
if [ -n "$ONLY_PROJECT" ]; then
  SELECTED_KEY="$(printf '%s\n' "$REGISTRY_JSON" | jq -r --arg project "$ONLY_PROJECT" \
    '[.entries[] | select(.project_key == $project) | .project_key] | unique | .[0] // empty')" \
    || exit "$(registry_state_floor "$?")"
  if [ -z "$SELECTED_KEY" ]; then
    MATCHING_KEYS=()
    while IFS= read -r project_key; do
      [ -n "$project_key" ] && MATCHING_KEYS+=("$project_key")
    done < <(printf '%s\n' "$REGISTRY_JSON" | jq -r --arg project "$ONLY_PROJECT" \
      '[.entries[] | select(.project_id == $project) | .project_key] | unique[]')
    case "${#MATCHING_KEYS[@]}" in
      0)
        echo "project not in local registry: $ONLY_PROJECT" >&2
        exit "$(registry_state_floor "$TRELLIS_EX_UNAVAILABLE")"
        ;;
      1) SELECTED_KEY="${MATCHING_KEYS[0]}" ;;
      *)
        echo "ambiguous project ID in local registry: $ONLY_PROJECT (${MATCHING_KEYS[*]}); use fleet/project ID" >&2
        exit "$(registry_state_floor "$TRELLIS_EX_CONFLICT")"
        ;;
    esac
  fi
fi

if [ -n "$SELECTED_KEY" ]; then
  TARGET_JSON="$(printf '%s\n' "$REGISTRY_JSON" | jq -c --arg project_key "$SELECTED_KEY" \
    '.entries[] | select(.project_key == $project_key)')" || exit "$(registry_state_floor "$?")"
else
  TARGET_JSON="$(printf '%s\n' "$REGISTRY_JSON" | jq -c '.entries[]')" || exit "$(registry_state_floor "$?")"
fi

TARGET_ROWS=()
while IFS= read -r row; do
  [ -n "$row" ] && TARGET_ROWS+=("$row")
done <<EOF
$TARGET_JSON
EOF

# Rows outside the selection are reported here, once, from the FULL listing.
# Unscoped, every row is selected and this reports nothing.
aggregate_rc="$(registry_state_floor "$aggregate_rc" "$TARGET_JSON")"

rollout_one() {
  local row="$1"
  local fleet project_key project_id kind availability status excluded root checkout_id worktree_id attachment_id
  local release release_dir payload plan harness expected_destination expected_source
  local resolved resolved_project_key resolved_root resolved_checkout_id resolved_worktree_id rc harnesses_json expected_harnesses_json
  local -a row_harnesses=()

  fleet="$(printf '%s\n' "$row" | jq -r '.fleet')" || return "$TRELLIS_EX_STATE"
  project_key="$(printf '%s\n' "$row" | jq -r '.project_key')" || return "$TRELLIS_EX_STATE"
  project_id="$(printf '%s\n' "$row" | jq -r '.project_id')" || return "$TRELLIS_EX_STATE"
  kind="$(printf '%s\n' "$row" | jq -r '.kind')" || return "$TRELLIS_EX_STATE"
  availability="$(printf '%s\n' "$row" | jq -r '.availability')" || return "$TRELLIS_EX_STATE"
  status="$(printf '%s\n' "$row" | jq -r '.status')" || return "$TRELLIS_EX_STATE"
  excluded="$(printf '%s\n' "$row" | jq -r '.excluded // false')" || return "$TRELLIS_EX_STATE"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')" || return "$TRELLIS_EX_STATE"
  checkout_id="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')" || return "$TRELLIS_EX_STATE"
  worktree_id="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')" || return "$TRELLIS_EX_STATE"
  attachment_id="$(printf '%s\n' "$row" | jq -r '.attachment_id // empty')" || return "$TRELLIS_EX_STATE"

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
    printf 'skip (ineligible row without root): %s\n' "$project_key"
    return 0
  fi
  if [ -z "$attachment_id" ]; then
    printf 'skip (ineligible row without attachment ownership): %s → %s\n' "$project_key" "$(safe_display_root "$root")"
    return 0
  fi
  require_safe_display_path "$root" || return "$?"
  if [ -z "$checkout_id" ] || [ -z "$worktree_id" ]; then
    printf 'error (active worktree row has incomplete identity): %s → %s\n' "$project_key" "$root" >&2
    return "$TRELLIS_EX_STATE"
  fi

  if resolved="$(local_registry_resolve_root "$TRELLIS_HOME" "$root")"; then
    :
  else
    rc=$?
    printf 'error (could not re-resolve active worktree row): %s → %s\n' "$project_key" "$root" >&2
    return "$rc"
  fi
  resolved_project_key="$(printf '%s\n' "$resolved" | jq -r '.project_key // empty')" || return "$TRELLIS_EX_STATE"
  resolved_root="$(printf '%s\n' "$resolved" | jq -r '.root // empty')" || return "$TRELLIS_EX_STATE"
  resolved_checkout_id="$(printf '%s\n' "$resolved" | jq -r '.checkout_id // empty')" || return "$TRELLIS_EX_STATE"
  resolved_worktree_id="$(printf '%s\n' "$resolved" | jq -r '.worktree_id // empty')" || return "$TRELLIS_EX_STATE"
  if [ "$resolved_project_key" != "$project_key" ] ||
    [ "$resolved_root" != "$root" ] ||
    [ "$resolved_checkout_id" != "$checkout_id" ] ||
    [ "$resolved_worktree_id" != "$worktree_id" ]; then
    printf 'error (active worktree row identity drift): %s → %s\n' "$project_key" "$root" >&2
    return "$TRELLIS_EX_STATE"
  fi


  if harnesses_json="$(printf '%s\n' "$row" | jq -r '.harnesses[]?')"; then
    :
  else
    rc=$?
    printf 'error (could not read active worktree harnesses): %s → %s\n' "$project_key" "$root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r harness; do
    [ -n "$harness" ] && row_harnesses+=("$harness")
  done <<EOF
$harnesses_json
EOF
  if [ "${#row_harnesses[@]}" -eq 0 ]; then
    printf 'skip (ineligible row without skill surfaces): %s → %s\n' "$project_key" "$root"
    return 0
  fi
  for harness in "${row_harnesses[@]}"; do
    case "$harness" in
      claude|codex) ;;
      *)
        printf 'error (active worktree row has invalid harness): %s → %s (%s)\n' "$project_key" "$root" "$harness" >&2
        return "$TRELLIS_EX_STATE"
        ;;
    esac
  done
  expected_harnesses_json="$(jq -cn --args '$ARGS.positional' "${row_harnesses[@]}")" || return "$TRELLIS_EX_STATE"
  expected_harnesses_json="$(local_registry_normalize_harnesses "$expected_harnesses_json")" || return "$TRELLIS_EX_STATE"


  release="$(printf '%s\n' "$row" | jq -r '.release // empty')" || return "$TRELLIS_EX_STATE"
  if [ -z "$release" ]; then
    printf 'error (active worktree row has no recorded release): %s → %s\n' "$project_key" "$root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if release_dir="$(release_store_locate "$release")"; then
    :
  else
    rc=$?
    printf 'error (recorded release unavailable or invalid): %s → %s (%s)\n' "$project_key" "$root" "$release" >&2
    return "$rc"
  fi
  payload="$release_dir/payload"
  if plan="$(surface_plan_emit "$payload" "${row_harnesses[@]}")"; then
    :
  else
    rc=$?
    printf 'error (release surface plan invalid): %s → %s (%s)\n' "$project_key" "$root" "$release" >&2
    return "$TRELLIS_EX_STATE"
  fi

  for harness in "${row_harnesses[@]}"; do
    case "$harness" in
      claude) expected_destination=".claude/skills" ;;
      codex) expected_destination=".agents/skills" ;;
    esac
    expected_source="core-rules/skills/${DEBRIEF_SKILLS[0]}"
    if ! printf '%s\n' "$plan" | jq -e \
      --arg harness "$harness" \
      --arg source "$expected_source" \
      --arg destination "$expected_destination/${DEBRIEF_SKILLS[0]}" \
      '[.artifacts[] | select(.kind == "symlink" and .harness == $harness and .source == $source and .destination == $destination)] | length == 1' >/dev/null; then
      printf 'error (release lacks exact debrief skill surface): %s → %s (%s)\n' "$project_key" "$root" "$harness" >&2
      return "$TRELLIS_EX_STATE"
    fi
  done

  printf '== %s ==\n' "$project_key"
  if $DRY_RUN; then
    printf '  + would reconcile attachment-managed debrief skill surface from release %s at %s\n' "$release" "$root"
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
    :
  else
    rc=$?
    printf 'error (attachment relink failed): %s → %s\n' "$project_key" "$root" >&2
    return "$rc"
  fi
}

echo "Targets:"
if [ "${#TARGET_ROWS[@]}" -eq 0 ]; then
  echo "  (none)"
else
  for row in "${TARGET_ROWS[@]}"; do
    # Floored, like every other exit past the selection: a target-display
    # fault must not report below the registry state class already proven and
    # printed by `registry_state_floor`.
    project_key="$(printf '%s\n' "$row" | jq -r '.project_key')" \
      || exit "$(local_registry_max_class "$?" "$aggregate_rc")"
    root="$(printf '%s\n' "$row" | jq -r '.root // "<no local root>"')" \
      || exit "$(local_registry_max_class "$?" "$aggregate_rc")"
    printf '  %s → %s\n' "$project_key" "$(safe_display_root "$root")"
  done
fi
echo "Skill: ${DEBRIEF_SKILLS[*]}"
$DRY_RUN && echo "(dry-run mode — no writes)"

if ! $ASSUME_YES && ! $DRY_RUN; then
  printf "Proceed? [y/N] "
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit "$aggregate_rc"; }
fi

if [ "${#TARGET_ROWS[@]}" -gt 0 ]; then
  for row in "${TARGET_ROWS[@]}"; do
    if rollout_one "$row"; then
      :
    else
      rc=$?
      if [ "$rc" -gt "$aggregate_rc" ]; then
        aggregate_rc=$rc
      fi
    fi
  done
fi

if [ "$aggregate_rc" -eq 0 ]; then
  echo "== done =="
else
  printf '== completed with failures (highest exit class: %s) ==\n' "$aggregate_rc" >&2
fi
echo
echo "Debrief is a release-backed, local attachment-managed surface."
echo "Collision handling remains with attachment ownership; this rollout never alters leaves directly."
exit "$aggregate_rc"
