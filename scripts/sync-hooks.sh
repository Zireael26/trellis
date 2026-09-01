#!/usr/bin/env bash
# Reconcile one attached harness across a local fleet.
#
# This command never derives a checkout from tracked policy and never copies a
# hook or settings file from the mutable checkout that launched it. Each
# mutation is delegated to the verified immutable active-release reconciler
# after strict registry identity and committed attachment ownership checks.
#
# sync-codex-hooks.sh invokes this program with TRELLIS_SYNC_HARNESS=codex.

set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
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

SYNC_HARNESS="${TRELLIS_SYNC_HARNESS:-claude}"
SYNC_NAME="${TRELLIS_SYNC_NAME:-sync-hooks.sh}"

# Bash's %q emits a one-line terminal-safe representation: control bytes become
# visible escapes rather than terminal instructions. Keep every dynamic
# diagnostic behind this boundary, including captured child-process output.
diagnostic_escape() {
  LC_ALL=C printf '%q' "${1-}"
}

case "$SYNC_HARNESS" in
  claude) SYNC_LABEL="Claude hooks" ;;
  codex) SYNC_LABEL="Codex hooks" ;;
  *)
    printf '%s: unsupported attached harness: %s\n' \
      "$(diagnostic_escape "$SYNC_NAME")" "$(diagnostic_escape "$SYNC_HARNESS")" >&2
    exit "$TRELLIS_EX_USAGE"
    ;;
esac

usage() {
  printf 'Usage: %s [--home PATH] [--fleet NAME] [--dry-run] [--yes] [PROJECT_ID]\n' \
    "$(diagnostic_escape "$SYNC_NAME")"
  printf '       %s --from-main-only [--home PATH] [--fleet NAME] [--dry-run] [--yes] [PROJECT_ID]\n' \
    "$(diagnostic_escape "$SYNC_NAME")"
  cat <<EOF

Reconciles the locally attached $SYNC_LABEL surface through the recorded
immutable release. PROJECT_ID selects all registered worktrees for that project
in the selected fleet. Without PROJECT_ID, every row in that fleet is examined.

Unavailable, excluded, legacy, and unattached rows are reported and never
mutated. --dry-run reports attachment relinks without invoking them.
EOF
}

DRY_RUN=false
ASSUME_YES=false
ONLY_PROJECT=""
FROM_MAIN_ONLY=false
HOME_OPT=""
FLEET_OPT=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || {
        printf '%s: --home requires PATH\n' "$(diagnostic_escape "$SYNC_NAME")" >&2
        exit "$TRELLIS_EX_USAGE"
      }
      HOME_OPT="$2"
      shift 2
      ;;
    --fleet)
      [ "$#" -ge 2 ] || {
        printf '%s: --fleet requires NAME\n' "$(diagnostic_escape "$SYNC_NAME")" >&2
        exit "$TRELLIS_EX_USAGE"
      }
      FLEET_OPT="$2"
      shift 2
      ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes|-y) ASSUME_YES=true; shift ;;
    --from-main-only) FROM_MAIN_ONLY=true; shift ;;
    --help|-h) usage; exit 0 ;;
    --)
      shift
      [ "$#" -le 1 ] || {
        printf '%s: accepts at most one PROJECT_ID\n' "$(diagnostic_escape "$SYNC_NAME")" >&2
        exit "$TRELLIS_EX_USAGE"
      }
      if [ "$#" -eq 1 ]; then ONLY_PROJECT="$1"; fi
      break
      ;;
    -*)
      printf '%s: unknown option: %s\n' \
        "$(diagnostic_escape "$SYNC_NAME")" "$(diagnostic_escape "$1")" >&2
      exit "$TRELLIS_EX_USAGE"
      ;;
    *)
      [ -z "$ONLY_PROJECT" ] || {
        printf '%s: accepts at most one PROJECT_ID\n' "$(diagnostic_escape "$SYNC_NAME")" >&2
        exit "$TRELLIS_EX_USAGE"
      }
      ONLY_PROJECT="$1"
      shift
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || {
  printf '%s: jq is required for local registry reconciliation\n' \
    "$(diagnostic_escape "$SYNC_NAME")" >&2
  exit "$TRELLIS_EX_UNAVAILABLE"
}

if HOME_PATH="$(trellis_home_resolve "$HOME_OPT" 2>/dev/null)"; then
  :
else
  rc=$?
  printf '%s: could not resolve local Trellis home\n' "$(diagnostic_escape "$SYNC_NAME")" >&2
  exit "$rc"
fi
CONFIG_PATH="$(trellis_home_config_path "$HOME_PATH")"
if FLEET="$(trellis_home_resolve_fleet "$FLEET_OPT" "$CONFIG_PATH" 2>/dev/null)"; then
  :
else
  rc=$?
  printf '%s: could not resolve local fleet\n' "$(diagnostic_escape "$SYNC_NAME")" >&2
  exit "$rc"
fi
export TRELLIS_HOME="$HOME_PATH"

# Keep the historical --from-main-only safety switch. It guards only the
# synchronizer program now: all project payloads are resolved from releases.
PROGRAM_ROOT="$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)"
if command -v git >/dev/null 2>&1 &&
   git -C "$PROGRAM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  PROGRAM_GIT_DIR="$(git -C "$PROGRAM_ROOT" rev-parse --git-dir 2>/dev/null || true)"
  case "$PROGRAM_GIT_DIR" in
    */worktrees/*)
      if $FROM_MAIN_ONLY; then
        printf '%s: refusing to run from a linked git worktree with --from-main-only\n' \
          "$(diagnostic_escape "$SYNC_NAME")" >&2
        exit 1
      fi
      ;;
  esac
  if $FROM_MAIN_ONLY && ! git -C "$PROGRAM_ROOT" symbolic-ref -q HEAD >/dev/null 2>&1; then
    printf '%s: refusing to run with a detached program HEAD and --from-main-only\n' \
      "$(diagnostic_escape "$SYNC_NAME")" >&2
    exit 1
  fi
fi

SNAPSHOT="$(mktemp "${TMPDIR:-/tmp}/trellis.sync-registry.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
TARGETS="$(mktemp "${TMPDIR:-/tmp}/trellis.sync-targets.XXXXXX")" || {
  rm -f "$SNAPSHOT"
  exit "$TRELLIS_EX_UNAVAILABLE"
}
ACTIVE_REPAIR_SNAPSHOT=""
ACTIVE_REPAIR_RELEASE_DIGEST=""
ACTIVE_REPAIR_RELEASE_VERSION=""

cleanup_sync() {
  local status="${1:-0}" cleanup_output cleanup_rc=0
  rm -f "$SNAPSHOT" "$TARGETS"
  if [ -n "$ACTIVE_REPAIR_SNAPSHOT" ]; then
    if cleanup_output="$(TRELLIS_HOME="$HOME_PATH" \
        release_store_remove_snapshot "$ACTIVE_REPAIR_SNAPSHOT" \
          "$ACTIVE_REPAIR_RELEASE_VERSION" 2>&1)"; then
      :
    else
      cleanup_rc=$?
    fi
  elif [ -n "$ACTIVE_REPAIR_RELEASE_VERSION" ]; then
    if cleanup_output="$(TRELLIS_HOME="$HOME_PATH" \
        release_store_remove_owned_snapshots \
          "$ACTIVE_REPAIR_RELEASE_VERSION" 2>&1)"; then
      :
    else
      cleanup_rc=$?
    fi
  fi
  if [ "$cleanup_rc" -ne 0 ]; then
    printf '  WARN: active immutable execution snapshot cleanup failed (%s): %s\n' \
      "$cleanup_rc" "$(diagnostic_escape "${cleanup_output:-no diagnostic}")" >&2
    if [ "$cleanup_rc" -gt "${RESULT_STATUS:-0}" ]; then
      RESULT_STATUS="$cleanup_rc"
    fi
  fi
  ACTIVE_REPAIR_SNAPSHOT=""
  ACTIVE_REPAIR_RELEASE_DIGEST=""
  ACTIVE_REPAIR_RELEASE_VERSION=""
  trap - EXIT HUP INT TERM
  if [ "${RESULT_STATUS:-0}" -gt "$status" ]; then
    status="$RESULT_STATUS"
  fi
  exit "$status"
}

trap 'cleanup_sync "$?"' EXIT
trap 'cleanup_sync 129' HUP
trap 'cleanup_sync 130' INT
trap 'cleanup_sync 143' TERM

if local_registry_list_json "$HOME_PATH" "$FLEET" > "$SNAPSHOT" 2>/dev/null; then
  :
else
  rc=$?
  printf '%s: could not read strict local registry for fleet %s\n' \
    "$(diagnostic_escape "$SYNC_NAME")" "$(diagnostic_escape "$FLEET")" >&2
  exit "$rc"
fi

# The aggregate is armed BEFORE the selection so that every exit path below —
# including the preflight "project not in this fleet" refusal — is floored by
# whatever the FULL listing already proved about registry state.
RESULT_STATUS=0

record_failure() {
  local status="$1"
  if [ "$status" -gt "$RESULT_STATUS" ]; then
    RESULT_STATUS="$status"
  fi
}

if [ -n "$ONLY_PROJECT" ]; then
  jq -c --arg project_id "$ONLY_PROJECT" \
    '.entries[] | select(.project_id == $project_id)' "$SNAPSHOT" > "$TARGETS"
else
  jq -c '.entries[]' "$SNAPSHOT" > "$TARGETS"
fi

# A registry state error is a property of the REGISTRY, not of the selection.
# `sync_one` reports the drifted rows this run would have visited; the rows the
# `--project` filter just removed are reported here instead, from the full
# fleet listing, so a scoped run over a healthy project can never exit 0 (or on
# a lower preflight class) over a registry it has been shown to be corrupt.
# Unscoped, every row is selected and this reports nothing.
if local_registry_report_unselected_state_errors "$(cat "$SNAPSHOT")" "$(cat "$TARGETS")"; then
  :
else
  record_failure "$?"
fi

TARGET_COUNT="$(wc -l < "$TARGETS" | tr -d ' ')"
if [ "$TARGET_COUNT" -eq 0 ] && [ -n "$ONLY_PROJECT" ]; then
  printf '%s: project not in local registry fleet %s: %s\n' \
    "$(diagnostic_escape "$SYNC_NAME")" "$(diagnostic_escape "$FLEET")" \
    "$(diagnostic_escape "$ONLY_PROJECT")" >&2
  exit 1
fi

printf 'Trellis home: %s\nFleet: %s\nTargets: %s\n' \
  "$(diagnostic_escape "$HOME_PATH")" "$(diagnostic_escape "$FLEET")" "$TARGET_COUNT"
$DRY_RUN && printf '%s\n' '(dry-run mode - attachment state is not changed)'

if ! $ASSUME_YES && ! $DRY_RUN && [ "$TARGET_COUNT" -gt 0 ]; then
  printf 'Proceed? [y/N] '
  read -r answer
  [ "$answer" = y ] || [ "$answer" = Y ] || {
    printf '%s\n' 'aborted'
    exit 0
  }
fi

RELINK_SUCCEEDED=false

row_is_legacy() {
  printf '%s\n' "$1" | jq -e '.metadata.legacy? != null' >/dev/null 2>&1
}

row_matches_resolved_root() {
  local row="$1" resolution="$2"
  jq -e \
    --arg fleet "$(printf '%s\n' "$row" | jq -r '.fleet' 2>/dev/null)" \
    --arg project_id "$(printf '%s\n' "$row" | jq -r '.project_id' 2>/dev/null)" \
    --arg root "$(printf '%s\n' "$row" | jq -r '.root // empty' 2>/dev/null)" \
    --arg checkout_id "$(printf '%s\n' "$row" | jq -r '.checkout_id // empty' 2>/dev/null)" \
    --arg worktree_id "$(printf '%s\n' "$row" | jq -r '.worktree_id // empty' 2>/dev/null)" '
      .fleet == $fleet and .project_id == $project_id and .root == $root
      and .checkout_id == $checkout_id and .worktree_id == $worktree_id
    ' <<<"$resolution" >/dev/null 2>&1
}

owner_harnesses_json() {
  jq -ce '
    def attachment_harness($path):
      if $path == "AGENTS.md" or ($path | startswith(".agents/")) or ($path | startswith(".codex/"))
      then "codex"
      elif ($path | startswith(".claude/")) then "claude"
      elif ($path | startswith(".omp/")) then "omp"
      else empty end;
    [.artifacts[] | attachment_harness(.path)] | unique | sort
  ' "$1" 2>/dev/null
}

owner_matches_row() {
  local owner="$1" row="$2" row_harnesses owner_harnesses
  if row_harnesses="$(printf '%s\n' "$row" | jq -c '.harnesses // []' 2>/dev/null)"; then
    :
  else
    return 1
  fi
  if row_harnesses="$(local_registry_normalize_harnesses "$row_harnesses" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  if owner_harnesses="$(owner_harnesses_json "$owner")"; then
    :
  else
    return 1
  fi
  [ "$owner_harnesses" = "$row_harnesses" ] || return 1

  jq -e \
    --arg fleet "$(printf '%s\n' "$row" | jq -r '.fleet' 2>/dev/null)" \
    --arg project_id "$(printf '%s\n' "$row" | jq -r '.project_id' 2>/dev/null)" \
    --arg root "$(printf '%s\n' "$row" | jq -r '.root // empty' 2>/dev/null)" \
    --arg checkout_id "$(printf '%s\n' "$row" | jq -r '.checkout_id // empty' 2>/dev/null)" \
    --arg worktree_id "$(printf '%s\n' "$row" | jq -r '.worktree_id // empty' 2>/dev/null)" \
    --arg attachment_id "$(printf '%s\n' "$row" | jq -r '.attachment_id // empty' 2>/dev/null)" \
    --arg release "$(printf '%s\n' "$row" | jq -r '.release // empty' 2>/dev/null)" '
      .status == "committed"
      and .fleet == $fleet and .project_id == $project_id
      and .project_root == $root and .worktree_root == $root
      and .checkout_id == $checkout_id and .worktree_id == $worktree_id
      and .attachment_id == $attachment_id and .release == $release
    ' "$owner" >/dev/null 2>&1
}

plan_has_attached_leaves() {
  jq -e '.artifacts | length > 0' <<<"$1" >/dev/null 2>&1
}

# Clear partial bundle state and recover any snapshot stranded before the
# command-substitution caller could record its returned path.
active_cli_repair_bundle_fail() {
  local status="${1:-$TRELLIS_EX_STATE}" version="${2:-}" cleanup_output cleanup_rc=0
  if [ -n "$version" ]; then
    if cleanup_output="$(TRELLIS_HOME="$HOME_PATH" \
        release_store_remove_owned_snapshots "$version" 2>&1)"; then
      :
    else
      cleanup_rc=$?
      printf '  WARN: active immutable execution snapshot cleanup failed (%s): %s\n' \
        "$cleanup_rc" "$(diagnostic_escape "${cleanup_output:-no diagnostic}")" >&2
    fi
  fi
  ACTIVE_REPAIR_SNAPSHOT=""
  ACTIVE_REPAIR_RELEASE_DIGEST=""
  ACTIVE_REPAIR_RELEASE_VERSION=""
  if [ "$cleanup_rc" -gt "$status" ]; then
    status="$cleanup_rc"
  fi
  return "$status"
}

# Resolve one private snapshot record from the active installed release. The
# only later consumer of its pathname is the verified in-memory bundle emitter;
# no snapshot path is ever executed directly.
active_cli_repair_bundle() {
  local active_release version record snapshot digest rc
  if [ -n "$ACTIVE_REPAIR_SNAPSHOT" ] && [ -n "$ACTIVE_REPAIR_RELEASE_DIGEST" ] &&
     [ -n "$ACTIVE_REPAIR_RELEASE_VERSION" ]; then
    return 0
  fi
  if [ -n "$ACTIVE_REPAIR_SNAPSHOT" ] || [ -n "$ACTIVE_REPAIR_RELEASE_DIGEST" ] ||
     [ -n "$ACTIVE_REPAIR_RELEASE_VERSION" ]; then
    return "$TRELLIS_EX_STATE"
  fi
  trellis_home_validate_config "$CONFIG_PATH" >/dev/null 2>&1 || return "$TRELLIS_EX_STATE"
  if active_release="$(jq -er '.active_cli_release' "$CONFIG_PATH" 2>/dev/null)"; then
    :
  else
    return "$TRELLIS_EX_STATE"
  fi
  # The snapshot the store seals is named for the NORMALIZED version (a leading
  # `v` is stripped), and every later gate on that name — cleanup and bundle
  # emission — binds the name to the version it is handed. Normalize here so the
  # two agree; the same call inside the store is what decides the name.
  if version="$(release_store_normalize_version "$active_release" 2>/dev/null)"; then
    :
  else
    return "$TRELLIS_EX_STATE"
  fi
  # Arm the release-version cleanup context before command substitution starts.
  # The producer records the owning shell in its sidecar; cleanup can recover
  # that exact snapshot if the substitution returns during a signal handoff.
  ACTIVE_REPAIR_RELEASE_VERSION="$version"
  if record="$(TRELLIS_HOME="$HOME_PATH" \
      release_store_snapshot_verified_release "$active_release" 2>/dev/null)"; then
    :
  else
    rc=$?
    active_cli_repair_bundle_fail "$rc" "$version"
    return $?
  fi
  case "$record" in
    *$'\t'*)
      snapshot="${record%%$'\t'*}"
      digest="${record#*$'\t'}"
      ;;
    *)
      active_cli_repair_bundle_fail "$TRELLIS_EX_STATE" "$version"
      return $?
      ;;
  esac
  if [ -z "$snapshot" ] || ! release_store_absolute_path_is_clean "$snapshot"; then
    active_cli_repair_bundle_fail "$TRELLIS_EX_STATE" "$version"
    return $?
  fi
  case "$digest" in
    ''|*[!0-9a-f]*|*$'\t'*|*$'\r'*|*$'\n'*)
      active_cli_repair_bundle_fail "$TRELLIS_EX_STATE" "$version"
      return $?
      ;;
  esac
  if [ "${#digest}" -ne 64 ]; then
    active_cli_repair_bundle_fail "$TRELLIS_EX_STATE" "$version"
    return $?
  fi
  ACTIVE_REPAIR_SNAPSHOT="$snapshot"
  ACTIVE_REPAIR_RELEASE_DIGEST="$digest"
  ACTIVE_REPAIR_RELEASE_VERSION="$version"
  return 0
}

relink_one() {
  local root="$1" label="$2" fleet="$3" project_id="$4" checkout_id="$5"
  local worktree_id="$6" attachment_id="$7" release="$8" harnesses="$9"
  local output rc
  local -a binding_args=(
    --expected-fleet "$fleet"
    --expected-project-id "$project_id"
    --expected-root "$root"
    --expected-checkout-id "$checkout_id"
    --expected-worktree-id "$worktree_id"
    --expected-attachment-id "$attachment_id"
    --expected-release "$release"
    --expected-harnesses-json "$harnesses"
  )

  RELINK_SUCCEEDED=false
  if $DRY_RUN; then
    printf '  ~ would reconcile attachment through relink: %s\n' "$(diagnostic_escape "$label")"
    return 0
  fi

  if active_cli_repair_bundle; then
    :
  else
    rc=$?
    printf '  WARN: active immutable repair bundle is unavailable (%s)\n' "$rc" >&2
    record_failure "$rc"
    return 0
  fi

  printf '%s\n' '  ~ reconciling attachment through relink'
  if output="$(
    set -o pipefail
    {
      TRELLIS_HOME="$HOME_PATH" \
        release_store_emit_verified_attachment_bundle \
          "$ACTIVE_REPAIR_SNAPSHOT" "$ACTIVE_REPAIR_RELEASE_DIGEST" \
          "$ACTIVE_REPAIR_RELEASE_VERSION" |
        /usr/bin/env -i \
          "HOME=${HOME:-}" \
          "TRELLIS_HOME=$HOME_PATH" \
          "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
          "LC_ALL=C" \
          "TRELLIS_LIBS_PRELOADED=1" \
          /bin/bash --noprofile --norc -s -- relink --home "$HOME_PATH" --fleet "$fleet" \
            "${binding_args[@]}" "$root"
    } 2>&1
  )"; then
    RELINK_SUCCEEDED=true
    printf '%s\n' '  + attachment relinked'
    return 0
  else
    rc=$?
  fi
  printf '  WARN: attachment relink failed (%s): %s\n' "$rc" \
    "$(diagnostic_escape "${output:-no diagnostic}")" >&2
  record_failure "$rc"
  return 0
}

sync_one() {
  local row="$1" fleet project_id kind availability status excluded root
  local release attachment_id checkout_id worktree_id row_harnesses owner_harnesses
  local label resolution owner release_dir payload plan rc

  # Extract nullable columns independently. IFS treats tab as whitespace and
  # would collapse an empty attachment_id, shifting every later binding field.
  if fleet="$(printf '%s\n' "$row" | jq -er '.fleet' 2>/dev/null)" &&
     project_id="$(printf '%s\n' "$row" | jq -er '.project_id' 2>/dev/null)" &&
     kind="$(printf '%s\n' "$row" | jq -er '.kind' 2>/dev/null)" &&
     availability="$(printf '%s\n' "$row" | jq -er '.availability' 2>/dev/null)" &&
     status="$(printf '%s\n' "$row" | jq -er '.status' 2>/dev/null)" &&
     excluded="$(printf '%s\n' "$row" | jq -er '((.excluded // false) | tostring)' 2>/dev/null)" &&
     root="$(printf '%s\n' "$row" | jq -r '(.root // "")' 2>/dev/null)" &&
     release="$(printf '%s\n' "$row" | jq -r '(.release // "")' 2>/dev/null)" &&
     attachment_id="$(printf '%s\n' "$row" | jq -r '(.attachment_id // "")' 2>/dev/null)" &&
     checkout_id="$(printf '%s\n' "$row" | jq -r '(.checkout_id // "")' 2>/dev/null)" &&
     worktree_id="$(printf '%s\n' "$row" | jq -r '(.worktree_id // "")' 2>/dev/null)" &&
     row_harnesses="$(printf '%s\n' "$row" | jq -c '(.harnesses // [])' 2>/dev/null)"; then
    :
  else
    printf '%s\n' 'blocked (invalid strict registry row)' >&2
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi
  label="$fleet/$project_id"

  # identity_error is tested BEFORE the excluded/legacy skips. Registry drift is
  # a property of the row's recorded identity, not of whether this run would
  # have acted on it, so an excluded or legacy row's drift must still be
  # reported and aggregated instead of being swallowed into an exit 0. The
  # report is report-only: this returns without processing the row, so the
  # excluded/legacy contract — never act on such a row — is unchanged.
  if [ "$availability" = identity_error ]; then
    printf 'blocked (registry row failed identity validation): %s\n' "$(diagnostic_escape "$label")" >&2
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi
  if [ "$excluded" = true ]; then
    printf 'skip (excluded): %s\n' "$(diagnostic_escape "$label")"
    return 0
  fi
  if row_is_legacy "$row"; then
    printf 'skip (legacy row): %s\n' "$(diagnostic_escape "$label")"
    return 0
  fi
  if [ "$availability" = unavailable ] || [ "$status" = unavailable ] || [ "$kind" = unavailable ]; then
    if [ -n "$root" ]; then
      printf 'skip (unavailable): %s -> %s\n' \
        "$(diagnostic_escape "$label")" "$(diagnostic_escape "$root")"
    else
      printf 'skip (unavailable): %s\n' "$(diagnostic_escape "$label")"
    fi
    return 0
  fi
  if [ "$status" != active ]; then
    printf 'skip (registry status %s): %s\n' \
      "$(diagnostic_escape "$status")" "$(diagnostic_escape "$label")"
    return 0
  fi
  if [ "$kind" != worktree ] || [ -z "$root" ] || [ ! -d "$root" ]; then
    printf 'skip (no available worktree): %s\n' "$(diagnostic_escape "$label")"
    return 0
  fi
  if [ -z "$attachment_id" ] || [ -z "$checkout_id" ] || [ -z "$worktree_id" ] || [ -z "$release" ]; then
    printf 'skip (unattached): %s\n' "$(diagnostic_escape "$label")"
    return 0
  fi

  if resolution="$(local_registry_resolve_root "$HOME_PATH" "$root" 2>/dev/null)"; then
    :
  else
    rc=$?
    printf 'skip (registered root identity unavailable or drifted): %s -> %s\n' \
      "$(diagnostic_escape "$label")" "$(diagnostic_escape "$root")" >&2
    record_failure "$rc"
    return 0
  fi
  if ! row_matches_resolved_root "$row" "$resolution"; then
    printf 'skip (registered root identity conflicts with row): %s\n' \
      "$(diagnostic_escape "$label")" >&2
    record_failure "$TRELLIS_EX_CONFLICT"
    return 0
  fi

  owner="$HOME_PATH/state/attachments/$checkout_id/$worktree_id.json"
  if ! _attachment_canonical_file "$owner"; then
    printf 'blocked (corrupt attachment owner record): %s\n' \
      "$(diagnostic_escape "$label")" >&2
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi
  if ! _attachment_owner_json_valid "$owner"; then
    printf 'blocked (corrupt attachment owner record): %s\n' \
      "$(diagnostic_escape "$label")" >&2
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi
  if ! owner_matches_row "$owner" "$row"; then
    printf 'skip (owner record conflicts with strict registry): %s\n' \
      "$(diagnostic_escape "$label")" >&2
    record_failure "$TRELLIS_EX_CONFLICT"
    return 0
  fi
  if owner_harnesses="$(owner_harnesses_json "$owner")"; then
    :
  else
    printf 'blocked (unreadable attachment owner harnesses): %s\n' \
      "$(diagnostic_escape "$label")" >&2
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi
  if ! printf '%s\n' "$owner_harnesses" | jq -e --arg harness "$SYNC_HARNESS" \
      'index($harness) != null' >/dev/null 2>&1; then
    printf 'skip (harness %s is not attached): %s\n' \
      "$(diagnostic_escape "$SYNC_HARNESS")" "$(diagnostic_escape "$label")"
    return 0
  fi

  if release_dir="$(TRELLIS_HOME="$HOME_PATH" release_store_locate "$release" 2>/dev/null)"; then
    :
  else
    rc=$?
    printf 'skip (recorded immutable release unavailable): %s @ %s\n' \
      "$(diagnostic_escape "$label")" "$(diagnostic_escape "$release")" >&2
    record_failure "$rc"
    return 0
  fi
  payload="$release_dir/payload"
  if [ ! -d "$payload" ] || [ -L "$payload" ]; then
    printf 'blocked (recorded release lacks a safe payload): %s @ %s\n' \
      "$(diagnostic_escape "$label")" "$(diagnostic_escape "$release")" >&2
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi
  if plan="$(surface_plan_emit "$payload" "$SYNC_HARNESS" 2>/dev/null)" &&
     plan_has_attached_leaves "$plan"; then
    :
  else
    printf 'blocked (immutable manifest has no usable %s surface): %s\n' \
      "$(diagnostic_escape "$SYNC_HARNESS")" "$(diagnostic_escape "$label")" >&2
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi

  printf '== %s ==\n' "$(diagnostic_escape "$label")"
  if attachment_verify "$HOME_PATH" "$owner" >/dev/null 2>&1; then
    printf '  (in sync: attached immutable release %s)\n' "$(diagnostic_escape "$release")"
    return 0
  fi

  relink_one "$root" "$label" "$fleet" "$project_id" "$checkout_id" "$worktree_id" \
    "$attachment_id" "$release" "$owner_harnesses"
  if ! $DRY_RUN && $RELINK_SUCCEEDED &&
     ! attachment_verify "$HOME_PATH" "$owner" >/dev/null 2>&1; then
    printf '%s\n' '  WARN: attachment remains unhealthy after relink; no direct file overwrite was attempted' >&2
    record_failure "$TRELLIS_EX_STATE"
  fi
  return 0
}

while IFS= read -r row; do
  [ -n "$row" ] || continue
  sync_one "$row"
done < "$TARGETS"

printf '%s\n' '== done =='
exit "$RESULT_STATUS"
