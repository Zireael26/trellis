#!/usr/bin/env bash
# Materialize one generic scheduled task from verified local state.
# Bash 3.2 compatible.

set -u
# Every private capture and rendered task input starts owner-only even before
# its explicit chmod. The materializer never writes to a project root.
umask 077


SCRIPT_DIR="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/trellis-home.sh
. "$SCRIPT_DIR/lib/trellis-home.sh"
# shellcheck source=lib/local-registry.sh
. "$SCRIPT_DIR/lib/local-registry.sh"
# shellcheck source=lib/release-store.sh
. "$SCRIPT_DIR/lib/release-store.sh"
TASK_PUBLISH_HELPER="$SCRIPT_DIR/lib/task-publish.py"

materialize_error() {
  printf 'trellis task: %s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  materialize-scheduled-task.sh materialize --fleet NAME TASK [--home PATH]

Materializes TASK from the verified active immutable release and exactly one
strict local-registry snapshot. The output is private machine state at:
  $TRELLIS_HOME/tasks/NAME/TASK/

The materialized directory contains snapshot.json, prompt.md, targets.md, and
manifest.json. Conductor additionally preserves private backlog.json. AEO
receives compatibility Markdown inputs only when its URL and marker mapping
exists in local registry metadata.

Exit classes: 0 success, 2 bad arguments, 3 publication conflict, 4 invalid
local state, 5 unavailable checkout, release, or local capability.
EOF
}

usage_error() {
  materialize_error "$*"
  usage >&2
  return "$TRELLIS_EX_USAGE"
}

require_task_name() {
  local task="${1:-}"
  if ! trellis_home_is_valid_lock_name "$task"; then
    materialize_error "invalid task name $task; expected ^[a-z0-9][a-z0-9._-]{0,63}$"
    return "$TRELLIS_EX_USAGE"
  fi
  return 0
}

sha256_file() {
  local path="${1:-}" digest
  if command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 < "$path" | awk '{print $1}')" || return "$TRELLIS_EX_UNAVAILABLE"
  elif command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum < "$path" | awk '{print $1}')" || return "$TRELLIS_EX_UNAVAILABLE"
  else
    materialize_error "a SHA-256 command (shasum or sha256sum) is required"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if ! printf '%s' "$digest" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$'; then
    materialize_error "could not calculate SHA-256 for $path"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  printf '%s\n' "$digest"
}

shell_quote() {
  # Bash printf %q returns one syntactically complete shell word and preserves
  # spaces, quotes, dollar signs, and other shell metacharacters as data.
  printf '%q' "${1:-}"
}

shell_assignment() {
  local name="${1:-}" value="${2:-}" quoted=""
  case "$name" in
    TRELLIS_AEO_RUNNER|TRELLIS_AEO_GATE|TRELLIS_AEO_TARGETS|TRELLIS_AEO_REGISTRY|TRELLIS_AEO_BLACKLIST|TRELLIS_TASK_ROOT|OUTPUT) ;;
    *)
      materialize_error "unknown trusted shell assignment name: $name"
      return "$TRELLIS_EX_STATE"
      ;;
  esac
  quoted="$(shell_quote "$value")" || return "$TRELLIS_EX_UNAVAILABLE"
  printf '%s=%s\n' "$name" "$quoted"
}

release_manifest_blob_oid() {
  local release_json="${1:-}" relative_path="${2:-}" oid=""

  if [ -L "$release_json" ] || [ ! -f "$release_json" ] || ! release_store_path_is_safe "$relative_path"; then
    materialize_error "release asset identity requires a regular release manifest and safe relative path"
    return "$TRELLIS_EX_STATE"
  fi
  oid="$(jq -er --arg path "$relative_path" '
    [ .tree[]
      | select(.path == $path and .mode == "100644")
      | .oid
    ] as $oids
    | if (
        ($oids | length) == 1
        and ($oids[0] | type == "string" and test("^[a-f0-9]{40,64}$"))
      ) then $oids[0]
      else error("missing or invalid regular release blob") end
  ' "$release_json")" || {
    materialize_error "verified release manifest does not identify required asset: $relative_path"
    return "$TRELLIS_EX_STATE"
  }
  printf '%s\n' "$oid"
}

stage_release_asset() {
  local release_payload="${1:-}" release_json="${2:-}" relative_path="${3:-}" destination="${4:-}"
  local source="" expected_oid="" actual_oid=""

  if [ -L "$release_payload" ] || [ ! -d "$release_payload" ] ||
     [ -z "$destination" ] || [ -e "$destination" ] || [ -L "$destination" ]; then
    materialize_error "release asset staging requires a real payload and new private destination"
    return "$TRELLIS_EX_STATE"
  fi
  source="$release_payload/$relative_path"
  if [ -L "$source" ] || [ ! -f "$source" ]; then
    materialize_error "verified active release does not provide required asset: $relative_path"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  expected_oid="$(release_manifest_blob_oid "$release_json" "$relative_path")" || return "$?"
  actual_oid="$(release_store_blob_oid_for_path "$source")" || {
    materialize_error "could not identify verified release asset: $relative_path"
    return "$TRELLIS_EX_STATE"
  }
  if [ "$actual_oid" != "$expected_oid" ]; then
    materialize_error "verified release asset differs from its manifest: $relative_path"
    return "$TRELLIS_EX_STATE"
  fi
  if ! cat "$source" > "$destination"; then
    materialize_error "could not stage verified release asset: $relative_path"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  chmod 600 "$destination" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  actual_oid="$(release_store_blob_oid_for_path "$destination")" || {
    materialize_error "could not identify staged release asset: $relative_path"
    return "$TRELLIS_EX_STATE"
  }
  if [ "$actual_oid" != "$expected_oid" ]; then
    materialize_error "staged release asset differs from its manifest: $relative_path"
    return "$TRELLIS_EX_STATE"
  fi
}

verify_staged_release_asset() {
  local release_json="${1:-}" relative_path="${2:-}" staged="${3:-}"
  local expected_oid="" actual_oid=""

  if [ -L "$staged" ] || [ ! -f "$staged" ]; then
    materialize_error "staged release asset must be a regular file: $relative_path"
    return "$TRELLIS_EX_STATE"
  fi
  expected_oid="$(release_manifest_blob_oid "$release_json" "$relative_path")" || return "$?"
  actual_oid="$(release_store_blob_oid_for_path "$staged")" || {
    materialize_error "could not identify staged release asset: $relative_path"
    return "$TRELLIS_EX_STATE"
  }
  if [ "$actual_oid" != "$expected_oid" ]; then
    materialize_error "staged release asset no longer matches release manifest: $relative_path"
    return "$TRELLIS_EX_STATE"
  fi
}

stage_release_task_assets() {
  local release_payload="${1:-}" release_json="${2:-}" task="${3:-}" stage="${4:-}"
  local relative_root="" asset_stage=""

  relative_root="scheduled-tasks/$task"
  asset_stage="$stage/.release-assets"
  if [ -L "$stage" ] || [ ! -d "$stage" ] || [ -e "$asset_stage" ] || [ -L "$asset_stage" ]; then
    materialize_error "private release asset staging directory is invalid"
    return "$TRELLIS_EX_STATE"
  fi
  mkdir "$asset_stage" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod 700 "$asset_stage" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  stage_release_asset "$release_payload" "$release_json" "$relative_root/prompt.md" "$asset_stage/prompt.md" || return "$?"
  stage_release_asset "$release_payload" "$release_json" "$relative_root/targets.md" "$asset_stage/targets.md" || return "$?"
  if [ "$task" = "dep-major-upgrade-watch" ]; then
    stage_release_asset "$release_payload" "$release_json" "$relative_root/watchlist.md" "$stage/watchlist.md" || return "$?"
  fi
}

task_publish_identity() {
  local path="${1:-}" identity=""

  if [ -L "$TASK_PUBLISH_HELPER" ] || [ ! -f "$TASK_PUBLISH_HELPER" ]; then
    materialize_error "fd-pinned task publication helper is unavailable"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    materialize_error "python3 is required for fd-pinned task publication"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  identity="$(python3 "$TASK_PUBLISH_HELPER" identity "$path")" || return "$?"
  if ! printf '%s' "$identity" | LC_ALL=C grep -Eq '^[0-9]+:[0-9]+$'; then
    materialize_error "fd-pinned task publication helper returned an invalid directory identity"
    return "$TRELLIS_EX_STATE"
  fi
  printf '%s\n' "$identity"
}

pin_verified_release_manifest() {
  local release_dir="${1:-}" release_version="${2:-}" destination="${3:-}"
  local live_manifest="" before_sha256="" pinned_sha256="" after_sha256=""

  if [ -L "$release_dir" ] || [ ! -d "$release_dir" ] ||
     [ -z "$destination" ] || [ -e "$destination" ] || [ -L "$destination" ]; then
    materialize_error "release manifest pinning requires a verified release and new private destination"
    return "$TRELLIS_EX_STATE"
  fi
  live_manifest="$release_dir/release.json"
  if [ -L "$live_manifest" ] || [ ! -f "$live_manifest" ]; then
    materialize_error "verified active release manifest is not a regular file"
    return "$TRELLIS_EX_STATE"
  fi
  before_sha256="$(sha256_file "$live_manifest")" || return "$?"
  if ! cat "$live_manifest" > "$destination"; then
    materialize_error "could not pin verified active release manifest"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  chmod 600 "$destination" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  pinned_sha256="$(sha256_file "$destination")" || return "$?"
  if [ "$pinned_sha256" != "$before_sha256" ]; then
    materialize_error "verified active release manifest changed while pinning"
    return "$TRELLIS_EX_STATE"
  fi

  # `release_store_locate` has already verified this release. Reverify the
  # live store only as a secondary integrity check, then bind it to the exact
  # private manifest copy that provides every release asset OID below.
  release_store_verify_path "$release_dir" "$release_version" || return "$?"
  after_sha256="$(sha256_file "$live_manifest")" || return "$?"
  if [ "$after_sha256" != "$pinned_sha256" ]; then
    materialize_error "verified active release manifest changed after pinning"
    return "$TRELLIS_EX_STATE"
  fi
  printf '%s\n' "$pinned_sha256"
}

verify_pinned_release_manifest() {
  local release_dir="${1:-}" release_version="${2:-}" pinned_manifest="${3:-}" expected_sha256="${4:-}"
  local live_manifest="" pinned_sha256="" live_sha256=""

  if [ -L "$pinned_manifest" ] || [ ! -f "$pinned_manifest" ] ||
     ! printf '%s' "$expected_sha256" | LC_ALL=C grep -Eq '^[a-f0-9]{64}$'; then
    materialize_error "pinned release manifest is invalid"
    return "$TRELLIS_EX_STATE"
  fi
  pinned_sha256="$(sha256_file "$pinned_manifest")" || return "$?"
  if [ "$pinned_sha256" != "$expected_sha256" ]; then
    materialize_error "private pinned release manifest changed during materialization"
    return "$TRELLIS_EX_STATE"
  fi
  release_store_verify_path "$release_dir" "$release_version" || return "$?"
  live_manifest="$release_dir/release.json"
  if [ -L "$live_manifest" ] || [ ! -f "$live_manifest" ]; then
    materialize_error "verified active release manifest is not a regular file"
    return "$TRELLIS_EX_STATE"
  fi
  live_sha256="$(sha256_file "$live_manifest")" || return "$?"
  if [ "$live_sha256" != "$expected_sha256" ]; then
    materialize_error "verified active release manifest changed during materialization"
    return "$TRELLIS_EX_STATE"
  fi
}


capture_registry_snapshot() {
  local home="${1:-}" fleet="${2:-}" capture="${3:-}" rc=0 release_rc=0
  local snapshot_home="" snapshot_registry="" registry="" projection=""

  if [ -z "$capture" ] || [ -e "$capture" ] || [ -L "$capture" ]; then
    materialize_error "registry capture destination must be a new regular file: $capture"
    return "$TRELLIS_EX_STATE"
  fi
  : > "$capture" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod 600 "$capture" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"

  # Freeze the persisted registry beneath its writer lock before projecting it.
  # The strict list operation then validates identities and reads only the
  # private copy, so no later materialization step touches the live pathname.
  trellis_home_lock_acquire "$home" registry 30 || return "$?"
  snapshot_home="$(mktemp -d "$(dirname "$capture")/.registry-home.XXXXXX")" || rc="$TRELLIS_EX_UNAVAILABLE"
  if [ "$rc" -eq 0 ]; then
    chmod 700 "$snapshot_home" 2>/dev/null || rc="$TRELLIS_EX_UNAVAILABLE"
  fi
  snapshot_registry="$snapshot_home/registry.json"
  if [ "$rc" -eq 0 ]; then
    registry="$(local_registry_path "$home")" || rc="$?"
  fi
  if [ "$rc" -eq 0 ]; then
    if [ -e "$registry" ] || [ -L "$registry" ]; then
      if [ -L "$registry" ] || [ ! -f "$registry" ]; then
        materialize_error "registry must be a regular file before snapshot capture"
        rc="$TRELLIS_EX_STATE"
      elif ! cp "$registry" "$snapshot_registry"; then
        rc="$TRELLIS_EX_UNAVAILABLE"
      fi
    else
      local_registry_empty_json > "$snapshot_registry" || rc="$TRELLIS_EX_UNAVAILABLE"
    fi
  fi
  if [ "$rc" -eq 0 ]; then
    chmod 600 "$snapshot_registry" 2>/dev/null || rc="$TRELLIS_EX_UNAVAILABLE"
  fi
  if [ "$rc" -eq 0 ]; then
    local_registry_validate_file "$snapshot_registry" || rc="$?"
  fi
  if [ "$rc" -eq 0 ]; then
    local_registry_list_json "$snapshot_home" "$fleet" > "$capture"
    rc="$?"
  fi
  # `local_registry_list_json` accurately marks a missing worktree unavailable,
  # but a deliberately detached project remains detached even after its former
  # root disappears. Preserve that explicit operator classification from the
  # same locked registry image; detached records are report-only, not a reason
  # to invent a required checkout.
  if [ "$rc" -eq 0 ]; then
    projection="$snapshot_home/registry-list-with-status.json"
    if ! jq -eS --slurpfile registry "$snapshot_registry" '
      ($registry[0].projects // {}) as $projects
      | .entries |= map(
          . as $entry
          | ($projects[$entry.project_key].status // null) as $recorded_status
          | if $recorded_status == "detached" then .status = "detached" else . end
        )
    ' "$capture" > "$projection"; then
      materialize_error "could not preserve detached registry classification in snapshot"
      rc="$TRELLIS_EX_STATE"
    elif ! mv "$projection" "$capture"; then
      rc="$TRELLIS_EX_UNAVAILABLE"
    fi
  fi
  if [ -n "$snapshot_home" ] && [ -d "$snapshot_home" ] && ! rm -rf "$snapshot_home"; then
    materialize_error "could not remove private registry snapshot staging directory"
    [ "$rc" -ne 0 ] || rc="$TRELLIS_EX_UNAVAILABLE"
  fi
  trellis_home_lock_release >/dev/null 2>&1
  release_rc="$?"
  if [ "$rc" -eq 0 ] && [ "$release_rc" -ne 0 ]; then
    rc="$release_rc"
  fi
  if [ "$rc" -eq 0 ]; then
    if [ -L "$capture" ] || [ ! -f "$capture" ] ||
       ! jq -e 'type == "object" and .schema_version == 1 and (.entries | type == "array")' "$capture" >/dev/null 2>&1; then
      materialize_error "strict registry snapshot capture is invalid"
      rc="$TRELLIS_EX_STATE"
    elif ! chmod 600 "$capture" 2>/dev/null; then
      rc="$TRELLIS_EX_UNAVAILABLE"
    fi
  fi
  return "$rc"
}

canonicalize_registry_snapshot() {
  local raw_snapshot="${1:-}" output="${2:-}" fleet="${3:-}"

  if [ -L "$raw_snapshot" ] || [ ! -f "$raw_snapshot" ] || [ -e "$output" ] || [ -L "$output" ]; then
    materialize_error "registry snapshot canonicalization requires a regular source and new destination"
    return "$TRELLIS_EX_STATE"
  fi
  if ! jq -eS --arg fleet "$fleet" '
    def fleet_name:
      type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$");
    def project_id:
      type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
    def project_key:
      type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
    def nullable_sha256:
      . == null or (type == "string" and test("^[a-f0-9]{64}$"));
    def nullable_safe_path:
      . == null or (
        type == "string"
        and startswith("/")
        and length > 1
        and (test("[[:cntrl:]]") | not)
        and (contains("//") | not)
        and (test("(^|/)(\\.|\\.\\.)(/|$)") | not)
      );
    def harnesses:
      type == "array"
      and all(.[]; type == "string" and (. == "claude" or . == "codex" or . == "omp"));
    def safe_text:
      type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
    def safe_date:
      type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
    def safe_relative_marker:
      safe_text
      and (startswith("/") | not)
      and (contains("//") | not)
      and (test("(^|/)(\\.|\\.\\.)(/|$)") | not);
    def aeo_skip:
      type == "object" and (.skip_reason? | safe_text);
    def aeo_mapping:
      type == "object"
      and (.url? | safe_text)
      and (.marker_file? | safe_relative_marker)
      and (.marker? | safe_text);
    # The registry schema intentionally allows extension metadata. A task
    # snapshot is agent-visible local state, so retain only fields this task
    # contract consumes and reconstruct them field-by-field.
    def allowed_metadata:
      . as $metadata
      | {}
      | if (($metadata.legacy? | type) == "object")
        and (($metadata.legacy.blacklisted? // false) | type == "boolean")
        then . + {
          legacy: {
            blacklisted: ($metadata.legacy.blacklisted // false)
          }
        } else . end
      | if (
          ($metadata.legacy? | type) == "object"
          and ($metadata.legacy.blacklist? | type) == "object"
          and ($metadata.legacy.blacklist.reason? | safe_text)
          and ($metadata.legacy.blacklist.added? | safe_date)
          and ($metadata.legacy.blacklist.review_after? | safe_date)
        ) then .legacy.blacklist = {
          reason: $metadata.legacy.blacklist.reason,
          added: $metadata.legacy.blacklist.added,
          review_after: $metadata.legacy.blacklist.review_after
        } else . end
      | if (
          ($metadata.task_targets? | type) == "object"
          and ($metadata.task_targets["aeo-baseline"]? | aeo_skip)
        ) then .task_targets = {
          "aeo-baseline": {
            skip_reason: $metadata.task_targets["aeo-baseline"].skip_reason
          }
        } elif (
          ($metadata.task_targets? | type) == "object"
          and ($metadata.task_targets["aeo-baseline"]? | aeo_mapping)
        ) then .task_targets = {
          "aeo-baseline": {
            url: $metadata.task_targets["aeo-baseline"].url,
            marker_file: $metadata.task_targets["aeo-baseline"].marker_file,
            marker: $metadata.task_targets["aeo-baseline"].marker
          }
        } else . end;
    def entry:
      type == "object"
      and (.fleet | fleet_name and . == $fleet)
      and (.project_id | project_id)
      and (.project_key | project_key)
      and (.status == "active" or .status == "unavailable" or .status == "detached")
      and (.kind == "worktree" or .kind == "checkout" or .kind == "unavailable"
           or .kind == "project")
      and (.checkout_id | nullable_sha256)
      and (.worktree_id | nullable_sha256)
      and (.root | nullable_safe_path)
      and (.git_common_dir | nullable_safe_path)
      and (.harnesses | harnesses)
      and (.metadata | type == "object")
      and (.availability == "available" or .availability == "unavailable"
           or .availability == "identity_error")
      and (.excluded | type == "boolean");
    if (
      type != "object"
      or .schema_version != 1
      or (.entries | type != "array")
      or (.discovery_ignores | type != "object")
      or (all(.entries[]; entry) | not)
    ) then
      error("invalid strict registry snapshot")
    else
      .entries |= (
        map(.metadata = (.metadata | allowed_metadata))
        | sort_by(.fleet, .project_id, (.checkout_id // ""), (.worktree_id // ""), (.root // ""))
      )
    end
  ' "$raw_snapshot" > "$output"; then
    materialize_error "could not canonicalize strict registry snapshot"
    return "$TRELLIS_EX_STATE"
  fi
  chmod 600 "$output" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
}

render_template() {
  local source="${1:-}" destination="${2:-}" task_root="${3:-}" snapshot_path="${4:-}"
  local fleet="${5:-}" release_payload="${6:-}" output_root="${7:-}" environment=""

  if [ -L "$source" ] || [ ! -f "$source" ]; then
    materialize_error "release template must be a regular file: $source"
    return "$TRELLIS_EX_STATE"
  fi
  if [ -e "$destination" ] || [ -L "$destination" ]; then
    materialize_error "render destination must be a new regular file: $destination"
    return "$TRELLIS_EX_STATE"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    materialize_error "python3 is required to render scheduled-task templates"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  environment="$(
    shell_assignment OUTPUT "$output_root" &&
    shell_assignment TRELLIS_AEO_RUNNER "$release_payload/core-rules/skills/aeo-gate/scripts/run-fleet.sh" &&
    shell_assignment TRELLIS_AEO_GATE "$release_payload/core-rules/skills/aeo-gate/scripts/aeo_gate.py" &&
    shell_assignment TRELLIS_AEO_TARGETS "$task_root/aeo-targets.md" &&
    shell_assignment TRELLIS_AEO_REGISTRY "$task_root/registry.md" &&
    shell_assignment TRELLIS_AEO_BLACKLIST "$task_root/blacklist.md" &&
    shell_assignment TRELLIS_TASK_ROOT "$task_root"
  )" || return "$TRELLIS_EX_UNAVAILABLE"

  if ! python3 - "$source" "$destination" "$task_root" "$snapshot_path" "$fleet" "$release_payload" "$output_root" "$environment" <<'PY'
import os
import stat
import sys

source, destination, task_root, snapshot_path, fleet, release_payload, output_root, environment = sys.argv[1:]

try:
    source_stat = os.lstat(source)
    if not stat.S_ISREG(source_stat.st_mode):
        raise ValueError("template source is not a regular file")
    if os.path.lexists(destination):
        raise ValueError("render destination already exists")
    with open(source, "rb") as handle:
        source_bytes = handle.read()

    values = {
        b"TASK_ROOT": os.fsencode(task_root),
        b"SNAPSHOT_JSON": os.fsencode(snapshot_path),
        b"FLEET": os.fsencode(fleet),
        b"RELEASE_PAYLOAD": os.fsencode(release_payload),
        b"OUTPUT_ROOT": os.fsencode(output_root),
        b"AEO_ENVIRONMENT": os.fsencode(environment),
    }
    rendered = []
    cursor = 0
    while True:
        opening = source_bytes.find(b"{{", cursor)
        if opening < 0:
            rendered.append(source_bytes[cursor:])
            break
        closing = source_bytes.find(b"}}", opening + 2)
        if closing < 0:
            raise ValueError("template contains an unclosed placeholder")
        token = source_bytes[opening + 2:closing]
        if token not in values:
            label = token.decode("ascii", "backslashreplace")
            raise ValueError("template contains an unknown placeholder {{" + label + "}}")
        rendered.append(source_bytes[cursor:opening])
        rendered.append(values[token])
        cursor = closing + 2

    output = b"".join(rendered)
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        view = memoryview(output)
        while view:
            written = os.write(descriptor, view)
            view = view[written:]
    finally:
        os.close(descriptor)
except (OSError, ValueError) as error:
    print("trellis task: " + str(error), file=sys.stderr)
    raise SystemExit(1)
PY
  then
    materialize_error "could not render release template: $source"
    return "$TRELLIS_EX_STATE"
  fi
  chmod 600 "$destination" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
}

# Most tasks traverse project checkouts. These control-plane tasks retain
# unavailable project records for reporting but do not require a checkout to
# materialize a useful local task state.
task_requires_checkout() {
  case "${1:-}" in
    audit-report-rollup|conductor|registry-blacklist-health) return 1 ;;
    *) return 0 ;;
  esac
}

unavailable_required_projects() {
  local snapshot="${1:-}"
  jq -cS '
    [ .entries
      | sort_by(.project_key, (.checkout_id // ""), (.worktree_id // ""), (.root // ""))
      | group_by(.project_key)[]
      | . as $rows
      # An explicitly detached project is report-only. A missing root does not
      # convert it into a requirement for a checkout-consuming task.
      | select(any($rows[]; .status == "detached") | not)
      | select(any($rows[]; (.excluded // false) | not))
      | select((any($rows[];
          .status == "active" and .kind == "worktree" and .availability == "available"
        )) | not)
      | $rows[0].project_id
    ] | sort | unique
  ' "$snapshot"
}

eligible_active_project_count() {
  local snapshot="${1:-}"
  jq -r '
    [
      .entries
      | group_by(.project_key)[]
      | select(any(.[]; .status == "detached") | not)
      | select(any(.[]; (.excluded // false) | not))
      | select(any(.[];
          .status == "active" and .kind == "worktree" and .availability == "available"
        ))
      | .[0].project_id
    ] | unique | length
  ' "$snapshot"
}

nonexcluded_project_count() {
  local snapshot="${1:-}"
  jq -r '
    [
      .entries
      | group_by(.project_key)[]
      | select(any(.[]; (.excluded // false) | not))
      | .[0].project_id
    ] | unique | length
  ' "$snapshot"
}

detached_only_project_count() {
  local snapshot="${1:-}"
  jq -r '
    [
      .entries
      | group_by(.project_key)[]
      | select(any(.[]; (.excluded // false) | not))
      | select(all(.[]; .status == "detached"))
      | .[0].project_id
    ] | unique | length
  ' "$snapshot"
}

aeo_url_matches_target_parser() {
  local url="${1:-}"
  if ! command -v python3 >/dev/null 2>&1; then
    materialize_error "python3 is required to validate AEO target URLs"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  python3 - "$url" <<'PY'
import sys
from urllib.parse import urlparse

parsed = urlparse(sys.argv[1])
raise SystemExit(0 if parsed.scheme in {"http", "https"} and parsed.netloc else 1)
PY
}

append_planned_error() {
  local errors_file="${1:-}" message="${2:-}"
  [ -n "$message" ] || return 0
  printf '%s\n' "$message" >> "$errors_file" || return "$TRELLIS_EX_UNAVAILABLE"
}

# Build the legacy Markdown triplet accepted by the currently shipped AEO fleet
# runner. It is intentionally derived only from snapshot metadata:
# metadata.task_targets["aeo-baseline"] is either
# {url, marker_file, marker} or {skip_reason}.
prepare_aeo_compatibility() {
  local raw_snapshot="${1:-}" stage="${2:-}" errors_file="${3:-}"
  local plan="" errors="" detail="" active_count=0 project="" url=""

  if [ -L "$raw_snapshot" ] || [ ! -f "$raw_snapshot" ] ||
     [ -L "$stage" ] || [ ! -d "$stage" ] ||
     [ -L "$errors_file" ] || [ ! -f "$errors_file" ]; then
    materialize_error "AEO compatibility requires a regular snapshot, private stage, and planned-error file"
    return "$TRELLIS_EX_STATE"
  fi
  AEO_COMPATIBILITY="unavailable"
  plan="$stage/.aeo-plan.json"
  if ! jq -S '
    def safe_text:
      if type == "string" then
        length > 0 and (test("[[:cntrl:]|]") | not)
      else false end;
    def safe_checkout:
      if safe_text then
        startswith("/")
        and (contains("//") | not)
        and (test("(^|/)(\\.|\\.\\.)(/|$)") | not)
      else false end;
    def safe_marker_file:
      if safe_text then
        (startswith("/") | not)
        and (contains("//") | not)
        and (test("(^|/)(\\.|\\.\\.)(/|$)") | not)
      else false end;
    def safe_date:
      if type == "string" then
        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
      else false end;
    def valid_blacklist:
      if type == "object" then
        (.reason | safe_text)
        and (.added | safe_date)
        and (.review_after | safe_date)
      else false end;
    .entries
    | sort_by(.project_key, (.checkout_id // ""), (.worktree_id // ""), (.root // ""))
    | group_by(.project_key)
    | map(
        . as $rows
        | $rows[0] as $entry
        | [ $rows[] | select(
              .status == "active" and .kind == "worktree" and .availability == "available"
            ) ] as $available
        | {
            project: $entry.project_id,
            excluded: ($entry.excluded // false),
            blacklist: (
              ($entry.metadata.legacy? // null)
              | if type == "object" then .blacklist // null else null end
            ),
            aeo: (
              ($entry.metadata.task_targets? // {})
              | if type == "object" then .["aeo-baseline"] // null else null end
            ),
            checkout: (
              ($available
                | sort_by((.checkout_id // ""), (.worktree_id // ""), (.root // ""))
                | .[0].root) // null
            )
          }
      )
    | sort_by(.project)
    | map(
        if (.checkout != null and ((.checkout | safe_checkout) | not)) then
          . + {mode: "error", error: "recorded checkout contains an unsafe Markdown/control character or path component"}
        elif .excluded then
          if (.blacklist | valid_blacklist) then . + {mode: "blacklist"}
          else . + {mode: "error", error: "local exclusion metadata requires reason, added, and review_after"}
          end
        elif .checkout == null then
          . + {mode: "skip", reason: "checkout unavailable in local registry snapshot"}
        elif (.aeo | type) != "object" then
          . + {mode: "error", error: "missing metadata.task_targets[\"aeo-baseline\"]"}
        elif (.aeo.skip_reason? | safe_text) then
          . + {mode: "skip", reason: .aeo.skip_reason}
        elif ((.aeo.url? | safe_text)
          and (.aeo.marker_file? | safe_marker_file)
          and (.aeo.marker? | safe_text)) then
          . + {
            mode: "active",
            url: .aeo.url,
            marker_file: .aeo.marker_file,
            marker: .aeo.marker
          }
        else
          . + {mode: "error", error: "metadata.task_targets[\"aeo-baseline\"] requires a parser-valid URL, marker_file, and marker or explicit skip_reason"}
        end
      )
  ' "$raw_snapshot" > "$plan"; then
    rm -f "$plan"
    return "$TRELLIS_EX_STATE"
  fi

  active_count="$(jq '[.[] | select(.mode == "active")] | length' "$plan")" || {
    rm -f "$plan"
    return "$TRELLIS_EX_STATE"
  }
  if [ "$active_count" -eq 0 ]; then
    append_planned_error "$errors_file" "AEO materialization: no eligible active targets in local registry snapshot" || {
      rm -f "$plan"
      return "$TRELLIS_EX_UNAVAILABLE"
    }
  fi
  errors="$(jq -r '.[] | select(.mode == "error") | "\(.project): \(.error)"' "$plan")" || {
    rm -f "$plan"
    return "$TRELLIS_EX_STATE"
  }
  if [ -n "$errors" ]; then
    while IFS= read -r detail; do
      append_planned_error "$errors_file" "AEO materialization: $detail" || {
        rm -f "$plan"
        return "$TRELLIS_EX_UNAVAILABLE"
      }
    done <<EOF
$errors
EOF
  fi
  while IFS=$'\t' read -r project url; do
    [ -n "$project" ] || continue
    if ! aeo_url_matches_target_parser "$url"; then
      append_planned_error "$errors_file" "AEO materialization: $project: target URL does not meet released parser scheme/netloc contract" || {
        rm -f "$plan"
        return "$TRELLIS_EX_UNAVAILABLE"
      }
    fi
  done <<EOF
$(jq -r '.[] | select(.mode == "active") | [.project, .url] | @tsv' "$plan")
EOF
  if [ -s "$errors_file" ]; then
    rm -f "$plan"
    return 0
  fi

  if ! jq -r '
    "# Local AEO registry compatibility input",
    "",
    "Generated from snapshot.json. Do not edit; materialize again after local registry changes.",
    "",
    "## Active projects",
    "",
    "| Project | Path | Class | Shared services | Project-owned local infrastructure | Fixed-port status | Notes |",
    "|---|---|---|---|---|---|---|",
    (.[] | "| \(.project) | - | local | {} | none | {} | materialized strict local snapshot |")
  ' "$plan" > "$stage/registry.md"; then
    rm -f "$plan"
    return "$TRELLIS_EX_STATE"
  fi
  if ! jq -r '
    "# Local AEO blacklist compatibility input",
    "",
    "Generated from snapshot.json. Do not edit; materialize again after local registry changes.",
    "",
    "## 1. Temporarily excluded (registered projects)",
    "",
    "| Project | Reason | Added | Review after |",
    "|---|---|---|---|",
    (.[] | select(.mode == "blacklist") | "| \(.project) | \(.blacklist.reason) | \(.blacklist.added) | \(.blacklist.review_after) |"),
    "",
    "## 2. Permanently excluded from management",
    "",
    "| Path | Reason |",
    "|---|---|"
  ' "$plan" > "$stage/blacklist.md"; then
    rm -f "$plan"
    return "$TRELLIS_EX_STATE"
  fi
  if ! jq -r '
    "# Local AEO baseline compatibility targets",
    "",
    "Generated only from local registry metadata and the matching snapshot.json.",
    "",
    "## Active targets",
    "",
    "| Project | URL | Checkout | Marker file | Marker |",
    "|---|---|---|---|---|",
    (.[] | select(.mode == "active") | "| \(.project) | \(.url) | \(.checkout) | \(.marker_file) | \(.marker) |"),
    "",
    "## Explicit skips",
    "",
    "| Project | Reason |",
    "|---|---|",
    (.[] | select(.mode == "skip") | "| \(.project) | \(.reason) |")
  ' "$plan" > "$stage/aeo-targets.md"; then
    rm -f "$plan"
    return "$TRELLIS_EX_STATE"
  fi
  rm -f "$plan"
  chmod 600 "$stage/registry.md" "$stage/blacklist.md" "$stage/aeo-targets.md" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  AEO_COMPATIBILITY="ready"
  return 0
}
publish_stage() {
  local fleet_dir="${1:-}" fleet="${2:-}" stage="${3:-}" task="${4:-}"
  local fleet_identity="${5:-}" stage_identity="${6:-}" stage_name=""

  if [ -L "$TASK_PUBLISH_HELPER" ] || [ ! -f "$TASK_PUBLISH_HELPER" ]; then
    materialize_error "fd-pinned task publication helper is unavailable"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  stage_name="$(basename "$stage")"
  python3 "$TASK_PUBLISH_HELPER" publish \
    --fleet-dir "$fleet_dir" \
    --fleet-name "$fleet" \
    --fleet-identity "$fleet_identity" \
    --stage-name "$stage_name" \
    --stage-identity "$stage_identity" \
    --task-name "$task"
}

validate_existing_task_root() {
  local task_root="${1:-}"
  if [ -L "$task_root" ] || { [ -e "$task_root" ] && [ ! -d "$task_root" ]; }; then
    materialize_error "materialized task destination must be a real directory: $task_root"
    return "$TRELLIS_EX_STATE"
  fi
}

materialize_directory_identity() {
  local path="${1:-}" label="${2:-directory}"
  if [ -L "$path" ] || [ ! -d "$path" ]; then
    materialize_error "$label must be a real directory: $path"
    return "$TRELLIS_EX_STATE"
  fi
  trellis_home_real_dir "$path" || {
    materialize_error "could not resolve $label: $path"
    return "$TRELLIS_EX_STATE"
  }
}

validate_task_publication_sink() {
  local tasks_dir="${1:-}" fleet_dir="${2:-}" task_root="${3:-}" stage="${4:-}"
  local expected_tasks_dir="${5:-}" expected_fleet_dir="${6:-}"
  local actual_tasks_dir="" actual_fleet_dir="" stage_parent=""

  actual_tasks_dir="$(materialize_directory_identity "$tasks_dir" "task state directory")" || return "$?"
  actual_fleet_dir="$(materialize_directory_identity "$fleet_dir" "fleet task state directory")" || return "$?"
  if [ "$actual_tasks_dir" != "$expected_tasks_dir" ] || [ "$actual_fleet_dir" != "$expected_fleet_dir" ]; then
    materialize_error "task publication parent changed during materialization"
    return "$TRELLIS_EX_STATE"
  fi
  if [ "$(dirname "$task_root")" != "$fleet_dir" ] || [ "$(dirname "$stage")" != "$fleet_dir" ]; then
    materialize_error "task publication paths escape the selected fleet directory"
    return "$TRELLIS_EX_STATE"
  fi
  stage_parent="$(materialize_directory_identity "$(dirname "$stage")" "task staging parent")" || return "$?"
  if [ "$stage_parent" != "$expected_fleet_dir" ] || [ -L "$stage" ] || [ ! -d "$stage" ]; then
    materialize_error "task staging directory is no longer bound to the selected fleet directory"
    return "$TRELLIS_EX_STATE"
  fi
  validate_existing_task_root "$task_root"
}
materialize_conductor_backlog() {
  local source="${1:-}" snapshot="${2:-}" destination="${3:-}"

  if [ -e "$source" ] || [ -L "$source" ]; then
    if [ -L "$source" ] || [ ! -f "$source" ]; then
      materialize_error "local conductor backlog must be a regular file: $source"
      return "$TRELLIS_EX_STATE"
    fi
    if ! jq -eS '
      def safe_text:
        type == "string"
        and length > 0
        and length <= 4096
        and (test("[[:cntrl:]]") | not);
      def safe_task_id:
        type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$");
      def safe_project_id:
        type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$");
      def safe_tag:
        type == "string" and test("^[a-z0-9][a-z0-9._-]{0,63}$");
      def safe_date:
        type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$");
      def weight_set:
        type == "object"
        and ((keys - ["deadline", "impact", "unblock", "effort", "staleness"]) | length == 0)
        and (keys | length == 5)
        and all(.[]; type == "number" and . >= 0 and . <= 1)
        and (([.deadline, .impact, .unblock, .effort, .staleness] | add) >= 0.999)
        and (([.deadline, .impact, .unblock, .effort, .staleness] | add) <= 1.001);
      def optional_text($field):
        if has($field) then (.[$field] | safe_text) else true end;
      def item:
        type == "object"
        and ((keys - [
          "id", "project_id", "title", "note", "priority", "effort", "type",
          "impact", "engine", "status", "deadline", "tags", "auto_spec",
          "safe", "surgical", "blocked_reason"
        ]) | length == 0)
        and (.id | safe_task_id)
        and (
          if has("project_id") then
            (.project_id == null or (.project_id | safe_project_id))
          else true end
        )
        and optional_text("title")
        and optional_text("note")
        and (
          if has("priority") then
            (.priority == "high" or .priority == "med" or .priority == "low")
          else true end
        )
        and (
          if has("effort") then
            (.effort == "S" or .effort == "M" or .effort == "L")
          else true end
        )
        and (
          if has("type") then
            (.type == "dev" or .type == "content" or .type == "design"
             or .type == "infra" or .type == "strategy" or .type == "planning")
          else true end
        )
        and (
          if has("impact") then
            (.impact == "revenue" or .impact == "users"
             or .impact == "strategic" or .impact == "internal")
          else true end
        )
        and (
          if has("engine") then
            (.engine == "claude" or .engine == "codex" or .engine == "omp")
          else true end
        )
        and (
          if has("status") then
            (.status == "todo" or .status == "blocked" or .status == "done")
          else true end
        )
        and (if has("deadline") then (.deadline | safe_date) else true end)
        and (
          if has("tags") then
            (.tags | type == "array"
             and all(.[]; safe_tag)
             and (length == (unique | length)))
          else true end
        )
        and (
          if has("auto_spec") then
            (.auto_spec == null or (.auto_spec | type == "boolean"))
          else true end
        )
        and (if has("safe") then .safe == "manual" else true end)
        and (
          if has("surgical") then (.surgical | type == "boolean") else true end
        )
        and (
          if .status? == "blocked" then
            (.blocked_reason | safe_text)
          else
            (has("blocked_reason") | not)
          end
        )
        and (
          if has("project_id") and .project_id != null then true
          else .auto_spec? != true
          end
        );
      if (
        type == "object"
        and ((keys - ["schema_version", "weights", "items"]) | length == 0)
        and (.schema_version == 1)
        and (.items | type == "array")
        and all(.items[]; item)
        and ((.items | map(.id) | length) == (.items | map(.id) | unique | length))
        and (if has("weights") then (.weights | weight_set) else true end)
      ) then . else error("invalid conductor backlog") end
    ' "$source" > "$destination"; then
      materialize_error "local conductor backlog has an invalid schema"
      return "$TRELLIS_EX_STATE"
    fi
  else
    jq -nS '{schema_version: 1, items: []}' > "$destination" || return "$TRELLIS_EX_UNAVAILABLE"
  fi

  if ! jq -e --slurpfile backlog "$destination" '
    (
      [
        .entries[]
        | select(
            .status == "active"
            and .kind == "worktree"
            and .availability == "available"
            and ((.excluded // false) | not)
          )
        | .project_id
      ] | unique
    ) as $eligible
    | all(
        $backlog[0].items[];
        if has("project_id") and .project_id != null then
          .project_id as $project_id | ($eligible | index($project_id)) != null
        else true
        end
      )
  ' "$snapshot" >/dev/null 2>&1; then
    materialize_error "local conductor backlog references a project without an active available snapshot root"
    return "$TRELLIS_EX_STATE"
  fi
  chmod 600 "$destination" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
}

cmd_materialize() {
  local home_opt="" fleet="" task="" home="" config="" release_version=""
  local release_dir="" release_payload="" release_commit="" release_manifest="" release_manifest_sha256="" stage=""
  local tasks_dir="" fleet_dir="" task_root="" output_root="" snapshot_path="" errors_file=""
  local tasks_dir_real="" fleet_dir_real="" fleet_dir_identity="" stage_identity="" task_lock_held=false
  local canonical_snapshot="" required_unavailable="[]" requires_checkout=false
  local entry_count=0 unavailable_count=0 eligible_count=0 nonexcluded_count=0
  local detached_only_count=0 conductor_backlog=false registry_state_errors=0
  local snapshot_sha256="" planned_errors="[]" manifest_status="ready" detail=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --home)
        [ "$#" -ge 2 ] || { usage_error "--home requires PATH"; return "$?"; }
        home_opt="$2"
        shift 2
        ;;
      --home=*)
        home_opt="${1#--home=}"
        [ -n "$home_opt" ] || { usage_error "--home requires PATH"; return "$?"; }
        shift
        ;;
      --fleet)
        [ "$#" -ge 2 ] || { usage_error "--fleet requires NAME"; return "$?"; }
        fleet="$2"
        shift 2
        ;;
      --fleet=*)
        fleet="${1#--fleet=}"
        [ -n "$fleet" ] || { usage_error "--fleet requires NAME"; return "$?"; }
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        usage_error "unknown materialize option: $1"
        return "$?"
        ;;
      *)
        if [ -n "$task" ]; then
          usage_error "materialize accepts exactly one TASK"
          return "$?"
        fi
        task="$1"
        shift
        ;;
    esac
  done
  while [ "$#" -gt 0 ]; do
    if [ -n "$task" ]; then
      usage_error "materialize accepts exactly one TASK"
      return "$?"
    fi
    task="$1"
    shift
  done

  [ -n "$fleet" ] || { usage_error "materialize requires --fleet NAME"; return "$?"; }
  [ -n "$task" ] || { usage_error "materialize requires TASK"; return "$?"; }
  trellis_home_require_fleet_name "$fleet" || return "$?"
  require_task_name "$task" || return "$?"

  home="$(local_registry_home "$home_opt")" || return "$?"
  export TRELLIS_HOME="$home"
  trellis_home_prepare_home "$home" || return "$?"
  config="$(trellis_home_config_path "$home")"
  trellis_home_validate_config "$config" || return "$?"
  if ! jq -e --arg fleet "$fleet" '.fleets[$fleet] | type == "object"' "$config" >/dev/null 2>&1; then
    materialize_error "fleet is not configured in local machine state: $fleet"
    return "$TRELLIS_EX_STATE"
  fi
  release_version="$(jq -r '.active_cli_release' "$config")" || return "$TRELLIS_EX_STATE"
  release_dir="$(release_store_locate "$release_version")" || return "$?"
  release_payload="$release_dir/payload"
  if [ -L "$release_dir/release.json" ] || [ ! -f "$release_dir/release.json" ]; then
    materialize_error "verified active release manifest is not a regular file"
    return "$TRELLIS_EX_STATE"
  fi
  release_commit="$(jq -er '.commit | select(type == "string" and test("^[a-f0-9]{40,64}$"))' "$release_dir/release.json")" || {
    materialize_error "verified active release manifest has an invalid commit"
    return "$TRELLIS_EX_STATE"
  }

  tasks_dir="$home/tasks"
  fleet_dir="$tasks_dir/$fleet"
  trellis_home_prepare_private_dir "$tasks_dir" "task state directory" || return "$?"
  trellis_home_prepare_private_dir "$fleet_dir" "fleet task state directory" || return "$?"
  tasks_dir_real="$(materialize_directory_identity "$tasks_dir" "task state directory")" || return "$?"
  fleet_dir_real="$(materialize_directory_identity "$fleet_dir" "fleet task state directory")" || return "$?"
  task_root="$fleet_dir/$task"
  validate_existing_task_root "$task_root" || return "$?"
  output_root="$task_root/output"
  snapshot_path="$task_root/snapshot.json"
  stage="$(mktemp -d "$fleet_dir/.${task}.tmp.XXXXXX")" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod 700 "$stage" 2>/dev/null || { rm -rf "$stage"; return "$TRELLIS_EX_UNAVAILABLE"; }
  fleet_dir_identity="$(task_publish_identity "$fleet_dir")" || return "$?"

  cleanup_stage() {
    [ -n "${stage:-}" ] && [ -d "$stage" ] && rm -rf "$stage"
    if [ "${task_lock_held:-false}" = true ]; then
      trellis_home_lock_release >/dev/null 2>&1 || true
      task_lock_held=false
    fi
  }
  trap cleanup_stage EXIT HUP INT TERM
  release_manifest="$stage/.release-manifest.json"
  release_manifest_sha256="$(pin_verified_release_manifest "$release_dir" "$release_version" "$release_manifest")" || return "$?"
  # Every asset identity below comes from this pinned release manifest, never a
  # later live-store read. The live release is reverified before publication.
  stage_release_task_assets "$release_payload" "$release_manifest" "$task" "$stage" || return "$?"
  mkdir "$stage/output" || return "$TRELLIS_EX_UNAVAILABLE"
  chmod 700 "$stage/output" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"

  # This is the sole registry read for this materialization. The writer lock
  # freezes a private copy before strict listing, canonicalization, and render.
  capture_registry_snapshot "$home" "$fleet" "$stage/.registry-snapshot.json" || return "$?"
  canonical_snapshot="$stage/.snapshot.canonical.json"
  canonicalize_registry_snapshot "$stage/.registry-snapshot.json" "$canonical_snapshot" "$fleet" || return "$?"
  rm -f "$stage/.registry-snapshot.json" || return "$TRELLIS_EX_UNAVAILABLE"
  mv "$canonical_snapshot" "$stage/snapshot.json" || return "$TRELLIS_EX_UNAVAILABLE"

  # The pinned manifest is the sole authority for asset identities. This live
  # store verification only rejects a changed or corrupt installed release.
  verify_pinned_release_manifest "$release_dir" "$release_version" "$release_manifest" "$release_manifest_sha256" || return "$?"
  verify_staged_release_asset "$release_manifest" "scheduled-tasks/$task/prompt.md" "$stage/.release-assets/prompt.md" || return "$?"
  render_template "$stage/.release-assets/prompt.md" "$stage/prompt.md" "$task_root" "$snapshot_path" "$fleet" "$release_payload" "$output_root" || return "$?"
  verify_staged_release_asset "$release_manifest" "scheduled-tasks/$task/targets.md" "$stage/.release-assets/targets.md" || return "$?"
  render_template "$stage/.release-assets/targets.md" "$stage/targets.md" "$task_root" "$snapshot_path" "$fleet" "$release_payload" "$output_root" || return "$?"
  if [ "$task" = "dep-major-upgrade-watch" ]; then
    verify_staged_release_asset "$release_manifest" "scheduled-tasks/$task/watchlist.md" "$stage/watchlist.md" || return "$?"
  fi
  if [ -L "$stage/.release-assets" ] || [ ! -d "$stage/.release-assets" ] || ! rm -rf "$stage/.release-assets"; then
    materialize_error "could not remove private release asset staging directory"
    return "$TRELLIS_EX_UNAVAILABLE"
  fi

  errors_file="$stage/.planned-errors"
  : > "$errors_file" || return "$TRELLIS_EX_UNAVAILABLE"
  # A row that fails identity validation stays visible in the snapshot, but it
  # is a state error for every task rather than a merely unavailable root.
  registry_state_errors="$(jq -r '[.entries[] | select(.availability == "identity_error")] | length' \
    "$stage/snapshot.json")" || return "$TRELLIS_EX_STATE"
  if [ "$registry_state_errors" -gt 0 ]; then
    while IFS= read -r detail; do
      [ -n "$detail" ] || continue
      append_planned_error "$errors_file" "local registry row failed identity validation: $detail" ||
        return "$TRELLIS_EX_UNAVAILABLE"
    done <<EOF
$(jq -r '[.entries[] | select(.availability == "identity_error") | .project_key] | unique | .[]' "$stage/snapshot.json")
EOF
  fi
  if task_requires_checkout "$task"; then
    requires_checkout=true
    entry_count="$(jq -r '.entries | length' "$stage/snapshot.json")" || return "$TRELLIS_EX_STATE"
    eligible_count="$(eligible_active_project_count "$stage/snapshot.json")" || return "$TRELLIS_EX_STATE"
    nonexcluded_count="$(nonexcluded_project_count "$stage/snapshot.json")" || return "$TRELLIS_EX_STATE"
    detached_only_count="$(detached_only_project_count "$stage/snapshot.json")" || return "$TRELLIS_EX_STATE"
    if [ "$entry_count" -eq 0 ]; then
      append_planned_error "$errors_file" "no registered project records in local registry snapshot" || return "$TRELLIS_EX_UNAVAILABLE"
    elif [ "$nonexcluded_count" -gt 0 ] && [ "$detached_only_count" -ne "$nonexcluded_count" ] && [ "$eligible_count" -eq 0 ]; then
      append_planned_error "$errors_file" "no eligible active checkout targets in local registry snapshot" || return "$TRELLIS_EX_UNAVAILABLE"
    fi
    required_unavailable="$(unavailable_required_projects "$stage/snapshot.json")" || return "$TRELLIS_EX_STATE"
    if [ "$(printf '%s\n' "$required_unavailable" | jq 'length')" -gt 0 ]; then
      while IFS= read -r detail; do
        append_planned_error "$errors_file" "required checkout unavailable for project: $detail" || return "$TRELLIS_EX_UNAVAILABLE"
      done <<EOF
$(printf '%s\n' "$required_unavailable" | jq -r '.[]')
EOF
    fi
  fi
  # Serialize the old private conductor state and the final directory swap.
  # The lock is acquired only after the registry capture has released its own
  # writer lock, because the shared lock helper is intentionally non-reentrant.
  trellis_home_lock_acquire "$home" scheduled-tasks 30 || return "$?"
  task_lock_held=true
  validate_task_publication_sink "$tasks_dir" "$fleet_dir" "$task_root" "$stage" "$tasks_dir_real" "$fleet_dir_real" || return "$?"
  stage_identity="$(task_publish_identity "$stage")" || return "$?"

  if [ "$task" = "conductor" ]; then
    materialize_conductor_backlog "$task_root/backlog.json" "$stage/snapshot.json" "$stage/backlog.json" || return "$?"
    conductor_backlog=true
  fi

  if [ "$task" = "aeo-baseline" ]; then
    prepare_aeo_compatibility "$stage/snapshot.json" "$stage" "$errors_file" || return "$?"
  else
    AEO_COMPATIBILITY="not-applicable"
  fi
  entry_count="$(jq -r '.entries | length' "$stage/snapshot.json")" || return "$TRELLIS_EX_STATE"
  # `unavailable` counts only absent roots. A row that failed identity
  # validation is unusable for a different reason and is counted separately, so
  # the snapshot block never under-reports rows this task cannot act on.
  unavailable_count="$(jq -r '[.entries[] | select(.availability == "unavailable")] | length' "$stage/snapshot.json")" || return "$TRELLIS_EX_STATE"
  snapshot_sha256="$(sha256_file "$stage/snapshot.json")" || return "$?"
  planned_errors="$(jq -Rsc 'split("\n") | map(select(length > 0)) | sort | unique' "$errors_file")" || return "$TRELLIS_EX_STATE"
  rm -f "$errors_file"
  if [ "$(printf '%s\n' "$planned_errors" | jq 'length')" -gt 0 ]; then
    manifest_status="planned-error"
  fi

  if ! jq -nS \
    --arg fleet "$fleet" \
    --arg task "$task" \
    --arg release_version "$release_version" \
    --arg release_commit "$release_commit" \
    --arg snapshot_sha256 "$snapshot_sha256" \
    --arg output_root "$output_root" \
    --arg status "$manifest_status" \
    --arg aeo_compatibility "$AEO_COMPATIBILITY" \
    --argjson conductor_backlog "$conductor_backlog" \
    --argjson entry_count "$entry_count" \
    --argjson unavailable_count "$unavailable_count" \
    --argjson identity_error_count "$registry_state_errors" \
    --argjson checkout_required "$requires_checkout" \
    --argjson unavailable_projects "$required_unavailable" \
    --argjson planned_errors "$planned_errors" \
    '{
      schema_version: 1,
      fleet: $fleet,
      task: $task,
      status: $status,
      source: {
        release_version: $release_version,
        release_commit: $release_commit
      },
      files: (
        {
          snapshot: "snapshot.json",
          prompt: "prompt.md",
          targets: "targets.md",
          output: "output"
        }
        + if $conductor_backlog then {
            backlog: "backlog.json"
          } else {} end
        + if $aeo_compatibility == "ready" then {
            aeo_targets: "aeo-targets.md",
            aeo_registry: "registry.md",
            aeo_blacklist: "blacklist.md"
          } else {} end
      ),
      snapshot: {
        sha256: $snapshot_sha256,
        entry_count: $entry_count,
        unavailable_entry_count: $unavailable_count,
        identity_error_entry_count: $identity_error_count
      },
      output: {
        relative_path: "output",
        root: $output_root
      },
      requirements: {
        checkout_required: $checkout_required,
        unavailable_projects: $unavailable_projects,
        planned_errors: $planned_errors
      },
      aeo_compatibility: $aeo_compatibility
    }' > "$stage/manifest.json"; then
    return "$TRELLIS_EX_STATE"
  fi
  chmod 600 "$stage/manifest.json" 2>/dev/null || return "$TRELLIS_EX_UNAVAILABLE"
  validate_task_publication_sink "$tasks_dir" "$fleet_dir" "$task_root" "$stage" "$tasks_dir_real" "$fleet_dir_real" || return "$?"
  verify_pinned_release_manifest "$release_dir" "$release_version" "$release_manifest" "$release_manifest_sha256" || return "$?"
  publish_stage "$fleet_dir" "$fleet" "$stage" "$task" "$fleet_dir_identity" "$stage_identity" || return "$?"
  stage=""
  if ! trellis_home_lock_release; then
    task_lock_held=false
    materialize_error "published task but could not release scheduled-task lock"
    return "$TRELLIS_EX_STATE"
  fi
  task_lock_held=false
  trap - EXIT HUP INT TERM

  printf '%s\n' "$task_root"
  if [ "$manifest_status" = "planned-error" ]; then
    printf '%s\n' "$planned_errors" | jq -r '.[] | "trellis task: planned error: \(.)"' >&2
    if [ "$registry_state_errors" -gt 0 ]; then
      return "$TRELLIS_EX_STATE"
    fi
    return "$TRELLIS_EX_UNAVAILABLE"
  fi
  return 0
}

main() {
  local command="${1:-help}"
  case "$command" in
    materialize)
      shift
      cmd_materialize "$@"
      return "$?"
      ;;
    help|-h|--help)
      usage
      return 0
      ;;
    *)
      usage_error "unknown command: $command"
      return "$?"
      ;;
  esac
}

main "$@"
