#!/usr/bin/env bash
# show-config.sh — portable policy plus validated local machine context.
set -u

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Direct-source rejection, in the exact shape release.sh, upgrade.sh, and
# sync-to-template.sh use it: ATTESTATION-BASED and default-refuse. This
# renderer is authoritative only as the copy the fixed launcher verified; the
# launcher exports that payload identity across its env -i boundary, so the
# gate binds to the attestation and to nothing else. No attestation means there
# is nothing to bind to, and the answer is refusal — period.
#
# It is deliberately NOT identity-based. An earlier shape asked "does a machine
# config name this copy as its source_root?" and allowed when no consulted
# config answered. That question is undecidable for the cases that matter — a
# copy of the source tree, a git worktree of it, an unpacked tarball, a clone at
# a path no config names — and every one of them answered "cannot tell", so
# every one of them rendered local authority state. A source gate whose
# undecidable case allows is not a gate. Undecidable here means refuse, the same
# way it does for its three siblings.
show_config_reject_direct_source() {
  printf '%s\n' \
    'trellis show-config: direct source execution is unsupported; run trellis show-config from the installed stable launcher' >&2
  exit 2
}

show_config_gate_path_is_clean() {
  local path="${1:-}"
  [ -n "$path" ] && [ "$path" != "/" ] || return 1
  case "$path" in
    /*) ;;
    *) return 1 ;;
  esac
  case "$path" in
    *$'\t'*|*$'\n'*|*$'\r'*|*'//'*|*/./*|*/../*|*/.|*/..|*/) return 1 ;;
  esac
  return 0
}

# Byte-identical copy of trellis_home_snapshot_payload_matches (see
# scripts/lib/trellis-home.sh for the normative definition and the reason the
# version segment must be matched whole rather than as a prefix). This gate
# decides whether this copy may source its own libraries at all, so no library
# is available to call and the body is pinned by
# scripts/tests/release-snapshot-predicate.bats instead.
show_config_payload_matches_release() {
  local home="$1" payload="$2" version="$3" snapshot_root snapshot_base rest suffix
  [ "$payload" = "$home/releases/$version/payload" ] && return 0
  snapshot_root="${payload%/payload}"
  [ "$snapshot_root" != "$payload" ] || return 1
  [ "${snapshot_root%/*}" = "$home/releases" ] || return 1
  snapshot_base="${snapshot_root##*/}"
  rest="${snapshot_base#.tmp.}"
  [ "$rest" != "$snapshot_base" ] || return 1
  suffix="${rest#"$version".exec.}"
  [ "$suffix" != "$rest" ] || return 1
  case "$suffix" in
    ""|*[!A-Za-z0-9]*) return 1 ;;
  esac
  return 0
}

# The machine home this invocation speaks for, resolved exactly as
# trellis_home_resolve does it after the libraries load: --home, then
# TRELLIS_HOME, then $HOME/.trellis. Resolved once here and handed to the
# renderer, so gate and render can never disagree about which home is in play.
show_config_selected_home() {
  if [ -n "$HOME_OPT" ]; then
    printf '%s\n' "$HOME_OPT"
  elif [ -n "${TRELLIS_HOME:-}" ]; then
    printf '%s\n' "$TRELLIS_HOME"
  elif [ -n "${HOME:-}" ]; then
    printf '%s/.trellis\n' "$HOME"
  fi
}

# Default-refuse. Every clause below is a requirement; there is no branch that
# reaches `return 0` without the launcher's attestation, and no machine config
# is consulted — a config is mutable local state and can never be the thing that
# authorizes running.
show_config_entry_gate() {
  local payload="${TRELLIS_VERIFIED_PAYLOAD:-}" version="${TRELLIS_VERIFIED_RELEASE_VERSION:-}"
  local home="${TRELLIS_HOME:-}" canonical_home canonical_payload
  # The attestation describes a payload inside the launcher's own home, which is
  # the one it exported in TRELLIS_HOME. A --home selection chooses what to
  # render; it never relocates the verified payload, so the gate reads
  # TRELLIS_HOME here even though the renderer honors --home.
  show_config_gate_path_is_clean "$home" || return 1
  show_config_gate_path_is_clean "$payload" || return 1
  case "$version" in ''|*/*|*$'\t'*|*$'\n'*|*$'\r'*|.*) return 1 ;; esac
  [ -d "$home" ] && [ ! -L "$home" ] || return 1
  [ -d "$payload" ] && [ ! -L "$payload" ] || return 1
  canonical_home="$(CDPATH='' cd "$home" && pwd -P)" || return 1
  canonical_payload="$(CDPATH='' cd "$payload" && pwd -P)" || return 1
  show_config_payload_matches_release "$canonical_home" "$canonical_payload" "$version" || return 1
  [ "$SCRIPT_DIR" = "$canonical_payload/scripts" ] || return 1
  [ ! -L "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR" ] &&
    [ ! -L "$SCRIPT_DIR/show-config.sh" ] && [ -f "$SCRIPT_DIR/show-config.sh" ]
}

# Gate FIRST — before any helper is sourced and before a single argument is
# looked at — exactly as release.sh, upgrade.sh, and sync-to-template.sh do it.
# A refused copy must not run its own libraries, and it must not answer for its
# own argv either: parsing first gave `show-config.sh -h` an exit-0 path out of
# a copy the launcher never attested, so the usage text (and the exit code that
# says "this ran fine") came from an ungated copy. The gate reads TRELLIS_HOME
# and the attestation only, so it needs nothing from argv.
show_config_entry_gate || show_config_reject_direct_source

# Argv is parsed only now, inside a copy that has already been cleared. --home
# selects what to RENDER; it never relocates the verified payload the gate above
# bound to. Nothing here sources a helper or touches the store.
HOME_OPT=""; FLEET_OPT=""
usage() { echo 'Usage: show-config.sh [--home PATH] [--fleet NAME]'; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) [ "$#" -ge 2 ] || { echo 'show-config: --home requires PATH' >&2; exit 2; }; HOME_OPT="$2"; shift 2 ;;
    --fleet) [ "$#" -ge 2 ] || { echo 'show-config: --fleet requires NAME' >&2; exit 2; }; FLEET_OPT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "show-config: unknown option: $1" >&2; exit 2 ;;
  esac
done

SELECTED_HOME="$(show_config_selected_home)"

. "$SCRIPT_DIR/lib/trellis-home.sh"
. "$SCRIPT_DIR/lib/release-store.sh"
. "$SCRIPT_DIR/lib/local-registry.sh"
. "$SCRIPT_DIR/lib/attachment.sh"
. "$SCRIPT_DIR/lib/health-checks.sh"

show_config_note_failure() {
  local rc="${1:-$TRELLIS_EX_STATE}"
  case "$rc" in
    "$TRELLIS_EX_CONFLICT"|"$TRELLIS_EX_STATE"|"$TRELLIS_EX_UNAVAILABLE") ;;
    *) rc="$TRELLIS_EX_STATE" ;;
  esac
  if [ "$rc" -gt "$SHOW_CONFIG_EXIT" ]; then
    SHOW_CONFIG_EXIT="$rc"
  fi
}

# This is intentionally limited to display-safe tracked policy fields.
# Machine-local fields remain forbidden because they never authorize local
# selection, attachment, or autonomy resolution.
show_config_tracked_policy_is_usable() {
  local policy="$1"
  jq -e '
    def level: type == "number" and floor == . and . >= 1 and . <= 5;
    type == "object"
    and .schema_version == 2
    and (.maintainer_name | type == "string" and length > 0)
    and (.github_user | type == "string" and length > 0)
    and (.harnesses | type == "array" and length > 0
      and all(.[]; . == "claude" or . == "codex" or . == "omp")
      and ((unique | length) == length))
    and ((has("autonomy_default") | not) or (.autonomy_default | level))
    and ((has("mandatory_pipeline") | not) or
      (.mandatory_pipeline | type == "object"
        and ((has("enabled") | not) or (.enabled | type == "boolean"))))
    and (has("trellis_root") | not)
    and (has("projects_root") | not)
    and (has("shared_infra_root") | not)
    and (has("user_home") | not)
    and (has("source_root") | not)
    and (has("release_remote") | not)
    and (has("active_cli_release") | not)
    and (has("default_fleet") | not)
    and (has("fleets") | not)
  ' "$policy" >/dev/null 2>&1
}

# Git emits filesystem bytes.  Do not reflect an unvalidated top-level path in
# a diagnostic; resolve it through the same canonical identity boundary used by
# the local registry before making it displayable or consuming its manifest.
show_config_safe_absolute_path() {
  local path="${1:-}"
  printf '%s' "$path" | jq -eRs '
    type == "string"
    and length >= 2
    and all(explode[]; . >= 32 and (. < 127 or . > 159))
    and startswith("/")
    and (startswith("//") | not)
    and (endswith("/") | not)
    and (test("(^|/)(\\.|\\.\\.)(/|$)") | not)
  ' >/dev/null 2>&1
}

show_config_canonical_git_root() {
  local candidate="$1" identity root
  show_config_safe_absolute_path "$candidate" || return 1
  identity="$(local_registry_identity_for_root "$candidate" 2>/dev/null)" || return 1
  root="$(printf '%s\n' "$identity" | jq -r '.root // empty')" || return 1
  show_config_safe_absolute_path "$root" || return 1
  printf '%s\n' "$root"
}

show_config_registry_matches() {
  local snapshot="$1" root="$2" checkout_id="$3" worktree_id="$4"
  printf '%s\n' "$snapshot" | jq -c \
    --arg root "$root" --arg checkout "$checkout_id" --arg worktree "$worktree_id" \
    '[.entries[]
      | select(.kind == "worktree"
        and .root == $root
        and .checkout_id == $checkout
        and .worktree_id == $worktree)]'
}

show_config_valid_autonomy_level() {
  case "${1:-}" in
    1|2|3|4|5) return 0 ;;
    *) return 1 ;;
  esac
}

show_config_preset_has_frontmatter() {
  local file="$1"
  awk '
    NR == 1 {
      sub(/\r$/, "")
      if ($0 != "---") exit 1
      next
    }
    {
      sub(/\r$/, "")
    }
    $0 == "---" {
      valid = 1
      exit
    }
    END {
      exit(valid ? 0 : 1)
    }
  ' "$file" >/dev/null 2>&1
}

show_config_preset_frontmatter_value() {
  local file="$1" key="$2"
  awk -v wanted="$key" '
    NR == 1 {
      sub(/\r$/, "")
      if ($0 != "---") exit
      in_frontmatter = 1
      next
    }
    in_frontmatter {
      sub(/\r$/, "")
      if ($0 == "---") exit
      line = $0
      if (line ~ "^[[:space:]]*" wanted ":[[:space:]]*") {
        sub("^[[:space:]]*" wanted ":[[:space:]]*", "", line)
        sub(/[[:space:]]*$/, "", line)
        print line
        exit
      }
    }
  ' "$file" 2>/dev/null
}

SHOW_CONFIG_PRESET_ERROR=""
show_config_validate_active_presets() {
  local manifest="$1" policy_root="$2" preset preset_file preset_default preset_ceiling
  SHOW_CONFIG_PRESET_ERROR=""
  while IFS= read -r preset; do
    [ -n "$preset" ] || continue
    preset_file="$policy_root/core-rules/presets/$preset.md"
    if [ -L "$preset_file" ] || [ ! -f "$preset_file" ]; then
      SHOW_CONFIG_PRESET_ERROR="active preset $preset is missing from the verified immutable payload"
      return 1
    fi
    if ! show_config_preset_has_frontmatter "$preset_file"; then
      SHOW_CONFIG_PRESET_ERROR="active preset $preset has malformed frontmatter in the verified immutable payload"
      return 1
    fi
    preset_default="$(show_config_preset_frontmatter_value "$preset_file" autonomy_default)"
    preset_ceiling="$(show_config_preset_frontmatter_value "$preset_file" autonomy_ceiling)"
    if [ -n "$preset_default" ] && ! show_config_valid_autonomy_level "$preset_default"; then
      SHOW_CONFIG_PRESET_ERROR="active preset $preset has an invalid autonomy_default in the verified immutable payload"
      return 1
    fi
    if [ -n "$preset_ceiling" ] && ! show_config_valid_autonomy_level "$preset_ceiling"; then
      SHOW_CONFIG_PRESET_ERROR="active preset $preset has an invalid autonomy_ceiling in the verified immutable payload"
      return 1
    fi
  done < <(jq -r '.presets[]? | strings' "$manifest" 2>/dev/null)
  return 0
}

command -v jq >/dev/null 2>&1 || { echo 'show-config: jq is required' >&2; exit "$TRELLIS_EX_UNAVAILABLE"; }

SHOW_CONFIG_EXIT=0
# Same string the entry gate refused (or cleared) against; trellis_home_resolve
# adds only its shared absolute-path validation on top.
HOME_PATH="$(trellis_home_resolve "$SELECTED_HOME")" || exit "$?"
MACHINE_CONFIG="$HOME_PATH/config.json"
POLICY="$SCRIPT_DIR/../trellis.config.json"

echo '=== Tracked portable policy ==='
if [ -f "$POLICY" ] && [ ! -L "$POLICY" ] && show_config_tracked_policy_is_usable "$POLICY"; then
  printf '  policy file:          %s\n' "$POLICY"
  printf '  harnesses:            %s\n' "$(jq -r '(.harnesses // []) | join(", ")' "$POLICY")"
  printf '  policy default level: L%s\n' "$(jq -r '.autonomy_default // 3' "$POLICY")"
  printf '  mandatory pipeline:   %s\n' "$(jq -r '.mandatory_pipeline.enabled // false' "$POLICY")"
else
  echo '  policy file:          unavailable or invalid'
  show_config_note_failure "$TRELLIS_EX_STATE"
fi
echo '  Note: tracked policy contains no machine path, fleet, checkout, or release selection.'
echo

echo '=== Local machine state (not tracked config) ==='
if [ -L "$HOME_PATH" ] || [ ! -d "$HOME_PATH" ]; then
  printf '  Trellis home:          unavailable (%s)\n' "$HOME_PATH"
  exit "$TRELLIS_EX_UNAVAILABLE"
fi
if MACHINE_STATUS="$(hc_portable_machine_config "$HOME_PATH")"; then
  :
else
  printf '  Trellis home:          %s\n' "$HOME_PATH"
  printf '  machine config:        %s\n' "$MACHINE_STATUS"
  exit "$TRELLIS_EX_STATE"
fi

SOURCE_ROOT_CONFIG="$(jq -r '.source_root' "$MACHINE_CONFIG")"
ACTIVE_RELEASE="$(jq -r '.active_cli_release' "$MACHINE_CONFIG")"
DEFAULT_FLEET="$(jq -r '.default_fleet' "$MACHINE_CONFIG")"
SELECTED_FLEET="${FLEET_OPT:-${TRELLIS_FLEET:-$DEFAULT_FLEET}}"
trellis_home_require_fleet_name "$SELECTED_FLEET" || exit "$?"
if ! jq -e --arg fleet "$SELECTED_FLEET" '.fleets[$fleet] != null' "$MACHINE_CONFIG" >/dev/null 2>&1; then
  echo "show-config: selected fleet is not configured locally: $SELECTED_FLEET" >&2
  exit "$TRELLIS_EX_USAGE"
fi

printf '  Trellis home:          %s\n' "$HOME_PATH"
printf '  machine config:        %s (validated local state)\n' "$MACHINE_CONFIG"
if SOURCE_ROOT="$(trellis_home_require_source_root "$SOURCE_ROOT_CONFIG" 2>/dev/null)"; then
  printf '  management source:     %s (validated; not attached runtime)\n' "$SOURCE_ROOT"
else
  SOURCE_RC=$?
  printf '  management source:     unavailable (%s) — run trellis configure\n' "$SOURCE_ROOT_CONFIG"
  show_config_note_failure "$SOURCE_RC"
fi
printf '  selected fleet:        %s\n' "$SELECTED_FLEET"
printf '  configured fleets:     %s\n' "$(jq -r '.fleets | keys | join(", ")' "$MACHINE_CONFIG")"
printf '  active CLI release:    %s\n' "$ACTIVE_RELEASE"
ACTIVE_RELEASE_PATH=""
if ACTIVE_RELEASE_PATH="$(TRELLIS_HOME="$HOME_PATH" release_store_locate "$ACTIVE_RELEASE" 2>/dev/null)"; then
  printf '  release payload:       %s/payload (verified immutable installed payload)\n' "$ACTIVE_RELEASE_PATH"
else
  ACTIVE_RELEASE_RC=$?
  printf '  release payload:       unavailable or invalid — run trellis release verify %s\n' "$ACTIVE_RELEASE"
  show_config_note_failure "$ACTIVE_RELEASE_RC"
fi
echo

PROJECT_ROOT=""
PROJECT_ROOT_STATE="outside"
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  PROJECT_ROOT_RAW="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$PROJECT_ROOT_RAW" ] &&
     PROJECT_ROOT="$(show_config_canonical_git_root "$PROJECT_ROOT_RAW")"; then
    PROJECT_ROOT_STATE="valid"
  else
    PROJECT_ROOT_STATE="unsafe"
    show_config_note_failure "$TRELLIS_EX_STATE"
  fi
fi

MANIFEST_PATH=""
MANIFEST_STATE="not-applicable"
MANIFEST_PROJECT_ID=""
MANIFEST_PRESETS=""
MANIFEST_REGISTRY_CONFLICT=0
if [ -n "$PROJECT_ROOT" ]; then
  MANIFEST_PATH="$PROJECT_ROOT/.trellis.json"
  if [ -L "$MANIFEST_PATH" ] || { [ -e "$MANIFEST_PATH" ] && [ ! -f "$MANIFEST_PATH" ]; }; then
    MANIFEST_STATE="invalid"
    show_config_note_failure "$TRELLIS_EX_STATE"
  elif [ -f "$MANIFEST_PATH" ]; then
    if MANIFEST_PROJECT_ID="$(local_registry_manifest_project_id "$MANIFEST_PATH" 2>/dev/null)"; then
      MANIFEST_STATE="valid"
      MANIFEST_PRESETS="$(jq -r '(.presets // []) | join(", ")' "$MANIFEST_PATH")"
    else
      MANIFEST_STATE="invalid"
      show_config_note_failure "$TRELLIS_EX_STATE"
    fi
  else
    MANIFEST_STATE="absent"
  fi
fi

REGISTRY_STATE="not-applicable"
REGISTRY_ROW=""
REGISTRY_PROJECT=""
REGISTRY_ROOT=""
CHECKOUT_ID=""
WORKTREE_ID=""
ATTACHMENT_ID=""
ATTACHMENT_RELEASE=""
ATTACHMENT_RELEASE_PATH=""
ATTACHMENT_CONTEXT=0
ATTACHMENT_VALID=0

echo '=== Checkout/worktree context (local registry) ==='
if [ "$PROJECT_ROOT_STATE" = outside ]; then
  echo '  project root:          (run inside a Git worktree)'
elif [ "$PROJECT_ROOT_STATE" != valid ]; then
  echo '  project root:          unavailable or unsafe Git worktree root'
else
  printf '  project root:          %s\n' "$PROJECT_ROOT"
  RESOLUTION=""
  RESOLUTION_RC=0
  if RESOLUTION="$(local_registry_resolve_root "$HOME_PATH" "$PROJECT_ROOT" 2>/dev/null)"; then
    RESOLUTION_OK=1
  else
    RESOLUTION_OK=0
    RESOLUTION_RC=$?
  fi
  REGISTRY_SNAPSHOT=""
  if REGISTRY_SNAPSHOT="$(local_registry_list_json "$HOME_PATH" 2>/dev/null)"; then
    REGISTRY_SNAPSHOT_OK=1
  else
    REGISTRY_SNAPSHOT_OK=0
    REGISTRY_SNAPSHOT_RC=$?
  fi

  # A row that fails identity validation no longer fails the whole listing; the
  # drift is carried per row instead. Inspect the rows here or identity drift
  # would read as benign local state. Counting failures is itself fail-closed.
  #
  # THREE counts, because the listing above is deliberately taken with no fleet
  # argument and therefore covers the WHOLE MACHINE:
  #
  #   * this worktree's own row      — fails this command's exit class
  #   * the SELECTED fleet's rows    — fails this command's exit class
  #   * every other fleet's rows     — REPORT-ONLY
  #
  # The middle count is what floors the exit, and it stays fleet-scoped: this
  # command speaks for the fleet it selected, and raising its class on a fleet
  # it neither selected nor can act on would report a fault the operator cannot
  # resolve from here. But counting only that one while listing the whole
  # machine left rows outside the selected fleet completely invisible, so the
  # whole-machine claim and the behaviour disagreed. The third count closes
  # exactly that gap and nothing more: it is printed, never floored.
  REGISTRY_ROW_IDENTITY_ERRORS=0
  REGISTRY_FLEET_IDENTITY_ERRORS=0
  REGISTRY_OTHER_FLEET_IDENTITY_ERRORS=0
  if [ "$REGISTRY_SNAPSHOT_OK" -eq 1 ]; then
    if REGISTRY_ROW_IDENTITY_ERRORS="$(printf '%s\n' "$REGISTRY_SNAPSHOT" | jq -er \
        --arg root "$PROJECT_ROOT" \
        '[.entries[] | select(.root == $root and .availability == "identity_error")] | length' 2>/dev/null)" &&
       REGISTRY_FLEET_IDENTITY_ERRORS="$(printf '%s\n' "$REGISTRY_SNAPSHOT" | jq -er \
        --arg fleet "$SELECTED_FLEET" \
        '[.entries[] | select(.fleet == $fleet and .availability == "identity_error")] | length' 2>/dev/null)" &&
       REGISTRY_OTHER_FLEET_IDENTITY_ERRORS="$(printf '%s\n' "$REGISTRY_SNAPSHOT" | jq -er \
        --arg fleet "$SELECTED_FLEET" \
        '[.entries[] | select(.fleet != $fleet and .availability == "identity_error")] | length' 2>/dev/null)"; then
      :
    else
      REGISTRY_SNAPSHOT_OK=0
      REGISTRY_SNAPSHOT_RC="$TRELLIS_EX_STATE"
      REGISTRY_ROW_IDENTITY_ERRORS=0
      REGISTRY_FLEET_IDENTITY_ERRORS=0
      REGISTRY_OTHER_FLEET_IDENTITY_ERRORS=0
    fi
  fi

  if [ "$REGISTRY_SNAPSHOT_OK" -ne 1 ]; then
    REGISTRY_STATE="error"
    echo '  registry:              unavailable, invalid, unsafe, or identity-drift local state'
    show_config_note_failure "$REGISTRY_SNAPSHOT_RC"
  elif [ "$REGISTRY_ROW_IDENTITY_ERRORS" -gt 0 ]; then
    REGISTRY_STATE="error"
    echo '  registry:              this worktree'"'"'s registered row failed identity validation'
    show_config_note_failure "$TRELLIS_EX_STATE"
  elif [ "$RESOLUTION_OK" -eq 1 ]; then
    REGISTRY_ROOT="$(printf '%s\n' "$RESOLUTION" | jq -r '.root')"
    CHECKOUT_ID="$(printf '%s\n' "$RESOLUTION" | jq -r '.checkout_id')"
    WORKTREE_ID="$(printf '%s\n' "$RESOLUTION" | jq -r '.worktree_id')"
    REGISTRY_MATCHES="$(show_config_registry_matches "$REGISTRY_SNAPSHOT" "$REGISTRY_ROOT" "$CHECKOUT_ID" "$WORKTREE_ID")"
    REGISTRY_MATCH_COUNT="$(printf '%s\n' "$REGISTRY_MATCHES" | jq -r 'length')"
    if [ "$REGISTRY_MATCH_COUNT" -ne 1 ]; then
      REGISTRY_STATE="error"
      echo '  registry:              changed or conflicting while resolving this worktree'
      show_config_note_failure "$TRELLIS_EX_STATE"
    else
      REGISTRY_ROW="$(printf '%s\n' "$REGISTRY_MATCHES" | jq -c '.[0]')"
      REGISTRY_STATE="registered"
    fi
  else
    IDENTITY=""
    if IDENTITY="$(local_registry_identity_for_root "$PROJECT_ROOT" 2>/dev/null)"; then
      REGISTRY_ROOT="$(printf '%s\n' "$IDENTITY" | jq -r '.root')"
      CHECKOUT_ID="$(printf '%s\n' "$IDENTITY" | jq -r '.checkout_id')"
      WORKTREE_ID="$(printf '%s\n' "$IDENTITY" | jq -r '.worktree_id')"
      REGISTRY_MATCHES="$(show_config_registry_matches "$REGISTRY_SNAPSHOT" "$REGISTRY_ROOT" "$CHECKOUT_ID" "$WORKTREE_ID")"
      REGISTRY_MATCH_COUNT="$(printf '%s\n' "$REGISTRY_MATCHES" | jq -r 'length')"
      if [ "$REGISTRY_MATCH_COUNT" -eq 0 ]; then
        REGISTRY_STATE="unregistered"
        echo '  registry:              this worktree is not locally registered'
      else
        REGISTRY_STATE="error"
        echo '  registry:              conflicting or changed local state while resolving this worktree'
        show_config_note_failure "$RESOLUTION_RC"
      fi
    else
      REGISTRY_STATE="error"
      echo '  registry:              worktree identity is unavailable; refusing to infer registration'
      show_config_note_failure "$RESOLUTION_RC"
    fi
  fi

  # Sibling drift stays visible and report-only for this worktree: it never
  # blocks the sections below, but it is recorded as a failure so a fleet with
  # unusable registry rows can never exit clean.
  if [ "$REGISTRY_FLEET_IDENTITY_ERRORS" -gt 0 ]; then
    printf '  registry state:        %s row(s) in fleet %s failed identity validation\n' \
      "$REGISTRY_FLEET_IDENTITY_ERRORS" "$SELECTED_FLEET"
    show_config_note_failure "$TRELLIS_EX_STATE"
  fi
  # Report-only, by construction: the machine-wide listing is what this command
  # already reads, so hiding its other-fleet rows was a reporting gap, not a
  # scope decision. Deliberately NOT passed to `show_config_note_failure` — the
  # exit class stays the selected fleet's.
  if [ "$REGISTRY_OTHER_FLEET_IDENTITY_ERRORS" -gt 0 ]; then
    printf '  registry state (machine): %s row(s) outside fleet %s failed identity validation (report-only)\n' \
      "$REGISTRY_OTHER_FLEET_IDENTITY_ERRORS" "$SELECTED_FLEET"
  fi

  if [ "$REGISTRY_STATE" = "registered" ]; then
    FLEET="$(printf '%s\n' "$REGISTRY_ROW" | jq -r '.fleet')"
    REGISTRY_PROJECT="$(printf '%s\n' "$REGISTRY_ROW" | jq -r '.project_id')"
    REGISTRY_STATUS="$(printf '%s\n' "$REGISTRY_ROW" | jq -r '.status')"
    REGISTRY_EXCLUDED="$(printf '%s\n' "$REGISTRY_ROW" | jq -r '.excluded')"
    ATTACHMENT_ID="$(printf '%s\n' "$REGISTRY_ROW" | jq -r '.attachment_id // empty')"
    REGISTRY_HARNESSES="$(printf '%s\n' "$REGISTRY_ROW" | jq -c '.harnesses // []')"
    ATTACHMENT_RELEASE="$(printf '%s\n' "$REGISTRY_ROW" | jq -r '.release // empty')"
    printf '  registry fleet:        %s\n' "$FLEET"
    printf '  registry project:      %s\n' "$REGISTRY_PROJECT"
    printf '  registry status:       %s; excluded=%s\n' "$REGISTRY_STATUS" "$REGISTRY_EXCLUDED"
    printf '  checkout ID:           %s\n' "$CHECKOUT_ID"
    printf '  worktree ID:           %s\n' "$WORKTREE_ID"

    if [ "$FLEET" != "$SELECTED_FLEET" ]; then
      REGISTRY_STATE="error"
      ATTACHMENT_CONTEXT=1
      printf '  registry:              fleet conflict (selected %s, authoritative %s)\n' "$SELECTED_FLEET" "$FLEET"
      printf '  registry move:         detach, then reattach with --fleet %s; current binding remains authoritative\n' "$SELECTED_FLEET"
      show_config_note_failure "$TRELLIS_EX_CONFLICT"
    elif [ "$REGISTRY_STATUS" != "active" ] || [ "$REGISTRY_EXCLUDED" != "false" ]; then
      ATTACHMENT_CONTEXT=1
      echo '  attachment:            registry status/exclusion does not authorize a local attachment'
      show_config_note_failure "$TRELLIS_EX_STATE"
    else
      OWNER="$HOME_PATH/state/attachments/$CHECKOUT_ID/$WORKTREE_ID.json"
      OWNER_DETAIL_FILE=""
      if OWNER_DETAIL_FILE="$(mktemp "${TMPDIR:-/tmp}/trellis.show-config.owner.XXXXXX")"; then
        ATTACHMENT_DETAIL=""
        if hc_portable_attachment "$HOME_PATH" "$OWNER" "$REGISTRY_ROOT" "$FLEET" "$REGISTRY_PROJECT" \
          "$CHECKOUT_ID" "$WORKTREE_ID" "$ATTACHMENT_ID" "$ATTACHMENT_RELEASE" "$REGISTRY_HARNESSES" \
          > "$OWNER_DETAIL_FILE"; then
          ATTACHMENT_HEALTH_RC="$HC_OK"
        else
          ATTACHMENT_HEALTH_RC=$?
        fi
        while IFS= read -r detail; do ATTACHMENT_DETAIL="$detail"; done < "$OWNER_DETAIL_FILE"
        rm -f "$OWNER_DETAIL_FILE"
      else
        ATTACHMENT_HEALTH_RC="$HC_ERROR"
        ATTACHMENT_DETAIL='could not allocate a diagnostic for the local attachment'
        HC_PORTABLE_OWNER_STATE="corrupt"
        HC_PORTABLE_ATTACHMENT_STATE=""
      fi

      if [ "$ATTACHMENT_HEALTH_RC" -eq "$HC_OK" ] &&
         [ "$HC_PORTABLE_ATTACHMENT_STATE" = attached ] &&
         [ -n "$HC_PORTABLE_ATTACHMENT_RELEASE_PATH" ]; then
        ATTACHMENT_CONTEXT=1
        ATTACHMENT_VALID=1
        ATTACHMENT_RELEASE_PATH="$HC_PORTABLE_ATTACHMENT_RELEASE_PATH"
        printf '  attachment:            valid strict local attachment (%s)\n' "$OWNER"
        printf '  attachment release:    %s (verified immutable attachment selection)\n' "$ATTACHMENT_RELEASE"
      elif [ "$HC_PORTABLE_OWNER_STATE" = "missing" ] && [ -z "$ATTACHMENT_ID" ]; then
        echo '  attachment:            no valid local owner record (portable project may be inert)'
      else
        ATTACHMENT_CONTEXT=1
        printf '  attachment:            invalid local attachment (%s)\n' "${ATTACHMENT_DETAIL:-strict local verification failed}"
        echo '  attachment release:    unavailable (requires exact registry, owner, native surfaces, excludes, and managed hooks)'
        case "$HC_PORTABLE_OWNER_STATE" in
          conflict) show_config_note_failure "$TRELLIS_EX_CONFLICT" ;;
          *) show_config_note_failure "$TRELLIS_EX_STATE" ;;
        esac
      fi
    fi
  fi
fi
echo

echo '=== Portable project policy ==='
case "$MANIFEST_STATE" in
  valid)
    printf '  manifest:              %s/.trellis.json (portable tracked policy)\n' "$PROJECT_ROOT"
    printf '  project ID:            %s\n' "$MANIFEST_PROJECT_ID"
    printf '  presets:               %s\n' "${MANIFEST_PRESETS:-(none)}"
    printf '  autonomy override:     %s\n' "$(jq -r '.autonomy // "(unset)"' "$MANIFEST_PATH")"
    echo '  machine fields:        absent by schema; fleet/release/paths stay local'
    if [ -n "$REGISTRY_PROJECT" ] && [ "$MANIFEST_PROJECT_ID" != "$REGISTRY_PROJECT" ]; then
      printf '  registry identity:     conflict (manifest project ID %s != registry project %s)\n' \
        "$MANIFEST_PROJECT_ID" "$REGISTRY_PROJECT"
      MANIFEST_REGISTRY_CONFLICT=1
      show_config_note_failure "$TRELLIS_EX_CONFLICT"
    fi
    ;;
  invalid)
    echo '  manifest:              invalid portable policy — run trellis doctor'
    ;;
  absent)
    echo '  manifest:              absent (inert non-user layout)'
    ;;
  *)
    echo '  manifest:              not applicable outside a Git worktree'
    ;;
esac
echo

echo '=== Active preset autonomy ==='
AUTONOMY_READY=0
AUTONOMY_POLICY_ROOT=""
AUTONOMY_POLICY_LABEL=""
AUTONOMY_UNAVAILABLE=""
if [ "$MANIFEST_STATE" != "valid" ]; then
  AUTONOMY_UNAVAILABLE='a valid portable project manifest is required'
elif [ "$MANIFEST_REGISTRY_CONFLICT" -eq 1 ]; then
  AUTONOMY_UNAVAILABLE='the portable manifest and local registry identify different projects'
elif [ "$REGISTRY_STATE" = "error" ]; then
  AUTONOMY_UNAVAILABLE='local registry state is not trustworthy'
elif [ "$ATTACHMENT_VALID" -eq 1 ]; then
  AUTONOMY_POLICY_ROOT="$ATTACHMENT_RELEASE_PATH/payload"
  AUTONOMY_POLICY_LABEL="verified immutable attachment payload $AUTONOMY_POLICY_ROOT"
elif [ "$ATTACHMENT_CONTEXT" -eq 1 ]; then
  AUTONOMY_UNAVAILABLE='a local attachment exists but does not pass strict local verification'
else
  AUTONOMY_UNAVAILABLE='no exact verified immutable attachment payload is available for autonomy resolution'
fi

if [ -n "$AUTONOMY_POLICY_ROOT" ]; then
  AUTONOMY_RESOLVER="$AUTONOMY_POLICY_ROOT/core-rules/hooks/lib/autonomy.sh"
  # shellcheck disable=SC1090  # AUTONOMY_RESOLVER is resolved at runtime from the verified
  # payload; a constant path would defeat the point of sourcing the installed release.
  if [ -L "$AUTONOMY_RESOLVER" ] || [ ! -f "$AUTONOMY_RESOLVER" ]; then
    AUTONOMY_UNAVAILABLE='the selected immutable payload has no usable autonomy resolver'
    show_config_note_failure "$TRELLIS_EX_STATE"
  elif ! show_config_validate_active_presets "$MANIFEST_PATH" "$AUTONOMY_POLICY_ROOT"; then
    AUTONOMY_UNAVAILABLE="$SHOW_CONFIG_PRESET_ERROR"
    show_config_note_failure "$TRELLIS_EX_STATE"
  elif ! . "$AUTONOMY_RESOLVER"; then
    AUTONOMY_UNAVAILABLE='the selected immutable payload autonomy resolver is malformed'
    show_config_note_failure "$TRELLIS_EX_STATE"
  elif ! type _se_resolve_autonomy >/dev/null 2>&1 ||
       ! type _se_autonomy_frontmatter_value >/dev/null 2>&1 ||
       ! type _se_valid_autonomy_level >/dev/null 2>&1; then
    AUTONOMY_UNAVAILABLE='the selected immutable payload autonomy resolver is incomplete'
    show_config_note_failure "$TRELLIS_EX_STATE"
  else
    # Runtime policy and resolver both come from this exact verified payload;
    # the mutable show-config checkout and configured source are display-only.
    TRELLIS_ROOT="$AUTONOMY_POLICY_ROOT"
    export TRELLIS_ROOT
    _se_resolve_autonomy "$PROJECT_ROOT"
    AUTONOMY_READY=1

    printf '  policy source:         %s\n' "$AUTONOMY_POLICY_LABEL"
    ACTIVE_PRESETS="$(jq -r '.presets[]? | strings' "$MANIFEST_PATH")"
    if [ -z "$ACTIVE_PRESETS" ]; then
      echo '  active presets:        (none)'
    else
      echo '  active presets:'
      while IFS= read -r PRESET; do
        [ -n "$PRESET" ] || continue
        PRESET_FILE="$AUTONOMY_POLICY_ROOT/core-rules/presets/$PRESET.md"
        PRESET_DEFAULT="$(_se_autonomy_frontmatter_value "$PRESET_FILE" autonomy_default)"
        PRESET_CEILING="$(_se_autonomy_frontmatter_value "$PRESET_FILE" autonomy_ceiling)"
        if [ -n "$PRESET_DEFAULT" ]; then
          PRESET_DEFAULT_DISPLAY="L$PRESET_DEFAULT"
        else
          PRESET_DEFAULT_DISPLAY='(none)'
        fi
        if [ -n "$PRESET_CEILING" ]; then
          PRESET_CEILING_DISPLAY="L$PRESET_CEILING"
        else
          PRESET_CEILING_DISPLAY='(none)'
        fi
        printf '    %s: default=%s ceiling=%s\n' "$PRESET" "$PRESET_DEFAULT_DISPLAY" "$PRESET_CEILING_DISPLAY"
      done <<EOF
$ACTIVE_PRESETS
EOF
    fi
    printf '  effective ceiling:     L%s\n' "$AUTONOMY_CEILING"
    if [ -n "$AUTONOMY_LIMITING_PRESET" ]; then
      printf '  limiting preset:       %s\n' "$AUTONOMY_LIMITING_PRESET"
    else
      echo '  limiting preset:       (none; hard ceiling L5)'
    fi
  fi
fi
if [ "$AUTONOMY_READY" -ne 1 ]; then
  printf '  resolution:            unavailable (%s)\n' "$AUTONOMY_UNAVAILABLE"
fi
echo

echo '=== Resolved autonomy level (this turn) ==='
if [ "$AUTONOMY_READY" -eq 1 ]; then
  SESSION_FILE="$PROJECT_ROOT/.claude/session-autonomy"
  if [ -f "$SESSION_FILE" ]; then
    SESSION_OVERRIDE="$(head -1 "$SESSION_FILE" 2>/dev/null | tr -d '[:space:]')"
    if _se_valid_autonomy_level "$SESSION_OVERRIDE"; then
      printf '  session override:      L%s (%s)\n' "$SESSION_OVERRIDE" "$SESSION_FILE"
    else
      printf '  session override:      invalid (%s; ignored by resolver)\n' "$SESSION_FILE"
    fi
  else
    echo '  session override:      (unset — no /autonomy run yet this session)'
  fi
  printf '  requested level:       L%s\n' "$AUTONOMY_REQUESTED_LEVEL"
  printf '  effective level:       L%s (%s)\n' "$AUTONOMY_LEVEL" "$AUTONOMY_NAME"
  if [ "$AUTONOMY_CLAMPED" -eq 1 ]; then
    printf '  clamp:                 requested L%s -> effective L%s (preset %s)\n' \
      "$AUTONOMY_REQUESTED_LEVEL" "$AUTONOMY_LEVEL" "$AUTONOMY_LIMITING_PRESET"
  else
    echo '  clamp:                 not needed'
  fi
  printf '  effective ceiling:     L%s\n' "$AUTONOMY_CEILING"
  if [ -n "$AUTONOMY_LIMITING_PRESET" ]; then
    printf '  limiting preset:       %s\n' "$AUTONOMY_LIMITING_PRESET"
  else
    echo '  limiting preset:       (none; hard ceiling L5)'
  fi
else
  printf '  resolution:            unavailable (%s)\n' "$AUTONOMY_UNAVAILABLE"
fi

exit "$SHOW_CONFIG_EXIT"
