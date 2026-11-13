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

# This process has not inherited any of its caller's shell functions.
unset TRELLIS_LIBS_PRELOADED

readonly SYNC_TMPDIR="${TMPDIR:-/tmp}"

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
diagnostic_escape() (
  export LC_ALL=C && printf '%q' "${1-}"
)

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
      if [ "$#" -eq 1 ]; then
        [ -n "$1" ] || {
          printf '%s: PROJECT_ID must not be empty\n' "$(diagnostic_escape "$SYNC_NAME")" >&2
          exit "$TRELLIS_EX_USAGE"
        }
        ONLY_PROJECT="$1"
      fi
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
      [ -n "$1" ] || {
        printf '%s: PROJECT_ID must not be empty\n' "$(diagnostic_escape "$SYNC_NAME")" >&2
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

SNAPSHOT="$(mktemp "$SYNC_TMPDIR/trellis.sync-registry.XXXXXX")" || exit "$TRELLIS_EX_UNAVAILABLE"
TARGETS="$(mktemp "$SYNC_TMPDIR/trellis.sync-targets.XXXXXX")" || {
  rm -f "$SNAPSHOT"
  exit "$TRELLIS_EX_UNAVAILABLE"
}
ACTIVE_REPAIR_SNAPSHOT=""
ACTIVE_REPAIR_RELEASE_DIGEST=""
ACTIVE_REPAIR_RELEASE_VERSION=""
SYNC_PROOF_DIR="$(mktemp -d "$SYNC_TMPDIR/trellis.sync-proofs.XXXXXX")" || SYNC_PROOF_DIR=""
SYNC_PROOF_TOKEN=""
SYNC_PROOF_STAT_OS="$(/usr/bin/uname -s 2>/dev/null)" || SYNC_PROOF_STAT_OS=""
_LOCAL_REGISTRY_SYNC_PROOF_READY=0
if [ -n "$SYNC_PROOF_DIR" ]; then
  SYNC_PROOF_TOKEN="$(_local_registry_diagnostic_token "$HOME_PATH" 2>/dev/null)" || SYNC_PROOF_TOKEN=""
fi

cleanup_sync() {
  local status="${1:-0}" cleanup_output cleanup_rc=0
  rm -f "$SNAPSHOT" "$TARGETS"
  [ -z "${SYNC_ROOT_PROOFS:-}" ] || rm -f "$SYNC_ROOT_PROOFS"
  [ -z "${SYNC_ROOT_PROOF_LIST:-}" ] || rm -f "$SYNC_ROOT_PROOF_LIST"
  if [ -n "$SYNC_PROOF_DIR" ] && [ -d "$SYNC_PROOF_DIR" ] && [ ! -L "$SYNC_PROOF_DIR" ]; then
    /usr/bin/find "$SYNC_PROOF_DIR" -mindepth 1 -maxdepth 1 ! -type d -exec rm -f {} + 2>/dev/null || true
    rmdir "$SYNC_PROOF_DIR" 2>/dev/null || true
  fi
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

if [ -n "$SYNC_PROOF_DIR" ] && [ -n "$SYNC_PROOF_TOKEN" ] &&
   [ "$(declare -f local_registry_list_json)" = "${_LOCAL_REGISTRY_LIST_JSON_ORIGINAL:-}" ]; then
  if _local_registry_list_json_for_sync "$HOME_PATH" "$FLEET" "$SYNC_PROOF_DIR" > "$SNAPSHOT" 2>/dev/null; then rc=0; else rc=$?; fi
else
  if local_registry_list_json "$HOME_PATH" "$FLEET" > "$SNAPSHOT" 2>/dev/null; then rc=0; else rc=$?; fi
fi
if [ "$rc" -ne 0 ]; then
  printf '%s: could not read strict local registry for fleet %s\n' \
    "$(diagnostic_escape "$SYNC_NAME")" "$(diagnostic_escape "$FLEET")" >&2
  exit "$rc"
fi
if [ "$_LOCAL_REGISTRY_SYNC_PROOF_READY" = 1 ]; then
  SYNC_PROOF_AFTER="$(_local_registry_diagnostic_token "$HOME_PATH" 2>/dev/null)" || SYNC_PROOF_AFTER=""
  [ "$SYNC_PROOF_AFTER" = "$SYNC_PROOF_TOKEN" ] || _LOCAL_REGISTRY_SYNC_PROOF_READY=0
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

# The row values the comparisons below pass to jq as --arg, computed in jq for
# the rows where that is exact: each value a string that $(jq -r ...) would
# return unchanged (no NUL, no trailing newline), an optional one "" when null
# or false (`// empty`). Any other row is undecided (2) and the caller takes
# its per-column extraction, which stays the authority.
SYNC_ROW_ARGS_DEFS='
  def plain: type == "string" and (explode | any(. == 0) | not) and (endswith("\n") | not);
  def req(f): (f) as $v | if ($v | plain) then $v else error("undecided") end;
  def opt(f): (f) as $v | if $v == null or $v == false then "" elif ($v | plain) then $v else error("undecided") end;
  def rowargs: {fleet: req(.fleet), project_id: req(.project_id), root: opt(.root),
    checkout_id: opt(.checkout_id), worktree_id: opt(.worktree_id),
    attachment_id: opt(.attachment_id), release: opt(.release)};
'

# One jq for row_matches_resolved_root: 0 match, 1 mismatch, 2 undecided.
_row_matches_resolved_root_fast() {
  local row="$1" resolution="$2" verdict
  verdict="$(jq -r --argjson row "$row" "$SYNC_ROW_ARGS_DEFS"'
    ($row | rowargs) as $a
    | .fleet == $a.fleet and .project_id == $a.project_id and .root == $a.root
      and .checkout_id == $a.checkout_id and .worktree_id == $a.worktree_id
  ' <<<"$resolution" 2>/dev/null)" || return 2
  case "$verdict" in
    true) return 0 ;;
    false) return 1 ;;
    *) return 2 ;;
  esac
}

row_matches_resolved_root() {
  local row="$1" resolution="$2" rc=0
  _row_matches_resolved_root_fast "$row" "$resolution" || rc=$?
  [ "$rc" -eq 2 ] || return "$rc"
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
    (.artifacts + (.pre_existing // [])) as $owned
    | (any($owned[]; .path | startswith(".pi/"))) as $has_pi
    | [$owned[]
      | if (.path | startswith(".codex/")) then "codex"
        elif (.path | startswith(".pi/")) then "pi"
        elif .path | startswith(".claude/") then "claude"
        elif (($has_pi | not) and (.path == "AGENTS.md" or (.path | startswith(".agents/")))) then "codex"
        else empty end] | unique | sort
  ' "$1" 2>/dev/null
}

# One jq for the field comparison of owner_matches_row: 0 match, 1 mismatch,
# 2 undecided.
_owner_matches_row_fields_fast() {
  local owner="$1" row="$2" verdict
  verdict="$(jq -r --argjson row "$row" "$SYNC_ROW_ARGS_DEFS"'
    ($row | rowargs) as $a
    | .status == "committed"
      and .fleet == $a.fleet and .project_id == $a.project_id
      and .project_root == $a.root and .worktree_root == $a.root
      and .checkout_id == $a.checkout_id and .worktree_id == $a.worktree_id
      and .attachment_id == $a.attachment_id and .release == $a.release
  ' "$owner" 2>/dev/null)" || return 2
  case "$verdict" in
    true) return 0 ;;
    false) return 1 ;;
    *) return 2 ;;
  esac
}

owner_matches_row() {
  local owner="$1" row="$2" row_harnesses owner_harnesses rc=0
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

  _owner_matches_row_fields_fast "$owner" "$row" || rc=$?
  [ "$rc" -eq 2 ] || return "$rc"
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

# Inventory locate caching never authorizes copying or executing release bytes.
# Bypass the same-process verify memo at both use boundaries: immediately
# before copying the installed tree and immediately before each bundle emission.
sync_verify_release_for_copy() {
  local version="$1" path
  path="$(release_store_release_path "$version")" || return "$?"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then return "$TRELLIS_EX_UNAVAILABLE"; fi
  release_store_release_has_no_acl "$path" || return "$TRELLIS_EX_STATE"
  release_store_verify_path_body "$path" "$version" 0 0
}

sync_reverify_repair_snapshot() {
  local digest
  digest="$(release_store_release_json_sha256_no_follow "${ACTIVE_REPAIR_SNAPSHOT%/*}" "${ACTIVE_REPAIR_SNAPSHOT##*/}")" || return "$?"
  [ "$digest" = "$ACTIVE_REPAIR_RELEASE_DIGEST" ] || return "$TRELLIS_EX_STATE"
  release_store_release_has_no_acl "$ACTIVE_REPAIR_SNAPSHOT" || return "$TRELLIS_EX_STATE"
  release_store_verify_path_body "$ACTIVE_REPAIR_SNAPSHOT" "$ACTIVE_REPAIR_RELEASE_VERSION" 0 1
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
  sync_verify_release_for_copy "$version" || return "$?"
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

  if sync_reverify_repair_snapshot >/dev/null 2>&1; then
    :
  else
    rc=$?
    printf '  WARN: attachment relink failed (%s): %s\n' "$rc" \
      "$(diagnostic_escape 'release snapshot failed use-time verification')" >&2
    record_failure "$rc"
    return 0
  fi

  printf '%s\n' '  ~ reconciling attachment through relink'
  if output="$(
    set -o pipefail
    {
      export TRELLIS_HOME="$HOME_PATH"
      release_store_emit_verified_attachment_bundle \
        "$ACTIVE_REPAIR_SNAPSHOT" "$ACTIVE_REPAIR_RELEASE_DIGEST" \
        "$ACTIVE_REPAIR_RELEASE_VERSION" |
        /usr/bin/env -i \
          "HOME=${HOME:-}" \
          "TRELLIS_HOME=$HOME_PATH" \
          "TMPDIR=$SYNC_TMPDIR" \
          "TMP=$SYNC_TMPDIR" \
          "TEMP=$SYNC_TMPDIR" \
          "PATH=/usr/bin:/bin:/usr/sbin:/sbin" \
          "LC_ALL=C" \
          "TRELLIS_VERIFIED_PAYLOAD=$ACTIVE_REPAIR_SNAPSHOT/payload" \
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

# The batch pre-pass verified OWNER together with every other owner it named.
sync_owner_batch_verified() {
  local owner=$1
  [ -n "$SYNC_VERIFIED_OWNERS" ] || return 1
  case $'\n'"$SYNC_VERIFIED_OWNERS"$'\n' in
    *$'\n'"$owner"$'\n'*) return 0 ;;
  esac
  return 1
}

# surface_plan_emit is a function of the verified immutable payload and the
# harness; rows on the same release share one plan per sync.
SYNC_PLAN_PAYLOAD=""
SYNC_PLAN=""
sync_surface_plan() {
  local payload=$1
  if [ -n "$SYNC_PLAN_PAYLOAD" ] && [ "$SYNC_PLAN_PAYLOAD" = "$payload" ]; then
    printf '%s\n' "$SYNC_PLAN"
    return 0
  fi
  surface_plan_emit "$payload" "$SYNC_HARNESS"
}

# A row proof is usable only while every named Git/registry node still has the
# identity and fine-ctime captured by the batch. Any uncertainty goes through
# the original resolver, preserving its exact result and failure class.
sync_resolve_root() {
  local root="$1" worktree_id="$2" prefix path expected actual resolved
  local -a watched=() ancestors=()
  case "$worktree_id" in ''|*[!0-9a-f]*) local_registry_resolve_root "$HOME_PATH" "$root"; return "$?" ;; esac
  if resolved="$(sync_root_proof "$root" "$worktree_id")"; then
    printf '%s\n' "$resolved"
    return 0
  fi
  if [ "${#worktree_id}" -eq 64 ] && [ "${_LOCAL_REGISTRY_SYNC_PROOF_READY:-0}" = 1 ] &&
     [ -n "$SYNC_PROOF_DIR" ] && [ -d "$SYNC_PROOF_DIR" ] && [ ! -L "$SYNC_PROOF_DIR" ]; then
    prefix="$SYNC_PROOF_DIR/$worktree_id"
    if [ -f "$prefix.ready" ] && [ ! -L "$prefix.ready" ] &&
       [ -f "$prefix.root" ] && [ ! -L "$prefix.root" ] &&
       [ -f "$prefix.resolution" ] && [ ! -L "$prefix.resolution" ] &&
       [ -f "$prefix.watched" ] && [ ! -L "$prefix.watched" ] &&
       [ -f "$prefix.full" ] && [ ! -L "$prefix.full" ] &&
       [ -f "$prefix.ancestors" ] && [ ! -L "$prefix.ancestors" ] &&
       [ -f "$prefix.partial" ] && [ ! -L "$prefix.partial" ] &&
       IFS= read -r path < "$prefix.root" && [ "$path" = "$root" ]; then
      while IFS= read -r path; do [ -z "$path" ] || watched+=("$path"); done < "$prefix.watched"
      while IFS= read -r path; do [ -z "$path" ] || ancestors+=("$path"); done < "$prefix.ancestors"
      if [ -n "${watched[*]-}" ] && [ -n "${ancestors[*]-}" ]; then
        expected="$(< "$prefix.full")"
        case "$SYNC_PROOF_STAT_OS" in
          Darwin) actual="$(/usr/bin/env LC_ALL=C TZ=UTC0 /usr/bin/stat -f $'%d\t%i\t%z\t%p\t%Fm\t%Fc' -- "${watched[@]}" 2>/dev/null)" || actual='' ;;
          Linux) actual="$(/usr/bin/env LC_ALL=C TZ=UTC0 /usr/bin/stat --printf='%d\t%i\t%s\t%f\t%y\t%z\n' -- "${watched[@]}" 2>/dev/null)" || actual='' ;;
          *) actual='' ;;
        esac
        if [ -n "$actual" ] && [ "$actual" = "$expected" ]; then
          expected="$(< "$prefix.partial")"
          case "$SYNC_PROOF_STAT_OS" in
            Darwin) actual="$(/usr/bin/env LC_ALL=C TZ=UTC0 /usr/bin/stat -f $'%d\t%i\t%p\t%u' -- "${ancestors[@]}" 2>/dev/null)" || actual='' ;;
            Linux) actual="$(/usr/bin/env LC_ALL=C TZ=UTC0 /usr/bin/stat --printf='%d\t%i\t%f\t%u\n' -- "${ancestors[@]}" 2>/dev/null)" || actual='' ;;
            *) actual='' ;;
          esac
          if [ -n "$actual" ] && [ "$actual" = "$expected" ] &&
             resolved="$(jq -e -s -S 'if length == 1 and (.[0] | type) == "object" then .[0] else error("invalid resolution proof") end' "$prefix.resolution" 2>/dev/null)" &&
             [ -n "$resolved" ]; then
            printf '%s\n' "$resolved"
            return 0
          fi
        fi
      fi
    fi
  fi
  local_registry_resolve_root "$HOME_PATH" "$root"
}

# One registry identity batch for every row, in this process, at the start of
# the row loop (local_registry_sync_root_proofs). Positive-only: no file, a
# failed batch or any doubt leaves every row on sync_resolve_root's other
# paths. Its stderr is discarded like the listing's above: the batch is an
# optimization, and a failed one must not change sync's diagnostics.
SYNC_ROOT_PROOFS=""
SYNC_ROOT_PROOF_TOKEN=""
SYNC_ROOT_PROOF_OS=""
SYNC_ROOT_PROOF_LIST=""
sync_root_proofs_prepare() {
  local file
  file="$(mktemp "$SYNC_TMPDIR/trellis.sync-roots.XXXXXX")" || return 0
  SYNC_ROOT_PROOF_LIST="$(mktemp "$SYNC_TMPDIR/trellis.sync-worktrees.XXXXXX")" || { rm -f "$file"; SYNC_ROOT_PROOF_LIST=""; return 0; }
  if local_registry_sync_root_proofs "$HOME_PATH" "$file" 2>/dev/null &&
     SYNC_ROOT_PROOF_TOKEN="$(head -n 1 "$file" | jq -r '.' 2>/dev/null)" && [ -n "$SYNC_ROOT_PROOF_TOKEN" ]; then
    SYNC_ROOT_PROOFS="$file"
    SYNC_ROOT_PROOF_OS="$(/usr/bin/uname -s 2>/dev/null)" || SYNC_ROOT_PROOFS=""
  fi
  [ -n "$SYNC_ROOT_PROOFS" ] || { rm -f "$file"; SYNC_ROOT_PROOF_TOKEN=""; }
  return 0
}

# The proven resolution for ROOT and WORKTREE_ID, printed exactly as
# local_registry_resolve_root prints it, while the registry token and the stat
# line of the root and its .git still equal the batch's AND Git, asked now in
# this environment, still gives the identity the proof relied on (sync_root_seen).
# 1 otherwise; the caller then runs the original resolver.
sync_root_proof() {
  local root="$1" worktree_id="$2" entry watch actual token checkout common
  [ -n "$SYNC_ROOT_PROOFS" ] && [ -f "$SYNC_ROOT_PROOFS" ] || return 1
  token="$(_local_registry_diagnostic_token "$HOME_PATH" 2>/dev/null)" && [ "$token" = "$SYNC_ROOT_PROOF_TOKEN" ] || return 1
  entry="$(tail -n +2 "$SYNC_ROOT_PROOFS" | jq -c --arg root "$root" --arg id "$worktree_id" \
    'select(.root == $root and .worktree_id == $id)' 2>/dev/null)" || return 1
  [ -n "$entry" ] && [ "$(printf '%s\n' "$entry" | wc -l | tr -d ' ')" = 1 ] || return 1
  watch="$(printf '%s\n' "$entry" | jq -r '.watch' 2>/dev/null)" || return 1
  actual="$(_local_registry_sync_watch "$SYNC_ROOT_PROOF_OS" "$root" "$root/.git")" || return 1
  [ -n "$actual" ] && [ "$actual" = "$watch" ] || return 1
  checkout="$(printf '%s\n' "$entry" | jq -r '.checkout_root | strings' 2>/dev/null)" && [ -n "$checkout" ] || return 1
  common="$(printf '%s\n' "$entry" | jq -r '.resolution.git_common_dir | strings' 2>/dev/null)" && [ -n "$common" ] || return 1
  # The Git observations local_registry_resolve_root makes for this root, run
  # now exactly as it runs them (sync_root_seen); any difference is a miss.
  sync_root_seen "$root" "$checkout" "$common" || return 1
  printf '%s\n' "$entry" | jq -S '.resolution' 2>/dev/null
}

# The Git invocations the original resolver makes for ROOT, with the same
# arguments, working directory and environment, in the same order
# (local_registry_identity_for_root, then local_registry_checkout_root_for_common_dir
# and local_registry_git_common_dir), each required to succeed and to give back
# the recorded ROOT, CHECKOUT and COMMON. Only the resolver's non-Git work
# (registry parsing, jq, ids) is skipped. Any non-zero status, missing field or
# difference is a miss, and the caller then runs the resolver itself. The rare
# primary-is-the-common-dir branch is not re-observed here: it misses.
sync_root_seen() {
  local root="$1" checkout="$2" common="$3" real record top seen candidate field
  real="$(cd "$root" 2>/dev/null && pwd -P)" && [ "$real" = "$root" ] || return 1
  # local_registry_identity_for_root
  record="$(git -C "$root" rev-parse --show-toplevel --git-common-dir 2>/dev/null)" || return 1
  [ "$record" != "${record#*$'\n'}" ] || return 1
  top="${record%%$'\n'*}"
  seen="${record#*$'\n'}"
  top="$(cd "$top" 2>/dev/null && pwd -P)" && [ "$top" = "$root" ] || return 1
  case "$seen" in /*) ;; *) seen="$root/$seen" ;; esac
  seen="$(cd "$seen" 2>/dev/null && pwd -P)" && [ "$seen" = "$common" ] || return 1
  # local_registry_checkout_root_for_common_dir: the primary worktree, read from
  # a file as the resolver reads it, never through a pipe
  [ -n "${SYNC_ROOT_PROOF_LIST:-}" ] || return 1
  git -C "$root" worktree list --porcelain -z > "$SYNC_ROOT_PROOF_LIST" 2>/dev/null || return 1
  IFS= read -r -d '' field < "$SYNC_ROOT_PROOF_LIST" || return 1
  case "$field" in 'worktree '*) candidate="${field#worktree }" ;; *) return 1 ;; esac
  candidate="$(cd "$candidate" 2>/dev/null && pwd -P)" && [ "$candidate" = "$checkout" ] || return 1
  [ "$candidate" != "$common" ] || return 1
  # local_registry_git_common_dir for the primary
  record="$(git -C "$candidate" rev-parse --is-inside-work-tree --git-common-dir 2>/dev/null)" || return 1
  [ "${record%%$'\n'*}" = true ] && [ "$record" != "${record#*$'\n'}" ] || return 1
  seen="${record#*$'\n'}"
  case "$seen" in /*) ;; *) seen="$candidate/$seen" ;; esac
  seen="$(cd "$seen" 2>/dev/null && pwd -P)" && [ "$seen" = "$common" ] || return 1
}

# A successful prepass locate may be reused only for this sync process and
# the same canonical release directory inode. This is an inventory shortcut,
# not authority to execute/copy payload bytes: the repair path still creates
# and verifies a fresh immutable snapshot before use.
SYNC_RELEASE_CACHE=""
sync_release_dir_identity() {
  local path="$1" physical token
  [ -d "$path" ] && [ ! -L "$path" ] && [ -f "$path/release.json" ] &&
    [ ! -L "$path/release.json" ] && [ -d "$path/payload" ] && [ ! -L "$path/payload" ] || return 1
  physical="$(CDPATH='' cd "$path" && pwd -P)" || return 1
  [ "$physical" = "$path" ] || return 1
  case "$SYNC_PROOF_STAT_OS" in
    Darwin) token="$(/usr/bin/env LC_ALL=C TZ=UTC0 /usr/bin/stat -f $'%d:%i:%p:%u:%z:%Fm:%Fc' -- "$path" "$path/release.json" "$path/payload" 2>/dev/null)" || return 1 ;;
    Linux) token="$(/usr/bin/env LC_ALL=C TZ=UTC0 /usr/bin/stat --printf='%d:%i:%f:%u:%s:%y:%z\n' -- "$path" "$path/release.json" "$path/payload" 2>/dev/null)" || return 1 ;;
    *) return 1 ;;
  esac
  [ -n "$token" ] || return 1
  printf '%s\n' "$token"
}

sync_release_preverify() {
  local release="$1" version path before after verified tmp rc lines
  if [ "$(_release_store_sync_cache_helpers)" != "${_RELEASE_STORE_SYNC_CACHE_HELPERS_ORIGINAL:-}" ]; then
    TRELLIS_HOME="$HOME_PATH" release_store_locate "$release" >/dev/null
    return "$?"
  fi
  version="$(release_store_normalize_version "$release")" || return "$?"
  path="$(release_store_release_path "$version")" || return "$?"
  before="$(sync_release_dir_identity "$path")" || {
    TRELLIS_HOME="$HOME_PATH" release_store_locate "$release" >/dev/null
    return "$?"
  }
  tmp="$(mktemp "$SYNC_TMPDIR/trellis.sync-release.XXXXXX")" || {
    TRELLIS_HOME="$HOME_PATH" release_store_locate "$release" >/dev/null
    return "$?"
  }
  if TRELLIS_HOME="$HOME_PATH" release_store_locate "$release" > "$tmp"; then rc=0; else rc=$?; fi
  lines="$(wc -l < "$tmp" | tr -d ' ')" || lines=''
  if [ "$rc" -eq 0 ] && [ "$lines" = 1 ] && IFS= read -r verified < "$tmp" && [ "$verified" = "$path" ] &&
     after="$(sync_release_dir_identity "$path")" && [ "$before" = "$after" ]; then
    # Keep the multi-line stat token on one table line; hashes are not used as
    # authority here, only to compare a fresh observation to this one.
    after="${after//$'\n'/|}"
    [ -z "$after" ] || SYNC_RELEASE_CACHE="${SYNC_RELEASE_CACHE}${version}"$'\t'"${path}"$'\t'"${after}"$'\n'
  fi
  rm -f "$tmp"
  return "$rc"
}

sync_release_locate() {
  local release="$1" version cached_version cached_path cached_identity current
  version="$(release_store_normalize_version "$release")" || return "$?"
  if [ "$(_release_store_sync_cache_helpers)" != "${_RELEASE_STORE_SYNC_CACHE_HELPERS_ORIGINAL:-}" ]; then
    TRELLIS_HOME="$HOME_PATH" release_store_locate "$release"
    return "$?"
  fi
  while IFS=$'\t' read -r cached_version cached_path cached_identity; do
    [ "$cached_version" = "$version" ] || continue
    if current="$(sync_release_dir_identity "$cached_path")"; then
      current="${current//$'\n'/|}"
    else
      current=''
    fi
    if [ -n "$current" ] && [ "$current" = "$cached_identity" ]; then
      printf '%s\n' "$cached_path"
      return 0
    fi
    break
  done <<EOF
$SYNC_RELEASE_CACHE
EOF
  TRELLIS_HOME="$HOME_PATH" release_store_locate "$release"
}

# Every column sync_one reads, from one jq: the values joined by the unit
# separator (not whitespace to IFS, so an empty column keeps its place). Only
# rows whose every value is a string that $(jq -r ...) returns unchanged and
# that holds no separator, newline or NUL; any other row fails here and
# sync_one extracts column by column as before. Sets the caller's locals.
_sync_row_columns_fast() {
  local columns
  columns="$(printf '%s\n' "$1" | jq -r '
    def plain: type == "string" and (explode | any(. == 0 or . == 10 or . == 31) | not);
    def s(f): (f) as $v | if ($v | plain) then $v else error("undecided") end;
    def req(f): (f) as $v | if $v == null or $v == false then error("absent") else s($v) end;
    [req(.fleet), req(.project_id), req(.kind), req(.availability), req(.status),
     s((.excluded // false) | tostring), s(.root // ""), s(.release // ""),
     s(.attachment_id // ""), s(.checkout_id // ""), s(.worktree_id // ""),
     s((.harnesses // []) | tojson)]
    | join("\u001f")' 2>/dev/null)" || return 1
  IFS=$'\037' read -r fleet project_id kind availability status excluded root release \
    attachment_id checkout_id worktree_id row_harnesses <<EOF
$columns
EOF
}

sync_one() {
  local row="$1" fleet project_id kind availability status excluded root
  local release attachment_id checkout_id worktree_id row_harnesses owner_harnesses
  local label resolution owner release_dir payload plan rc

  # Extract nullable columns independently. IFS treats tab as whitespace and
  # would collapse an empty attachment_id, shifting every later binding field.
  if _sync_row_columns_fast "$row"; then
    :
  elif fleet="$(printf '%s\n' "$row" | jq -er '.fleet' 2>/dev/null)" &&
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

  if resolution="$(sync_resolve_root "$root" "$worktree_id" 2>/dev/null)"; then
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

  if release_dir="$(sync_release_locate "$release" 2>/dev/null)"; then
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
  if plan="$(sync_surface_plan "$payload" 2>/dev/null)" &&
     plan_has_attached_leaves "$plan"; then
    SYNC_PLAN_PAYLOAD="$payload"
    SYNC_PLAN="$plan"
  else
    printf 'blocked (immutable manifest has no usable %s surface): %s\n' \
      "$(diagnostic_escape "$SYNC_HARNESS")" "$(diagnostic_escape "$label")" >&2
    record_failure "$TRELLIS_EX_STATE"
    return 0
  fi

  printf '== %s ==\n' "$(diagnostic_escape "$label")"
  if sync_owner_batch_verified "$owner" || attachment_verify "$HOME_PATH" "$owner" >/dev/null 2>&1; then
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

# One pass before the rows, none of it a verdict on its own. Each recorded
# release is verified once in this shell, so sync_one's locate captures answer
# from the verify memo (the ACL refusal still runs on each). The owner records
# the rows name are verified together (attachment_verify_owners_batch); only
# when every one passes does sync_one take that pass in place of its own
# attachment_verify, and any miss leaves every row to verify alone.
SYNC_VERIFIED_OWNERS=""
sync_prepass() {
  local release owner
  local -a owners=()
  while IFS= read -r release; do
    [ -n "$release" ] || continue
    sync_release_preverify "$release" >/dev/null 2>&1 || :
  done < <(jq -r 'select(.kind == "worktree") | .release // empty' "$TARGETS" | sort -u)
  while IFS= read -r owner; do
    [ -f "$owner" ] && [ ! -L "$owner" ] || continue
    owners+=("$owner")
  done < <(jq -r --arg home "$HOME_PATH" '
    select(.kind == "worktree" and (.checkout_id // "") != "" and (.worktree_id // "") != "")
    | $home + "/state/attachments/" + .checkout_id + "/" + .worktree_id + ".json"' "$TARGETS" | sort -u)
  [ "${#owners[@]}" -gt 0 ] || return 0
  attachment_verify_owners_batch "$HOME_PATH" "${owners[@]}" || return 0
  SYNC_VERIFIED_OWNERS="$(printf '%s\n' "${owners[@]}")"
}
sync_prepass
sync_root_proofs_prepare

while IFS= read -r row; do
  [ -n "$row" ] || continue
  sync_one "$row"
done < "$TARGETS"

printf '%s\n' '== done =='
exit "$RESULT_STATUS"
