#!/usr/bin/env bash
# Compatibility-only SE Core → Trellis rule-link migration.
#
# Attached projects own their native rule surfaces through attach-project.sh and
# are deliberately out of scope here. For an unattached local-registry row this
# script recognizes only the historical se-core rule-link spelling, then
# retargets it to that row's verified immutable release payload. It never uses a
# mutable policy checkout as a link source and refuses unknown or foreign links.
#
# Usage:
#   rollout-rebrand.sh                 # interactive, all local rows
#   rollout-rebrand.sh --dry-run       # show plan only
#   rollout-rebrand.sh --yes           # non-interactive
#   rollout-rebrand.sh <fleet/id|id>   # one logical local project

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
DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""

usage() {
  sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
}

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --yes|-y) ASSUME_YES=true ;;
    --help|-h) usage; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; exit 2 ;;
    *)
      if [ -n "$ONLY_PROJECT" ]; then
        echo "only one project filter is allowed" >&2
        exit 2
      fi
      ONLY_PROJECT="$arg"
      ;;
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


trellis_home_require_jq || exit $?
HOME_PATH="$(trellis_home_resolve)" || exit $?

REGISTRY_JSON=""
REGISTRY_STATUS=0
REGISTRY_JSON="$(local_registry_list_json "$HOME_PATH")" || REGISTRY_STATUS=$?
if [ "$REGISTRY_STATUS" -ne 0 ]; then
  echo "could not enumerate the strict local registry" >&2
  exit "$REGISTRY_STATUS"
fi


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

select_rows() {
  local registry="$1" keys key key_count=0 selected_key=""

  if [ -z "$ONLY_PROJECT" ]; then
    printf '%s\n' "$registry" | jq -c '.entries[]'
    return
  fi
  if [[ "$ONLY_PROJECT" == */* ]]; then
    printf '%s\n' "$registry" |
      jq -c --arg project_key "$ONLY_PROJECT" '.entries[] | select(.project_key == $project_key)'
    return
  fi

  keys="$(printf '%s\n' "$registry" |
    jq -r --arg project_id "$ONLY_PROJECT" '
      [.entries[] | select(.project_id == $project_id) | .project_key] | unique | .[]
    ')" || return "$TRELLIS_EX_STATE"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    key_count=$((key_count + 1))
    selected_key="$key"
  done <<EOF
$keys
EOF
  if [ "$key_count" -eq 0 ]; then
    echo "project not in local registry: $ONLY_PROJECT" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ "$key_count" -gt 1 ]; then
    echo "ambiguous project ID '$ONLY_PROJECT'; use one of:" >&2
    while IFS= read -r key; do
      [ -n "$key" ] && echo "  $key" >&2
    done <<EOF
$keys
EOF
    return "$TRELLIS_EX_CONFLICT"
  fi
  printf '%s\n' "$registry" |
    jq -c --arg project_key "$selected_key" '.entries[] | select(.project_key == $project_key)'
}

SELECTED_ROWS=""
SELECT_STATUS=0
SELECTED_ROWS="$(select_rows "$REGISTRY_JSON")" || SELECT_STATUS=$?
if [ "$SELECT_STATUS" -ne 0 ]; then
  exit "$(registry_state_floor "$SELECT_STATUS")"
fi
AGGREGATE_FLOOR="$(registry_state_floor 0 "$SELECTED_ROWS")"

ROWS=()
while IFS= read -r row; do
  [ -n "$row" ] && ROWS+=("$row")
done <<EOF
$SELECTED_ROWS
EOF
if [ -n "$ONLY_PROJECT" ] && [ "${#ROWS[@]}" -eq 0 ]; then
  echo "project not in local registry: $ONLY_PROJECT" >&2
  exit "$(local_registry_max_class "$TRELLIS_EX_UNAVAILABLE" "$AGGREGATE_FLOOR")"
fi

echo "Targets:"
if [ "${#ROWS[@]}" -eq 0 ]; then
  echo "  (none)"
else
  for row in "${ROWS[@]}"; do
    key="$(printf '%s\n' "$row" | jq -r '.project_key')"
    kind="$(printf '%s\n' "$row" | jq -r '.kind')"
    availability="$(printf '%s\n' "$row" | jq -r '.availability')"
    root="$(printf '%s\n' "$row" | jq -r '.root // "(no root)"')"
    printf '  %s [%s, %s] %s\n' "$key" "$kind" "$availability" "$(safe_display_root "$root")"
  done
fi
$DRY_RUN && echo "(dry-run mode — no project or Trellis-home writes)"
if ! $ASSUME_YES && ! $DRY_RUN; then
  printf "Proceed? [y/N] "
  read -r ans
  [ "$ans" = "y" ] || [ "$ans" = "Y" ] || { echo "aborted"; exit "$AGGREGATE_FLOOR"; }
fi

row_identity_matches() {
  local row="$1" resolved="$2" key checkout worktree root
  key="$(printf '%s\n' "$row" | jq -r '.project_key')"
  checkout="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')"
  worktree="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')"
  printf '%s\n' "$resolved" |
    jq -e --arg key "$key" --arg checkout "$checkout" --arg worktree "$worktree" --arg root "$root" '
      .project_key == $key and .checkout_id == $checkout and .worktree_id == $worktree and .root == $root
    ' >/dev/null
}

row_is_current() {
  local row="$1" registry rc
  if registry="$(local_registry_list_json "$HOME_PATH")"; then
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


row_owner_path() {
  local row="$1" checkout worktree
  checkout="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')"
  worktree="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')"
  [ -n "$checkout" ] && [ -n "$worktree" ] || return 1
  printf '%s/state/attachments/%s/%s.json\n' "$HOME_PATH" "$checkout" "$worktree"
}

LEGACY_SOURCE_RULE=""

legacy_source_rule() {
  local config source rc

  if [ -n "$LEGACY_SOURCE_RULE" ]; then
    printf '%s\n' "$LEGACY_SOURCE_RULE"
    return 0
  fi
  config="$(trellis_home_config_path "$HOME_PATH")" || return "$?"
  if trellis_home_validate_config "$config"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  if source="$(jq -r '.source_root // empty' "$config")"; then
    :
  else
    return "$TRELLIS_EX_STATE"
  fi
  if [ -n "$source" ]; then
    :
  else
    return "$TRELLIS_EX_STATE"
  fi
  if trellis_home_require_absolute_safe_path "legacy source root" "$source"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  LEGACY_SOURCE_RULE="$source/core-rules/CLAUDE.md"
  printf '%s\n' "$LEGACY_SOURCE_RULE"
}

known_legacy_target() {
  local target="$1" payload_rule="$2" source_rule rc

  [ "$target" = "$payload_rule" ] && return 0
  if source_rule="$(legacy_source_rule)"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  [ "$target" = "$source_rule" ]
}

enter_rule_parent() {
  local root="$1" subdir="$2" expected component

  if [ -d "$root" ] && [ ! -L "$root" ]; then
    :
  else
    echo "  ERROR: project root is not a real directory" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if cd -P -- "$root"; then
    :
  else
    echo "  ERROR: cannot enter project root for compatibility migration" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ "$PWD" = "$root" ]; then
    :
  else
    echo "  ERROR: project root changed while preparing compatibility migration" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  for component in "$subdir" rules; do
    expected="$PWD/$component"
    if [ -d "$component" ] && [ ! -L "$component" ]; then
      :
    else
      echo "  ERROR: $subdir/rules is not a real project-owned directory" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    if cd -P -- "$component"; then
      :
    else
      echo "  ERROR: cannot enter $subdir/rules for compatibility migration" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    if [ "$PWD" = "$expected" ]; then
      :
    else
      echo "  ERROR: $subdir/rules changed while preparing compatibility migration" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
  done
}

stage_rule_link() {
  local target="$1" stage

  stage=".trellis-rebrand.$$.tmp"
  if [ -e "$stage" ] || [ -L "$stage" ]; then
    echo "  ERROR: rebrand staging path already exists" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if ln -s "$target" "$stage"; then
    printf '%s\n' "$stage"
  else
    echo "  ERROR: could not stage rebrand link" >&2
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
}

retarget_known_link() {
  local link="$1" target="$2" expected="$3" payload_rule="$4" label="$5"
  local stage current rc

  if stage="$(stage_rule_link "$target")"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  if [ -L "$link" ] && current="$(readlink "$link")" && [ "$current" = "$expected" ]; then
    :
  else
    rm -f "$stage" || true
    echo "  ERROR: $label changed during compatibility migration — leaving" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if known_legacy_target "$current" "$payload_rule"; then
    :
  else
    rc=$?
    rm -f "$stage" || true
    if [ "$rc" -eq 1 ]; then
      echo "  ERROR: $label no longer targets a recognized legacy source — leaving" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    echo "  ERROR: cannot establish legacy source provenance for $label" >&2
    return "$rc"
  fi
  if mv -f "$stage" "$link"; then
    return 0
  fi
  rc=$?
  rm -f "$stage" || true
  echo "  ERROR: could not atomically retarget $label" >&2
  return "$rc"
}

remove_known_link() {
  local link="$1" expected="$2" payload_rule="$3" label="$4" current rc

  if [ -L "$link" ] && current="$(readlink "$link")" && [ "$current" = "$expected" ]; then
    :
  else
    echo "  ERROR: $label changed during compatibility migration — leaving" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if known_legacy_target "$current" "$payload_rule"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      echo "  ERROR: $label no longer targets a recognized legacy source — leaving" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    echo "  ERROR: cannot establish legacy source provenance for $label" >&2
    return "$rc"
  fi
  if rm "$link"; then
    return 0
  fi
  echo "  ERROR: could not remove known legacy $label" >&2
  return "$TRELLIS_EX_UNAVAILABLE"
}

migrate_harness() (
  local root="$1" harness="$2" subdir="$3" plan="$4" payload_rule="$5"
  local fresh="trellis.md" legacy="se-core.md" fresh_label legacy_label
  local fresh_target="" legacy_target="" fresh_present=false legacy_present=false stage rc

  fresh_label="$subdir/rules/$fresh"
  legacy_label="$subdir/rules/$legacy"
  if [ ! -e "$root/$fresh_label" ] && [ ! -L "$root/$fresh_label" ] &&
     [ ! -e "$root/$legacy_label" ] && [ ! -L "$root/$legacy_label" ]; then
    echo "  info: no legacy $subdir rule links"
    return 0
  fi
  if enter_rule_parent "$root" "$subdir"; then
    :
  else
    rc=$?
    return "$rc"
  fi
  if [ -e "$fresh" ] || [ -L "$fresh" ]; then fresh_present=true; fi
  if [ -e "$legacy" ] || [ -L "$legacy" ]; then legacy_present=true; fi
  if ! $fresh_present && ! $legacy_present; then
    echo "  info: no legacy $subdir rule links"
    return 0
  fi
  if plan_has_rule_surface "$plan" "$harness" "$fresh_label"; then
    :
  else
    echo "  ERROR: verified release does not plan $fresh_label" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if $legacy_present; then
    if [ -L "$legacy" ]; then
      :
    else
      echo "  ERROR: $legacy_label is not a symlink" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    if legacy_target="$(readlink "$legacy")"; then
      :
    else
      echo "  ERROR: could not read $legacy_label" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    if known_legacy_target "$legacy_target" "$payload_rule"; then
      :
    else
      rc=$?
      if [ "$rc" -eq 1 ]; then
        echo "  ERROR: $legacy_label targets an unknown or foreign location" >&2
        return "$TRELLIS_EX_CONFLICT"
      fi
      echo "  ERROR: cannot establish legacy source provenance for $legacy_label" >&2
      return "$rc"
    fi
  fi
  if $fresh_present; then
    if [ -L "$fresh" ]; then
      :
    else
      echo "  ERROR: $fresh_label is not a symlink" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    if fresh_target="$(readlink "$fresh")"; then
      :
    else
      echo "  ERROR: could not read $fresh_label" >&2
      return "$TRELLIS_EX_UNAVAILABLE"
    fi
    if known_legacy_target "$fresh_target" "$payload_rule"; then
      :
    else
      rc=$?
      if [ "$rc" -eq 1 ]; then
        echo "  ERROR: $fresh_label targets an unknown or foreign location" >&2
        return "$TRELLIS_EX_CONFLICT"
      fi
      echo "  ERROR: cannot establish legacy source provenance for $fresh_label" >&2
      return "$rc"
    fi
  fi

  if ! $fresh_present; then
    if $DRY_RUN; then
      echo "  + would link: $fresh_label → verified release payload"
      echo "  + would remove known legacy: $legacy_label"
      return 0
    fi
    if stage="$(stage_rule_link "$payload_rule")"; then
      :
    else
      rc=$?
      return "$rc"
    fi
    if [ -e "$fresh" ] || [ -L "$fresh" ]; then
      rm -f "$stage" || true
      echo "  ERROR: $fresh_label changed during compatibility migration — leaving" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    if mv -f "$stage" "$fresh"; then
      :
    else
      rc=$?
      rm -f "$stage" || true
      echo "  ERROR: could not atomically create $fresh_label" >&2
      return "$rc"
    fi
    if remove_known_link "$legacy" "$legacy_target" "$payload_rule" "$legacy_label"; then
      echo "  migrated: $fresh_label → verified release payload; removed known legacy se-core.md"
      return 0
    fi
    rc=$?
    return "$rc"
  fi

  if [ "$fresh_target" != "$payload_rule" ]; then
    if $DRY_RUN; then
      echo "  + would retarget known legacy: $fresh_label → verified release payload"
    else
      if retarget_known_link "$fresh" "$payload_rule" "$fresh_target" "$payload_rule" "$fresh_label"; then
        echo "  retargeted: $fresh_label → verified release payload"
      else
        rc=$?
        return "$rc"
      fi
    fi
  fi
  if $legacy_present; then
    if $DRY_RUN; then
      echo "  + would remove known legacy: $legacy_label"
      return 0
    fi
    if remove_known_link "$legacy" "$legacy_target" "$payload_rule" "$legacy_label"; then
      echo "  removed known legacy: $legacy_label"
      return 0
    fi
    rc=$?
    return "$rc"
  fi
  echo "  skip (already rebranded): $fresh_label"
  return 0
)

rollout_one() (
  local row="$1" key kind availability status excluded root release attachment resolved release_dir payload payload_rule
  local harnesses_json plan owner rc row_status=0 checkout_id common
  local -a harnesses=()

  key="$(printf '%s\n' "$row" | jq -r '.project_key')" || return "$TRELLIS_EX_STATE"
  kind="$(printf '%s\n' "$row" | jq -r '.kind')" || return "$TRELLIS_EX_STATE"
  availability="$(printf '%s\n' "$row" | jq -r '.availability')" || return "$TRELLIS_EX_STATE"
  status="$(printf '%s\n' "$row" | jq -r '.status')" || return "$TRELLIS_EX_STATE"
  excluded="$(printf '%s\n' "$row" | jq -r '.excluded // false')" || return "$TRELLIS_EX_STATE"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')" || return "$TRELLIS_EX_STATE"
  release="$(printf '%s\n' "$row" | jq -r '.release // empty')" || return "$TRELLIS_EX_STATE"
  attachment="$(printf '%s\n' "$row" | jq -r '.attachment_id // empty')" || return "$TRELLIS_EX_STATE"

  # identity_error is tested BEFORE the excluded skip: drift is a property of the
  # row's recorded identity, not of whether this run would have acted on it, so
  # an excluded row's drift must not be swallowed into an exit 0. Report-only —
  # the row is still never processed.
  if [ "$availability" = "identity_error" ]; then
    echo "ERROR: registry row failed identity validation: $key → $(safe_display_root "${root:-<no local root>}")" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ "$excluded" = true ]; then
    echo "skip (excluded local row): $key"
    return 0
  fi
  if [ "$availability" != "available" ]; then
    printf 'skip (unavailable local row): %s → %s\n' "$key" "$(safe_display_root "${root:-<no local root>}")"
    return 0
  fi
  if [ "$kind" != "worktree" ] || [ -z "$root" ]; then
    echo "skip (no available worktree row): $key"
    return 0
  fi
  if [ "$status" != active ]; then
    echo "skip (ineligible registry status: $status): $key"
    return 0
  fi
  if [ -n "$attachment" ]; then
    echo "skip (attached row; rebrand never alters attachment-owned surfaces): $key"
    return 0
  fi
  require_safe_display_path "$root" || return "$?"
  if [ -z "$release" ]; then
    echo "ERROR: active row has no recorded immutable release: $key" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if resolved="$(local_registry_resolve_root "$HOME_PATH" "$root")"; then
    :
  else
    rc=$?
    echo "ERROR: active row root no longer resolves through local registry: $key → $root" >&2
    return "$rc"
  fi
  if row_identity_matches "$row" "$resolved"; then
    :
  else
    echo "ERROR: local registry identity changed while resolving row: $key" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ -e "$root/.trellis/runtime" ] || [ -L "$root/.trellis/runtime" ]; then
    echo "skip (runtime anchor exists; rebrand never alters attachment-owned surfaces): $key"
    return 0
  fi
  if owner="$(row_owner_path "$row")"; then
    if [ -e "$owner" ] || [ -L "$owner" ]; then
      echo "skip (attachment ownership record exists; rebrand refuses attached state): $key" >&2
      return 0
    fi
  else
    echo "ERROR: cannot derive attachment ownership path for active row: $key" >&2
    return "$TRELLIS_EX_STATE"
  fi

  harnesses_json="$(printf '%s\n' "$row" | jq -c '.harnesses // []')" || return "$TRELLIS_EX_STATE"
  if printf '%s\n' "$harnesses_json" | jq -e 'index("claude") != null' >/dev/null; then
    harnesses+=("claude")
  fi
  if printf '%s\n' "$harnesses_json" | jq -e 'index("codex") != null' >/dev/null; then
    harnesses+=("codex")
  fi
  if [ "${#harnesses[@]}" -eq 0 ]; then
    echo "skip (row has no Claude or Codex compatibility surface): $key"
    return 0
  fi
  if release_dir="$(TRELLIS_HOME="$HOME_PATH" release_store_locate "$release")"; then
    :
  else
    rc=$?
    echo "ERROR: recorded release is unavailable or invalid: $key @ $release" >&2
    return "$rc"
  fi
  payload="$release_dir/payload"
  payload_rule="$payload/core-rules/CLAUDE.md"
  if [ -f "$payload_rule" ] && [ ! -L "$payload_rule" ]; then
    :
  else
    echo "ERROR: verified release lacks a real core rule source: $key @ $release" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if plan="$(surface_plan_emit "$payload" "${harnesses[@]}")"; then
    :
  else
    echo "ERROR: release surface plan is invalid: $key @ $release" >&2
    return "$TRELLIS_EX_STATE"
  fi
  checkout_id="$(printf '%s\n' "$resolved" | jq -r '.checkout_id // empty')" || return "$TRELLIS_EX_STATE"
  common="$(printf '%s\n' "$resolved" | jq -r '.git_common_dir // empty')" || return "$TRELLIS_EX_STATE"
  if [ -z "$checkout_id" ] || [ -z "$common" ]; then
    echo "ERROR: active row has no checkout lock identity: $key" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if ! $DRY_RUN; then
  if attachment_checkout_lock_reclaim "$HOME_PATH" "$checkout_id" "$common"; then
    :
  else
    rc=$?
    echo "ERROR: could not reclaim checkout lock for compatibility migration: $key" >&2
    return "$rc"
  fi
  if attachment_checkout_lock_acquire "$HOME_PATH" "$checkout_id" "$common"; then
    :
  else
    rc=$?
    echo "ERROR: checkout is busy; compatibility migration was not applied: $key" >&2
    return "$rc"
  fi
  _attachment_install_checkout_lock_traps
  if row_is_current "$row"; then
    :
  else
    rc=$?
    if [ "$rc" -eq 1 ]; then
      echo "ERROR: registry row changed while waiting for compatibility migration: $key" >&2
      return "$TRELLIS_EX_CONFLICT"
    fi
    return "$rc"
  fi
  if resolved="$(local_registry_resolve_root "$HOME_PATH" "$root")"; then
    :
  else
    rc=$?
    echo "ERROR: active row root no longer resolves while locked: $key" >&2
    return "$rc"
  fi
  if row_identity_matches "$row" "$resolved"; then
    :
  else
    echo "ERROR: local registry identity changed while waiting for compatibility migration: $key" >&2
    return "$TRELLIS_EX_CONFLICT"
  fi
  if [ -n "$attachment" ] ||
     [ -e "$root/.trellis/runtime" ] || [ -L "$root/.trellis/runtime" ] ||
     [ -e "$owner" ] || [ -L "$owner" ]; then
    echo "skip (attachment state appeared while waiting; rebrand leaves managed surfaces unchanged): $key"
    return 0
  fi
  fi


  echo "== $key =="
  echo "  release: $release (verified payload; compatibility-only)"
  for harness in "${harnesses[@]}"; do
    case "$harness" in
      claude)
        if migrate_harness "$root" "claude" ".claude" "$plan" "$payload_rule"; then
          :
        else
          rc="$?"
          [ "$rc" -le "$row_status" ] || row_status="$rc"
        fi
        ;;
      codex)
        if migrate_harness "$root" "codex" ".agents" "$plan" "$payload_rule"; then
          :
        else
          rc="$?"
          [ "$rc" -le "$row_status" ] || row_status="$rc"
        fi
        ;;
    esac
  done
  return "$row_status"
)

overall="$AGGREGATE_FLOOR"
if [ "${#ROWS[@]}" -gt 0 ]; then
  for row in "${ROWS[@]}"; do
    if rollout_one "$row"; then
      :
    else
      rc="$?"
      [ "$rc" -le "$overall" ] || overall="$rc"
    fi
  done
fi

echo "== done =="
exit "$overall"
