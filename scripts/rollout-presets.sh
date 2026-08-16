#!/usr/bin/env bash
# Rollout: install and reconcile project-opt-in preset links from each selected
# row's immutable release payload. Presets are project-local opt-in leaves, not
# attachment-managed runtime surfaces; foreign files and links are never moved
# or replaced.
#
# Usage:
#   rollout-presets.sh                 # interactive, all local registry rows
#   rollout-presets.sh --dry-run       # show plan only
#   rollout-presets.sh --yes           # non-interactive
#   rollout-presets.sh <fleet/project> # one logical project
#   rollout-presets.sh <project>       # one unambiguous project ID

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
# shellcheck source=lib/attachment.sh
. "$SCRIPT_DIR/lib/attachment.sh"

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

TRELLIS_HOME="$(trellis_home_resolve "${TRELLIS_HOME:-}")"
export TRELLIS_HOME
REGISTRY_JSON="$(local_registry_list_json "$TRELLIS_HOME")"
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
    return
  fi
  echo "Targets:"
  for row in "${TARGET_ROWS[@]}"; do
    project_key="$(printf '%s\n' "$row" | jq -r '.project_key')"
    root="$(printf '%s\n' "$row" | jq -r '.root // "(no root)"')"
    printf '  %s — %s\n' "$project_key" "$(safe_display_root "$root")"
  done
}

read_project_presets() {
  local manifest="$1"
  if [ -L "$manifest" ] || [ ! -f "$manifest" ]; then
    echo "  WARN: missing required project manifest .trellis.json — skipping" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if ! local_registry_manifest_project_id "$manifest" >/dev/null; then
    echo "  WARN: invalid project manifest $manifest — skipping" >&2
    return "$TRELLIS_EX_STATE"
  fi
  jq -r '.presets // [] | .[]' "$manifest"
}

verified_release_preset_target() {
  local current="$1" name="$2" releases suffix version release_dir expected
  releases="$(release_store_releases_dir)" || return "$?"
  case "$current" in
    "$releases"/*/payload/core-rules/presets/"$name".md) ;;
    *) return 1 ;;
  esac
  suffix="${current#"$releases/"}"
  version="${suffix%%/*}"
  [ -n "$version" ] && [ "$suffix" = "$version/payload/core-rules/presets/$name.md" ] || return 1
  release_dir="$(release_store_locate "$version")" || return "$?"
  expected="$release_dir/payload/core-rules/presets/$name.md"
  [ "$current" = "$expected" ] || return 1
  [ -f "$expected" ] && [ ! -L "$expected" ] || return "$TRELLIS_EX_STATE"
  printf '%s\n' "$release_dir"
}

enter_preset_rules_dir() {
  local root="$1" subdir="$2" create="$3" component expected
  [ "$#" -eq 3 ] || return "$TRELLIS_EX_USAGE"
  if [ ! -d "$root" ] || [ -L "$root" ]; then
    echo "  ERROR: project root is not a real directory" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if cd -P -- "$root"; then
    :
  else
    echo "  ERROR: cannot enter project root for preset reconciliation" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ "$PWD" != "$root" ]; then
    echo "  ERROR: project root changed while preparing preset reconciliation" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  for component in "$subdir" rules; do
    expected="$PWD/$component"
    if [ -L "$component" ]; then
      echo "  ERROR: $subdir preset parent is a symlink" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    if [ -e "$component" ]; then
      if [ -d "$component" ]; then
        :
      else
        echo "  ERROR: $subdir preset parent is not a directory" >&2
        return "$TRELLIS_EX_CONFLICT"
      fi
    elif [ "$create" = true ]; then
      if mkdir -- "$component"; then
        :
      else
        echo "  ERROR: cannot create $subdir preset parent" >&2
        return "$TRELLIS_EX_UNAVAILABLE"
      fi
    else
      return 1
    fi
    if cd -P -- "$component"; then
      :
    else
      echo "  ERROR: cannot enter $subdir preset parent" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    if [ "$PWD" != "$expected" ]; then
      echo "  ERROR: $subdir preset parent changed while preparing reconciliation" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
  done
}

atomic_retarget_preset_symlink() (
  local link="$1" old_target="$2" target="$3" label="$4" name="$5" stage staged current rc
  if stage="$(mktemp -d ".trellis-preset.XXXXXX")"; then
    :
  else
    echo "  ERROR: cannot stage preset link at $label" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  staged="$stage/link"
  if ln -s "$target" "$staged"; then
    :
  else
    rmdir "$stage" >/dev/null 2>&1 || true
    echo "  ERROR: cannot stage preset link at $label" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if current="$(readlink "$link")"; then
    :
  else
    rm -f "$staged"
    rmdir "$stage" >/dev/null 2>&1 || true
    echo "  ERROR: cannot re-read preset link $label" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ "$current" != "$old_target" ]; then
    rm -f "$staged"
    rmdir "$stage" >/dev/null 2>&1 || true
    echo "  WARN: $label changed during reconciliation — leaving" >&2
    return 0
  fi
  if verified_release_preset_target "$current" "$name" >/dev/null; then
    :
  else
    rc="$?"
    rm -f "$staged"
    rmdir "$stage" >/dev/null 2>&1 || true
    if [ "$rc" -eq 1 ]; then
      echo "  WARN: $label no longer targets a verified release payload — leaving" >&2
      return 0
    fi
    echo "  ERROR: cannot re-verify prior preset target $label" >&2
    return "$rc"
  fi
  if mv -f "$staged" "$link"; then
    :
  else
    rm -f "$staged"
    rmdir "$stage" >/dev/null 2>&1 || true
    echo "  ERROR: cannot atomically retarget preset link $label" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if rmdir "$stage"; then
    :
  else
    echo "  ERROR: cannot remove preset staging directory for $label" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  echo "  retargeted: $label → immutable payload"
)

install_preset_symlink() (
  local root="$1" subdir="$2" name="$3" presets_dir="$4" target link label current old_release rc create=false
  if ! printf '%s' "$name" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9-]*[a-z0-9]$'; then
    if trellis_home_has_unsafe_chars "$name"; then
      echo "  ERROR: malformed preset name with terminal control characters" >&2
    else
      echo "  ERROR: malformed preset name '$name'" >&2
    fi
    return "$TRELLIS_EX_STATE"
  fi
  target="$presets_dir/$name.md"
  link="preset-$name.md"
  label="$subdir/rules/$link"
  if [ ! -f "$target" ] || [ -L "$target" ]; then
    echo "  ERROR: preset '$name' is absent from immutable release payload" >&2
    return "$TRELLIS_EX_STATE"
  fi
  $DRY_RUN || create=true
  if enter_preset_rules_dir "$root" "$subdir" "$create"; then
    :
  else
    rc=$?
    if $DRY_RUN && [ "$rc" -eq 1 ]; then
      echo "  + would link: $label → immutable payload"
      return 0
    fi
    return "$rc"
  fi
  if [ -L "$link" ]; then
    if current="$(readlink "$link")"; then
      :
    else
      echo "  ERROR: cannot read $label" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    if [ "$current" = "$target" ]; then
      echo "  skip (correct payload link): $label"
      return 0
    fi
    # shellcheck disable=SC2034  # The substitution is tested for its exit status; the value is
    # deliberately discarded, and capturing it keeps the probe's stdout out of the rollout log.
    if old_release="$(verified_release_preset_target "$current" "$name")"; then
      if $DRY_RUN; then
        echo "  + would atomically retarget: $label → immutable payload"
        return 0
      fi
      atomic_retarget_preset_symlink "$link" "$current" "$target" "$label" "$name"
      return "$?"
    fi
    rc="$?"
    if [ "$rc" -ne 1 ]; then
      echo "  ERROR: cannot verify prior release target for $label" >&2
      return "$rc"
    fi
    echo "  WARN: $label has a foreign target — leaving" >&2
    return 0
  fi
  if [ -e "$link" ]; then
    echo "  WARN: $label is project-owned — leaving" >&2
    return 0
  fi
  if $DRY_RUN; then
    echo "  + would link: $label → immutable payload"
    return 0
  fi
  if ln -s "$target" "$link"; then
    :
  else
    echo "  ERROR: cannot create preset link $label" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  echo "  linked: $label → immutable payload"
)

prune_stale_presets() (
  local root="$1" subdir="$2" declared="$3" link filename name label current verified_release rc
  if enter_preset_rules_dir "$root" "$subdir" false; then
    :
  else
    rc=$?
    [ "$rc" -eq 1 ] && return 0
    return "$rc"
  fi
  for link in preset-*.md; do
    [ -L "$link" ] || continue
    filename="$link"
    name="${filename#preset-}"
    name="${name%.md}"
    # The on-disk name reaches stderr, so reject control bytes before it is ever
    # built into a diagnostic label.
    if trellis_home_has_unsafe_chars "$filename"; then
      echo "  WARN: $subdir/rules/<unsafe preset link name> has terminal control characters — leaving" >&2
      continue
    fi
    label="$subdir/rules/$filename"
    if printf '%s\n' "$declared" | grep -qxF "$name"; then
      continue
    fi
    if ! printf '%s' "$name" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9-]*[a-z0-9]$'; then
      echo "  WARN: $label has an unrecognized name — leaving" >&2
      continue
    fi
    if current="$(readlink "$link")"; then
      :
    else
      echo "  ERROR: cannot read $label" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    # shellcheck disable=SC2034  # Exit status only, as above.
    if verified_release="$(verified_release_preset_target "$current" "$name")"; then
      :
    else
      rc="$?"
      if [ "$rc" -ne 1 ]; then
        echo "  ERROR: cannot verify payload target for $label" >&2
        return "$rc"
      fi
      echo "  WARN: $label does not target an exact verified payload preset — leaving" >&2
      continue
    fi
    if $DRY_RUN; then
      echo "  + would remove stale payload link: $label"
      continue
    fi
    if [ "$(readlink "$link")" != "$current" ]; then
      echo "  WARN: $label changed during reconciliation — leaving" >&2
      continue
    fi
    if rm "$link"; then
      :
    else
      echo "  ERROR: cannot remove stale payload link $label" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    echo "  removed stale payload link: $label"
  done
)

row_identity_matches() {
  local row="$1" resolved="$2" project_key root checkout_id worktree_id
  project_key="$(printf '%s\n' "$row" | jq -r '.project_key')" || return "$TRELLIS_EX_STATE"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')" || return "$TRELLIS_EX_STATE"
  checkout_id="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')" || return "$TRELLIS_EX_STATE"
  worktree_id="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')" || return "$TRELLIS_EX_STATE"
  printf '%s\n' "$resolved" | jq -e \
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

row_is_current() {
  local row="$1" registry rc
  if registry="$(local_registry_list_json "$TRELLIS_HOME")"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  printf '%s\n' "$registry" | jq -e --argjson expected "$row" '
    [.entries[]
      | select(
          .project_key == $expected.project_key
          and .root == $expected.root
          and .checkout_id == $expected.checkout_id
          and .worktree_id == $expected.worktree_id
        )]
    | length == 1 and .[0] == $expected
  ' >/dev/null
}


rollout_one() (
  local row="$1" project_key project_id kind availability status excluded root release release_dir payload presets_dir plan manifest manifest_project_id declared harness resolved checkout_id common rc
  local -a harnesses=()

  project_key="$(printf '%s\n' "$row" | jq -r '.project_key')" || return "$TRELLIS_EX_STATE"
  project_id="$(printf '%s\n' "$row" | jq -r '.project_id')" || return "$TRELLIS_EX_STATE"
  kind="$(printf '%s\n' "$row" | jq -r '.kind')" || return "$TRELLIS_EX_STATE"
  availability="$(printf '%s\n' "$row" | jq -r '.availability')" || return "$TRELLIS_EX_STATE"
  status="$(printf '%s\n' "$row" | jq -r '.status')" || return "$TRELLIS_EX_STATE"
  excluded="$(printf '%s\n' "$row" | jq -r '.excluded // false')" || return "$TRELLIS_EX_STATE"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')" || return "$TRELLIS_EX_STATE"
  release="$(printf '%s\n' "$row" | jq -r '.release // empty')" || return "$TRELLIS_EX_STATE"

  # identity_error is tested BEFORE the excluded skip: drift is a property of the
  # row's recorded identity, not of whether this run would have acted on it, so
  # an excluded row's drift must not be swallowed into an exit 0. Report-only —
  # the row is still never processed.
  if [ "$availability" = identity_error ]; then
    echo "ERROR: registry row failed identity validation: $project_key → $(safe_display_root "${root:-<no local root>}")" >&2
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
  if [ "$status" != active ]; then
    echo "skip (ineligible registry status: $status): $project_key"
    return 0
  fi
  require_safe_display_path "$root" || return "$?"
  if [ -z "$release" ]; then
    echo "ERROR: active row has no recorded immutable release: $project_key → $root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if resolved="$(local_registry_resolve_root "$TRELLIS_HOME" "$root")"; then
    :
  else
    rc=$?
    echo "ERROR: active row root no longer resolves through local registry: $project_key → $root" >&2
    return "$rc"
  fi
  if row_identity_matches "$row" "$resolved"; then
    :
  else
    echo "ERROR: local registry identity changed while resolving row: $project_key → $root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  checkout_id="$(printf '%s\n' "$resolved" | jq -r '.checkout_id // empty')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$resolved" | jq -r '.git_common_dir // empty')" || return "$TRELLIS_EX_STATE"
  if [ -z "$checkout_id" ] || [ -z "$common" ]; then
    echo "ERROR: active row has no checkout lock identity: $project_key" >&2
    return "$TRELLIS_EX_STATE"
  fi


  while IFS= read -r harness; do
    [ -n "$harness" ] && harnesses+=("$harness")
  done < <(printf '%s\n' "$row" | jq -r '.harnesses[]?')
  if [ "${#harnesses[@]}" -eq 0 ]; then
    echo "ERROR: active row has no recorded harnesses: $project_key → $root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if release_dir="$(release_store_locate "$release")"; then
    :
  else
    rc="$?"
    echo "ERROR: recorded release is unavailable or invalid: $project_key → $release" >&2
    return "$rc"
  fi
  payload="$release_dir/payload"
  if [ -d "$payload" ] && [ ! -L "$payload" ]; then
    :
  else
    echo "ERROR: verified release has no real payload directory: $project_key → $release" >&2
    return "$TRELLIS_EX_STATE"
  fi
  # shellcheck disable=SC2034  # Exit status only; the plan itself is re-emitted by the applier.
  if plan="$(surface_plan_emit "$payload" "${harnesses[@]}")"; then
    :
  else
    rc="$?"
    echo "ERROR: invalid release surface plan: $project_key → $release" >&2
    return "$TRELLIS_EX_STATE"
  fi
  presets_dir="$payload/core-rules/presets"
  if [ -d "$presets_dir" ] && [ ! -L "$presets_dir" ]; then
    :
  else
    echo "ERROR: release payload has no real preset source directory: $project_key → $release" >&2
    return "$TRELLIS_EX_STATE"
  fi

  echo "== $project_key — $root =="
  if ! $DRY_RUN; then
    if attachment_checkout_lock_reclaim "$TRELLIS_HOME" "$checkout_id" "$common"; then
      :
    else
      rc=$?
      echo "ERROR: could not reclaim checkout lock for preset reconciliation: $project_key" >&2
      return "$rc"
    fi
    if attachment_checkout_lock_acquire "$TRELLIS_HOME" "$checkout_id" "$common"; then
      :
    else
      rc=$?
      echo "ERROR: checkout is busy; preset reconciliation was not applied: $project_key" >&2
      return "$rc"
    fi
    _attachment_install_checkout_lock_traps
    if row_is_current "$row"; then
      :
    else
      rc=$?
      if [ "$rc" -eq 1 ]; then
        echo "ERROR: registry row changed while waiting for preset reconciliation: $project_key" >&2
        return "$TRELLIS_EX_CONFLICT"
      fi
      return "$rc"
    fi
    if resolved="$(local_registry_resolve_root "$TRELLIS_HOME" "$root")"; then
      :
    else
      rc=$?
      echo "ERROR: active row root no longer resolves while locked: $project_key" >&2
      return "$rc"
    fi
    if row_identity_matches "$row" "$resolved"; then
      :
    else
      echo "ERROR: local registry identity changed while waiting for preset reconciliation: $project_key" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
  fi

  manifest="$root/.trellis.json"
  if declared="$(read_project_presets "$manifest")"; then
    :
  else
    rc="$?"
    return "$rc"
  fi
  if manifest_project_id="$(local_registry_manifest_project_id "$manifest")"; then
    :
  else
    return "$TRELLIS_EX_STATE"
  fi
  if [ "$manifest_project_id" != "$project_id" ]; then
    echo "ERROR: .trellis.json project_id does not match registry row: $project_key" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -z "$declared" ]; then
    echo "  no presets declared in .trellis.json"
  fi

  if printf '%s\n' "$row" | jq -e '.harnesses | index("claude") != null' >/dev/null; then
    for name in $declared; do
      if install_preset_symlink "$root" ".claude" "$name" "$presets_dir"; then
        :
      else
        rc="$?"
        return "$rc"
      fi
    done
    if prune_stale_presets "$root" ".claude" "$declared"; then
      :
    else
      rc="$?"
      return "$rc"
    fi
  else
    # A row whose harness set no longer includes claude installs nothing into
    # .claude — but nothing else owns the managed preset links already there,
    # so they would leak forever. Reclaim them by pruning against an empty
    # declared set. `prune_stale_presets` enters with create=false, so it never
    # creates .claude or .claude/rules, and it keeps every symlink-safety check:
    # only a link that resolves to an exact verified payload preset is removed.
    echo "  reclaim (row without Claude harness): pruning managed .claude preset links"
    if prune_stale_presets "$root" ".claude" ""; then
      :
    else
      rc="$?"
      return "$rc"
    fi
  fi

  if printf '%s\n' "$row" | jq -e '.harnesses | index("codex") != null' >/dev/null; then
    for name in $declared; do
      if install_preset_symlink "$root" ".agents" "$name" "$presets_dir"; then
        :
      else
        rc="$?"
        return "$rc"
      fi
    done
    if prune_stale_presets "$root" ".agents" "$declared"; then
      :
    else
      rc="$?"
      return "$rc"
    fi
  fi
  return 0
)

if select_target_rows; then
  AGGREGATE_FLOOR="$(registry_state_floor 0 "$(selected_rows_json)")"
else
  exit "$(registry_state_floor "$?")"
fi
if print_targets; then
  :
else
  rc=$?
  exit "$(local_registry_max_class "$rc" "$AGGREGATE_FLOOR")"
fi
$DRY_RUN && echo "(dry-run mode — no project or home writes)"

if ! $ASSUME_YES && ! $DRY_RUN; then
  printf "Proceed? [y/N] "
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit "$AGGREGATE_FLOOR"; }
fi

overall="$AGGREGATE_FLOOR"
if [ "${#TARGET_ROWS[@]}" -gt 0 ]; then
  for row in "${TARGET_ROWS[@]}"; do
    if rollout_one "$row"; then
      :
    else
      rc="$?"
      [ "$rc" -le "$overall" ] || overall="$rc"
    fi
  done
fi

echo "== done =="
echo
echo "Per-project next steps:"
echo "  1. Edit the tracked .trellis.json presets array to select project presets."
echo "  2. Re-run this command after changing that manifest or adopting a new"
echo "     immutable release; only exact verified release payload links are pruned."
exit "$overall"
