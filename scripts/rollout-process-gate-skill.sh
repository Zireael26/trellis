#!/usr/bin/env bash
# Reconcile the process-gate release surface for locally attached worktrees.
#
# Normal ownership belongs to attach-project.sh: this consumer validates each
# strict local-registry row against its recorded immutable release, then asks
# the attachment relink flow to repair only a missing runtime anchor. It never
# creates skill links or writes project-local process-gate configuration.
#
# Usage:
#   rollout-process-gate-skill.sh                 # interactive, all local rows
#   rollout-process-gate-skill.sh --dry-run       # show plan only
#   rollout-process-gate-skill.sh --yes           # non-interactive
#   rollout-process-gate-skill.sh <fleet/id|id>   # one logical local project

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

if trellis_home_require_jq; then
  :
else
  rc=$?
  exit "$rc"
fi
if HOME_PATH="$(trellis_home_resolve "${TRELLIS_HOME:-}")"; then
  :
else
  rc=$?
  exit "$rc"
fi
TRELLIS_HOME="$HOME_PATH"
export TRELLIS_HOME

if REGISTRY_JSON="$(local_registry_list_json "$HOME_PATH")"; then
  :
else
  rc=$?
  echo "could not enumerate the strict local registry" >&2
  exit "$rc"
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
  local registry="$1" keys key key_count=0 selected_key="" rc

  if [ -z "$ONLY_PROJECT" ]; then
    printf '%s\n' "$registry" | jq -c '.entries[]'
    return 0
  fi

  if [[ "$ONLY_PROJECT" == */* ]]; then
    printf '%s\n' "$registry" |
      jq -c --arg project_key "$ONLY_PROJECT" '.entries[] | select(.project_key == $project_key)'
    return 0
  fi

  if keys="$(printf '%s\n' "$registry" |
    jq -r --arg project_id "$ONLY_PROJECT" '
      [.entries[] | select(.project_id == $project_id) | .project_key] | unique | .[]
    ')"; then
    :
  else
    rc=$?
    return "$rc"
  fi
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
if SELECTED_ROWS="$(select_rows "$REGISTRY_JSON")"; then
  AGGREGATE_FLOOR="$(registry_state_floor 0 "$SELECTED_ROWS")"
else
  rc=$?
  exit "$(registry_state_floor "$rc")"
fi

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
      .project_key == $key
      and .checkout_id == $checkout
      and .worktree_id == $worktree
      and .root == $root
    ' >/dev/null
}

row_owner_path() {
  local row="$1" checkout worktree
  checkout="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')"
  worktree="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')"
  [ -n "$checkout" ] && [ -n "$worktree" ] || return 1
  printf '%s/state/attachments/%s/%s.json\n' "$HOME_PATH" "$checkout" "$worktree"
}

owner_matches_row() {
  local owner="$1" row="$2" harnesses_json="$3" attachment fleet project_id release root
  attachment="$(printf '%s\n' "$row" | jq -r '.attachment_id // empty')"
  fleet="$(printf '%s\n' "$row" | jq -r '.fleet')"
  project_id="$(printf '%s\n' "$row" | jq -r '.project_id')"
  release="$(printf '%s\n' "$row" | jq -r '.release // empty')"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')"
  jq -e --arg attachment "$attachment" --arg fleet "$fleet" --arg project_id "$project_id" \
    --arg release "$release" --arg root "$root" --argjson harnesses "$harnesses_json" '
      .status == "committed"
      and .attachment_id == $attachment
      and .fleet == $fleet
      and .project_id == $project_id
      and .release == $release
      and .worktree_root == $root
      and (
        [.artifacts[]
          | if .path == "AGENTS.md"
              or (.path | startswith(".agents/"))
              or (.path | startswith(".codex/")) then "codex"
            elif .path | startswith(".claude/") then "claude"
            else empty
            end
        ] | unique | sort
      ) == $harnesses
    ' "$owner" >/dev/null 2>&1
}

plan_has_process_gate() {
  local plan="$1" harnesses="$2"
  printf '%s\n' "$plan" |
    jq -e --argjson harnesses "$harnesses" '
      .artifacts as $artifacts
      | all($harnesses[];
          if . == "claude" then
            [$artifacts[]
              | select(.harness == "claude"
                  and .kind == "symlink"
                  and .source == "core-rules/skills/process-gate"
                  and .destination == ".claude/skills/process-gate")]
            | length == 1
          elif . == "codex" then
            [$artifacts[]
              | select(.harness == "codex"
                  and .kind == "symlink"
                  and .source == "core-rules/skills/process-gate"
                  and .destination == ".agents/skills/process-gate")]
            | length == 1

          else false
          end
        )
    ' >/dev/null
}

rollout_one() {
  local row="$1" key project_id kind availability status excluded root release fleet attachment checkout_id worktree_id
  local harnesses_json harness_lines harness plan owner runtime actual rc verify_status relink_status expected_harnesses_json
  local -a harnesses=()

  key="$(printf '%s\n' "$row" | jq -r '.project_key')"
  project_id="$(printf '%s\n' "$row" | jq -r '.project_id')" || return "$TRELLIS_EX_STATE"
  kind="$(printf '%s\n' "$row" | jq -r '.kind')"
  availability="$(printf '%s\n' "$row" | jq -r '.availability')"
  status="$(printf '%s\n' "$row" | jq -r '.status')"
  excluded="$(printf '%s\n' "$row" | jq -r '.excluded')"
  root="$(printf '%s\n' "$row" | jq -r '.root // empty')"
  checkout_id="$(printf '%s\n' "$row" | jq -r '.checkout_id // empty')" || return "$TRELLIS_EX_STATE"
  worktree_id="$(printf '%s\n' "$row" | jq -r '.worktree_id // empty')" || return "$TRELLIS_EX_STATE"
  release="$(printf '%s\n' "$row" | jq -r '.release // empty')"
  fleet="$(printf '%s\n' "$row" | jq -r '.fleet')"
  attachment="$(printf '%s\n' "$row" | jq -r '.attachment_id // empty')"

  # identity_error is tested BEFORE the excluded skip: drift is a property of the
  # row's recorded identity, not of whether this run would have acted on it, so
  # an excluded row's drift must not be swallowed into an exit 0. Report-only —
  # the row is still never processed.
  if [ "$availability" = "identity_error" ]; then
    echo "error (registry row failed identity validation): $key → $(safe_display_root "${root:-<no local root>}")" >&2
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
  if [ "$status" != "active" ]; then
    echo "skip (inactive local row): $key"
    return 0
  fi
  if [ -z "$attachment" ]; then
    echo "skip (no attachment record; process-gate surfaces are attachment-managed): $key"
    return 0
  fi
  require_safe_display_path "$root" || return "$?"

  if resolved="$(local_registry_resolve_root "$TRELLIS_HOME" "$root")"; then
    :
  else
    rc=$?
    echo "error (row root no longer resolves through local registry; status $rc): $key → $root" >&2
    return "$rc"
  fi
  if row_identity_matches "$row" "$resolved"; then
    :
  else
    rc=$?
    echo "error (registry identity changed while resolving row; status $rc): $key → $root" >&2
    return "$TRELLIS_EX_STATE"
  fi

  if [ -z "$release" ]; then
    echo "error (row has no recorded release): $key → $root" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if release_dir="$(release_store_locate "$release")"; then
    :
  else
    rc=$?
    echo "error (recorded release is unavailable or invalid; status $rc): $key @ $release" >&2
    return "$rc"
  fi
  payload="$release_dir/payload"
  if [ ! -d "$payload" ] || [ -L "$payload" ]; then
    echo "error (verified release has no payload directory): $key @ $release" >&2
    return "$TRELLIS_EX_STATE"
  fi

  if harnesses_json="$(printf '%s\n' "$row" | jq -ce '.harnesses // []')"; then
    :
  else
    rc=$?
    echo "error (invalid row harnesses; status $rc): $key" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if harness_lines="$(printf '%s\n' "$harnesses_json" | jq -r '.[]')"; then
    :
  else
    rc=$?
    echo "error (invalid row harnesses; status $rc): $key" >&2
    return "$TRELLIS_EX_STATE"
  fi
  while IFS= read -r harness; do
    [ -n "$harness" ] || continue
    case "$harness" in
      claude|codex) harnesses+=("$harness") ;;
      *)
        echo "error (unsupported row harness '$harness'): $key" >&2
        return "$TRELLIS_EX_STATE"
        ;;
    esac
  done <<EOF
$harness_lines
EOF
  if [ "${#harnesses[@]}" -eq 0 ]; then
    echo "skip (row has no attached harnesses): $key"
    return 0
  fi
  expected_harnesses_json="$(jq -cn --args '$ARGS.positional' "${harnesses[@]}")" || return "$TRELLIS_EX_STATE"
  expected_harnesses_json="$(local_registry_normalize_harnesses "$expected_harnesses_json")" || return "$TRELLIS_EX_STATE"


  if plan="$(surface_plan_emit "$payload" "${harnesses[@]}")"; then
    :
  else
    rc=$?
    echo "error (release surface plan is invalid; status $rc): $key @ $release" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if plan_has_process_gate "$plan" "$expected_harnesses_json"; then
    :
  else
    rc=$?

    echo "error (process-gate has no exact planned artifact; status $rc): $key @ $release" >&2
    return "$TRELLIS_EX_STATE"
  fi

  echo "== $key =="
  echo "  release: $release (verified payload)"
  if [ -e "$root/.claude/skills/process-gate-local/local.config.sh" ] ||
     [ -L "$root/.claude/skills/process-gate-local/local.config.sh" ]; then
    echo "  info: project-owned process-gate local configuration left unchanged"
  fi

  if owner="$(row_owner_path "$row")"; then
    :
  else
    rc=$?
    echo "error (row has no attachment identity; status $rc): $key" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if [ ! -f "$owner" ] || [ -L "$owner" ]; then
    echo "error (recorded attachment ownership is unavailable): $key" >&2
    return "$TRELLIS_EX_STATE"
  fi
  if owner_matches_row "$owner" "$row" "$expected_harnesses_json"; then
    :
  else
    rc=$?
    echo "error (attachment ownership disagrees with the registry row; status $rc): $key" >&2
    return "$TRELLIS_EX_STATE"
  fi

  runtime="$root/.trellis/runtime"
  if $DRY_RUN; then
    if [ -L "$runtime" ]; then
      if actual="$(readlink "$runtime")"; then
        :
      else
        rc=$?
        echo "error (could not read attachment runtime anchor; status $rc): $key" >&2
        return "$TRELLIS_EX_STATE"
      fi
      if [ "$actual" = "$payload" ]; then
        echo "  skip (runtime anchor already selects the recorded release)"
      else
        echo "  skip (runtime anchor selects a different target; leaving attachment-owned surface unchanged)" >&2
      fi
    elif [ -e "$runtime" ]; then
      echo "  skip (runtime anchor is not a symlink; leaving attachment-owned surface unchanged)" >&2
    else
      echo "  + would reconcile missing attachment runtime anchor via attach-project relink"
    fi
    return 0
  fi

  if attachment_verify "$HOME_PATH" "$owner" >/dev/null 2>&1; then
    echo "  skip (attachment-managed process-gate surfaces already current)"
    return 0
  else
    verify_status=$?
  fi
  if [ -e "$runtime" ] || [ -L "$runtime" ]; then
    echo "  WARN: attachment verification failed (status $verify_status); leaving managed surfaces unchanged" >&2
    return "$verify_status"
  fi

  if "$SCRIPT_DIR/attach-project.sh" relink \
    --home "$HOME_PATH" \
    --fleet "$fleet" \
    --expected-fleet "$fleet" \
    --expected-project-id "$project_id" \
    --expected-root "$root" \
    --expected-checkout-id "$checkout_id" \
    --expected-worktree-id "$worktree_id" \
    --expected-attachment-id "$attachment" \
    --expected-release "$release" \
    --expected-harnesses-json "$expected_harnesses_json" \
    "$root"; then
    echo "  reconciled missing attachment runtime anchor"
    return 0
  else
    relink_status=$?
    echo "  WARN: attachment relink failed (status $relink_status); leaving managed surfaces unchanged" >&2
    return "$relink_status"
  fi
}

aggregate_status="$AGGREGATE_FLOOR"
if [ "${#ROWS[@]}" -gt 0 ]; then
  for row in "${ROWS[@]}"; do
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
exit "$aggregate_status"
